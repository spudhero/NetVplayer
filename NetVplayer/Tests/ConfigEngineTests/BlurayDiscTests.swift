import AppKit
import CryptoKit
import Foundation
import Testing
import Models
@testable import FileServiceEngine
import MediaLibraryEngine
import Storage
import SpiderEngine
@testable import PlayerEngine
@testable import ProxyServer

@Suite(.serialized)
struct BlurayDiscTests {
    @Test func selectionHistoryAndPlaylistIdentityAreStable() throws {
        let reference = try FileResourceReference(serviceID: UUID(), path: "/Film.iso")
        let selection = DiscSelection(reference: reference, playlist: 42, angle: 1)
        #expect(DiscSelection(locator: selection.locator) == selection)
        #expect(HistoryPersistencePolicy.sanitizedEpisodeLocator(selection.locator) == selection.locator)
        #expect(selection.mediaIdentity != DiscSelection(reference: reference, playlist: 43).mediaIdentity)
        let history = History(episodeUrl: selection.locator, position: 12000, duration: 30000,
                              disc: .init(selection: selection, audioTrackID: "2", subtitleTrackID: "no"))
        #expect(try JSONDecoder().decode(History.self, from: JSONEncoder().encode(history)) == history)
        #expect(try JSONDecoder().decode(History.self, from: Data("{}".utf8)).disc == nil)
        var mismatched = history; mismatched.episodeUrl = "other"
        #expect(HistoryPersistencePolicy.sanitized(mismatched).disc == nil)
        var invalid = selection; invalid.reference.path = "/../outside.iso"
        #expect(DiscSelection(locator: invalid.locator) == nil)
        let folder = FileEntry(path: "/Movie/BDMV", name: "BDMV", isDirectory: true)
        let vod = try FileServiceNativeProvider.vod(entry: folder, serviceID: reference.serviceID, site: Site(key: "fixture"))
        #expect(FileResourceReference(locator: vod.vodId)?.path == "/Movie")
    }

    @Test func edlUsesExplicitDurationsAndEscapedLocalResources() throws {
        let selection = DiscSelection(reference: try .init(serviceID: UUID(), path: "/disc"), playlist: 0)
        let title = DiscTitle(playlist: 0, duration: 30, angles: 1,
                              clips: [.init(id: "00000", start: 0, inTime: 600, outTime: 610),
                                      .init(id: "00001", start: 10, inTime: 600, outTime: 620)], chapters: [])
        let url = "http://127.0.0.1/resource?id=a,b;!"
        let disc = DiscPlayback(selection: selection, title: title, segmentURLs: [url, url])
        #expect(disc.edl().contains("%\(url.utf8.count)%\(url),600.000000000,10.000000000"))
        #expect(disc.edl().hasSuffix(",600.000000000,20.000000000"))
        #expect(disc.edl(urls: []) == "")
        var result = Models.Result(url: disc.edl()); result.disc = disc
        #expect(!String(decoding: try JSONEncoder().encode(result), as: UTF8.self).contains("segmentURLs"))
        #expect(try JSONDecoder().decode(Models.Result.self, from: JSONEncoder().encode(result)).disc == nil)
    }

    @Test func scannerAggregatesBDMVBeforeTraversingStreamsAndIndexesISO() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("disc-scan-\(UUID())")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Movie/BDMV/STREAM"), withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("Movie/BDMV/STREAM/00000.m2ts"))
        try Data().write(to: folder.appendingPathComponent("Another.iso"))
        defer { try? FileManager.default.removeItem(at: folder) }
        let client = try LocalDirectoryClient(folder: folder)
        let index = MediaIndex(url: folder.appendingPathComponent("index.sqlite"))
        let library = MediaLibraryConfiguration(serviceID: UUID(), name: "fixture", metadataSource: .local)
        await MediaLibraryScanner(index: index).scan(library, client: client)
        let disc = try FileResourceReference(serviceID: library.serviceID, libraryID: library.id, path: "/Movie")
        #expect(try await index.record(reference: disc)?.entry.isDirectory == true)
        let iso = try FileResourceReference(serviceID: library.serviceID, libraryID: library.id, path: "/Another.iso")
        #expect(try await index.record(reference: iso) != nil)
        let clip = try FileResourceReference(serviceID: library.serviceID, libraryID: library.id, path: "/Movie/BDMV/STREAM/00000.m2ts")
        #expect(try await index.record(reference: clip) == nil)
    }

    @Test func compositeReadsSharePhysicalCacheWithoutNestedBudget() async throws {
        let server = ProxyServer(); try server.start(); defer { server.stop() }
        let bytes = Data((0..<1000).map { UInt8($0 % 251) })
        let probe = DiscReadCounter()
        let physical = try server.registerSeekableResource(.init(size: 1000) { range in
            await probe.record(range)
            return bytes.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
        })
        let composite = try server.registerSeekableResource(.init(size: 1000, managesReadBudget: true) { range in
            try await server.readRegisteredResource(url: physical, range: range)
        })
        let identity = PlaybackMediaIdentity(source: "fixture", account: "a", item: "disc")
        let session = PlaybackReadSession()
        let first = try #require(server.readLease(forLocalURL: composite, session: session, mediaIdentity: identity, purpose: .chapterPreview))
        let second = try #require(server.readLease(forLocalURL: composite, session: session, mediaIdentity: identity, purpose: .chapterPreview))
        defer { first.cancel(); second.cancel(); server.unregisterSeekableResource(url: composite); server.unregisterSeekableResource(url: physical) }
        async let a = server.readRegisteredResource(url: first.url, range: 0..<100)
        async let b = server.readRegisteredResource(url: second.url, range: 50..<150)
        #expect(try await a == bytes.subdata(in: 0..<100))
        #expect(try await b == bytes.subdata(in: 50..<150))
        #expect(await probe.byteCount == 150)
        #expect(PlaybackBackgroundBudget.shared.reservedBytes == 0)
        session.advance()
        await #expect(throws: CancellationError.self) { try await server.readRegisteredResource(url: first.url, range: 200..<300) }
        #expect(await probe.byteCount == 150)
    }

    @Test func httpRangesRejectShiftedTruncatedAndUnsupportedResponses() throws {
        let url = URL(string: "http://localhost/disc.iso")!
        func response(_ code: Int = 206, _ range: String?) -> HTTPURLResponse {
            HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: range.map { ["Content-Range": $0] })!
        }
        let bytes = Data(repeating: 1, count: 10)
        try FileHTTPTransport.validateRange(data: bytes, response: response(206, "bytes 100-109/1000"), requested: 100..<120)
        #expect(throws: FileServiceError.self) { try FileHTTPTransport.validateRange(data: bytes, response: response(206, "bytes 0-9/1000"), requested: 100..<110) }
        #expect(throws: FileServiceError.self) { try FileHTTPTransport.validateRange(data: bytes, response: response(206, "bytes 100-119/1000"), requested: 100..<120) }
        #expect(throws: FileServiceError.self) { try FileHTTPTransport.validateRange(data: bytes, response: response(206, nil), requested: 100..<110) }
        #expect(throws: FileServiceError.self) { try FileHTTPTransport.validateRange(data: bytes, response: response(200, nil), requested: 100..<110) }
    }

    @MainActor
    @Test(.disabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_BLURAY_FIXTURES"] == nil))
    func authoredISOBDMVNativePlaybackAndCrossClipSeek() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["NETVPLAYER_BLURAY_FIXTURES"]))
        _ = NSApplication.shared
        let server = ProxyServer.shared; try server.start(); defer { server.stop() }
        var reports: [[String: Any]] = []
        var cases = [("local-ISO", "/authored.iso"), ("local-BDMV", "/authored")]
        if ProcessInfo.processInfo.environment["NETVPLAYER_BLURAY_HTTP"] != nil {
            cases += [("loopback-WebDAV-ISO", "/authored.iso"), ("loopback-WebDAV-BDMV", "/authored")]
        }
        for (name, path) in cases {
            let client: any FileServiceClient
            if name.hasPrefix("loopback"), let address = ProcessInfo.processInfo.environment["NETVPLAYER_BLURAY_HTTP"] {
                client = try WebDAVClient(configuration: .init(name: "Disc fixture", kind: .webDAV, address: address))
            } else { client = try LocalDirectoryClient(folder: root) }
            let reference = try FileResourceReference(serviceID: UUID(), path: path)
            let reader = BlurayDiscReader(reference: reference, client: client)
            let catalog = try await reader.scan()
            #expect(Set(catalog.titles.map(\.playlist)) == [0, 1, 2, 10])
            #expect(catalog.suggestedPlaylist == 10)
            let title = try #require(catalog.titles.first { $0.playlist == 10 })
            #expect(title.clips.count == 3 && title.chapters.count == 6)
            #expect(abs(title.duration - 30.125) < 0.01)
            let disc = try await reader.playback(selection: .init(reference: reference, playlist: 10))
            defer { disc.segmentURLs.forEach { server.unregisterSeekableResource(url: $0) } }
            var spec = PlaySpec(url: disc.edl(), disc: disc, title: "Authored Blu-ray")
            spec.mpvOptions["cache-secs"] = "30"
            let prefsID = "bluray-native-\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: prefsID))
            defer { defaults.removePersistentDomain(forName: prefsID) }
            let preferences = PlaybackAudioPreferenceStore(defaults: defaults); preferences.setMuted(true)
            let engine = MPVPlayerEngine(videoSurface: .vod, stopResourcePolicy: .fullDestroy, audioPreferences: preferences)
            engine.performanceDiagnosticsHandler = { _, _ in }
            let state = PlayerState(); engine.playerState = state
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 270), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.alphaValue = 0.01
            let view = try #require(MPVOpenGLVideoView(engine: engine, surface: .vod))
            view.frame = window.contentView!.bounds; window.contentView = view; window.orderFrontRegardless()
            engine.attach(to: view, surface: .vod)
            defer { engine.stop(); engine.detach(from: view); window.orderOut(nil) }
            await engine.play(spec: spec)
            try #require(await discWait { state.errorMessage != nil || (!state.isMediaLoading && state.position > 0.2) })
            try #require(state.errorMessage == nil, "\(state.errorMessage ?? "")")
            #expect(abs(state.duration - title.duration) < 0.1)
            #expect(state.chapters.count == 6)
            var positions: [Double] = []
            for target in [12.0, 22.0, 2.0] {
                engine.seek(to: Int64(target * 1000))
                try #require(await discWait { state.errorMessage != nil || (!state.isSeeking && state.position >= target && state.position < target + 2) })
                try #require(state.errorMessage == nil)
                positions.append(state.position)
            }
            // Decoded previews must come from three different clips, not an unchanging frame.
            engine.pause()
            try #require(await discWait { PlaybackBackgroundBudget.shared.permitsBackgroundWork })
            let active = try #require(state.currentSpec)
            var previews: [Data] = []
            for target in [2.0, 12.0, 22.0] {
                let data = try #require(await PlayerChapterThumbnailDecoder.shared.imageData(spec: active, seconds: target))
                #expect(NSImage(data: data) != nil); previews.append(data)
            }
            #expect(Set(previews).count == 3)
            engine.seek(to: 8000)
            try #require(await discWait { !state.isSeeking && state.position >= 8 && state.position < 10 })
            engine.resume()
            let began = Date(), start = state.position
            let framesBefore = engine.performanceFrameSnapshot.freshFrames
            try await Task.sleep(for: .seconds(14))
            let elapsed = Date().timeIntervalSince(began), advanced = state.position - start
            let freshFrames = engine.performanceFrameSnapshot.freshFrames - framesBefore
            #expect(state.errorMessage == nil && advanced >= elapsed * 0.98)
            #expect(freshFrames >= 280)
            let resume = state.position
            engine.stop()
            spec.initialStartPositionSeconds = resume
            await engine.play(spec: spec)
            try #require(await discWait { !state.isMediaLoading && state.position >= resume && state.position < resume + 2 })
            let restored = state.position
            engine.stop()
            // Select a shorter episode manually; longest-title advice is not selection policy.
            let episodeReader = BlurayDiscReader(reference: reference, client: client)
            let episode = try await episodeReader.playback(selection: .init(reference: reference, playlist: 1))
            defer { episode.segmentURLs.forEach { server.unregisterSeekableResource(url: $0) } }
            var episodeSpec = PlaySpec(url: episode.edl(), disc: episode)
            episodeSpec.mpvOptions = ["aid": "1", "sid": "no", "cache-secs": "30"]
            await engine.play(spec: episodeSpec)
            try #require(await discWait { state.errorMessage != nil || (!state.isMediaLoading && state.position > 0.2) })
            try #require(state.errorMessage == nil)
            #expect(state.chapters.count == 2 && abs(state.duration - 10.041666667) < 0.1)
            #expect(state.selectedAudioTrackID == "1" && state.selectedSubtitleTrackID == nil)
            engine.seek(to: 2000)
            try #require(await discWait { !state.isSeeking && state.position >= 2 && state.position < 4 })
            reports.append(["source": name, "playlists": catalog.titles.map(\.playlist),
                            "clips": title.clips.count, "chapters": title.chapters.count, "duration": title.duration,
                            "seekPositions": positions, "previewCount": previews.count, "elapsed": elapsed, "advanced": advanced,
                            "freshFrames": freshFrames, "resume": resume, "restored": restored,
                            "manualPlaylist": 1, "singleClipDuration": state.duration, "singleClipSeek": state.position])
            engine.stop()
        }
        if let output = ProcessInfo.processInfo.environment["NETVPLAYER_BLURAY_REPORT"] {
            try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output), options: .withoutOverwriting)
        }
    }

    @MainActor
    @Test(.disabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_BLURAY_NAS_DISCOVERY"] == nil))
    func boundedConfiguredNASDiscDiscovery() async throws {
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["NETVPLAYER_BLURAY_NAS_DISCOVERY"]))
        let defaults = try #require(UserDefaults(suiteName: UserPreferences.stableBundleIdentifier))
        let store = FileServiceStore(preferences: UserPreferences(defaults: defaults, credentialStore: LocalCredentialStore()))
        let catalog = store.load()
        let service = try #require(catalog.services.first { $0.kind == .smb })
        let runtime = FileServiceRuntime(store: store)
        let client = try await runtime.client(for: service.id)
        defer { Task { await client.disconnect() } }
        var queue = [("/", 0)], visited = Set<String>(), candidates: [FileResourceReference] = []
        var entryCount = 0, failures = 0
        let began = Date()
        while !queue.isEmpty, visited.count < 80, entryCount < 12000, Date().timeIntervalSince(began) < 60 {
            let (path, depth) = queue.removeFirst()
            guard visited.insert(path).inserted else { continue }
            do {
                let entries = try await client.allEntries(path: path); entryCount += entries.count
                if entries.contains(where: DiscMediaPolicy.isBDMV) {
                    candidates.append(try .init(serviceID: service.id, path: path)); continue
                }
                for entry in entries where !entry.isSymbolicLink && !entry.name.hasPrefix(".") {
                    if !entry.isDirectory && DiscMediaPolicy.isISO(entry.name) { candidates.append(try .init(serviceID: service.id, path: entry.path)) }
                    else if entry.isDirectory && depth < 3 { queue.append((entry.path, depth + 1)) }
                }
            } catch { failures += 1 }
        }
        let report: [String: Any] = ["scope": "configured-real-SMB-metadata-discovery-only", "directories": visited.count,
            "entries": entryCount, "failedDirectories": failures, "candidateCount": candidates.count,
            "seconds": Date().timeIntervalSince(began), "completeWithinBounds": queue.isEmpty,
            "candidatePathSHA256": candidates.map { SHA256.hash(data: Data($0.path.utf8)).map { String(format: "%02x", $0) }.joined() }]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .withoutOverwriting)
        if !candidates.isEmpty {
            let privateOutput = output.deletingLastPathComponent().appendingPathComponent("nas-disc-candidates-private.json")
            try JSONEncoder().encode(candidates).write(to: privateOutput, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privateOutput.path)
        }
    }

    @Test(.disabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_BLURAY_FIXTURES"] == nil))
    func shortReadsRetryAndNonCooperativeCancellationKeepReaderAlive() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["NETVPLAYER_BLURAY_FIXTURES"]))
        let server = ProxyServer(); try server.start(); defer { server.stop() }
        let reference = try FileResourceReference(serviceID: UUID(), path: "/authored.iso")
        let client = DiscFaultClient(local: try LocalDirectoryClient(folder: root))
        await client.setFailure(true)
        var reader: BlurayDiscReader? = BlurayDiscReader(reference: reference, client: client, proxy: server, ownsClient: true)
        await #expect(throws: DiscReadError.self) { _ = try await reader!.scan() }
        await client.setFailure(false)
        #expect(try await reader!.scan().titles.count == 4)
        let playback = try await reader!.playback(selection: .init(reference: reference, playlist: 10))
        let data = try await server.readRegisteredResource(url: playback.segmentURLs[0], range: 128..<700000)
        #expect(data.count == 699872)
        #expect(await client.maximumRead <= 256 * 1024)
        let before = await client.reads
        await client.setBlocked(true)
        let interrupted = Task { try await server.readRegisteredResource(url: playback.segmentURLs[0], range: 2_000_000..<2_200_000) }
        for _ in 0..<200 { if await client.reads > before { break }; try await Task.sleep(for: .milliseconds(5)) }
        #expect(await client.reads > before)
        interrupted.cancel()
        await client.releaseReads()
        await #expect(throws: CancellationError.self) { _ = try await interrupted.value }
        let recovered = try await server.readRegisteredResource(url: playback.segmentURLs[0], range: 2_000_000..<2_200_000)
        #expect(recovered.count == 200000)
        playback.segmentURLs.forEach { server.unregisterSeekableResource(url: $0) }
        reader = nil

        let blocked = DiscFaultClient(local: try LocalDirectoryClient(folder: root))
        await blocked.setBlocked(true)
        var waitingReader: BlurayDiscReader? = BlurayDiscReader(reference: reference, client: blocked, proxy: server, ownsClient: true)
        func beginScan(_ reader: BlurayDiscReader) -> Task<DiscCatalog, Error> { Task { try await reader.scan() } }
        let scan = beginScan(waitingReader!)
        for _ in 0..<200 { if await blocked.reads > 0 { break }; try await Task.sleep(for: .milliseconds(5)) }
        #expect(await blocked.reads > 0)
        scan.cancel(); waitingReader = nil
        #expect(await blocked.closes == 0)
        await blocked.releaseReads()
        await #expect(throws: CancellationError.self) { _ = try await scan.value }
        for _ in 0..<200 { if await blocked.closes > 0 { break }; try await Task.sleep(for: .milliseconds(5)) }
        #expect(await blocked.closes == 1)
    }
}

private actor DiscReadCounter {
    var byteCount = 0
    func record(_ range: Range<Int64>) { byteCount += Int(range.upperBound - range.lowerBound) }
}
private actor DiscFaultClient: FileServiceClient {
    let local: LocalDirectoryClient
    var failure = false, blocked = false
    var reads = 0, closes = 0, maximumRead = 0
    var waiters: [CheckedContinuation<Void, Never>] = []
    init(local: LocalDirectoryClient) { self.local = local }
    func connect() async throws { try await local.connect() }
    func disconnect() async { closes += 1; await local.disconnect() }
    func list(path: String, cursor: String?) async throws -> FileEntryPage { try await local.list(path: path, cursor: cursor) }
    func stat(path: String) async throws -> FileEntry { try await local.stat(path: path) }
    func resolve(path: String) async throws -> ResolvedFileResource { try await local.resolve(path: path) }
    func setFailure(_ value: Bool) { failure = value }
    func setBlocked(_ value: Bool) { blocked = value }
    func releaseReads() { blocked = false; let old = waiters; waiters = []; old.forEach { $0.resume() } }
    func read(path: String, range: Range<Int64>) async throws -> Data {
        reads += 1
        if blocked { await withCheckedContinuation { waiters.append($0) } }
        if failure { throw DiscReadError.readFailed }
        let limited = range.lowerBound..<min(range.upperBound, range.lowerBound + 64 * 1024)
        maximumRead = max(maximumRead, Int(limited.upperBound - limited.lowerBound))
        return try await local.read(path: path, range: limited)
    }
}
@MainActor
private func discWait(_ predicate: () -> Bool) async -> Bool {
    for _ in 0..<400 { if predicate() { return true }; try? await Task.sleep(for: .milliseconds(50)) }
    return false
}
