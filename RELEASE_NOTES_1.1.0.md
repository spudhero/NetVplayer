# NetVplayer 1.1.0

主程序壳源码与扩展更新 / Application shell source and Provider update. Version: `1.1.0 (14)`.

2026-10-07：最新主程序壳源码已公开，五种 Provider 1.1.0 已[正式分发](https://github.com/spudhero/NetVplayer-Provider-Distribution/releases)。Python 目录包要求主程序至少 1.1.0，其余四包最低 1.0.0。当前稳定应用安装包为[1.0.12](https://github.com/spudhero/NetVplayer/releases/latest)，1.1.0 应用安装包继续保留候选验收状态。

2026-10-07: The latest application shell source is public and all five Provider 1.1.0 bundles are [published](https://github.com/spudhero/NetVplayer-Provider-Distribution/releases). Python catalog requires application 1.1.0; the other four packages require 1.0.0 or later. The stable application download is [1.0.12](https://github.com/spudhero/NetVplayer/releases/latest); the 1.1.0 application bundle remains a release candidate.

## 中文

- 支持 WebDAV、AList、OpenList、SMB 和本地目录，以及电影、剧集和混合媒体库；支持本地 NFO/海报、TMDB/豆瓣资料、增量扫描和手动修正。
- “内容来源”集中管理链接、网盘账号和 NAS / 本地文件；账号使用本机加密库，升级时迁移 1.0.12 的旧登录。
- 增加双字幕、可选在线字幕、章节与时间轴画面预览，修复移动预览位置时暂时串图的问题，改进歌曲封面和播放结束提示。
- 续播、自动下一条和预加载遵循当前选集的显示顺序；修复搜索返回状态、配置恢复、分页与缓存问题。
- 改进网盘/NAS 传输、后台预加载预算和直播缓冲，减少切换和取消任务对当前播放的影响。
- 修复部分站点海报与直连播放的 macOS 兼容问题；播放扩展补齐 AI 短漫剧，播放器支持附带有效密钥的 CENC/AES-CTR 视频。

公开应用保持无内置内容来源。需要 Apple Silicon 和 macOS 14 或更高版本，使用社区 ad-hoc 签名；首次安装可能需要 macOS 放行。真实服务的网络、账号、权限和媒体格式仍影响播放，系统可能要求重新允许本地网络访问。

## English

- Add WebDAV, AList, OpenList, SMB, and local folders with movie, TV, and mixed libraries, local NFO/artwork, TMDB/Douban metadata, incremental scans, and manual corrections.
- Bring links, cloud accounts, and NAS/local files into Content Sources. Encrypt credentials locally and migrate plaintext sign-ins from 1.0.12.
- Add dual subtitles, optional online subtitle search, and chapter/timeline image previews; prevent stale frames when moving between preview positions, and improve audio artwork and the playback completion panel.
- Follow the visible episode order for resume, automatic advancement, and preloading; fix search navigation, configuration recovery, pagination, and caches.
- Improve cloud/NAS transfers, background preload budgets, and live buffering so switching and cancellation interfere less with current playback.
- Fix macOS compatibility for affected posters and direct playback. Add AI drama support through the playback extension and CENC/AES-CTR playback with a valid supplied key.

The public application has no built-in content sources. It requires Apple Silicon and macOS 14 or later and uses community ad-hoc signing; first installation may require macOS approval. Real services remain subject to their network, credentials, permissions, and media formats. macOS may require renewed local network permission.

完整变更 / Full change history: [CHANGELOG.md](CHANGELOG.md).

## 候选验收状态 / Candidate validation

主干和公开源码完整回归、公开发行门禁、签名、许可证、SBOM 与归档校验已通过。本轮实播仍有待处理项，当前不建议直接正式发布：阿里原画样本跳转超时；夸克视频初测卡顿、独立复验通过，尚需长播确认；晚到直播错误场景的恢复时序断言未全部通过；TMDB 官方 API 连接超时；115/PikPak 没有已授权样本。

Main and public-source regression suites, public distribution gates, signing, licenses, SBOMs, and archive integrity passed. This candidate is not ready for a formal release: an Ali original-video sample times out during seeking; a Quark video stalled initially and passed an independent repeat, so longer playback remains unverified; late live-error timing assertions did not all pass; the official TMDB API connection timed out; and no authorized 115/PikPak samples were available.
