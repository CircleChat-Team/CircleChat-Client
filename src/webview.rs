//! 主窗口：tao 窗口 + wry WebView，以及事件循环里处理的那些事
//! （重置快捷键、站内跳转、系统通知、下载）。

use std::cell::RefCell;
use std::path::{Path, PathBuf};
use std::rc::Rc;

use serde::Deserialize;
use tao::dpi::{LogicalPosition, LogicalSize};
use tao::event::{Event, WindowEvent};
use tao::event_loop::{ControlFlow, EventLoopBuilder};
use tao::window::{UserAttentionType, WindowBuilder};
use wry::{NewWindowResponse, WebContext, WebViewBuilder};

use crate::app;
use crate::download;
use crate::icon;
use crate::identity;
use crate::links;
use crate::notice;
use crate::notification;
use crate::reload;
use crate::shake;

const WINDOW_WIDTH: f64 = 1100.0;
const WINDOW_HEIGHT: f64 = 720.0;

/// 注入到每个页面的脚本：捕获重置快捷键并通过 IPC 通知 Rust 侧。
///
/// 注意：WebView 无法把原生键盘事件交给宿主，所以快捷键只能在页面里监听后用 IPC 上报；
/// 脚本在页面 JS 之前执行，所以这里直接在 `window` 上做捕获监听。
const RESET_SHORTCUT_SCRIPT: &str = r#"
(function () {
  if (window.__circleChatResetBound) { return; }
  window.__circleChatResetBound = true;

  function isMac() {
    return /Mac|iPhone|iPad|iPod/.test(navigator.platform || navigator.userAgent);
  }

  window.addEventListener('keydown', function (event) {
    var modifier = isMac() ? event.metaKey : event.ctrlKey;
    if (!modifier || !event.shiftKey) { return; }
    if (event.key !== 'R' && event.key !== 'r') { return; }

    event.preventDefault();
    event.stopPropagation();

    if (window.ipc) {
      window.ipc.postMessage(JSON.stringify({ action: 'reset' }));
    }
  }, true);
})();
"#;

/// WebView 要加载的内容来源。
pub(crate) enum WebViewSource {
    /// 正常情况：加载已校验过的站点地址
    Url(String),
    /// 没有可用地址（首次启动且用户没在配置窗口里保存）：显示内置提示页
    MissingConfig,
}

/// 页面通过 IPC 发过来的消息。除了 `action` 之外的字段都是可选的，
/// 所以 `{"action":"reset"}` 这种最小消息也能解析。
#[derive(Debug, Deserialize)]
struct IpcMessage {
    action: String,
    #[serde(default)]
    id: String,
    #[serde(default)]
    title: String,
    #[serde(default)]
    body: String,
}

#[derive(Debug, Clone)]
enum AppEvent {
    /// 用户请求重置配置（WebView 内按下快捷键）
    ResetConfig,
    /// 站内链接需要在当前 WebView 内打开（window.open / target=_blank）
    Navigate(String),
    /// 页面请求发系统通知
    Notify {
        id: String,
        title: String,
        body: String,
    },
    /// 通知发送结果（从后台线程回到主线程，再由主线程回传给页面）
    NotifyResult {
        id: String,
        ok: bool,
        error: Option<String>,
    },
    /// 页面请求把窗口置顶到前台并抖动（新消息提醒等场景）
    Shake,
    /// 抖动动画的一帧（step 为位移模式索引），真正改位置只在主线程做
    ShakeTick {
        step: u32,
    },
    /// 页面请求重新加载当前页（F5 / Ctrl+R 或 window.__CIRCLECHAT__.reload()）
    Reload,
}

/// 抖动位移模式（像素）：起步静息 → 左右上下错动 → 收尾回到 (0,0)。
const SHAKE_PATTERN: &[(i32, i32)] = &[
    (0, 0),
    (-12, 0),
    (12, 0),
    (-12, 8),
    (12, -8),
    (-9, 0),
    (9, 0),
    (-6, 5),
    (6, -5),
    (0, 0),
];
/// 抖动总帧数（等于模式长度，保证收尾落回静息位）。
const SHAKE_STEPS: u32 = SHAKE_PATTERN.len() as u32;
/// 每帧间隔（毫秒）：太快看不清、太慢像卡顿。
const SHAKE_STEP_MS: u64 = 28;

/// WebView 的持久化数据目录：HTTP 磁盘缓存、Cookie、localStorage 都落在这里。
/// wry 默认用的是临时上下文（`WebContext::new_ephemeral`），什么都不会留下，必须自己给一个目录。
fn data_dir() -> PathBuf {
    match app::data_dir() {
        Some(dir) => dir.join("webview"),
        None => app::fallback_dir("circlechat-webview"),
    }
}

/// 启动 WebView 主窗口，直到窗口关闭或进程重启。
pub(crate) fn run(source: WebViewSource, config_path: PathBuf) -> wry::Result<()> {
    let site = match &source {
        WebViewSource::Url(url) => links::site_origin(url),
        WebViewSource::MissingConfig => None,
    };

    let event_loop = EventLoopBuilder::<AppEvent>::with_user_event().build();
    let ipc_proxy = event_loop.create_proxy();
    let window_proxy = event_loop.create_proxy();
    let notify_proxy = event_loop.create_proxy();

    let window = WindowBuilder::new()
        .with_title(app::APP_DISPLAY_NAME)
        .with_window_icon(icon::window_icon())
        .with_inner_size(LogicalSize::new(WINDOW_WIDTH, WINDOW_HEIGHT))
        .build(&event_loop)
        .expect("创建主窗口失败");

    let navigation_site = site.clone();
    let new_window_site = site;

    // 持久化上下文：图片 / 字体 / 媒体 / 附件这些会被真正缓存到磁盘，重启后仍在。
    let data_dir = data_dir();
    if let Err(err) = std::fs::create_dir_all(&data_dir) {
        eprintln!("创建 WebView 数据目录失败（{data_dir:?}）：{err}");
    }
    println!("WebView 缓存目录：{}", data_dir.display());
    let mut web_context = WebContext::new(Some(data_dir));

    let user_agent = identity::user_agent();
    println!("User-Agent：{user_agent}");

    let builder = WebViewBuilder::new_with_web_context(&mut web_context)
        // 告诉页面“我是客户端，不是浏览器”：UA 覆盖所有请求，注入的全局变量给页面 JS 用
        .with_user_agent(user_agent)
        .with_initialization_script(identity::client_marker_script())
        .with_initialization_script(RESET_SHORTCUT_SCRIPT)
        // 页面可调用的系统通知 API：await window.__CIRCLECHAT__.notify({...})
        .with_initialization_script(notification::API_SCRIPT)
        // 页面可调用的“抖动窗口”API：await window.__CIRCLECHAT__.shakeWindow()
        .with_initialization_script(shake::API_SCRIPT)
        // 重新加载当前页：F5 / Ctrl+R 接管 + window.__CIRCLECHAT__.reload()
        .with_initialization_script(reload::API_SCRIPT)
        .with_ipc_handler(move |request| {
            let message = match serde_json::from_str::<IpcMessage>(request.body()) {
                Ok(message) => message,
                Err(err) => {
                    eprintln!("收到无法解析的 IPC 消息：{err}");
                    return;
                }
            };

            match message.action.as_str() {
                "reset" => {
                    let _ = ipc_proxy.send_event(AppEvent::ResetConfig);
                }
                "notify" => {
                    let _ = ipc_proxy.send_event(AppEvent::Notify {
                        id: message.id,
                        title: message.title,
                        body: message.body,
                    });
                }
                "shake" => {
                    let _ = ipc_proxy.send_event(AppEvent::Shake);
                }
                "reload" => {
                    let _ = ipc_proxy.send_event(AppEvent::Reload);
                }
                other => eprintln!("收到未知的 IPC action：{other}"),
            }
        })
        // 站外链接：拦下来交给系统浏览器
        .with_navigation_handler(move |target| {
            if links::is_external_link(&target, &navigation_site) {
                links::open_in_system(&target);
                false
            } else {
                true
            }
        })
        // window.open / target="_blank"：站外的走系统浏览器，站内的在当前 WebView 打开
        .with_new_window_req_handler({
            // 这个 move 闭包会拿走 window_proxy，所以先给它一个独立克隆，
            // 事件循环里还要用原版 window_proxy 发 ShakeTick。
            let new_window_proxy = window_proxy.clone();
            move |target, _features| {
                if links::is_external_link(&target, &new_window_site) {
                    links::open_in_system(&target);
                } else {
                    let _ = new_window_proxy.send_event(AppEvent::Navigate(target));
                }
                NewWindowResponse::Deny
            }
        })
        // 下载：落到系统下载目录，重名自动加序号
        .with_download_started_handler(|url, destination| {
            let file_name = destination
                .file_name()
                .and_then(|name| name.to_str())
                .map(str::to_string)
                .or_else(|| download::file_name_from_url(&url))
                .unwrap_or_else(|| "download".to_string());

            let target = download::unique_path(&download::download_dir(), &file_name);
            println!("开始下载：{url} → {}", target.display());
            *destination = target;
            true
        })
        .with_download_completed_handler(|url, path, success| {
            let location = path
                .map(|path| path.display().to_string())
                .unwrap_or_else(|| "<未知路径>".to_string());

            if success {
                println!("下载完成：{url} → {location}");
            } else {
                eprintln!("下载失败：{url}");
            }
        });

    // 有地址就加载站点（入口文档显式要求不缓存，前端发新版本立刻生效），
    // 没有地址就显示内置的“尚未配置”提示页。
    let builder = match source {
        WebViewSource::Url(url) => {
            builder.with_url_and_headers(url, identity::entry_request_headers())
        }
        WebViewSource::MissingConfig => {
            println!("未配置服务地址，显示提示页");
            builder.with_html(notice::missing_config_notice_page())
        }
    };

    #[cfg(any(
        target_os = "windows",
        target_os = "macos",
        target_os = "ios",
        target_os = "android"
    ))]
    let webview = builder.build(&window)?;

    #[cfg(not(any(
        target_os = "windows",
        target_os = "macos",
        target_os = "ios",
        target_os = "android"
    )))]
    let webview = {
        use tao::platform::unix::WindowExtUnix;
        use wry::WebViewBuilderExtUnix;
        let vbox = window.default_vbox().expect("获取 GTK 容器失败");
        builder.build_gtk(vbox)?
    };

    let webview = Rc::new(webview);

    // 抖动动画的基准位置（主线程独享，用 RefCell 即可），收到 Shake 时记下当前
    // 窗口位置，之后每一帧 ShakeTick 都相对它做偏移，收尾帧落回原位。
    let shake_base = Rc::new(RefCell::new(None::<LogicalPosition<f64>>));

    // tao 的事件循环是 `-> !`：退出即结束进程，所以“回到配置窗口”必须重启自身。
    event_loop.run(move |event, _, control_flow| {
        *control_flow = ControlFlow::Wait;

        match event {
            Event::WindowEvent {
                event: WindowEvent::CloseRequested,
                ..
            } => {
                *control_flow = ControlFlow::Exit;
            }
            Event::UserEvent(AppEvent::ResetConfig) => {
                clear_config(&config_path);
                relaunch();
                *control_flow = ControlFlow::Exit;
            }
            Event::UserEvent(AppEvent::Navigate(target)) => {
                if let Err(err) = webview.load_url(&target) {
                    eprintln!("站内跳转失败（{target}）：{err}");
                }
            }
            Event::UserEvent(AppEvent::Reload) => {
                println!("重新加载当前页");
                if let Err(err) = webview.reload() {
                    eprintln!("重新加载失败：{err}");
                }
            }
            Event::UserEvent(AppEvent::Notify { id, title, body }) => {
                // D-Bus / WinRT 调用可能阻塞，丢到后台线程，结果再回到主线程
                let proxy = notify_proxy.clone();
                std::thread::spawn(move || {
                    let (ok, error) = match notification::show(&title, &body) {
                        Ok(()) => {
                            println!("已发送系统通知：{title}");
                            (true, None)
                        }
                        Err(err) => {
                            eprintln!("发送系统通知失败：{err}");
                            (false, Some(err))
                        }
                    };

                    let _ = proxy.send_event(AppEvent::NotifyResult { id, ok, error });
                });
            }
            Event::UserEvent(AppEvent::NotifyResult { id, ok, error }) => {
                // 用 serde_json 生成字面量，避免标题里的引号把脚本拼坏
                let id_literal = serde_json::to_string(&id).unwrap_or_else(|_| "\"\"".to_string());
                let payload = serde_json::json!({ "ok": ok, "error": error });
                let script = format!(
                    "window.__circleChatNotifyResult && window.__circleChatNotifyResult({id_literal}, {payload});"
                );

                if let Err(err) = webview.evaluate_script(&script) {
                    eprintln!("回传通知结果失败：{err}");
                }
            }
            Event::UserEvent(AppEvent::Shake) => {
                // 1) 先置顶到前台：取消最小化、可见、抢焦点、并在任务栏闪一下
                window.set_minimized(false);
                window.set_visible(true);
                let _ = window.set_focus();
                window.request_user_attention(Some(UserAttentionType::Informational));

                // 2) 记下当前位置作为抖动基准（取不到就跳过位移，只置顶）
                let base = window.outer_position().ok().map(|p| p.to_logical(window.scale_factor()));
                *shake_base.borrow_mut() = base;
                if base.is_none() {
                    eprintln!("读取窗口位置失败，抖动跳过，仅置顶");
                }

                // 3) 后台线程只负责按节奏发 tick，真正改位置只在主线程做（跨平台安全，
                //    也避免把平台相关的 Window 跨线程传递）。
                let proxy = window_proxy.clone();
                std::thread::spawn(move || {
                    for step in 0..SHAKE_STEPS {
                        std::thread::sleep(std::time::Duration::from_millis(SHAKE_STEP_MS));
                        if proxy.send_event(AppEvent::ShakeTick { step }).is_err() {
                            break;
                        }
                    }
                });
            }
            Event::UserEvent(AppEvent::ShakeTick { step }) => {
                let base = match *shake_base.borrow() {
                    Some(base) => base,
                    None => return,
                };
                let (dx, dy) = SHAKE_PATTERN[(step as usize) % SHAKE_PATTERN.len()];
                window.set_outer_position(LogicalPosition::new(
                    base.x + dx as f64,
                    base.y + dy as f64,
                ));
            }
            _ => {}
        }
    });
}

/// 删除配置文件（不存在也算成功）。
fn clear_config(path: &Path) {
    match std::fs::remove_file(path) {
        Ok(()) => println!("已清除配置：{}", path.display()),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
            println!("配置文件不存在，无需清除：{}", path.display());
        }
        Err(err) => eprintln!("清除配置失败：{err}"),
    }
}

/// 重新启动自身。新进程读不到 URL，因此会落到配置窗口。
fn relaunch() {
    match std::env::current_exe() {
        Ok(exe) => {
            if let Err(err) = std::process::Command::new(exe).spawn() {
                eprintln!("重启客户端失败：{err}");
            }
        }
        Err(err) => eprintln!("获取可执行文件路径失败：{err}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ipc_message_defaults_are_tolerated() {
        // 重置快捷键发过来的就是这种最小消息
        let reset: IpcMessage = serde_json::from_str("{\"action\":\"reset\"}").unwrap();
        assert_eq!(reset.action, "reset");
        assert!(reset.id.is_empty() && reset.title.is_empty() && reset.body.is_empty());

        let notify: IpcMessage =
            serde_json::from_str("{\"action\":\"notify\",\"id\":\"1\",\"title\":\"t\",\"body\":\"b\"}")
                .unwrap();
        assert_eq!((notify.id.as_str(), notify.title.as_str()), ("1", "t"));
    }
}
