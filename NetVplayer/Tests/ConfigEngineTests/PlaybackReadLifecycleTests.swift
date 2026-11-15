import Foundation
import Testing
import Models
@testable import ProxyServer

private actor ResourceReadGate {
    var ranges: [Range<Int64>] = []
    var closes = 0
    var blocked = true
    private var pending: [CheckedContinuation<Void, Never>] = []
    func read(_ range: Range<Int64>) async -> Data {
        ranges.append(range)
        if blocked { await withCheckedContinuation { pending.append($0) } }
        return Data(range.map { UInt8($0 % 251) })
    }
    func open() { blocked = false; let p = pending; pending = []; for c in p { c.resume() } }
    func close() { closes += 1 }
}

private func lifecycleWait(_ predicate: () async -> Bool) async throws {
    for _ in 0..<500 {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw CancellationError()
}

@Suite(.serialized)
struct PlaybackReadLifecycleTests {
    @Test func leasedRemoteSourceSurvivesRegistrationTrimmingAndCacheEviction() async throws {
        let server = ProxyServer(); try server.start(); defer { server.stop() }
        let url = server.registerRemoteStream(url: "https://fixture.example/retained", headers: [:], contentLength: 100,
            bufferConfiguration: .init(chunkSize: 100, prefetchWindowSize: 0, maxBytes: 1024, maxConcurrentPrefetches: 0))
        let identity = PlaybackMediaIdentity(source: "fixture", account: "a", item: "movie")
        let lease = try #require(server.readLease(forLocalURL: url, session: PlaybackReadSession(), mediaIdentity: identity, purpose: .foreground))
        defer { lease.cancel() }
        let id = try #require(URLComponents(string: lease.url)?.queryItems?.first?.value)
        for index in 0..<10 { _ = server.registerRemoteStream(url: "https://fixture.example/other/\(index)", headers: [:]) }
        let stream = try #require(server.stream(for: id))
        let fetch: @Sendable (RemoteStreamRange, RemoteStreamLoadKind) async throws -> RemoteStreamChunk = { range, _ in
            .init(range: range, data: Data(repeating: 7, count: Int(range.count)), headers: [:], contentType: "video/mp4", totalLength: 100)
        }
        _ = try await stream.buffer.response(for: .init(start: 0, end: 99), stream: stream, method: .GET, isPriming: true, fetch: fetch)
        #expect(await stream.buffer.evictCachedBytes(100) == 100)
        #expect(try await stream.buffer.response(for: .init(start: 0, end: 99), stream: stream, method: .GET, isPriming: true, fetch: fetch).data.count == 100)
        server.unregisterRemoteStream(forLocalURL: url)
        #expect(server.stream(for: id) != nil)
    }

    @Test func remoteRangesShareAPartialOverlapWithoutDuplicateBytes() async throws {
        let server = ProxyServer(); try server.start(); defer { server.stop() }
        let url = server.registerRemoteStream(url: "https://fixture.example/movie", headers: [:], contentLength: 1000,
            bufferConfiguration: .init(chunkSize: 100, prefetchWindowSize: 0, maxBytes: 1024, maxConcurrentPrefetches: 0))
        let id = try #require(URLComponents(string: url)?.queryItems?.first?.value)
        let stream = try #require(server.stream(for: id))
        let gate = ResourceReadGate()
        let fetch: @Sendable (RemoteStreamRange, RemoteStreamLoadKind) async throws -> RemoteStreamChunk = { range, _ in
            let data = await gate.read(range.start..<(range.end + 1))
            return .init(range: range, data: data, headers: [:], contentType: "video/mp4", totalLength: 1000)
        }
        let first = Task { try await stream.buffer.response(for: .init(start: 0, end: 99), stream: stream, method: .GET, isPriming: true, fetch: fetch) }
        try await lifecycleWait { await gate.ranges.count == 1 }
        let second = Task { try await stream.buffer.response(for: .init(start: 50, end: 149), stream: stream, method: .GET, isPriming: true, fetch: fetch) }
        await gate.open()
        #expect(try await first.value.data.count == 100)
        #expect(try await second.value.data == Data((50..<150).map { UInt8($0 % 251) }))
        #expect(await gate.ranges == [0..<100, 100..<150])
    }

    @Test func partialOverlapAndInterleavedRangesFetchOnlyGaps() async throws {
        let gate = ResourceReadGate()
        let buffer = SeekableResourceBuffer(maximumBytes: 1024)
        let resource = SeekableResource(size: 1000) { await gate.read($0) }
        let first = Task { try await buffer.read(id: "shared", range: 0..<100, resource: resource) }
        try await lifecycleWait { await gate.ranges.count == 1 }
        let second = Task { try await buffer.read(id: "shared", range: 50..<150, resource: resource) }
        await gate.open()
        #expect(try await first.value == Data((0..<100).map { UInt8($0 % 251) }))
        #expect(try await second.value == Data((50..<150).map { UInt8($0 % 251) }))
        #expect(await gate.ranges == [0..<100, 100..<150])
        let third = try await buffer.read(id: "shared", range: 20..<140, resource: resource)
        #expect(third.count == 120)
        #expect(await gate.ranges.count == 2)
        #expect(await buffer.snapshot(id: "shared").receivedBytes == 150)
    }

    @Test func cancellingOneOwnerKeepsTheOtherSharedReaderAlive() async throws {
        let gate = ResourceReadGate()
        let buffer = SeekableResourceBuffer()
        let resource = SeekableResource(size: 100) { await gate.read($0) }
        let session = PlaybackReadSession()
        let identity = PlaybackMediaIdentity(source: "fixture", account: "a", item: "movie")
        let preview = session.makeOwner(mediaIdentity: identity, purpose: .chapterPreview)
        let foreground = session.makeOwner(mediaIdentity: identity, purpose: .foreground)
        let a = Task { try await preview.perform { try await buffer.read(id: "one", range: 0..<100, resource: resource, phase: .preview) } }
        try await lifecycleWait { await gate.ranges.count == 1 }
        let b = Task { try await foreground.perform { try await buffer.read(id: "one", range: 0..<100, resource: resource) } }
        // Give the actor the second waiter before retiring the preview.
        try await Task.sleep(for: .milliseconds(30))
        preview.cancel()
        _ = await a.result
        await gate.open()
        #expect(try await b.value.count == 100)
        #expect(await gate.ranges.count == 1)
    }

    @Test func registeredSourceClosesOnlyAfterTheFinalAliasAndRead() async throws {
        let server = ProxyServer(); try server.start(); defer { server.stop() }
        let gate = ResourceReadGate(); await gate.open()
        let url = try server.registerSeekableResource(.init(size: 100, close: { await gate.close() }) { await gate.read($0) })
        let session = PlaybackReadSession()
        let identity = PlaybackMediaIdentity(source: "fixture", account: "a", item: "movie")
        let first = try #require(server.readLease(forLocalURL: url, session: session, mediaIdentity: identity, purpose: .foreground))
        let second = try #require(server.readLease(forLocalURL: url, session: session, mediaIdentity: identity, purpose: .subtitleExtraction))
        server.unregisterSeekableResource(url: url)
        #expect(!server.isRegisteredSeekableResource(url: url))
        first.cancel()
        var request = URLRequest(url: URL(string: second.url)!)
        request.setValue("bytes=0-99", forHTTPHeaderField: "Range")
        #expect(try await URLSession.shared.data(for: request).0.count == 100)
        #expect(await gate.closes == 0)
        second.cancel()
        try await lifecycleWait { await gate.closes == 1 }
    }

    @Test func seekAndStopRejectOldAuxiliaryAliasesBeforeAddingRequests() async throws {
        let server = ProxyServer(); try server.start(); defer { server.stop() }
        let gate = ResourceReadGate(); await gate.open()
        let url = try server.registerSeekableResource(.init(size: 100) { await gate.read($0) })
        let session = PlaybackReadSession()
        let identity = PlaybackMediaIdentity(source: "fixture", account: "a", item: "movie")
        let old = try #require(server.readLease(forLocalURL: url, session: session, mediaIdentity: identity, purpose: .nextEpisode))
        let foreground = try #require(server.readLease(forLocalURL: url, session: session, mediaIdentity: identity, purpose: .foreground))
        defer { old.cancel(); foreground.cancel(); server.unregisterSeekableResource(url: url) }
        session.advance()
        do { _ = try await URLSession.shared.data(from: URL(string: old.url)!); Issue.record("Old hint read data") } catch { }
        #expect(await gate.ranges.isEmpty)
        #expect(try await URLSession.shared.data(from: URL(string: foreground.url)!).0.count == 100)
        session.stop()
        do { _ = try await URLSession.shared.data(from: URL(string: foreground.url)!); Issue.record("Stopped session read data") } catch { }
        #expect(await gate.ranges.count == 1)
    }

    @Test func finalAliasReleaseWaitsForANonCooperativeReadBeforeClosingSource() async throws {
        let server = ProxyServer(); try server.start(); defer { server.stop() }
        let gate = ResourceReadGate()
        let url = try server.registerSeekableResource(.init(size: 100, close: { await gate.close() }) { await gate.read($0) })
        let session = PlaybackReadSession()
        let alias = try #require(server.readLease(forLocalURL: url, session: session,
            mediaIdentity: .init(source: "fixture", account: "a", item: "movie"), purpose: .foreground))
        let read = Task { try await URLSession.shared.data(from: URL(string: alias.url)!) }
        try await lifecycleWait { await gate.ranges.count == 1 }
        server.unregisterSeekableResource(url: url); alias.cancel()
        #expect(await gate.closes == 0)
        await gate.open()
        _ = await read.result
        try await lifecycleWait { await gate.closes == 1 }
    }

    @Test func closedBufferRejectsLateBytesAndShortReadsFailWithoutCaching() async throws {
        let buffer = SeekableResourceBuffer()
        let gate = ResourceReadGate()
        let resource = SeekableResource(size: 100) { await gate.read($0) }
        let read = Task { try await buffer.read(id: "old", range: 0..<100, resource: resource) }
        try await lifecycleWait { await gate.ranges.count == 1 }
        await buffer.close(id: "old"); await gate.open()
        do { _ = try await read.value; Issue.record("Closed resource accepted bytes") } catch { }
        #expect(await buffer.snapshot(id: "old").cachedBytes == 0)
        let short = SeekableResource(size: 100) { _ in Data([1]) }
        do { _ = try await buffer.read(id: "short", range: 0..<100, resource: short); Issue.record("Short read succeeded") } catch { }
        #expect(await buffer.snapshot(id: "short").cachedBytes == 0)
    }
}
