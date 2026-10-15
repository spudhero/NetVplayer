# NetVplayer 1.1.2

Version: **1.1.2 (build 16)** · 2026-10-12 · macOS 14+ · Apple Silicon arm64.

## 中文

- 恢复课堂选集与播放：主程序保留扩展返回的 Bilibili 分集，不再误当作网盘分享过滤，修复列表正常却显示“暂无可播放资源”的问题。
- 修复 UC 智能线路部分个人盘 MP4 视频的 403：按返回格式携带 UC 自己的账号请求头，已工作的 HLS 路径继续保留。
- 网盘恢复时排除已经被拒绝的转存文件，限制失败重试；切集、换片和关闭后不再接收旧任务的迟到结果。
- 原画起播超时转备用线路时保留历史续播位置，避免回到开头。
- 修复内容来源快速定位的布局断言与 TMDB 图标的打包资源查找。

本次更新主程序，目录扩展沿用 Java 1.1.3、JavaScript 1.1.2、Python 1.1.6、QuickJS 1.1.2 和可配置 Python 1.1.0。旧版安装包、标签及扩展继续保留。

课堂与 UC、夸克的已授权样本通过安装播放验证。百度缺少有效授权，阿里样本分享受限；这些场景和全部 47 来源整片播放未重新认定为通过。macOS 15.6 上报告的设置布局问题已有代码修复，该系统版本的实机复测仍待完成。

应用 ZIP 配套提供签名更新清单、构建清单、CycloneDX / SPDX SBOM 和 SHA-256 校验和。使用社区 ad-hoc 签名。公开应用不内置内容入口、账号或视频目录。

## English

- Restore classroom episodes and playback by preserving Bilibili episodes returned by extensions rather than filtering them as cloud-drive shares.
- Fix HTTP 403 for affected UC personal-drive MP4 smart playback by supplying UC's own account headers according to the returned format; preserve the working HLS path.
- Exclude rejected saved files from drive recovery, bound failed retries, and discard stale results after switching episodes, titles, or closing playback.
- Preserve the history resume target when original-quality startup times out and falls back to another route.
- Fix the Content Sources layout assertion and bundled TMDB logo lookup.

Catalog extensions remain Java 1.1.3, JavaScript 1.1.2, Python 1.1.6, QuickJS 1.1.2, and configurable Python 1.1.0. Previous application releases, tags, and extensions remain available.

Authorized classroom, UC, and Quark samples passed installed playback checks. Baidu lacks valid authorization and the Ali sample share is restricted; these cases and full-length playback across all 47 sources remain unverified. Runtime verification of the Settings layout fix on macOS 15.6 is still pending.

The ZIP is accompanied by a signed update feed, build inventory, CycloneDX / SPDX SBOMs, and SHA-256 checksums. This is a community ad-hoc signed application with no bundled content sources, accounts, or catalogs.
