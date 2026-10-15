# NetVplayer 1.1.1

Version: **1.1.1 (build 15)** · 2026-10-09 · macOS 14+ · Apple Silicon arm64.

## 中文

本次补丁发布包含此前已在本机验证的修复；打包阶段只更新版本与发行资料，不改变这些修复的业务逻辑。

- 历史、收藏和搜索统一按“原页面 → 详情 → 播放 → 详情 → 原页面”返回。分享详情保留搜索结果及进行中的搜索；播放失败的关闭操作也正常恢复详情。
- 修复部分网络环境中的海报连接失败，补齐动态 DNS、连接期限与取消；减少重复首页请求，并行加载独立目录资料，缩短首次列表与详情等待。
- 修复有声内容请求头兼容问题，原画启播及持续缓冲增加有界备用线路恢复；用户手动切换线路时显示正确提示并保留人工选择。
- 四种目录扩展补齐课堂分类、筛选和分页等迁移遗漏，并通过最终签名归档内的行为检查，防止源码修复未进入分发包。

同时更新签名目录扩展：Java **1.1.3**、JavaScript **1.1.2**、Python **1.1.6**、QuickJS **1.1.2**；可配置 Python 保持 **1.1.0**。Python 目录最低主程序仍为 1.1.0，其余四种扩展为 1.0.0。应用会自动检查兼容更新，也可在“设置 → 扩展支持”选择“重新检查”。

应用 ZIP 附带签名自动更新清单、构建清单、两种 SBOM 和 SHA-256 校验和。使用社区 ad-hoc 签名；首次运行可能需要 macOS 的正常打开许可。公开应用不内置内容入口、账户或视频目录，Provider 只处理用户配置。

此前真实样本和相关回归通过，不等同于所有来源、所有影片或全部网络条件已完成整片验收。外部服务供给不足仍可能影响播放；缺少账号或样本的场景继续保留为未验证。

## English

This patch ships the fixes already validated locally. Packaging updates version metadata and release material without changing their application behavior.

- History, favorites, and search return through the same path: original page → details → playback → details → original page. Share details preserve search results and active searches; closing a playback error restores details through the normal exit path.
- Recover artwork connections on affected networks with dynamic DNS, bounded connection attempts, and cancellation. Remove duplicate home requests and load independent catalog data concurrently.
- Fix audio-content request-header compatibility and add bounded fallback recovery for original-quality startup and buffering. Manual route changes retain the user's selection and show the correct message.
- Deliver classroom categories, filtering, pagination, and other catalog migration fixes in all four signed catalog runtimes. Acceptance checks execute the final archives rather than relying on source-only checks.

Signed catalog versions: Java **1.1.3**, JavaScript **1.1.2**, Python **1.1.6**, and QuickJS **1.1.2**. Configurable Python remains **1.1.0**. Python catalog still requires application 1.1.0 or later; the other four packages require 1.0.0 or later. Compatible updates are checked automatically, or through Settings → Verified Extensions → Check Again.

The application ZIP includes a signed update feed, build inventory, CycloneDX and SPDX SBOMs, and SHA-256 checksums. It uses community ad-hoc signing. The public application includes no content sources, accounts, or catalogs; extensions process user-provided configurations only.

Validated samples and regression checks do not establish full-length playback for every source, title, or network. Upstream delivery can still limit playback; scenarios without accounts or samples remain unverified.
