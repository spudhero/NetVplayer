import Foundation
import CryptoKit
import Models
import Networking


extension MediaServerClient {
    private func plexJSON(_ path: [String], query: [String: String] = [:]) async throws -> ServerJSONValue {
        do {
            let (data, _) = try await transport.request(request(path, query: query), maximumBytes: 4 * 1024 * 1024, origin: baseURL)
            let root = try JSONDecoder().decode(ServerJSONValue.self, from: data)
            guard case .object = root["MediaContainer"] else { throw MediaServerError.response }
            return root["MediaContainer"]
        } catch MediaServerError.http(401) { throw MediaServerError.authentication }
        catch MediaServerError.http(403) { throw MediaServerError.authentication }
        catch is DecodingError { throw MediaServerError.response }
    }
    private static func plexUserIdentity(_ token: String) -> String {
        // PMS does not identify the requesting user consistently. Token changes get
        // their own history namespace rather than inheriting another user's progress.
        "token-" + SHA256.hash(data: Data(token.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
    func plexAuthenticate(displayName: String, accessToken: String) async throws -> (MediaServerConfiguration, String) {
        let value = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 4096 else { throw MediaServerError.authentication }
        let client = try MediaServerClient(account: account, token: value, transport: transport)
        let system = try await client.plexJSON([])
        _ = try await client.plexViews() // Authenticate against a protected endpoint, not /identity alone.
        guard let serverID = system["machineIdentifier"].string, !serverID.isEmpty else { throw MediaServerError.response }
        let userID = Self.plexUserIdentity(value)
        var updated = account; updated.serverID = serverID; updated.userID = userID
        updated.username = displayName.isEmpty ? "Plex" : displayName
        if (!account.serverID.isEmpty && account.serverID != serverID) || (!account.userID.isEmpty && account.userID != userID) {
            updated.id = UUID()
        }
        return (updated, value)
    }
    func plexSessionUser() async throws -> ServerUser {
        guard !token.isEmpty, account.userID == Self.plexUserIdentity(token) else { throw MediaServerError.authentication }
        let system = try await plexJSON([])
        guard system["machineIdentifier"].string == account.serverID else { throw MediaServerError.authentication }
        _ = try await plexViews()
        return .init(Id: account.userID, Name: account.username)
    }
    func plexViews() async throws -> [ServerItem] {
        let response = try await plexJSON(["library", "sections"])
        return try response["Directory"].array.filter { ["movie", "show", "artist"].contains($0["type"].string ?? "") }.map { value in
            guard let key = value["key"].string, MediaServerReference.validID(key) else { throw MediaServerError.response }
            var item = ServerItem(); item.Id = "section-" + key; item.Name = value["title"].string
            item.Type = "CollectionFolder"; item.IsFolder = true
            return item
        }
    }
    func plexItems(parent: String?, page: Int, search: String?, series: String?, recursive: Bool) async throws -> ServerItemPage {
        var query = ["X-Plex-Container-Start": String((page - 1) * 50), "X-Plex-Container-Size": "50"]
        let path: [String]
        if let search {
            path = ["library", "all"]; query["title"] = search; query["sort"] = "titleSort"
        } else if let series {
            guard MediaServerReference.validID(series) else { throw MediaServerError.response }
            path = ["library", "metadata", series, "allLeaves"]
        } else if let parent, parent.hasPrefix("section-") {
            let section = String(parent.dropFirst(8)); guard MediaServerReference.validID(section) else { throw MediaServerError.response }
            path = ["library", "sections", section, "all"]; query["sort"] = "titleSort"
        } else if let parent, MediaServerReference.validID(parent) {
            path = ["library", "metadata", parent, recursive ? "allLeaves" : "children"]
        } else { path = ["library", "all"] }
        let result = try await plexJSON(path, query: query)
        let values = result["Metadata"].array
        guard values.count <= 50 else { throw MediaServerError.response }
        let items = try values.map(plexMap)
        let total = result["totalSize"].integer ?? (Int64((page - 1) * 50 + items.count) + (items.count == 50 ? 1 : 0))
        guard total >= 0, total <= 10_000_000 else { throw MediaServerError.response }
        return .init(Items: items, TotalRecordCount: Int(total))
    }
    private func plexMetadata(_ id: String) async throws -> ServerJSONValue {
        guard MediaServerReference.validID(id) else { throw MediaServerError.response }
        let result = try await plexJSON(["library", "metadata", id], query: ["includeChapters": "1"])
        guard let item = result["Metadata"].array.first, item["ratingKey"].string == id else { throw MediaServerError.response }
        return item
    }
    func plexItem(_ id: String) async throws -> ServerItem { try plexMap(await plexMetadata(id)) }
    private func plexMap(_ value: ServerJSONValue) throws -> ServerItem {
        guard let id = value["ratingKey"].string, MediaServerReference.validID(id) else { throw MediaServerError.response }
        var item = ServerItem(); item.Id = id; item.Name = value["title"].string; item.Overview = value["summary"].string
        let type = value["type"].string ?? ""
        item.Type = ["movie": "Movie", "show": "Series", "season": "Season", "episode": "Episode", "track": "Audio", "artist": "MusicArtist", "album": "MusicAlbum"][type] ?? "Video"
        item.IsFolder = ["show", "season", "artist", "album", "collection"].contains(type)
        item.MediaType = type == "track" ? "Audio" : "Video"
        item.ProductionYear = value["year"].integer.flatMap(Int.init(exactly:)); item.OriginalTitle = value["originalTitle"].string
        item.IndexNumber = value["index"].integer.flatMap(Int.init(exactly:)); item.ParentIndexNumber = value["parentIndex"].integer.flatMap(Int.init(exactly:))
        item.RunTimeTicks = Self.plexTicks(value["duration"].integer)
        item.UserData = .init(PlaybackPositionTicks: Self.plexTicks(value["viewOffset"].integer))
        item.CommunityRating = value["audienceRating"].double ?? value["rating"].double; item.OfficialRating = value["contentRating"].string
        item.PremiereDate = value["originallyAvailableAt"].string
        item.Genres = value["Genre"].array.compactMap { $0["tag"].string }
        item.ProductionLocations = value["Country"].array.compactMap { $0["tag"].string }
        item.Studios = value["studio"].string.map { [.init(Name: $0)] }
        item.Taglines = value["tagline"].string.map { [$0] }
        item.People = ["Director", "Writer", "Role"].flatMap { key in
            value[key].array.prefix(256).map { person in
                ServerPerson(Id: person["id"].string, Name: person["tag"].string, Type: key == "Role" ? "Actor" : key,
                    Role: person["role"].string)
            }
        }
        let tag = value["updatedAt"].string.flatMap { MediaServerReference.validID($0) ? $0 : nil } ?? "plex"
        if value["thumb"].string != nil { item.ImageTags = ["Primary": tag] }
        if value["art"].string != nil { item.BackdropImageTags = [tag] }
        item.Chapters = value["Chapter"].array.prefix(256).compactMap { chapter in
            guard let ticks = Self.plexTicks(chapter["startTimeOffset"].integer) else { return nil }
            return .init(Name: chapter["tag"].string ?? chapter["title"].string, StartPositionTicks: ticks)
        }
        item.MediaSources = try value["Media"].array.prefix(32).flatMap { media -> [ServerMediaSource] in
            let parts = media["Part"].array
            return try parts.prefix(32).map { part in
                guard let partID = part["id"].string, MediaServerReference.validID(partID),
                      let key = part["key"].string else { throw MediaServerError.response }
                var source = ServerMediaSource()
                source.Id = partID; source.Name = part["file"].string.map { ($0 as NSString).lastPathComponent } ?? media["videoResolution"].string
                source.Path = key; source.Protocol = "plex"; source.Size = part["size"].integer
                source.Container = part["container"].string ?? media["container"].string
                source.SupportsDirectPlay = parts.count == 1 && plexResourceRequest(key, prefixes: ["/library/parts/"]) != nil
                source.VideoType = "VideoFile"; source.RunTimeTicks = Self.plexTicks(part["duration"].integer ?? media["duration"].integer ?? value["duration"].integer)
                source.Chapters = item.Chapters
                source.MediaStreams = part["Stream"].array.prefix(128).map { stream in
                    var result = ServerMediaStream()
                    result.Index = (stream["index"].integer ?? stream["id"].integer).flatMap(Int.init(exactly:))
                    result.Type = [1: "Video", 2: "Audio", 3: "Subtitle"][Int(stream["streamType"].integer ?? 0)]
                    result.Codec = stream["codec"].string; result.Language = stream["languageCode"].string
                    result.DisplayTitle = stream["displayTitle"].string ?? stream["title"].string
                    result.DeliveryUrl = stream["key"].string; result.IsExternal = result.DeliveryUrl != nil
                    result.Width = stream["width"].integer.flatMap(Int.init(exactly:)); result.Height = stream["height"].integer.flatMap(Int.init(exactly:))
                    result.Channels = stream["channels"].integer.flatMap(Int.init(exactly:)); result.SampleRate = stream["samplingRate"].integer.flatMap(Int.init(exactly:))
                    return result
                }
                return source
            }
        }
        return item
    }
    private static func plexTicks(_ milliseconds: Int64?) -> Int64? {
        guard let milliseconds, milliseconds >= 0, milliseconds <= Int64.max / 10_000 else { return nil }
        return milliseconds * 10_000
    }
    func plexResourceRequest(_ path: String, prefixes: [String]) -> URLRequest? {
        guard path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("\\"),
              let components = URLComponents(string: path), components.scheme == nil, components.host == nil,
              components.query == nil, components.fragment == nil,
              !components.path.split(separator: "/").contains(".."), prefixes.contains(where: components.path.hasPrefix) else { return nil }
        var target = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        target.percentEncodedPath = target.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty
            ? components.percentEncodedPath : target.percentEncodedPath + components.percentEncodedPath
        guard let url = target.url, HTTPRedirectPolicy.sameOrigin(url, baseURL) else { return nil }
        return mediaRequest(url.absoluteString)
    }
    func plexArtwork(_ reference: MediaServerArtworkReference) async throws -> Data {
        let item = try await plexMetadata(reference.item.itemID)
        guard let path = item[reference.kind == .backdrop ? "art" : "thumb"].string,
              var request = plexResourceRequest(path, prefixes: ["/library/metadata/"]) else { throw MediaServerError.response }
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        let (data, response) = try await transport.request(request, maximumBytes: 4 * 1024 * 1024, origin: baseURL)
        guard !data.isEmpty, response.mimeType?.hasPrefix("image/") == true else { throw MediaServerError.response }
        return data
    }
    func plexReport(phase: String, payload: Data) async throws {
        guard let values = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let item = values["ItemId"] as? String, MediaServerReference.validID(item),
              let ticks = values["PositionTicks"] as? NSNumber else { throw MediaServerError.response }
        var query = ["ratingKey": item, "key": "/library/metadata/" + item, "identifier": "com.plexapp.plugins.library",
            "state": phase == "Stopped" ? "stopped" : (values["IsPaused"] as? Bool == true ? "paused" : "playing"),
            "time": String(max(0, ticks.int64Value) / 10_000)]
        if let duration = values["DurationTicks"] as? NSNumber { query["duration"] = String(max(0, duration.int64Value) / 10_000) }
        _ = try await transport.request(request([":", "timeline"], query: query), maximumBytes: 64 * 1024, origin: baseURL)
    }
}
