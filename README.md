# CircleChat 桌面客户端

WebView 外壳：把 CircleChat 的网页端装进一个原生桌面窗口里。

- 只用 **wry** 做 WebView（不用 Tauri）
- 配置窗口是 **iced** 写的原生控件，不是 HTML
- 跨平台：Linux / macOS / Windows

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

按 `Ctrl+Shift+R`（macOS 为 `Cmd+Shift+R`）可以清除配置、重启并回到配置窗口。

---

## 构建

需要 Rust **1.89+**（`notify-rust` 的 MSRV 最高）。

```bash
cargo build --release
```

### Linux 依赖

```bash
sudo apt-get install -y build-essential pkg-config \
  libwebkit2gtk-4.1-dev libgtk-3-dev \
  libayatana-appindicator3-dev librsvg2-dev
```

### 环境变量

| 变量 | 是否必需 | 说明 |
|---|---|---|
| `APP_SECRET` | **是** | 站点身份校验用的共享密钥。没设置时任何站点都会校验失败 |
| `CIRCLECHAT_USER_AGENT` | 否 | 整体覆盖 User-Agent（内置的 UA 里写死了浏览器版本号，将来变旧时用它兜底） |

```bash
APP_SECRET='你的密钥' cargo run
```

> macOS / Windows 只做了 API 层面的核对（没有对应工具链在本机编译过），首次在这两个平台构建时留意一下窗口图标和通知的表现。

---

## 启动

```bash
# 调试运行（首次会弹配置窗口）
APP_SECRET='你的密钥' cargo run

# 或者先构建再直接跑二进制
cargo build --release
APP_SECRET='你的密钥' ./target/release/circlechat-client
```

**首次启动**（配置文件里还没有地址）：

1. 弹出「CircleChat 配置」窗口
2. 填服务地址，点「保存并进入」
3. 客户端去拉 `{地址}/api/app-manifest` 校验站点身份 —— 通过才写入配置并打开 WebView，失败则在窗口里提示「无效的站点」

**之后再启动**：配置里已有地址，直接打开 WebView，不再弹配置窗口。这种情况**可以不用传 `APP_SECRET`**（校验只发生在保存地址那一刻）。

**回到配置窗口**，两种方式：

- 在 WebView 里按 `Ctrl+Shift+R`（macOS 为 `Cmd+Shift+R`）—— 会清掉配置并重启客户端
- 直接删掉配置文件再启动

日志（配置路径、缓存目录、UA、下载、通知）都打到 stdout，需要留档就：

```bash
APP_SECRET='你的密钥' cargo run 2>&1 | tee run.log
```

---

## 站点身份校验

保存地址前，客户端会 GET `{地址}/api/app-manifest`，期望：

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

---

## 给前端的接口

### 判断自己跑在客户端里

```ts
const isDesktop = !!window.__CIRCLECHAT_CLIENT__
// { name: 'circlechat-desktop', version: '0.1.0', platform: 'linux' | 'macos' | 'windows' }
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
|---|---|---|
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

---

## 缓存与其它行为

- **入口文档每次都重新请求**（带 `Cache-Control: no-cache, no-store`），前端发版立刻生效
- **其它资源**（图片、字体、媒体、附件）按服务端响应头走 WebView 的磁盘缓存。wry 默认是临时上下文，什么都不留，所以客户端显式指定了一个持久化目录
- **下载**落到系统下载目录，重名自动加 ` (1)`、` (2)`
- **站外链接**（origin 不同，含子域和换协议）交给系统默认程序打开，不在 WebView 里开
- `window.open` / `target="_blank"` 的站内链接在当前 WebView 打开，不弹新窗

清缓存：删掉数据目录里的 `webview/` 即可。

---

## 目录

| 路径 | 说明 |
|---|---|
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

配置文件与数据目录：

| 平台 | 配置 |
|---|---|
| Linux | `~/.config/circlechat/config.json`（数据在 `~/.local/share/circlechat/`） |
| macOS | `~/Library/Application Support/com.CircleChat.CircleChat/config.json` |
| Windows | `%APPDATA%\CircleChat\CircleChat\config\config.json` |

---

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

---

## 测试

```bash
cargo test
```

30 项，覆盖配置读写、站点校验（含签名向量与时间戳边界）、站内外判定、下载文件名处理、客户端标记、图标解码、说明页转义等。
