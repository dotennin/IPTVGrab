# IPTVGrab — Rust Edition

完整的 HLS/M3U8 下载器，包含：
- **Rust 核心库** (`crates/m3u8-core`) — 分片下载、AES-128 解密、CMAF/MPEG-TS 合并
- **Axum Web 服务器** (`crates/server`) — 替代原 Python/FastAPI 版本，复用同一前端
- **Flutter 移动客户端** (`mobile/flutter`) — 在设备本地拉起 Rust server，并通过 `127.0.0.1` 访问同一套 HTTP / WebSocket API
- **C FFI 绑定层** (`crates/mobile-ffi`) — Flutter 本地 server 启停桥接

---

## 架构

```
crates/
  m3u8-core/      ← 核心引擎（服务端 + 移动端共用）
  server/         ← axum HTTP 服务器（可桌面运行，也可嵌入移动端）
  mobile-ffi/     ← Flutter 本地 server 的 FFI 桥接层

mobile/
  flutter/        ← Flutter 本地客户端（推荐）
```

---

## 快速开始

### 服务器

```bash
# 编译并运行
cargo run -p server

# 或编译 release 版
make server
./target/release/m3u8-server

# 环境变量
PORT=8765 DOWNLOADS_DIR=./downloads AUTH_PASSWORD=secret ./target/release/m3u8-server
```

前端和 Python 版本完全一致，直接复用 `static/` 目录。

---

### Flutter App（推荐）

**前置条件：** Flutter 3.x、Xcode（生成 IPA）、Android SDK（生成 APK）

```bash
# 生成 / 补齐 Flutter 平台工程（首次）
make flutter-bootstrap

# 准备 Flutter 所需 Rust 原生库（Android .so + iOS XCFramework）
make flutter-prepare

# 本地运行
make flutter-run

# 生成 Android APK
make apk

# 生成可安装到本地设备的 debugging IPA（推荐）
make ipa-debug

# 生成 App Store / Distribution IPA（需要发行证书）
make ipa
```

Flutter 客户端是 **on-device 模式**：
1. App 启动后通过 `mobile-ffi` 在设备内拉起 Rust localhost server
2. Flutter 通过 `127.0.0.1` 调用同一套 `/api/*` 和 `/ws/*` 接口
3. 下载、clip、playlist、watch proxy、任务流全部复用现有 Rust server 逻辑
4. 不需要远程连接桌面机器
5. 当移动端 Rust server 因 `$PATH` 中没有 `ffmpeg` 而无法 merge / clip 时，Flutter 会使用 `ffmpeg_kit_flutter_new_min` 在本地完成 merge / clip，并把结果回写到任务状态
6. 预览、直播 watch、成品播放现在直接在 Flutter 内使用 `video_player` 打开，不再只是复制 URL

**iOS 说明：**
- Flutter iOS 构建还需要本机安装 CocoaPods（例如 `brew install cocoapods`）
- 当前移动端 FFmpeg 方案基于 `ffmpeg_kit_flutter_new_min`，iOS 最低部署版本需要 `14.0+`
- `make flutter-rust-ios` 会把 `MobileFfi.xcframework` 复制到 `mobile/flutter/ios/Frameworks/`
- Flutter Runner 工程已内置 `MobileFfi.xcframework` 链接和符号强制引用，不再需要手工把它拖进 Xcode

---

## 依赖

| 组件 | 要求 |
|---|---|
| Rust | 1.75+ (`rustup`) |
| ffmpeg | 需在 `$PATH` （合并阶段用） |
| Flutter | 3.x（Flutter 移动客户端） |
| Xcode | 15+ （iOS 构建） |
| CocoaPods | Flutter iOS 构建依赖 |
| Android NDK | r25+ （Android 构建） |
| cargo-ndk | `cargo install cargo-ndk` |

如果 `cargo ndk` 找不到 Android NDK，请安装 Android Studio 的 NDK 组件，或显式设置：

```bash
export ANDROID_NDK_HOME="$HOME/Library/Android/sdk/ndk/<version>"
```

---

## 与 Python 版本对比

| 功能 | Python | Rust |
|---|---|---|
| VOD 下载 | ✅ | ✅ |
| 直播录制 | ✅ | ✅ |
| AES-128 解密 | ✅ | ✅ |
| CMAF/fMP4 | ✅ | ✅ |
| IPTV 播放表 | ✅ | ✅ |
| 任务断点续传 | ✅ | ✅ |
| 实时预览 | ✅ | ✅ |
| 访问控制 | ✅ | ✅ |
| iOS App | ❌ | ✅ |
| Android App | ❌ | ✅ |
| 内存占用 | ~120 MB | ~25 MB |
| 启动时间 | ~1.2s | ~0.05s |
