import Foundation
import Models
import Storage
import ProxyServer

public actor MediaServerRuntime {
    public static let shared = MediaServerRuntime()
    private let store: MediaServerStore
    private let transport: MediaServerTransport
    private struct Lease {
        let accountID: UUID
        let source: MediaServerByteSource
        let urls: [String]
        let reporter: MediaServerPlaybackReporter
    }
    private var leases: [UUID: Lease] = [:]
    private var revisions: [UUID: UInt64] = [:]
    public init(store: MediaServerStore = .shared, transport: MediaServerTransport = .init()) {
        self.store = store; self.transport = transport
    }
    public func client(for id: UUID) async throws -> MediaServerClient {
        guard let account = store.load().first(where: { $0.id == id }) else { throw MediaServerError.configuration }
        let observation = ServiceConnectionObservations.shared.begin(store.connectionObservationScope(account))
        do {
            let client = try MediaServerClient(account: account, token: store.token(for: account), transport: transport)
            try await client.validateSession()
            try Task.checkCancellation()
            guard store.load().contains(account) else { throw CancellationError() }
            ServiceConnectionObservations.shared.finish(observation, state: .available)
            return client
        } catch {
            if !TaskDiagnosticIssue.isCancellation(error), store.load().contains(account) {
                ServiceConnectionObservations.shared.finish(observation, state: ServiceConnectionObservations.failure(error))
            }
            throw error
        }
    }
    public func resolve(_ reference: MediaServerReference) async throws -> Models.Result {
        let revision = revisions[reference.accountID, default: 0]
        let client = try await client(for: reference.accountID)
        let item = try await client.item(reference.itemID)
        let info = try await client.playbackInfo(reference.itemID, sourceID: reference.sourceID)
        let unavailable: MediaServerError = reference.sourceID == nil ? .originalUnavailable : .selectedSourceUnavailable
        guard info.ErrorCode == nil, let sessionID = info.PlaySessionId, !sessionID.isEmpty,
              let source = info.MediaSources?.first(where: {
                  (reference.sourceID == nil || $0.Id == reference.sourceID) &&
                  $0.SupportsDirectPlay != false && $0.IsInfiniteStream != true && $0.RequiresOpening != true &&
                  ($0.VideoType == nil || $0.VideoType == "VideoFile") && $0.Container?.lowercased() != "iso"
              }),
              let sourceID = source.Id, MediaServerReference.validID(sourceID) else { throw unavailable }
        let fallback: URLRequest
        if client.account.kind == .plex {
            guard let path = source.Path, let request = client.plexResourceRequest(path, prefixes: ["/library/parts/"]) else { throw unavailable }
            fallback = request
        } else { fallback = client.originalRequest(item: reference.itemID, source: sourceID, audio: item.MediaType == "Audio") }
        let size: Int64
        if let value = source.Size, value > 0 { size = value }
        else {
            var probe = fallback; probe.setValue("bytes=0-0", forHTTPHeaderField: "Range")
            let probeRequest = probe
            let total = try await PlaybackBackgroundBudget.shared.withRead(purpose: .probe, bytes: 1) {
                let (data, response) = try await client.transport.request(client.refreshedMediaRequest(probeRequest), maximumBytes: 1)
                guard response.statusCode == 206, data.count == 1,
                      let value = response.value(forHTTPHeaderField: "Content-Range"), value.hasPrefix("bytes 0-0/"),
                      let total = Int64(value.dropFirst("bytes 0-0/".count)), total > 0 else { throw MediaServerError.originalUnavailable }
                return total
            }
            size = total
        }
        let direct = client.account.kind != .plex && source.Protocol?.lowercased() == "http" ? source.Path.flatMap(client.mediaRequest) : nil
        let reader = MediaServerByteSource(client: client, fallback: fallback, direct: direct, size: size)
        let id = UUID(), identity = client.account.identity(itemID: reference.itemID, sourceID: reference.sourceID)
        let reporter = MediaServerPlaybackReporter(client: client, itemID: reference.itemID, sourceID: sourceID, sessionID: sessionID,
            durationTicks: source.RunTimeTicks ?? item.RunTimeTicks, fnOSContext: info.FnOSContext)
        var urls: [String] = []
        do {
            try Task.checkCancellation()
            let proxy = try ProxyServer.shared.registerSeekableResource(.init(size: size, readChunkSize: 4 * 1024 * 1024,
                mediaIdentity: identity,
                close: { await reader.close() }, read: { try await reader.read($0) }))
            urls.append(proxy)
            var subs: [Sub] = []
            var subtitleIndices: [String: Int] = [:]
            var subtitleBytes = 0
            for stream in (source.MediaStreams ?? []).prefix(128) where stream.Type == "Subtitle" && stream.IsExternal == true {
                guard subs.count < 16, subtitleBytes < 8 * 1024 * 1024 else { break }
                guard let index = stream.Index, index >= 0,
                      let codec = stream.Codec?.lowercased(), ["srt", "subrip", "ass", "ssa", "vtt", "webvtt"].contains(codec) else { continue }
                let ext = ["subrip": "srt", "webvtt": "vtt"][codec] ?? codec
                let value: String
                if client.account.kind == .plex {
                    guard let path = stream.DeliveryUrl, let url = client.plexResourceRequest(path, prefixes: ["/library/streams/"])?.url else { continue }
                    value = url.absoluteString
                } else {
                    value = stream.DeliveryUrl.flatMap { URL(string: $0, relativeTo: client.baseURL.appendingPathComponent(""))?.absoluteString }
                        ?? client.endpoint(["Videos", reference.itemID, sourceID, "Subtitles", String(index), "0", "Stream." + ext]).absoluteString
                }
                guard let request = client.mediaRequest(value) else { continue }
                let limit = min(4 * 1024 * 1024, 8 * 1024 * 1024 - subtitleBytes)
                let data: Data
                do {
                    data = try await PlaybackBackgroundBudget.shared.withRead(purpose: .subtitleExtraction, bytes: Int64(limit)) {
                        try await client.transport.request(request, maximumBytes: limit).0
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { continue } // Original embedded tracks remain usable if an external file fails.
                guard !data.isEmpty else { continue }
                subtitleBytes += data.count
                // Native accounts may intentionally use localhost. Keep their bounded
                // subtitle bytes on the trusted resource path; the public URL relay's
                // target restrictions stay in force.
                let local = try ProxyServer.shared.registerSeekableResource(.init(size: Int64(data.count),
                    contentType: "text/plain", read: { range in
                        try Task.checkCancellation()
                        return data.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
                    }))
                urls.append(local)
                subtitleIndices[local] = index
                subs.append(Sub(name: String((stream.DisplayTitle ?? stream.Language ?? ext).prefix(256)), url: local,
                                lang: stream.Language ?? "", format: ext))
            }
            try Task.checkCancellation()
            guard store.load().contains(client.account), revisions[reference.accountID, default: 0] == revision,
                  (try? store.token(for: client.account)) == client.token else { throw CancellationError() }
            leases[id] = .init(accountID: reference.accountID, source: reader, urls: urls, reporter: reporter)
            var result = Models.Result(url: proxy, subs: subs)
            let runtimeTicks = source.RunTimeTicks ?? item.RunTimeTicks
            let chapters = (source.Chapters ?? item.Chapters ?? []).prefix(256).compactMap { chapter -> MediaServerChapter? in
                guard let ticks = chapter.StartPositionTicks, ticks >= 0,
                      runtimeTicks == nil || ticks < runtimeTicks! else { return nil }
                return .init(title: String((chapter.Name ?? "").prefix(256)), seconds: Double(ticks) / 10_000_000)
            }.sorted { $0.seconds < $1.seconds }
            // Server user data is item-wide and does not identify the cut. Explicit
            // versions resume only from matching local history supplied by the app.
            let resumeSeconds = reference.sourceID == nil
                ? Double(max(0, item.UserData?.PlaybackPositionTicks ?? 0)) / 10_000_000 : 0
            result.mediaServer = .init(leaseID: id, identity: identity,
                resumeSeconds: resumeSeconds, chapters: chapters, externalSubtitleIndices: subtitleIndices)
            return result
        } catch {
            for url in urls { unregister(url) }
            await reader.close(); throw error
        }
    }
    public func artwork(_ reference: MediaServerArtworkReference) async throws -> Data {
        let id = reference.item.accountID, revision = revisions[reference.item.accountID, default: 0]
        let client = try await client(for: id)
        let data = try await client.artwork(reference)
        try Task.checkCancellation()
        guard revisions[id, default: 0] == revision, store.load().contains(client.account),
              (try? store.token(for: client.account)) == client.token else { throw CancellationError() }
        return data
    }
    public func report(_ id: UUID, snapshot: MediaServerPlaybackSnapshot, started: Bool = false) async {
        await leases[id]?.reporter.update(snapshot, start: started)
    }
    public func release(_ id: UUID, snapshot: MediaServerPlaybackSnapshot? = nil) async {
        guard let lease = leases.removeValue(forKey: id) else { return }
        // Reject late callbacks before the first suspension.
        lease.urls.forEach(unregister)
        await lease.reporter.stop(snapshot)
    }
    public func invalidate(_ accountID: UUID) async {
        revisions[accountID, default: 0] &+= 1
        for id in leases.filter({ $0.value.accountID == accountID }).map(\.key) {
            await leases[id]?.source.close()
            await release(id)
        }
    }
    private func unregister(_ url: String) {
        ProxyServer.shared.unregisterSeekableResource(url: url)
        _ = ProxyServer.shared.unregisterRemoteStream(forLocalURL: url)
    }
    public var activeLeaseCount: Int { leases.count }
}
