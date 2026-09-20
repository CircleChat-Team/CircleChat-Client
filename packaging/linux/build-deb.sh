#!/usr/bin/env bash
#
# 打一个 .deb。用系统的 dpkg-deb 手工组装，不额外装 cargo-deb 之类的工具。
#
# 用法：
#   packaging/linux/build-deb.sh <二进制路径> <版本号> [输出目录]
#
# 例子：
#   packaging/linux/build-deb.sh target/release/circlechat-client 0.1.0+abc1234 dist

set -euo pipefail

BIN="${1:?缺少参数：二进制路径}"
VERSION="${2:?缺少参数：版本号}"
OUT_DIR="${3:-dist}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1

NAME="circlechat-client"
ARCH="$(dpkg --print-architecture)"
ICON="$ROOT/assets/icon.png"
DESKTOP="$ROOT/packaging/linux/circlechat.desktop"

for file in "$BIN" "$ICON" "$DESKTOP"; do
    [[ -f "$file" ]] || { echo "找不到文件：$file" >&2; exit 1; }
done

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/DEBIAN"
mkdir -p "$STAGE/usr/bin"
mkdir -p "$STAGE/usr/share/applications"
mkdir -p "$STAGE/usr/share/icons/hicolor/256x256/apps"

install -m 0755 "$BIN" "$STAGE/usr/bin/$NAME"
install -m 0644 "$DESKTOP" "$STAGE/usr/share/applications/circlechat.desktop"
install -m 0644 "$ICON" "$STAGE/usr/share/icons/hicolor/256x256/apps/circlechat.png"

cat > "$STAGE/DEBIAN/control" <<CONTROL
Package: $NAME
Version: $VERSION
Section: net
Priority: optional
Architecture: $ARCH
Depends: libwebkit2gtk-4.1-0, libgtk-3-0
Maintainer: CircleChat <noreply@example.com>
Homepage: https://github.com/CircleChat-Team/CircleChat-Client
Description: CircleChat 桌面客户端
 把 CircleChat 网页端装进原生桌面窗口的客户端（WebView 外壳）。
CONTROL

mkdir -p "$OUT_DIR"
OUTPUT="$OUT_DIR/${NAME}_${VERSION}_${ARCH}.deb"

dpkg-deb --build --root-owner-group "$STAGE" "$OUTPUT"
echo "已生成：$OUTPUT"
