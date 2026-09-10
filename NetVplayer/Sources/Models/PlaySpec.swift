// Models/PlaySpec.swift
// 播放规格（新增模型，整合 Result 到播放器输入的完整合同）

import Foundation

public struct DanmakuAttachmentStyle: Codable, Sendable, Equatable {
    public var opacity: Double
    public var fontSize: Int

    public init(opacity: Double = 0.8, fontSize: Int = 36) {
        self.opacity = min(1, max(0, opacity))
        self.fontSize = min(72, max(18, fontSize))
    }
}

public struct DanmakuAttachment: Codable, Sendable, Equatable {
    public var sourceID: String
    public var trackCacheKey: String
    public var offsetMs: Int
    public var style: DanmakuAttachmentStyle

    public init(
        sourceID: String,
        trackCacheKey: String,
        offsetMs: Int = 0,
        style: DanmakuAttachmentStyle = DanmakuAttachmentStyle()
    ) {
        self.sourceID = sourceID
        self.trackCacheKey = trackCacheKey
        self.offsetMs = offsetMs
        self.style = style
    }
}

/// 播放规格 — 从解析结果到播放器的完整输入
public struct PlaySpec: Sendable {
    /// 播放 URL
    public var url: String
    /// 与主视频分离、由播放器合并的外部音频 URL
    public var externalAudioURL: String
    /// 主媒体的字节长度；本地 Range 代理用它构造首次完整响应
    public var contentLength: Int64?
    /// HTTP 请求头
    public var headers: [String: String]
    /// 直连失败后降级播放要恢复的请求头。仅在运行时内存中传递，不放入 metadata 日志。
    public var fallbackHeaders: [String: String]
    /// 格式提示 (HLS/DASH/FLV...)
    public var format: String
    /// 音频无视频画面时由播放器展示的封面图 URL
    public var artwork: String
    /// mpv 专用播放选项，用于处理网盘返回的特殊容器/伪头
    public var mpvOptions: [String: String]
    /// 播放链路元数据，用于记录网盘 fid/cacheKey 等非播放器参数
    public var metadata: [String: String]
    /// Typed cloud-drive route plan. It remains in memory and must never be serialized into diagnostics metadata.
    public var drivePlaybackPlan: DrivePlaybackPlan?
    /// Runtime generation used to reject stale cloud-drive player callbacks.
    public var drivePlaybackSessionGeneration: UInt64?
    /// DRM 配置
    public var drm: Drm?
    /// 外挂字幕列表
    public var subs: [Sub]
    /// 弹幕数据源
    public var danmaku: String
    /// 结构化弹幕附件。只保存本地缓存引用和样式，不保存外部接口凭据。
    public var danmakuAttachment: DanmakuAttachment?
    /// 视频元数据（标题等）
    public var title: String
    /// 播放线路标识
    public var flag: String
    /// 站点 key
    public var siteKey: String

    public init(
        url: String = "",
        externalAudioURL: String = "",
        contentLength: Int64? = nil,
        headers: [String: String] = [:],
        fallbackHeaders: [String: String] = [:],
        format: String = "",
        artwork: String = "",
        mpvOptions: [String: String] = [:],
        metadata: [String: String] = [:],
        drivePlaybackPlan: DrivePlaybackPlan? = nil,
        drivePlaybackSessionGeneration: UInt64? = nil,
        drm: Drm? = nil,
        subs: [Sub] = [],
        danmaku: String = "",
        danmakuAttachment: DanmakuAttachment? = nil,
        title: String = "",
        flag: String = "",
        siteKey: String = ""
    ) {
        self.url = url
        self.externalAudioURL = externalAudioURL
        self.contentLength = contentLength
        self.headers = headers
        self.fallbackHeaders = fallbackHeaders
        self.format = format
        self.artwork = artwork
        self.mpvOptions = mpvOptions
        self.metadata = metadata
        self.drivePlaybackPlan = drivePlaybackPlan
        self.drivePlaybackSessionGeneration = drivePlaybackSessionGeneration
        self.drm = drm
        self.subs = subs
        self.danmaku = danmaku
        self.danmakuAttachment = danmakuAttachment
        self.title = title
        self.flag = flag
        self.siteKey = siteKey
    }

    public func merging(_ override: PlaySpec) -> PlaySpec {
        var spec = self
        if !override.url.isEmpty {
            if override.url != spec.url { spec.contentLength = nil }
            spec.url = override.url
        }
        if !override.externalAudioURL.isEmpty { spec.externalAudioURL = override.externalAudioURL }
        if let contentLength = override.contentLength { spec.contentLength = contentLength }
        spec.headers.merge(override.headers) { _, new in new }
        if !override.fallbackHeaders.isEmpty { spec.fallbackHeaders.merge(override.fallbackHeaders) { _, new in new } }
        if !override.format.isEmpty { spec.format = override.format }
        if !override.artwork.isEmpty { spec.artwork = override.artwork }
        if !override.mpvOptions.isEmpty { spec.mpvOptions.merge(override.mpvOptions) { _, new in new } }
        if !override.metadata.isEmpty { spec.metadata.merge(override.metadata) { _, new in new } }
        if let drivePlaybackPlan = override.drivePlaybackPlan { spec.drivePlaybackPlan = drivePlaybackPlan }
        if let generation = override.drivePlaybackSessionGeneration {
            spec.drivePlaybackSessionGeneration = generation
        }
        if let drm = override.drm { spec.drm = drm }
        if !override.subs.isEmpty { spec.subs = override.subs }
        if !override.danmaku.isEmpty { spec.danmaku = override.danmaku }
        if let danmakuAttachment = override.danmakuAttachment { spec.danmakuAttachment = danmakuAttachment }
        if !override.title.isEmpty { spec.title = override.title }
        if !override.flag.isEmpty { spec.flag = override.flag }
        if !override.siteKey.isEmpty { spec.siteKey = override.siteKey }
        return spec
    }
}
