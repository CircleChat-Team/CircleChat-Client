// Release 构建时不要在 Windows 上弹出控制台窗口
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use directories::{BaseDirs, ProjectDirs, UserDirs};
use iced::futures::channel::oneshot;
use iced::widget::{Space, button, column, row, text, text_input};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tao::dpi::LogicalSize;
use tao::event::{Event, WindowEvent};
use tao::event_loop::{ControlFlow, EventLoopBuilder};
use tao::window::WindowBuilder;
use url::Url;
use wry::http::header::{CACHE_CONTROL, PRAGMA};
use wry::http::{HeaderMap, HeaderName, HeaderValue};
use wry::{NewWindowResponse, WebContext, WebViewBuilder};

const APP_QUALIFIER: &str = "com";
const APP_ORGANIZATION: &str = "CircleChat";
const APP_NAME: &str = "CircleChat";
const CONFIG_FILE_NAME: &str = "config.json";

const WINDOW_TITLE: &str = "CircleChat";
const WINDOW_WIDTH: f64 = 1100.0;
const WINDOW_HEIGHT: f64 = 720.0;

/// 兜底地址：当配置里没有 URL 时不会用到，仅用于提示文案。
const URL_PLACEHOLDER: &str = "https://your-circlechat-server";

/// 要求的网页端最低版本。
///
/// 注意：这里**只用于向用户提示，客户端不做强制拦截** —— 目前没有可用的版本校验接口，
/// 客户端无法知道网页端当前是哪个版本，也就无法判断新旧（git commit hash 本身没有大小关系）。
/// 将来要真正拦截，需要网页端 / 服务端提供一个可比较的版本（构建号）或一个判定接口。
const MIN_WEB_VERSION: &str = "243fca365628c5777202c281d01d3a0d97754296";

/// 版本要求的提示文案（纯展示，无逻辑）。
fn min_web_version_notice() -> String {
    format!("网页端版本必须大于等于 {MIN_WEB_VERSION} 才能使用，否则无法进入 CircleChat。")
}

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
// 站点身份校验
// ---------------------------------------------------------------------------

/// 站点必须声明的应用 ID。
const EXPECTED_APP_ID: &str = "com.example.myapp";
/// 身份信息的接口路径。
const MANIFEST_PATH: &str = "/api/app-manifest";
/// 时间戳允许的偏差（秒）。
const TIMESTAMP_TOLERANCE_SECS: i64 = 300;
/// 校验请求的超时。
const MANIFEST_TIMEOUT: Duration = Duration::from_secs(8);

#[derive(Debug, Deserialize)]
struct AppManifest {
    app_id: String,
    version: String,
    timestamp: i64,
    signature: String,
}

/// SECRET 只从环境变量 `APP_SECRET` 读，且整个进程只读一次；不写死在代码里。
fn app_secret() -> Option<&'static str> {
    static SECRET: OnceLock<Option<String>> = OnceLock::new();

    SECRET
        .get_or_init(|| {
            std::env::var("APP_SECRET")
                .ok()
                .map(|secret| secret.trim().to_string())
                .filter(|secret| !secret.is_empty())
        })
        .as_deref()
}

/// 会话内的校验结果缓存：同一个 URL 只真正请求一次（成功、失败都缓存）。
fn site_cache() -> &'static Mutex<HashMap<String, Result<(), String>>> {
    static CACHE: OnceLock<Mutex<HashMap<String, Result<(), String>>>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

/// 把配置里的地址归一化成缓存 key（去掉首尾空白和结尾斜杠）。
fn site_key(url: &str) -> String {
    url.trim().trim_end_matches('/').to_string()
}

fn verify_site_cached(base_url: &str) -> Result<(), String> {
    let key = site_key(base_url);

    if let Some(cached) = site_cache()
        .lock()
        .ok()
        .and_then(|cache| cache.get(&key).cloned())
    {
        println!("站点校验命中内存缓存：{key}");
        return cached;
    }

    let result = verify_site(&key);
    if let Ok(mut cache) = site_cache().lock() {
        cache.insert(key, result.clone());
    }
    result
}

/// 校验站点身份：拉取身份信息，再逐项核对。
fn verify_site(base_url: &str) -> Result<(), String> {
    let secret = app_secret().ok_or_else(|| "未设置环境变量 APP_SECRET".to_string())?;

    let manifest = fetch_manifest(&format!("{base_url}{MANIFEST_PATH}"))?;
    println!(
        "站点声明：app_id={} version={} timestamp={}",
        manifest.app_id, manifest.version, manifest.timestamp
    );

    verify_manifest(&manifest, secret, unix_timestamp()?)
}

/// 纯校验逻辑（不碰网络、不读环境变量），方便单测。
fn verify_manifest(manifest: &AppManifest, secret: &str, now: i64) -> Result<(), String> {
    if manifest.app_id != EXPECTED_APP_ID {
        return Err(format!("app_id 不匹配（{}）", manifest.app_id));
    }

    let drift = (now - manifest.timestamp).abs();
    if drift > TIMESTAMP_TOLERANCE_SECS {
        return Err(format!("时间戳偏差 {drift} 秒"));
    }

    let expected = manifest_signature(EXPECTED_APP_ID, &manifest.version, manifest.timestamp, secret);
    if !constant_time_eq(
        expected.as_bytes(),
        normalize_signature(&manifest.signature).as_bytes(),
    ) {
        return Err("签名不匹配".to_string());
    }

    Ok(())
}

fn unix_timestamp() -> Result<i64, String> {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| elapsed.as_secs() as i64)
        .map_err(|err| format!("读取系统时间失败：{err}"))
}

/// `sha256(app_id + version + timestamp + SECRET)`，返回小写 hex。
fn manifest_signature(app_id: &str, version: &str, timestamp: i64, secret: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(format!("{app_id}{version}{timestamp}{secret}").as_bytes());
    hex_lower(&hasher.finalize())
}

fn hex_lower(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        out.push_str(&format!("{byte:02x}"));
    }
    out
}

/// 容错处理：服务端可能带 `sha256=` / `sha256:` 前缀，统一成小写 hex 再比。
fn normalize_signature(signature: &str) -> String {
    let trimmed = signature.trim().to_ascii_lowercase();

    trimmed
        .strip_prefix("sha256=")
        .or_else(|| trimmed.strip_prefix("sha256:"))
        .unwrap_or(&trimmed)
        .to_string()
}

/// 定长比较，避免签名比对时提前返回。
fn constant_time_eq(left: &[u8], right: &[u8]) -> bool {
    if left.len() != right.len() {
        return false;
    }

    left.iter()
        .zip(right.iter())
        .fold(0u8, |acc, (a, b)| acc | (a ^ b))
        == 0
}

fn fetch_manifest(url: &str) -> Result<AppManifest, String> {
    let mut response = ureq::get(url)
        .config()
        .timeout_global(Some(MANIFEST_TIMEOUT))
        .build()
        .call()
        .map_err(|err| format!("请求 {url} 失败：{err}"))?;

    let status = response.status();
    if !status.is_success() {
        return Err(format!("{url} 返回 {status}"));
    }

    let body = response
        .body_mut()
        .read_to_string()
        .map_err(|err| format!("读取响应内容失败：{err}"))?;

    serde_json::from_str::<AppManifest>(&body).map_err(|err| format!("响应解析失败：{err}"))
}

// ---------------------------------------------------------------------------
// 配置窗口（iced，纯 Rust 控件，不涉及 HTML）
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
struct ConfigWindow {
    url: String,
    error: Option<String>,
    /// 正在做站点身份校验（期间禁止重复提交）
    checking: bool,
}

#[derive(Debug, Clone)]
enum ConfigMessage {
    UrlChanged(String),
    Save,
    /// 校验结束：带上被校验的 URL 和结果
    Checked(String, Result<(), String>),
}

/// 弹出配置窗口，阻塞直到用户保存或关闭。
/// 返回 `Some(url)` 表示用户保存了地址；返回 `None` 表示用户直接关掉了窗口。
fn run_config_window(initial_url: Option<String>) -> Option<String> {
    let saved: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));
    let sink = Arc::clone(&saved);

    let boot_state = ConfigWindow {
        url: initial_url.unwrap_or_default(),
        error: None,
        checking: false,
    };

    let update = move |state: &mut ConfigWindow, message: ConfigMessage| -> iced::Task<ConfigMessage> {
        match message {
            ConfigMessage::UrlChanged(value) => {
                state.url = value;
                state.error = None;
            }
            ConfigMessage::Save => {
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
                                let _ = sender.send(verify_site_cached(&target));
                            });

                            receiver
                                .await
                                .unwrap_or_else(|_| Err("校验线程异常结束".to_string()))
                        },
                        move |result| ConfigMessage::Checked(checked_url.clone(), result),
                    );
                }
            }
            ConfigMessage::Checked(url, result) => {
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

    let application = iced::application(move || boot_state.clone(), update, view)
        .title("CircleChat 配置")
        .window_size((480.0, 360.0))
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

    let save = button(text(if state.checking {
        "正在校验站点…"
    } else {
        "保存并进入"
    }).size(15))
    .on_press_maybe((!state.checking).then_some(ConfigMessage::Save))
    .padding([10, 20]);

    let mut content = column![
        text("CircleChat 尚未配置").size(20),
        text("请填写服务地址。保存前会校验站点身份，校验通过才会进入应用。").size(13),
        Space::new().height(6),
        input,
        row![Space::new().width(iced::Length::Fill), save],
        Space::new().height(2),
        text(min_web_version_notice()).size(12),
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
    /// 站内链接需要在当前 WebView 内打开（window.open / target=_blank）
    Navigate(String),
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

/// 注入到页面里的客户端标记名（挂在 window 上）。前端用 `window.__CIRCLECHAT_CLIENT__` 判断。
const CLIENT_MARKER: &str = "__CIRCLECHAT_CLIENT__";
/// 客户端标识，前端与（入口请求的）服务端都用这个名字认。
const CLIENT_NAME: &str = "circlechat-desktop";
/// User-Agent 里追加的标记名，服务端在所有请求（含 XHR / WebSocket 握手）上都能看到。
const CLIENT_UA_TOKEN: &str = "CircleChatDesktop";
/// 允许用环境变量整体覆盖 UA，用来在不重新发版的情况下修 UA 相关的问题。
const USER_AGENT_ENV: &str = "CIRCLECHAT_USER_AGENT";
/// 入口文档请求头里带的客户端标记（小写，HTTP/2 要求）。
const CLIENT_HEADER: &str = "x-circlechat-client";

fn client_version() -> &'static str {
    env!("CARGO_PKG_VERSION")
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
fn client_marker_script() -> String {
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
/// wry 的 `with_user_agent` 是**整体替换**（不是追加），而且不知道各引擎的真实版本号，
/// 所以这里按平台给出“引擎真实 + 我们的标记”的 UA，形态与 Electron / Tauri 应用一致：
///
/// - Linux / macOS 是 WebKit 内核 → 用 Safari 形态，带 `CircleChatDesktop/<版本>`
/// - Windows 是 WebView2（Chromium） → 用 Chrome/Edge 形态，带 `CircleChatDesktop/<版本>`
///
/// 风险与兜底：`Chrome/<版本>` 是写死的，几年后会显得旧。真要修的时候不用改代码，
/// 设 `CIRCLECHAT_USER_AGENT` 环境变量整体覆盖即可。
fn user_agent() -> String {
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

/// WebView 的持久化数据目录：HTTP 磁盘缓存、Cookie、localStorage 都落在这里。
/// wry 默认用的是临时上下文（WebContext::new_ephemeral），什么都不会留下，必须自己给一个目录。
fn webview_data_dir() -> PathBuf {
    if let Some(dirs) = ProjectDirs::from(APP_QUALIFIER, APP_ORGANIZATION, APP_NAME) {
        return dirs.data_dir().join("webview");
    }
    std::env::temp_dir().join("circlechat-webview")
}

/// 入口文档的请求头：强制不走缓存，保证前端更新后立刻生效；并带上客户端标记。
/// 其它资源（图片、字体、媒体、附件等）不加任何干预，按服务端响应头走 WebView 的磁盘缓存。
///
/// 注意：wry 的自定义请求头**只作用于入口文档这一次请求**，页面里的 XHR / fetch /
/// 子资源都不会带。要让后续接口请求也带标记，得由前端自己加（见 CLIENT_HEADER）。
fn entry_request_headers() -> HeaderMap {
    let mut headers = HeaderMap::new();
    headers.insert(
        CACHE_CONTROL,
        HeaderValue::from_static("no-cache, no-store, must-revalidate"),
    );
    headers.insert(PRAGMA, HeaderValue::from_static("no-cache"));
    headers.insert(
        HeaderName::from_static(CLIENT_HEADER),
        HeaderValue::from_static(client_version()),
    );
    headers
}

/// 站点 origin（`scheme://host[:port]`），用来区分站内 / 站外链接。
fn site_origin(url: &str) -> Option<String> {
    let parsed = Url::parse(url).ok()?;
    matches!(parsed.scheme(), "http" | "https").then(|| parsed.origin().ascii_serialization())
}

/// 是否属于“站外链接”。“站外”一律交给系统浏览器，不在 WebView 里打开。
fn is_external_link(target: &str, site: &Option<String>) -> bool {
    let Ok(parsed) = Url::parse(target) else {
        // 解析不了（相对地址等）就放行，让 WebView 自己处理
        return false;
    };

    match parsed.scheme() {
        "http" | "https" => match site {
            Some(origin) => parsed.origin().ascii_serialization() != *origin,
            None => false,
        },
        // WebView 内部使用的地址，不能拦
        "about" | "blob" | "data" | "javascript" => false,
        // mailto: / tel: / 自定义协议 → 也交给系统
        _ => true,
    }
}

/// 调用系统默认程序（浏览器 / 邮件客户端等）。放到独立线程里，避免阻塞 UI。
fn open_in_system(target: &str) {
    let target = target.to_string();
    println!("站外链接，交给系统处理：{target}");

    std::thread::spawn(move || {
        let result = if target.starts_with("http://") || target.starts_with("https://") {
            opener::open_browser(&target)
        } else {
            opener::open(&target)
        };

        if let Err(err) = result {
            eprintln!("调用系统程序打开 {target} 失败：{err}");
        }
    });
}

/// 下载目录：优先系统标准下载目录，退化到应用数据目录，再退化到临时目录。
fn download_dir() -> PathBuf {
    if let Some(dir) = UserDirs::new().and_then(|dirs| dirs.download_dir().map(Path::to_path_buf)) {
        return dir;
    }
    if let Some(dirs) = ProjectDirs::from(APP_QUALIFIER, APP_ORGANIZATION, APP_NAME) {
        return dirs.data_dir().join("Downloads");
    }
    std::env::temp_dir()
}

/// 去掉 WebKit 建议文件名里已有的 ` (1)` 这类后缀，避免出现 `file (1) (1).pdf`。
fn strip_indexing(stem: &str) -> &str {
    if stem.ends_with(')') {
        if let Some(open) = stem.rfind(" (") {
            let inner = &stem[open + 2..stem.len() - 1];
            if !inner.is_empty() && inner.chars().all(|c| c.is_ascii_digit()) {
                return &stem[..open];
            }
        }
    }
    stem
}

fn sanitize_file_name(file_name: &str) -> String {
    let cleaned: String = file_name
        .chars()
        .map(|c| {
            if matches!(c, '<' | '>' | ':' | '"' | '/' | '\\' | '|' | '?' | '*' | '\0') {
                '_'
            } else {
                c
            }
        })
        .collect();

    let cleaned = cleaned.trim().trim_matches('.');
    if cleaned.is_empty() {
        "download".to_string()
    } else {
        cleaned.to_string()
    }
}

/// 生成不会覆盖已有文件的下载路径（重名时追加 ` (1)`、` (2)`…）。
fn unique_download_path(file_name: &str) -> PathBuf {
    let dir = download_dir();
    let _ = std::fs::create_dir_all(&dir);

    let sanitized = sanitize_file_name(file_name);
    let path = Path::new(&sanitized);

    let stem = path
        .file_stem()
        .and_then(|stem| stem.to_str())
        .map(strip_indexing)
        .unwrap_or("download");
    let extension = path
        .extension()
        .and_then(|ext| ext.to_str())
        .map(|ext| format!(".{ext}"))
        .unwrap_or_default();

    let mut candidate = dir.join(&sanitized);
    let mut index = 1;
    while candidate.exists() {
        candidate = dir.join(format!("{stem} ({index}){extension}"));
        index += 1;
    }
    candidate
}

/// 从 URL 的 path 里退一个文件名出来（WebView 没给建议名时用）。
fn file_name_from_url(url: &str) -> Option<String> {
    let parsed = Url::parse(url).ok()?;
    let name = parsed.path_segments()?.next_back().unwrap_or_default();

    if name.is_empty() {
        None
    } else {
        Some(name.to_string())
    }
}

/// WebView 要加载的内容来源。
enum WebViewSource {
    /// 正常情况：加载已校验过的站点地址
    Url(String),
    /// 没有可用地址（首次启动且用户没在配置窗口里保存）：显示内置提示页
    MissingConfig,
}

/// 客户端自己渲染的说明页模板。内联 HTML，不依赖网络，也不依赖任何前端资源，
/// 所以网页端挂了、版本不对、没配置地址时都能显示。
/// `{{TITLE}}` / `{{BODY}}` 是占位符（不用 format! 是为了避免转义 CSS 里的花括号）。
const NOTICE_PAGE_TEMPLATE: &str = r#"<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>CircleChat</title>
<style>
  :root { color-scheme: light dark; }
  body {
    margin: 0; height: 100vh; display: flex; align-items: center; justify-content: center;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "Noto Sans SC", "PingFang SC", "Microsoft YaHei", sans-serif;
    background: #f5f6f8; color: #1f2329;
  }
  main { max-width: 520px; padding: 40px; text-align: center; }
  h1 { font-size: 22px; margin: 0 0 14px; font-weight: 600; }
  p { margin: 0 0 10px; line-height: 1.75; font-size: 14px; color: #5b6169; }
  code {
    font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12.5px;
    padding: 2px 6px; border-radius: 5px; border: 1px solid #d0d3d9; background: #fff; color: #1f2329;
    word-break: break-all;
  }
  kbd {
    font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px;
    padding: 2px 6px; border-radius: 5px; border: 1px solid #d0d3d9; background: #fff; color: #1f2329;
  }
  @media (prefers-color-scheme: dark) {
    body { background: #17181a; color: #e8eaed; }
    p { color: #9aa0a6; }
    code, kbd { background: #24262a; border-color: #3c4043; color: #e8eaed; }
  }
</style>
</head>
<body>
<main>
  <h1>{{TITLE}}</h1>
  {{BODY}}
</main>
</body>
</html>
"#;

/// “尚未配置服务地址”说明页。
fn missing_config_notice_page() -> String {
    notice_page(
        "尚未配置服务地址",
        &format!(
            "<p>客户端还没有连接到任何 CircleChat 站点。</p>\
             <p>按 <kbd>Ctrl</kbd> + <kbd>Shift</kbd> + <kbd>R</kbd>\
             （macOS 为 <kbd>Cmd</kbd> + <kbd>Shift</kbd> + <kbd>R</kbd>）打开配置窗口。</p>\
             <p>网页端版本必须大于等于 <code>{version}</code> 才能使用，否则无法进入 CircleChat。</p>",
            version = escape_html(MIN_WEB_VERSION),
        ),
    )
}

/// 生成说明页。`body` 是**可信 HTML**，动态内容请先用 [`escape_html`] 转义。
fn notice_page(title: &str, body: &str) -> String {
    NOTICE_PAGE_TEMPLATE
        .replace("{{TITLE}}", &escape_html(title))
        .replace("{{BODY}}", body)
}

/// 说明页里插入动态内容（版本号之类）前一律转义。
fn escape_html(input: &str) -> String {
    let mut out = String::with_capacity(input.len());

    for ch in input.chars() {
        match ch {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            _ => out.push(ch),
        }
    }

    out
}

fn run_webview(source: WebViewSource, config_path: PathBuf) -> wry::Result<()> {
    let site = match &source {
        WebViewSource::Url(url) => site_origin(url),
        WebViewSource::MissingConfig => None,
    };

    let event_loop = EventLoopBuilder::<AppEvent>::with_user_event().build();
    let ipc_proxy = event_loop.create_proxy();
    let window_proxy = event_loop.create_proxy();

    let window = WindowBuilder::new()
        .with_title(WINDOW_TITLE)
        .with_inner_size(LogicalSize::new(WINDOW_WIDTH, WINDOW_HEIGHT))
        .build(&event_loop)
        .expect("创建主窗口失败");

    let navigation_site = site.clone();
    let new_window_site = site;

    // 持久化上下文：图片 / 字体 / 媒体 / 附件这些会被真正缓存到磁盘，重启后仍在。
    let data_dir = webview_data_dir();
    if let Err(err) = std::fs::create_dir_all(&data_dir) {
        eprintln!("创建 WebView 数据目录失败（{data_dir:?}）：{err}");
    }
    println!("WebView 缓存目录：{}", data_dir.display());
    let mut web_context = WebContext::new(Some(data_dir));

    let user_agent = user_agent();
    println!("User-Agent：{user_agent}");

    let builder = WebViewBuilder::new_with_web_context(&mut web_context)
        // 告诉页面“我是客户端，不是浏览器”：UA 覆盖所有请求，注入的全局变量给页面 JS 用
        .with_user_agent(user_agent)
        .with_initialization_script(client_marker_script())
        .with_initialization_script(RESET_SHORTCUT_SCRIPT)
        .with_ipc_handler(move |request| {
            let reset_requested = serde_json::from_str::<IpcMessage>(request.body())
                .map(|message| message.action == "reset")
                .unwrap_or(false);

            if reset_requested {
                let _ = ipc_proxy.send_event(AppEvent::ResetConfig);
            }
        })
        // 站外链接：拦下来交给系统浏览器
        .with_navigation_handler(move |target| {
            if is_external_link(&target, &navigation_site) {
                open_in_system(&target);
                false
            } else {
                true
            }
        })
        // window.open / target="_blank"：站外的走系统浏览器，站内的在当前 WebView 打开
        .with_new_window_req_handler(move |target, _features| {
            if is_external_link(&target, &new_window_site) {
                open_in_system(&target);
            } else {
                let _ = window_proxy.send_event(AppEvent::Navigate(target));
            }
            NewWindowResponse::Deny
        })
        // 下载：落到系统下载目录，重名自动加序号
        .with_download_started_handler(|url, destination| {
            let file_name = destination
                .file_name()
                .and_then(|name| name.to_str())
                .map(str::to_string)
                .or_else(|| file_name_from_url(&url))
                .unwrap_or_else(|| "download".to_string());

            let target = unique_download_path(&file_name);
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
        WebViewSource::Url(url) => builder.with_url_and_headers(url, entry_request_headers()),
        WebViewSource::MissingConfig => {
            println!("未配置服务地址，显示提示页");
            builder.with_html(missing_config_notice_page())
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

    let source = match config.url() {
        Some(url) => WebViewSource::Url(url.to_string()),
        None => match run_config_window(config.url.clone()) {
            Some(url) => {
                config.url = Some(url.clone());
                if let Err(err) = config.save(&config_path) {
                    eprintln!("保存配置失败：{err}");
                }
                WebViewSource::Url(url)
            }
            // 用户没在配置窗口里保存：不再直接退出，进 WebView 显示内置提示页，
            // 用户仍可按 Ctrl+Shift+R 重新打开配置窗口。
            None => WebViewSource::MissingConfig,
        },
    };

    if let Err(err) = run_webview(source, config_path) {
        eprintln!("启动 WebView 失败：{err}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SECRET: &str = "s3cr3t";

    fn manifest(version: &str, timestamp: i64, signature: String) -> AppManifest {
        AppManifest {
            app_id: EXPECTED_APP_ID.to_string(),
            version: version.to_string(),
            timestamp,
            signature,
        }
    }

    fn signature(version: &str, timestamp: i64, secret: &str) -> String {
        manifest_signature(EXPECTED_APP_ID, version, timestamp, secret)
    }

    #[test]
    fn signature_vector_matches_coreutils() {
        assert_eq!(
            signature("1.0.0", 1700000000, SECRET),
            "db404ccf3c5e8457a6a1a6f0f7288722692fd66955f65312d249fe2677541429"
        );
    }

    #[test]
    fn valid_manifest_passes() {
        let item = manifest("1.0.0", 1700000000, signature("1.0.0", 1700000000, SECRET));
        assert!(verify_manifest(&item, SECRET, 1700000100).is_ok());
        // 边界：正好 300 秒也算通过
        assert!(verify_manifest(&item, SECRET, 1700000300).is_ok());
    }

    #[test]
    fn wrong_app_id_is_rejected() {
        let mut item = manifest("1.0.0", 1700000000, signature("1.0.0", 1700000000, SECRET));
        item.app_id = "com.evil.app".to_string();
        assert!(verify_manifest(&item, SECRET, 1700000000).is_err());
    }

    #[test]
    fn stale_timestamp_is_rejected() {
        let item = manifest("1.0.0", 1700000000, signature("1.0.0", 1700000000, SECRET));
        assert!(verify_manifest(&item, SECRET, 1700000301).is_err());
    }

    #[test]
    fn wrong_secret_is_rejected() {
        let item = manifest("1.0.0", 1700000000, signature("1.0.0", 1700000000, "wrong"));
        assert!(verify_manifest(&item, SECRET, 1700000000).is_err());
    }

    #[test]
    fn notice_page_fills_placeholders_and_keeps_version_requirement() {
        let page = missing_config_notice_page();

        assert!(page.contains("尚未配置服务地址"));
        assert!(page.contains(MIN_WEB_VERSION), "说明页里应该带上版本要求");
        assert!(!page.contains("{{"), "占位符应该都被替换掉");
    }

    #[test]
    fn escape_html_escapes_dangerous_chars() {
        assert_eq!(
            escape_html("<script>&\"'"),
            "&lt;script&gt;&amp;&quot;&#39;"
        );
    }

    #[test]
    fn sha256_prefix_is_tolerated() {
        let item = manifest(
            "1.0.0",
            1700000000,
            format!("sha256:{}", signature("1.0.0", 1700000000, SECRET)),
        );
        assert!(verify_manifest(&item, SECRET, 1700000000).is_ok());
    }
}
