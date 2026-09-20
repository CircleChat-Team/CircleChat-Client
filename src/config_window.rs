//! 配置窗口（iced，纯 Rust 控件，不涉及 HTML）。
//!
//! 用户在输入框里填服务地址，保存前先在 Rust 侧校验站点身份，通过了才关闭窗口。

use std::sync::{Arc, Mutex};

use iced::futures::channel::oneshot;
use iced::widget::{Space, button, column, row, text, text_input};

use crate::icon;
use crate::notice;
use crate::site;

/// 输入框的占位文字。
const URL_PLACEHOLDER: &str = "https://your-circlechat-server";

#[derive(Debug, Clone)]
struct State {
    url: String,
    error: Option<String>,
    /// 正在做站点身份校验（期间禁止重复提交）
    checking: bool,
}

#[derive(Debug, Clone)]
enum Message {
    UrlChanged(String),
    Save,
    /// 校验结束：带上被校验的 URL 和结果
    Checked(String, Result<(), String>),
}

/// 弹出配置窗口，阻塞直到用户保存或关闭。
/// 返回 `Some(url)` 表示用户保存了地址；返回 `None` 表示用户直接关掉了窗口。
pub(crate) fn run(initial_url: Option<String>) -> Option<String> {
    // iced 的 run() 会吃掉 state，结果只能通过共享变量带出来
    let saved: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));
    let sink = Arc::clone(&saved);

    let boot_state = State {
        url: initial_url.unwrap_or_default(),
        error: None,
        checking: false,
    };

    let update = move |state: &mut State, message: Message| -> iced::Task<Message> {
        match message {
            Message::UrlChanged(value) => {
                state.url = value;
                state.error = None;
            }
            Message::Save => {
                if state.checking {
                    return iced::Task::none();
                }

                let url = state.url.trim().to_string();
                if url.is_empty() {
                    state.error = Some("请填写 CircleChat 服务地址".to_string());
                } else if !(url.starts_with("http://") || url.starts_with("https://")) {
                    state.error = Some("地址需要以 http:// 或 https:// 开头".to_string());
                } else {
                    state.error = None;
                    state.checking = true;

                    // 校验是阻塞请求，丢到独立线程做，结果通过 oneshot 回到 iced。
                    let target = url.clone();
                    let checked_url = url.clone();
                    return iced::Task::perform(
                        async move {
                            let (sender, receiver) = oneshot::channel();
                            std::thread::spawn(move || {
                                let _ = sender.send(site::verify_site_cached(&target));
                            });

                            receiver
                                .await
                                .unwrap_or_else(|_| Err("校验线程异常结束".to_string()))
                        },
                        move |result| Message::Checked(checked_url.clone(), result),
                    );
                }
            }
            Message::Checked(url, result) => {
                state.checking = false;

                match result {
                    Ok(()) => {
                        if let Ok(mut guard) = sink.lock() {
                            *guard = Some(url);
                        }
                        // 校验通过，关闭窗口，随后进入 WebView 阶段
                        return iced::exit();
                    }
                    Err(reason) => {
                        eprintln!("站点校验失败（{url}）：{reason}");
                        state.error = Some(format!("无效的站点（{reason}）"));
                    }
                }
            }
        }

        iced::Task::none()
    };

    let window_settings = iced::window::Settings {
        size: (480.0, 360.0).into(),
        position: iced::window::Position::Centered,
        icon: icon::config_window_icon(),
        ..iced::window::Settings::default()
    };

    let application = iced::application(move || boot_state.clone(), update, view)
        .title("CircleChat 配置")
        .window(window_settings);

    if let Err(err) = application.run() {
        eprintln!("配置窗口运行失败：{err}");
        return None;
    }

    saved.lock().ok().and_then(|guard| guard.clone())
}

fn view(state: &State) -> iced::Element<'_, Message> {
    let input = text_input(URL_PLACEHOLDER, &state.url)
        .on_input(Message::UrlChanged)
        .on_submit(Message::Save)
        .padding(10)
        .size(15);

    let save = button(text(if state.checking {
        "正在校验站点…"
    } else {
        "保存并进入"
    }).size(15))
    .on_press_maybe((!state.checking).then_some(Message::Save))
    .padding([10, 20]);

    let mut content = column![
        text("CircleChat 尚未配置").size(20),
        text("请填写服务地址。保存前会校验站点身份，校验通过才会进入应用。").size(13),
        Space::new().height(6),
        input,
        row![Space::new().width(iced::Length::Fill), save],
        Space::new().height(2),
        text(notice::min_web_version_notice()).size(12),
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
