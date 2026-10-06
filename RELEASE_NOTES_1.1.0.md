# NetVplayer 1.1.0

正式发布 / Stable release. Version: `1.1.0 (14)`.

2026-10-07：[NetVplayer 1.1.0 主程序安装包](https://github.com/spudhero/NetVplayer/releases/tag/1.1.0)、公开主程序壳源码及五种 [Provider 1.1.0](https://github.com/spudhero/NetVplayer-Provider-Distribution/releases)均已发布。附带签名自动更新清单、构建清单、SBOM 和 SHA-256 校验和。Python 目录包要求主程序至少 1.1.0，其余四包最低 1.0.0。

2026-10-07: [NetVplayer application 1.1.0](https://github.com/spudhero/NetVplayer/releases/tag/1.1.0), the public shell source, and all five [Provider 1.1.0](https://github.com/spudhero/NetVplayer-Provider-Distribution/releases) bundles are released with a signed update feed, build inventory, SBOMs, and SHA-256 checksums. Python catalog requires application 1.1.0; the other four packages require 1.0.0 or later.

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

## 验证与已知限制 / Validation and known limitations

主干和公开源码完整回归、公开发行门禁、签名、许可证、SBOM 与归档校验已通过。正式发布复查确认 TMDB 中文电影/剧集搜索、详情、评分和海报资料通过，归档与更新清单签名可用应用内固定公钥验证。

已知限制保留：阿里原画样本曾跳转超时；夸克视频初测卡顿后独立复验通过，长期播放稳定性尚需更多样本；晚到直播错误的恢复时序仍需核对；115/PikPak 没有已授权实播样本。以上场景不计为验证通过。

Main and public-source regression suites, public distribution gates, signing, licenses, SBOMs, and archive integrity passed. Release verification confirmed Chinese TMDB movie/TV search, details, ratings, and poster metadata. The archive and update feed can be verified with the public key pinned in the application.

Known limitations remain: an Ali original-video sample timed out during seeking; a Quark video stalled initially and passed an independent repeat, while long playback requires more samples; late live-error recovery timing still needs review; and no authorized 115/PikPak playback samples were available. These scenarios are not counted as passed.
