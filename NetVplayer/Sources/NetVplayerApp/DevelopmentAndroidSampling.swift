import CryptoKit
import Foundation

/// Reproducible sampling of original catalogue identities. No content is added
/// or substituted when a selected item fails.
enum DevelopmentAndroidSampling {
    static func indices(ids: [String], seed: String?, scope: String, offset: Int, count: Int) -> [Int] {
        let limit = min(3, max(1, count))
        guard let seed else { return Array(ids.indices.dropFirst(max(0, offset)).prefix(limit)) }
        var seen = Set<String>()
        let unique = ids.indices.filter { seen.insert(ids[$0]).inserted }
        var ranked: [(index: Int, rank: String)] = []
        for index in unique {
            let input = [seed, scope, ids[index]].map { "\($0.utf8.count):\($0)" }.joined()
            let rank = SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
            ranked.append((index, rank))
        }
        ranked.sort { lhs, rhs in
            if lhs.rank == rhs.rank { return lhs.index < rhs.index }
            return lhs.rank < rhs.rank
        }
        return ranked.dropFirst(max(0, offset)).prefix(limit).map { $0.index }
    }

    static func categoryExclusion(id: String, name: String) -> String? {
        if ["search", "sou"].contains(id.lowercased()) || name.contains("仅支持搜索") {
            return "search_action"
        }
        if ["peizhi", "设置", "配置"].contains(id.lowercased()) || name.contains("配置") {
            return "settings_action"
        }
        if ["登录", "登陆"].contains(where: name.contains) { return "authentication_action" }
        return nil
    }

    struct PlaybackProgress {
        private var first: Double?
        private var last: Double?
        private var count = 0

        mutating func observe(position: Double, playing: Bool, loading: Bool, buffering: Bool) -> Bool {
            guard playing, !loading, !buffering, position.isFinite else {
                self = Self()
                return false
            }
            if let last, position < last || position - last > 3 {
                self = Self()
            }
            if first == nil { first = position }
            last = position
            count += 1
            return count >= 6 && position - (first ?? position) >= 5
        }
    }

    /// A full observation is one uninterrupted run, measured independently by
    /// monotonic wall time and media progress. Invalid samples discard the run.
    struct ContinuousPlaybackWindow {
        let requiredSeconds: Double
        private var first: (time: Double, position: Double)?
        private var last: (time: Double, position: Double)?
        private(set) var sampleCount = 0

        init(requiredSeconds: Double) { self.requiredSeconds = requiredSeconds }

        var elapsedSeconds: Double { guard let first, let last else { return 0 }; return last.time - first.time }
        var advancedSeconds: Double { guard let first, let last else { return 0 }; return last.position - first.position }
        var firstPosition: Double? { first?.position }
        var lastPosition: Double? { last?.position }
        var complete: Bool { sampleCount >= 2 && elapsedSeconds >= requiredSeconds && advancedSeconds >= requiredSeconds }

        mutating func observe(time: Double, position: Double, playing: Bool, loading: Bool,
                              buffering: Bool, seeking: Bool = false, speed: Double = 1,
                              decoded: Bool = true, identityMatches: Bool = true) -> Bool {
            guard requiredSeconds.isFinite, requiredSeconds > 0, time.isFinite,
                  position.isFinite, position >= 0, playing, !loading, !buffering,
                  !seeking, speed == 1, decoded, identityMatches else {
                reset()
                return false
            }
            if let last {
                let wall = time - last.time
                let media = position - last.position
                // A delayed sample can be valid; an unobserved interval, a stall,
                // or a media jump cannot substitute for continuous playback.
                if wall <= 0 || wall > 10 || media <= 0 || media > wall * 1.5 + 0.25 { reset() }
            }
            if first == nil { first = (time, position) }
            last = (time, position)
            sampleCount += 1
            return complete
        }

        private mutating func reset() { first = nil; last = nil; sampleCount = 0 }
    }

    /// Judge the first settled position after a seek or history load. Later
    /// playback reaching the target cannot repair an initially wrong landing.
    struct PlaybackTargetLanding {
        let targetSeconds: Double
        let toleranceSeconds: Double = 12
        private(set) var firstSettledPosition: Double?
        private(set) var reached = false
        private(set) var failed = false

        mutating func observe(position: Double, settled: Bool) -> Bool {
            guard !failed, !reached else { return reached }
            guard settled else { return false }
            guard targetSeconds.isFinite, targetSeconds >= 0, position.isFinite, position >= 0 else {
                failed = true
                return false
            }
            firstSettledPosition = position
            reached = abs(position - targetSeconds) <= toleranceSeconds
            failed = !reached
            return reached
        }
    }

    static func milliseconds(since start: TimeInterval) -> Double {
        max(0, (ProcessInfo.processInfo.systemUptime - start) * 1_000)
    }
}
