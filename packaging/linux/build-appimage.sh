#!/usr/bin/env bash
#
# 打一个 AppImage：单文件、双击即运行，自带 WebKitGTK 等依赖。
#
# 用法：
#   packaging/linux/build-appimage.sh <二进制路径> <版本号> [输出目录]
#
# 需要联网下载 linuxdeploy / appimagetool（CI 里做）。
# 用 ARCH 环境变量可以指定架构（默认 x86_64）。

set -euo pipefail

BIN="${1:?缺少参数：二进制路径}"
VERSION="${2:?缺少参数：版本号}"
OUT_DIR="${3:-dist}"

ARCH="${ARCH:-x86_64}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1

ICON="$ROOT/assets/icon.png"
DESKTOP="$ROOT/packaging/linux/circlechat.desktop"
for file in "$BIN" "$ICON" "$DESKTOP"; do
    [[ -f "$file" ]] || { echo "找不到文件：$file" >&2; exit 1; }
done

TOOLS="$(mktemp -d)"
WORK="$(mktemp -d)"
trap 'rm -rf "$TOOLS" "$WORK"' EXIT

download() {
    local url="$1" target="$2"
    echo "下载：$(basename "$target")"
    curl -fsSL "$url" -o "$target"
    chmod +x "$target"
}

download "https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-${ARCH}.AppImage" \
         "$TOOLS/linuxdeploy"
# GTK 插件：把 gdk-pixbuf 加载器、GLib 模块这些一起收进去，否则图标/主题可能显示不出来
download "https://github.com/linuxdeploy/linuxdeploy-plugin-gtk/releases/download/continuous/linuxdeploy-plugin-gtk-${ARCH}.AppImage" \
         "$TOOLS/linuxdeploy-plugin-gtk"
download "https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-${ARCH}.AppImage" \
         "$TOOLS/appimagetool"

mkdir -p "$WORK/AppDir"

# linuxdeploy 用 VERSION 决定 AppImage 的文件名
export VERSION

# linuxdeploy 会自己把二进制依赖的 .so 收进 AppDir
ARCH="$ARCH" "$TOOLS/linuxdeploy" \
    --appdir "$WORK/AppDir" \
    --executable "$BIN" \
    --desktop-file "$DESKTOP" \
    --icon-file "$ICON" \
    --plugin gtk \
    --output appimage 2>&1 | tail -20

mkdir -p "$OUT_DIR"
OUTPUT="$OUT_DIR/CircleChat-${VERSION}-${ARCH}.AppImage"

# 上面那步会在当前目录产出 *.AppImage，统一改名搬到输出目录
mv ./*.AppImage "$OUTPUT"
chmod +x "$OUTPUT"
echo "已生成：$OUTPUT"
