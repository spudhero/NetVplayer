# NetVplayer

<p align="center">
  <img src="website/assets/app-icon.webp" width="128" height="128" alt="NetVplayer app icon">
</p>

<p align="center">
  <strong>你的内容，你的 Mac，你的播放方式。</strong><br>
  <strong>Your content. Your Mac. Your way to watch.</strong>
</p>

<p align="center">
  <a href="#中文">中文</a> |
  <a href="#english">English</a> |
  <a href="https://spudhero.github.io/NetVplayer/">Website</a> |
  <a href="https://github.com/spudhero/NetVplayer/releases/latest">Download</a> |
  <a href="CHANGELOG.md">Release History</a> |
  <a href="https://github.com/spudhero/NetVplayer-Provider-Distribution/releases">Provider Releases</a> |
  <a href="provider-sdk/README.md">Provider SDK</a>
</p>

![NetVplayer running on macOS](website/assets/home-aurora.webp)

发布基线 / Release baseline: **NetVplayer 1.1.4 (build 18)**.

| Component | Version |
| --- | --- |
| Stable application | 1.1.4 |

## 中文

NetVplayer 是基于 SwiftUI 与内嵌 libmpv 的原生 macOS 媒体播放器，支持点播、直播、云盘和自有文件。适用于 **macOS 14+ / Apple Silicon**，界面支持简体中文和 English。

公开应用不内置视频源、目录、直播列表、账号或媒体内容。内容入口由用户自行添加，并应具有相应访问权限。

### 项目背景

FongMi/TV、OK影视、影视仓、TVBox 等工具主要服务 Android 生态。我一直没有找到符合自己使用习惯的 macOS 版本，于是从 SwiftUI 与 libmpv 开始，写了 NetVplayer。

项目将内容浏览、搜索、选集和播放组织成原生 Mac 桌面体验。感谢 [FongMi/TV](https://github.com/FongMi/TV) 等开源实践提供的兼容性参考；NetVplayer 使用独立的 Swift/macOS 实现，与这些项目没有隶属或官方合作关系。

### 主要功能

- **浏览与搜索**：影片详情、多线路选集、跨已连接来源搜索。
- **点播与直播**：字幕、音轨、倍速、画面比例、章节预览、频道分组与节目单。
- **云盘与文件**：连接受支持云盘、WebDAV、AList/OpenList、SMB 和本机文件夹。
- **媒体库**：电影、剧集和混合海报墙，支持本地资料、TMDB、豆瓣及手动匹配。
- **桌面体验**：播放历史、收藏、续播、紧凑窗口与主题切换。

| 影片详情与选集 | 播放控制 |
| :---: | :---: |
| <img src="website/assets/screen-detail.webp" alt="影片详情与选集" width="720"> | <img src="website/assets/screen-player.webp" alt="点播播放控制" width="720"> |

### 安装

1. 从[最新 GitHub Release](https://github.com/spudhero/NetVplayer/releases/latest)下载 `macos-arm64.zip`。
2. 解压，将 `NetVplayer.app` 拖入“应用程序”。
3. 首次启动在 Finder 中右键选择“打开”。当前应用使用社区 ad-hoc 签名；如仍被拦截，在“系统设置 → 隐私与安全性”确认应用后选择“仍要打开”。
4. 等待“设置 → 扩展支持”显示就绪。首次安装和扩展更新需要能访问 GitHub。
5. 在“设置 → 内容来源”添加自己的配置、账号或文件位置，即可开始使用。

应用会在侧栏和设置页的版本号旁提示更新，确认后在后台下载与校验，正常退出后安装。版本说明与历史请查看 [CHANGELOG](CHANGELOG.md#中文) 或 [GitHub Releases](https://github.com/spudhero/NetVplayer/releases)。

### 使用

- **在线内容**：在“设置 → 内容来源 → 在线内容”加载影视配置或 JSON、M3U、TXT 直播列表；Xtream 服务填写服务方提供的地址和账号。
- **云盘**：在“网盘账号”完成所需授权，再打开自己的文件或分享。
- **NAS / 本地**：在“视频文件位置”添加服务器或文件夹，测试并保存后从首页选择该服务；切到“媒体库”可添加电影或剧集目录。
- **播放**：打开详情选择线路和剧集，在播放器调整字幕、音轨和倍速；历史记录可继续上次播放。

TMDB 由正式应用提供项目凭据，普通用户无需填写令牌。配置与账号保存在本机，导出备份不包含密码、Token 或 Cookie。

### 扩展与开发

兼容的签名 Provider 由应用自动下载、验证和更新，异常时在“设置 → 扩展支持”选择“重新检查”。包版本与兼容说明见 [Provider Releases](https://github.com/spudhero/NetVplayer-Provider-Distribution/releases)。主程序和 SDK 公开，Provider 实现源码保持私有。

使用 Xcode 和 Homebrew libmpv 依赖从源码构建：

```bash
swift build --package-path NetVplayer
swift test --package-path NetVplayer --disable-sandbox --no-parallel
```

详细说明：[架构](ARCHITECTURE.md) · [Provider SDK](provider-sdk/README.md) · [Runner](provider-runners/README.md) · [打包凭据配置](TMDB_SETUP.md) · [贡献指南](CONTRIBUTING.md) · [安全说明](SECURITY.md)。

遇到问题可通过应用内“问题反馈”生成脱敏信息，并说明复现步骤。自动诊断可在“设置 → 问题反馈”中关闭。项目采用 [MIT License](LICENSE)，第三方组件适用各自许可证。

---

## English

NetVplayer is a native macOS media player built with SwiftUI and embedded libmpv, supporting on-demand video, live channels, cloud drives, and your own files. It runs on **macOS 14+ / Apple Silicon**, with Simplified Chinese and English interfaces.

The public app contains no bundled content sources, catalogs, channel lists, accounts, or media. Users add their own entry points and must be authorized to access them.

### Project background

FongMi/TV, OK影视, 影视仓, and TVBox primarily serve Android. I could not find a macOS version that matched how I wanted to use a desktop media app, so I started NetVplayer with SwiftUI and libmpv.

The project brings browsing, search, episode selection, and playback into a native Mac experience. Thanks to [FongMi/TV](https://github.com/FongMi/TV) and other open-source projects for compatibility references. NetVplayer uses an independent Swift/macOS implementation and has no affiliation or official partnership with those projects.

### Features

- **Browse and search:** details, multiple playback routes, episode selection, and search across connected sources.
- **Video and live TV:** subtitles, audio tracks, playback speed, aspect ratio, chapter previews, channel groups, and programme guides.
- **Cloud drives and files:** supported drive accounts, WebDAV, AList/OpenList, SMB, and local folders.
- **Media libraries:** movie, TV, and mixed poster libraries with local metadata, TMDB, Douban, and manual matching.
- **Desktop controls:** history, favorites, resume playback, compact windows, and themes.

### Installation

1. Download `macos-arm64.zip` from the [latest GitHub Release](https://github.com/spudhero/NetVplayer/releases/latest).
2. Extract it and move `NetVplayer.app` to Applications.
3. On first launch, right-click the app in Finder and choose Open. The community build uses ad-hoc signing; if macOS blocks it, confirm the app under System Settings → Privacy & Security and choose Open Anyway.
4. Wait for Settings → Verified Extensions to report ready. Initial preparation and extension updates require access to GitHub.
5. Add your own configuration, accounts, or file locations under Settings → Content Sources.

The app marks available updates beside its version in the sidebar and Settings. Confirm an update to download and verify it in the background; installation happens on normal exit. Release notes and history are available in the [CHANGELOG](CHANGELOG.md#english) and [GitHub Releases](https://github.com/spudhero/NetVplayer/releases).

### Usage

- **Online content:** load a video configuration or JSON, M3U, or TXT channel list under Settings → Content Sources → Online Content. For Xtream services, enter the address and account supplied by your service.
- **Cloud drives:** authorize the required account under Cloud Drive Accounts, then open your files or shares.
- **NAS / local:** add a server or folder under Video File Locations, test and save it, then select it from the home source menu. Switch to Media Libraries to add movie or TV directories.
- **Playback:** choose a route and episode in the details view, adjust subtitles, audio, and speed in the player, and resume from History.

Official builds supply the TMDB application credential; ordinary users do not need a token. Configurations and accounts stay on the Mac. Exported backups exclude passwords, tokens, and cookies.

### Extensions and development

The app automatically downloads, verifies, and updates compatible signed Providers. Use Settings → Verified Extensions → Check Again if preparation fails. See [Provider Releases](https://github.com/spudhero/NetVplayer-Provider-Distribution/releases) for versions and compatibility. The main application and SDK are public; Provider implementation sources remain private.

Build from source with Xcode and the Homebrew libmpv dependencies using the commands above. Further documentation: [Architecture](ARCHITECTURE.md) · [Provider SDK](provider-sdk/README.md) · [Runners](provider-runners/README.md) · [Packaging credentials](TMDB_SETUP.md) · [Contributing](CONTRIBUTING.md) · [Security](SECURITY.md).

Use the in-app Problem Report flow to generate redacted diagnostics and describe reproduction steps. Automatic Diagnostics can be disabled under Settings → Problem Report. The project uses the [MIT License](LICENSE); third-party components retain their own licenses.
