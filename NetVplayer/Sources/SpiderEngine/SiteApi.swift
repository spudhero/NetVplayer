// SpiderEngine/SiteApi.swift
// 站点 API 统一调用层，对应 FongMi: SiteApi.java

import Foundation
import Models
import Networking

/// 站点 API 统一调用层
/// 根据 site.type 路由到 Spider 或 CMS HTTP 请求
public final class SiteApi: Sendable {

    public static let shared = SiteApi()

    private let httpClient: HTTPClient

    public init(httpClient: HTTPClient = .shared) {
        self.httpClient = httpClient
    }

    /// 获取首页内容
    public func homeContent(site: Site) async throws -> Result {
        if let provider = await SpiderReplacementRegistry.shared.nativeProvider(for: site) {
            var result = try await provider.homeContent(site: site)
            let homeVideo = try await provider.homeVideoContent(site: site)
            Self.applyHomeVideoContent(homeVideo, to: &result)
            return result
        }

        let site = await effectiveSite(site)
        if site.isSpider {
            throw SpiderEngineError.nativeReplacementUnsupported(
                site: site.key,
                capability: "当前 JS Provider 必须通过签名 Provider 包运行"
            )
        } else if site.siteType == .xpath {
            // Type 4: XPath/扩展 API
            let url = requestURL(site: site, params: ["filter": "true"])
            let response = try await httpClient.get(url: url, headers: site.header)
            return Result.fromJSON(response.text)
        } else {
            // Type 0/1: CMS XML/JSON
            let url = requestURL(site: site, params: ["ac": "list"])
            let response = try await httpClient.get(url: url, headers: site.header)
            var result = try decodeCMSResult(response.text, siteKey: site.key)
            
            // 批量拉取详情并补齐海报图等数据
            if !result.list.isEmpty {
                let ids = result.list.map { "\($0.vodId)" }
                do {
                    let detailRes = try await self.detailContent(key: site.key, id: ids.joined(separator: ","), sites: [site])
                    if !detailRes.list.isEmpty {
                        let detailMap = Dictionary(uniqueKeysWithValues: detailRes.list.map { ($0.vodId, $0) })
                        result.list = result.list.map { oldVod in
                            if let detailed = detailMap[oldVod.vodId] {
                                print("[DEBUG_LOGGER] 补图详细结果: name=\(detailed.vodName), pic=\(detailed.vodPic)")
                                return detailed
                            }
                            return oldVod
                        }
                    }
                } catch {
                    print("[DEBUG_LOGGER] CMS 首页批量详情补图失败: \(error)")
                }
            }
            return result
        }
    }

    static func applyHomeVideoContent(_ homeVideo: Result?, to result: inout Result) {
        guard let homeVideo, !homeVideo.list.isEmpty else { return }
        result.list = homeVideo.list
    }

    /// 获取分类内容
    public func categoryContent(key: String, tid: String, page: String, filter: Bool, extend: [String: String], sites: [Site]) async throws -> Result {
        guard let originalSite = sites.first(where: { $0.key == key }) else { return .empty }
        if let provider = await SpiderReplacementRegistry.shared.nativeProvider(for: originalSite) {
            return try await provider.categoryContent(site: originalSite, tid: tid, page: page, filter: filter, extend: extend)
        }

        let site = await effectiveSite(originalSite)

        if site.isSpider {
            throw SpiderEngineError.nativeReplacementUnsupported(
                site: site.key,
                capability: "当前 JS Provider 必须通过签名 Provider 包运行"
            )
        } else {
            var params: [String: String] = [
                "ac": site.acParam,
                "t": tid,
                "pg": page
            ]
            if site.siteType == .cmsJSON && !extend.isEmpty {
                if let extData = try? JSONSerialization.data(withJSONObject: extend),
                   let extStr = String(data: extData, encoding: .utf8) {
                    params["f"] = extStr
                }
            } else if site.siteType == .xpath {
                let extData = (try? JSONSerialization.data(withJSONObject: extend)) ?? Data()
                let extStr = String(data: extData, encoding: .utf8) ?? "{}"
                params["ext"] = URLHelper.base64URLSafe(extStr)
            }
            let url = requestURL(site: site, params: params)
            let response = try await httpClient.get(url: url, headers: site.header)
            var result: Result
            if site.siteType == .xpath {
                result = Result.fromJSON(response.text)
            } else {
                result = try decodeCMSResult(response.text, siteKey: site.key)
            }
            
            // 批量拉取详情并补齐海报图等数据
            if !result.list.isEmpty && (site.acParam != "detail" || (result.list.first?.vodPic.isEmpty ?? true)) {
                let ids = result.list.map { "\($0.vodId)" }
                do {
                    let detailRes = try await self.detailContent(key: site.key, id: ids.joined(separator: ","), sites: [site])
                    if !detailRes.list.isEmpty {
                        let detailMap = Dictionary(uniqueKeysWithValues: detailRes.list.map { ($0.vodId, $0) })
                        result.list = result.list.map { oldVod in
                            if let detailed = detailMap[oldVod.vodId] {
                                print("[DEBUG_LOGGER] 分类补图详细结果: name=\(detailed.vodName), pic=\(detailed.vodPic)")
                                return detailed
                            }
                            return oldVod
                        }
                    }
                } catch {
                    print("[DEBUG_LOGGER] CMS 分类批量详情补图失败: \(error)")
                }
            }
            return result
        }
    }

    /// 获取视频详情
    public func detailContent(key: String, id: String, sites: [Site]) async throws -> Result {
        guard let originalSite = sites.first(where: { $0.key == key }) else { return .empty }
        if let provider = await SpiderReplacementRegistry.shared.nativeProvider(for: originalSite) {
            return try await provider.detailContent(site: originalSite, id: id)
        }

        let site = await effectiveSite(originalSite)

        if site.isSpider {
            throw SpiderEngineError.nativeReplacementUnsupported(
                site: site.key,
                capability: "当前 JS Provider 必须通过签名 Provider 包运行"
            )
        } else {
            let url = requestURL(site: site, params: ["ac": site.acParam, "ids": id])
            let response = try await httpClient.get(url: url, headers: site.header)
            if site.siteType == .xpath {
                return Result.fromJSON(response.text)
            }
            return try decodeCMSResult(response.text, siteKey: site.key)
        }
    }

    /// 获取播放内容
    public func playerContent(key: String, flag: String, id: String, sites: [Site]) async throws -> Result {
        guard let originalSite = sites.first(where: { $0.key == key }) else { return .empty }
        if let provider = await SpiderReplacementRegistry.shared.nativeProvider(for: originalSite) {
            return try await provider.playerContent(site: originalSite, flag: flag, id: id)
        }

        let site = await effectiveSite(originalSite)

        if site.isSpider {
            throw SpiderEngineError.nativeReplacementUnsupported(
                site: site.key,
                capability: "当前 JS Provider 必须通过签名 Provider 包运行"
            )
        } else if site.siteType == .xpath {
            let url = requestURL(site: site, params: ["play": id, "flag": flag])
            let response = try await httpClient.get(url: url, headers: site.header)
            return Result.fromJSON(response.text)
        } else {
            var result = Result()
            result.url = id
            result.flag = flag
            result.header = site.header
            result.playUrl = site.playUrl
            return result
        }
    }

    /// 搜索内容
    public func searchContent(site: Site, keyword: String, quick: Bool, page: String) async throws -> Result {
        if let provider = await SpiderReplacementRegistry.shared.nativeProvider(for: site) {
            return try await provider.searchContent(site: site, keyword: keyword, quick: quick, page: page)
        }

        let site = await effectiveSite(site)
        if site.isSpider {
            throw SpiderEngineError.nativeReplacementUnsupported(
                site: site.key,
                capability: "当前 JS Provider 必须通过签名 Provider 包运行"
            )
        } else {
            var params: [String: String] = [
                "wd": keyword,
                "quick": String(quick),
                "pg": page
            ]
            if site.siteType != .xpath {
                params["ac"] = site.acParam
            }
            let url = requestURL(site: site, params: params)
            let response = try await httpClient.get(url: url, headers: site.header)
            var result: Result
            if site.siteType == .xpath {
                result = Result.fromJSON(response.text)
            } else {
                result = try decodeCMSResult(response.text, siteKey: site.key)
            }
            
            // 批量拉取详情并补齐海报图等数据
            if !result.list.isEmpty {
                let ids = result.list.map { "\($0.vodId)" }
                do {
                    let detailRes = try await self.detailContent(key: site.key, id: ids.joined(separator: ","), sites: [site])
                    if !detailRes.list.isEmpty {
                        let detailMap = Dictionary(uniqueKeysWithValues: detailRes.list.map { ($0.vodId, $0) })
                        result.list = result.list.map { oldVod in
                            if let detailed = detailMap[oldVod.vodId] {
                                return detailed
                            }
                            return oldVod
                        }
                    }
                } catch {
                    print("[DEBUG_LOGGER] CMS 搜索批量详情补图失败: \(error)")
                }
            }
            return result
        }
    }

    private func effectiveSite(_ site: Site) async -> Site {
        guard site.isSpider,
              site.api.hasPrefix("csp_"),
              let replacement = await SpiderReplacementRegistry.shared.replacement(for: site) else {
            return site
        }
        return replacement
    }

    private func decodeCMSResult(_ payload: String, siteKey: String) throws -> Result {
        var result = try MacCMSPayloadDecoder.decode(payload).result
        result.key = siteKey
        result.list = result.list.map { vod in
            var vod = vod
            if vod.siteKey.isEmpty {
                vod.siteKey = siteKey
            }
            return vod
        }
        return result
    }

    private func requestURL(site: Site, params: [String: String]) -> String {
        var query = params
        if !site.ext.isEmpty {
            query["extend"] = site.ext
        }

        guard var components = URLComponents(string: site.api) else {
            let encoded = query.map { "\($0.key)=\(URLHelper.encode($0.value))" }.joined(separator: "&")
            return encoded.isEmpty ? site.api : "\(site.api)?\(encoded)"
        }

        let requestedNames = Set(query.keys.map { $0.lowercased() })
        var items = (components.queryItems ?? []).filter {
            !requestedNames.contains($0.name.lowercased())
        }
        items.append(contentsOf: query.map { URLQueryItem(name: $0.key, value: $0.value) })
        components.queryItems = items
        return components.url?.absoluteString ?? site.api
    }
}
