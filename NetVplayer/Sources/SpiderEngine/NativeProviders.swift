// SpiderEngine/NativeProviders.swift
// Public adapters for user-owned storage, static shares, and direct push input.

import Foundation
import DriveEngine
import Models
import Networking

public struct AListNativeProvider: SiteContentProvider {
    private let httpClient: HTTPClient
    private let defaultHeaders: [String: String]

    public init(httpClient: HTTPClient = .shared, defaultHeaders: [String: String] = [:]) {
        self.httpClient = httpClient
        self.defaultHeaders = defaultHeaders
    }

    public func homeContent(site: Site) async throws -> Result {
        let drives = try await loadDrives(site: site)
        let classes = drives.filter { !$0.hidden }.map { VodClass(typeId: $0.name, typeName: $0.name) }
        let filters = Dictionary(uniqueKeysWithValues: classes.map { ($0.typeId, Self.sortFilters) })
        return Result(types: classes, filters: filters, key: site.key)
    }

    public func categoryContent(site: Site, tid: String, page: String, filter: Bool, extend: [String: String]) async throws -> Result {
        let drives = try await loadDrives(site: site)
        let (driveName, path) = splitDrivePath(tid)
        guard let drive = drives.first(where: { $0.name == driveName }) ?? drives.first else {
            return .empty
        }

        let items = try await list(drive: drive, path: path.isEmpty ? drive.path : path)
        let sorted = sort(items: items, type: extend["type"] ?? "", order: extend["order"] ?? "")
        let vods = sorted.filter { $0.isDirectory || Self.isMedia($0.name) }.map { item in
            Vod(
                vodId: drivePathID(drive: drive, path: item.path),
                vodName: item.name,
                vodPic: item.isDirectory ? Self.folderImage : Self.videoImage,
                vodRemarks: item.isDirectory ? "目录" : byteCount(item.size),
                siteKey: site.key
            )
        }
        return Result(list: vods, key: site.key, page: Int(page) ?? 1, pagecount: 1, total: vods.count)
    }

    public func detailContent(site: Site, id: String) async throws -> Result {
        let drives = try await loadDrives(site: site)
        let (driveName, itemPath) = splitDrivePath(id)
        guard let drive = drives.first(where: { $0.name == driveName }) ?? drives.first else {
            return .empty
        }

        let parentPath = parentPath(for: itemPath)
        let siblings = try await list(drive: drive, path: parentPath.isEmpty ? drive.path : parentPath)
        let media = siblings.filter { !$0.isDirectory && Self.isMedia($0.name) }
        let subtitles = siblings.filter { !$0.isDirectory && Self.isSubtitle($0.name) }
        let playItems = media.map { item in
            "\(safeEpisodeName(item.name))$\(alistURL(drive: drive, item: item, siblings: subtitles))"
        }
        let title = itemPath.split(separator: "/").last.map(String.init) ?? drive.name
        let vod = Vod(
            vodId: id,
            vodName: title.isEmpty ? drive.name : title,
            vodPic: Self.videoImage,
            vodPlayFrom: drive.name,
            vodPlayUrl: playItems.joined(separator: "#"),
            siteKey: site.key
        )
        return Result(list: [vod], key: site.key)
    }

    public func playerContent(site: Site, flag: String, id: String) async throws -> Result {
        let request = try AListPlaybackRequest(url: id)
        let drives = try await loadDrives(site: site)
        let drive = drives.first { $0.name == flag || sameServer($0.server, request.server) }
        let link = try await resolvePlayback(request, drive: drive)
        return Result(
            url: link.url,
            parse: 0,
            jx: 0,
            flag: flag,
            header: link.headers,
            key: site.key,
            subs: link.subs
        )
    }

    public func searchContent(site: Site, keyword: String, quick: Bool, page: String) async throws -> Result {
        let drives = try await loadDrives(site: site).filter { $0.searchable }
        var vods: [Vod] = []
        for drive in drives {
            let items = (try? await search(drive: drive, keyword: keyword, page: page)) ?? []
            vods.append(contentsOf: items.filter { $0.isDirectory || Self.isMedia($0.name) }.map { item in
                Vod(
                    vodId: drivePathID(drive: drive, path: item.path),
                    vodName: item.name,
                    vodPic: item.isDirectory ? Self.folderImage : Self.videoImage,
                    vodRemarks: drive.name,
                    siteKey: site.key
                )
            })
        }
        return Result(list: vods, key: site.key, page: Int(page) ?? 1, pagecount: 1, total: vods.count)
    }

    private func resolvePlayback(_ request: AListPlaybackRequest, drive: AListDrive?) async throws -> AListPlaybackLink {
        var body: [String: Any] = ["path": request.path, "password": drive?.password(for: request.path) ?? ""]
        if !request.password.isEmpty { body["password"] = request.password }
        var headers = request.headers
        let response = try await postJSON(
            url: request.server.appendingPathComponent("/api/fs/get"),
            body: body,
            headers: headers,
            drive: drive
        )
        if let driveHeaders = response.updatedHeaders {
            headers.merge(driveHeaders) { _, new in new }
        }
        let object = response.object
        guard let data = object["data"] as? [String: Any] else {
            throw SpiderEngineError.nativeReplacementUnsupported(site: "csp_AList", capability: "missing data")
        }
        let url = firstString(data, keys: ["raw_url", "url", "download_url"])
        guard !url.isEmpty else {
            throw SpiderEngineError.nativeReplacementUnsupported(site: "csp_AList", capability: "missing raw_url")
        }
        return AListPlaybackLink(url: url, headers: headers, subs: request.subs)
    }

    private func loadDrives(site: Site) async throws -> [AListDrive] {
        let ext = site.ext.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ext.isEmpty else {
            return [AListDrive(
                name: site.name.isEmpty ? site.key : site.name,
                server: site.api,
                path: "/",
                headers: defaultHeaders
            )]
        }
        let text: String
        if isReadableResource(ext) {
            text = try await loadTextResource(ext, httpClient: httpClient, headers: site.header)
        } else {
            text = ext
        }
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return []
        }
        let rawDrives: [[String: Any]]
        if let dict = object as? [String: Any], let drives = dict["drives"] as? [[String: Any]] {
            rawDrives = drives
        } else if let drives = object as? [[String: Any]] {
            rawDrives = drives
        } else {
            rawDrives = []
        }
        return rawDrives.compactMap(AListDrive.init)
    }

    private func list(drive: AListDrive, path: String) async throws -> [AListItem] {
        var drive = drive
        let response = try await postJSON(
            url: drive.server.appendingPathComponent("/api/fs/list"),
            body: ["path": normalizedPath(path), "password": drive.password(for: path), "page": 1, "per_page": 200],
            headers: drive.headers,
            drive: drive
        )
        if let updatedHeaders = response.updatedHeaders {
            drive.headers.merge(updatedHeaders) { _, new in new }
        }
        return items(from: response.object)
    }

    private func search(drive: AListDrive, keyword: String, page: String) async throws -> [AListItem] {
        var drive = drive
        let response = try await postJSON(
            url: drive.server.appendingPathComponent("/api/fs/search"),
            body: [
                "parent": drive.path,
                "keywords": keyword,
                "scope": 0,
                "page": Int(page) ?? 1,
                "per_page": 50
            ],
            headers: drive.headers,
            drive: drive
        )
        if let updatedHeaders = response.updatedHeaders {
            drive.headers.merge(updatedHeaders) { _, new in new }
        }
        return items(from: response.object)
    }

    private func postJSON(url: String, body: [String: Any], headers: [String: String], drive: AListDrive? = nil) async throws -> AListPostResponse {
        let data = try JSONSerialization.data(withJSONObject: body)
        var requestHeaders = headers
        requestHeaders["Content-Type"] = "application/json; charset=utf-8"
        let response = try await httpClient.post(url: url, headers: requestHeaders, body: data, timeout: 30)
        if response.text.contains("Guest user is disabled"),
           let drive,
           let loggedInHeaders = try await loginHeaders(for: drive) {
            var retryHeaders = requestHeaders
            retryHeaders.merge(loggedInHeaders) { _, new in new }
            let retry = try await httpClient.post(url: url, headers: retryHeaders, body: data, timeout: 30)
            guard let object = try? JSONSerialization.jsonObject(with: retry.data) as? [String: Any] else {
                throw SpiderEngineError.nativeReplacementUnsupported(site: "csp_AList", capability: "invalid JSON")
            }
            return AListPostResponse(object: object, updatedHeaders: loggedInHeaders)
        }
        guard let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
            throw SpiderEngineError.nativeReplacementUnsupported(site: "csp_AList", capability: "invalid JSON")
        }
        return AListPostResponse(object: object, updatedHeaders: nil)
    }

    private func loginHeaders(for drive: AListDrive) async throws -> [String: String]? {
        guard !drive.loginUsername.isEmpty || !drive.loginPassword.isEmpty else { return nil }
        let body = try JSONSerialization.data(withJSONObject: [
            "username": drive.loginUsername,
            "password": drive.loginPassword
        ])
        let response = try await httpClient.post(
            url: drive.server.appendingPathComponent("/api/auth/login"),
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: body,
            timeout: 30
        )
        guard let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let data = object["data"] as? [String: Any] else {
            return nil
        }
        let token = firstString(data, keys: ["token"])
        guard !token.isEmpty else { return nil }
        return ["Authorization": token.hasPrefix("Bearer ") ? token : "Bearer \(token)"]
    }

    private func items(from response: [String: Any]) -> [AListItem] {
        let data = response["data"] as? [String: Any]
        let content = (data?["content"] as? [[String: Any]])
            ?? (data?["files"] as? [[String: Any]])
            ?? (response["data"] as? [[String: Any]])
            ?? []
        return content.compactMap(AListItem.init)
    }

    private func alistURL(drive: AListDrive, item: AListItem, siblings: [AListItem]) -> String {
        let subs = matchingSubtitles(for: item, siblings: siblings).map { sub in
            Sub(name: sub.name, url: alistURL(drive: drive, item: sub, siblings: []), format: fileExtension(sub.name))
        }
        return AListPlaybackRequest.makeURL(server: drive.server, path: item.path, password: drive.password(for: item.path), headers: drive.headers, subs: subs)
    }

    private func matchingSubtitles(for item: AListItem, siblings: [AListItem]) -> [AListItem] {
        let stem = fileStem(item.name)
        let exact = siblings.filter { fileStem($0.name).localizedCaseInsensitiveCompare(stem) == .orderedSame }
        return exact.isEmpty ? siblings : exact
    }

    private func splitDrivePath(_ id: String) -> (String, String) {
        guard let slash = id.firstIndex(of: "/") else { return (id, "/") }
        return (String(id[..<slash]), String(id[slash...]))
    }

    private func drivePathID(drive: AListDrive, path: String) -> String {
        "\(drive.name)\(normalizedPath(path))"
    }

    private func sort(items: [AListItem], type: String, order: String) -> [AListItem] {
        let sorted: [AListItem]
        switch type {
        case "name":
            sorted = items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case "size":
            sorted = items.sorted { $0.size < $1.size }
        case "date":
            sorted = items.sorted { $0.modified.localizedStandardCompare($1.modified) == .orderedAscending }
        default:
            sorted = items
        }
        return order == "desc" ? sorted.reversed() : sorted
    }

    fileprivate static let sortFilters: [Filter] = [
        Filter(key: "type", name: "排序类型", values: [
            FilterValue(name: "默认", value: ""),
            FilterValue(name: "名称", value: "name"),
            FilterValue(name: "大小", value: "size"),
            FilterValue(name: "修改时间", value: "date")
        ]),
        Filter(key: "order", name: "排序方式", values: [
            FilterValue(name: "默认", value: ""),
            FilterValue(name: "升序", value: "asc"),
            FilterValue(name: "降序", value: "desc")
        ])
    ]

    private static let folderImage = "folder"
    private static let videoImage = "video"
    static let mediaExtensions: Set<String> = ["mp4", "m4v", "mov", "mkv", "m3u8", "ts", "flv", "webm", "avi", "wmv", "iso"]
    static let subtitleExtensions: Set<String> = ["srt", "ass", "ssa", "vtt"]

    static func isMedia(_ name: String) -> Bool { mediaExtensions.contains(fileExtension(name)) }
    static func isSubtitle(_ name: String) -> Bool { subtitleExtensions.contains(fileExtension(name)) }
}

public struct DriveShareCatalogProvider: SiteContentProvider {
    private static let pageSize = 60

    private let httpClient: HTTPClient
    private let driveExpander: DriveShareExpander

    public init(httpClient: HTTPClient = .shared, driveExpander: DriveShareExpander? = nil) {
        self.httpClient = httpClient
        self.driveExpander = driveExpander ?? DriveShareExpander(httpClient: httpClient)
    }

    public func homeContent(site: Site) async throws -> Result {
        let catalog = try await loadCatalog(site: site)
        return Result(
            types: catalog.classes.map { VodClass(typeId: $0.id, typeName: $0.name) },
            list: vods(from: Array(catalog.entries.prefix(Self.pageSize)), siteKey: site.key),
            key: site.key,
            page: 1,
            pagecount: max(1, Int(ceil(Double(catalog.entries.count) / Double(Self.pageSize)))),
            total: catalog.entries.count
        )
    }

    public func categoryContent(site: Site, tid: String, page: String, filter: Bool, extend: [String: String]) async throws -> Result {
        let catalog = try await loadCatalog(site: site)
        let currentPage = max(Int(page) ?? 1, 1)
        let filtered = catalog.entries.filter { tid.isEmpty || tid == "all" || $0.classID == tid }
        let start = min((currentPage - 1) * Self.pageSize, filtered.count)
        let end = min(start + Self.pageSize, filtered.count)
        let slice = start < end ? Array(filtered[start..<end]) : []
        return Result(
            types: catalog.classes.map { VodClass(typeId: $0.id, typeName: $0.name) },
            list: vods(from: slice, siteKey: site.key),
            key: site.key,
            page: currentPage,
            pagecount: max(1, Int(ceil(Double(filtered.count) / Double(Self.pageSize)))),
            total: filtered.count
        )
    }

    public func detailContent(site: Site, id: String) async throws -> Result {
        guard let entry = DriveShareCatalogEntry.decode(id) else {
            return Result(list: [Vod(vodId: id, vodName: id, siteKey: site.key)], key: site.key)
        }

        let playItems: [String]
        switch await driveExpander.expansionOutcome(url: entry.shareURL, fallbackTitle: entry.title) {
        case .expanded(let episodes):
            playItems = episodes.map { "\(safeEpisodeName($0.name))$\($0.url)" }
        case .unavailable(let reason):
            playItems = [unavailableEpisode(title: entry.title, reason: reason)]
        }

        let vod = Vod(
            vodId: id,
            vodName: entry.title,
            vodRemarks: entry.provider.displayName,
            vodPlayFrom: entry.provider.displayName,
            vodPlayUrl: playItems.joined(separator: "#"),
            siteKey: site.key
        )
        return Result(list: [vod], key: site.key)
    }

    public func playerContent(site: Site, flag: String, id: String) async throws -> Result {
        Result(url: id, parse: 0, jx: 0, flag: flag, key: site.key)
    }

    public func searchContent(site: Site, keyword: String, quick: Bool, page: String) async throws -> Result {
        let catalog = try await loadCatalog(site: site)
        let currentPage = max(Int(page) ?? 1, 1)
        let filtered = catalog.entries.filter { $0.title.localizedCaseInsensitiveContains(keyword) }
        let start = min((currentPage - 1) * Self.pageSize, filtered.count)
        let end = min(start + Self.pageSize, filtered.count)
        let slice = start < end ? Array(filtered[start..<end]) : []
        return Result(
            list: vods(from: slice, siteKey: site.key),
            key: site.key,
            page: currentPage,
            pagecount: max(1, Int(ceil(Double(filtered.count) / Double(Self.pageSize)))),
            total: filtered.count
        )
    }

    private func loadCatalog(site: Site) async throws -> DriveShareCatalog {
        let provider = provider(for: site)
        let ext = site.ext.trimmingCharacters(in: .whitespacesAndNewlines)
        let text: String
        if ext.isEmpty {
            text = ""
        } else if isReadableResource(ext) {
            text = try await loadTextResource(ext, httpClient: httpClient, headers: site.header)
        } else {
            text = ext
        }

        if let jsonCatalog = parseJSONCatalog(text: text, defaultProvider: provider, site: site),
           (!jsonCatalog.classes.isEmpty || !jsonCatalog.entries.isEmpty) {
            return jsonCatalog
        }
        return parseTextCatalog(text: text, defaultProvider: provider, site: site)
    }

    private func parseTextCatalog(text: String, defaultProvider: DriveProvider, site: Site) -> DriveShareCatalog {
        var classes: [DriveShareCatalogClass] = []
        var entries: [DriveShareCatalogEntry] = []
        var currentClass = DriveShareCatalogClass(id: "all", name: site.name.isEmpty ? defaultProvider.displayName : site.name)
        classes.append(currentClass)

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("//") { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let first = parts.first else { continue }

            if ["self", "class", "category"].contains(first.lowercased()) {
                let title = cleanedTitle(Array(parts.dropFirst()))
                currentClass = DriveShareCatalogClass(
                    id: first.lowercased() == "self" ? "self" : safeClassID(title.isEmpty ? first : title),
                    name: title.isEmpty ? currentClass.name : title
                )
                if !classes.contains(where: { $0.id == currentClass.id }) {
                    classes.append(currentClass)
                }
                continue
            }

            let provider = providerForShareToken(first, defaultProvider: defaultProvider)
            let title = cleanedTitle(Array(parts.dropFirst()))
            let shareURL = shareURL(from: first, provider: provider)
            guard provider != .unknown, !shareURL.isEmpty else { continue }
            entries.append(DriveShareCatalogEntry(
                provider: provider,
                classID: currentClass.id,
                title: title.isEmpty ? first : title,
                shareURL: shareURL
            ))
        }

        let usedClassIDs = Set(entries.map(\.classID))
        classes = classes.filter { usedClassIDs.contains($0.id) || (entries.isEmpty && $0.id == currentClass.id) }
        if entries.isEmpty, classes.isEmpty {
            classes = [DriveShareCatalogClass(id: "all", name: site.name.isEmpty ? "网盘分享" : site.name)]
        }
        return DriveShareCatalog(classes: classes, entries: entries)
    }

    private func parseJSONCatalog(text: String, defaultProvider: DriveProvider, site: Site) -> DriveShareCatalog? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        let dict = object as? [String: Any] ?? [:]
        let classObjects = (dict["classes"] as? [[String: Any]])
            ?? (dict["class"] as? [[String: Any]])
            ?? (dict["categories"] as? [[String: Any]])
            ?? []
        var classes = classObjects.compactMap { item -> DriveShareCatalogClass? in
            let id = firstString(item, keys: ["type_id", "typeId", "id", "key"])
            let name = firstString(item, keys: ["type_name", "typeName", "name", "title"])
            guard !id.isEmpty || !name.isEmpty else { return nil }
            return DriveShareCatalogClass(id: id.isEmpty ? safeClassID(name) : id, name: name.isEmpty ? id : name)
        }
        if classes.isEmpty {
            classes = [DriveShareCatalogClass(id: "all", name: site.name.isEmpty ? defaultProvider.displayName : site.name)]
        }

        let entryObjects = (dict["shares"] as? [[String: Any]])
            ?? (dict["list"] as? [[String: Any]])
            ?? (object as? [[String: Any]])
            ?? []
        let entries = entryObjects.compactMap { item -> DriveShareCatalogEntry? in
            let rawURL = firstString(item, keys: ["url", "share", "share_url", "shareUrl", "id"])
            guard !rawURL.isEmpty else { return nil }
            let provider = providerForShareToken(firstString(item, keys: ["provider", "type"]).nilIfEmpty ?? rawURL, defaultProvider: defaultProvider)
            let title = firstString(item, keys: ["name", "title", "vod_name", "vodName"])
            let classID = firstString(item, keys: ["class_id", "classId", "type_id", "typeId"]).nilIfEmpty ?? classes.first?.id ?? "all"
            return DriveShareCatalogEntry(
                provider: provider,
                classID: classID,
                title: title.isEmpty ? rawURL : title,
                shareURL: shareURL(from: rawURL, provider: provider)
            )
        }
        return DriveShareCatalog(classes: classes, entries: entries)
    }

    private func vods(from entries: [DriveShareCatalogEntry], siteKey: String) -> [Vod] {
        entries.map { entry in
            Vod(
                vodId: entry.encodedID,
                vodName: entry.title,
                vodPic: providerImage(entry.provider),
                vodRemarks: entry.provider.displayName,
                siteKey: siteKey
            )
        }
    }

    private func provider(for site: Site) -> DriveProvider {
        providerForShareToken([site.api, site.key, site.name, site.ext].joined(separator: " "), defaultProvider: .unknown)
    }

    private func providerForShareToken(_ value: String, defaultProvider: DriveProvider) -> DriveProvider {
        let lower = value.lowercased()
        if lower.contains("quark") || lower.contains("pan.quark.cn") || lower.hasPrefix("quark://") { return .quark }
        if lower.contains("ucshare") || lower.contains("drive.uc.cn") || lower.hasPrefix("uc://") { return .uc }
        if lower.contains("aliyundrive") || lower.contains("alipan") || lower.contains("alishare") || lower.hasPrefix("ali://") { return .ali }
        if lower.contains("115share") || lower.contains("p115") || lower.contains("115.com") || lower.hasPrefix("115://") || lower.hasPrefix("sw") { return .p115 }
        if lower.contains("pan.baidu.com") || lower.contains("baidushare") || lower.hasPrefix("baidu://") { return .baidu }
        if lower.contains("123pan")
            || lower.contains("123684")
            || lower.contains("123865")
            || lower.contains("123952")
            || lower.contains("123912")
            || lower.contains("cloud123")
            || lower.hasPrefix("123://") { return .cloud123 }
        if lower.contains("xunlei") || lower.contains("pan.xunlei.com") || lower.hasPrefix("thunder://") { return .xunlei }
        if lower.contains("yun.139.com") || lower.contains("caiyun.139.com") || lower.contains("feixin.10086.cn") || lower.hasPrefix("139://") { return .mobile }
        if lower.contains("cloud.189.cn") || lower.contains("tianyi") || lower.hasPrefix("189://") { return .tianyi }
        return defaultProvider
    }

    private func shareURL(from token: String, provider: DriveProvider) -> String {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if DriveFileReference.provider(for: trimmed) != .unknown {
            return trimmed
        }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return trimmed
        }
        switch provider {
        case .quark: return "quark://share/\(trimmed)"
        case .uc: return "uc://share/\(trimmed)"
        case .ali: return "ali://share/\(trimmed)"
        case .p115: return "115://share/\(trimmed)"
        case .baidu: return "baidu://share/\(trimmed)"
        case .cloud123: return "123://share/\(trimmed)"
        case .xunlei: return "xunlei://share/\(trimmed)"
        case .mobile: return "139://share/\(trimmed)"
        case .tianyi: return "189://share/\(trimmed)"
        default: return trimmed
        }
    }

    private func cleanedTitle(_ tokens: [String]) -> String {
        var tokens = tokens
        while let last = tokens.last?.lowercased(),
              last == "asc" || last == "desc" || Int(last) != nil {
            tokens.removeLast()
        }
        if tokens.last?.lowercased() == "updated_at" {
            tokens.removeLast()
        }
        while let last = tokens.last?.lowercased(),
              Int(last) != nil {
            tokens.removeLast()
        }
        return tokens.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func unavailableEpisode(title: String, reason: String) -> String {
        let safeReason = reason
            .replacingOccurrences(of: "$", with: " ")
            .replacingOccurrences(of: "#", with: " ")
        var components = URLComponents()
        components.scheme = "netvplayer-unavailable"
        components.host = "drive-share"
        components.queryItems = [URLQueryItem(name: "reason", value: safeReason)]
        return "\(safeEpisodeName(title.isEmpty ? "不可用" : title))$\(components.url?.absoluteString ?? "netvplayer-unavailable://drive-share")"
    }

    private func providerImage(_ provider: DriveProvider) -> String {
        switch provider {
        case .ali: return "https://img.alicdn.com/imgextra/i3/O1CN01fI0Vgb1iHn5wIr0nY_!!6000000004385-2-tps-1024-1024.png"
        case .p115: return "https://115.com/favicon.ico"
        case .quark: return "https://pan.quark.cn/favicon.ico"
        case .uc: return "https://drive.uc.cn/favicon.ico"
        case .baidu: return "https://pan.baidu.com/res/static/images/favicon.ico"
        case .cloud123: return "https://www.123pan.com/favicon.ico"
        case .xunlei: return "https://pan.xunlei.com/favicon.ico"
        case .mobile: return "https://yun.139.com/favicon.ico"
        case .tianyi: return "https://cloud.189.cn/favicon.ico"
        default: return ""
        }
    }

    private func safeClassID(_ value: String) -> String {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "all" }
        return cleaned.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? cleaned
    }
}

/// Public-shell replacement for the FongMi-compatible `我的网盘` source.
///
/// The old source is a private legacy provider and is intentionally omitted
/// from public exports. This adapter keeps the same aliases and routes share
/// URLs through the common DriveShareExpander instead of a Node bundle.
public struct MyDrivePublicProvider: SiteContentProvider {
    public typealias CredentialProvider = @Sendable (DriveProvider) -> CloudCredential?

    private let credentialProvider: CredentialProvider
    private let driveExpander: DriveShareExpander

    public init(
        credentialProvider: @escaping CredentialProvider = { _ in nil },
        driveExpander: DriveShareExpander = .shared
    ) {
        self.credentialProvider = credentialProvider
        self.driveExpander = driveExpander
    }

    public func homeContent(site: Site) async throws -> Result {
        let entries = Self.entries(credentialProvider: credentialProvider)
        return Result(
            types: Self.classes,
            list: entries.map { $0.vod(siteKey: site.key) },
            key: site.key,
            page: 1,
            pagecount: 1,
            total: entries.count
        )
    }

    public func categoryContent(site: Site, tid: String, page: String, filter: Bool, extend: [String: String]) async throws -> Result {
        let allEntries = Self.entries(credentialProvider: credentialProvider)
        let entries = allEntries.filter { tid.isEmpty || tid == "all" || $0.classID == tid }
        return Result(
            types: Self.classes,
            list: entries.map { $0.vod(siteKey: site.key) },
            key: site.key,
            page: max(Int(page) ?? 1, 1),
            pagecount: 1,
            total: entries.count
        )
    }

    public func detailContent(site: Site, id: String) async throws -> Result {
        guard let entry = MyDrivePublicEntry.decode(id) else {
            return Result(list: [Vod(vodId: id, vodName: id, siteKey: site.key)], key: site.key)
        }
        if entry.action == .manageAccounts {
            return Result(list: [], key: site.key, page: 1, pagecount: 1, total: 0)
        }

        let playItems: [String]
        switch await driveExpander.expansionOutcome(url: entry.shareURL, fallbackTitle: entry.title) {
        case .expanded(let episodes):
            playItems = episodes.map { "\(Self.safeEpisodeName($0.name))$\($0.url)" }
        case .unavailable(let reason):
            playItems = [Self.unavailableEpisode(title: entry.title, reason: reason)]
        }
        let vod = Vod(
            vodId: id,
            vodName: entry.title,
            vodContent: entry.summary,
            vodRemarks: entry.provider.displayName,
            vodPlayFrom: entry.provider.displayName,
            vodPlayUrl: playItems.joined(separator: "#"),
            siteKey: site.key
        )
        return Result(list: [vod], key: site.key)
    }

    public func playerContent(site: Site, flag: String, id: String) async throws -> Result {
        Result(url: id, parse: 0, jx: 0, flag: flag, key: site.key)
    }

    public func searchContent(site: Site, keyword: String, quick: Bool, page: String) async throws -> Result {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = DriveFileReference.provider(for: trimmed)
        guard provider != .unknown else {
            return Result(list: [], key: site.key, page: max(Int(page) ?? 1, 1), pagecount: 1, total: 0)
        }
        let entry = MyDrivePublicEntry(
            provider: provider,
            classID: provider.rawValue,
            title: trimmed,
            summary: "手动输入分享链接，详情页会先展开目录再生成播放集数。",
            shareURL: trimmed,
            action: nil
        )
        return Result(
            list: [entry.vod(siteKey: site.key)],
            key: site.key,
            page: max(Int(page) ?? 1, 1),
            pagecount: 1,
            total: 1
        )
    }

    private static let classes = [
        VodClass(typeId: "settings", typeName: "网盘配置"),
        VodClass(typeId: "quark", typeName: "夸克"),
        VodClass(typeId: "uc", typeName: "UC"),
        VodClass(typeId: "baidu", typeName: "百度"),
        VodClass(typeId: "p115", typeName: "115"),
        VodClass(typeId: "cloud123", typeName: "123"),
        VodClass(typeId: "pikpak", typeName: "PikPak"),
        VodClass(typeId: "xunlei", typeName: "迅雷"),
        VodClass(typeId: "tianyi", typeName: "天翼"),
        VodClass(typeId: "mobile", typeName: "移动")
    ]

    private static let supportedProviders: [DriveProvider] = [
        .quark, .uc, .baidu, .p115, .cloud123, .pikpak, .xunlei, .tianyi, .mobile
    ]

    private static func entries(credentialProvider: CredentialProvider) -> [MyDrivePublicEntry] {
        let manage = MyDrivePublicEntry(
            provider: .unknown,
            classID: "settings",
            title: "登录与授权",
            summary: "扫码或手动配置网盘 Cookie / token；授权后才能播放需要登录的资源。",
            shareURL: "",
            action: .manageAccounts
        )
        let providers = supportedProviders.map { provider in
            let hasCredential = credentialProvider(provider) != nil
            let status = hasCredential ? "已配置授权" : "未配置授权"
            return MyDrivePublicEntry(
                provider: provider,
                classID: provider.rawValue,
                title: "\(provider.displayName) · \(status)",
                summary: "将\(provider.displayName)分享链接粘贴到搜索框即可展开；播放个人网盘文件需要先完成授权。",
                shareURL: "",
                action: .manageAccounts
            )
        }
        return [manage] + providers
    }

    private static func safeEpisodeName(_ value: String) -> String {
        value.replacingOccurrences(of: "$", with: " ")
            .replacingOccurrences(of: "#", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? "正片"
    }

    private static func unavailableEpisode(title: String, reason: String) -> String {
        var components = URLComponents()
        components.scheme = "netvplayer-unavailable"
        components.host = "my-drive"
        components.queryItems = [URLQueryItem(name: "reason", value: reason)]
        return "\(safeEpisodeName(title))$\(components.url?.absoluteString ?? "netvplayer-unavailable://my-drive")"
    }
}

/// Public-shell configuration-center adapter. Cards are navigation actions,
/// so AppState handles them without opening a fake playback detail page.
public struct ConfigurationCenterPublicProvider: SiteContentProvider {
    private struct Entry: Sendable {
        let section: ConfigurationCenterSection
        let title: String
        let summary: String

        func vod(siteKey: String) -> Vod {
            Vod(
                vodId: ConfigurationCenterAction.open(section).vodID,
                vodName: title,
                vodContent: summary,
                vodRemarks: "配置中心",
                siteKey: siteKey
            )
        }
    }

    private static let entries = [
        Entry(section: .dataSource, title: "视频配置与网盘授权", summary: "管理点播、直播、搜索源和网盘登录。"),
        Entry(section: .providers, title: "Provider 运行时", summary: "查看已安装的原生和签名 Provider。"),
        Entry(section: .playback, title: "播放偏好", summary: "调整播放器、字幕、弹幕和跳过片头设置。"),
        Entry(section: .network, title: "网络与代理", summary: "配置代理、端口和播放中继。"),
        Entry(section: .system, title: "缓存与系统", summary: "清理缓存、备份配置和查看诊断信息。"),
        Entry(section: .appearance, title: "外观主题", summary: "选择主题背景和界面强调色。")
    ]

    public init() {}

    public func homeContent(site: Site) async throws -> Result {
        Result(
            types: [VodClass(typeId: "settings", typeName: "配置中心")],
            list: Self.entries.map { $0.vod(siteKey: site.key) },
            key: site.key,
            page: 1,
            pagecount: 1,
            total: Self.entries.count
        )
    }

    public func categoryContent(site: Site, tid: String, page: String, filter: Bool, extend: [String: String]) async throws -> Result {
        try await homeContent(site: site)
    }

    public func detailContent(site: Site, id: String) async throws -> Result {
        guard ConfigurationCenterAction.decode(vodID: id) != nil else { return .empty }
        return Result(list: [], key: site.key, page: 1, pagecount: 1, total: 0)
    }

    public func playerContent(site: Site, flag: String, id: String) async throws -> Result {
        Result(url: id, parse: 0, jx: 0, flag: flag, key: site.key)
    }

    public func searchContent(site: Site, keyword: String, quick: Bool, page: String) async throws -> Result {
        Result(list: [], key: site.key, page: max(Int(page) ?? 1, 1), pagecount: 1, total: 0)
    }
}

private struct MyDrivePublicEntry: Sendable {
    let provider: DriveProvider
    let classID: String
    let title: String
    let summary: String
    let shareURL: String
    let action: MyDriveConfigurationAction?

    var encodedID: String {
        var object = [
            "provider": provider.rawValue,
            "class_id": classID,
            "title": title,
            "summary": summary,
            "share_url": shareURL
        ]
        if let action {
            switch action {
            case .manageAccounts:
                object["action"] = "manage_accounts"
            case .clearCredential(let provider):
                object["action"] = "clear_credential:\(provider.rawValue)"
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return shareURL }
        return "mydrive://entry/\(ProxySafeBase64.encode(data))"
    }

    func vod(siteKey: String) -> Vod {
        Vod(
            vodId: encodedID,
            vodName: title,
            vodPic: providerImage,
            vodContent: summary,
            vodRemarks: action == nil ? provider.displayName : "网盘配置",
            siteKey: siteKey
        )
    }

    var providerImage: String {
        switch provider {
        case .quark: return "https://pan.quark.cn/favicon.ico"
        case .uc: return "https://drive.uc.cn/favicon.ico"
        case .baidu: return "https://pan.baidu.com/res/static/images/favicon.ico"
        case .p115: return "https://115.com/favicon.ico"
        default: return ""
        }
    }

    static func decode(_ id: String) -> MyDrivePublicEntry? {
        guard let url = URL(string: id),
              url.scheme?.lowercased() == "mydrive",
              let encoded = url.pathComponents.last,
              let data = ProxySafeBase64.decode(encoded),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let title = object["title"] else { return nil }
        let provider = DriveProvider(rawValue: object["provider"] ?? "") ?? .unknown
        let action: MyDriveConfigurationAction?
        switch object["action"] {
        case "manage_accounts": action = .manageAccounts
        case let value? where value.hasPrefix("clear_credential:"):
            let raw = String(value.dropFirst("clear_credential:".count))
            action = DriveProvider(rawValue: raw).map(MyDriveConfigurationAction.clearCredential)
        default: action = nil
        }
        return MyDrivePublicEntry(
            provider: provider,
            classID: object["class_id"] ?? provider.rawValue,
            title: title,
            summary: object["summary"] ?? "",
            shareURL: object["share_url"] ?? "",
            action: action
        )
    }
}

private struct DriveShareCatalog: Sendable {
    var classes: [DriveShareCatalogClass]
    var entries: [DriveShareCatalogEntry]
}

private struct DriveShareCatalogClass: Sendable, Equatable {
    var id: String
    var name: String
}

private struct DriveShareCatalogEntry: Sendable {
    var provider: DriveProvider
    var classID: String
    var title: String
    var shareURL: String

    var encodedID: String {
        let object = [
            "provider": provider.rawValue,
            "class_id": classID,
            "title": title,
            "share_url": shareURL
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            return shareURL
        }
        return "driveshare://entry/\(ProxySafeBase64.encode(data))"
    }

    static func decode(_ id: String) -> DriveShareCatalogEntry? {
        guard let url = URL(string: id),
              url.scheme == "driveshare",
              let encoded = url.pathComponents.last,
              let data = ProxySafeBase64.decode(encoded),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let rawProvider = object["provider"],
              let provider = DriveProvider(rawValue: rawProvider),
              let title = object["title"],
              let shareURL = object["share_url"] else {
            return nil
        }
        return DriveShareCatalogEntry(
            provider: provider,
            classID: object["class_id"] ?? "all",
            title: title,
            shareURL: shareURL
        )
    }
}

public struct WebDAVNativeProvider: SiteContentProvider {
    private let session: URLSession
    private let defaultHeaders: [String: String]
    private let allowedOrigin: URL?

    public init(
        session: URLSession = .shared,
        defaultHeaders: [String: String] = [:],
        allowedOrigin: URL? = nil
    ) {
        self.session = session
        self.defaultHeaders = defaultHeaders
        self.allowedOrigin = allowedOrigin
    }

    public func homeContent(site: Site) async throws -> Result {
        let drives = try await drives(from: site)
        let classes = drives.map { VodClass(typeId: $0.name, typeName: $0.name) }
        return Result(types: classes, filters: Dictionary(uniqueKeysWithValues: classes.map { ($0.typeId, AListNativeProvider.sortFilters) }), key: site.key)
    }

    public func categoryContent(site: Site, tid: String, page: String, filter: Bool, extend: [String: String]) async throws -> Result {
        let drives = try await drives(from: site)
        let (driveName, path) = splitDrivePath(tid)
        guard let drive = drives.first(where: { $0.name == driveName }) ?? drives.first else { return .empty }
        let items = try await propfind(drive: drive, path: path.isEmpty ? drive.path : path)
        let sorted = sort(items: items, type: extend["type"] ?? "", order: extend["order"] ?? "")
        let vods = sorted.filter { $0.isDirectory || AListNativeProvider.isMedia($0.name) }.map { item in
            Vod(
                vodId: "\(drive.name)\(item.path)",
                vodName: item.name,
                vodPic: item.isDirectory ? "folder" : "video",
                vodRemarks: item.isDirectory ? "目录" : byteCount(item.size),
                siteKey: site.key
            )
        }
        return Result(list: vods, key: site.key, page: Int(page) ?? 1, pagecount: 1, total: vods.count)
    }

    public func detailContent(site: Site, id: String) async throws -> Result {
        let drives = try await drives(from: site)
        let (driveName, path) = splitDrivePath(id)
        guard let drive = drives.first(where: { $0.name == driveName }) ?? drives.first else { return .empty }
        let siblings = try await propfind(drive: drive, path: parentPath(for: path))
        let subtitles = siblings.filter { AListNativeProvider.isSubtitle($0.name) }
        let playItems = siblings.filter { !$0.isDirectory && AListNativeProvider.isMedia($0.name) }.map { item in
            let subs = matchingSubtitles(for: item, siblings: subtitles).map { sub in
                Sub(name: sub.name, url: webDAVPlaybackURL(drive: drive, item: sub), format: fileExtension(sub.name))
            }
            return "\(safeEpisodeName(item.name))$\(webDAVPlaybackURL(drive: drive, item: item, subs: subs))"
        }
        let vod = Vod(vodId: id, vodName: path.split(separator: "/").last.map(String.init) ?? drive.name, vodPic: "video", vodPlayFrom: drive.name, vodPlayUrl: playItems.joined(separator: "#"), siteKey: site.key)
        return Result(list: [vod], key: site.key)
    }

    public func playerContent(site: Site, flag: String, id: String) async throws -> Result {
        let request = try WebDAVPlaybackRequest(url: id)
        return Result(url: request.url, flag: flag, header: request.headers, key: site.key, subs: request.subs)
    }

    public func searchContent(site: Site, keyword: String, quick: Bool, page: String) async throws -> Result {
        Result(list: [], key: site.key, page: Int(page) ?? 1, pagecount: 1)
    }

    private func drives(from site: Site) async throws -> [WebDAVDrive] {
        let ext = site.ext.trimmingCharacters(in: .whitespacesAndNewlines)
        let text: String
        if isReadableResource(ext) {
            text = try await loadTextResource(ext, httpClient: .shared, headers: site.header)
        } else {
            text = ext
        }
        let parsed = WebDAVDrive.array(from: text)
        return parsed.isEmpty
            ? [WebDAVDrive(
                name: site.name.isEmpty ? site.key : site.name,
                server: site.api,
                path: "/",
                headers: defaultHeaders
            )]
            : parsed
    }

    private func propfind(drive: WebDAVDrive, path: String) async throws -> [WebDAVItem] {
        guard let url = URL(string: URLHelper.resolve(base: drive.server.ensureTrailingSlash(), relative: normalizedPath(path).dropFirstSlash())) else {
            throw SpiderEngineError.nativeReplacementUnsupported(site: "csp_WebDAV", capability: "invalid URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")
        for (key, value) in drive.headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HTTPError.invalidResponse
        }
        if let allowedOrigin {
            guard let finalURL = httpResponse.url, sameOrigin(finalURL, allowedOrigin) else {
                throw HTTPError.originMismatch
            }
        }
        return WebDAVItem.parse(data: data, basePath: normalizedPath(path))
    }

    private func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard lhs.scheme?.lowercased() == rhs.scheme?.lowercased(),
              lhs.host?.lowercased() == rhs.host?.lowercased() else {
            return false
        }
        let lhsPort = lhs.port ?? (lhs.scheme?.lowercased() == "https" ? 443 : 80)
        let rhsPort = rhs.port ?? (rhs.scheme?.lowercased() == "https" ? 443 : 80)
        return lhsPort == rhsPort
    }

    private func sort(items: [WebDAVItem], type: String, order: String) -> [WebDAVItem] {
        let sorted: [WebDAVItem]
        switch type {
        case "name":
            sorted = items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case "size":
            sorted = items.sorted { $0.size < $1.size }
        case "date":
            sorted = items.sorted { ($0.modified ?? .distantPast) < ($1.modified ?? .distantPast) }
        default:
            sorted = items
        }
        return order == "desc" ? sorted.reversed() : sorted
    }

    private func webDAVPlaybackURL(drive: WebDAVDrive, item: WebDAVItem, subs: [Sub] = []) -> String {
        let url = URLHelper.resolve(base: drive.server.ensureTrailingSlash(), relative: item.path.dropFirstSlash())
        return WebDAVPlaybackRequest.makeURL(url: url, headers: drive.headers, subs: subs)
    }

    private func matchingSubtitles(for item: WebDAVItem, siblings: [WebDAVItem]) -> [WebDAVItem] {
        let stem = fileStem(item.name)
        let exact = siblings.filter { fileStem($0.name).localizedCaseInsensitiveCompare(stem) == .orderedSame }
        return exact.isEmpty ? siblings : exact
    }

    private func splitDrivePath(_ id: String) -> (String, String) {
        guard let slash = id.firstIndex(of: "/") else { return (id, "/") }
        return (String(id[..<slash]), String(id[slash...]))
    }
}

public struct PushNativeProvider: SiteContentProvider {
    public init() {}

    public func homeContent(site: Site) async throws -> Result {
        Result(types: [VodClass(typeId: "push", typeName: "推送")], key: site.key)
    }

    public func categoryContent(site: Site, tid: String, page: String, filter: Bool, extend: [String: String]) async throws -> Result {
        Result(list: [], key: site.key, page: Int(page) ?? 1, pagecount: 1)
    }

    public func detailContent(site: Site, id: String) async throws -> Result {
        let url = decodePushURL(id)
        let escaped = url.replacingOccurrences(of: "#", with: "***")
        let episode = "\(safeEpisodeName(displayName(for: url)))$\(escaped)"
        let flags: [(String, String)]
        if url.contains("$") {
            flags = [("直连", escaped)]
        } else {
            flags = [
                ("直连", episode),
                ("嗅探", episode),
                ("解析", episode)
            ]
        }
        let vod = Vod(
            vodId: id,
            vodName: displayName(for: url),
            vodPic: "video",
            vodPlayFrom: flags.map(\.0).joined(separator: "$$$"),
            vodPlayUrl: flags.map(\.1).joined(separator: "$$$"),
            siteKey: site.key
        )
        return Result(list: [vod], key: site.key)
    }

    public func playerContent(site: Site, flag: String, id: String) async throws -> Result {
        let url = decodePushURL(id).replacingOccurrences(of: "***", with: "#")
        switch flag {
        case "解析":
            return Result(url: url, parse: 1, jx: 1, flag: flag, key: site.key)
        case "嗅探":
            return Result(url: url, parse: 1, jx: 0, flag: flag, key: site.key)
        default:
            return Result(url: url, parse: 0, jx: 0, flag: flag, key: site.key, subs: localSubtitles(for: url))
        }
    }

    public func searchContent(site: Site, keyword: String, quick: Bool, page: String) async throws -> Result {
        Result(list: [], key: site.key, page: Int(page) ?? 1, pagecount: 1)
    }

    private func decodePushURL(_ value: String) -> String {
        value.removingPercentEncoding ?? value
    }

    private func displayName(for url: String) -> String {
        if let parsed = URL(string: url), parsed.isFileURL {
            return parsed.lastPathComponent
        }
        return URL(string: url)?.lastPathComponent.nilIfEmpty ?? url
    }

    private func localSubtitles(for url: String) -> [Sub] {
        guard let parsed = URL(string: url), parsed.isFileURL else { return [] }
        let file = parsed
        let directory = file.deletingLastPathComponent()
        let stem = file.deletingPathExtension().lastPathComponent
        let items = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return items
            .filter { AListNativeProvider.isSubtitle($0.lastPathComponent) }
            .filter { $0.deletingPathExtension().lastPathComponent.localizedCaseInsensitiveCompare(stem) == .orderedSame }
            .map { Sub(name: $0.lastPathComponent, url: $0.absoluteString, format: $0.pathExtension.lowercased()) }
    }
}

public struct AListPlaybackRequest: Sendable {
    public let server: String
    public let path: String
    public let password: String
    public let headers: [String: String]
    public let subs: [Sub]

    public init(url: String) throws {
        guard let components = URLComponents(string: url),
              components.scheme?.lowercased() == "alist" else {
            throw SpiderEngineError.nativeReplacementUnsupported(site: "csp_AList", capability: "invalid alist URL")
        }
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        self.server = query["server"] ?? ""
        self.path = query["path"] ?? ""
        self.password = query["password"] ?? ""
        self.headers = decodeStringMap(query["headers"])
        self.subs = decodeSubs(query["subs"])
    }

    static func makeURL(server: String, path: String, password: String = "", headers: [String: String] = [:], subs: [Sub] = []) -> String {
        var components = URLComponents()
        components.scheme = "alist"
        components.host = "file"
        components.queryItems = [
            URLQueryItem(name: "server", value: server),
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "password", value: password),
            URLQueryItem(name: "headers", value: encodeStringMap(headers))
        ]
        if !subs.isEmpty {
            components.queryItems?.append(URLQueryItem(name: "subs", value: encodeSubs(subs)))
        }
        return components.url?.absoluteString ?? path
    }
}

public struct AListPlaybackLink: Sendable {
    public let url: String
    public let headers: [String: String]
    public let subs: [Sub]
}

private struct AListPostResponse: @unchecked Sendable {
    let object: [String: Any]
    let updatedHeaders: [String: String]?
}

public struct WebDAVPlaybackRequest: Sendable {
    public let url: String
    public let headers: [String: String]
    public let subs: [Sub]

    public init(url: String) throws {
        guard let components = URLComponents(string: url),
              components.scheme?.lowercased() == "webdav" else {
            throw SpiderEngineError.nativeReplacementUnsupported(site: "csp_WebDAV", capability: "invalid webdav URL")
        }
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        self.url = query["url"] ?? ""
        self.headers = decodeStringMap(query["headers"])
        self.subs = decodeSubs(query["subs"])
    }

    static func makeURL(url: String, headers: [String: String], subs: [Sub] = []) -> String {
        var components = URLComponents()
        components.scheme = "webdav"
        components.host = "file"
        components.queryItems = [
            URLQueryItem(name: "url", value: url),
            URLQueryItem(name: "headers", value: encodeStringMap(headers))
        ]
        if !subs.isEmpty {
            components.queryItems?.append(URLQueryItem(name: "subs", value: encodeSubs(subs)))
        }
        return components.url?.absoluteString ?? url
    }
}

private struct AListDrive: Sendable {
    let name: String
    let server: String
    let path: String
    let password: String
    let searchable: Bool
    let hidden: Bool
    var headers: [String: String]
    let loginUsername: String
    let loginPassword: String
    let pathPasswords: [AListPathPassword]

    init(
        name: String,
        server: String,
        path: String = "/",
        password: String = "",
        searchable: Bool = true,
        hidden: Bool = false,
        headers: [String: String] = [:],
        loginUsername: String = "",
        loginPassword: String = "",
        pathPasswords: [AListPathPassword] = []
    ) {
        self.name = name
        self.server = server.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.path = normalizedPath(path)
        self.password = password
        self.searchable = searchable
        self.hidden = hidden
        self.headers = headers
        self.loginUsername = loginUsername
        self.loginPassword = loginPassword
        self.pathPasswords = pathPasswords
    }

    init?(_ dict: [String: Any]) {
        let name = firstString(dict, keys: ["name", "title"])
        let server = firstString(dict, keys: ["server", "url", "host"])
        guard !name.isEmpty, !server.isEmpty else { return nil }
        var headers = (dict["headers"] as? [String: String]) ?? (dict["header"] as? [String: String]) ?? [:]
        if let token = dict["token"] as? String, !token.isEmpty {
            headers["Authorization"] = token.hasPrefix("Bearer ") ? token : "Bearer \(token)"
        }
        let login = dict["login"] as? [String: Any]
        let pathPasswords = (dict["params"] as? [[String: Any]] ?? []).compactMap(AListPathPassword.init)
        self.init(
            name: name,
            server: server,
            path: firstString(dict, keys: ["path", "root"]).nilIfEmpty ?? "/",
            password: firstString(dict, keys: ["password", "pass"]),
            searchable: boolValue(dict["search"] ?? dict["searchable"], defaultValue: true),
            hidden: boolValue(dict["hidden"] ?? dict["hide"], defaultValue: false),
            headers: headers,
            loginUsername: login.map { firstString($0, keys: ["username", "user"]) } ?? "",
            loginPassword: login.map { firstString($0, keys: ["password", "pass"]) } ?? "",
            pathPasswords: pathPasswords
        )
    }

    func password(for itemPath: String) -> String {
        let normalized = normalizedPath(itemPath)
        return pathPasswords.first { normalized.hasPrefix($0.path) }?.password ?? password
    }
}

private struct AListPathPassword: Sendable {
    let path: String
    let password: String

    init?(_ dict: [String: Any]) {
        let path = firstString(dict, keys: ["path", "root"])
        let password = firstString(dict, keys: ["pass", "password"])
        guard !path.isEmpty || !password.isEmpty else { return nil }
        self.path = normalizedPath(path)
        self.password = password
    }
}

private struct AListItem: Sendable {
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int64
    let modified: String

    init?(_ dict: [String: Any]) {
        let name = firstString(dict, keys: ["name", "file_name"])
        guard !name.isEmpty else { return nil }
        self.name = name
        self.path = normalizedPath(firstString(dict, keys: ["path", "id", "url"]).nilIfEmpty ?? "/\(name)")
        self.isDirectory = boolValue(dict["is_dir"] ?? dict["isDirectory"] ?? dict["folder"], defaultValue: false)
        self.size = int64Value(dict["size"])
        self.modified = firstString(dict, keys: ["modified", "updated_at", "time", "date"])
    }
}

private struct WebDAVDrive: Sendable {
    let name: String
    let server: String
    let path: String
    let headers: [String: String]

    init(name: String, server: String, path: String = "/", headers: [String: String] = [:]) {
        self.name = name
        self.server = server
        self.path = normalizedPath(path)
        self.headers = headers
    }

    static func array(from ext: String) -> [WebDAVDrive] {
        guard let data = ext.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let raw: [[String: Any]]
        if let dict = object as? [String: Any], let drives = dict["drives"] as? [[String: Any]] {
            raw = drives
        } else if let drives = object as? [[String: Any]] {
            raw = drives
        } else {
            raw = []
        }
        return raw.compactMap { dict in
            let name = firstString(dict, keys: ["name", "title"])
            let server = firstString(dict, keys: ["server", "url", "host"])
            guard !name.isEmpty, !server.isEmpty else { return nil }
            var headers = (dict["headers"] as? [String: String]) ?? [:]
            let username = firstString(dict, keys: ["username", "user"])
            let password = firstString(dict, keys: ["password", "pass"])
            if !username.isEmpty || !password.isEmpty {
                let auth = Data("\(username):\(password)".utf8).base64EncodedString()
                headers["Authorization"] = "Basic \(auth)"
            }
            return WebDAVDrive(name: name, server: server, path: firstString(dict, keys: ["path", "root"]).nilIfEmpty ?? "/", headers: headers)
        }
    }
}

private struct WebDAVItem: Sendable {
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int64
    let modified: Date?

    static func parse(data: Data, basePath: String) -> [WebDAVItem] {
        let responses = WebDAVXMLParser.parse(data: data)
        let base = normalizedPath(basePath)
        return responses.compactMap { block in
            let href = block.href.removingPercentEncoding ?? block.href
            guard !href.isEmpty else { return nil }
            let path = normalizedPath(URL(string: href)?.path ?? href)
            guard path != base && path != base.ensureTrailingSlash() else { return nil }
            let name = path.split(separator: "/").last.map(String.init) ?? path
            return WebDAVItem(
                name: name,
                path: path,
                isDirectory: block.isDirectory,
                size: block.size,
                modified: block.modified
            )
        }
    }
}

private final class WebDAVXMLParser: NSObject, XMLParserDelegate {
    struct Response {
        var href: String = ""
        var isDirectory: Bool = false
        var size: Int64 = 0
        var modified: Date?
    }

    private var responses: [Response] = []
    private var current: Response?
    private var currentElement = ""
    private var text = ""

    static func parse(data: Data) -> [Response] {
        let delegate = WebDAVXMLParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.responses
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let name = localName(qName ?? elementName)
        currentElement = name
        text = ""
        if name == "response" {
            current = Response()
        } else if name == "collection" {
            current?.isDirectory = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = localName(qName ?? elementName)
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "href":
            current?.href = value
        case "getcontentlength":
            current?.size = Int64(value) ?? 0
        case "getlastmodified":
            current?.modified = Self.httpDateFormatter.date(from: value)
        case "response":
            if let current { responses.append(current) }
            current = nil
        default:
            break
        }
        currentElement = ""
        text = ""
    }

    private func localName(_ value: String) -> String {
        value.split(separator: ":").last.map(String.init) ?? value
    }

    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()
}

private func isReadableResource(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") || trimmed.hasPrefix("file://") || trimmed.hasPrefix("assets://") {
        return true
    }
    return FileManager.default.fileExists(atPath: trimmed)
}

private func loadTextResource(_ value: String, httpClient: HTTPClient, headers: [String: String] = [:]) async throws -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("assets://") {
        let path = String(trimmed.dropFirst("assets://".count))
        let fileURL = URL(fileURLWithPath: path)
        let candidates = [
            Bundle.main.url(forResource: fileURL.deletingPathExtension().lastPathComponent, withExtension: fileURL.pathExtension.isEmpty ? nil : fileURL.pathExtension),
            Bundle.main.resourceURL?.appendingPathComponent(path)
        ].compactMap { $0 }
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            return try String(contentsOf: candidate, encoding: .utf8)
        }
    }
    if trimmed.hasPrefix("file://"), let url = URL(string: trimmed) {
        return try String(contentsOf: url, encoding: .utf8)
    }
    if FileManager.default.fileExists(atPath: trimmed) {
        return try String(contentsOfFile: trimmed, encoding: .utf8)
    }
    let response = try await httpClient.get(url: trimmed, headers: headers, timeout: 30)
    return response.text
}

private func sameServer(_ lhs: String, _ rhs: String) -> Bool {
    let left = lhs.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
    let right = rhs.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
    return !left.isEmpty && left == right
}

private func firstString(_ dict: [String: Any], keys: [String]) -> String {
    for key in keys {
        if let value = dict[key] {
            let text = stringValue(value)
            if !text.isEmpty { return text }
        }
    }
    return ""
}

private func stringValue(_ value: Any?) -> String {
    if let value = value as? String { return value }
    if let value = value as? NSNumber { return value.stringValue }
    return ""
}

private func boolValue(_ value: Any?, defaultValue: Bool) -> Bool {
    if let value = value as? Bool { return value }
    if let value = value as? NSNumber { return value.boolValue }
    if let value = value as? String {
        if ["1", "true", "yes"].contains(value.lowercased()) { return true }
        if ["0", "false", "no"].contains(value.lowercased()) { return false }
    }
    return defaultValue
}

private func int64Value(_ value: Any?) -> Int64 {
    if let value = value as? Int64 { return value }
    if let value = value as? Int { return Int64(value) }
    if let value = value as? NSNumber { return value.int64Value }
    if let value = value as? String { return Int64(value) ?? 0 }
    return 0
}

private func normalizedPath(_ path: String) -> String {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "/" }
    return trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
}

private func parentPath(for path: String) -> String {
    let normalized = normalizedPath(path)
    guard let slash = normalized.lastIndex(of: "/"), slash != normalized.startIndex else { return "/" }
    return String(normalized[..<slash])
}

private func safeEpisodeName(_ value: String) -> String {
    let stem = fileStem(value)
    return stem.isEmpty ? value.replacingOccurrences(of: "$", with: " ").replacingOccurrences(of: "#", with: " ") : stem
}

private func fileExtension(_ name: String) -> String {
    URL(fileURLWithPath: name).pathExtension.lowercased()
}

private func fileStem(_ name: String) -> String {
    let url = URL(fileURLWithPath: name)
    let stem = url.deletingPathExtension().lastPathComponent
    return stem.replacingOccurrences(of: "$", with: " ").replacingOccurrences(of: "#", with: " ")
}

private func byteCount(_ size: Int64) -> String {
    guard size > 0 else { return "" }
    return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
}

private func encodeStringMap(_ map: [String: String]) -> String {
    guard JSONSerialization.isValidJSONObject(map),
          let data = try? JSONSerialization.data(withJSONObject: map) else { return "" }
    return ProxySafeBase64.encode(data)
}

private func decodeStringMap(_ encoded: String?) -> [String: String] {
    guard let encoded, let data = ProxySafeBase64.decode(encoded),
          let map = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
    return map
}

private func encodeSubs(_ subs: [Sub]) -> String {
    guard let data = try? JSONEncoder().encode(subs) else { return "" }
    return ProxySafeBase64.encode(data)
}

private func decodeSubs(_ encoded: String?) -> [Sub] {
    guard let encoded, let data = ProxySafeBase64.decode(encoded),
          let subs = try? JSONDecoder().decode([Sub].self, from: data) else { return [] }
    return subs
}

private enum ProxySafeBase64 {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ value: String) -> Data? {
        var normalized = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder > 0 {
            normalized.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: normalized)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }

    func ensureTrailingSlash() -> String {
        hasSuffix("/") ? self : "\(self)/"
    }

    func dropFirstSlash() -> String {
        hasPrefix("/") ? String(dropFirst()) : self
    }

    func appendingPathComponent(_ path: String) -> String {
        ensureTrailingSlash() + path.dropFirstSlash()
    }

    func removingHTMLTags() -> String {
        replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
