//! 客户端身份标记：告诉页面和服务端"我是客户端，不是浏览器"。
//!
//! 三种机制，互相不冲突：
//!
//! | 机制 | 谁用 | 覆盖范围 |
//! |---|---|---|
//! | User-Agent 里的 `CircleChatDesktop/<版本>` | 服务端 + 前端 | **所有请求**（子资源 / XHR / WebSocket 握手） |
//! | `window.__CIRCLECHAT_CLIENT__` | 前端 JS 判断（最稳） | 所有页面 / 路由，主 frame |
//! | `X-CircleChat-Client` 请求头 | 服务端 | 仅入口文档那一次请求 |

use wry::http::header::{CACHE_CONTROL, PRAGMA};
use wry::http::{HeaderMap, HeaderName, HeaderValue};

use crate::app;

/// 注入到页面里的客户端标记名（挂在 window 上）。
const CLIENT_MARKER: &str = "__CIRCLECHAT_CLIENT__";
/// 客户端标识，前端与（入口请求的）服务端都用这个名字认。
const CLIENT_NAME: &str = "circlechat-desktop";
/// User-Agent 里追加的标记名。
const CLIENT_UA_TOKEN: &str = "CircleChatDesktop";
/// 入口文档请求头里带的客户端标记（小写，HTTP/2 要求）。
const CLIENT_HEADER: &str = "x-circlechat-client";
/// 允许用环境变量整体覆盖 UA，用来在不重新发版的情况下修 UA 相关的问题。
const USER_AGENT_ENV: &str = "CIRCLECHAT_USER_AGENT";

/// 客户端版本（`0.1.0+<构建号>`），构建号是 CI 注入的 git short sha。
pub(crate) fn client_version() -> String {
    app::version()
}

/// 给前端的客户端标记：在页面自身脚本执行之前注入，所有路由 / 刷新都在。
///
/// 契约（前端按这个读，后续只做加法，不改现有字段）：
/// ```js
/// window.__CIRCLECHAT_CLIENT__ === {
///   name:     'circlechat-desktop',  // 固定值
///   version:  '0.1.0',               // 客户端版本，来自 Cargo.toml
///   platform: 'linux'                // 'linux' | 'macos' | 'windows'
/// }
/// ```
/// 只在主 frame 注入（不注入 iframe），并且是冻结对象，前端不要改写。
pub(crate) fn client_marker_script() -> String {
    format!(
        "window.{marker} = Object.freeze({{ name: '{name}', version: '{version}', platform: '{platform}' }});",
        marker = CLIENT_MARKER,
        name = CLIENT_NAME,
        version = client_version(),
        platform = std::env::consts::OS,
    )
}

/// User-Agent。
///
/// wry 的 `with_user_agent` 是**整体替换**（不是追加），而且拿不到各引擎的真实版本号，
/// 所以这里按平台给出"引擎真实 + 我们的标记"的 UA，形态与 Electron / Tauri 应用一致：
///
/// - Linux / macOS 是 WebKit 内核 → 用 Safari 形态
/// - Windows 是 WebView2（Chromium） → 用 Chrome/Edge 形态
///
/// 风险与兜底：`Chrome/<版本>` 是写死的，几年后会显得旧。真要修的时候不用改代码，
/// 设 `CIRCLECHAT_USER_AGENT` 环境变量整体覆盖即可。
pub(crate) fn user_agent() -> String {
    if let Ok(custom) = std::env::var(USER_AGENT_ENV) {
        let custom = custom.trim().to_string();
        if !custom.is_empty() {
            println!("User-Agent 已被 {USER_AGENT_ENV} 覆盖：{custom}");
            return custom;
        }
    }

    let token = format!("{CLIENT_UA_TOKEN}/{}", client_version());

    match std::env::consts::OS {
        "macos" => format!(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 \
             (KHTML, like Gecko) Version/17.0 Safari/605.1.15 {token}"
        ),
        "windows" => format!(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
             (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36 Edg/140.0.0.0 {token}"
        ),
        _ => format!(
            "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/605.1.15 \
             (KHTML, like Gecko) Version/17.0 Safari/605.1.15 {token}"
        ),
    }
}

/// 入口文档的请求头：强制不走缓存（前端更新后立刻生效）+ 客户端标记。
/// 其它资源（图片、字体、媒体、附件等）不加任何干预，按服务端响应头走 WebView 的磁盘缓存。
///
/// 注意：wry 的自定义请求头**只作用于入口文档这一次请求**，页面里的 XHR / fetch /
/// 子资源都不会带。要让后续接口请求也带标记，得由前端自己加。
pub(crate) fn entry_request_headers() -> HeaderMap {
    let mut headers = HeaderMap::new();
    headers.insert(
        CACHE_CONTROL,
        HeaderValue::from_static("no-cache, no-store, must-revalidate"),
    );
    headers.insert(PRAGMA, HeaderValue::from_static("no-cache"));
    headers.insert(
        HeaderName::from_static(CLIENT_HEADER),
        HeaderValue::from_str(&client_version())
            .unwrap_or_else(|_| HeaderValue::from_static("unknown")),
    );
    headers
}

#[cfg(test)]
mod tests {
    use super::*;
    use wry::http::header::CACHE_CONTROL;

    #[test]
    fn marker_script_carries_name_version_platform() {
        let script = client_marker_script();

        assert!(script.contains(CLIENT_MARKER));
        assert!(script.contains(CLIENT_NAME));
        assert!(script.contains(&client_version()));
        assert!(script.contains(std::env::consts::OS));
        assert!(script.contains("Object.freeze"), "标记应该是冻结对象");
    }

    #[test]
    fn user_agent_carries_the_client_token() {
        let ua = user_agent();

        assert!(ua.contains(&format!("{CLIENT_UA_TOKEN}/{}", client_version())));
        assert!(ua.starts_with("Mozilla/5.0"), "UA 要保持浏览器形态");
    }

    #[test]
    fn entry_headers_disable_cache_and_mark_client() {
        let headers = entry_request_headers();

        assert!(headers.get(CACHE_CONTROL).is_some());
        assert_eq!(
            headers.get(CLIENT_HEADER).map(|value| value.to_str().unwrap()),
            Some(client_version().as_str())
        );
    }
}
