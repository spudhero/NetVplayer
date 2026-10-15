# NetVplayer 1.1.3

Version: **1.1.3 (build 17)** · 2026-10-13 · macOS 14+ · Apple Silicon arm64.

## 中文

- 修复带 AAC 等音轨标记的视频被当作音频的问题：显示集名隐藏 `.mp4` 时，优先按真实源文件名、保存文件名或媒体 URL 识别媒体类型。
- UC 原片使用正确的视频传输配置，避免音频配置供数不足造成起播超时、缓冲后过早自动转码。真实 AAC、FLAC 等音频保持原有行为。
- 保留 1.1.2 的课堂选集、UC 智能线路 403、失败重试、网盘续播位置和设置页修复。

本次更新主程序与公开源码。目录扩展保持 Java 1.1.3、JavaScript 1.1.2、Python 1.1.6、QuickJS 1.1.2 和可配置 Python 1.1.0，兼容新版应用。历史发布、标签和安装包继续保留。

安装验证中，《一斩苍穹》第 1、2 集保持 UC 原片并连续出画，切集后仍为原片；共享媒体判定已覆盖 UC、夸克、百度、阿里、115 和 PikPak 的回归样本。百度账号授权、阿里受限分享、全部 47 来源整片播放及 macOS 15.6 现场复测仍待验证。

ZIP 配套提供签名更新清单、构建清单、CycloneDX / SPDX SBOM 和 SHA-256 校验和。应用使用社区 ad-hoc 签名，不内置内容入口、账号或视频目录。

## English

- Fix videos with AAC or similar audio-track labels being classified as audio when their displayed episode title hides `.mp4`. Actual source filenames, saved filenames, and media URLs take precedence.
- Use the correct video transfer profile for UC original playback, avoiding startup timeouts and early transcoding caused by insufficient buffering under the audio profile. Preserve genuine AAC, FLAC, and other audio behavior.
- Retain the 1.1.2 fixes for classroom episodes, UC smart-play HTTP 403, bounded retries, drive resume positions, and Settings.

This release updates the main application and public source. Compatible catalog extensions remain Java 1.1.3, JavaScript 1.1.2, Python 1.1.6, QuickJS 1.1.2, and configurable Python 1.1.0. Previous releases, tags, and downloads remain available.

Installed checks kept episodes 1 and 2 of the reported UC title on original playback, with visible video and working episode switching. Shared media classification regression samples cover UC, Quark, Baidu, Ali, 115, and PikPak. Baidu authorization, the restricted Ali share, full-length playback across all 47 sources, and macOS 15.6 runtime verification remain pending.

The ZIP includes a signed update feed, build inventory, CycloneDX / SPDX SBOMs, and SHA-256 checksums. The community ad-hoc signed application contains no bundled content sources, accounts, or catalogs.
