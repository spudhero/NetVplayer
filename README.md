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

> [!IMPORTANT]
> NetVplayer 的官方公开源码与发布应用不提供、托管或内置任何视频源、视频目录、直播列表、默认源地址、站点 Provider、账号或媒体内容。用户只能连接自己选择且有权访问的内容。
>
> The official public source and release build do not provide, host, or bundle video sources, catalogs, live channel lists, default source URLs, site-specific Providers, accounts, or media. Users may connect only content they choose and are authorized to access.

---

## 中文

### 原生 macOS 媒体播放器

NetVplayer 1.1.0 是基于 SwiftUI 与内嵌 `libmpv` 构建的原生 macOS 媒体播放器。它把内容发现、详情与选集、跨来源搜索、点播、直播、字幕、音轨和播放历史组织成一致的桌面体验，同时让内容入口和访问凭据始终由用户掌控。

2026-10-07 已正式发布 **NetVplayer 1.1.0（构建号 14）**、最新主程序壳源码和五种 **Provider 1.1.0**。应用安装包、源码与扩展均已更新；下载安装包或从当前 main 构建都可使用下文功能。

| 项目 | 当前版本 | 获取入口 |
| --- | --- | --- |
| 稳定应用安装包 | 1.1.0 | [最新 GitHub Release](https://github.com/spudhero/NetVplayer/releases/latest) |
| 公开主程序壳源码 | 1.1.0 | [main](https://github.com/spudhero/NetVplayer/tree/main) · [更新说明](RELEASE_NOTES_1.1.0.md) |
| 签名播放扩展 | 1.1.0 | [Provider Distribution](https://github.com/spudhero/NetVplayer-Provider-Distribution/releases) |

### 项目背景

FongMi/TV、OK影视、影视仓、TVBox 等常用工具主要服务 Android 生态。我一直没有找到符合自己使用习惯的 macOS 版本，于是从 SwiftUI 与 libmpv 开始，写了 NetVplayer。

NetVplayer 的目标不是照搬手机或电视端界面，而是把内容浏览、搜索、选集、点播和直播重新组织成一套原生 Mac 桌面体验。NetVplayer 不是上述项目的官方 Mac 版，与它们不存在隶属或官方合作关系；项目感谢 FongMi/TV 等开源实践提供的兼容性参考，并保持独立的 Swift/macOS 实现。

[查看版本与修复历史](CHANGELOG.md#中文)。README 只保留当前产品能力、安装方法和稳定使用说明。

你可以添加自己的兼容配置、Xtream-compatible 服务或受支持的云盘账号。全新安装保持空白，直到用户主动添加内容入口；已保存的配置可以在后续启动时恢复。

1.1.0 将“数据源设置”整理为“内容来源”，按在线内容、网盘账号、NAS / 本地、搜索与检查提供同页分组和快速定位。影视配置与直播列表使用链接入口；支持 Xtream 的服务使用服务方提供的地址、用户名和密码。网盘登录用于访问需要账号的视频，NAS / 本地用于连接自己的视频文件。旧版 1.0.12 的对应设置菜单名为“数据源设置”。

1.1.0 支持在“设置 → 内容来源 → NAS / 本地 → 视频文件位置”添加 WebDAV、AList、OpenList、SMB 和本机文件夹。填写服务器参数、测试连接并保存后，在首页选择该文件服务，浏览目录或添加媒体库。账号与密码在本机加密保存，本地目录使用系统授权书签。

每个文件服务可以添加多个电影、剧集或混合媒体库，首页提供“媒体库／文件”切换。媒体库优先读取本地 NFO 和图片，支持自动、TMDB、豆瓣、仅本地四种信息来源，并可手动修正匹配和海报。首次保存自动扫描，后续增量更新；修改影视信息不改变播放历史和续播身份。TMDB 由发布方配置应用凭据，普通用户无需填写令牌；无凭据的开发构建仍可使用豆瓣和本地资料。

分类、详情和海报会使用可清理的性能缓存缩短往返等待；过期列表在刷新时保留当前内容，慢网盘详情先显示影片信息再后台补齐剧集。设置中的普通缓存清理保留网页登录、配置、历史、收藏和扩展，网页 Cookie 与网站数据只由独立的“清除网页会话”操作删除。

### 完整观看体验

| 发现与选集 | 点播播放 |
| :---: | :---: |
| <img src="website/assets/screen-detail.webp" alt="影片详情与选集界面" width="720"> | <img src="website/assets/screen-player.webp" alt="点播播放器界面" width="720"> |
| **详情、线路与选集**<br>集中呈现影片信息、多线路和自然排序后的剧集。 | **原生播放控制**<br>使用 libmpv 播放，支持字幕、音轨、倍速、画面比例和紧凑窗口。 |

1.1.0 的章节面板提供画面预览、名称、时间范围和当前章节提示；悬停进度条节点可预览，点击可跳到章节起点，拖动仍可自由定位。没有章节的媒体隐藏入口，无法生成预览时仍可跳转。

| 跨来源搜索 | 直播播放 |
| :---: | :---: |
| <img src="website/assets/screen-search.webp" alt="跨来源搜索界面" width="720"> | <img src="website/assets/screen-live.webp" alt="直播播放器已经显示真实视频画面的运行界面" width="720"> |
| **高密度搜索工作台**<br>只搜索用户已经连接并选择的内容入口。 | **独立直播窗口**<br>提供频道分组、同名线路合并和按需显示的频道指南。 |

1.1.0 的直播配置可在“设置 → 内容来源 → 在线内容 → 影视与直播链接 → 直播频道列表”中加载 JSON、M3U 或 TXT 地址。“支持格式与填写示例”提供格式说明。JSON 包含多个直播源时，使用下方“直播源”菜单选择具体来源；直播窗口顶部也可切换，应用会记住选择。某个源加载失败时可直接选择其他源或重试。

### 用户自有内容

NetVplayer 提供播放、连接和兼容能力，不运营内容服务，也不代替用户取得访问授权。

- 公开仓库和发布应用不包含视频目录、直播列表、默认配置或媒体文件。
- 配置地址、站点列表、账号和凭据由用户自行提供并保存在本地边界内。
- 用户应只访问自己有权使用的内容，并遵守所在地法律及相关服务条款。
- Provider 扩展只能在用户配置精确匹配后参与处理，不能静默增加内容入口。
- 1.1.0 的网盘与 Xtream 账号在本机加密保存；历史、收藏和应用导出备份只保存无凭据的资源身份。公开 1.0.12 的明文登录在升级时自动迁移，校验成功后清理旧副本。
- 可直接添加自有 Xtream-compatible 服务，使用 Movies、Series、搜索与基础直播；服务器差异仍适用。
- 应用自有界面支持简体中文与 English，Provider 返回的内容名称保持原文。

### 安全扩展

Provider 是与主应用分离的扩展包。NetVplayer 只接受固定 HTTPS 索引中的候选，并在激活前检查索引签名、归档 SHA-256、manifest 签名、协议版本、App/macOS/架构兼容性、声明资源、沙盒启动器和吊销状态。

当前公开壳只会自动安装声明 `user-configured-only` 的 Provider。运行时、Runner、Provider 和依赖都必须位于签名包内；Runner 不会在运行时下载代码或安装依赖。其它用户配置策略需要单独的壳层与发行审查，不能借自动安装路径激活。

设置页会分别显示组件、缓存和用户数据占用。用户可以安全清理旧版本，或停用并卸载可识别组件；账号、Provider `.state`、配置、历史和未知文件保持不变，未完成维护可恢复。

### 签名扩展发布

五种 Provider 1.1.0 已正式发布，面向 **macOS 14+ / Apple Silicon arm64**。通常由应用自动安装与更新；可在“设置 → 扩展支持”选择“重新检查”。应用会核对主程序兼容版本，历史版本继续保留在官方索引中。

| Provider | 版本 | 最低主程序版本 |
| --- | --- | --- |
| [Java 目录](https://github.com/spudhero/NetVplayer-Provider-Distribution/releases/tag/provider-netvplayer.catalog.java-v1.1.0-arm64) | 1.1.0 | 1.0.0 |
| [JavaScript 目录](https://github.com/spudhero/NetVplayer-Provider-Distribution/releases/tag/provider-netvplayer.catalog.javascript-v1.1.0-arm64) | 1.1.0 | 1.0.0 |
| [Python 目录](https://github.com/spudhero/NetVplayer-Provider-Distribution/releases/tag/provider-netvplayer.catalog.python-v1.1.0-arm64) | 1.1.0 | 1.1.0 |
| [QuickJS 目录](https://github.com/spudhero/NetVplayer-Provider-Distribution/releases/tag/provider-netvplayer.catalog.quickjs-v1.1.0-arm64) | 1.1.0 | 1.0.0 |
| [可配置 Python](https://github.com/spudhero/NetVplayer-Provider-Distribution/releases/tag/provider-netvplayer.configurable.python-v1.1.0-arm64) | 1.1.0 | 1.0.0 |

Python 目录 1.1.0 包含最新目录兼容修复，需要主程序 1.1.0 提供的新播放能力。Provider 实现源码保持私有；签名安装包与[官方 stable 索引](https://spudhero.github.io/NetVplayer-Provider-Distribution/stable/index.json)公开分发。

### 项目架构

```mermaid
flowchart TB
    User[用户自有配置与服务<br>User-owned configuration and services]
    App[NetVplayerApp<br>SwiftUI + AppState]
    Core[ApplicationCore + Models<br>纯状态与决策]
    Engines[Config / Search / Spider / Drive / Live / Parse<br>File Services / Media Libraries]
    SDK[ProviderSDK<br>Wire + Manifest + Distribution contracts]
    Runtime[ProviderRuntime<br>Verify + Install + Rollback]
    Runner[Sandboxed Runner<br>Java / Node.js / QuickJS / Python]
    Proxy[ProxyServer<br>受限本地路由]
    Player[PlayerEngine<br>PlaySpec + libmpv]
    Diagnostics[Diagnostics<br>隐私过滤后的错误与性能诊断]

    User -->|用户主动配置| App
    App --> Core
    App --> Engines
    Engines --> SDK
    SDK --> Runtime
    Runtime --> Runner
    Runner -->|结构化结果| Engines
    Engines -->|统一 PlaySpec| Proxy
    Engines -->|可直连媒体| Player
    Proxy --> Player
    App -->|固定错误码与有限步骤| Diagnostics
```

`Models` 和 `ApplicationCore` 保存跨模块数据与纯决策；平台引擎负责配置、网络、Provider、网盘、解析和直播；所有播放入口最终归一化为 `PlaySpec`，再由 `PlayerEngine` 交给 libmpv。普通界面把内部失败转换为可理解的问题和建议动作，`Diagnostics` 只接收隐私门禁允许的固定错误码、阶段和有限步骤。详细模块边界、Provider 数据流和代理路由见[架构说明](ARCHITECTURE.md)。

### Provider SDK

仓库公开的 SDK 用于开发 **Provider 扩展**，不是把播放器嵌入其它应用的播放控件 SDK。它包括：

- `ProviderSDK` Swift 类型以及 protocol v1、manifest、catalog、source descriptor 和 distribution index JSON Schema；
- Java 21、Node.js 22.20.0、QuickJS 2026-06-04 和 Python Runner；
- fixture、签名打包、包结构验证、运行时验证和发行检查脚本。

从 [Provider SDK 开发指南](provider-sdk/README.md)开始，先运行不访问网络的 Python fixture，再选择目标运行时。Runner 的实现约束见 [Provider runners 参考](provider-runners/README.md)。

### 下载与构建

当前公开版本面向 macOS 14 或更高版本和 Apple Silicon。请从[项目官网](https://spudhero.github.io/NetVplayer/)或[最新 GitHub Release](https://github.com/spudhero/NetVplayer/releases/latest)下载。

应用会检查主程序更新，并在侧栏和设置页的版本号旁提示。打开版本号后可查看新版并选择“更新”；下载和验证在后台完成，正常退出应用后安装，下次启动使用新版本。1.0.8 及更早版本不含应用内更新器，需要先手动安装一次 1.0.9 或更新版本。当前 ad-hoc 签名仍可能触发 macOS 的首次打开或安装授权提示。

#### 小白安装步骤

1. 点击 macOS 左上角苹果菜单，打开“关于本机”，确认芯片是 Apple M 系列，系统为 macOS 14 或更高版本。当前公开版本暂不支持 Intel Mac。
2. 下载名称中包含 `macos-arm64.zip` 的最新正式安装包。
3. 双击 ZIP 解压，将 `NetVplayer.app` 拖入“应用程序”文件夹。
4. 首次启动时，在 Finder 中右键 NetVplayer 并选择“打开”，再在确认框中选择一次“打开”。
5. 如果仍被系统拦截，进入“系统设置 → 隐私与安全性”，确认应用名称后选择“仍要打开”。当前版本使用社区 ad-hoc 签名，首次放行通常只需一次。
6. 启动后等待“扩展支持”显示就绪。首次准备和后续更新扩展时，网络需要能够正常连接 GitHub；下载并验证完成后，离线时仍可继续使用本机已经安装且有效的组件。
7. 进入“设置 → 内容来源 → 在线内容”，填写你自己有权使用的兼容配置。看到加载成功后返回首页即可开始浏览和播放。

![NetVplayer 设置中的扩展支持页面，显示扩展能力已就绪与重新检查按钮](website/assets/screen-extension-support-1.1.0.webp)

在“设置 → 扩展支持”看到“扩展能力已就绪”后，即可继续配置自己的内容入口。遇到异常时选择“重新检查”。

![NetVplayer 1.1.0 内容来源实际运行截图：在线内容、影视配置链接与直播频道列表](website/assets/screen-content-sources-1.1.0.webp)

进入“设置 → 内容来源 → 在线内容”，在“影视配置链接”中粘贴自己的配置并点击“加载影视”；直播列表填写在“直播频道列表”，点击“加载直播”。截图中的私人配置已遮挡，实际加载结果以应用显示为准。

从源码构建需要 Xcode 和 Homebrew 提供的 libmpv 依赖：

```bash
swift build --package-path NetVplayer
swift test --package-path NetVplayer --disable-sandbox --no-parallel
```

生成隔离的无源发布应用：

发布前，在构建环境中设置项目专用的 `NETVPLAYER_TMDB_API_KEY` 或 `NETVPLAYER_TMDB_READ_ACCESS_TOKEN`，二选一；不要将真实凭据提交到仓库。打包会注入应用资源，缺少凭据时公开发布构建会明确失败。开发验收可使用 `--package-dev /absolute/path/to/fresh-output`，允许缺少 TMDB 凭据。详见 [TMDB 配置指南](TMDB_SETUP.md)。

本机可把项目凭据保存在仓库外的 `~/.config/netvplayer/tmdb.env`（文件权限 `0600`）；规范打包脚本自动读取，显式环境变量优先。具体格式、覆盖规则和安装包检查见 [TMDB 配置指南](TMDB_SETUP.md)。

```bash
bash NetVplayer/script/build_and_run.sh \
  --package-public /absolute/path/to/output
```

该命令会拒绝脏的公开检出和额外源码/资源输入，并检查运行库许可证、SBOM、签名和最终 `.app` 的无源边界。它不会替换或启动 `/Applications/NetVplayer.app`。

### 常见问题

- **支持 Intel Mac 吗？** 当前不支持。公开版本只提供 Apple Silicon arm64 构建。
- **为什么第一次打开会被 macOS 拦截？** 当前版本使用社区 ad-hoc 签名，没有使用 Apple Developer ID 公证。请确认应用名称和下载来源后完成首次放行。
- **软件自带视频源或直播列表吗？** 不自带。公开应用不内置、不提供也不托管视频源、直播列表、账号或媒体内容。
- **配置地址从哪里获得？** 请使用你自己维护、购买或明确获得授权的内容服务。项目不提供、推荐或代找视频源地址。
- **播放扩展需要手动安装吗？** 正常情况下不需要。首次准备或后续更新时，网络必须能连接 GitHub，否则下载与更新无法完成。已经安装并验证通过的组件在离线时仍可继续使用；状态异常时可在“设置 → 扩展支持”中选择“重新检查”。
- **配置和授权凭据保存在哪里？** 配置只保存在本机；1.1.0 的账号使用本机加密库，公开 1.0.12 的旧明文登录在升级时自动迁移，后续 ad-hoc 更新无需重复钥匙串授权。应用导出备份不包含密码、Token、Cookie 或密钥。加密库由当前用户的文件权限保护，不提供应用隔离。
- **NAS 和本地影片怎么显示海报墙？** 添加文件服务后，在首页选择该服务，切到“媒体库”并添加目录、类型和信息来源；保存后开始扫描。右键海报可修正影视信息，来源菜单可重新匹配。扫描和信息匹配均可取消，失败会保留已有资料。
- **TMDB 必须填令牌吗？** 普通用户无需填写。发布方统一提供 NetVplayer 专用应用凭据；个人 API Key 或 Read Access Token 仅作为高级设置中的可选覆盖。豆瓣遇到网页验证时，可在应用内正常完成验证后恢复匹配。
- **为什么错误提示不再显示 Android、Provider 或播放器内部名称？** 这些属于兼容和诊断实现，不是用户可执行的问题说明。普通界面会说明配置、来源、网络、授权或播放出了什么问题，并提示重试、切换来源/线路或重新授权；技术细节继续保留在脱敏诊断中。
- **这是 FongMi、影视仓或 TVBox 的官方 Mac 版吗？** 不是。NetVplayer 是独立的 Swift/macOS 实现，与这些项目不存在隶属或官方合作关系。
- **遇到问题如何反馈？** 使用应用内“问题反馈”生成脱敏信息并描述复现步骤。不要公开账号、Token、Cookie 或完整配置地址。
- **支持自动错误上报吗？** 配置了 Sentry 的构建可自动发送崩溃堆栈、版本、固定数字错误维度和有限操作步骤，并对起播耗时进行 5% 采样。可恢复的播放错误只作为诊断步骤记录，所有恢复方式耗尽后才创建问题。可在“设置 → 问题反馈 → 自动诊断”关闭；账号凭据、媒体名称、播放地址、原始错误正文和完整日志都不会发送。未配置 Sentry 的构建不发送自动诊断。

### 仓库结构

| 路径 | 用途 |
| --- | --- |
| `NetVplayer/` | macOS 应用与 Swift Package 模块 |
| `provider-sdk/` | 公开 wire、manifest、catalog 和 distribution Schema 与开发指南 |
| `provider-runners/` | Java、Node.js、QuickJS 和 Python Runner 合同 |
| `script/` | 构建、签名、沙盒、边界审计与发行检查 |
| `website/` | 项目官网及真实产品截图 |

### 致谢

感谢 [FongMi/TV](https://github.com/FongMi/TV) 项目及其贡献者。FongMi 对 TVBox 配置、CatVod 生命周期、播放解析和本地代理行为的长期实践，为 NetVplayer 的兼容性研究和测试合同提供了重要参考。

NetVplayer 与 FongMi/TV 没有隶属或官方合作关系。NetVplayer 使用独立的 Swift/macOS 实现，官方公开源码与发布应用不包含 FongMi 的 GPL 源码、Android JAR/Dex/so 或其运行时。

### 参与项目

提交代码或诊断前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md) 和 [SECURITY.md](SECURITY.md)。NetVplayer 使用 [MIT License](LICENSE) 发布；第三方组件继续适用各自的许可证和声明。

---

## English

### A native media player for macOS

NetVplayer 1.1.0 is a native macOS media player built with SwiftUI and an embedded `libmpv` playback core. It brings discovery, details and episodes, federated search, video on demand, live playback, subtitles, audio tracks, and viewing history into one desktop experience while keeping content entry points and access credentials under the user's control.

**NetVplayer 1.1.0 (build 14)**, the latest application shell source, and all five **Provider 1.1.0** packages were released on 2026-10-07. The stable application download, public source, and extensions are all updated. The features below are available in the downloaded application and in builds of the current main branch.

| Component | Current version | Get it |
| --- | --- | --- |
| Stable application | 1.1.0 | [Latest GitHub Release](https://github.com/spudhero/NetVplayer/releases/latest) |
| Public application shell source | 1.1.0 | [main](https://github.com/spudhero/NetVplayer/tree/main) · [Update notes](RELEASE_NOTES_1.1.0.md) |
| Signed playback extensions | 1.1.0 | [Provider Distribution](https://github.com/spudhero/NetVplayer-Provider-Distribution/releases) |

### Project background

FongMi/TV, OK影视, 影视仓, and TVBox primarily serve the Android ecosystem. I could not find a macOS version that matched how I wanted to use a desktop media app, so I started NetVplayer with SwiftUI and libmpv.

The goal is not to copy a phone or TV interface. NetVplayer reorganizes discovery, search, episode selection, on-demand playback, and live playback as a native Mac experience. It is not an official Mac edition of those projects and has no affiliation or official partnership with them. Their open-source work remains an important compatibility reference, while NetVplayer uses an independent Swift/macOS implementation.

[Read the release and fix history](CHANGELOG.md#english). The README stays focused on current capabilities, installation, and stable usage guidance.

You can add your own compatible configuration, Xtream-compatible service, or supported cloud-drive account. A fresh installation stays empty until the user adds an entry point. Saved configurations can be restored on later launches.

The 1.1.0 application renames Data Sources to Content Sources, with same-page groups and quick navigation for Online Content, Cloud Drive Accounts, NAS / Local, and Search & Checks. Use links for video configurations or channel lists; Xtream services require the server address, username, and password supplied by the service. Cloud sign-in enables videos that require a drive account; NAS / Local connects your own video files. The older 1.0.12 release calls this menu Data Sources.

In version 1.1.0, add WebDAV, AList, OpenList, SMB, or a local folder under Settings → Content Sources → NAS / Local → Video File Locations. Test and save the connection, then select it from the home source menu to browse files or create movie, TV, and mixed libraries. Credentials are encrypted in a local vault; local folders use persistent access bookmarks. Local NFO files and artwork take priority, with Automatic, TMDB, Douban, and Local Only metadata options. Publisher builds provide the TMDB application credential; ordinary users do not need a token. Development builds without it can use Douban and local metadata. See the [TMDB setup guide](TMDB_SETUP.md) for publisher and optional personal credentials.

Catalogs, details, and posters use clearable performance caches to make repeat navigation faster. Expired lists stay visible while refreshing, and slow cloud-drive details show movie metadata before episode expansion finishes in the background. Clearing performance caches preserves web sessions, configurations, history, favorites, and extensions; website cookies and data are removed only by the separate Clear Web Sessions action.

### The viewing experience

- **Details, routes, and episodes:** browse metadata, multiple playback routes, and naturally sorted episodes in one view.
- **Native playback controls:** use libmpv with subtitle, audio-track, speed, aspect-ratio, and compact-window controls.
- **Federated search:** search only across content entry points the user has already connected and selected.
- **Live playback:** use a dedicated player window with channel groups, same-channel route merging, and an on-demand channel guide.
- **Personal themes:** choose from the built-in appearance catalog without changing the underlying native interaction model.

The screenshots above come from the running application and are also used by the [project website](https://spudhero.github.io/NetVplayer/).

In 1.1.0, load a JSON, M3U or TXT address in Settings → Content Sources → Online Content → Video & Live TV Links → Live Channel List. Supported Formats & Examples explains the input formats. When a JSON configuration contains several live sources, choose one from the Live Source menu below the address or at the top of the live player. The app remembers your choice; a failed source can be retried or replaced by selecting another.

### User-owned content

NetVplayer supplies playback, connection, and compatibility capabilities. It does not operate a content service or obtain access rights for users.

- The public repository and release application contain no video catalogs, live channel lists, default configurations, or media files.
- Configuration URLs, site lists, accounts, and credentials are supplied by the user and remain within local application boundaries.
- Users must access only content they are authorized to use and comply with applicable law and service terms.
- Provider extensions participate only after an exact match against user-supplied configuration. They cannot silently add content entry points.
- The 1.1.0 application encrypts cloud-drive and Xtream credentials locally; history, favorites, and app exports retain only credential-free resource identities. Plaintext sign-ins from public 1.0.12 are migrated automatically and removed only after verification. The vault uses the current user's file permissions without per-app isolation.
- Users can add their own Xtream-compatible service for Movies, Series, search, and basic live channels. Server differences still apply.
- Application-owned UI ships in Simplified Chinese and English. Provider-supplied content names remain unchanged.

### Verified extensions

Providers are separate from the main application. NetVplayer considers releases only from its pinned HTTPS index, then verifies the index signature, archive SHA-256, manifest signature, protocol version, application/macOS/architecture compatibility, declared assets, sandbox launcher, and revocation state before activation.

The current public shell automatically installs only Providers that declare `user-configured-only`. The runtime, Runner, Provider, and dependencies must all live inside the signed package. Runners never download code or install dependencies at runtime. Any other user-configured policy requires separate shell and release review and cannot use the automatic activation path.

Settings reports component, cache, and user-data storage separately. Users can remove old versions or disable and uninstall recognized components while preserving accounts, Provider state, configurations, history, and unknown files. Interrupted maintenance remains recoverable.

### Provider releases

All five Provider 1.1.0 packages are published for **macOS 14+ / Apple Silicon arm64**. The application normally installs and updates compatible packages automatically. Select Settings → Verified Extensions → Check Again to check for updates; historical compatible versions remain in the official index.

| Provider | Version | Minimum application version |
| --- | --- | --- |
| [Java catalog](https://github.com/spudhero/NetVplayer-Provider-Distribution/releases/tag/provider-netvplayer.catalog.java-v1.1.0-arm64) | 1.1.0 | 1.0.0 |
| [JavaScript catalog](https://github.com/spudhero/NetVplayer-Provider-Distribution/releases/tag/provider-netvplayer.catalog.javascript-v1.1.0-arm64) | 1.1.0 | 1.0.0 |
| [Python catalog](https://github.com/spudhero/NetVplayer-Provider-Distribution/releases/tag/provider-netvplayer.catalog.python-v1.1.0-arm64) | 1.1.0 | 1.1.0 |
| [QuickJS catalog](https://github.com/spudhero/NetVplayer-Provider-Distribution/releases/tag/provider-netvplayer.catalog.quickjs-v1.1.0-arm64) | 1.1.0 | 1.0.0 |
| [Configurable Python](https://github.com/spudhero/NetVplayer-Provider-Distribution/releases/tag/provider-netvplayer.configurable.python-v1.1.0-arm64) | 1.1.0 | 1.0.0 |

Python catalog 1.1.0 includes the latest compatibility fixes and requires the updated playback support in application 1.1.0. Provider implementation sources remain private; signed bundles and the [official stable index](https://spudhero.github.io/NetVplayer-Provider-Distribution/stable/index.json) are publicly distributed.

### Architecture

`Models` and `ApplicationCore` own cross-module data and pure decisions. Platform engines handle configuration, networking, Providers, cloud drives, parsing, and live playback. Every playback entry point is normalized into a `PlaySpec` before `PlayerEngine` sends it to libmpv. Ordinary UI maps internal failures to a plain-language problem and next action, while `Diagnostics` receives only fixed error codes, stages, and bounded interaction steps allowed by the privacy gate. The diagram in the Chinese section shows the complete boundary; see the [architecture guide](ARCHITECTURE.md) for module responsibilities, Provider data flow, and local proxy routes.

### Provider SDK

The public SDK is for building **Provider extensions**. It is not a player-control SDK for embedding NetVplayer in another application. It includes:

- Swift `ProviderSDK` types and JSON Schemas for protocol v1, manifests, catalogs, source descriptors, and distribution indexes;
- Runners for Java 21, Node.js 22.20.0, QuickJS 2026-06-04, and Python;
- fixtures and tools for signing, packaging, structural validation, runtime validation, and release checks.

Start with the [Provider SDK development guide](provider-sdk/README.md), which runs a network-free Python fixture before introducing runtime-specific packaging. See the [Provider runners reference](provider-runners/README.md) for implementation constraints.

### Download and build

The current 1.1.0 release targets macOS 14 or later on Apple Silicon. Download it from the [project website](https://spudhero.github.io/NetVplayer/) or the [latest GitHub Release](https://github.com/spudhero/NetVplayer/releases/latest).

The app checks for application updates and marks the version in the sidebar and Settings when a new release is available. Open the version, review the update, and select Update to download and verify it in the background. Installation happens when the app normally quits. Version 1.0.8 and earlier need one manual installation of 1.0.9 or later to gain in-app updates. The current ad-hoc signature may still require macOS first-open or installation approval.

#### Beginner installation

1. Open Apple menu → About This Mac. Confirm that the chip is an Apple M-series chip and that the system is macOS 14 or later. The current public build does not support Intel Macs.
2. Download the latest release file whose name contains `macos-arm64.zip`.
3. Double-click the ZIP and move `NetVplayer.app` into Applications.
4. On first launch, right-click NetVplayer in Finder, choose Open, and confirm Open once more.
5. If macOS still blocks the app, open System Settings → Privacy & Security, confirm the application name, and choose Open Anyway. The community ad-hoc build normally needs this approval only once.
6. Wait for Verified Extensions to become ready. The first preparation and later updates require a network connection that can reach GitHub. After the components are downloaded and verified, installed components that remain valid can continue to work offline.
7. Open Settings → Content Sources → Online Content and load a compatible configuration that you are authorized to use.

![NetVplayer Verified Extensions screen showing that extension support is ready and the Check Again button](website/assets/screen-extension-support-1.1.0.webp)

Continue to your content configuration after this screen reports that extension support is ready. Use Check Again if the status reports a problem.

![Screenshot of NetVplayer 1.1.0 showing Content Sources, Online Content, video configuration links, and channel lists](website/assets/screen-content-sources-1.1.0.webp)

Open Settings → Content Sources → Online Content. Enter your authorized configuration in Video Configuration Link and select Load Video; use Live Channel List and Load live channels for channels. Private configurations in the screenshot are redacted; the application shows the actual result after loading.

Building from source requires Xcode and the Homebrew libmpv dependencies:

```bash
swift build --package-path NetVplayer
swift test --package-path NetVplayer --disable-sandbox --no-parallel
```

Create an isolated source-free release bundle:

For local packaging, keep the project TMDB credential outside the checkout in `~/.config/netvplayer/tmdb.env` with mode `0600`. The packaging script loads it when no explicit TMDB environment value is supplied. See the [TMDB setup guide](TMDB_SETUP.md) for the file format and bundle checks.

```bash
bash NetVplayer/script/build_and_run.sh \
  --package-public /absolute/path/to/output
```

The command rejects a dirty public checkout and unexpected source or resource inputs. It verifies runtime licenses, SBOM data, signatures, and the source-free boundary of the final `.app`. It does not replace or launch `/Applications/NetVplayer.app`.

### FAQ

- **Does it support Intel Macs?** Not currently. The public release is an Apple Silicon arm64 build.
- **Why can macOS block the first launch?** The current release uses community ad-hoc signing rather than Apple Developer ID notarization. Verify the application name and download source before approving the first launch.
- **Does the app include video sources or live channel lists?** No. The public app does not bundle, provide, or host catalogs, live lists, accounts, or media.
- **Where do configuration URLs come from?** Use only services that you maintain, purchase, or are explicitly authorized to access. The project does not provide or recommend source URLs.
- **Do I install Provider extensions manually?** Normally no. The initial preparation and later updates require network access to GitHub; without it, downloads and updates cannot complete. Components that are already installed and verified can continue to work offline. Use Settings → Verified Extensions → Check Again when the status reports a problem.
- **Where are configurations and credentials stored?** Configurations and authorization credentials remain on the Mac. Non-sensitive backups exclude cloud-drive tokens and cookies.
- **Why do errors no longer show Android, Provider, or player implementation names?** Those names describe compatibility internals rather than an action the user can take. Ordinary messages identify the configuration, source, network, authorization, or playback problem and suggest retrying, switching a source or route, or authorizing again. Technical details remain in redacted diagnostics.
- **Is this an official Mac version of FongMi, OK影视, 影视仓, or TVBox?** No. NetVplayer is an independent Swift/macOS implementation with no affiliation or official partnership.
- **How do I report a problem?** Use the in-app Problem Report flow to generate redacted diagnostics and describe the reproduction steps. Never publish accounts, tokens, cookies, or full configuration URLs.
- **Does the app report errors automatically?** Builds configured with Sentry can send crash stacks, app versions, fixed numeric failure dimensions and a limited trail of diagnostic steps, with 5% sampling for playback startup timing. Recoverable playback failures remain diagnostic steps; an issue is created only after recovery is exhausted. Disable this in Settings → Problem Report → Automatic Diagnostics. Credentials, media titles, playback URLs, raw error text and full logs are excluded. Builds without a Sentry configuration do not send automatic diagnostics.

### Repository layout

| Path | Purpose |
| --- | --- |
| `NetVplayer/` | macOS application and Swift Package modules |
| `provider-sdk/` | Public wire, manifest, catalog, and distribution Schemas plus the development guide |
| `provider-runners/` | Java, Node.js, QuickJS, and Python Runner contracts |
| `script/` | Build, signing, sandbox, boundary-audit, and release checks |
| `website/` | Project website and real product screenshots |

### Acknowledgements

Thank you to the [FongMi/TV](https://github.com/FongMi/TV) project and its contributors. Its long-running work on TVBox configuration, the CatVod lifecycle, playback resolution, and local proxy behavior provided valuable references for NetVplayer's compatibility research and test contracts.

NetVplayer is not affiliated with or endorsed by FongMi/TV. NetVplayer uses an independent Swift/macOS implementation. The official public source and release application do not bundle FongMi GPL source, Android JAR/Dex/so artifacts, or its runtime.

### Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md) before submitting code or diagnostics. NetVplayer is released under the [MIT License](LICENSE). Third-party components retain their own licenses and notices.
