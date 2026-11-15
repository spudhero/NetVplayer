import AppKit
import Foundation
import SwiftUI
import Testing
import Models
import LiveEngine
import Networking
@testable import PlayerEngine
import Storage
@testable import NetVplayerApp

@Suite("Generic live catchup policy")
struct LiveCatchupPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_792_360_800)
    private var programme: EpgItem { .init(title: "Midnight", start: now.addingTimeInterval(-3_600), end: now.addingTimeInterval(-1_800)) }
    private func channel(_ catchup: Catchup? = .init(source: "?utc={utc}&duration={duration}", type: "append", days: 7)) -> Channel {
        .init(name: "Channel", urls: ["https://media.example.test/live.m3u8"], catchup: catchup)
    }
    private func availability(_ catchup: Catchup?, item: EpgItem? = nil, offset: Double = 0, zone: TimeZone? = nil) -> LiveCatchupAvailability {
        LiveCatchupPolicy.availability(channel: channel(catchup), programme: item ?? programme, now: now, timeZone: zone, offset: offset)
    }

    @Test func distinguishesMissingFutureOnAirExpiredAndUnsupported() {
        let ch = channel()
        #expect(LiveCatchupPolicy.availability(channel: ch, programme: nil, now: now, timeZone: nil) == .unavailable(.missingProgramme))
        #expect(availability(ch.catchup, item: .init(start: now.addingTimeInterval(1), end: now.addingTimeInterval(100))) == .unavailable(.future))
        #expect(availability(ch.catchup, item: .init(start: now.addingTimeInterval(-100), end: now.addingTimeInterval(1))) == .unavailable(.onAir))
        #expect(availability(ch.catchup, item: .init(start: now.addingTimeInterval(-8 * 86_400), end: now.addingTimeInterval(-7 * 86_400))) == .unavailable(.expired))
        #expect(availability(nil) == .unavailable(.unsupported))
        #expect(availability(.init(type: "none")) == .unavailable(.unsupported))
        #expect(availability(.init(type: "unknown-provider")) == .unavailable(.unsupportedType))
    }

    @Test func validatesProgrammeTemplateAndNetworkURL() {
        #expect(availability(channel().catchup, item: .init(start: now, end: now)) == .unavailable(.invalidProgramme))
        for source in ["", "relative.m3u8", "file:///tmp/secret", "https://example.test/a b", "https://example.test/a#fragment"] {
            #expect(availability(.init(source: source, type: "default")) == .unavailable(.invalidTemplate))
        }
        for source in ["https://example.test/{timestamp}", "https://example.test/{utc", "https://example.test/utc}"] {
            #expect(availability(.init(source: source, type: "default")) == .unavailable(.unknownPlaceholder))
        }
        #expect(availability(.init(source: "https://example.test/{utc}", days: -1)) == .unavailable(.invalidTemplate))
        #expect(availability(channel().catchup, offset: .nan) == .unavailable(.invalidProgramme))
        #expect(availability(channel().catchup, offset: 1_800) == .unavailable(.invalidProgramme))
    }

    @Test func legacyTokensRetainTheirMeaningAndRequireExplicitCalendarTimeZone() throws {
        let template = Catchup(source: "https://archive.example.test/{lutc}?start={utc}&duration={duration}", type: "default")
        #expect(availability(template) == .unavailable(.missingTimeZone))
        let zone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let result = availability(template, zone: zone)
        guard case .available(let request) = result else { Issue.record("expected request"); return }
        #expect(request.url == template.playbackURL(channelURL: channel().currentUrl!, start: programme.start, end: programme.end, timeZone: zone))
        #expect(request.supportsRequestSeek)
        #expect(!request.url.contains("{lutc}"))
        #expect(availability(.init(type: "xc")) == .unavailable(.missingTimeZone))
    }

    @Test(arguments: ["append", "default", "flussonic", "shift", "xc"])
    func allExistingAddressFormatsUseOriginalRenderer(type: String) throws {
        let template = Catchup(source: type == "append" ? "?utc={utc}&duration={duration}" : "https://archive.example.test/{start}/{duration}", type: type, days: 7)
        let zone = TimeZone(secondsFromGMT: 0)!
        guard case .available(let request) = availability(template, zone: zone) else { Issue.record("expected request"); return }
        #expect(request.url == template.playbackURL(channelURL: channel().currentUrl!, start: programme.start, end: programme.end, timeZone: zone))
    }

    @Test func requestSeekMovesOnlyRequestedWindowAndKeepsProgrammeDuration() throws {
        guard case .available(let request) = availability(channel().catchup, offset: 601.8) else { Issue.record("expected request"); return }
        #expect(request.mediaStartOffset == 601)
        #expect(request.url.contains("utc=\(Int(programme.start.timeIntervalSince1970) + 601)"))
        #expect(request.url.contains("duration=1199"))
        let context = LiveCatchupContext(sourceFingerprint: "source", sourceRevision: UUID(), channelFingerprint: "channel",
            channelName: "Channel", programme: programme, mediaStartOffset: request.mediaStartOffset, supportsRequestSeek: true)
        #expect(context.programme == programme && context.duration == 1_800)
        #expect(context.programmePosition(mediaPosition: 10) == 611)
        #expect(context.programmePosition(mediaPosition: 2_000) == 1_800)
        #expect(LiveCatchupPolicy.seek(context: context, target: 300, nativeSeekable: true, mediaDuration: 1_199) == .request(programmePosition: 300))
        #expect(LiveCatchupPolicy.seek(context: context, target: 900, nativeSeekable: true, mediaDuration: 1_199) == .native(mediaPosition: 299))
        #expect(LiveCatchupPolicy.seek(context: context, target: 900, nativeSeekable: false, mediaDuration: 1_199) == .request(programmePosition: 900))
        #expect(LiveCatchupPolicy.seek(context: context, target: 1_800, nativeSeekable: false, mediaDuration: 0) == .finish)
    }

    @Test func fixedURLRequiresConfirmedNativeSeekAndUnspecifiedRetentionDoesNotInventExpiry() {
        let template = Catchup(source: "https://archive.example.test/fixed.mp4", type: "default", days: 0)
        guard case .available(let request) = availability(template) else { Issue.record("expected request"); return }
        #expect(!request.supportsRequestSeek)
        let context = LiveCatchupContext(sourceFingerprint: "source", sourceRevision: UUID(), channelFingerprint: "channel",
            channelName: "Channel", programme: programme, supportsRequestSeek: false)
        #expect(LiveCatchupPolicy.seek(context: context, target: 30, nativeSeekable: nil, mediaDuration: 1_800) == .unsupported)
        #expect(LiveCatchupPolicy.seek(context: context, target: 30, nativeSeekable: false, mediaDuration: 1_800) == .unsupported)
        #expect(LiveCatchupPolicy.seek(context: context, target: 30, nativeSeekable: true, mediaDuration: 1_800) == .native(mediaPosition: 30))
        #expect(LiveCatchupPolicy.seek(context: context, target: .nan, nativeSeekable: true, mediaDuration: 1_800) == .unsupported)
        #expect(availability(template, item: .init(start: now.addingTimeInterval(-30 * 86_400), end: now.addingTimeInterval(-29 * 86_400))).isAvailable)
    }

    @Test func programmeBoundaryIsAFileLocalOptionAndDoesNotLeakToLive() {
        let context = LiveCatchupContext(sourceFingerprint: "source", sourceRevision: UUID(), channelFingerprint: "channel",
            channelName: "Channel", programme: programme, mediaStartOffset: 600, supportsRequestSeek: true)
        var archive = PlaySpec(url: "https://archive.example.test/a", metadata: ["playback.kind": "live"])
        archive.liveCatchup = context
        #expect(MPVInitialStartPolicy.loadFileOptions(for: archive) == "end=1200.0")
        archive.liveCatchup = nil
        #expect(MPVInitialStartPolicy.loadFileOptions(for: archive) == nil)
    }

    @Test func m3uRetainsCatchupAndFingerprintsCoverHeadersAndTemplates() throws {
        let groups = M3UParser.parse(text: """
        #EXTM3U
        #EXTINF:-1 tvg-id="ch1" catchup="append" catchup-source="?start={utc}&duration={duration}" catchup-days="7",Channel
        https://media.example.test/live.m3u8
        """)
        var parsed = try #require(groups.first?.channels.first)
        #expect(parsed.catchup?.source == "?start={utc}&duration={duration}")
        let original = LiveCatchupPolicy.channelFingerprint(parsed)
        parsed.currentUrlIndex = 99
        #expect(LiveCatchupPolicy.channelFingerprint(parsed) == original)
        parsed.header["Authorization"] = "private-token"
        #expect(LiveCatchupPolicy.channelFingerprint(parsed) != original)
        #expect(!LiveCatchupPolicy.channelFingerprint(parsed).contains("private-token"))
        var live = Live(name: "A", url: "https://source.example.test/a", timeZone: "UTC")
        let source = LiveCatchupPolicy.sourceFingerprint(live)
        live.groups = groups
        #expect(LiveCatchupPolicy.sourceFingerprint(live) == source)
        live.timeZone = "Asia/Shanghai"
        #expect(LiveCatchupPolicy.sourceFingerprint(live) != source)
    }
}

@Suite("AppState live catchup", .serialized) @MainActor
struct AppStateLiveCatchupTests {
    private func withState(_ body: (AppState, Channel, EpgItem, CatchupSpecCapture) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("catchup-\(UUID())")
        let suite = "catchup-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatchupURLProtocol.self]
        CatchupURLProtocol.reset()
        let state = AppState(loadDefaultConfig: false, startProxyServer: false, startProviderRuntime: false,
            liveHTTPClient: HTTPClient(session: URLSession(configuration: configuration)),
            storageManager: StorageManager(storageDirectory: directory), userPreferences: UserPreferences(defaults: defaults))
        let channel = Channel(name: "Archive fixture", number: "1", urls: ["https://catchup.example.test/live.m3u8", "https://catchup.example.test/alternate.m3u8"],
            header: ["Authorization": "fixture-secret"], catchup: .init(source: "?utc={utc}&duration={duration}", type: "append", days: 7))
        await state.changeLive(.init(name: "Fixture", url: "https://catchup.example.test/channels.txt"), initialGroups: [.init(name: "Group", channels: [channel])])
        state.presentLivePlayer()
        let capture = CatchupSpecCapture()
        state.playSpecHandler = { spec in
            capture.specs.append(spec)
            state.livePlayerState.currentSpec = spec
        }
        defer { state.dismissLivePlayer(); CatchupURLProtocol.reset() }
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let programme = EpgItem(title: "Fixture programme", start: now.addingTimeInterval(-3_600), end: now.addingTimeInterval(-1_800))
        try await body(state, channel, programme, capture)
    }

    @Test func requestSeekRetryAndReturnToLivePreserveProgrammeAndRotateRequestIdentity() async throws {
        try await withState { state, channel, programme, capture in
            await state.playLiveCatchup(channel: channel, programme: programme)
            let first = try #require(capture.specs.last)
            let firstContext = try #require(first.liveCatchup)
            #expect(first.headers["Authorization"] == "fixture-secret")
            #expect(!first.metadata.values.contains { $0.contains("fixture-secret") })
            state.handleMPVPlaybackStarted(spec: first)
            #expect(state.liveCatchupPhase == .playing)
            state.livePlayerState.isSeekable = false
            #expect(await state.seekLiveCatchup(to: 600) == .request(programmePosition: 600))
            let second = try #require(capture.specs.last)
            let context = try #require(second.liveCatchup)
            #expect(context.requestID != firstContext.requestID)
            #expect(context.programme == programme && context.mediaStartOffset == 600)
            #expect(second.url.contains("duration=1200"))
            state.handleMPVPlaybackStarted(spec: second)
            state.handleMPVPlaybackPosition(spec: second, positionSeconds: 25)
            #expect(state.liveCatchupPosition == 625)
            state.handleMPVPlaybackPosition(spec: first, positionSeconds: 1_790)
            state.handleMPVPlaybackFailure(spec: first, message: "old failure")
            #expect(state.liveCatchupPosition == 625 && state.liveError == nil)
            state.handleMPVPlaybackFailure(spec: second, message: "https://secret.example/?token=private")
            #expect(state.liveCatchupPhase == .failed)
            #expect(state.liveError?.contains("private") == false)
            await state.retryLiveCatchup()
            let retried = try #require(capture.specs.last)
            #expect(retried.liveCatchup?.mediaStartOffset == 625)
            #expect(retried.liveCatchup?.programme == programme)
            await state.returnToLiveFromCatchup()
            #expect(state.liveCatchupContext == nil)
            #expect(capture.specs.last?.liveCatchup == nil)
            #expect(capture.specs.last?.url == channel.urls[0])
        }
    }

    @Test func programmeEndStopsAndRequiresExplicitReplayOrLive() async throws {
        try await withState { state, channel, programme, capture in
            await state.playLiveCatchup(channel: channel, programme: programme)
            let spec = try #require(capture.specs.last)
            state.handleMPVPlaybackStarted(spec: spec)
            state.handleMPVPlaybackPosition(spec: spec, positionSeconds: 1_800)
            #expect(state.liveCatchupPhase == .ended && state.liveCatchupPosition == 1_800)
            #expect(capture.specs.count == 1)
            state.handleMPVPlaybackStarted(spec: spec)
            state.handleMPVPlaybackFailure(spec: spec, message: "late failure")
            #expect(state.liveCatchupPhase == .ended && state.liveError == nil)
            await state.retryLiveCatchup(fromBeginning: true)
            #expect(capture.specs.count == 2)
            #expect(capture.specs.last?.liveCatchup?.mediaStartOffset == 0)
        }
    }

    @Test func earlyEOFIsFailureAndSeekToEndDoesNotRequestZeroLengthMedia() async throws {
        try await withState { state, channel, programme, capture in
            await state.playLiveCatchup(channel: channel, programme: programme)
            var spec = try #require(capture.specs.last)
            state.handleMPVPlaybackStarted(spec: spec)
            state.handleMPVPlaybackPosition(spec: spec, positionSeconds: 12)
            state.handleMPVPlaybackEnded(spec: spec)
            #expect(state.liveCatchupPhase == .failed && state.liveCatchupPosition == 12)
            await state.retryLiveCatchup()
            spec = try #require(capture.specs.last)
            state.handleMPVPlaybackStarted(spec: spec)
            #expect(await state.seekLiveCatchup(to: 1_800) == .finish)
            #expect(state.liveCatchupPhase == .ended && capture.specs.count == 2)
        }
    }

    @Test func switchingLineKeepsArchiveAndShowingWindowDoesNotReturnToLive() async throws {
        try await withState { state, channel, programme, capture in
            await state.playLiveCatchup(channel: channel, programme: programme, offset: 300)
            let first = try #require(capture.specs.last)
            state.handleMPVPlaybackStarted(spec: first)
            state.handleMPVPlaybackPosition(spec: first, positionSeconds: 20)
            await state.resumeSelectedLiveChannelIfNeeded()
            #expect(capture.specs.count == 1)
            await state.changeChannelUrlIndex(1)
            #expect(capture.specs.last?.liveCatchup?.mediaStartOffset == 320)
            #expect(capture.specs.last?.url.hasPrefix(channel.urls[1]) == true)
            #expect(capture.specs.last?.liveCatchup?.programme == programme)
        }
    }

    @Test func sourceSwitchAndSameURLRefreshRejectOldRequestsAndGuideActions() async throws {
        try await withState { state, channel, programme, capture in
            let revision = state.liveSourceRevision
            await state.playLiveCatchup(channel: channel, programme: programme, revision: revision)
            let spec = try #require(capture.specs.last)
            #expect(await state.loadLiveContent())
            #expect(state.liveCatchupContext == nil && state.liveSourceRevision != revision)
            state.handleMPVPlaybackStarted(spec: spec)
            state.handleMPVPlaybackPosition(spec: spec, positionSeconds: 600)
            await state.playLiveCatchup(channel: channel, programme: programme, revision: revision)
            #expect(state.liveCatchupContext == nil && capture.specs.count == 1)
            await state.changeLive(.init(name: "Other", url: "https://other.example.test/list"), initialGroups: [.init(name: "Other", channels: [])])
            #expect(!state.liveCatchupAvailability(channel: channel, programme: programme).isAvailable)
            state.handleMPVPlaybackFailure(spec: spec, message: "old")
            #expect(state.liveError == nil)
        }
    }

    @Test func cancelledOrDelayedPreparationCannotStartAfterChannelSwitch() async throws {
        try await withState { state, channel, programme, capture in
            CatchupURLProtocol.delayArchives = true
            let task = Task { await state.playLiveCatchup(channel: channel, programme: programme) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while CatchupURLProtocol.archiveRequests == 0, ContinuousClock.now < deadline { await Task.yield() }
            #expect(CatchupURLProtocol.archiveRequests == 1)
            await state.playChannel(channel)
            await task.value
            try await Task.sleep(for: .milliseconds(200))
            #expect(capture.specs.count == 1 && capture.specs.first?.liveCatchup == nil)
            #expect(state.liveError == nil && state.liveCatchupContext == nil)
        }
    }

    @Test func fixedArchiveWithoutNativeSeekGivesExplicitUnsupportedResult() async throws {
        try await withState { state, channel, programme, capture in
            var fixed = channel
            fixed.catchup = .init(source: "https://catchup.example.test/fixed.mp4", type: "default")
            await state.changeLive(.init(name: "Fixed", url: "https://catchup.example.test/list"), initialGroups: [.init(name: "G", channels: [fixed])])
            capture.specs = []
            await state.playLiveCatchup(channel: fixed, programme: programme)
            let spec = try #require(capture.specs.last)
            state.handleMPVPlaybackStarted(spec: spec)
            state.livePlayerState.duration = 1_800
            state.livePlayerState.isSeekable = false
            #expect(!state.liveCatchupCanSeek)
            #expect(await state.seekLiveCatchup(to: 60) == .unsupported)
            #expect(state.liveCatchupNotice == L10n.text("此回放不支持跳转"))
            #expect(capture.specs.count == 1)
        }
    }

    @Test func archiveProbeUsesSmallRangeAndDoesNotExposeHeadersInMetadata() async throws {
        try await withState { state, channel, programme, capture in
            CatchupURLProtocol.largeBody = true
            await state.playLiveCatchup(channel: channel, programme: programme)
            #expect(capture.specs.count == 1)
            #expect(CatchupURLProtocol.archiveRange == "bytes=0-4095")
            #expect(CatchupURLProtocol.archiveAuthorization == "fixture-secret")
        }
    }

    @Test func catchupControlsFitRegularAndCompactNativeLayouts() throws {
        _ = NSApplication.shared
        let item = EpgItem(title: "跨午夜的节目回放 · Programme", start: Date().addingTimeInterval(-3_600), end: Date().addingTimeInterval(-1_800))
        let context = LiveCatchupContext(sourceFingerprint: "fixture", sourceRevision: UUID(), channelFingerprint: "fixture",
            channelName: "Fixture Channel", programme: item, supportsRequestSeek: true)
        for compact in [false, true] {
            let view = NSHostingView(rootView: LiveCatchupControls(context: context, phase: compact ? .failed : .playing,
                position: 625, canSeek: !compact, message: compact ? L10n.text("回放加载失败，可重试或返回直播。") : L10n.text("跳转时将重新请求回放"), compact: compact,
                onSeek: { _ in }, onRetry: {}, onReplay: {}, onReturnToLive: {}))
            view.frame = NSRect(x: 0, y: 0, width: compact ? 411 : 780, height: compact ? 112 : 150)
            view.layoutSubtreeIfNeeded()
            #expect(view.fittingSize.width <= view.frame.width)
            #expect(view.fittingSize.height <= view.frame.height)
            if let output = ProcessInfo.processInfo.environment["NETVPLAYER_CATCHUP_CAPTURE_DIRECTORY"] {
                let directory = URL(fileURLWithPath: output)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(compact ? "catchup-compact.png" : "catchup-regular.png"))
            }
        }
    }
}

@MainActor private final class CatchupSpecCapture { var specs: [PlaySpec] = [] }

private final class CatchupURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) static var delayArchives = false
    nonisolated(unsafe) static var largeBody = false
    nonisolated(unsafe) static var archiveRequests = 0
    nonisolated(unsafe) static var archiveRange: String?
    nonisolated(unsafe) static var archiveAuthorization: String?
    static func reset() {
        lock.lock(); defer { lock.unlock() }
        delayArchives = false; largeBody = false; archiveRequests = 0; archiveRange = nil; archiveAuthorization = nil
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let archive = url.query?.contains("utc=") == true || url.path == "/fixed.mp4"
        Self.lock.lock()
        if archive {
            Self.archiveRequests += 1
            Self.archiveRange = request.value(forHTTPHeaderField: "Range")
            Self.archiveAuthorization = request.value(forHTTPHeaderField: "Authorization")
        }
        let delay = archive && Self.delayArchives
        let large = archive && Self.largeBody
        Self.lock.unlock()
        let deliver: @Sendable () -> Void = { [self] in
            let list = url.path.hasSuffix(".txt")
            let body = list ? "Group,#genre#\nArchive fixture,https://catchup.example.test/live.m3u8\n" : "#EXTM3U\n#EXT-X-VERSION:3\n" + (large ? String(repeating: "#fixture\n", count: 8_192) : "")
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": list ? "text/plain" : "application/vnd.apple.mpegurl"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        if delay { DispatchQueue.global().asyncAfter(deadline: .now() + 0.15, execute: deliver) } else { deliver() }
    }
    override func stopLoading() {}
}
