//! 应用图标：解码内置 PNG，产出 tao / iced 的窗口图标，以及系统通知用的图标文件。

use std::path::PathBuf;

use crate::app;

/// 内置的应用图标。
///
/// 由 `assets/logo.svg` 生成：`python3 packaging/icons/build-icons.py`
/// （同时产出 `icon.png` 运行时用、`icon.ico` Windows 用、`icon.icns` macOS 用）。
const APP_ICON_PNG: &[u8] = include_bytes!("../assets/icon.png");

/// 解出 PNG 的 RGBA 像素（tao 和 iced 的窗口图标都要 RGBA）。
fn decode_png(bytes: &[u8]) -> Result<(Vec<u8>, u32, u32), String> {
    // png 0.18 的 Decoder 要求 BufRead + Seek，所以包一层 Cursor
    let decoder = png::Decoder::new(std::io::Cursor::new(bytes));
    let mut reader = decoder
        .read_info()
        .map_err(|err| format!("读取图标失败：{err}"))?;

    let buffer_size = reader
        .output_buffer_size()
        .ok_or_else(|| "图标尺寸超出解码上限".to_string())?;
    let mut buffer = vec![0; buffer_size];

    let info = reader
        .next_frame(&mut buffer)
        .map_err(|err| format!("解码图标失败：{err}"))?;

    if info.bit_depth != png::BitDepth::Eight {
        return Err(format!("图标位深不支持：{:?}", info.bit_depth));
    }

    let rgba = match info.color_type {
        png::ColorType::Rgba => buffer[..info.buffer_size()].to_vec(),
        png::ColorType::Rgb => buffer[..info.buffer_size()]
            .chunks_exact(3)
            .flat_map(|pixel| [pixel[0], pixel[1], pixel[2], 255])
            .collect(),
        other => return Err(format!("图标颜色类型不支持：{other:?}")),
    };

    Ok((rgba, info.width, info.height))
}

/// 主窗口图标（tao）。
pub(crate) fn window_icon() -> Option<tao::window::Icon> {
    match decode_png(APP_ICON_PNG).and_then(|(rgba, width, height)| {
        tao::window::Icon::from_rgba(rgba, width, height).map_err(|err| err.to_string())
    }) {
        Ok(icon) => Some(icon),
        Err(err) => {
            eprintln!("加载窗口图标失败：{err}");
            None
        }
    }
}

/// 配置窗口图标（iced 有自己的 Icon 类型，`from_rgba` 是模块下的自由函数）。
pub(crate) fn config_window_icon() -> Option<iced::window::Icon> {
    match decode_png(APP_ICON_PNG).and_then(|(rgba, width, height)| {
        iced::window::icon::from_rgba(rgba, width, height).map_err(|err| err.to_string())
    }) {
        Ok(icon) => Some(icon),
        Err(err) => {
            eprintln!("加载配置窗口图标失败：{err}");
            None
        }
    }
}

/// 系统通知用的图标文件路径。
///
/// Linux 的通知守护进程要的是主题图标名或文件路径，所以把内置图标落一份到数据目录；
/// 内容长度变了（换了图标重新发版）才重写。
pub(crate) fn notification_icon_path() -> Option<PathBuf> {
    let dir = app::data_dir()?;
    let path = dir.join("icon.png");

    let up_to_date = std::fs::metadata(&path)
        .map(|meta| meta.len() == APP_ICON_PNG.len() as u64)
        .unwrap_or(false);

    if !up_to_date {
        if let Err(err) = std::fs::create_dir_all(&dir) {
            eprintln!("创建数据目录失败：{err}");
            return None;
        }
        if let Err(err) = std::fs::write(&path, APP_ICON_PNG) {
            eprintln!("写入通知图标失败：{err}");
            return None;
        }
    }

    Some(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn embedded_icon_decodes_to_rgba() {
        let (rgba, width, height) = decode_png(APP_ICON_PNG).expect("内置图标应该能解码");

        assert_eq!((width, height), (256, 256));
        assert_eq!(rgba.len(), (width * height) as usize * 4);
        assert!(
            rgba.chunks_exact(4).any(|pixel| pixel[3] > 0),
            "图标不应该整张都是透明的"
        );
    }

    #[test]
    fn window_icons_build_from_embedded_png() {
        assert!(window_icon().is_some(), "tao 窗口图标应该能构造");
        assert!(config_window_icon().is_some(), "iced 窗口图标应该能构造");
    }

    #[test]
    fn garbage_bytes_are_rejected() {
        assert!(decode_png(b"not a png").is_err());
    }
}
