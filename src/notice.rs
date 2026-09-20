//! 客户端自己渲染的说明页。
//!
//! 全部是内联 HTML，不依赖网络、也不依赖任何前端资源，所以网页端挂了、没配置地址时都能显示。

/// 要求的网页端最低版本。
///
/// 注意：这里**只用于向用户提示，客户端不做强制拦截** —— 目前没有可用的版本校验接口，
/// 客户端无法知道网页端当前是哪个版本，也就无法判断新旧（git commit hash 本身没有大小关系）。
/// 将来要真正拦截，需要网页端 / 服务端提供一个可比较的版本（构建号）或一个判定接口。
pub(crate) const MIN_WEB_VERSION: &str = "243fca365628c5777202c281d01d3a0d97754296";

/// 版本要求的提示文案（纯展示，无逻辑）。
pub(crate) fn min_web_version_notice() -> String {
    format!("网页端版本必须大于等于 {MIN_WEB_VERSION} 才能使用，否则无法进入 CircleChat。")
}

/// 说明页模板。`{{TITLE}}` / `{{BODY}}` 是占位符
/// （不用 `format!` 是为了避免把 CSS 里的花括号都写成 `{{`）。
const TEMPLATE: &str = r#"<!doctype html>
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

/// 生成说明页。`body` 是**可信 HTML**，动态内容请先用 [`escape_html`] 转义。
pub(crate) fn notice_page(title: &str, body: &str) -> String {
    TEMPLATE
        .replace("{{TITLE}}", &escape_html(title))
        .replace("{{BODY}}", body)
}

/// "尚未配置服务地址"说明页（WebView 阶段没有可用地址时显示）。
pub(crate) fn missing_config_notice_page() -> String {
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

/// 往说明页里插入动态内容（版本号之类）前一律转义。
pub(crate) fn escape_html(input: &str) -> String {
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn notice_page_fills_placeholders_and_keeps_version_requirement() {
        let page = missing_config_notice_page();

        assert!(page.contains("尚未配置服务地址"));
        assert!(page.contains(MIN_WEB_VERSION), "说明页里应该带上版本要求");
        assert!(!page.contains("{{"), "占位符应该都被替换掉");
    }

    #[test]
    fn notice_page_escapes_dynamic_values() {
        let page = notice_page("标题", &format!("<p>{}</p>", escape_html("<script>")));

        assert!(page.contains("&lt;script&gt;"));
        assert!(!page.contains("<script>"));
    }

    #[test]
    fn escape_html_escapes_dangerous_chars() {
        assert_eq!(
            escape_html("<script>&\"'"),
            "&lt;script&gt;&amp;&quot;&#39;"
        );
    }
}
