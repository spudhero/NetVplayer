# NetVplayer Release History

This file records user-visible release and fix history. For installation requirements and current usage, see the [README](README.md).

## 中文

### [1.0.12](https://github.com/spudhero/NetVplayer/releases/tag/1.0.12) - 2026-09-23

- 分类与推荐列表在 5 分钟内直接复用结果，5 至 30 分钟先显示缓存再后台刷新，并恢复同一筛选组合已经加载的连续分页；刷新按钮可主动获取最新内容。
- 海报改用独立的 64 MiB 内存和 256 MiB / 7 天磁盘缓存，合并重复下载、限制并发，并在后台校验、预解码和按显示尺寸降采样。
- 详情结果缓存 10 分钟并支持悬停预取。签名扩展与本机玩偶详情先显示海报、标题和简介，网盘目录在后台并发展开，各线路完成后立即补齐剧集，不再由最慢分享阻塞整个页面。
- 多站搜索最多同时执行 6 个真实 Provider 操作，并使用不依赖 Provider 配合取消的硬截止；当前、稳定和响应更快的来源优先返回。
- 设置页现在准确显示海报、网络、分类和详情缓存。“清理性能缓存”保留登录状态、配置、历史、收藏、反馈和 Provider；“清除网页会话”单独删除 Cookie 与网站数据。
- 播放准备记录源站、网盘、解析、代理、mpv 提交和首个有效播放进度的阶段耗时，并在新播放规格准备完成前保留当前视频。

### [1.0.11](https://github.com/spudhero/NetVplayer/releases/tag/1.0.11) - 2026-09-22

- 修复 macOS 27 切换或断开音频设备时可能触发的 CoreAudio 崩溃；内嵌 libmpv 现在使用稳定的交错浮点音频格式初始化。
- 播放准备和内容目录加载遇到超时、断网、HTTP 429 或服务器临时错误时会自动重试一次，再决定是否向用户报告失败。
- 自动诊断现在把远端流、播放器和直播列表的可恢复故障保留为诊断步骤，只在所有播放恢复线路耗尽后创建问题，避免同一次故障拆成多个告警。
- 诊断事件增加错误阶段、重试次数、HTTP 状态、网络错误、网盘类型和播放线路等固定数字维度，便于定位问题，同时继续排除账号、地址、媒体名称和完整错误正文。

### [1.0.10](https://github.com/spudhero/NetVplayer/releases/tag/1.0.10) - 2026-09-21

- 修复普通本地构建遗漏扩展签名配置而误报“扩展暂时不可用”的问题；首次安装完成记录会结合已验签的本地包判断可用性，待升级版本单独保存，联网检查失败不再阻塞已有扩展的数据源恢复。
- 已保存点播源的首页从首帧显示准备或加载状态；首次扩展安装失败会阻止数据源加载并提供重试，不再闪现“请先配置视频源”。
- 修复直播停止或退出后再次进入只创建空播放器却不恢复频道的问题：每次打开直播窗口都会重新激活会话，并从已缓存列表恢复上次频道和线路；无频道时“打开频道指南”不再被透明视频手势层拦截。
- 修复短视频的片头跳过时间超过片长时无法起播的问题：正常视频仍直接从目标位置加载，越界时自动从头恢复一次。
- 扩展同步遇到网络错误时会明确显示需要重试；网盘业务失败不再被误报成“错误码 200”。
- 配置 Sentry 的构建新增默认开启、可在设置关闭的自动诊断：发送脱敏崩溃堆栈、固定错误码和有限诊断步骤，起播耗时按 5% 采样；不发送凭据、媒体名称、播放地址或完整日志。
- 配置、视频源、播放、直播、网盘授权、备份、扩展、更新、反馈和内嵌页面现在使用统一的错误提示：先说明发生了什么，再给出重试、切源、换线或重新授权等下一步，不再把 Android、`csp_`、Dex、FongMi、Provider、mpv、WebView、抓包或 relay 等内部术语直接显示给普通用户。
- 视频源与外部资源兼容状态改为“已兼容 / 部分可用 / 正在适配 / 源站暂不可用 / 配置不完整 / 暂不支持”等产品文案；设置页同时展示原因和建议。重复的 Android 运行时诊断字段、统计捷径和两套状态标题映射已删除，内部兼容枚举与诊断事件继续保留。
- 启动时先注册本机已安装的签名播放扩展，再恢复保存的数据源，避免偶发把已有 macOS 扩展支持的站点误判为 Android 专用源；联网更新仍在后台执行。
- 已安装扩展可用时，设置页明确显示“后台检查更新”，不再把联网检查呈现为播放能力仍在准备。
- 点播进入新剧集时会直接从片头或可验证的历史位置开始加载，并在目标画面到达前持续显示加载状态，避免先加载开头再二次跳转造成长时间黑屏；网盘转码/HLS 的后续跳转会使用关键帧定位，降低 `loading failed` 风险。
- 播放中途缓冲只显示独立的缓冲状态层，不再自动拉起或阻止隐藏标题栏和控制栏；播放器栏仅响应鼠标、点击、键盘、暂停及面板操作。
- 播放器控制栏自动收起时，仅在鼠标仍位于视频区域内隐藏指针，移到窗口其他区域后保持可见。
- 手动跳转后，在目标画面恢复且缓存暂停结束前保留圆形加载状态，避免旧画面静止时没有任何缓冲提示。
- 手动跳转期间清除上一个播放位置的缓存百分比和秒数；本地网盘流在圆形状态层显示本次跳转实际收到的数据量及平均接收速度。
- 圆形状态层区分“正在跳转”和“播放中缓冲”，避免将目标位置读取与线路吞吐不足导致的中途卡顿混淆。
- 修复并行 Range 拉流将部分缓存误判为完整命中时的空数据错误；夸克原文件在实测并发无吞吐增益后恢复原有拉流策略。

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

### [1.0.12](https://github.com/spudhero/NetVplayer/releases/tag/1.0.12) - 2026-09-23

- Category and recommendation results are reused for five minutes, shown immediately with background refresh for up to thirty minutes, and restore consecutive pages for each filter combination. A refresh button retrieves current content on demand.
- Posters now use a dedicated 64 MiB memory cache and 256 MiB seven-day disk cache with request coalescing, bounded downloads, validation, background decoding, and display-sized downsampling.
- Details are cached for ten minutes and prefetched on hover. Signed extensions and local WoGG pages show artwork, metadata, and descriptions first; each cloud-drive route becomes available as its episode expansion completes.
- Federated search runs at most six real Provider operations at once and enforces a hard deadline even when a Provider ignores cancellation. The active, healthier, and faster sources are searched first.
- Settings now reports poster, network, catalog, and detail caches separately. Clear Performance Cache preserves sign-ins, configurations, history, favorites, reports, and Providers; Clear Web Sessions separately removes cookies and website data.
- Playback startup records source, cloud-drive, parsing, proxy, mpv submission, and first valid playback-progress timing while keeping the current video until the next playback specification is ready.

### [1.0.11](https://github.com/spudhero/NetVplayer/releases/tag/1.0.11) - 2026-09-22

- Fixed a CoreAudio crash that could occur on macOS 27 when an audio device was switched or disconnected. The embedded libmpv core now initializes with the stable interleaved-float audio format.
- Playback preparation and catalog loading retry once for timeouts, offline transitions, HTTP 429 responses, and temporary server failures before presenting an error.
- Automatic diagnostics now keep recoverable remote-stream, player, and live-catalog failures as diagnostic steps and create an issue only after all playback recovery routes are exhausted, preventing one incident from becoming several alerts.
- Diagnostic events now include fixed numeric dimensions for failure stage, retry count, HTTP status, network error, cloud provider, and playback route while continuing to exclude accounts, URLs, media titles, and raw error text.

### [1.0.10](https://github.com/spudhero/NetVplayer/releases/tag/1.0.10) - 2026-09-21

- Fixed local builds omitting extension trust configuration and reporting extensions as unavailable. First-install completion is checked against verified local packages, pending upgrades are stored separately, and online update failures no longer block restoration of a saved source with valid extensions.
- A saved VOD source now shows preparation or loading from the first home-screen frame. An incomplete first extension installation blocks source loading and offers retry instead of briefly showing the configure-source prompt.
- Fixed live playback reopening into an empty player after stopping or exiting. Every live-window request now reactivates the session and restores the saved channel and route from the cached guide; the empty-state Open Channel Guide button is no longer blocked by the transparent video gesture layer.
- Videos whose intro-skip position exceeds their actual length now recover from the beginning once; valid starts still load directly at the requested position.
- Extension synchronization errors now reliably show retry guidance, and cloud-drive business failures are no longer mislabeled as error code 200.
- Builds configured with Sentry now enable automatic diagnostics by default, with an off switch in Settings: redacted crash stacks, fixed error codes, bounded diagnostic steps, and 5% sampling of playback startup timing. Credentials, media titles, playback URLs, and full logs are excluded.
- Configuration, source, playback, live, cloud authorization, backup, extension, update, feedback, and embedded-page failures now share one user-facing error map. Messages explain what happened and offer a next step without exposing internal Android, `csp_`, Dex, FongMi, Provider, mpv, WebView, capture, or relay terminology.
- Source and external-resource compatibility now uses product labels such as Compatible, Partially Available, Being Adapted, Source Temporarily Unavailable, Incomplete Configuration, and Unsupported, with a reason and suggested action in Settings. Duplicate Android-runtime report fields, count shortcuts, and parallel status-title mappings were removed while internal compatibility enums and diagnostic events remain intact.
- Installed signed playback extensions now register before the saved source is restored, preventing intermittent classification of supported macOS providers as Android-only while network updates continue in the background.
- Settings now identifies catalog refreshes as background update checks when installed extensions are already usable.
- VOD episodes now load directly at the intro-skip or validated history position and keep the loading state visible until the target frame arrives, avoiding the prolonged black screen caused by loading the beginning and then seeking again. Later seeks on cloud-drive transcode/HLS routes use keyframes to reduce `loading failed` errors.
- Mid-play buffering now displays only its independent activity overlay and no longer opens or pins the title and control bars; player chrome responds only to pointer, click, keyboard, pause, and panel interactions.
- Auto-hiding playback controls only hides the cursor while it remains over the video; the pointer stays visible in other window areas.
- Manual seeks now keep the circular loading state until playback restarts near the target and cache pausing ends, so a frozen previous frame no longer appears idle.
- During a manual seek, stale cache percentages and buffered-time values are cleared. Local cloud-drive streams show bytes actually delivered for this seek and their average transfer speed.
- The circular activity state now distinguishes seeking from mid-play buffering, so reading a target position is not confused with later stalls caused by insufficient stream throughput.
- Fixed an empty-data error when parallel Range streaming mistook a partial cache entry for a complete hit. Quark original-file playback keeps its prior streaming policy after parallel requests showed no throughput gain in the live test.

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
