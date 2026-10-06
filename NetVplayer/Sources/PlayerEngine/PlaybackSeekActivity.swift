import Foundation

/// A token is attached when the native event is read, before it can reach UI state.
struct PlaybackEventOwner: Equatable, Sendable {
    var mediaID = UUID()
    var seek: UInt64 = 0
}

struct PlaybackSeekActivity: Sendable {
    private(set) var owner = PlaybackEventOwner()
    private(set) var isPending = false
    private var sawSeek = false
    private var sawRestart = false
    private var nativeSeeking = false

    mutating func resetMedia() {
        self = PlaybackSeekActivity()
    }

    @discardableResult
    mutating func begin() -> PlaybackEventOwner {
        owner.seek &+= 1
        isPending = true
        sawSeek = false
        sawRestart = false
        nativeSeeking = true
        return owner
    }

    mutating func observeSeek(owner: PlaybackEventOwner) {
        guard self.owner == owner, isPending else { return }
        sawSeek = true
    }

    @discardableResult
    mutating func observeRestart(owner: PlaybackEventOwner) -> Bool {
        guard self.owner == owner, isPending, sawSeek, !sawRestart else { return false }
        sawRestart = true
        return true
    }

    mutating func observeSeeking(_ value: Bool, owner: PlaybackEventOwner) {
        guard self.owner == owner, isPending else { return }
        nativeSeeking = value
    }

    func isReady(owner: PlaybackEventOwner, pausedForCache: Bool) -> Bool {
        self.owner == owner && isPending && sawSeek && sawRestart && !nativeSeeking && !pausedForCache
    }

    mutating func finish(owner: PlaybackEventOwner) {
        guard self.owner == owner else { return }
        isPending = false
    }
}
