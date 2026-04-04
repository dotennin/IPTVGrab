# Media Nest — Rust Edition

面向**个人媒体归档、离线访问与自有源管理**的工具套件，适用于你自己控制、自己维护，或已获得授权访问的 HLS/M3U8 媒体源。它包含：
- **Rust 核心库** (`crates/m3u8-core`) — 媒体分片抓取、AES-128 解密、CMAF/MPEG-TS 合并与本地归档能力
- **Axum Web 服务器** (`crates/server`) — 替代原 Python/FastAPI 版本，复用同一前端，提供本地 API / WebSocket 工作流
- **Flutter 移动客户端** (`mobile/flutter`) — 在设备本地拉起 Rust server，把手机本身变成一个个人媒体工作区
- **C FFI 绑定层** (`crates/mobile-ffi`) — Flutter 本地 server 启停桥接

它更适合被理解为：
- 个人媒体库与离线缓存工具
- 自有播放列表 / 自建源管理工具
- 本地优先（local-first）的媒体整理与播放辅助应用

而不是“公共站点视频抓取器”。项目默认假设用户只会处理自己有权访问的源。

---

## 产品介绍（适合商店 / 官网）

**Media Nest** 是一个本地优先的个人媒体归档应用。你可以把自己维护的播放列表、直播源、点播源或其他 HLS/M3U8 媒体地址接入到设备中，统一做可用性检查、变体选择、离线保存、片段裁剪、预览播放和本地文件导出。

与典型“远程下载器”不同，Media Nest 的移动端会直接在设备上启动本地 Rust 媒体服务，所有任务、索引和处理中间态都尽量留在本机完成。这样做的重点是让用户围绕**自己的媒体资产**建立一个稳定、可携带、可离线访问的个人媒体库，而不是依赖外部托管平台。

适合的使用场景包括：
- 管理你自己维护的播放列表、频道分组和频道可用性
- 对你有权访问的直播 / 点播源做本地保存与后续离线播放
- 把临时预览流整理成设备内可分享、可导出、可裁剪的媒体文件
- 在手机端直接完成播放、Picture in Picture、导出相册和分享

建议对外文案可以强调以下关键词：
- `Personal media archive`
- `Offline access for your own sources`
- `On-device media workspace`
- `Playlist and channel management`

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
3. 离线保存、clip、playlist、watch proxy、任务流全部复用现有 Rust server 逻辑
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
| 离线归档 | ✅ | ✅ |
| 实时采集 | ✅ | ✅ |
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
