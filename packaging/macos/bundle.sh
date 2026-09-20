#!/usr/bin/env bash
#
# 把构建产物打成一个 macOS .app（带图标）。
#
# 用法：
#   cargo build --release
#   packaging/macos/bundle.sh                      # 默认取 target/release/circlechat-client
#   packaging/macos/bundle.sh /path/to/binary      # 也可以显式指定二进制
#
# 产物：target/macos/CircleChat.app
#
# 注意：必须在 macOS 上执行才能得到真正可用的 bundle（签名、公证另说）。
# 在 Linux 上跑也能生成目录结构，但里面装的是 Linux 二进制。

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="${1:-$ROOT/target/release/circlechat-client}"
APP="$ROOT/target/macos/CircleChat.app"
ICON="$ROOT/assets/icon.icns"

if [[ ! -f "$BIN" ]]; then
    echo "找不到二进制：$BIN" >&2
    echo "先跑 cargo build --release，或者把二进制路径作为第一个参数传进来。" >&2
    exit 1
fi

if [[ ! -f "$ICON" ]]; then
    echo "找不到图标：$ICON" >&2
    exit 1
fi

# 版本号：CI 里用 CIRCLECHAT_VERSION 传入（`0.1.0+<sha>`），本地就从 Cargo.toml 读
VERSION="${CIRCLECHAT_VERSION:-$(sed -n 's/^version *= *"\(.*\)"/\1/p' "$ROOT/Cargo.toml" | head -1)}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/CircleChat"
chmod +x "$APP/Contents/MacOS/CircleChat"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>CircleChat</string>
    <key>CFBundleDisplayName</key>
    <string>CircleChat</string>
    <key>CFBundleExecutable</key>
    <string>CircleChat</string>
    <key>CFBundleIdentifier</key>
    <string>com.circlechat.desktop</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION:-0.1.0}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION:-0.1.0}</string>
    <key>LSMinimumSystemVersion</key>
    <string>11.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <!-- 通知权限：客户端会通过 notify-rust 发系统通知 -->
    <key>NSUserNotificationAlertStyle</key>
    <string>alert</string>
</dict>
</plist>
PLIST

echo "已生成：$APP"
echo "  可执行文件：$APP/Contents/MacOS/CircleChat"
echo "  图标：      $APP/Contents/Resources/AppIcon.icns"

# CIRCLECHAT_DMG=1 时再打个 dmg（分发用，.app 直接拷会丢权限/签名信息）
if [[ "${CIRCLECHAT_DMG:-0}" == "1" ]]; then
    DMG="$ROOT/target/macos/CircleChat-${VERSION}.dmg"
    rm -f "$DMG"
    hdiutil create -volname "CircleChat" -srcfolder "$APP" -ov -format UDZO "$DMG" >/dev/null
    echo "已生成：$DMG"
fi
