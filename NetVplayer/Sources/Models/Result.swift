// Models/Result.swift
// API 结果模型，对应 FongMi: bean/Result.java

import Foundation

/// Spider/CMS API 统一返回结果
public struct Result: Codable, Sendable {
    /// 分类列表
    public var types: [VodClass]
    /// 视频列表
    public var list: [Vod]
    /// 筛选器 (typeId -> [Filter])
    public var filters: [String: [Filter]]

    // MARK: - playerContent 返回字段
    /// 播放 URL（可能是字符串或多线路对象）
    public var url: String
    /// 是否需要二次解析 (parse=1 或 jx=1)
    public var parse: Int
    /// 强制解析标记
    public var jx: Int
    /// 播放源标识
    public var flag: String
    /// 播放请求头
    public var header: [String: String]
    /// 播放 URL 前缀
    public var playUrl: String
    /// 与主视频分离的外部音频 URL
    public var externalAudioURL: String
    /// 主媒体的字节长度；用于在首次 Range 响应前建立完整的流语义
    public var contentLength: Int64?
    /// MIME 格式提示
    public var format: String
    /// 音频或视频播放时显示的封面图 URL
    public var artwork: String
    /// 点击脚本
    public var click: String
    /// 解析来源
    public var jxFrom: String
    /// 站点 key
    public var key: String

    /// 外挂字幕列表
    public var subs: [Sub]
    /// DRM 配置
    public var drm: Drm?
    /// 可供用户选择的播放候选；旧 Provider 默认留空
    public var playbackCandidates: [PlaybackCandidate]

    // MARK: - 分页
    public var page: Int
    public var pagecount: Int
    public var total: Int

    // MARK: - 错误
    public var msg: String
    public var code: Int

    public init(
        types: [VodClass] = [],
        list: [Vod] = [],
        filters: [String: [Filter]] = [:],
        url: String = "",
        parse: Int = 0,
        jx: Int = 0,
        flag: String = "",
        header: [String: String] = [:],
        playUrl: String = "",
        externalAudioURL: String = "",
        contentLength: Int64? = nil,
        format: String = "",
        artwork: String = "",
        click: String = "",
        jxFrom: String = "",
        key: String = "",
        subs: [Sub] = [],
        drm: Drm? = nil,
        playbackCandidates: [PlaybackCandidate] = [],
        page: Int = 1,
        pagecount: Int = 1,
        total: Int = 0,
        msg: String = "",
        code: Int = 0
    ) {
        self.types = types
        self.list = list
        self.filters = filters
        self.url = url
        self.parse = parse
        self.jx = jx
        self.flag = flag
        self.header = header
        self.playUrl = playUrl
        self.externalAudioURL = externalAudioURL
        self.contentLength = contentLength
        self.format = format
        self.artwork = artwork
        self.click = click
        self.jxFrom = jxFrom
        self.key = key
        self.subs = subs
        self.drm = drm
        self.playbackCandidates = playbackCandidates
        self.page = page
        self.pagecount = pagecount
        self.total = total
        self.msg = msg
        self.code = code
    }

    enum CodingKeys: String, CodingKey {
        case types, list, filters, url, parse, jx, flag, header, playUrl, externalAudioURL, contentLength, format, artwork, click, jxFrom, key, subs, drm, playbackCandidates, page, pagecount, total, msg, code
    }

    private struct ClassKey: CodingKey {
        var stringValue: String
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        if let typesList = try? container.decode([VodClass].self, forKey: .types) {
            self.types = typesList
        } else if let classContainer = try? decoder.container(keyedBy: ClassKey.self),
                  let classList = try? classContainer.decode([VodClass].self, forKey: ClassKey(stringValue: "class")!) {
            self.types = classList
        } else {
            self.types = []
        }
        
        self.list = (try? container.decode([Vod].self, forKey: .list)) ?? []
        self.filters = (try? container.decode([String: [Filter]].self, forKey: .filters)) ?? [:]
        self.url = (try? container.decode(String.self, forKey: .url)) ?? ""
        self.parse = (try? container.decode(Int.self, forKey: .parse)) ?? 0
        self.jx = (try? container.decode(Int.self, forKey: .jx)) ?? 0
        self.flag = (try? container.decode(String.self, forKey: .flag)) ?? ""
        self.header = (try? container.decode([String: String].self, forKey: .header)) ?? [:]
        self.playUrl = (try? container.decode(String.self, forKey: .playUrl)) ?? ""
        self.externalAudioURL = (try? container.decode(String.self, forKey: .externalAudioURL)) ?? ""
        if let value = try? container.decode(Int64.self, forKey: .contentLength) {
            self.contentLength = value
        } else if let value = try? container.decode(String.self, forKey: .contentLength) {
            self.contentLength = Int64(value)
        } else {
            self.contentLength = nil
        }
        self.format = (try? container.decode(String.self, forKey: .format)) ?? ""
        self.artwork = (try? container.decode(String.self, forKey: .artwork)) ?? ""
        self.click = (try? container.decode(String.self, forKey: .click)) ?? ""
        self.jxFrom = (try? container.decode(String.self, forKey: .jxFrom)) ?? ""
        self.key = (try? container.decode(String.self, forKey: .key)) ?? ""
        self.subs = (try? container.decode([Sub].self, forKey: .subs)) ?? []
        self.drm = try? container.decode(Drm.self, forKey: .drm)
        self.playbackCandidates = (try? container.decode([PlaybackCandidate].self, forKey: .playbackCandidates)) ?? []
        self.page = (try? container.decodeIfPresent(JSONDynamicValue.self, forKey: .page))?.intValue ?? 1
        self.pagecount = (try? container.decodeIfPresent(JSONDynamicValue.self, forKey: .pagecount))?.intValue ?? 1
        self.total = (try? container.decodeIfPresent(JSONDynamicValue.self, forKey: .total))?.intValue ?? 0
        self.msg = (try? container.decode(String.self, forKey: .msg)) ?? ""
        self.code = (try? container.decodeIfPresent(JSONDynamicValue.self, forKey: .code))?.intValue ?? 0
    }

    // MARK: - 业务逻辑

    /// 是否需要二次解析
    public var needParse: Bool {
        parse == 1 || jx == 1
    }

    /// 获取第一个 Vod
    public var vod: Vod? {
        list.first
    }

    /// 空结果
    public static let empty = Result()

    /// 从 JSON 字符串解析
    public static func fromJSON(_ json: String) -> Result {
        guard let data = json.data(using: .utf8) else { return .empty }
        let decoder = JSONDecoder()
        return (try? decoder.decode(Result.self, from: data)) ?? .empty
    }
}
