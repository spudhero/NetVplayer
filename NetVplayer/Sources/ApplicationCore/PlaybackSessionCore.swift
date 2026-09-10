import Foundation
import Models

public enum PlaybackSessionPhase: String, Sendable {
    case idle
    case loadingSource
    case awaitingSelection
    case resolvingCandidate
    case startingPlayback
    case playing
    case failed
}

public struct PlaybackEpisodeIntent: Sendable {
    public var generation: UInt64
    public var site: Site
    public var episode: Episode
    public var resumePosition: Int64?
    public var resumeDuration: Int64?
    public var isAutomatic: Bool
    public var preferenceKey: String

    public init(
        generation: UInt64,
        site: Site,
        episode: Episode,
        resumePosition: Int64? = nil,
        resumeDuration: Int64? = nil,
        isAutomatic: Bool = false,
        preferenceKey: String = ""
    ) {
        self.generation = generation
        self.site = site
        self.episode = episode
        self.resumePosition = resumePosition
        self.resumeDuration = resumeDuration
        self.isAutomatic = isAutomatic
        self.preferenceKey = preferenceKey
    }
}

public struct PlaybackSelectionRequest: Identifiable, Sendable {
    public let id: UUID
    public let generation: UInt64
    public let site: Site
    public let episode: Episode
    public let result: Result
    public let resumePosition: Int64?
    public let resumeDuration: Int64?
    public let isAutomatic: Bool
    public let preferenceKey: String

    public init(
        id: UUID = UUID(),
        generation: UInt64 = 0,
        site: Site,
        episode: Episode,
        result: Result,
        resumePosition: Int64?,
        resumeDuration: Int64?,
        isAutomatic: Bool,
        preferenceKey: String = ""
    ) {
        self.id = id
        self.generation = generation
        self.site = site
        self.episode = episode
        self.result = result
        self.resumePosition = resumePosition
        self.resumeDuration = resumeDuration
        self.isAutomatic = isAutomatic
        self.preferenceKey = preferenceKey
    }

    public var candidates: [PlaybackCandidate] { result.playbackCandidates }
}

public struct PlaybackSessionState: Sendable {
    public var generation: UInt64
    public var phase: PlaybackSessionPhase
    public var intent: PlaybackEpisodeIntent?
    public var selection: PlaybackSelectionRequest?
    public var autoAdvanceEpisodeURL: String?

    public init(
        generation: UInt64 = 0,
        phase: PlaybackSessionPhase = .idle,
        intent: PlaybackEpisodeIntent? = nil,
        selection: PlaybackSelectionRequest? = nil,
        autoAdvanceEpisodeURL: String? = nil
    ) {
        self.generation = generation
        self.phase = phase
        self.intent = intent
        self.selection = selection
        self.autoAdvanceEpisodeURL = autoAdvanceEpisodeURL
    }
}

public enum PlaybackSessionFailure: Equatable, Sendable, Error {
    case staleSession
    case invalidCandidate
    case unavailableCandidate
}

public enum PlaybackSessionCommand: Sendable {
    case none
    case resolveCandidate(
        request: PlaybackSelectionRequest,
        candidate: PlaybackCandidate,
        rememberPreference: Bool
    )
    case startResolved(intent: PlaybackEpisodeIntent, result: Result)
}

public struct PlaybackSessionTransition: Sendable {
    public var state: PlaybackSessionState
    public var command: PlaybackSessionCommand
    public var failure: PlaybackSessionFailure?

    public init(
        state: PlaybackSessionState,
        command: PlaybackSessionCommand = .none,
        failure: PlaybackSessionFailure? = nil
    ) {
        self.state = state
        self.command = command
        self.failure = failure
    }
}

public struct PlaybackEpisodeContext: Sendable {
    public let currentEpisode: Episode?
    public let currentEpisodeURL: String
    public let currentEpisodeName: String
    public let currentIndex: Int?
    public let total: Int
    public let previousEpisode: Episode?
    public let nextEpisode: Episode?
    public let progressText: String?

    public init(
        currentEpisode: Episode?,
        currentEpisodeURL: String,
        currentEpisodeName: String,
        currentIndex: Int?,
        total: Int,
        previousEpisode: Episode?,
        nextEpisode: Episode?,
        progressText: String?
    ) {
        self.currentEpisode = currentEpisode
        self.currentEpisodeURL = currentEpisodeURL
        self.currentEpisodeName = currentEpisodeName
        self.currentIndex = currentIndex
        self.total = total
        self.previousEpisode = previousEpisode
        self.nextEpisode = nextEpisode
        self.progressText = progressText
    }

    public var hasPrevious: Bool { previousEpisode != nil }
    public var hasNext: Bool { nextEpisode != nil }
}

public struct PlaybackAutoAdvanceTransition: Sendable {
    public var state: PlaybackSessionState
    public var targetEpisode: Episode?

    public init(state: PlaybackSessionState, targetEpisode: Episode? = nil) {
        self.state = state
        self.targetEpisode = targetEpisode
    }
}

public enum PlaybackSessionCore {
    public static func beginEpisode(
        _ current: PlaybackSessionState,
        site: Site,
        episode: Episode,
        resumePosition: Int64? = nil,
        resumeDuration: Int64? = nil,
        automaticSelection: Bool = false,
        preferenceKey: String = ""
    ) -> PlaybackSessionState {
        var state = current
        state.generation &+= 1
        state.phase = .loadingSource
        state.intent = PlaybackEpisodeIntent(
            generation: state.generation,
            site: site,
            episode: episode,
            resumePosition: resumePosition,
            resumeDuration: resumeDuration,
            isAutomatic: automaticSelection,
            preferenceKey: preferenceKey
        )
        state.selection = nil
        if !automaticSelection {
            state.autoAdvanceEpisodeURL = nil
        }
        return state
    }

    public static func receivePlayerResult(
        _ current: PlaybackSessionState,
        generation: UInt64,
        result: Result,
        preferredSignature: String?
    ) -> PlaybackSessionTransition {
        guard current.generation == generation,
              current.phase == .loadingSource,
              let intent = current.intent,
              intent.generation == generation else {
            return PlaybackSessionTransition(state: current, failure: .staleSession)
        }

        var state = current
        guard !result.playbackCandidates.isEmpty else {
            state.phase = .startingPlayback
            state.autoAdvanceEpisodeURL = nil
            return PlaybackSessionTransition(
                state: state,
                command: .startResolved(intent: intent, result: result)
            )
        }

        let request = PlaybackSelectionRequest(
            generation: generation,
            site: intent.site,
            episode: intent.episode,
            result: result,
            resumePosition: intent.resumePosition,
            resumeDuration: intent.resumeDuration,
            isAutomatic: intent.isAutomatic,
            preferenceKey: intent.preferenceKey
        )
        let playable = request.candidates.filter(\.isPlayable)
        let preferred = intent.isAutomatic
            ? preferredSignature.flatMap { signature in
                playable.first(where: { $0.preferenceSignature == signature })
            }
            : nil

        if let candidate = preferred ?? (playable.count == 1 ? playable[0] : nil) {
            state.phase = .resolvingCandidate
            return PlaybackSessionTransition(
                state: state,
                command: .resolveCandidate(
                    request: request,
                    candidate: candidate,
                    rememberPreference: false
                )
            )
        }

        state.phase = .awaitingSelection
        state.selection = request
        return PlaybackSessionTransition(state: state)
    }

    public static func selectCandidate(
        _ current: PlaybackSessionState,
        selectionID: UUID,
        candidateID: String
    ) -> PlaybackSessionTransition {
        guard current.phase == .awaitingSelection,
              let request = current.selection,
              request.id == selectionID,
              request.generation == current.generation else {
            return PlaybackSessionTransition(state: current, failure: .staleSession)
        }
        guard let candidate = request.candidates.first(where: { $0.id == candidateID }) else {
            return PlaybackSessionTransition(state: current, failure: .invalidCandidate)
        }
        guard candidate.isPlayable else {
            return PlaybackSessionTransition(state: current, failure: .unavailableCandidate)
        }

        var state = current
        state.phase = .resolvingCandidate
        state.selection = nil
        return PlaybackSessionTransition(
            state: state,
            command: .resolveCandidate(
                request: request,
                candidate: candidate,
                rememberPreference: true
            )
        )
    }

    public static func receiveResolvedCandidate(
        _ current: PlaybackSessionState,
        generation: UInt64,
        result: Result
    ) -> PlaybackSessionTransition {
        guard current.generation == generation,
              current.phase == .resolvingCandidate,
              let intent = current.intent,
              intent.generation == generation else {
            return PlaybackSessionTransition(state: current, failure: .staleSession)
        }
        var state = current
        state.phase = .startingPlayback
        state.autoAdvanceEpisodeURL = nil
        return PlaybackSessionTransition(
            state: state,
            command: .startResolved(intent: intent, result: result)
        )
    }

    public static func finishStarting(
        _ current: PlaybackSessionState,
        generation: UInt64
    ) -> PlaybackSessionState {
        guard current.generation == generation, current.phase == .startingPlayback else {
            return current
        }
        var state = current
        state.phase = .playing
        state.selection = nil
        state.autoAdvanceEpisodeURL = nil
        return state
    }

    public static func fail(
        _ current: PlaybackSessionState,
        generation: UInt64
    ) -> PlaybackSessionState {
        guard current.generation == generation else { return current }
        var state = current
        state.phase = .failed
        state.selection = nil
        return state
    }

    public static func cancel(_ current: PlaybackSessionState) -> PlaybackSessionState {
        var state = current
        state.generation &+= 1
        state.phase = .idle
        state.intent = nil
        state.selection = nil
        state.autoAdvanceEpisodeURL = nil
        return state
    }

    public static func dismissSelection(
        _ current: PlaybackSessionState,
        selectionID: UUID? = nil
    ) -> PlaybackSessionState {
        guard current.phase == .awaitingSelection,
              let selection = current.selection,
              selectionID == nil || selection.id == selectionID else {
            return current
        }
        var state = current
        state.phase = .idle
        state.intent = nil
        state.selection = nil
        return state
    }

    public static func preferredCandidateID(
        in request: PlaybackSelectionRequest,
        signature: String?
    ) -> String? {
        guard let signature else { return nil }
        return request.candidates.first { $0.preferenceSignature == signature }?.id
    }

    public static func preferenceKey(siteKey: String, vodID: String, playFlag: String) -> String {
        [siteKey, vodID, playFlag].joined(separator: "\u{0}")
    }

    public static func episode(
        in episodes: [Episode],
        metadataEpisodeURL: String?,
        fallbackPlaybackURL: String,
        metadataEpisodeName: String?
    ) -> Episode? {
        guard !episodes.isEmpty else { return nil }
        let metadataURL = metadataEpisodeURL?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !metadataURL.isEmpty,
           let exact = episodes.first(where: { $0.url == metadataURL }) {
            return exact
        }
        if metadataURL.isEmpty,
           let exact = episodes.first(where: { $0.url == fallbackPlaybackURL }) {
            return exact
        }

        let metadataName = metadataEpisodeName?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !metadataName.isEmpty else { return nil }
        let matches = episodes.filter { $0.name == metadataName }
        return matches.count == 1 ? matches[0] : nil
    }

    public static func episodeContext(
        episodes: [Episode],
        metadataEpisodeURL: String?,
        fallbackPlaybackURL: String,
        metadataEpisodeName: String?,
        progressText: String?
    ) -> PlaybackEpisodeContext {
        let currentEpisode = episode(
            in: episodes,
            metadataEpisodeURL: metadataEpisodeURL,
            fallbackPlaybackURL: fallbackPlaybackURL,
            metadataEpisodeName: metadataEpisodeName
        )
        let currentIndex = currentEpisode.flatMap { current in
            episodes.firstIndex { $0.url == current.url && $0.name == current.name }
        }
        let previous = currentIndex.flatMap { index in
            index > 0 ? episodes[index - 1] : nil
        }
        let next = currentIndex.flatMap { index in
            index + 1 < episodes.count ? episodes[index + 1] : nil
        }
        return PlaybackEpisodeContext(
            currentEpisode: currentEpisode,
            currentEpisodeURL: metadataEpisodeURL ?? currentEpisode?.url ?? "",
            currentEpisodeName: metadataEpisodeName ?? currentEpisode?.name ?? "",
            currentIndex: currentIndex,
            total: episodes.count,
            previousEpisode: previous,
            nextEpisode: next,
            progressText: progressText
        )
    }

    public static func relativeEpisode(
        in episodes: [Episode],
        context: PlaybackEpisodeContext,
        offset: Int
    ) -> Episode? {
        guard offset != 0, let currentIndex = context.currentIndex else { return nil }
        let targetIndex = currentIndex + offset
        guard episodes.indices.contains(targetIndex) else { return nil }
        return episodes[targetIndex]
    }

    public static func requestAutoAdvance(
        _ current: PlaybackSessionState,
        episodeURL: String,
        context: PlaybackEpisodeContext,
        isLoading: Bool
    ) -> PlaybackAutoAdvanceTransition {
        guard !episodeURL.isEmpty,
              episodeURL == context.currentEpisodeURL,
              current.autoAdvanceEpisodeURL != episodeURL,
              let target = context.nextEpisode,
              !isLoading else {
            return PlaybackAutoAdvanceTransition(state: current)
        }
        var state = current
        state.autoAdvanceEpisodeURL = episodeURL
        return PlaybackAutoAdvanceTransition(state: state, targetEpisode: target)
    }
}
