import CryptoKit
import Foundation
import Models
import Networking

/// Ephemeral playback data, kept with the lease and never persisted as a media identity.
public struct FnOSPlaybackContext: Decodable, Sendable {
    let itemID: String
    let mediaID: String
    let videoID: String
    let audioIDs: [String: String]
    let subtitleIDs: [String: String]
    let resolution: String
    let bitrate: Int64
    let duration: Int64
}

extension MediaServerClient {
    // Public web-protocol constants, not account credentials. This is a fresh
    // Swift implementation of the observed wire protocol; no third-party client code is bundled.
    static func fnOSAuthx(path: String, body: Data?, query: [URLQueryItem], nonce: String, timestamp: String) -> String {
        let payload = body ?? Data(query.sorted { $0.name < $1.name }
            .map { $0.name + "=" + ($0.value ?? "") }.joined(separator: "&").utf8)
        let input = ["NDzZTVxnRKP8Z0jXg1VAMonaG8akvh", path, nonce, timestamp,
                     fnOSMD5(payload), "16CCEB3D-AB42-077D-36A1-F355324E4237"].joined(separator: "_")
        return "nonce=\(nonce)&timestamp=\(timestamp)&sign=\(fnOSMD5(Data(input.utf8)))"
    }
    private static func fnOSMD5(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func fnOSHash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func fnOSSigned(_ original: URLRequest, authenticated: Bool = true) -> URLRequest {
        var request = original
        guard let url = request.url, HTTPRedirectPolicy.sameOrigin(url, baseURL) else { return request }
        if authenticated { request.setValue(token, forHTTPHeaderField: "Authorization") }
        request.setValue("web", forHTTPHeaderField: "x-trim-client")
        request.setValue("616", forHTTPHeaderField: "x-trim-client-version")
        request.setValue("NetVplayer/macOS", forHTTPHeaderField: "User-Agent")
        request.setValue(Self.fnOSAuthx(path: url.path, body: request.httpBody,
            query: URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [],
            nonce: String(Int.random(in: 100000...999999)),
            timestamp: String(Int64(Date().timeIntervalSince1970 * 1000))), forHTTPHeaderField: "Authx")
        return request
    }
    func refreshedMediaRequest(_ original: URLRequest) -> URLRequest {
        // Long films can outlive the API signature window; sign each byte read.
        account.kind == .fnos ? fnOSSigned(original) : original
    }
    func fnOSJSON(_ path: [String], query: [String: String] = [:], method: String = "GET",
                  body: Data? = nil, authenticated: Bool = true) async throws -> ServerJSONValue {
        do {
            let (data, _) = try await transport.request(request(["v", "api", "v1"] + path,
                query: query, method: method, body: body, authenticated: authenticated),
                maximumBytes: 4 * 1024 * 1024, origin: baseURL)
            let envelope = try JSONDecoder().decode(ServerJSONValue.self, from: data)
            guard let code = envelope["code"].integer else { throw MediaServerError.response }
            if [401, 403].contains(code) { throw MediaServerError.authentication }
            guard code == 0 else { throw MediaServerError.response }
            return envelope["data"]
        } catch MediaServerError.http(401) { throw MediaServerError.authentication }
        catch MediaServerError.http(403) { throw MediaServerError.authentication }
        catch is DecodingError { throw MediaServerError.response }
    }
    private func fnOSPost(_ path: [String], _ payload: [String: Any]) async throws -> ServerJSONValue {
        try await fnOSJSON(path, method: "POST", body: JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]))
    }
    private func fnOSServerID() async throws -> String {
        let config = try await fnOSJSON(["sys", "config"], authenticated: false)
        guard let id = config["server_guid"].string, MediaServerReference.validID(id) else { throw MediaServerError.response }
        return id
    }
    func fnOSAuthenticate(username: String, password: String) async throws -> (MediaServerConfiguration, String) {
        let serverID = try await fnOSServerID()
        let body = try JSONSerialization.data(withJSONObject: ["username": username, "password": password, "app_name": "trimemedia-web"], options: [.sortedKeys, .withoutEscapingSlashes])
        let auth = try await fnOSJSON(["login"], method: "POST", body: body, authenticated: false)
        guard let token = auth["token"].string, !token.isEmpty else { throw MediaServerError.authentication }
        let client = try MediaServerClient(account: account, token: token, transport: transport)
        let user = try await client.fnOSJSON(["user", "info"])
        guard let userID = user["guid"].string, MediaServerReference.validID(userID) else { throw MediaServerError.authentication }
        var saved = account
        saved.serverID = serverID; saved.userID = userID; saved.username = user["username"].string ?? username
        if (!account.userID.isEmpty && account.userID != userID) || (!account.serverID.isEmpty && account.serverID != saved.serverID) { saved.id = UUID() }
        return (saved, token)
    }
    func fnOSSessionUser() async throws -> ServerUser {
        guard account.serverID == (try await fnOSServerID()) else { throw MediaServerError.authentication }
        let user = try await fnOSJSON(["user", "info"])
        guard user["guid"].string == account.userID else { throw MediaServerError.authentication }
        return .init(Id: account.userID, Name: user["username"].string)
    }
    func fnOSViews() async throws -> [ServerItem] {
        let rows = try await fnOSJSON(["mediadb", "list"])
        guard case .array = rows else { throw MediaServerError.response }
        return try rows.array.map { row in
            guard let id = row["guid"].string, MediaServerReference.validID(id) else { throw MediaServerError.response }
            return .init(Id: id, Name: row["title"].string, Type: "CollectionFolder", IsFolder: true)
        }
    }
    func fnOSItems(parent: String?, page: Int, search: String?, series: String?, recursive: Bool) async throws -> ServerItemPage {
        guard parent.map(MediaServerReference.validID) != false, series.map(MediaServerReference.validID) != false else { throw MediaServerError.response }
        if let search {
            let rows = try await fnOSJSON(["search", "list"], query: ["q": search])
            guard case .array = rows else { throw MediaServerError.response }
            return try fnOSPage(rows.array.filter { $0["type"].string?.lowercased() != "person" }, page: page)
        }
        if let series {
            let seasons = try await fnOSJSON(["season", "list", series])
            guard case .array = seasons, seasons.array.count <= 100 else { throw MediaServerError.response }
            var rows: [ServerJSONValue] = []
            for season in seasons.array {
                guard let id = season["guid"].string, MediaServerReference.validID(id) else { throw MediaServerError.response }
                let episodes = try await fnOSJSON(["episode", "list", id])
                guard case .array = episodes, rows.count + episodes.array.count <= 5000 else { throw MediaServerError.response }
                rows += episodes.array
            }
            return try fnOSPage(rows, page: page)
        }
        if recursive, let parent {
            let rows = try await fnOSJSON(["episode", "list", parent])
            guard case .array = rows else { throw MediaServerError.response }
            return try fnOSPage(rows.array, page: page)
        }
        var payload: [String: Any] = ["page": page, "page_size": 50, "sort_column": "title", "sort_type": "ASC", "exclude_grouped_video": 1, "tags": ["type": [String]()]]
        if let parent {
            // fv_* are file-view folders; other parents are library IDs.
            payload[parent.hasPrefix("fv_") ? "parent_guid" : "ancestor_guid"] = parent
        }
        let result = try await fnOSPost(["item", "list"], payload)
        guard case .array = result["list"], let total = result["total"].integer, total >= 0, total <= Int64(Int.max), result["list"].array.count <= 50 else { throw MediaServerError.response }
        return .init(Items: try result["list"].array.map(fnOSMapItem), TotalRecordCount: Int(total))
    }
    private func fnOSPage(_ rows: [ServerJSONValue], page: Int) throws -> ServerItemPage {
        let start = min(rows.count, (page - 1) * 50), end = min(rows.count, page * 50)
        return .init(Items: try rows[start..<end].map(fnOSMapItem), TotalRecordCount: rows.count)
    }
    private func fnOSMapItem(_ row: ServerJSONValue) throws -> ServerItem {
        guard let id = row["guid"].string, MediaServerReference.validID(id) else { throw MediaServerError.response }
        let type = row["type"].string?.lowercased() ?? "video"
        let mapped = ["movie": "Movie", "tv": "Series", "season": "Season", "episode": "Episode", "folder": "Folder"][type] ?? "Video"
        let poster = row["poster"].string ?? row["posters"].string ?? row["poster_list"].array.first?.string
        let backdrop = row["backdrops"].string
        let date = row["release_date"].string ?? row["first_air_date"].string ?? row["air_date"].string
        var result = ServerItem(Id: id, Name: row["title"].string ?? row["tv_title"].string,
            Type: mapped, IsFolder: ["Series", "Season", "Folder"].contains(mapped),
            ImageTags: poster.flatMap { $0.isEmpty ? nil : ["Primary": Self.fnOSHash($0)] },
            Overview: row["overview"].string, ProductionYear: date.flatMap { Int($0.prefix(4)) },
            IndexNumber: row["episode_number"].integer.flatMap(Int.init(exactly:)),
            ParentIndexNumber: row["season_number"].integer.flatMap(Int.init(exactly:)), MediaType: "Video",
            RunTimeTicks: Self.fnOSTicks(row["duration"].integer),
            UserData: .init(PlaybackPositionTicks: Self.fnOSTicks(row["ts"].integer ?? row["watched_ts"].integer)),
            OriginalTitle: row["original_title"].string, PremiereDate: date,
            ProductionLocations: row["production_countries"].array.compactMap(\.string),
            CommunityRating: row["vote_average"].double, OfficialRating: row["content_ratings"].string,
            BackdropImageTags: backdrop.flatMap { $0.isEmpty ? nil : [Self.fnOSHash($0)] })
        if let imdb = row["imdb_id"].string, !imdb.isEmpty { result.ProviderIds = ["Imdb": imdb] }
        return result
    }
    private static func fnOSTicks(_ seconds: Int64?) -> Int64? {
        guard let seconds, seconds >= 0, seconds <= Int64.max / 10_000_000 else { return nil }
        return seconds * 10_000_000
    }
    func fnOSItem(_ id: String) async throws -> ServerItem {
        let row = try await fnOSJSON(["item", id])
        guard row["guid"].string == id else { throw MediaServerError.response }
        var item = try fnOSMapItem(row)
        if !["Series", "Season", "Folder"].contains(item.Type) {
            let sources = try await fnOSJSON(["stream", "list", id])
            item.MediaSources = try fnOSSources(sources)
            let progress = try await fnOSPost(["play", "info"], ["item_guid": id])
            item.UserData = .init(PlaybackPositionTicks: Self.fnOSTicks(progress["ts"].integer))
        }
        return item
    }
    private func fnOSSources(_ rows: ServerJSONValue) throws -> [ServerMediaSource] {
        guard case .array = rows["files"], rows["files"].array.count <= 128 else { throw MediaServerError.response }
        return try rows["files"].array.map { file in
            guard let id = file["guid"].string, MediaServerReference.validID(id) else { throw MediaServerError.response }
            let video = rows["video_streams"].array.first { $0["media_guid"].string == id } ?? .null
            let audio = rows["audio_streams"].array.filter { $0["media_guid"].string == id }
            let subtitles = rows["subtitle_streams"].array.filter { $0["media_guid"].string == id }
            let filename = file["file_name"].string ?? "原始文件"
            return .init(Id: id, Name: filename, Protocol: "File", Size: file["size"].integer,
                Container: (filename as NSString).pathExtension.lowercased(), SupportsDirectPlay: file["can_play"].integer == 1 || file["can_play"].boolean == true,
                VideoType: "VideoFile", MediaStreams: fnOSStreams(video: video, audio: audio, subtitles: subtitles),
                RunTimeTicks: Self.fnOSTicks(video["duration"].integer))
        }
    }
    private func fnOSStreams(video: ServerJSONValue, audio: [ServerJSONValue], subtitles: [ServerJSONValue]) -> [ServerMediaStream] {
        var result: [ServerMediaStream] = []
        if video["guid"].string != nil {
            result.append(.init(Index: video["index"].integer.flatMap(Int.init(exactly:)), Type: "Video", Codec: video["codec_name"].string,
                Width: video["width"].integer.flatMap(Int.init(exactly:)), Height: video["height"].integer.flatMap(Int.init(exactly:)), VideoRange: video["color_range_type"].string))
        }
        result += audio.prefix(128).map { .init(Index: $0["index"].integer.flatMap(Int.init(exactly:)), Type: "Audio", Codec: $0["codec_name"].string,
            Language: $0["language"].string, DisplayTitle: $0["title"].string, Channels: $0["channels"].integer.flatMap(Int.init(exactly:)), SampleRate: $0["sample_rate"].integer.flatMap(Int.init(exactly:))) }
        result += subtitles.prefix(128).map { row in
            let external = row["is_external"].integer == 1 || row["is_external"].boolean == true
            let url = row["guid"].string.flatMap { MediaServerReference.validID($0) ? endpoint(["v", "api", "v1", "subtitle", "dl", $0]).absoluteString : nil }
            return .init(Index: row["index"].integer.flatMap(Int.init(exactly:)), Type: "Subtitle", Codec: row["codec_name"].string,
                Language: row["language"].string, DisplayTitle: row["title"].string, IsExternal: external, DeliveryUrl: external ? url : nil)
        }
        return result
    }
    func fnOSPlaybackInfo(_ id: String, sourceID: String?) async throws -> ServerPlaybackInfo {
        var payload = ["item_guid": id]
        if let sourceID { payload["media_guid"] = sourceID }
        let info = try await fnOSPost(["play", "info"], payload)
        let unavailable: MediaServerError = sourceID == nil ? .originalUnavailable : .selectedSourceUnavailable
        guard let mediaID = info["media_guid"].string, MediaServerReference.validID(mediaID), sourceID == nil || sourceID == mediaID,
              info["item"]["guid"].string == id else { throw unavailable }
        let stream = try await fnOSPost(["stream"], ["media_guid": mediaID, "ip": Self.fnOSMD5(Data(token.utf8)), "level": 1])
        let file = stream["file_stream"], video = stream["video_stream"]
        guard file["guid"].string == mediaID, file["can_play"].integer == 1 || file["can_play"].boolean == true, video["ext1"].integer != -1,
              let videoID = video["guid"].string, MediaServerReference.validID(videoID) else { throw unavailable }
        // /media/range returns the unmodified file; never negotiate an HLS transcode.
        let rows = ServerJSONValue.object(["files": .array([file]), "video_streams": .array([video]),
            "audio_streams": stream["audio_streams"], "subtitle_streams": stream["subtitle_streams"]])
        let sources = try fnOSSources(rows)
        func indices(_ rows: ServerJSONValue) -> [String: String] {
            var result: [String: String] = [:]
            for row in rows.array.prefix(128) {
                if let index = row["index"].integer, let id = row["guid"].string, MediaServerReference.validID(id) { result[String(index)] = id }
            }
            return result
        }
        let context = FnOSPlaybackContext(itemID: id, mediaID: mediaID, videoID: videoID,
            audioIDs: indices(stream["audio_streams"]), subtitleIDs: indices(stream["subtitle_streams"]),
            resolution: video["resolution_type"].string ?? "", bitrate: video["bps"].integer ?? 0, duration: video["duration"].integer ?? 0)
        return .init(MediaSources: sources, PlaySessionId: UUID().uuidString, FnOSContext: context)
    }
    func fnOSReport(_ context: FnOSPlaybackContext, snapshot: MediaServerPlaybackSnapshot) async throws {
        var payload: [String: Any] = ["item_guid": context.itemID, "media_guid": context.mediaID, "video_guid": context.videoID,
            "audio_guid": snapshot.audioIndex.flatMap { context.audioIDs[String($0)] } ?? "", "resolution": context.resolution,
            "bitrate": context.bitrate, "ts": snapshot.ticks / 10_000_000, "duration": context.duration,
            "device_id": account.deviceID.uuidString, "direct_link_audio_index": -1, "lan": "zh-CN", "device_name": "NetVplayer for macOS"]
        if let index = snapshot.subtitleIndex { payload["subtitle_guid"] = context.subtitleIDs[String(index)] }
        _ = try await fnOSPost(["play", "record"], payload)
    }
    func fnOSArtwork(_ reference: MediaServerArtworkReference) async throws -> Data {
        let row = try await fnOSJSON(["item", reference.item.itemID])
        let path: String?
        if reference.kind == .backdrop { path = row["backdrops"].string }
        else { path = row["poster"].string ?? row["posters"].string ?? row["poster_list"].array.first?.string }
        guard let path, Self.fnOSHash(path) == reference.tag else { throw MediaServerError.response }
        let value: String
        if path.hasPrefix("http://") || path.hasPrefix("https://") { value = path }
        else {
            let relative = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            value = account.server + "/" + (relative.hasPrefix("v/api/v1/sys/img/") ? relative : "v/api/v1/sys/img/" + relative)
        }
        guard let request = mediaRequest(value), let url = request.url, HTTPRedirectPolicy.sameOrigin(url, baseURL) else { throw MediaServerError.response }
        let (data, response) = try await transport.request(request, maximumBytes: 4 * 1024 * 1024, origin: baseURL)
        guard !data.isEmpty, response.mimeType?.hasPrefix("image/") == true else { throw MediaServerError.response }
        return data
    }
}
