//! 构建脚本：给 Windows 的 exe 嵌入图标和版本信息。
//!
//! 其它平台什么都不做 —— 这个脚本是在**宿主机**上跑的，所以用 `cfg(windows)` 判断宿主机。
//! 从 Linux 交叉编译到 Windows 时不会嵌图标，也就不会因为缺少资源编译器而构建失败。

const ICON_PATH: &str = "assets/icon.ico";

fn main() {
    println!("cargo:rerun-if-changed={ICON_PATH}");

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
