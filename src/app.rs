//! 应用身份与标准目录。
//!
//! 这里是"应用是谁"的唯一出处：显示名、`directories` 用的标识、配置/数据目录。
//! 其它模块都从这里取，避免同一个字符串散落在各处。

use std::path::PathBuf;

use directories::{BaseDirs, ProjectDirs};

/// `directories` 用的反向域名标识。
const APP_QUALIFIER: &str = "com";
const APP_ORGANIZATION: &str = "CircleChat";
/// 用于目录名与 ProjectDirs 的应用名（小写、无空格）。
const APP_NAME: &str = "CircleChat";

/// 展示给用户的应用名（窗口标题、系统通知里的应用名）。
pub(crate) const APP_DISPLAY_NAME: &str = "CircleChat";

const CONFIG_FILE_NAME: &str = "config.json";

/// 配置文件路径：优先用 `ProjectDirs`，拿不到时退回 `BaseDirs`，再退回当前目录。
pub(crate) fn config_path() -> PathBuf {
    if let Some(dirs) = ProjectDirs::from(APP_QUALIFIER, APP_ORGANIZATION, APP_NAME) {
        return dirs.config_dir().join(CONFIG_FILE_NAME);
    }
    if let Some(dirs) = BaseDirs::new() {
        return dirs.config_dir().join(APP_NAME).join(CONFIG_FILE_NAME);
    }
    PathBuf::from(CONFIG_FILE_NAME)
}

/// 应用数据目录（WebView 缓存、通知图标等都放这里）。拿不到标准目录时返回 `None`。
pub(crate) fn data_dir() -> Option<PathBuf> {
    ProjectDirs::from(APP_QUALIFIER, APP_ORGANIZATION, APP_NAME)
        .map(|dirs| dirs.data_dir().to_path_buf())
}

/// 数据目录拿不到时的兜底：临时目录。
pub(crate) fn fallback_dir(name: &str) -> PathBuf {
    std::env::temp_dir().join(name)
}
