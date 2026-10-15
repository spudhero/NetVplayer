# NetVplayer 1.1.4

Version: **1.1.4 (build 18)** · 2026-10-15 · macOS 14+ · Apple Silicon arm64.

## 中文

- **网盘资源分组**：按实际分享与文件夹展示可折叠选集，正倒序只调整组内顺序。上一集、下一集、预加载和自动续播使用当前组，到组末停止，避免跳到其他资源版本。
- **NAS 媒体库**：滚动自动加载更多影片；同一连接可一次选择多个文件夹、分别命名并设置电影／剧集类型，阻止重复和父子重叠扫描。
- **NAS 影视详情**：展示背景图、简介、评分、演职员和文件版本，电视剧支持选季、展开选集和按真实文件继续观看。修复宽屏布局、演员横向滚动和详情右侧留白，缺图时使用当前主题背景。
- **剧集归并与筛选**：优先按已确认的 TMDB／豆瓣身份合并电视剧卡片，可手动合并并保留季集号。系列、主演、导演筛选查询整个当前媒体库，支持条件交集和详情点击跳转；旧缓存、手动修正与观看记录继续兼容。
- 保留 1.1.3 的 UC 原片媒体类型修复，以及此前的课堂选集、UC 智能线路、失败重试和续播位置修复。

目录扩展继续兼容 Java 1.1.3、JavaScript 1.1.2、Python 1.1.6、QuickJS 1.1.2 和可配置 Python 1.1.0。

ZIP 配套提供签名更新清单、构建清单、CycloneDX／SPDX SBOM 和 SHA-256 校验和。应用使用社区 ad-hoc 签名，不内置内容入口、账号或视频目录。

## English

- **Cloud-drive episode groups:** display collapsible groups based on actual shares and folders. Ordering, previous/next, preloading, and automatic playback follow the current group and stop at its end.
- **NAS libraries:** load more movies automatically while scrolling. Add multiple folders under one connection in a single operation, with individual names and media types and checks against duplicate or overlapping scans.
- **NAS movie and TV details:** show artwork, descriptions, ratings, cast, and file versions, with season selection, expandable episodes, and resume tied to the actual file. Fix wide-window layout, horizontal cast scrolling, and right-edge gaps; use the current theme when artwork is unavailable.
- **TV identity and filters:** merge TV cards using confirmed TMDB/Douban identities, with manual merging that preserves season and episode numbers. Filter the entire library by collection, cast, and director, combine conditions, and open filters from details. Preserve old caches, manual corrections, and watch history.
- Retain the UC original-media classification fix from 1.1.3 and earlier fixes for classroom episodes, UC smart playback, bounded retries, and resume positions.

Compatible extensions remain Java 1.1.3, JavaScript 1.1.2, Python 1.1.6, QuickJS 1.1.2, and configurable Python 1.1.0.

The ZIP is accompanied by a signed update feed, build inventory, CycloneDX/SPDX SBOMs, and SHA-256 checksums. The community ad-hoc signed application contains no bundled content sources, accounts, or catalogs.
