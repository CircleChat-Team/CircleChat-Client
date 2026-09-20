//! 站内 / 站外链接的判定，以及"用系统默认程序打开"。

use url::Url;

/// 站点 origin（`scheme://host[:port]`），用来区分站内 / 站外链接。
pub(crate) fn site_origin(url: &str) -> Option<String> {
    let parsed = Url::parse(url).ok()?;
    matches!(parsed.scheme(), "http" | "https").then(|| parsed.origin().ascii_serialization())
}

/// 是否属于"站外链接"。"站外"一律交给系统浏览器，不在 WebView 里打开。
///
/// 按 origin 比较（含端口），所以 `http` 与 `https`、带不带默认端口都会区分开；
/// 子域也算站外（`chat.example.com` 与 `www.example.com` 互相跳会被交给系统）。
pub(crate) fn is_external_link(target: &str, site: &Option<String>) -> bool {
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
pub(crate) fn open_in_system(target: &str) {
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn same_origin_is_internal() {
        let site = site_origin("https://chat.example.com/app");

        assert_eq!(site.as_deref(), Some("https://chat.example.com"));
        assert!(!is_external_link("https://chat.example.com/room/1", &site));
        // 同源但带默认端口也算站内
        assert!(!is_external_link("https://chat.example.com:443/room/1", &site));
    }

    #[test]
    fn different_origin_is_external() {
        let site = site_origin("https://chat.example.com");

        assert!(is_external_link("https://example.com", &site));
        assert!(is_external_link("http://chat.example.com", &site), "换协议算站外");
        // 子域也算站外
        assert!(is_external_link("https://www.chat.example.com", &site));
    }

    #[test]
    fn webview_internal_schemes_are_allowed() {
        let site = site_origin("https://chat.example.com");

        for target in ["about:blank", "blob:https://chat.example.com/xxx", "data:text/plain,hi"] {
            assert!(!is_external_link(target, &site), "{target} 不该被拦");
        }
    }

    #[test]
    fn other_schemes_go_to_system() {
        let site = site_origin("https://chat.example.com");

        assert!(is_external_link("mailto:hi@example.com", &site));
        assert!(is_external_link("tel:+123456", &site));
    }

    #[test]
    fn no_site_means_allow_all_http() {
        assert!(!is_external_link("https://anywhere.example.com", &None));
    }
}
