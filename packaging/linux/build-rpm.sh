#!/usr/bin/env bash
#
# 打一个 .rpm（需要 rpmbuild：CI 里 `sudo apt-get install -y rpm`）。
#
# 用法：
#   packaging/linux/build-rpm.sh <二进制路径> <版本号> [输出目录]
#
# 注意：rpm 的版本号里不能有 `-`，脚本会自动替换成 `_`。
# 另外刻意**不写 Requires** —— WebKitGTK 的包名在各发行版里不一样
# （Fedora 是 webkit2gtk4.1，openSUSE 是 libwebkit2gtk-4_1-0），写死反而会装不上。

set -euo pipefail

BIN="${1:?缺少参数：二进制路径}"
VERSION="${2:?缺少参数：版本号}"
OUT_DIR="${3:-dist}"

VERSION="${VERSION//-/_}"
NAME="circlechat-client"
ARCH="$(uname -m)"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1

command -v rpmbuild >/dev/null 2>&1 || { echo "找不到 rpmbuild，先装 rpm 包" >&2; exit 1; }

ICON="$ROOT/assets/icon.png"
DESKTOP="$ROOT/packaging/linux/circlechat.desktop"
for file in "$BIN" "$ICON" "$DESKTOP"; do
    [[ -f "$file" ]] || { echo "找不到文件：$file" >&2; exit 1; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
mkdir -p "$WORK/root/usr/bin"
mkdir -p "$WORK/root/usr/share/applications"
mkdir -p "$WORK/root/usr/share/icons/hicolor/256x256/apps"

install -m 0755 "$BIN" "$WORK/root/usr/bin/$NAME"
install -m 0644 "$DESKTOP" "$WORK/root/usr/share/applications/circlechat.desktop"
install -m 0644 "$ICON" "$WORK/root/usr/share/icons/hicolor/256x256/apps/circlechat.png"

cat > "$WORK/SPECS/$NAME.spec" <<SPEC
Name:           $NAME
Version:        $VERSION
Release:        1%{?dist}
Summary:        CircleChat 桌面客户端
License:        MIT OR Apache-2.0
URL:            https://github.com/CircleChat-Team/CircleChat-Client

%description
把 CircleChat 网页端装进原生桌面窗口的客户端（WebView 外壳）。

%install
rm -rf %{buildroot}
mkdir -p %{buildroot}
cp -a %{_builddir}/. %{buildroot}/

%files
/usr/bin/$NAME
/usr/share/applications/circlechat.desktop
/usr/share/icons/hicolor/256x256/apps/circlechat.png

%changelog
* $(date +'%a %b %d %Y') CircleChat <noreply@example.com> - $VERSION-1
- 自动构建
SPEC

mkdir -p "$OUT_DIR"
rpmbuild --define "_topdir $WORK" \
         --define "_builddir $WORK/root" \
         --define "_buildrootdir $WORK/buildroot" \
         --define "_rpmdir $OUT_DIR" \
         --target "$ARCH" \
         -bb "$WORK/SPECS/$NAME.spec"

echo "已生成（在 $OUT_DIR 下）："
find "$OUT_DIR" -name "*.rpm" -newermt '-2 minutes' 2>/dev/null || ls "$OUT_DIR"
