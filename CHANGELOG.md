# NetVplayer Release History

This file records user-visible release and fix history. For installation requirements and current usage, see the [README](README.md).

## 中文

### 1.1.0（2026-10-07）

本次正式版本汇总以下主干变更，构建号为 14。版本概览见[发布说明](RELEASE_NOTES_1.1.0.md)。

#### 2026-10-07

- 正式发布 Apple Silicon / macOS 14+ 主程序安装包 1.1.0（构建 14），同步签名 Sparkle 更新清单、SBOM 和 SHA-256 校验和；官网和应用内更新入口指向新版。
- 最新主程序壳源码进入公开 main，包含光影与 AI 短漫剧兼容、章节预览、内容来源、文件服务与媒体库等更新；公开主干完整回归与发行门禁通过。
- Java、JavaScript、Python、QuickJS 目录和可配置 Python 五种签名 Provider 1.1.0 已在 [Distribution](https://github.com/spudhero/NetVplayer-Provider-Distribution/releases) 正式发布，官方 stable 索引已上线。
- Python 目录 1.1.0 要求主程序至少 1.1.0，其余四包最低为 1.0.0；历史兼容版本保留。当前正式应用下载为 1.1.0。

#### 2026-10-06

- 修复章节与时间轴预览在切换位置时暂时显示其他时间点画面的问题：只显示当前时间点的图片，未取到时显示加载状态，迟到请求不会覆盖新位置。
- 修复光影首页附加海报请求失败时整页报错，以及部分海报服务在 macOS 上的连接兼容问题；复用有效请求路线，减少重复等待，并补齐新播放线路的 HLS 中转。
- 播放扩展补齐 AI 短漫剧的分类、分页、搜索、详情和选集解析；播放器支持由扩展提供有效密钥的 CENC/AES-CTR 视频，换片清理旧参数。

#### 2026-10-04

- 起播稳定后后台预取章节和时间轴预览，重复打开共用取帧任务与有界缓存，已缓存画面立即显示；低缓冲、跳转和换片时优先保护播放。补齐 macOS 本地网络用途说明及中英文打包资源。
- 统一网盘和 NAS 的传输策略与后台带宽判断，保留各来源及 MP3、WAV、FLAC 等格式的读取窗口；修复取消预热影响当前播放、缓存范围误报和切换线路沿用旧参数的问题，NAS 下一条预热复用已缓存文件头。
- 直播增加缓冲余量，结合实际停滞和连接错误对当前频道执行有界恢复；迅雷可选预加载改为后台升级，增加文件大小、磁盘和令牌有效期保护，私有测试包可要求附带 SDK。
- 修正直播短连接恢复的 HLS/HTTP 参数位置；夸克按实际文件头区分改名视频与音频后缀，避免缩小视频传输窗口；百度旧历史优先复用同一文件的个人盘转存记录，原分享失效后仍可播放已保存文件，记录失效再恢复分享并转存。
- 阿里原画视频增加有界并行读取与独立连接池，维持已有缓存预算；歌曲和转码继续使用各自的传输策略。真实原画流畅度仍在验收，未发布。

- 修复推荐海报跳转搜索后输入为空、仍显示历史与热搜的问题：自动填入片名并显示搜索进度和结果；连续点击不同海报、修改输入和清空输入保持正常。
- 修复搜索结果打开其他来源的影片详情后变为 0：保留搜索关键字、结果顺序和分页状态；从搜索进入播放并返回详情后，关闭详情仍回到原搜索结果。
- 章节入口与字幕、音轨等播放器控件统一样式；章节面板显示画面预览、名称、时间范围和当前章节，支持前后章节跳转与滚动浏览。
- 时间轴章节标记改为可悬停预览、点击精确跳转的圆点；拖动保持自由定位，紧凑窗口使用较矮预览卡片。画面预览独立取帧，失败不影响章节跳转。

#### 2026-10-03

- 播放结束提示统一播放器玻璃面板与按钮样式，并适配紧凑窗口；选集顶部显示当前条目或影片的真实海报。
- 修复部分 FLAC／音乐封面被图片站防盗链拒绝而黑屏：封面复用详情页图片请求和解码规则，独立于音频取流；图片不可用时显示音乐背景。换歌取消旧图片，防止封面串到下一首。
- 默认账号存储改为本机加密库，免费 ad-hoc 更新不再反复申请钥匙串授权；公开 1.0.12 的明文登录自动迁移并校验后清理，凭据与密钥不进入应用导出备份。装过后续开发构建的旧钥匙串账号仅静默兼容，无法读取时提示重新登录一次。
- 应用内确认、历史来源选择、账号授权和编辑弹窗统一跟随当前主题，保留取消与原有操作说明。
- 密码、Cookie 和 Token 输入增加显隐按钮，离开页面或应用失去活跃状态后恢复隐藏；账号与文件位置表单标明必填、选填和按需填写，并解释访客连接、公开目录及默认值。
- 播放器字幕面板直接展示和选择主／副字幕轨道；倍速与画面比例改为列表点选并标记当前值。播放设置按播放、字幕、弹幕和更多分类，字幕样式、位置与同步分组排列。
- 音乐合集支持按来源列表顺序切换上一首、下一首和自动连播，混合 MP3、WAV、FLAC 等格式仍保持同一歌曲队列。
- 修复播放音频封面时调节音量或静音可能导致播放器死锁的问题，运行中的音频偏好改为异步提交。
- 网盘原文件取流保持指定的直接连接路线；按压缩音频和无损音频设置传输窗口，下一首预加载缓存连续文件头并复用已有数据，减少起播等待和供数不足导致的卡顿。
- 修复跳到末尾前短片尾后误弹结束面板的问题；确认真实播放到结尾时正常续播，结束后保留有效进度与时长。
- 视频和音频统一按当前选集列表的可见顺序执行上一条、下一条、自动连播和预加载，直到列表末尾；正序/倒序一致。取消按文件名、季集号、版本或目录隐藏筛选，修复列表有条目却提示没有下一集的问题。

#### 2026-10-02

- 修复媒体库中英文片名、原文片名和官方别名匹配；无年份时仅自动选择类型一致的唯一精确候选。自动来源在 TMDB 无结果、歧义或失败后继续豆瓣，正常豆瓣影片页自动恢复，真正验证码保留人工操作。
- 海报右上角新增“待确认／查找”，核对候选后点击“保存修正”完成关联；海报墙、候选窗口、滚动条和进度统一跟随主题。
- 修复媒体库误显示隐藏目录权限错误、SMB 会话失效和 NAS 资源二次代理导致的播放失败；有界分块预读减少高码率播放的协议往返，退出或跳转时取消预读。
- 凭据错误按账号隔离；可选个人 TMDB 覆盖读取失败时仍可使用有效项目凭据，NAS 自身凭据错误继续正常报告。
- 启动时先恢复同一地址上次成功保存的有效点播配置，再后台检查更新；临时网络或 TLS 握手失败按 2、5、10 秒最多重试三次，失败保留配置并提示原因。后台更新合并外部列表后保存，下次加载生效；切换或删除来源会取消旧恢复任务。
- 详情页与播放器共用正序/倒序；上一集、下一集、自动连播和下一集预加载遵循当前排序，首尾按钮同步更新，切换排序不会改变当前播放进度。
- 点击切集后立即显示目标集与“正在切换”，准备期间不再沿用上一集的时间轴和缓冲数据；取消或关闭会拒绝晚到的预加载结果。夸克音频直接获取个人盘原文件，省去先请求视频接口再回退的等待。
- 修复网盘音频合集被误判为无资源的问题；MP3、FLAC、WAV 等音频可进入分享展开和原文件播放链路，图片、歌词文件与压缩包仍不作为播放条目。
- 纯音频缺少播放接口封面时，确认没有视频轨道后显示剧集或详情封面；封面加载失败不影响音频播放，换片清理旧图。
- 修复自动下一集等待预加载时闪出结束面板的问题，取消或关闭后不再接收晚到切集；宽泛电影分类中的明确季集支持连播，已知上传副本保留手选。
- 将“数据源设置”整理为“内容来源”：同页分为在线内容、网盘账号、NAS / 本地、搜索与检查，支持快速定位并保留表单输入。补充 Xtream、直播列表和资料来源的用途说明；统一主题卡片、输入框及自适应文件位置/媒体库弹窗。网盘明确区分凭据填写、保存与验证，中英文文案同步更新。
- 播放器支持主/副双字幕，分别选择轨道、调整位置和按影片保存延迟；文字字幕可调整字体、颜色、描边与背景，图片字幕按可用能力显示位置与缩放。
- 新增默认关闭的在线字幕搜索；用户启用并填写自己的 ASSRT 令牌后，可手动搜索、下载并选择 ZIP 中的字幕，加载到主或副字幕。令牌在本机加密保存，不进入应用导出备份。
- 普通与紧凑播放器增加章节菜单、前后章节跳转和时间轴标记；没有章节的媒体自动隐藏入口，换片后旧菜单不能操作新视频。
- 对部分未声明 HLS 的起播格式错误增加一次有界识别与恢复；播放器参数按来源、用户、会话和传输规则合并，换片恢复默认值，并可查看脱敏的参数来源。
- 统一普通、流式、下载、扩展和文件服务请求的重定向规则，跨源不转发鉴权，保留正确的方法与请求体语义；切换内容源或直播源后拒绝旧加载结果。
- 修复点播列表点击线路旁刷新按钮后无法继续翻页的问题；刷新返回相同海报时仍能继续加载下一页，连续刷新不会重复请求或越过最后一页。
- 修复切换视频源或离开列表后旧海报请求继续占用下载位置的问题；仍被其他卡片使用的同图请求保持共享。本机完整构建恢复此前课堂分类和手机推送实现，玩偶请求增加有效镜像回退及地址复用。
- 新增 WebDAV、AList、OpenList、SMB 和本地目录的文件服务配置、连接测试、目录浏览与播放；账号密码在本机加密保存，本地目录使用系统授权。首页刷新按钮移到线路选择器旁，按当前视图刷新目录或媒体库并支持取消。
- 文件服务可添加多个电影、剧集或混合媒体库，优先读取本地 NFO/图片，支持增量扫描、季集聚合、多版本电影、自动/TMDB/豆瓣/仅本地来源和手动修正。修正保留续播身份，失败扫描保留索引；备份兼容旧格式。TMDB 应用凭据由发布方配置，个人覆盖可选；豆瓣验证时暂停并提供正常网页验证入口。
- 直播配置支持从 JSON 内选择具体直播源，设置页和直播窗口共用选源菜单并记住选择；修复外层配置地址覆盖源地址、切源请求竞争，以及频道列表请求遗漏请求头的问题。单个源失败后仍可切换或重试。
- 修复 SMB 动态库导致的应用打包失败；独立携带 SMB 许可证、固定版本源码和依赖清单，并核对打包完整性。
- 首次安装播放扩展时自动进入“设置 → 扩展支持”并展开高级诊断，在联网前提示需要访问 GitHub；按组件展示真实下载量、百分比和安装阶段，全部启用成功 1.5 秒后自动收起。失败保留原因和重试入口，切页不重复跳回，手动展开或收起优先。
- 历史与收藏按来源配置隔离，旧记录只在来源唯一时自动迁移；删除历史后，同一播放会话的延迟保存不会重新创建记录。
- 多站搜索支持按来源继续加载、失败重试与去重；重复搜索复用进行中的任务，成功页使用有界短时缓存，刷新与账号切换正确失效。
- 点播与直播共享音量、静音偏好；弹幕按播放时钟显示，支持候选选择、文件导入、逐集绑定与偏移保存。
- 直播增加有界 XMLTV 导入、Xtream 当前/下一节目和按需加载的节目指南；导入失败保留上次可用数据。
- 修复连续跳转、长 GOP 视频定位及授权回调的会话归属；过期或重复的授权结果不会恢复到已经离开的影片。
- 文件列表按保守规则建立统一剧集导航；播放结束后可从头重播、手动下一集和重试未完成列表，自动连播等待完整列表。
- 普通与紧凑播放器增加进度时间预览，失焦、尺寸和全屏变化会清理交互状态；全屏过渡失败后可恢复操作。

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

### 1.1.0 (2026-10-07)

This release includes the main-branch changes below and uses build 14. See the [release notes](RELEASE_NOTES_1.1.0.md) for an overview.

#### 2026-10-07

- Release application 1.1.0 (build 14) for Apple Silicon / macOS 14+, together with the signed Sparkle update feed, SBOMs, and SHA-256 checksums. Website downloads and in-app updates point to the new release.
- Publish the latest application shell source to public main, including compatibility, chapter previews, Content Sources, file services, and media libraries. Full public-source regression and distribution gates passed.
- Publish all five signed Provider 1.1.0 bundles—Java, JavaScript, Python, QuickJS catalogs, and configurable Python—to [Distribution](https://github.com/spudhero/NetVplayer-Provider-Distribution/releases) and the official stable index.
- Python catalog 1.1.0 requires application 1.1.0; the other four packages require 1.0.0 or later. Historical compatible versions remain available. The stable application download is 1.1.0.

#### 2026-10-06

- Fix chapter and timeline previews briefly showing a frame from another time after moving the pointer. Display only the requested frame, show loading while it is unavailable, and reject late results for previous positions.
- Keep a valid Guangying home page when optional artwork enrichment fails, restore poster connection compatibility on macOS, reuse working catalog connections, and relay the newly observed HLS route.
- Add AI drama browsing, pagination, search, details, and episode resolution through the playback extension. Support CENC/AES-CTR media with a valid extension-provided key and clear its options when changing media.

#### 2026-10-04

- Prefetch chapter and timeline previews after playback stabilizes, share pending requests and a bounded cache, and display cached frames immediately. Protect playback during low buffering, seeks, and media changes; include localized macOS local-network usage descriptions.

- Centralize drive and NAS transfer policies and background bandwidth decisions while retaining source and MP3/WAV/FLAC read windows. Fix preload cancellation affecting playback, overstated cached ranges, and stale route settings; reuse cached NAS file headers for the next item.
- Increase live buffering and use observed stalls and connection errors for bounded channel recovery. Upgrade optional Xunlei preloads in the background with file-size, disk-space and token-expiry guards; private test builds can require the SDK.
- Correct the HLS/HTTP option layers used for live connection recovery. Use probed containers to keep renamed Quark videos out of small audio transfer windows. Reuse exact Baidu personal-file mappings so saved files remain playable after the original share expires; reopen and transfer the share only when that mapping is unavailable.
- Add bounded parallel ranges and a separate connection pool for Ali original videos within the existing cache budget. Audio and transcoded streams retain their own policies. Real original-stream smoothness remains under validation; this change is unreleased.

- Fix recommendation posters opening search with an empty field and the history/trending page. Fill the title and show search progress and results; switching posters, editing the query and clearing it continue to work.
- Fix search results disappearing after opening a title from another source. Preserve the query, result order and pagination; starting playback from search and closing its restored detail returns to the original results.
- Match the chapter control to the player’s subtitle and audio controls. Show frame previews, names, time ranges and the current chapter in a scrollable panel with previous/next navigation.
- Replace timeline ticks with chapter dots that show previews on hover and seek to exact chapter starts on click. Keep dragging continuous and use a shorter preview card in compact windows. Decode previews separately; failed previews do not block chapter navigation.

#### 2026-10-03

- Match playback completion panels and buttons to the player HUD, including compact windows. Show the actual episode or title poster in the episode drawer.
- Fix black screens for music whose covers are rejected by image-server hotlink protection. Load and decode covers with the detail-page image policy independently of audio transfers, show a music backdrop when unavailable, and cancel old cover requests when changing tracks.
- Store accounts in a local encrypted vault so free ad-hoc updates do not repeatedly request Keychain access. Automatically migrate plaintext sign-ins from public 1.0.12 and remove old copies only after verification; exclude credentials and keys from app exports. Silently import Keychain accounts from later development builds when possible, otherwise ask the affected account to sign in again.
- Apply the current theme to in-app confirmations, history source selection, account authorization, and editor dialogs while preserving cancellation and action descriptions.
- Add visibility buttons to password, Cookie, and Token fields and hide values again when leaving the view or the app becomes inactive. Mark required, optional, and conditional fields, with guidance for guest connections, public folders, and defaults.
- Show and select primary/secondary subtitle tracks directly. Select playback speed and aspect ratio from lists with the current choice marked. Organize playback settings into Playback, Subtitles, Danmaku, and More, with subtitle appearance, position, and timing grouped separately.
- Support previous/next navigation and automatic advancement in music collections using source list order, including mixed MP3, WAV and FLAC files.
- Prevent playback deadlocks when changing volume or mute while rendering audio artwork by submitting runtime audio preferences asynchronously.
- Keep cloud original-file transfers on their selected direct route. Use separate transfer windows for compressed and lossless audio, preload contiguous file headers and reuse cached data to reduce startup waits and buffering caused by insufficient delivery.
- Advance normally after confirmed playback through a short tail following a seek, and retain the last valid position and duration after playback ends.
- Use the visible episode list order for previous/next, automatic advancement and preloading in both video and audio collections, through the final entry. Ascending/descending order stays consistent; filenames, episode numbers, versions and folders no longer create hidden navigation subsets.

#### 2026-10-02

- Fix media library matching across translated titles, original titles, and official aliases. Without a year, only a unique exact title and media type match is selected. Automatic metadata continues to Douban after TMDB misses, ambiguity, or failures; normal Douban pages resume automatically while actual verification remains manual.
- Add direct confirmation and search buttons on posters. Select a candidate and save the correction to associate it; the poster wall, candidate sheet, scrollbars, and progress follow the shared theme.
- Fix hidden directory errors leaking into the library, stale SMB sessions, and NAS playback failures caused by wrapping registered resources in another proxy. Bounded reads and one-chunk prefetch reduce round trips and cancel on exit or seeking.
- Scope credential errors to each account. A failed optional personal TMDB override can fall back to a valid application credential, while NAS account failures remain visible.
- Restore the last valid saved VOD configuration for the same URL before checking for updates in the background. Retry temporary network or TLS handshake failures up to three times after 2, 5 and 10 seconds, retaining saved sites and reporting failures. Persist complete updates with merged external lists for the next load, and cancel stale recovery tasks when switching or removing a source.
- Share ascending/descending order between details and the player. Previous/next navigation, automatic advancement and next-episode preloading follow the selected order, including boundary button states, without changing the current playback position.
- Show the target episode and switching state immediately, without reusing the previous episode's timeline or buffering metrics during preparation. Reject late preloaded results after cancellation or closing. Quark audio requests the personal original file directly, avoiding an unnecessary video-endpoint fallback.
- Fix cloud-drive audio collections incorrectly appearing empty. MP3, FLAC, WAV and other audio files enter share expansion and original-file playback, while images, lyrics sidecars and archives remain excluded.
- Show episode or detail artwork for audio without player-provided artwork, after confirming the media has no video track. Artwork failures do not interrupt audio, and switching media clears the previous image.
- Prevent the ended panel from appearing while automatic next-episode playback waits for preloading. Cancellation and closing reject late transitions; explicit episode labels support series on broad movie shelves, with known upload copies remaining manually selectable.
- Reorganize Data Sources as Content Sources, with same-page groups for Online Content, Cloud Drive Accounts, NAS / Local, and Search & Checks. Quick navigation preserves form input. Explain Xtream, channel lists, and metadata sources; unify themed cards, fields, and adaptive file-location/library dialogs. Distinguish entered, saved, and verified cloud credentials, with matching Chinese and English copy.
- Add primary and secondary subtitles with independent track selection, positions and per-media delays. Text subtitles support font, color, border and background controls; bitmap subtitles expose supported position and scale controls.
- Add opt-in online subtitle search using the user's ASSRT token, with manual downloads and file selection from ZIP archives for either subtitle slot. Encrypt the token locally and exclude it from app exports.
- Add chapter menus, previous/next navigation and timeline markers to regular and compact players. Hide controls when chapters are unavailable and reject stale menus after media changes.
- Recover once from selected startup format errors when a bounded probe identifies undeclared HLS. Resolve player options by source, user, session and transport priority, restore defaults between media, and show redacted option origins.
- Unify redirect behavior for ordinary, streaming, download, extension and file-service requests, isolate cross-origin credentials and preserve method/body semantics. Reject retired content and live-source loading results.
- Add configuration, connection tests, browsing, and playback for WebDAV, AList, OpenList, SMB, and local folders. Encrypt credentials locally and retain local access in system bookmarks. Place refresh beside the source picker, with directory/library refresh and cancellation.
- Add multiple movie, TV, and mixed libraries per file service, local NFO/artwork priority, incremental scans, seasons and movie versions, Automatic/TMDB/Douban/Local Only metadata, and manual corrections. Preserve resume identities, retain indexes after failed scans, and support older backups. Publisher builds provide the TMDB application credential with optional personal overrides; Douban verification pauses matching and opens a normal verification browser.
- Add a persistent live-source picker to Settings and the live player for JSON configurations. Keep configuration and playlist URLs distinct, preserve request headers, and discard stale responses after source switches. Failed sources remain switchable and retryable.
- Fix packaging with the SMB dynamic library, including separate license texts, pinned source archives, dependency records and integrity checks.
- First-time playback extension setup opens Settings → Extension Support and expands advanced diagnostics, with GitHub connectivity guidance before network requests. Each component shows actual download bytes, percentages and installation stages; diagnostics collapse 1.5 seconds after every component is enabled. Failures retain reasons and retry actions, navigation is not repeated, and manual disclosure choices take precedence.
- Scope history and favorites to their source configuration, migrate legacy records only when the source is unambiguous, and prevent delayed saves from recreating history deleted during the same playback session.
- Add per-source search pagination, retries and deduplication. Reuse in-flight searches and bounded, short-lived successful-page caches, with explicit refresh and credential invalidation.
- Share volume and mute preferences between video and live playback. Drive danmaku with the playback clock and support candidate selection, file import, episode bindings and saved offsets.
- Add bounded XMLTV imports, Xtream current/next programme information and an on-demand programme guide. Failed imports retain the previous usable data.
- Correct request ownership for consecutive seeks, long-GOP playback and authorization callbacks. Stale or duplicate authorization results cannot resume a film the user has left.
- Build conservative file episode queues shared by navigation and preloading. Finished playback supports replay from the beginning, manual next episode and incomplete-list retries; automatic advancement waits for a complete list.
- Add timeline time previews to regular and compact players, reset interaction state on focus, size and fullscreen changes, and recover from failed fullscreen transitions.

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
