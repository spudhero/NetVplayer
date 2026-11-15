import Foundation
import Models

/// Serial, bounded, coalescing control traffic. Stopped is terminal, even when
/// a server ignores cancellation or a previous Progress is still in flight.
public actor MediaServerPlaybackReporter {
    private let client: MediaServerClient
    private let itemID: String
    private let sourceID: String
    private let sessionID: String
    private let durationTicks: Int64?
    private let fnOSContext: FnOSPlaybackContext?
    private var started = false
    private var stopped = false
    private var running = false
    private var pending: (String, MediaServerPlaybackSnapshot)?
    private var last: MediaServerPlaybackSnapshot?
    private var observed: MediaServerPlaybackSnapshot?
    private var lastSent = ContinuousClock.Instant.now - .seconds(10)
    public private(set) var failures = 0
    public init(client: MediaServerClient, itemID: String, sourceID: String, sessionID: String, durationTicks: Int64? = nil, fnOSContext: FnOSPlaybackContext? = nil) {
        self.client = client; self.itemID = itemID; self.sourceID = sourceID; self.sessionID = sessionID
        self.durationTicks = durationTicks
        self.fnOSContext = fnOSContext
    }
    public func update(_ snapshot: MediaServerPlaybackSnapshot, start: Bool = false) {
        guard !stopped else { return }
        let previous = observed
        observed = snapshot
        if !started {
            guard start else { return }
            started = true; pending = ("", snapshot)
        } else {
            let changed = previous.map { $0.paused != snapshot.paused || $0.audioIndex != snapshot.audioIndex ||
                $0.subtitleIndex != snapshot.subtitleIndex || $0.rate != snapshot.rate || $0.muted != snapshot.muted ||
                $0.volume != snapshot.volume || abs($0.seconds - snapshot.seconds) > 3 } ?? true
            guard changed || ContinuousClock.now - lastSent >= .seconds(10) else { return }
            if pending?.0 != "" { pending = ("Progress", snapshot) }
        }
        last = snapshot; lastSent = .now
        launch()
    }
    public func stop(_ snapshot: MediaServerPlaybackSnapshot?) {
        guard !stopped else { return }
        stopped = true
        guard started else { return }
        // Keep a queued Started, then the final snapshot; never send Progress after Stopped.
        finalSnapshot = snapshot ?? last ?? .init()
        launch()
    }
    private var finalSnapshot: MediaServerPlaybackSnapshot?
    private func launch() {
        guard !running else { return }
        running = true
        Task { await drain() }
    }
    private func drain() async {
        while pending != nil || finalSnapshot != nil {
            let next: (String, MediaServerPlaybackSnapshot)
            if let value = pending { next = value; pending = nil }
            else { next = ("Stopped", finalSnapshot!); finalSnapshot = nil }
            do {
                if let fnOSContext { try await client.fnOSReport(fnOSContext, snapshot: next.1) }
                else { try await client.report(path: next.0, payload: payload(next.1, path: next.0)) }
            }
            catch {
                failures += 1
                // Never include server bodies, URLs, header values, or NSError userInfo.
                DiagnosticLog.write("[MEDIA_SERVER_REPORT] phase=\(next.0.isEmpty ? "Started" : next.0) failed=true")
            }
        }
        running = false
    }
    func payload(_ snapshot: MediaServerPlaybackSnapshot, path: String) throws -> Data {
        var value: [String: Any] = ["ItemId": itemID, "MediaSourceId": sourceID, "PlaySessionId": sessionID,
            "PositionTicks": snapshot.ticks, "IsPaused": snapshot.paused, "IsMuted": snapshot.muted,
            "VolumeLevel": snapshot.volume, "PlaybackRate": snapshot.rate, "CanSeek": true,
            "PlayMethod": "DirectPlay", "QueueableMediaTypes": ["Video", "Audio"]]
        if let index = snapshot.audioIndex { value["AudioStreamIndex"] = index }
        if let index = snapshot.subtitleIndex { value["SubtitleStreamIndex"] = index }
        if path == "Progress" { value["EventName"] = "TimeUpdate" }
        if let durationTicks { value["DurationTicks"] = durationTicks }
        return try JSONSerialization.data(withJSONObject: value)
    }
    public var idle: Bool { !running }
}
