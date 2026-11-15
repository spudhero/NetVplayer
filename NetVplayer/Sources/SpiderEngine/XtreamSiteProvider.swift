import Foundation
import Models
import Networking
import Storage

/// Native, user-configured Xtream adapter. Catalogues contain opaque resource IDs.
public actor XtreamSiteProvider: SiteContentProvider, SiteContentCacheClearing {
    public nonisolated let configuration: XtreamConfiguration
    private let credentials: @Sendable () throws -> XtreamCredentials
    private let client: HTTPClient
    private var catalogs: [String: (Date, [[String: JSONDynamicValue]])] = [:]
    private var authorizedAt: Date?
    private var authorizedCredentials: XtreamCredentials?
    private var previewConnections = XtreamPreviewConnections(maximum: nil, active: nil)
    private var serverTimeZone: TimeZone?
    private var sessionID = UUID()
    private var authenticationRevision = UUID()
    private var observedCredentials: XtreamCredentials?
    private var historyCache: [String: (Date, EpgData)] = [:]
    private var historyFailures: [String: Date] = [:]
    private var epgRequests: [String: UUID] = [:]
    private var epgCache: [String: (Date, EpgData)] = [:]

    public init(configuration: XtreamConfiguration, client: HTTPClient? = nil,
                credentials: (@Sendable () throws -> XtreamCredentials)? = nil) throws {
        self.configuration = try configuration.validated()
        self.credentials = credentials ?? {
            guard let owned = UserPreferences.shared.xtreamConfigurations.first(where: { $0.id == configuration.id }),
                  owned.server == configuration.server, owned.allowsHTTP == configuration.allowsHTTP else { throw XtreamError.authorizationRequired }
            return try UserPreferences.shared.xtreamCredentials(for: configuration.id, server: configuration.server)
        }
        let session = URLSession(configuration: .ephemeral)
        self.client = (client ?? HTTPClient(session: session)).constrained(to: URL(string: configuration.server)!)
    }

    public func clearContentCache() {
        sessionID = UUID()
        authenticationRevision = UUID()
        catalogs.removeAll(); epgCache.removeAll(); historyCache.removeAll(); historyFailures.removeAll(); epgRequests.removeAll()
        authorizedAt = nil; authorizedCredentials = nil; serverTimeZone = nil
        previewConnections = .init(maximum: nil, active: nil)
    }

    @discardableResult private func currentCredentials() throws -> XtreamCredentials {
        do {
            let account = try credentials()
            guard !account.username.isEmpty, !account.password.isEmpty else { throw XtreamError.authorizationRequired }
            if observedCredentials != account { clearContentCache(); observedCredentials = account }
            return account
        } catch {
            clearContentCache(); observedCredentials = nil
            throw error
        }
    }

    private func checkSession(_ session: UUID) throws {
        try Task.checkCancellation()
        _ = try currentCredentials()
        guard session == sessionID else { throw CancellationError() }
    }

    public func authenticate(forceRefresh: Bool = false) async throws {
        let account = try currentCredentials()
        let session = sessionID
        if !forceRefresh, let authorizedAt, Date().timeIntervalSince(authorizedAt) < 30,
           authorizedCredentials?.username == account.username, authorizedCredentials?.password == account.password { return }
        if forceRefresh { authenticationRevision = UUID() }
        let revision = authenticationRevision
        let response = try await request(action: nil, maximumBytes: 1_024 * 1_024)
        try checkSession(session)
        guard revision == authenticationRevision else { throw CancellationError() }
        guard case .object(let root) = response, case .object(let info) = root["user_info"],
              info["auth"] == .bool(true) || info["auth"]?.stringValue == "1",
              let status = info["status"]?.stringValue.lowercased(), !status.isEmpty else { throw XtreamError.authorizationRequired }
        guard status == "active" else { throw XtreamError.inactiveAccount }
        if let raw = info["exp_date"]?.stringValue, !raw.isEmpty, raw != "0" {
            guard let expiry = Double(raw), expiry.isFinite else { throw XtreamError.malformedResponse }
            guard expiry > Date().timeIntervalSince1970 else { throw XtreamError.inactiveAccount }
        }
        authorizedCredentials = account; authorizedAt = Date()
        previewConnections = .init(maximum: info["max_connections"]?.stringValue,
                                   active: info["active_cons"]?.stringValue)
        serverTimeZone = nil
        if case .object(let server) = root["server_info"], let timezone = server["timezone"]?.stringValue,
           let parsed = TimeZone(identifier: timezone) { serverTimeZone = parsed }
    }

    private func request(action: String?, parameters: [String: String] = [:], maximumBytes: Int = 32 * 1024 * 1024) async throws -> JSONDynamicValue {
        let account = try currentCredentials()
        let session = sessionID
        var url = URLComponents(string: configuration.server + "/player_api.php")!
        var query = ["username": account.username, "password": account.password]
        if let action { query["action"] = action }
        query.merge(parameters) { _, new in new }
        url.queryItems = query.keys.sorted().map { URLQueryItem(name: $0, value: query[$0]) }
        do {
            let buffer = XtreamResponseBuffer(maximumBytes: maximumBytes)
            _ = try await client.stream(
                url: url.string!,
                timeout: 20,
                allowsProxyFallback: false,
                redactsURLInLogs: true,
                shouldStream: { response in
                    guard (200..<300).contains(response.statusCode) else {
                        throw XtreamError.requestFailed
                    }
                    if let rawLength = response.headers.first(where: {
                        $0.key.caseInsensitiveCompare("Content-Length") == .orderedSame
                    })?.value,
                       let contentLength = Int(rawLength),
                         contentLength > maximumBytes {
                        throw XtreamError.requestFailed
                    }
                    return true
                },
                receive: { try await buffer.append($0) }
            )
            let data = await buffer.data
            try checkSession(session)
            return try JSONDecoder().decode(JSONDynamicValue.self, from: data)
        } catch is CancellationError { throw CancellationError() }
        catch { if Task.isCancelled { throw CancellationError() }; throw XtreamError.requestFailed }
    }

    private func rows(_ action: String, parameters: [String: String] = [:], forceRefresh: Bool = false) async throws -> [[String: JSONDynamicValue]] {
        try await authenticate()
        let session = sessionID
        let key = action + parameters.sorted { $0.key < $1.key }.map { $0.key + "=" + $0.value }.joined(separator: "&")
        if !forceRefresh, let (date, rows) = catalogs[key], Date().timeIntervalSince(date) < 300 { return rows }
        let value = try await request(action: action, parameters: parameters)
        try checkSession(session)
        guard case .array(let array) = value else { throw XtreamError.malformedResponse }
        let rows = array.compactMap { value -> [String: JSONDynamicValue]? in
            guard case .object(let object) = value else { return nil }
            return object
        }
        if catalogs.count > 20 { catalogs.removeAll() }
        catalogs[key] = (Date(), rows)
        return rows
    }

    public func homeContent(site: Site) async throws -> Result {
        var categories: [VodClass] = []
        for (kind, action, label) in [("movie", "get_vod_categories", L10n.text("电影")), ("series", "get_series_categories", L10n.text("剧集"))] {
            for item in try await rows(action) {
                let id = item["category_id"]?.stringValue ?? ""
                if !id.isEmpty { categories.append(VodClass(typeId: kind + ":" + id, typeName: label + " · " + (item["category_name"]?.stringValue ?? id))) }
            }
        }
        return Result(types: categories, list: try await list(kind: "movie", category: nil, site: site).prefix(30).map { $0 })
    }

    private func list(kind: String, category: String?, site: Site) async throws -> [Vod] {
        let action = kind == "series" ? "get_series" : "get_vod_streams"
        return try await rows(action, parameters: category.map { ["category_id": $0] } ?? [:]).compactMap { item in
            let id = item[kind == "series" ? "series_id" : "stream_id"]?.stringValue ?? ""
            guard !id.isEmpty, id.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Vod(vodId: kind + ":" + id, vodName: item["name"]?.stringValue ?? id,
                vodPic: safeImage(item["stream_icon"]?.stringValue ?? item["cover"]?.stringValue ?? ""),
                vodRemarks: item["rating"]?.stringValue ?? "", siteKey: site.key)
        }
    }

    public func categoryContent(site: Site, tid: String, page: String, filter: Bool, extend: [String: String]) async throws -> Result {
        let parts = tid.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, ["movie", "series"].contains(parts[0]) else { throw XtreamError.invalidReference }
        return paginated(try await list(kind: parts[0], category: parts[1], site: site), page: page)
    }

    public func searchContent(site: Site, keyword: String, quick: Bool, page: String) async throws -> Result {
        let keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return Result() }
        let movies = try await list(kind: "movie", category: nil, site: site)
        let series = try await list(kind: "series", category: nil, site: site)
        return paginated((movies + series).filter { $0.vodName.localizedStandardContains(keyword) }, page: page)
    }

    private func paginated(_ items: [Vod], page: String) -> Result {
        let page = min(max(Int(page) ?? 1, 1), 100_000)
        return Result(list: Array(items.dropFirst((page - 1) * 50).prefix(50)), page: page, pagecount: max(1, (items.count + 49) / 50), total: items.count)
    }

    public func detailContent(site: Site, id: String) async throws -> Result {
        try await authenticate()
        let parts = id.split(separator: ":").map(String.init)
        guard parts.count == 2, ["movie", "series"].contains(parts[0]), parts[1].allSatisfy({ $0.isASCII && $0.isNumber }) else { throw XtreamError.invalidReference }
        let series = parts[0] == "series"
        let response = try await request(action: series ? "get_series_info" : "get_vod_info", parameters: [series ? "series_id" : "vod_id": parts[1]])
        guard case .object(let root) = response else { throw XtreamError.malformedResponse }
        let info: [String: JSONDynamicValue]
        switch root["info"] {
        case .object(let value): info = value
        case .array(let value) where value.isEmpty: info = [:]
        case .none, .null: info = [:]
        default: throw XtreamError.malformedResponse
        }
        let cached = try await list(kind: parts[0], category: nil, site: site).first { $0.vodId == id }
        var vod = cached ?? Vod(vodId: id, siteKey: site.key)
        vod.vodName = info["name"]?.stringValue ?? vod.vodName
        vod.vodContent = info["plot"]?.stringValue ?? ""
        vod.vodActor = info["cast"]?.stringValue ?? ""
        vod.vodDirector = info["director"]?.stringValue ?? ""
        let image = safeImage(info["cover"]?.stringValue ?? info["movie_image"]?.stringValue ?? "")
        if !image.isEmpty { vod.vodPic = image }
        if series {
            let seasons: [(String, [JSONDynamicValue])]
            switch root["episodes"] {
            case .object(let values):
                seasons = values.compactMap { key, value in if case .array(let rows) = value { return (key, rows) }; return nil }
                    .sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
            case .array(let values): seasons = [("1", values)]
            default: throw XtreamError.malformedResponse
            }
            var flags: [String] = [], urls: [String] = []
            for (season, items) in seasons {
                let episodes = items.compactMap { item -> String? in
                    guard case .object(let row) = item,
                          let ref = try? resource(
                            kind: "series",
                            id: row["id"]?.stringValue ?? "",
                            format: row["container_extension"]?.stringValue ?? "mp4"
                          ) else { return nil }
                    let title = row["title"]?.stringValue
                        ?? L10n.text("第 {0} 集", [row["episode_num"]?.stringValue ?? "-"])
                    return cleanTitle(title) + "$" + ref.encoded
                }
                if !episodes.isEmpty {
                    flags.append(PlaybackFlagPresentation.xtreamSeasonID(season))
                    urls.append(episodes.joined(separator: "#"))
                }
            }
            vod.vodPlayFrom = flags.joined(separator: "$$$"); vod.vodPlayUrl = urls.joined(separator: "$$$")
        } else {
            let movie: [String: JSONDynamicValue]
            if case .object(let value) = root["movie_data"] { movie = value } else { movie = [:] }
            let ref = try resource(kind: "movie", id: parts[1], format: movie["container_extension"]?.stringValue ?? "mp4")
            vod.vodPlayFrom = "Xtream"; vod.vodPlayUrl = cleanTitle(vod.vodName) + "$" + ref.encoded
        }
        return Result(list: [vod])
    }

    public func playerContent(site: Site, flag: String, id: String) async throws -> Result {
        let ref = try XtreamResource(id)
        guard ref.accountID == configuration.id else { throw XtreamError.invalidReference }
        try await authenticate()
        let account = try credentials()
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/%?#")
        guard let username = account.username.addingPercentEncoding(withAllowedCharacters: allowed),
              let password = account.password.addingPercentEncoding(withAllowedCharacters: allowed) else { throw XtreamError.authorizationRequired }
        let url = configuration.server + "/" + ref.kind + "/" + username + "/" + password + "/" + ref.streamID + "." + ref.format
        return Result(url: url, flag: flag, format: ref.format == "m3u8" ? "hls" : ref.format, key: site.key)
    }

    public func liveGroups() async throws -> [ChannelGroup] {
        _ = try currentCredentials()
        let session = sessionID
        var categories = try await rows("get_live_categories")
        let channels = try await rows("get_live_streams")
        try checkSession(session)
        let identity = try currentCredentials().runtimeIdentity(configuration: configuration)
        let known = Set(categories.compactMap { $0["category_id"]?.stringValue })
        let unknown = Set(channels.map { $0["category_id"]?.stringValue ?? "" }).subtracting(known)
        categories += unknown.sorted().map { ["category_id": .string($0), "category_name": .string(L10n.text("未分类"))] }
        return categories.map { category in
            let categoryID = category["category_id"]?.stringValue ?? ""
            let entries = channels.filter {
                ($0["category_id"]?.stringValue ?? "") == categoryID
            }.compactMap { row -> Channel? in
                let id = row["stream_id"]?.stringValue ?? ""
                guard let ts = try? resource(kind: "live", id: id, format: "ts"),
                      let hls = try? resource(kind: "live", id: id, format: "m3u8") else {
                    return nil
                }
                return Channel(name: row["name"]?.stringValue ?? id, number: id,
                      logo: safeImage(row["stream_icon"]?.stringValue ?? ""),
                      tvgId: row["epg_channel_id"]?.stringValue ?? "", urls: [ts.encoded, hls.encoded],
                      xtreamArchive: archiveCapability(row, identity: identity))
            }
            return ChannelGroup(name: category["category_name"]?.stringValue ?? categoryID, channels: entries)
        }
    }

    /// Revalidate quota and channel/credential ownership before exposing an ephemeral URL.
    /// This does not reserve capacity on the remote server; other clients may race it.
    public func livePreviewSpec(channel: Channel) async throws -> PlaySpec {
        let ref = try checkChannel(channel), session = sessionID
        try await authenticate(forceRefresh: true)
        try checkSession(session)
        guard previewConnections.permitsPreview else { throw LivePreviewError.connectionLimit }
        let result = try await playerContent(site: configuration.site(), flag: "Xtream", id: ref.encoded)
        try checkSession(session)
        return PlaySpec(url: result.url, format: result.format, title: channel.name)
    }

    private func resource(kind: String, id: String, format: String) throws -> XtreamResource {
        try XtreamResource(accountID: configuration.id, kind: kind, streamID: id, format: format.lowercased())
    }

    public func shortEpg(streamID: String, limit: Int = 128, forceRefresh: Bool = false, scope: String = "") async throws -> EpgData {
        _ = try resource(kind: "live", id: streamID, format: "ts")
        try await authenticate()
        let session = sessionID, key = scope + ":" + streamID
        if !forceRefresh, let cached = epgCache[key], Date().timeIntervalSince(cached.0) < 300 { return cached.1 }
        let ticket = UUID(), requestKey = "short:" + key
        epgRequests[requestKey] = ticket
        defer { if epgRequests[requestKey] == ticket { epgRequests[requestKey] = nil } }
        let response = try await request(action: "get_short_epg", parameters: ["stream_id": streamID, "limit": String(min(128, max(2, limit)))], maximumBytes: 1_024 * 1_024)
        try checkSession(session)
        guard epgRequests[requestKey] == ticket else { throw CancellationError() }
        guard case .object(let root) = response, case .array(let rows) = root["epg_listings"] else { throw XtreamError.malformedResponse }
        let data = EpgData(channelName: streamID, items: Self.epgItems(rows: rows, timeZone: serverTimeZone))
        if epgCache.count >= 48, epgCache[key] == nil,
           let oldest = epgCache.min(by: { $0.value.0 < $1.value.0 })?.key { epgCache[oldest] = nil }
        epgCache[key] = (Date(), data)
        return data
    }

    public func shortEpgResult(streamID: String, forceRefresh: Bool = false, scope: String = "") async -> EpgLoadResult {
        let session = sessionID
        do {
            let data = try await shortEpg(streamID: streamID, forceRefresh: forceRefresh, scope: scope)
            return EpgLoadResult(data: data, availability: data.items.isEmpty ? .empty : .available, coverage: .xtreamShort)
        } catch {
            guard !(error is CancellationError), (try? checkSession(session)) != nil else { return retiredEPG() }
            if let cached = epgCache[scope + ":" + streamID] {
                return EpgLoadResult(data: cached.1, availability: .stale, message: L10n.text("刷新失败，正在显示上次的节目单。"), coverage: .xtreamShort)
            }
            return EpgLoadResult(data: EpgData(), availability: .unavailable, message: L10n.text("节目单加载失败，请重试。"), coverage: .xtreamShort)
        }
    }

    static func epgItems(rows: [JSONDynamicValue], timeZone: TimeZone?) -> [EpgItem] {
        // The short endpoint is intentionally tolerant and never grants archive permission.
        var seen = Set<String>()
        return rows.prefix(128).compactMap { value -> EpgItem? in
            guard var item = try? XtreamEPGParser.item(value, timeZone: timeZone) else { return nil }
            item.title = String(item.title.prefix(512))
            guard seen.insert(item.id).inserted else { return nil }
            return item
        }
            .sorted { $0.start < $1.start }
    }

    private func archiveCapability(_ row: [String: JSONDynamicValue], identity: String) -> XtreamArchiveChannel {
        .init(enabled: XtreamEPGParser.positive(row["tv_archive"]),
            days: min(36_500, max(0, Int(row["tv_archive_duration"]?.stringValue ?? "") ?? 0)),
            timeZone: serverTimeZone?.identifier, session: sessionID, credentialIdentity: identity)
    }

    private func retiredEPG() -> EpgLoadResult {
        .init(data: EpgData(), availability: .unavailable, message: LiveCatchupUnavailableReason.staleSource.message,
              discardsPreviousData: true)
    }

    private func checkChannel(_ channel: Channel) throws -> XtreamResource {
        let account = try currentCredentials()
        guard let raw = channel.currentUrl, let ref = try? XtreamResource(raw), ref.kind == "live",
              ref.accountID == configuration.id, let capability = channel.xtreamArchive,
              capability.session == sessionID,
              capability.credentialIdentity == account.runtimeIdentity(configuration: configuration) else { throw CancellationError() }
        return ref
    }

    private func history(streamID: String, scope: String, forceRefresh: Bool) async throws -> EpgData {
        try await authenticate()
        let session = sessionID, key = scope + ":" + streamID
        if !forceRefresh, let failed = historyFailures[key], Date().timeIntervalSince(failed) < 30 { throw XtreamError.requestFailed }
        if !forceRefresh, historyFailures[key] == nil, let cached = historyCache[key], Date().timeIntervalSince(cached.0) < 300 { return cached.1 }
        let ticket = UUID(), requestKey = "history:" + key
        epgRequests[requestKey] = ticket
        defer { if epgRequests[requestKey] == ticket { epgRequests[requestKey] = nil } }
        do {
            let response = try await request(action: "get_simple_data_table", parameters: ["stream_id": streamID], maximumBytes: 2 * 1_024 * 1_024)
            try checkSession(session)
            guard epgRequests[requestKey] == ticket else { throw CancellationError() }
            let ref = try resource(kind: "live", id: streamID, format: "ts")
            let data = try XtreamEPGParser.history(response, timeZone: serverTimeZone, resource: ref.encoded, scope: scope, session: session)
            historyFailures[key] = nil
            historyCache[key] = (Date(), data)
            // Independent history cache: 32 entries / 8 MiB logical payload, no short-EPG promotion.
            while historyCache.count > 32 || historyCache.values.reduce(0, { $0 + Self.historyCost($1.1) }) > 8 * 1_024 * 1_024 {
                guard let oldest = historyCache.min(by: { $0.value.0 < $1.value.0 })?.key else { break }
                historyCache[oldest] = nil
            }
            return data
        } catch {
            try checkSession(session)
            guard epgRequests[requestKey] == ticket else { throw CancellationError() }
            if !(error is CancellationError) {
                if historyFailures.count >= 32 { historyFailures.removeAll() }
                historyFailures[key] = Date()
            }
            throw error
        }
    }

    private static func historyCost(_ data: EpgData) -> Int { data.items.reduce(0) { $0 + $1.title.utf8.count + 512 } }

    public func guideEpg(channel: Channel, window: DateInterval, scope: String, forceRefresh: Bool = false) async -> EpgLoadResult {
        let ref: XtreamResource
        do { ref = try checkChannel(channel) } catch { return retiredEPG() }
        let session = sessionID, key = scope + ":" + ref.streamID
        guard window.duration > 0, window.duration <= 86_400 else { return retiredEPG() }
        do {
            try await authenticate()
            try checkSession(session)
            guard channel.xtreamArchive?.timeZone == serverTimeZone?.identifier else { return retiredEPG() }
        } catch { return retiredEPG() }
        var result: EpgLoadResult
        if window.start < Date() {
            do {
                let data = try await history(streamID: ref.streamID, scope: scope, forceRefresh: forceRefresh)
                result = .init(data: data, availability: data.items.isEmpty ? .empty : .available, coverage: .xtreamHistory)
            } catch {
                guard !(error is CancellationError), (try? checkSession(session)) != nil else { return retiredEPG() }
                if let cached = historyCache[key] {
                    result = .init(data: cached.1, availability: .stale,
                        message: L10n.text("历史节目单刷新失败，缓存覆盖可能不完整。"), coverage: .xtreamHistory)
                } else {
                    // At most one short fallback; it remains explicitly limited and cannot enable replay.
                    result = await shortEpgResult(streamID: ref.streamID, forceRefresh: forceRefresh, scope: scope)
                    guard !result.discardsPreviousData else { return result }
                    result.availability = result.availability == .unavailable ? .unavailable : .stale
                    result.message = L10n.text("历史接口不可用，仅显示短节目单；历史覆盖不完整。")
                }
                if let reason = error as? LiveCatchupUnavailableReason {
                    result.message = reason.message + " " + (result.message ?? "")
                }
            }
        } else {
            result = await shortEpgResult(streamID: ref.streamID, forceRefresh: forceRefresh, scope: scope)
            result.message = L10n.text("短节目单仅覆盖服务端返回的有限时段。")
        }
        guard (try? checkSession(session)) != nil else { return retiredEPG() }
        result.data.channelName = channel.name
        let filtered = result.data.items.filter { $0.start < window.end && $0.end > window.start }
        result.data.items = Array(filtered.prefix(128))
        if filtered.count > 128 {
            result.availability = .stale
            result.message = L10n.text("节目数量达到读取上限，当前时段覆盖不完整。")
        } else if result.availability == .available, filtered.isEmpty { result.availability = .empty }
        return result
    }

    /// Revalidate server declarations and programme permission before resolving current credentials.
    public func archiveRequest(channel: Channel, programme: EpgItem, scope: String, offset: Double) async throws -> LiveCatchupRequest {
        let ref = try checkChannel(channel), session = sessionID
        guard programme.xtreamArchive?.scope == scope, programme.xtreamArchive?.session == session else { throw LiveCatchupUnavailableReason.staleSource }
        try await authenticate(forceRefresh: true)
        try checkSession(session)
        let streams = try await rows("get_live_streams", forceRefresh: true)
        try checkSession(session)
        guard let row = streams.first(where: { $0["stream_id"]?.stringValue == ref.streamID }) else { throw LiveCatchupUnavailableReason.noArchive }
        let fresh = try await history(streamID: ref.streamID, scope: scope, forceRefresh: true)
        try checkSession(session)
        guard let confirmed = fresh.items.first(where: { $0.start == programme.start && $0.end == programme.end }),
              confirmed.xtreamArchive?.hasArchive == true else { throw LiveCatchupUnavailableReason.noArchive }
        let account = try currentCredentials()
        var currentChannel = channel
        currentChannel.xtreamArchive = archiveCapability(row, identity: account.runtimeIdentity(configuration: configuration))
        guard currentChannel.xtreamArchive?.timeZone == channel.xtreamArchive?.timeZone else { throw LiveCatchupUnavailableReason.staleSource }
        let result = XtreamArchivePolicy.availability(channel: currentChannel, programme: confirmed, offset: offset)
        guard case .available(let mapping) = result else {
            if case .unavailable(let reason) = result { throw reason }
            throw LiveCatchupUnavailableReason.noArchive
        }
        let zone = TimeZone(identifier: currentChannel.xtreamArchive!.timeZone!)!
        let start = programme.start.addingTimeInterval(mapping.mediaStartOffset)
        let minutes = Int(ceil(programme.end.timeIntervalSince(start) / 60))
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let user = account.username.addingPercentEncoding(withAllowedCharacters: allowed),
              let password = account.password.addingPercentEncoding(withAllowedCharacters: allowed) else { throw XtreamError.authorizationRequired }
        let url = configuration.server + "/timeshift/" + user + "/" + password + "/" + String(minutes)
            + "/" + XtreamArchivePolicy.routeStart(start, timeZone: zone) + "/" + ref.streamID + ".ts"
        return .init(url: url, mediaStartOffset: mapping.mediaStartOffset, initialPosition: mapping.initialPosition, supportsRequestSeek: true)
    }
    private func cleanTitle(_ title: String) -> String { title.replacingOccurrences(of: "#", with: "＃").replacingOccurrences(of: "$", with: "＄") }
    private func safeImage(_ value: String) -> String {
        guard let url = URLComponents(string: value), ["http", "https"].contains(url.scheme ?? ""), url.user == nil, url.password == nil,
              !(url.queryItems ?? []).contains(where: { ["username", "password", "token"].contains($0.name.lowercased()) }) else { return "" }
        return value
    }
}

private actor XtreamResponseBuffer {
    private(set) var data = Data()
    let maximumBytes: Int
    init(maximumBytes: Int) { self.maximumBytes = maximumBytes }
    func append(_ chunk: Data) throws {
        guard data.count + chunk.count <= maximumBytes else { throw XtreamError.requestFailed }
        data.append(chunk)
    }
}
