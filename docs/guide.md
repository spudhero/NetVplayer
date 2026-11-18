# NetVplayer 使用指南 / User Guide

[中文](#中文) · [English](#english) · [返回介绍](../README.md) · [官网](https://spudhero.github.io/NetVplayer/) · [架构](../ARCHITECTURE.md)

## 中文

### 先安装，再添加自己的内容

1. 下载[最新正式版](https://github.com/spudhero/NetVplayer/releases/latest)的 `macos-arm64.zip`，解压并将应用移入“应用程序”。需要 Apple Silicon 和 macOS 14 或更新系统。
2. 社区包使用 ad-hoc 签名。首次被系统阻止时，先核对下载来源，再按系统提示到“隐私与安全性”选择“仍要打开”；部分系统也支持 Finder 右键“打开”。
3. 进入“设置 → 扩展支持”。首次安装和扩展更新需要能连接 GitHub；正常情况下自动完成，失败时选择“重新检查”。已安装且校验有效的组件可在离线时继续使用，内容服务本身仍可能需要联网。
4. 打开“设置 → 内容来源”，选择下文对应的入口。应用不附带内容，首次首页为空是正常状态。

本指南截图取自实际安装的 2.0.6。来源信息在图片中直接打码，海报与影视名称模糊处理；播放器显示自制本地演示视频。空白连接表单用于说明操作入口，不表示已连接真实账号或 NAS。

### 在线点播、直播与搜索

打开“设置 → 内容来源 → 在线内容”（页面标题为“在线视频与直播”）。

- 将自己的影视配置填入“影视配置链接”，点击“加载影视”。返回点播首页，从左上来源菜单切换已配置的来源。
- 将 JSON、M3U 或 TXT 直播列表填入“直播频道列表”，点击“加载直播”。配置包含多个直播源时，可在“直播源”菜单中选择。
- 使用 Xtream 时，在“影视与直播账号（Xtream）”填写服务方提供的地址、用户名和密码，选择“验证并连接”。
- 点击首页右上角搜索，输入关键词；也可粘贴支持的网盘分享文本。搜索范围在“内容来源 → 搜索与检查”调整，只搜索你已经配置的来源。

![影视与直播配置入口；私人链接已遮挡](../website/assets/overview/content-sources.webp)

详情页可切换原详情与 TMDB 资料，选择播放线路、资源组和剧集。右上方切换宫格／列表或正倒序。文件大小仅在来源目录已提供时显示；没有大小的条目留空。出现“需授权”时，按对应网盘提示完成自己的登录。

![线路、资源分组与选集](../website/assets/overview/detail.webp?v=057d310747)

直播播放器的“频道指南”可按分组浏览或搜索频道，“节目单”查看可用 EPG，播放期间可切换线路、调整音量和进入小窗。指南中的预览是缓存画面，使用“刷新可见画面”更新；没有缓存时仍可选择频道。节目数据取决于列表或服务提供的 EPG。

![频道指南与搜索，停止播放后的实际界面](../website/assets/overview/live-guide.webp)

### 个人网盘目录

1. 在“内容来源 → 网盘账号”选择所需服务并登录。**个人目录支持夸克、UC、阿里云盘、百度网盘和 115**。
2. 点击“添加网盘目录”，选择服务。若提示未登录，先完成该网盘的授权。
3. 进入文件夹选择页，选择一个或多个目录加入媒体库。之后从首页已添加的媒体入口浏览。
4. 原生网盘账号用于 Mac 实现与个人目录；**Android 原版需在视频源内按提示扫码，其授权独立保存**。

![添加个人网盘目录](../website/assets/overview/cloud-folders.webp)

“登录网盘”页面还有其他受支持账号入口，但账号可登录不等于该服务支持个人目录。本指南列出的五种服务才是当前“添加网盘目录”范围。分享目录是否可读、原片是否可播，还受账号权限、验证状态、限速和服务规则影响。

### NAS、文件服务器与本机文件

在“内容来源 → NAS / 本地”（页面标题为“NAS 与本地媒体”）点击“添加连接”：

1. 填写便于识别的名称，选择本机文件夹、SMB、WebDAV、AList、OpenList、FTP／FTPS 或 SFTP。
2. 填写地址以及服务需要的账号信息。本机文件夹通过系统选择器授权访问；远程服务使用你自己的连接信息。
3. 选择“测试连接”。通过后点击“连接并选择文件夹”，选择一个或多个目录。
4. 连接只需建立一次，电影、剧集等文件夹可分别管理。按目录用途设置媒体库类型和资料来源，从首页进入浏览。

![文件位置的连接方式与两步流程](../website/assets/overview/file-services.webp)

只看单个本机视频时，使用“文件 → 打开文件…”或将视频拖入应用。如右上出现“待打开的文件”，展开并选择文件开始播放，不必先建媒体库。

### Emby、Jellyfin、Plex、极影视与飞牛影视

这些服务使用已有的服务器媒体库。进入“内容来源 → 在线内容”，向下找到“媒体服务器”：选择类型，填写服务地址和登录信息，点击“验证并连接”。成功后从首页来源菜单选择对应服务器，再浏览电影、剧集和详情。

![媒体服务器类型与登录表单](../website/assets/overview/media-servers.webp)

媒体服务器与 SMB／WebDAV 是不同接入方式：前者由服务端组织媒体资料，后者让应用读取文件目录并整理媒体库。极影视／飞牛影视等服务的真实 NAS 和不同版本兼容性尚未全面验收，连接入口的存在不保证每台设备可用。

### 海报、影片资料与媒体库

为电影、剧集或混合目录创建媒体库后，可补充海报、简介、评分并手动匹配资料。“内容来源 → NAS / 本地 → 海报与影片资料”设置新建库的默认资料来源，已有库在编辑时分别调整。

“自动选择”优先使用视频旁的本地资料，再尝试可用的 TMDB 和豆瓣；只用本地资料也能整理与播放。正式包提供项目 TMDB 凭据，普通用户无需填写令牌。元数据服务仅补充影片资料，不提供视频内容。

### 播放、音画与字幕

播放器底部集中提供选集、前后跳转、片头片尾、字幕、音轨、比例、倍速、音量、设置、小窗和全屏。章节信息取决于媒体；历史记录保存续播位置。

![实际播放器；画面为自制本地演示视频](../website/assets/overview/player.webp)

| 调整项 | 操作位置与说明 |
| --- | --- |
| 字幕和音轨 | 播放器 → 字幕／音轨，选择主字幕、副字幕或所需音轨 |
| 字幕样式 | 设置 → 播放偏好 → 播放行为 → 字幕，调整字体、大小、位置、描边；图片字幕使用缩放 |
| 文本字幕翻译 | 播放器 → 字幕 → 文本字幕翻译，选择 SRT／ASS／SSA／VTT 文件和语言，可跟随播放或翻译整份字幕 |
| 双语与导出 | 翻译面板 → 导出字幕，选择格式及“双语字幕”；译文完整后可导出，原字幕可随时导出 |
| 图片字幕／音频识别 | 播放器 → 字幕 → 图片字幕／音频识别，按面板提示选择输入并准备所需权限或资源 |
| 在线字幕 | 播放器 → 字幕 → 在线搜索，需要可用的外部字幕服务 |
| HDR 与 SDR | 设置 → 播放偏好 → 色彩与视频输出，选择跟随系统、临时 HDR 或 SDR 映射；播放器中可查看实际输出 |
| 音频设备 | 设置 → 播放偏好 → 音频输出与设备，按当前设备选择输出策略 |
| 对白清晰度 | 设置 → 播放偏好 → 对白清晰度，选择关闭、轻度、中度或较强；“恢复原音频”撤销处理 |
| 弹幕 | 设置 → 播放偏好 → 播放行为 → 弹幕手动入口；默认关闭，开启后在播放器中手动搜索 |

| 文本字幕翻译 | 对白清晰度 |
| :---: | :---: |
| <img src="../website/assets/overview/subtitles.webp" width="600" alt="本机字幕翻译与双语导出"> | <img src="../website/assets/overview/dialogue.webp" width="720" alt="对白处理强度菜单"> |

Apple 本机翻译需要 **macOS 15+** 和可用语言资源；macOS 14 可使用原字幕及其导出功能。对白增强使用音频处理，并不分离人声与音乐。临时 HDR、HDR／杜比视界呈现及音频格式的实际输出都依赖当前素材、系统、显示器和音频链路；以实际输出状态为准。

### 选择 Mac 实现或 Android 原版

1. 打开“设置 → 扩展支持 → 来源解析方式”。
2. 在“下次启动使用”选择 Mac 实现或 Android 原版，按提示重启应用。
3. Android 原版首次加载配置时自动下载并校验完整签名环境。保持 GitHub 可访问，完成后重新选择内容。
4. 当前页面会显示“本次启动”和“实际解析方式”；切换不会在正在运行的会话里立即生效。

![来源解析方式、Android 组件与扩展状态](../website/assets/overview/extensions.webp)

Mac 模式不下载或调用 Android 环境；Android 模式在兼容环境中执行用户配置的原始 JAR。两者独立运行，不在失败后自动改用另一种实现。本机文件、媒体服务器和标准内容接口不受此选项影响。应用界面与实际媒体播放始终使用原生 Mac 实现。

所需扩展通常自动维护。可用的本机版本与在线更新状态分别显示；首次准备失败可“重新检查”。手动安装和回滚属于高级操作，需按提示重启，详见[扩展发布](https://github.com/spudhero/NetVplayer-Provider-Distribution/releases)。

### 个性化、更新与反馈

- “设置 → 外观”选择 14 种主题之一，选择自动保存。
- 在设置顶部输入“字幕”“HDR”等关键词，点击结果直接定位。
- 应用版本旁出现更新提示时，确认后后台下载与校验，正常退出后安装。
- 配置备份不包含密码、Token 或 Cookie；恢复配置后可能需要重新登录。
- “设置 → 问题反馈”可生成脱敏信息和关闭自动诊断。反馈时说明应用版本、使用的解析方式、复现步骤和错误提示，避免上传未打码的链接或账号信息。

![设置搜索与结果定位](../website/assets/overview/settings-search.webp)

### 使用条件与限制

- 需要自己有权访问的配置、服务与媒体。配置加载成功或目录展开不代表每一条线路都可播放。
- 网盘登录、个人目录、原片持续播放、不同 NAS／服务端版本、全部来源和 macOS 14 实机的完整验收仍有未覆盖范围。部分服务可能返回空结果、验证要求、限速或媒体请求拒绝。
- HDR／杜比视界标签说明素材或格式信息，实际显示取决于设备和当前输出路径。音频输出能力同样不能仅从文件名判断。
- 本机翻译、图片／音频识别、在线字幕和弹幕需要相应的系统能力、权限、语言资源或外部服务；没有对应数据时不会凭空生成字幕或节目内容。
- 图文介绍说明当前功能与用法；具体版本修复和验证范围见[发布说明](releases/README.md)。

---

## English

### Install and add content

Download the versioned `macos-arm64.zip` from the [latest Release](https://github.com/spudhero/NetVplayer/releases/latest), extract it and move the app to Applications. Apple Silicon and macOS 14+ are required. Community builds use ad-hoc signing; verify the download source and follow macOS Privacy & Security → Open Anyway if blocked.

Wait for Settings → Verified Extensions to prepare the required components. First installation and updates need GitHub access; use Check Again if preparation fails. An empty first-run home screen is expected until you add content.

The screenshots above are real captures from installed 2.0.6. Private source values are masked in the image files, artwork and media names are blurred, and the player displays a self-created local demo. Empty forms document the interface, not successful real-account connections.

### Connect your content

| Content | Steps |
| --- | --- |
| Video configuration or live list | Settings → Content Sources → Online Content; load your configuration or JSON/M3U/TXT list, then select the source on Home |
| Xtream | Online Content → video/live accounts; enter the service address and credentials, then Verify and Connect |
| Personal cloud folders | Cloud Drive Accounts → authorize Quark, UC, Aliyun, Baidu or 115 → Add Cloud Folder → choose one or more folders |
| NAS / file service | NAS / Local → Add Connection → choose SMB, WebDAV, AList, OpenList, FTP/FTPS or SFTP → Test → Connect and Select Folders |
| Local folder or individual file | Add a local folder through the system picker, or use File → Open / drag a video into the app; select a pending file entry if shown |
| Media server | Online Content → Media Servers → choose Emby, Jellyfin, Plex, Zspace Media or FnOS Media, supply your server and sign in |

File services expose folders for the app to browse and organize. Media servers supply their own catalogs and metadata. Personal folder support currently covers the five services listed above; a separate account-login entry does not imply personal-folder support.

Poster libraries support movie, TV and mixed folders. Set metadata defaults under NAS / Local, or edit an existing library separately. Auto mode prioritizes local metadata, then available TMDB and Douban results. Official builds supply the TMDB application credential. Metadata services supply information rather than video.

### Browse, search and watch

Use the Home source menu to choose a configured entry. Search across configured sources or paste a supported cloud share. Search scope is adjustable under Content Sources. In details, choose a route, resource group and episode; switch grid/list view or sort order. File sizes appear only when supplied by the directory. Resume later from History.

The live player provides channel groups, channel search, programme guides, route selection and a floating window. Channel previews are cached rather than live; EPG availability depends on the source or service.

The native player exposes subtitles, main/secondary tracks, audio tracks, speed, aspect ratio, chapter navigation, intro/outro skipping, floating mode and fullscreen. Playback Preferences contains subtitle appearance, video output, audio devices and dialogue enhancement.

For text translation, open Player → Subtitles → Text Subtitle Translation, choose an SRT/ASS/SSA/VTT file, languages, and follow-playback or whole-document translation. Export the original at any time, or the completed translation, optionally bilingual. Apple local translation requires **macOS 15+** and available language resources. The subtitle menu also provides image-subtitle/audio recognition and online search, each subject to its own requirements. Danmaku is disabled by default and uses manual search when enabled.

### Choose source execution

Under Settings → Verified Extensions → Source Execution, choose Mac implementation or Original Android, then restart. Mac mode uses native adapters or signed extensions without Android. Original Android executes the JAR referenced by user configuration in an independent compatibility environment; first use downloads and verifies the complete signed runtime from GitHub.

One selected implementation handles catalog, details and playback resolution. There is no automatic fallback to the other mode. Local files, media servers and standard content APIs are independent of this setting. Both modes keep the native Mac interface and media player. Native cloud credentials and Android source authorization are stored separately.

### Appearance, updates and support

Choose among 14 themes under Appearance. Search Settings to jump to a control. In-app updates download and verify in the background after confirmation and install on normal exit. Backups exclude passwords, tokens and cookies. Use Problem Report for redacted diagnostics or to disable Automatic Diagnostics.

### Conditions and limits

Source loading or a readable directory does not guarantee playback. Real cloud accounts, sustained original-stream playback, all NAS/server versions, every source and macOS 14 hardware have not all passed complete acceptance. Upstream validation, rate limits, empty results and rejected media requests can still occur.

HDR/Dolby Vision and audio output depend on media, system, display and output devices; use actual output status rather than filename labels. Translation, recognition, online subtitles and danmaku require the relevant system capability, permission, resource or service. For individual fixes and validation scope, consult the [release notes](releases/README.md).
