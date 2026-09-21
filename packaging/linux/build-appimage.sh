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
    local try=0 max=5
    while [[ $try -lt $max ]]; do
        echo "下载：$(basename "$target")（第 $((try + 1))/$max 次）"
        if curl -fsSL "$url" -o "$target"; then
            chmod +x "$target"
            return 0
        fi
        try=$((try + 1))
        sleep 3
    done
    echo "错误：下载失败 $url" >&2
    exit 1
}

# 非致命下载：失败只返回 1，不退出（用于“能降级就降级”的插件）
try_download() {
    local url="$1" target="$2"
    local try=0 max=5
    while [[ $try -lt $max ]]; do
        echo "下载：$(basename "$target")（第 $((try + 1))/$max 次）"
        if curl -fsSL "$url" -o "$target"; then
            chmod +x "$target"
            return 0
        fi
        try=$((try + 1))
        sleep 3
    done
    return 1
}

download "https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-${ARCH}.AppImage" \
         "$TOOLS/linuxdeploy"
# AppImageKit 的 continuous 发布已下架（404），改用 AppImage/appimagetool 的 latest 稳定版。
# latest/download 会自动 302 到最新 release 资产，名字同样是 appimagetool-${ARCH}.AppImage。
download "https://github.com/AppImage/appimagetool/releases/latest/download/appimagetool-${ARCH}.AppImage" \
         "$TOOLS/appimagetool"

# GTK 插件：把 gdk-pixbuf 加载器、GLib 模块收进去，否则图标/主题可能显示不出来。
# 上游（linuxdeploy/linuxdeploy-plugin-gtk 的 continuous 发布）已下架，下载不到就降级跳过，
# AppImage 依旧能生成，只是图标/主题可能不完美——避免上游变动把整个 CI 打挂。
PLUGIN_ARGS=()
if try_download "https://github.com/linuxdeploy/linuxdeploy-plugin-gtk/releases/download/continuous/linuxdeploy-plugin-gtk-${ARCH}.AppImage" \
         "$TOOLS/linuxdeploy-plugin-gtk"; then
    PLUGIN_ARGS=(--plugin gtk)
else
    echo "警告：linuxdeploy-plugin-gtk 下载失败（上游已下架），跳过 --plugin gtk；AppImage 仍可生成，但图标/主题可能不完美。" >&2
fi

# linuxdeploy 的 --output appimage 会自己调用 appimagetool，而 --plugin gtk 也要能在 PATH 里
# 找到 linuxdeploy-plugin-gtk；把它们所在的目录加进 PATH，否则 linuxdeploy 生成步骤会静默失败、
# 不产出 .AppImage，导致后面 `mv ./*.AppImage` 直接报错。
export PATH="$TOOLS:$PATH"

mkdir -p "$WORK/AppDir"

# linuxdeploy 用 VERSION 决定 AppImage 的文件名
export VERSION

# linuxdeploy 按 --icon-file 的文件名把图标部署进 AppDir；桌面文件 Icon=circlechat 需要
# 同名图标（circlechat.png），否则报 "Could not find suitable icon" 且不产出 .AppImage。
# 这里复制一份按 Icon 名命名的图标传入（不依赖已下架的 GTK 插件来做图标主题化）。
ICON_ENTRY="$(grep -i '^Icon=' "$DESKTOP" | head -1 | cut -d= -f2 | sed 's/\.[a-zA-Z0-9]*$//')"
ICON_FOR_APPIMAGE="$TOOLS/circlechat.png"
[[ -n "$ICON_ENTRY" ]] && ICON_FOR_APPIMAGE="$TOOLS/$ICON_ENTRY.png"
cp "$ICON" "$ICON_FOR_APPIMAGE"

# linuxdeploy 会自己把二进制依赖的 .so 收进 AppDir
ARCH="$ARCH" "$TOOLS/linuxdeploy" \
    --appdir "$WORK/AppDir" \
    --executable "$BIN" \
    --desktop-file "$DESKTOP" \
    --icon-file "$ICON_FOR_APPIMAGE" \
    "${PLUGIN_ARGS[@]}" \
    --output appimage 2>&1 | tail -20

mkdir -p "$OUT_DIR"
OUTPUT="$OUT_DIR/CircleChat-${VERSION}-${ARCH}.AppImage"

# 上面那步会在当前目录产出 *.AppImage，统一改名搬到输出目录
shopt -s nullglob
appimages=( ./*.AppImage )
shopt -u nullglob
if [[ ${#appimages[@]} -eq 0 ]]; then
  echo "错误：linuxdeploy 没有产出任何 .AppImage，打包失败" >&2
  exit 1
fi
mv "${appimages[0]}" "$OUTPUT"
chmod +x "$OUTPUT"
echo "已生成：$OUTPUT"
