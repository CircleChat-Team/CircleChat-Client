// Release 构建时不要在 Windows 上弹出控制台窗口
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod app;
mod config;
mod config_window;
mod download;
mod icon;
mod identity;
mod links;
mod notice;
mod notification;
mod site;
mod webview;

use config::Config;
use webview::WebViewSource;

fn main() {
    let config_path = app::config_path();
    println!("配置文件：{}", config_path.display());

    let mut config = Config::load(&config_path);

    let source = match config.url() {
        Some(url) => WebViewSource::Url(url.to_string()),
        None => match config_window::run(config.url.clone()) {
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

    if let Err(err) = webview::run(source, config_path) {
        eprintln!("启动 WebView 失败：{err}");
        std::process::exit(1);
    }
}
