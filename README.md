# CircleChat 桌面客户端

> 把 [CircleChat](https://github.com/CircleChat-Team) 网页端装进一个原生桌面窗口的轻量客户端。

[![最新版本](https://img.shields.io/github/v/release/CircleChat-Team/CircleChat-Client)](https://github.com/CircleChat-Team/CircleChat-Client/releases)
[![许可证](https://img.shields.io/github/license/CircleChat-Team/CircleChat-Client)](./LICENSE)
[![平台](https://img.shields.io/badge/platform-Linux%20%7C%20macOS%20%7C%20Windows-2ea44f)](https://github.com/CircleChat-Team/CircleChat-Client/releases)
[![CI](https://github.com/CircleChat-Team/CircleChat-Client/actions/workflows/ci.yml/badge.svg)](https://github.com/CircleChat-Team/CircleChat-Client/actions/workflows/ci.yml)
[![Release](https://github.com/CircleChat-Team/CircleChat-Client/actions/workflows/release.yml/badge.svg)](https://github.com/CircleChat-Team/CircleChat-Client/actions/workflows/release.yml)

CircleChat 桌面客户端是一个用 Rust 编写的 WebView 外壳：它不捆绑浏览器引擎，而是调用系统原生的 WebView（Linux 的 WebKitGTK / macOS 的 WKWebView / Windows 的 WebView2），把 CircleChat 的网页端承载在一个原生窗口里。

## 特性

- **轻量**：复用系统 WebView，不内置 Chromium，安装包小、内存占用低
- **纯 Rust**：只用 [wry](https://github.com/tauri-apps/wry) 做 WebView，不引入 Tauri 整套框架
- **原生配置窗口**：首次配置用 [iced](https://github.com/iced-rs/iced) 写的原生控件，不是内嵌网页
- **跨平台**：Linux / macOS / Windows 一套代码
- **桌面能力**：系统通知、下载落盘、站内外链接自动分流到系统默认程序

## 目录

- [下载与安装](#下载与安装)
- [快速开始](#快速开始)
- [从源码构建](#从源码构建)
- [配置与启动流程](#配置与启动流程)
- [站点身份校验](#站点身份校验)
- [给前端的接口](#给前端的接口)
- [缓存与其它行为](#缓存与其它行为)
- [项目结构](#项目结构)
- [图标与打包](#图标与打包)
- [CI 与发布](#ci-与发布)
- [贡献](#贡献)
- [许可证](#许可证)

## 下载与安装

推荐从 [Releases](https://github.com/CircleChat-Team/CircleChat-Client/releases) 下载预编译安装包：

| 平台 | 安装包 | 安装方式 |
| --- | --- | --- |
| Linux | `.deb` | `sudo apt install ./circlechat-client_<版本>_amd64.deb` |
| Linux | `.rpm` | `sudo dnf install ./circlechat-client-<版本>-1.x86_64.rpm` |
| Linux | `.AppImage` | `chmod +x CircleChat-<版本>-x86_64.AppImage && ./CircleChat-<版本>-x86_64.AppImage` |
| macOS | `.dmg` | 打开挂载后把 `CircleChat.app` 拖进「应用程序」 |
| Windows | `.zip` | 解压后运行 `circlechat-client.exe` |

> 当前发布包**未签名**：macOS 首次打开会被 Gatekeeper 拦截（右键 → 打开）；Windows 可能弹 SmartScreen。正式分发前需要在 CI 里加上开发者证书签名 / 公证步骤，详见 [CI 与发布](#ci-与发布)。

## 快速开始

首次启动需要配置服务地址，以及用于站点身份校验的共享密钥 `APP_SECRET`：

```bash
# 直接跑预编译二进制（路径按你的安装方式调整）
APP_SECRET='你的密钥' ./circlechat-client

# 或从源码开发运行
APP_SECRET='你的密钥' cargo run
```

启动后按 `Ctrl+Shift+R`（macOS 为 `Cmd+Shift+R`）可以清除配置、重启并回到配置窗口。

## 从源码构建

需要 Rust **1.89+**（`notify-rust` 的 MSRV 最高）。

```bash
cargo build --release
```

### Linux 依赖

```bash
sudo apt-get install -y build-essential pkg-config \
  libwebkit2gtk-4.1-dev libgtk-3-dev \
  libayatana-appindicator3-dev librsvg2-dev \
  libdbus-1-dev libxkbcommon-dev
```

### macOS / Windows

macOS 与 Windows 走系统原生 WebView，无需额外系统依赖；具体的打包/签名事宜见 [图标与打包](#图标与打包) 与 [CI 与发布](#ci-与发布)。

### 环境变量

| 变量 | 是否必需 | 说明 |
| --- | --- | --- |
| `APP_SECRET` | **是** | 站点身份校验用的共享密钥。没设置时任何站点都会校验失败 |
| `CIRCLECHAT_USER_AGENT` | 否 | 整体覆盖 User-Agent（内置的 UA 里写死了浏览器版本号，将来变旧时用它兜底） |
| `CIRCLECHAT_URL` | 否 | 直接指定要加载的地址，跳过配置窗口（调试用） |

```bash
APP_SECRET='你的密钥' cargo run
```

## 配置与启动流程

启动流程：

```
读本地配置 → 有地址？── 是 ──→ 打开 WebView
                    │
                    否
                    ↓
              弹出配置窗口（填地址）
                    ↓
              GET {地址}/api/app-manifest 校验站点身份
                    ↓
              通过 → 保存地址并进入 WebView
              失败 → 窗口里提示“无效的站点”，不保存、不进入
```

**首次启动**（配置文件里还没有地址）：

1. 弹出「CircleChat 配置」窗口
2. 填服务地址，点「保存并进入」
3. 客户端去拉 `{地址}/api/app-manifest` 校验站点身份 —— 通过才写入配置并打开 WebView，失败则在窗口里提示「无效的站点」

**之后再启动**：配置里已有地址，直接打开 WebView，不再弹配置窗口。这种情况**可以不用传 `APP_SECRET`**（校验只发生在保存地址那一刻）。

**回到配置窗口**，两种方式：

- 在 WebView 里按 `Ctrl+Shift+R`（macOS 为 `Cmd+Shift+R`）—— 会清掉配置并重启客户端
- 直接删掉配置文件再启动

配置文件与数据目录：

| 平台 | 配置 |
| --- | --- |
| Linux | `~/.config/circlechat/config.json`（数据在 `~/.local/share/circlechat/`） |
| macOS | `~/Library/Application Support/com.CircleChat.CircleChat/config.json` |
| Windows | `%APPDATA%\CircleChat\CircleChat\config\config.json` |

日志（配置路径、缓存目录、UA、下载、通知）都打到 stdout，需要留档就：

```bash
APP_SECRET='你的密钥' cargo run 2>&1 | tee run.log
```

## 站点身份校验

保存地址前，客户端会 `GET {地址}/api/app-manifest`，期望：

```json
{
  "app_id": "com.example.myapp",
  "version": "1.0.0",
  "timestamp": 1700000000,
  "signature": "sha256(app_id+version+timestamp+SECRET)"
}
```

三项全部通过才允许保存：

1. `app_id == "com.example.myapp"`（硬编码）
2. `signature == sha256(app_id + version + timestamp + SECRET)` 的小写 hex（大小写不敏感，允许 `sha256=` / `sha256:` 前缀）
3. `|本地时间 - timestamp| <= 300` 秒

> 校验结果**缓存在内存里，成功和失败都缓存**。所以服务端修好之后，需要让用户重启客户端才能重新校验。

## 给前端的接口

### 判断自己跑在客户端里

```ts
const isDesktop = !!window.__CIRCLECHAT_CLIENT__
// { name: 'circlechat-desktop', version: '0.1.1', platform: 'linux' | 'macos' | 'windows' }
```

注入时机是页面脚本执行之前，所有路由/刷新都在。**只在主 frame 注入**，iframe 里没有。

### 发系统通知

```ts
const result = await window.__CIRCLECHAT__.notify({ title: '新消息', body: '张三：在吗？' })
// { ok: true, error: null } 或 { ok: false, error: '<原因>' }
```

`error` 可能是系统通知服务的报错（Linux 没有通知守护进程、macOS 权限被拒…），也可能是：

- `ipc-unavailable` —— 不在客户端里（比如用浏览器调试页面）
- `timeout` —— 10 秒内没拿到结果

标题上限 120 字符、正文 500 字符，超出截断。

### 其它两个标记

| 机制 | 谁用 | 覆盖范围 |
| --- | --- | --- |
| User-Agent 里的 `CircleChatDesktop/<版本>` | 服务端 + 前端 | **所有请求**（子资源 / XHR / WebSocket 握手） |
| `X-CircleChat-Client: <版本>` 请求头 | 服务端 | **只有入口文档那一次请求** |

后续接口请求要带标记的话，前端自己在拦截器里加：

```ts
axios.interceptors.request.use(cfg => {
  if (window.__CIRCLECHAT_CLIENT__) cfg.headers['X-CircleChat-Client'] = window.__CIRCLECHAT_CLIENT__.version
  return cfg
})
```

> 这些标记**只能用来做功能分支，不能用来做信任判定** —— 普通浏览器可以原样伪造。要服务端能信任，得用 `APP_SECRET` 签名换 token。

## 缓存与其它行为

- **入口文档每次都重新请求**（带 `Cache-Control: no-cache, no-store`），前端发版立刻生效
- **其它资源**（图片、字体、媒体、附件）按服务端响应头走 WebView 的磁盘缓存。wry 默认是临时上下文，什么都不留，所以客户端显式指定了一个持久化目录
- **下载**落到系统下载目录，重名自动加 ` (1)`、` (2)`
- **站外链接**（origin 不同，含子域和换协议）交给系统默认程序打开，不在 WebView 里开
- `window.open` / `target="_blank"` 的站内链接在当前 WebView 打开，不弹新窗

清缓存：删掉数据目录里的 `webview/` 即可。

## 项目结构

| 路径 | 说明 |
| --- | --- |
| `src/main.rs` | 启动编排（只做这件事） |
| `src/app.rs` | 应用身份与标准目录 |
| `src/config.rs` | 本地 JSON 配置读写 |
| `src/site.rs` | 站点身份校验 |
| `src/config_window.rs` | iced 配置窗口 |
| `src/webview.rs` | tao 窗口 + wry WebView + 事件循环 |
| `src/download.rs` | 下载落盘 |
| `src/identity.rs` | 客户端标记 / UA / 入口请求头 |
| `src/notice.rs` | 内置说明页（未配置时显示） |
| `src/icon.rs` | 图标解码 |
| `src/notification.rs` | 系统通知与页面 JS API |
| `src/links.rs` | 站内外判定与系统默认程序 |
| `build.rs` | Windows 上给 exe 嵌图标（`tauri-winres`） |
| `assets/` | `logo.svg` 源图 + 生成好的 `icon.png` / `.ico` / `.icns` |
| `packaging/` | 图标生成脚本、macOS `.app` 打包脚本 |

## 图标与打包

改图标只需要换 `assets/logo.svg`，然后：

```bash
python3 packaging/icons/build-icons.py   # 需要 python3 + ffmpeg（带 librsvg）
```

会重新生成 `icon.png`（运行时窗口/通知用）、`icon.ico`（Windows exe）、`icon.icns`（macOS）。

macOS 打 `.app`（图标必须打进 bundle 才生效）：

```bash
cargo build --release
packaging/macos/bundle.sh                # → target/macos/CircleChat.app
```

Windows 不需要额外步骤，`build.rs` 在 Windows 宿主机上构建时会自动把 `icon.ico` 嵌进 exe（分发前还需要签名）。

## CI 与发布

两条流水线，目的是**平时的提交不产生版本**：

| 流水线 | 触发时机 | 做什么 |
| --- | --- | --- |
| `.github/workflows/ci.yml` | push / PR，且改动涉及代码（`src/**`、`Cargo.*`、`build.rs`、`assets/**`） | 三个平台编译 + `cargo test`，**不产出、不发布** |
| `.github/workflows/release.yml` | ① 推送 `v*` tag ② 手动 Run workflow | 构建多平台安装包，创建 GitHub Release 并附上产物 |

### 发正式版

```bash
git tag v0.2.0 && git push origin v0.2.0
```

> 把版本号换成你要发的版本；tag 名去掉 `v` 即是发布版本号。

### 按某个提交发版（sha 作版本号）

网页上 Actions → Release → Run workflow，填：

- `ref`：要构建的 commit sha（留空用当前 HEAD）
- `prerelease`：默认勾上

或者命令行：

```bash
gh workflow run release.yml -f ref=$(git rev-parse --short HEAD) -f prerelease=true
```

会创建一个 `sha-<短sha>` 标签的预发布版本。

### 产物

| 平台 | 产物 |
| --- | --- |
| Linux | `.deb`、`.rpm`、`.AppImage` |
| Windows | `circlechat-<版本>-windows-x86_64.zip`（含 exe，图标已由 `build.rs` 嵌入） |
| macOS | `CircleChat-<版本>.dmg`（内含 `.app`，图标来自 `assets/icon.icns`） |

### 构建号

CI 通过环境变量 `CIRCLECHAT_BUILD` 把 git short sha 编进二进制，本地构建时 `build.rs` 会自己去问 git。所以客户端对外报的版本是 `0.1.1+<sha>`，UA 和 `window.__CIRCLECHAT_CLIENT__.version` 里都能看到。

```bash
CIRCLECHAT_BUILD=$(git rev-parse --short HEAD) cargo build --release
```

## 测试

```bash
cargo test
```

覆盖配置读写、站点校验（含签名向量与时间戳边界）、站内外判定、下载文件名处理、客户端标记、图标解码、说明页转义等。

## 贡献

欢迎 Issue 和 Pull Request！

- 开发在功能分支进行，平常的 push / PR 只会跑 `ci.yml` 编译与测试，不会产生版本
- 发版靠打 `v*` tag 触发 `release.yml`（见上）
- 提交信息建议清晰说明意图；涉及行为变更的 PR 最好带上对应测试

## 许可证

本项目采用双重许可，你可以任选其一：

- [MIT](./LICENSE)
- [Apache-2.0](./LICENSE)

具体的许可条款见仓库根目录的 `LICENSE` 文件。
