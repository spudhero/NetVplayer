import Foundation
import Models
import Networking

public struct ServerItemPage: Decodable, Sendable {
    public var Items: [ServerItem]?
    public var TotalRecordCount: Int?
}
public struct ServerItem: Decodable, Sendable {
    public var Id: String?
    public var Name: String?
    public var `Type`: String?
    public var IsFolder: Bool?
    public var ImageTags: [String: String]?
    public var Overview: String?
    public var ProductionYear: Int?
    public var IndexNumber: Int?
    public var ParentIndexNumber: Int?
    public var MediaType: String?
    public var RunTimeTicks: Int64?
    public var UserData: ServerUserData?
    public var MediaSources: [ServerMediaSource]?
    public var Chapters: [ServerChapter]?
    public var OriginalTitle: String?
    public var Genres: [String]?
    public var PremiereDate: String?
    public var ProductionLocations: [String]?
    public var Studios: [ServerNamedItem]?
    public var Taglines: [String]?
    public var People: [ServerPerson]?
    public var ProviderIds: [String: String]?
    public var CommunityRating: Double?
    public var OfficialRating: String?
    public var BackdropImageTags: [String]?
    public var isBrowsableFolder: Bool {
        IsFolder == true && Type != "Series" && Type != "Season"
    }
}
public struct ServerNamedItem: Decodable, Sendable { public var Name: String? }
public struct ServerPerson: Decodable, Sendable {
    public var Id: String?
    public var Name: String?
    public var `Type`: String?
    public var Role: String?
    public var PrimaryImageTag: String?
}
public struct ServerUser: Decodable, Sendable {
    public let Id: String
    public let Name: String?
    public init(Id: String, Name: String? = nil) { self.Id = Id; self.Name = Name }
    private enum CodingKeys: String, CodingKey { case Id, Name }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try? values.decode(String.self, forKey: .Id) { Id = id }
        else { Id = String(try values.decode(Int64.self, forKey: .Id)) }
        Name = try values.decodeIfPresent(String.self, forKey: .Name)
    }
}
public struct ServerUserData: Decodable, Sendable { public var PlaybackPositionTicks: Int64? }
public struct ServerChapter: Decodable, Sendable { public var Name: String?; public var StartPositionTicks: Int64? }
public struct ServerPlaybackInfo: Decodable, Sendable {
    public var MediaSources: [ServerMediaSource]?
    public var PlaySessionId: String?
    public var ErrorCode: String?
    public var FnOSContext: FnOSPlaybackContext?
}
public struct ServerMediaSource: Decodable, Sendable {
    public var Id: String?
    public var Name: String?
    public var Path: String?
    public var `Protocol`: String?
    public var Size: Int64?
    public var Container: String?
    public var SupportsDirectPlay: Bool?
    public var IsInfiniteStream: Bool?
    public var RequiresOpening: Bool?
    public var VideoType: String?
    public var MediaStreams: [ServerMediaStream]?
    public var Chapters: [ServerChapter]?
    public var RunTimeTicks: Int64?
}
public struct ServerMediaStream: Decodable, Sendable {
    public var Index: Int?
    public var `Type`: String?
    public var Codec: String?
    public var Language: String?
    public var DisplayTitle: String?
    public var IsExternal: Bool?
    public var DeliveryUrl: String?
    public var Width: Int?
    public var Height: Int?
    public var VideoRange: String?
    public var VideoRangeType: String?
    public var Channels: Int?
    public var SampleRate: Int?
}

public struct MediaServerClient: Sendable {
    public let account: MediaServerConfiguration
    let token: String
    let transport: MediaServerTransport
    public init(account: MediaServerConfiguration, token: String = "", transport: MediaServerTransport = .init()) throws {
        self.account = try account.validated()
        guard !token.contains("\r"), !token.contains("\n") else { throw MediaServerError.authentication }
        self.token = token; self.transport = transport
    }
    public var baseURL: URL {
        let base = URL(string: account.server)!
        return [.emby, .zspace].contains(account.kind) && !base.path.hasSuffix("/emby") ? base.appendingPathComponent("emby") : base
    }
    public func endpoint(_ path: [String], query: [String: String] = [:]) -> URL {
        var url = baseURL
        path.forEach { url.appendPathComponent($0) }
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        c.queryItems = query.sorted { $0.key < $1.key }.map { .init(name: $0.key, value: $0.value) }
        if account.kind == .fnos {
            // FnOS signs decoded query values; its form parser treats a raw '+' as space.
            c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        return c.url!
    }
    public func request(_ path: [String], query: [String: String] = [:], method: String = "GET",
                        body: Data? = nil, authenticated: Bool = true) -> URLRequest {
        var request = URLRequest(url: endpoint(path, query: query)); request.timeoutInterval = 20
        request.httpMethod = method; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if account.kind == .fnos { return fnOSSigned(request, authenticated: authenticated) }
        if account.kind == .plex {
            request.setValue("NetVplayer", forHTTPHeaderField: "X-Plex-Product")
            request.setValue(account.deviceID.uuidString, forHTTPHeaderField: "X-Plex-Client-Identifier")
            request.setValue("macOS", forHTTPHeaderField: "X-Plex-Platform")
            request.setValue("NetVplayer for macOS", forHTTPHeaderField: "X-Plex-Device-Name")
            for field in ["X-Plex-Container-Start", "X-Plex-Container-Size"] {
                if let value = query[field] { request.setValue(value, forHTTPHeaderField: field) }
            }
            if authenticated { request.setValue(token, forHTTPHeaderField: "X-Plex-Token") }
            return request
        }
        request.setValue(authorization(authenticated: authenticated), forHTTPHeaderField: "Authorization")
        if account.kind == .zspace { request.setValue(authorization(authenticated: false), forHTTPHeaderField: "X-Emby-Authorization") }
        if authenticated { request.setValue(token, forHTTPHeaderField: "X-Emby-Token") }
        return request
    }
    private func authorization(authenticated: Bool) -> String {
        let scheme = account.kind == .emby ? "Emby" : "MediaBrowser"
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        var value = "\(scheme) Client=\"NetVplayer\", Device=\"macOS\", DeviceId=\"\(account.deviceID.uuidString)\", Version=\"\(version)\""
        if authenticated, account.kind == .jellyfin, !token.isEmpty {
            // Current Jellyfin can disable legacy X-Emby-Token authentication.
            // Its Authorization parser URL-decodes quoted values; encode delimiters
            // and '+' as well, so an opaque token cannot alter client parameters.
            let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
            let encoded = token.addingPercentEncoding(withAllowedCharacters: allowed)!
            value += ", Token=\"\(encoded)\""
        }
        return value
    }
    private func json<T: Decodable>(_ type: T.Type, path: [String], query: [String: String] = [:], method: String = "GET",
                                    body: Data? = nil, authenticated: Bool = true) async throws -> T {
        do {
            let (data, _) = try await transport.request(request(path, query: query, method: method, body: body, authenticated: authenticated),
                                                       maximumBytes: 4 * 1024 * 1024, origin: baseURL)
            guard let result = try? JSONDecoder().decode(type, from: data) else { throw MediaServerError.response }
            return result
        } catch MediaServerError.http(401) { throw MediaServerError.authentication }
    }
    private struct SystemInfo: Decodable { let Id: String }
    private struct Authentication: Decodable { let AccessToken: String; let User: ServerUser; let ServerId: String? }
    public func authenticate(username: String, password: String) async throws -> (MediaServerConfiguration, String) {
        if account.kind == .plex { return try await plexAuthenticate(displayName: username, accessToken: password) }
        if account.kind == .fnos { return try await fnOSAuthenticate(username: username, password: password) }
        if account.kind == .zspace { return try await zspaceAuthenticate(username: username, password: password) }
        let system = try await json(SystemInfo.self, path: ["System", "Info", "Public"], authenticated: false)
        let body = try JSONSerialization.data(withJSONObject: ["Username": username, "Pw": password])
        let auth = try await json(Authentication.self, path: ["Users", "AuthenticateByName"], method: "POST", body: body, authenticated: false)
        guard !auth.AccessToken.isEmpty, MediaServerReference.validID(auth.User.Id), !system.Id.isEmpty,
              auth.ServerId == nil || auth.ServerId == system.Id else { throw MediaServerError.authentication }
        var configuration = account; configuration.serverID = system.Id; configuration.userID = auth.User.Id
        configuration.username = auth.User.Name ?? username.trimmingCharacters(in: .whitespacesAndNewlines)
        // Editing an account must not silently give a new user the old history namespace.
        if (!account.userID.isEmpty && account.userID != auth.User.Id) || (!account.serverID.isEmpty && account.serverID != system.Id) {
            configuration.id = UUID()
        }
        return (configuration, auth.AccessToken)
    }
    public func validateSession() async throws {
        _ = try await sessionUser()
    }
    public func sessionUser() async throws -> ServerUser {
        if account.kind == .plex { return try await plexSessionUser() }
        if account.kind == .fnos { return try await fnOSSessionUser() }
        if account.kind == .zspace { return try await zspaceSessionUser() }
        let system = try await json(SystemInfo.self, path: ["System", "Info", "Public"], authenticated: false)
        guard system.Id == account.serverID else { throw MediaServerError.authentication }
        let user = try await json(ServerUser.self, path: ["Users", account.kind == .emby ? account.userID : "Me"])
        guard user.Id == account.userID else { throw MediaServerError.authentication }
        return user
    }
    public func views() async throws -> [ServerItem] {
        if account.kind == .plex { return try await plexViews() }
        if account.kind == .fnos { return try await fnOSViews() }
        return try await json(ServerItemPage.self, path: ["Users", account.userID, "Views"]).Items ?? []
    }
    public func items(parent: String?, page: Int, search: String? = nil, series: String? = nil, recursive: Bool = false) async throws -> ServerItemPage {
        guard (1...10_000).contains(page) else { throw MediaServerError.response }
        if account.kind == .plex { return try await plexItems(parent: parent, page: page, search: search, series: series, recursive: recursive) }
        if account.kind == .fnos { return try await fnOSItems(parent: parent, page: page, search: search, series: series, recursive: recursive) }
        var query = ["UserId": account.userID, "StartIndex": String((page - 1) * 50), "Limit": "50",
                     "Fields": "Overview", "EnableImages": "true", "EnableImageTypes": "Primary",
                     "SortBy": "SortName", "SortOrder": "Ascending"]
        if let parent, !parent.isEmpty { query["ParentId"] = parent }
        if let search { query["SearchTerm"] = search; query["Recursive"] = "true"; query["IncludeItemTypes"] = "Movie,Series,Episode,Video,Audio" }
        if recursive { query["Recursive"] = "true"; query["IncludeItemTypes"] = "Movie,Episode,Video,Audio" }
        if series != nil {
            query["SortBy"] = "ParentIndexNumber,IndexNumber,SortName"
            query["Fields"] = "Overview,MediaSources,MediaStreams"
        }
        if let series { return try await json(ServerItemPage.self, path: ["Shows", series, "Episodes"], query: query) }
        return try await json(ServerItemPage.self, path: ["Users", account.userID, "Items"], query: query)
    }
    public func item(_ id: String) async throws -> ServerItem {
        guard MediaServerReference.validID(id) else { throw MediaServerError.response }
        if account.kind == .plex { return try await plexItem(id) }
        if account.kind == .fnos { return try await fnOSItem(id) }
        return try await json(ServerItem.self, path: ["Users", account.userID, "Items", id],
                              query: ["Fields": "Overview,OriginalTitle,Genres,People,Studios,Taglines,ProviderIds,ProductionLocations,MediaSources,MediaStreams,Chapters"])
    }
    public func artwork(_ reference: MediaServerArtworkReference) async throws -> Data {
        guard reference.item.accountID == account.id else { throw MediaServerError.response }
        if account.kind == .plex { return try await plexArtwork(reference) }
        if account.kind == .fnos { return try await fnOSArtwork(reference) }
        var request = request(["Items", reference.item.itemID, "Images", reference.kind.rawValue],
            query: ["Tag": reference.tag, "MaxWidth": reference.kind == .backdrop ? "1920" : "800", "Quality": "90", "Format": "jpg"])
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        let (data, response) = try await transport.request(request, maximumBytes: 4 * 1024 * 1024, origin: baseURL)
        guard !data.isEmpty, response.mimeType?.hasPrefix("image/") == true else { throw MediaServerError.response }
        return data
    }
    public func playbackInfo(_ id: String, sourceID: String? = nil) async throws -> ServerPlaybackInfo {
        guard MediaServerReference.validID(id), sourceID.map(MediaServerReference.validID) != false else { throw MediaServerError.response }
        if account.kind == .fnos { return try await fnOSPlaybackInfo(id, sourceID: sourceID) }
        if account.kind == .plex {
            let item = try await plexItem(id)
            return .init(MediaSources: item.MediaSources, PlaySessionId: UUID().uuidString)
        }
        var payload: [String: Any] = ["UserId": account.userID, "IsPlayback": true,
            "EnableDirectPlay": true, "EnableDirectStream": false, "EnableTranscoding": false, "AutoOpenLiveStream": false]
        if let sourceID { payload["MediaSourceId"] = sourceID }
        let body = try JSONSerialization.data(withJSONObject: payload)
        return try await json(ServerPlaybackInfo.self, path: ["Items", id, "PlaybackInfo"], method: "POST", body: body)
    }
    func originalRequest(item: String, source: String, audio: Bool) -> URLRequest {
        if account.kind == .fnos { return request(["v", "api", "v1", "media", "range", source]) }
        return request([audio ? "Audio" : "Videos", item, "stream"], query: ["Static": "true", "MediaSourceId": source])
    }
    /// Server credentials are headers on its own origin only. Never copy a server token into a CDN URL.
    func mediaRequest(_ value: String) -> URLRequest? {
        guard var c = URLComponents(string: value), let url = c.url,
              ["http", "https"].contains(c.scheme?.lowercased() ?? ""), c.host != nil,
              c.user == nil, c.password == nil, c.fragment == nil else { return nil }
        let sameOrigin = HTTPRedirectPolicy.sameOrigin(url, baseURL)
        if !sameOrigin, HTTPRedirectDelegate.url(value, contains: token) { return nil }
        if sameOrigin {
              c.queryItems = c.queryItems?.filter { !["apikey", "api_key", "x-emby-token", "x-mediabrowser-token", "x-plex-token"].contains($0.name.lowercased()) }
        }
        guard let safeURL = c.url, !HTTPRedirectDelegate.url(safeURL.absoluteString, contains: token) else { return nil }
        var request = URLRequest(url: safeURL); request.timeoutInterval = 30
        if sameOrigin {
            if account.kind == .plex {
                request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
                request.setValue(account.deviceID.uuidString, forHTTPHeaderField: "X-Plex-Client-Identifier")
            } else if account.kind == .fnos {
                request = fnOSSigned(request)
            } else {
                request.setValue(authorization(authenticated: true), forHTTPHeaderField: "Authorization")
                request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
                if account.kind == .zspace { request.setValue(authorization(authenticated: false), forHTTPHeaderField: "X-Emby-Authorization") }
            }
        }
        return request
    }
    public func report(path: String, payload: Data) async throws {
        if account.kind == .plex { try await plexReport(phase: path, payload: payload); return }
        _ = try await transport.request(request(["Sessions", "Playing"] + (path.isEmpty ? [] : [path]), method: "POST", body: payload),
                                        maximumBytes: 64 * 1024, origin: baseURL)
    }
    public func logout() async throws {
        // A manually supplied Plex token may be shared with other clients; disconnect only this local account.
        if account.kind == .plex { return }
        if account.kind == .fnos { _ = try await fnOSJSON(["user", "logout"], method: "POST"); return }
        _ = try await transport.request(request(["Sessions", "Logout"], method: "POST"), maximumBytes: 64 * 1024, origin: baseURL)
    }
}
