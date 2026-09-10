// Models/Value.swift
// 通用值对象

import Foundation

/// 搜索结果集合（按站点分组）
public struct SearchResult: Identifiable, Sendable {
    public var siteName: String
    public var siteKey: String
    public var vods: [Vod]
    public var isLoading: Bool
    public var error: String?
    public var errorCategory: AppFailureCategory?
    public var page: Int
    public var hasMore: Bool
    public var durationMs: Int

    public var id: String { siteKey }

    public init(
        siteName: String = "",
        siteKey: String = "",
        vods: [Vod] = [],
        isLoading: Bool = false,
        error: String? = nil,
        errorCategory: AppFailureCategory? = nil,
        page: Int = 1,
        hasMore: Bool = false,
        durationMs: Int = 0
    ) {
        self.siteName = siteName
        self.siteKey = siteKey
        self.vods = vods
        self.isLoading = isLoading
        self.error = error
        self.errorCategory = errorCategory
        self.page = page
        self.hasMore = hasMore
        self.durationMs = max(0, durationMs)
    }
}
