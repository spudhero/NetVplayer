import Foundation
import Models
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case appearance
    case dataSource
    case providers
    case playback
    case network
    case system
    case feedback

    var id: String { rawValue }
    var title: String {
        switch self {
        case .appearance: L10n.text("外观")
        case .dataSource: L10n.text("内容来源")
        case .providers: L10n.text("扩展支持")
        case .playback: L10n.text("播放偏好")
        case .network: L10n.text("网络与代理")
        case .system: L10n.text("缓存与系统")
        case .feedback: L10n.text("问题反馈")
        }
    }

    var icon: String {
        switch self {
        case .appearance: return "paintpalette"
        case .dataSource: return "link"
        case .providers: return "puzzlepiece.extension"
        case .playback: return "play.circle"
        case .network: return "network"
        case .system: return "wrench"
        case .feedback: return "exclamationmark.bubble"
        }
    }

    var subtitle: String {
        switch self {
        case .appearance: return L10n.text("背景、主题与控件色彩")
        case .dataSource: return L10n.text("按视频所在位置，选择适合你的接入方式")
        case .providers: return L10n.text("自动维护播放兼容能力")
        case .playback: return L10n.text("画面、字幕与播放行为")
        case .network: return L10n.text("代理、端口与中继")
        case .system: return L10n.text("缓存、备份与实验功能")
        case .feedback: return L10n.text("复现资料、脱敏日志与 Issue")
        }
    }
}


enum SettingsPlaybackPage: String, CaseIterable, Identifiable {
    case general, video, audio, dialogue
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: L10n.text("播放行为")
        case .video: L10n.text("色彩与视频输出")
        case .audio: L10n.text("音频输出与设备")
        case .dialogue: L10n.text("对白清晰度")
        }
    }
}

enum SettingsSearchExpansion: String {
    case formats, manualCloud, metadata, report, compatibility, hygiene, credentials, resources, liveQuality
    case providerDetails, videoAdvanced, audioAdvanced
}

/// IDs describe destinations, never translated labels or a preference key.
enum SettingsSearchTarget: String, CaseIterable, Identifiable {
    case theme
    case vod
    case live
    case savedConfigs
    case sourceFormats
    case xtream
    case mediaServer
    case cloudAccounts
    case quark
    case uc
    case ali
    case p115
    case pikpak
    case baidu
    case files
    case metadata
    case tmdbCredential
    case searchScope
    case searchSorting
    case diagnostics
    case compatibility
    case hygiene
    case credentials
    case resources
    case liveQuality
    case providers
    case providerDetails
    case decode
    case playerWindow
    case subtitle
    case subtitleStyle
    case subtitleSize
    case subtitlePosition
    case danmaku
    case danmakuOpacity
    case danmakuSize
    case danmakuOffset
    case video
    case toneMapping
    case sdrPeak
    case dolbyVision
    case audio
    case audioDevice
    case audioChannels
    case audioRate
    case trueHD
    case dialogue
    case automation
    case proxy
    case customProxy
    case relay
    case networkCheck
    case language
    case cache
    case webHome
    case webHomeURL
    case backup
    case progress
    case update
    case feedback
    var id: String { rawValue }
}

struct SettingsSearchEntry: Identifiable {
    let id: SettingsSearchTarget
    let section: SettingsSection
    let titleKey: String
    let parents: [String]
    let aliases: String
    var page: SettingsPlaybackPage = .general
    var expansion: SettingsSearchExpansion? = nil

    var title: String { L10n.text(titleKey) }
    var path: String { ([section.title] + parents.map { L10n.text($0) }).joined(separator: " › ") }
}

enum SettingsSearchIndex {
    static let entries: [SettingsSearchEntry] = [
        .init(id: .theme, section: .appearance, titleKey: "界面主题", parents: [], aliases: "appearance theme background accent 背景 主题 强调色"),
        .init(id: .vod, section: .dataSource, titleKey: "影视配置链接", parents: ["影视与直播链接"], aliases: "vod movie config json maccms tvbox 配置源"),
        .init(id: .live, section: .dataSource, titleKey: "直播频道列表", parents: ["影视与直播链接"], aliases: "live iptv m3u txt playlist 直播源"),
        .init(id: .savedConfigs, section: .dataSource, titleKey: "已保存的影视配置", parents: ["影视与直播链接"], aliases: "saved configuration saved config 已保存配置"),
        .init(id: .sourceFormats, section: .dataSource, titleKey: "支持格式与填写示例", parents: ["影视与直播链接"], aliases: "supported formats example json xml m3u", expansion: .formats),
        .init(id: .xtream, section: .dataSource, titleKey: "Xtream 账号", parents: [], aliases: "xtream codes iptv account 账号"),
        .init(id: .mediaServer, section: .dataSource, titleKey: "媒体服务器", parents: [], aliases: "emby jellyfin plex media server 媒体服务器"),
        .init(id: .cloudAccounts, section: .dataSource, titleKey: "网盘账号", parents: [], aliases: "cloud drive account login cookie token 网盘 登录 授权"),
        .init(id: .quark, section: .dataSource, titleKey: "夸克", parents: ["网盘账号"], aliases: "quark cookie login", expansion: .manualCloud),
        .init(id: .uc, section: .dataSource, titleKey: "UC", parents: ["网盘账号"], aliases: "uc cookie login", expansion: .manualCloud),
        .init(id: .ali, section: .dataSource, titleKey: "阿里云盘", parents: ["网盘账号"], aliases: "aliyun ali alipan refresh token", expansion: .manualCloud),
        .init(id: .p115, section: .dataSource, titleKey: "115", parents: ["网盘账号"], aliases: "115 cookie open api token", expansion: .manualCloud),
        .init(id: .pikpak, section: .dataSource, titleKey: "PikPak", parents: ["网盘账号"], aliases: "pikpak access refresh token device id", expansion: .manualCloud),
        .init(id: .baidu, section: .dataSource, titleKey: "百度网盘", parents: ["网盘账号"], aliases: "baidu bduss stoken cookie 百度", expansion: .manualCloud),
        .init(id: .files, section: .dataSource, titleKey: "连接与文件夹", parents: [], aliases: "nas smb webdav ftp sftp local folder files 本机 文件夹"),
        .init(id: .metadata, section: .dataSource, titleKey: "海报与影片资料", parents: [], aliases: "metadata tmdb douban poster nfo 刮削 豆瓣 海报"),
        .init(id: .tmdbCredential, section: .dataSource, titleKey: "高级：自定义 TMDB 访问凭据", parents: ["海报与影片资料"], aliases: "tmdb api key read access token credential 令牌", expansion: .metadata),
        .init(id: .searchScope, section: .dataSource, titleKey: "搜索范围", parents: ["搜索设置"], aliases: "search sites scope default sources 默认 搜索站点"),
        .init(id: .searchSorting, section: .dataSource, titleKey: "优先搜索响应稳定的站点", parents: ["搜索设置"], aliases: "search health sorting performance 搜索 排序 健康"),
        .init(id: .diagnostics, section: .dataSource, titleKey: "查看详细检查报告", parents: ["连接检查"], aliases: "connection diagnostics config report 连接 报告", expansion: .report),
        .init(id: .compatibility, section: .dataSource, titleKey: "外部源兼容状态", parents: ["连接检查", "查看详细检查报告"], aliases: "compatibility provider source 兼容", expansion: .compatibility),
        .init(id: .hygiene, section: .dataSource, titleKey: "来源治理", parents: ["连接检查", "查看详细检查报告"], aliases: "source hygiene block rules 屏蔽 规则", expansion: .hygiene),
        .init(id: .credentials, section: .dataSource, titleKey: "凭据风险", parents: ["连接检查", "查看详细检查报告"], aliases: "credential risk account token 凭据 风险", expansion: .credentials),
        .init(id: .resources, section: .dataSource, titleKey: "资源诊断", parents: ["连接检查", "查看详细检查报告"], aliases: "resource diagnostics jar python 资源", expansion: .resources),
        .init(id: .liveQuality, section: .dataSource, titleKey: "直播线路质量", parents: ["连接检查", "查看详细检查报告"], aliases: "live line quality probe 直播 测速", expansion: .liveQuality),
        .init(id: .providers, section: .providers, titleKey: "扩展支持", parents: [], aliases: "provider runtime extension install update 扩展 安装 更新"),
        .init(id: .providerDetails, section: .providers, titleKey: "高级诊断", parents: [], aliases: "provider runtime diagnostics 组件 诊断", expansion: .providerDetails),
        .init(id: .decode, section: .playback, titleKey: "解码方式", parents: ["播放行为"], aliases: "decode hardware hwdec software 硬解 硬件加速 软解"),
        .init(id: .playerWindow, section: .playback, titleKey: "播放器窗口", parents: ["播放行为"], aliases: "player window reset position size 窗口 位置 大小"),
        .init(id: .subtitle, section: .playback, titleKey: "字幕", parents: [], aliases: "subtitle captions ass srt appearance style 字幕 样式"),
        .init(id: .subtitleStyle, section: .playback, titleKey: "忽略片源字幕样式", parents: ["字幕"], aliases: "subtitle override source style 字幕 样式"),
        .init(id: .subtitleSize, section: .playback, titleKey: "字幕大小", parents: ["字幕"], aliases: "subtitle font size 字号"),
        .init(id: .subtitlePosition, section: .playback, titleKey: "字幕位置", parents: ["字幕"], aliases: "subtitle position bottom 位置"),
        .init(id: .danmaku, section: .playback, titleKey: "启用弹幕入口", parents: ["弹幕手动入口"], aliases: "danmaku bullet comments 弹幕"),
        .init(id: .danmakuOpacity, section: .playback, titleKey: "透明度", parents: ["弹幕手动入口"], aliases: "danmaku opacity 弹幕透明度"),
        .init(id: .danmakuSize, section: .playback, titleKey: "字号", parents: ["弹幕手动入口"], aliases: "danmaku font size 弹幕字号"),
        .init(id: .danmakuOffset, section: .playback, titleKey: "时间偏移", parents: ["弹幕手动入口"], aliases: "danmaku offset delay 弹幕同步 偏移"),
        .init(id: .video, section: .playback, titleKey: "HDR 策略", parents: ["色彩与视频输出"], aliases: "hdr edr sdr video output 临时HDR 色彩", page: .video),
        .init(id: .toneMapping, section: .playback, titleKey: "映射算法", parents: ["色彩与视频输出", "高级设置"], aliases: "tone mapping bt2390 mobius reinhard 色调映射", page: .video, expansion: .videoAdvanced),
        .init(id: .sdrPeak, section: .playback, titleKey: "SDR 参考峰值", parents: ["色彩与视频输出", "高级设置"], aliases: "sdr peak nits brightness 亮度", page: .video, expansion: .videoAdvanced),
        .init(id: .dolbyVision, section: .playback, titleKey: "系统杜比视界", parents: ["色彩与视频输出", "高级设置"], aliases: "dolby vision dv 杜比视界", page: .video, expansion: .videoAdvanced),
        .init(id: .audio, section: .playback, titleKey: "音频直通", parents: ["音频输出与设备"], aliases: "audio passthrough bitstream atmos dolby 音频 原码直通 杜比全景声", page: .audio),
        .init(id: .audioDevice, section: .playback, titleKey: "输出设备偏好", parents: ["音频输出与设备", "高级设置"], aliases: "audio output device speaker hdmi 音频设备 音箱", page: .audio, expansion: .audioAdvanced),
        .init(id: .audioChannels, section: .playback, titleKey: "PCM 声道偏好", parents: ["音频输出与设备", "高级设置"], aliases: "pcm channels surround stereo 声道 环绕", page: .audio, expansion: .audioAdvanced),
        .init(id: .audioRate, section: .playback, titleKey: "PCM 采样率", parents: ["音频输出与设备", "高级设置"], aliases: "pcm sample rate 采样率", page: .audio, expansion: .audioAdvanced),
        .init(id: .trueHD, section: .playback, titleKey: "TrueHD 对象音频", parents: ["音频输出与设备", "高级设置"], aliases: "truehd objects atmos 全景声 对象音频", page: .audio, expansion: .audioAdvanced),
        .init(id: .dialogue, section: .playback, titleKey: "对白清晰度", parents: [], aliases: "dialogue dialog clarity voice enhancement 人声 对白增强", page: .dialogue),
        .init(id: .automation, section: .network, titleKey: "本地只读接口", parents: [], aliases: "local automation api mcp loopback 只读接口 自动化"),
        .init(id: .proxy, section: .network, titleKey: "代理模式", parents: [], aliases: "proxy direct auto network 直连 自动探测 代理"),
        .init(id: .customProxy, section: .network, titleKey: "自定义代理", parents: [], aliases: "custom proxy server port 端口 服务器"),
        .init(id: .relay, section: .network, titleKey: "分片 Range Relay", parents: [], aliases: "range relay chunked 中继 分片"),
        .init(id: .networkCheck, section: .network, titleKey: "连接诊断", parents: [], aliases: "network diagnostics probe 重新探测"),
        .init(id: .language, section: .system, titleKey: "界面语言", parents: [], aliases: "language english chinese 中文 英文 语言"),
        .init(id: .cache, section: .system, titleKey: "缓存管理", parents: [], aliases: "cache disk memory clear cleanup 缓存 清理"),
        .init(id: .webHome, section: .system, titleKey: "启用 WebHome", parents: ["WebHome 实验入口"], aliases: "webhome experimental 网页 首页"),
        .init(id: .webHomeURL, section: .system, titleKey: "WebHome URL", parents: ["WebHome 实验入口"], aliases: "webhome url address 网页 地址"),
        .init(id: .backup, section: .system, titleKey: "应用数据", parents: ["备份与迁移"], aliases: "backup import export migrate data 备份 迁移 导入 导出"),
        .init(id: .progress, section: .system, titleKey: "播放进度", parents: ["备份与迁移"], aliases: "playback progress sync 进度 同步"),
        .init(id: .update, section: .system, titleKey: "关于 NetVplayer", parents: [], aliases: "about version update upgrade sparkle 检查更新 版本 升级"),
        .init(id: .feedback, section: .feedback, titleKey: "问题反馈", parents: [], aliases: "feedback issue report log diagnostics bug 反馈 日志"),
    ]
    static func entry(_ target: SettingsSearchTarget) -> SettingsSearchEntry {
        // All targets are covered once; the contract is checked by the catalog tests.
        entries.first { $0.id == target }!
    }

    static func matches(_ query: String) -> [SettingsSearchEntry] {
        let words = normalized(String(query.prefix(256))).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        return entries.enumerated().compactMap { offset, entry -> (Int, Int, SettingsSearchEntry)? in
            let title = normalized(entry.title + " " + entry.titleKey + " " + L10n.text(entry.titleKey, language: "en"))
            let englishParents = entry.parents.map { L10n.text($0, language: "en") }.joined(separator: " ")
            let text = normalized(title + " " + entry.path + " " + entry.parents.joined(separator: " ")
                + " " + englishParents + " " + entry.aliases + " " + sectionTerms(entry.section))
            guard words.allSatisfy({ text.contains($0) }) else { return nil }
            let aliases = normalized(entry.aliases)
            let score = words.reduce(0) { $0 + (title.contains($1) ? 4 : aliases.contains($1) ? 2 : 0) }
            return (score, offset, entry)
        }.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 > $1.0 }.map { $0.2 }
    }

    private static func sectionTerms(_ section: SettingsSection) -> String {
        switch section {
        case .appearance: "appearance theme"
        case .dataSource: "content sources"
        case .providers: "extensions providers"
        case .playback: "playback preferences"
        case .network: "network proxy"
        case .system: "cache system"
        case .feedback: "feedback"
        }
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                      locale: Locale(identifier: "en_US_POSIX")).lowercased()
    }
}

/// Ephemeral navigation only: no preference store, action callback, or setting binding.
@MainActor final class SettingsSearchNavigation: ObservableObject {
    @Published private(set) var section: SettingsSection = .appearance
    @Published private(set) var page: SettingsPlaybackPage = .general
    @Published private(set) var target: SettingsSearchTarget?
    @Published private(set) var requestID = UUID()
    @Published private(set) var isHighlighted = false

    func reveal(_ target: SettingsSearchTarget) {
        let entry = SettingsSearchIndex.entry(target)
        section = entry.section
        page = entry.page
        self.target = target
        isHighlighted = true
        requestID = UUID() // Selecting the same result again must scroll and highlight again.
    }
    func select(section: SettingsSection, page: SettingsPlaybackPage = .general) {
        self.section = section
        self.page = page
        clearLocation()
    }
    func clearLocation() {
        target = nil
        isHighlighted = false
        requestID = UUID()
    }
    func expireHighlight(request: UUID) {
        guard requestID == request else { return }
        isHighlighted = false
    }
}

/// A read-only snapshot lets results explain conditional controls without enabling them.
struct SettingsSearchContext {
    var customProxy = false
    var danmakuEnabled = false
    var webHomeEnabled = false
    var hasExternalReports = false
    var hasSearchSites = false
    var hasLiveChannels = false
    var pcmControlsAvailable = true

    func anchor(for target: SettingsSearchTarget) -> SettingsSearchTarget {
        target == .compatibility && !hasExternalReports ? .diagnostics : target
    }
    func reason(for target: SettingsSearchTarget) -> String? {
        switch target {
        case .customProxy where !customProxy: L10n.text("仅在自定义代理模式下可编辑。")
        case .danmakuOpacity where !danmakuEnabled,
             .danmakuSize where !danmakuEnabled,
             .danmakuOffset where !danmakuEnabled: L10n.text("启用弹幕入口后可编辑。")
        case .webHomeURL where !webHomeEnabled: L10n.text("启用 WebHome 后可编辑地址。")
        case .compatibility where !hasExternalReports: L10n.text("尚无外部源报告，加载影视配置后可查看。")
        case .searchScope where !hasSearchSites: L10n.text("尚无可搜索站点，请先加载影视配置。")
        case .liveQuality where !hasLiveChannels: L10n.text("尚无直播频道，请先加载直播列表。")
        case .video, .dolbyVision, .audio, .trueHD:
            L10n.text("实际输出取决于片源、系统和设备能力，播放后可查看。")
        case .audioChannels where !pcmControlsAvailable, .audioRate where !pcmControlsAvailable:
            L10n.text("原码直通时由音箱解码，PCM 选项暂不可用。")
        default: nil
        }
    }
}
