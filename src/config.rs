//! 本地 JSON 配置的读写。

use std::path::Path;

use serde::{Deserialize, Serialize};

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
pub(crate) struct Config {
    /// CircleChat 服务地址。为空表示尚未配置。
    #[serde(default)]
    pub(crate) url: Option<String>,
}

impl Config {
    /// 读取配置；文件不存在、内容损坏时都退化为默认配置（这样用户至少还能进配置窗口）。
    pub(crate) fn load(path: &Path) -> Self {
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

    pub(crate) fn save(&self, path: &Path) -> std::io::Result<()> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let json = serde_json::to_string_pretty(self)?;
        std::fs::write(path, json)
    }

    /// 去掉首尾空白后仍然有效的 URL。
    pub(crate) fn url(&self) -> Option<&str> {
        self.url
            .as_deref()
            .map(str::trim)
            .filter(|url| !url.is_empty())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_path(tag: &str) -> std::path::PathBuf {
        let path = std::env::temp_dir().join(format!("circlechat-config-{}-{tag}.json", std::process::id()));
        let _ = std::fs::remove_file(&path);
        path
    }

    #[test]
    fn save_then_load_round_trips() {
        let path = temp_path("round-trip");

        let mut config = Config::default();
        config.url = Some("https://chat.example.com".to_string());
        config.save(&path).expect("保存应该成功");

        let loaded = Config::load(&path);
        assert_eq!(loaded.url(), Some("https://chat.example.com"));

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn broken_file_falls_back_to_default() {
        let path = temp_path("broken");
        std::fs::write(&path, "{ this is not json").unwrap();

        assert!(Config::load(&path).url().is_none());

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn blank_url_counts_as_not_configured() {
        let mut config = Config::default();
        assert!(config.url().is_none());

        config.url = Some("   ".to_string());
        assert!(config.url().is_none());

        config.url = Some("  https://chat.example.com  ".to_string());
        assert_eq!(config.url(), Some("https://chat.example.com"));
    }
}
