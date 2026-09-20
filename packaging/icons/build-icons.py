#!/usr/bin/env python3
"""从 assets/logo.svg 生成三份图标：icon.png（运行时用）、icon.ico（Windows）、icon.icns（macOS）。

依赖：python3 + ffmpeg（需要带 librsvg 解码器）。用法：

    packaging/icons/build-icons.py

关键点：必须先把 SVG 的 width/height 改成目标尺寸，librsvg 才会按目标分辨率光栅化；
直接让 ffmpeg 放大 48×48 的位图会糊。
"""

import re
import shutil
import struct
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ASSETS = ROOT / "assets"
SVG = ASSETS / "logo.svg"

PNG_SIZES = [16, 24, 32, 48, 64, 128, 256, 512, 1024]

# 运行时会用到的尺寸
MAIN_ICON_SIZE = 256
# Windows ico 里塞哪些尺寸
ICO_SIZES = [16, 24, 32, 48, 64, 128, 256]
# macOS icns 的 entry 类型 → 尺寸
ICNS_ENTRIES = [
    ("ic11", 32),
    ("ic12", 64),
    ("ic07", 128),
    ("ic13", 256),
    ("ic08", 256),
    ("ic14", 512),
    ("ic09", 512),
    ("ic10", 1024),
]


def rasterize(workdir: Path) -> dict:
    """用 ffmpeg 把 SVG 按每个尺寸光栅化成 PNG。"""
    if shutil.which("ffmpeg") is None:
        sys.exit("找不到 ffmpeg（需要带 librsvg 解码器）")

    source = SVG.read_text(encoding="utf-8")
    if not re.search(r'width="\d+"\s+height="\d+"', source):
        sys.exit("logo.svg 里没有找到 width/height，无法按目标尺寸光栅化")

    # 只改根 <svg> 标签上的 width/height！里面的 <rect width="44" height="44"> 之类不能动，
    # 否则图形会被撑出 viewBox（re.sub 默认替换所有匹配，必须限定在第一个标签内）
    root_end = source.find(">", source.find("<svg"))
    root_tag, rest = source[:root_end], source[root_end:]

    images = {}
    for size in PNG_SIZES:
        # 改 svg 的 width/height，librsvg 就会按这个尺寸渲染
        scaled_tag = re.sub(
            r'width="\d+"\s+height="\d+"',
            f'width="{size}" height="{size}"',
            root_tag,
            count=1,
        )
        scaled = scaled_tag + rest
        svg_path = workdir / f"logo-{size}.svg"
        png_path = workdir / f"{size}.png"
        svg_path.write_text(scaled, encoding="utf-8")

        subprocess.run(
            ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
             "-i", str(svg_path), "-frames:v", "1", str(png_path)],
            check=True,
        )
        images[size] = png_path.read_bytes()
    return images


def build_ico(images: dict) -> bytes:
    """ICONDIR(6) + ICONDIRENTRY(16 * n) + 图片数据。图片直接用 PNG（Vista+ 支持）。"""
    header = struct.pack("<HHH", 0, 1, len(ICO_SIZES))
    offset = len(header) + 16 * len(ICO_SIZES)

    entries = b""
    for size in ICO_SIZES:
        data = images[size]
        dimension = 0 if size >= 256 else size  # 256 在 entry 里记 0
        entries += struct.pack("<BBBBHHII", dimension, dimension, 0, 0, 1, 32, len(data), offset)
        offset += len(data)

    return header + entries + b"".join(images[size] for size in ICO_SIZES)


def build_icns(images: dict) -> bytes:
    """'icns' + 总长度 + [类型(4) + 长度(4) + PNG 数据] * n。"""
    body = b""
    for type_name, size in ICNS_ENTRIES:
        data = images[size]
        body += type_name.encode("ascii") + struct.pack(">I", len(data) + 8) + data

    return b"icns" + struct.pack(">I", len(body) + 8) + body


def main() -> None:
    workdir = ROOT / "target" / "icons"
    workdir.mkdir(parents=True, exist_ok=True)

    images = rasterize(workdir)

    (ASSETS / "icon.png").write_bytes(images[MAIN_ICON_SIZE])
    (ASSETS / "icon.ico").write_bytes(build_ico(images))
    (ASSETS / "icon.icns").write_bytes(build_icns(images))

    for name in ("icon.png", "icon.ico", "icon.icns"):
        path = ASSETS / name
        print(f"{path.relative_to(ROOT)}: {path.stat().st_size} bytes")


if __name__ == "__main__":
    main()
