//! 下载落盘：决定文件存哪、重名怎么办。

use std::path::{Path, PathBuf};

use directories::UserDirs;
use url::Url;

use crate::app;

/// 下载目录：优先系统标准下载目录，退化到应用数据目录，再退化到临时目录。
pub(crate) fn download_dir() -> PathBuf {
    if let Some(dir) = UserDirs::new().and_then(|dirs| dirs.download_dir().map(Path::to_path_buf)) {
        return dir;
    }
    if let Some(dir) = app::data_dir() {
        return dir.join("Downloads");
    }
    app::fallback_dir("circlechat-downloads")
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

/// 清掉文件名里非法的字符（跨平台取并集，Windows 最严）。
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

/// 在 `dir` 下生成一个不会覆盖已有文件的路径（重名时追加 ` (1)`、` (2)`…）。
pub(crate) fn unique_path(dir: &Path, file_name: &str) -> PathBuf {
    let _ = std::fs::create_dir_all(dir);

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
pub(crate) fn file_name_from_url(url: &str) -> Option<String> {
    let parsed = Url::parse(url).ok()?;
    let name = parsed.path_segments()?.next_back().unwrap_or_default();

    if name.is_empty() {
        None
    } else {
        Some(name.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("circlechat-download-{}-{tag}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn sanitize_replaces_illegal_chars() {
        assert_eq!(sanitize_file_name("a/b:c*d?.pdf"), "a_b_c_d_.pdf");
        assert_eq!(sanitize_file_name("  ..hidden..  "), "hidden");
        assert_eq!(sanitize_file_name("   "), "download");
    }

    #[test]
    fn strip_indexing_removes_only_webkit_suffix() {
        assert_eq!(strip_indexing("report (1)"), "report");
        assert_eq!(strip_indexing("report (12)"), "report");
        assert_eq!(strip_indexing("report (final)"), "report (final)");
        assert_eq!(strip_indexing("report"), "report");
    }

    #[test]
    fn unique_path_avoids_overwriting() {
        let dir = temp_dir("unique");

        let first = unique_path(&dir, "report.pdf");
        assert_eq!(first.file_name().unwrap(), "report.pdf");

        std::fs::write(&first, b"x").unwrap();
        let second = unique_path(&dir, "report.pdf");
        assert_eq!(second.file_name().unwrap(), "report (1).pdf");

        // WebKit 已经加过序号的建议名不会被叠成 "report (1) (1).pdf"
        std::fs::write(&second, b"x").unwrap();
        let third = unique_path(&dir, "report (1).pdf");
        assert_eq!(third.file_name().unwrap(), "report (2).pdf");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn file_name_from_url_reads_last_path_segment() {
        assert_eq!(
            file_name_from_url("https://example.com/files/report.pdf?token=1").as_deref(),
            Some("report.pdf")
        );
        assert_eq!(file_name_from_url("https://example.com/"), None);
    }
}
