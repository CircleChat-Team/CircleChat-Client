//! 构建脚本：
//! 1. 把构建号（一般是 git short sha）编进二进制，UA、客户端标记、安装包版本都用它
//! 2. 给 Windows 的 exe 嵌入图标和版本信息
//!
//! 注意：build script 是在**宿主机**上跑的，所以 `cfg(windows)` 判断的是宿主机。
//! 从 Linux 交叉编译到 Windows 时不会嵌图标，也就不会因为缺少资源编译器而构建失败。

const ICON_PATH: &str = "assets/icon.ico";
/// CI 里注入构建号用的环境变量。
const BUILD_ENV: &str = "CIRCLECHAT_BUILD";

fn main() {
    println!("cargo:rerun-if-changed={ICON_PATH}");
    println!("cargo:rerun-if-env-changed={BUILD_ENV}");

    println!("cargo:rustc-env={BUILD_ENV}={}", build_id());

    #[cfg(windows)]
    {
        use std::path::Path;

        if !Path::new(ICON_PATH).exists() {
            println!("cargo:warning=找不到 {ICON_PATH}，跳过 exe 图标");
            return;
        }

        let mut resource = tauri_winres::WindowsResource::new();
        resource.set_icon(ICON_PATH);
        resource.set("ProductName", "CircleChat");
        resource.set("FileDescription", "CircleChat 桌面客户端");
        resource.set("ProductVersion", env!("CARGO_PKG_VERSION"));
        resource.set("FileVersion", env!("CARGO_PKG_VERSION"));

        // 资源编译失败不该拦住整个构建，打个警告让用户自己决定
        if let Err(err) = resource.compile() {
            println!("cargo:warning=嵌入 Windows 图标失败（已忽略）：{err}");
        }
    }
}

/// 构建号：CI 通过环境变量注入；本地没设就自己去问 git；都没有就用 "dev"。
fn build_id() -> String {
    if let Ok(id) = std::env::var(BUILD_ENV) {
        let id = id.trim().to_string();
        if !id.is_empty() {
            return id;
        }
    }

    std::process::Command::new("git")
        .args(["rev-parse", "--short", "HEAD"])
        .output()
        .ok()
        .map(|output| String::from_utf8_lossy(&output.stdout).trim().to_string())
        .filter(|sha| !sha.is_empty())
        .unwrap_or_else(|| "dev".to_string())
}
