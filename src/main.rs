// Release 构建时不要在 Windows 上弹出控制台窗口
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use directories::{BaseDirs, ProjectDirs};
use iced::widget::{Space, button, column, row, text, text_input};
use serde::{Deserialize, Serialize};
use tao::dpi::LogicalSize;
use tao::event::{Event, WindowEvent};
use tao::event_loop::{ControlFlow, EventLoopBuilder};
use tao::window::WindowBuilder;
use wry::WebViewBuilder;

const APP_QUALIFIER: &str = "com";
const APP_ORGANIZATION: &str = "CircleChat";
const APP_NAME: &str = "CircleChat";
const CONFIG_FILE_NAME: &str = "config.json";

const WINDOW_TITLE: &str = "CircleChat";
const WINDOW_WIDTH: f64 = 1100.0;
const WINDOW_HEIGHT: f64 = 720.0;

/// 兜底地址：当配置里没有 URL 时不会用到，仅用于提示文案。
const URL_PLACEHOLDER: &str = "https://your-circlechat-server";

// ---------------------------------------------------------------------------
// 配置
// ---------------------------------------------------------------------------

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
struct Config {
    /// CircleChat 服务地址。为空表示尚未配置。
    #[serde(default)]
    url: Option<String>,
}

impl Config {
    /// 读取配置；文件不存在、内容损坏时都退化为默认配置。
    fn load(path: &Path) -> Self {
        match std::fs::read_to_string(path) {
            Ok(raw) => match serde_json::from_str::<Config>(&raw) {
                Ok(config) => config,
                Err(err) => {
                    eprintln!("配置文件解析失败（将重新配置）：{err}");
                    Config::default()
                }
            },
            Err(err) => {
                if err.kind() != std::io::ErrorKind::NotFound {
                    eprintln!("读取配置文件失败：{err}");
                }
                Config::default()
            }
        }
    }

    fn save(&self, path: &Path) -> std::io::Result<()> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let json = serde_json::to_string_pretty(self)?;
        std::fs::write(path, json)
    }

    /// 去掉首尾空白后仍然有效的 URL。
    fn url(&self) -> Option<&str> {
        self.url
            .as_deref()
            .map(str::trim)
            .filter(|url| !url.is_empty())
    }
}

/// 配置文件路径：优先用 `directories::ProjectDirs`，拿不到时退回 `BaseDirs`。
fn config_path() -> PathBuf {
    if let Some(dirs) = ProjectDirs::from(APP_QUALIFIER, APP_ORGANIZATION, APP_NAME) {
        return dirs.config_dir().join(CONFIG_FILE_NAME);
    }
    if let Some(dirs) = BaseDirs::new() {
        return dirs.config_dir().join(APP_NAME).join(CONFIG_FILE_NAME);
    }
    PathBuf::from(CONFIG_FILE_NAME)
}

// ---------------------------------------------------------------------------
// 配置窗口（iced，纯 Rust 控件，不涉及 HTML）
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
struct ConfigWindow {
    url: String,
    error: Option<String>,
}

#[derive(Debug, Clone)]
enum ConfigMessage {
    UrlChanged(String),
    Save,
}

/// 弹出配置窗口，阻塞直到用户保存或关闭。
/// 返回 `Some(url)` 表示用户保存了地址；返回 `None` 表示用户直接关掉了窗口。
fn run_config_window(initial_url: Option<String>) -> Option<String> {
    let saved: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));
    let sink = Arc::clone(&saved);

    let boot_state = ConfigWindow {
        url: initial_url.unwrap_or_default(),
        error: None,
    };

    let update = move |state: &mut ConfigWindow, message: ConfigMessage| -> iced::Task<ConfigMessage> {
        match message {
            ConfigMessage::UrlChanged(value) => {
                state.url = value;
                state.error = None;
            }
            ConfigMessage::Save => {
                let url = state.url.trim().to_string();
                if url.is_empty() {
                    state.error = Some("请填写 CircleChat 服务地址".to_string());
                } else if !(url.starts_with("http://") || url.starts_with("https://")) {
                    state.error = Some("地址需要以 http:// 或 https:// 开头".to_string());
                } else {
                    if let Ok(mut guard) = sink.lock() {
                        *guard = Some(url);
                    }
                    // 关闭窗口，随后进入 WebView 阶段
                    return iced::exit();
                }
            }
        }

        iced::Task::none()
    };

    let application = iced::application(move || boot_state.clone(), update, view)
        .title("CircleChat 配置")
        .window_size((480.0, 300.0))
        .centered();

    if let Err(err) = application.run() {
        eprintln!("配置窗口运行失败：{err}");
        return None;
    }

    saved.lock().ok().and_then(|guard| guard.clone())
}

fn view(state: &ConfigWindow) -> iced::Element<'_, ConfigMessage> {
    let input = text_input(URL_PLACEHOLDER, &state.url)
        .on_input(ConfigMessage::UrlChanged)
        .on_submit(ConfigMessage::Save)
        .padding(10)
        .size(15);

    let save = button(text("保存并进入").size(15))
        .on_press(ConfigMessage::Save)
        .padding([10, 20]);

    let mut content = column![
        text("CircleChat 尚未配置").size(20),
        text("请填写服务地址，保存后将立即进入应用。").size(13),
        Space::new().height(6),
        input,
        row![Space::new().width(iced::Length::Fill), save],
        Space::new().height(2),
        text("提示：进入应用后按 Ctrl+Shift+R（macOS 为 Cmd+Shift+R）可重置配置。").size(12),
    ]
    .spacing(10)
    .padding(24);

    if let Some(error) = &state.error {
        content = content.push(text(error.clone()).size(13).color(iced::Color::from_rgb(
            0.85, 0.25, 0.25,
        )));
    }

    content.into()
}

// ---------------------------------------------------------------------------
// WebView 主窗口
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
enum AppEvent {
    /// 用户请求重置配置（WebView 内按下快捷键）
    ResetConfig,
}

#[derive(Debug, Deserialize)]
struct IpcMessage {
    action: String,
}

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

fn run_webview(url: String, config_path: PathBuf) -> wry::Result<()> {
    let event_loop = EventLoopBuilder::<AppEvent>::with_user_event().build();
    let proxy = event_loop.create_proxy();

    let window = WindowBuilder::new()
        .with_title(WINDOW_TITLE)
        .with_inner_size(LogicalSize::new(WINDOW_WIDTH, WINDOW_HEIGHT))
        .build(&event_loop)
        .expect("创建主窗口失败");

    let builder = WebViewBuilder::new()
        .with_url(url)
        .with_initialization_script(RESET_SHORTCUT_SCRIPT)
        .with_ipc_handler(move |request| {
            let reset_requested = serde_json::from_str::<IpcMessage>(request.body())
                .map(|message| message.action == "reset")
                .unwrap_or(false);

            if reset_requested {
                let _ = proxy.send_event(AppEvent::ResetConfig);
            }
        });

    #[cfg(any(
        target_os = "windows",
        target_os = "macos",
        target_os = "ios",
        target_os = "android"
    ))]
    let _webview = builder.build(&window)?;

    #[cfg(not(any(
        target_os = "windows",
        target_os = "macos",
        target_os = "ios",
        target_os = "android"
    )))]
    let _webview = {
        use tao::platform::unix::WindowExtUnix;
        use wry::WebViewBuilderExtUnix;
        let vbox = window.default_vbox().expect("获取 GTK 容器失败");
        builder.build_gtk(vbox)?
    };

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

/// 重新启动自身。新进程读不到 URL，因此会直接落到配置窗口。
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

// ---------------------------------------------------------------------------
// 入口
// ---------------------------------------------------------------------------

fn main() {
    let config_path = config_path();
    println!("配置文件：{}", config_path.display());

    let mut config = Config::load(&config_path);

    let url = match config.url() {
        Some(url) => url.to_string(),
        None => match run_config_window(config.url.clone()) {
            Some(url) => {
                config.url = Some(url.clone());
                if let Err(err) = config.save(&config_path) {
                    eprintln!("保存配置失败：{err}");
                }
                url
            }
            None => {
                println!("未配置地址，退出。");
                return;
            }
        },
    };

    if let Err(err) = run_webview(url, config_path) {
        eprintln!("启动 WebView 失败：{err}");
        std::process::exit(1);
    }
}
