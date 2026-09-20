# NetVplayer Release History

This file records user-visible release and fix history. For installation requirements and current usage, see the [README](README.md).

## 中文

### [1.0.9](https://github.com/spudhero/NetVplayer/releases/tag/1.0.9) - 2026-09-20

- 侧栏和设置页的版本号会提示新版本；确认更新后在后台下载、校验，并在应用正常退出后安装。
- 播放期间阻止显示器空闲变暗和休眠；暂停、结束或退出后恢复系统节能策略。

### [1.0.8](https://github.com/spudhero/NetVplayer/releases/tag/1.0.8) - 2026-09-18

#### 网盘起播与返回体验

- UC 个人盘原文件的安全探测改为最小 Range，并复用已经解析的个人盘记录，不再在起播前重复下载相同探测数据。
- MP4 读取文件尾部元数据后会复用已经完成的头部分段；慢速 UC CDN 下无需再次下载同一批起播数据。
- 玩偶详情页会并发展开多个网盘分享，同时保持原页面中的线路和剧集顺序。
- 从同站搜索结果进入播放时会保留原首页目录；退出播放器后恢复影片详情，不再回到空白“推荐”页。

### 1.0.7 开发里程碑 - 2026-09-18

1.0.7 的兼容性修复随后并入 1.0.8，没有单独发布 GitHub Release。

#### macOS 14 与扩展兼容性

- 内嵌 libmpv 及其依赖由 macOS 14 ARM 构建任务独立产出，macOS 14/15 不再因发布机版本过高而无法加载播放器。
- Provider 安全启动器显式以 macOS 14 为部署目标构建；Java 数据源兼容包可以在受支持系统上自动下载、验证并启用。
- 发布流程检查最终 App、动态库和 Provider 启动器的真实最低系统版本；高于公开兼容范围的产物会直接阻断发布。
- 启动时先恢复本机保存的数据源，Provider 网络更新继续在后台进行；若首次恢复确实缺少组件，同步完成后会自动重试。
- UC 扫码确认后直接用官方 `service_ticket` 建立并验证个人盘 Cookie，不再依赖易受网页结构变化影响的单次 iframe 注入。

更早版本及安装资产见 [GitHub Releases](https://github.com/spudhero/NetVplayer/releases)。

## English

### [1.0.9](https://github.com/spudhero/NetVplayer/releases/tag/1.0.9) - 2026-09-20

- The version in the sidebar and Settings now marks available app updates. Confirming an update downloads and verifies it in the background, then installs it after the app normally quits.
- Playback prevents the display from idle dimming or sleeping; pausing, ending playback, or quitting restores the system's energy-saving policy.

### [1.0.8](https://github.com/spudhero/NetVplayer/releases/tag/1.0.8) - 2026-09-18

#### Cloud-drive startup and navigation

- UC personal-drive originals now use a minimal safety probe and reuse the resolved saved-file record instead of downloading the same probe data twice before playback.
- MP4 playback reuses completed head ranges after reading tail metadata, avoiding a second download of the startup window on slow UC CDN paths.
- WoGG detail pages expand multiple cloud-drive shares concurrently while preserving the source order of routes and episodes.
- Opening a same-site search result keeps the loaded home catalog, and leaving playback restores the movie detail instead of an empty Recommended page.

### 1.0.7 development milestone - 2026-09-18

The 1.0.7 compatibility work was folded into 1.0.8 and was not published as a separate GitHub Release.

#### macOS 14 and extension compatibility

- The embedded libmpv runtime and its dependencies are produced separately on macOS 14 ARM, preventing macOS 14/15 from receiving libraries built for a newer deployment target.
- Provider sandbox launchers explicitly target macOS 14, allowing the Java compatibility package to download, verify, and activate on supported systems.
- Release checks inspect the actual deployment target of every packaged app binary, dynamic library, and Provider launcher and reject incompatible artifacts.
- Saved data sources restore before background Provider updates finish, with one automatic retry after synchronization when a required component was initially unavailable.
- UC QR confirmation exchanges the official `service_ticket` directly for a validated personal-drive Cookie instead of relying on a one-shot iframe bridge.

See [GitHub Releases](https://github.com/spudhero/NetVplayer/releases) for earlier versions and downloadable artifacts.
