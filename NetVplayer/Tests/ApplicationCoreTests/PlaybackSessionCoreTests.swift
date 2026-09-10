import ApplicationCore
import Models
import Testing

@Suite("Application core playback session")
struct PlaybackSessionCoreTests {
    private let site = Site(key: "site", name: "Site", type: 3)
    private let episode = Episode(name: "E1", url: "episode-1")

    @Test func directResultStartsWithoutCandidateSelection() {
        let initial = PlaybackSessionState(autoAdvanceEpisodeURL: "episode-0")
        let loading = PlaybackSessionCore.beginEpisode(
            initial,
            site: site,
            episode: episode,
            resumePosition: 120,
            preferenceKey: "preference"
        )

        #expect(loading.phase == .loadingSource)
        #expect(loading.autoAdvanceEpisodeURL == nil)
        #expect(loading.intent?.resumePosition == 120)
        let transition = PlaybackSessionCore.receivePlayerResult(
            loading,
            generation: loading.generation,
            result: Result(url: "https://media.example.test/video.mp4"),
            preferredSignature: nil
        )

        #expect(transition.state.phase == .startingPlayback)
        switch transition.command {
        case let .startResolved(intent, result):
            #expect(intent.episode.url == episode.url)
            #expect(intent.preferenceKey == "preference")
            #expect(result.url.hasSuffix("video.mp4"))
        default:
            Issue.record("Expected a resolved playback command")
        }
    }

    @Test func manualMultipleCandidatesWaitAndKeepUnavailableReasons() {
        let playableA = candidate(id: "a", provider: "addon-a", group: "group-a")
        let playableB = candidate(id: "b", provider: "addon-b", group: "group-b")
        let disabled = PlaybackCandidate(
            id: "torrent",
            providerKey: "addon-c",
            providerName: "Addon C",
            kind: .torrent,
            status: .unsupported,
            unavailableReason: "Torrent unavailable"
        )
        let loading = PlaybackSessionCore.beginEpisode(
            PlaybackSessionState(),
            site: site,
            episode: episode,
            preferenceKey: "preference"
        )
        let transition = PlaybackSessionCore.receivePlayerResult(
            loading,
            generation: loading.generation,
            result: Result(playbackCandidates: [playableA, disabled, playableB]),
            preferredSignature: playableB.preferenceSignature
        )

        #expect(transition.state.phase == .awaitingSelection)
        #expect(transition.state.selection?.candidates.map(\.id) == ["a", "torrent", "b"])
        #expect(transition.state.selection?.preferenceKey == "preference")
        #expect(transition.state.selection?.isAutomatic == false)
        if let request = transition.state.selection {
            #expect(PlaybackSessionCore.preferredCandidateID(
                in: request,
                signature: playableB.preferenceSignature
            ) == "b")
        } else {
            Issue.record("Expected a playback selection")
        }
    }

    @Test func automaticSelectionUsesPreferenceWhileSinglePlayableAlwaysContinues() {
        let playableA = candidate(id: "a", provider: "addon-a", group: "group-a")
        let playableB = candidate(id: "b", provider: "addon-b", group: "group-b")
        let loading = PlaybackSessionCore.beginEpisode(
            PlaybackSessionState(autoAdvanceEpisodeURL: "episode-0"),
            site: site,
            episode: episode,
            automaticSelection: true
        )
        #expect(loading.autoAdvanceEpisodeURL == "episode-0")
        let preferred = PlaybackSessionCore.receivePlayerResult(
            loading,
            generation: loading.generation,
            result: Result(playbackCandidates: [playableA, playableB]),
            preferredSignature: playableB.preferenceSignature
        )
        switch preferred.command {
        case let .resolveCandidate(_, candidate, rememberPreference):
            #expect(candidate.id == "b")
            #expect(!rememberPreference)
        default:
            Issue.record("Expected automatic preferred candidate resolution")
        }

        let singleLoading = PlaybackSessionCore.beginEpisode(
            PlaybackSessionState(),
            site: site,
            episode: episode,
            automaticSelection: true
        )
        let single = PlaybackSessionCore.receivePlayerResult(
            singleLoading,
            generation: singleLoading.generation,
            result: Result(playbackCandidates: [playableA]),
            preferredSignature: nil
        )
        switch single.command {
        case let .resolveCandidate(_, candidate, _):
            #expect(candidate.id == "a")
        default:
            Issue.record("Expected the only playable candidate to continue")
        }
    }

    @Test func candidateSelectionUsesCanonicalCandidateAndRejectsUnavailableChoice() {
        let playable = candidate(id: "playable", provider: "addon", group: "group")
        let unavailable = PlaybackCandidate(
            id: "disabled",
            providerKey: "addon",
            providerName: "Addon",
            kind: .externalURL,
            status: .unsupported,
            unavailableReason: "External URL unavailable"
        )
        let alternate = candidate(id: "alternate", provider: "other-addon", group: "other-group")
        let waiting = waitingState(candidates: [playable, alternate, unavailable])
        let request = waiting.selection!

        let rejected = PlaybackSessionCore.selectCandidate(
            waiting,
            selectionID: request.id,
            candidateID: unavailable.id
        )
        #expect(rejected.failure == .unavailableCandidate)
        #expect(rejected.state.selection?.id == request.id)

        let selected = PlaybackSessionCore.selectCandidate(
            waiting,
            selectionID: request.id,
            candidateID: playable.id
        )
        #expect(selected.failure == nil)
        #expect(selected.state.phase == .resolvingCandidate)
        #expect(selected.state.selection == nil)
        switch selected.command {
        case let .resolveCandidate(commandRequest, commandCandidate, rememberPreference):
            #expect(commandRequest.id == request.id)
            #expect(commandCandidate.url == playable.url)
            #expect(rememberPreference)
        default:
            Issue.record("Expected a candidate resolution command")
        }
    }

    @Test func staleResultsAndResolvedCandidatesCannotReplaceNewSession() {
        let first = PlaybackSessionCore.beginEpisode(
            PlaybackSessionState(),
            site: site,
            episode: episode
        )
        let second = PlaybackSessionCore.beginEpisode(
            first,
            site: site,
            episode: Episode(name: "E2", url: "episode-2")
        )
        let staleResult = PlaybackSessionCore.receivePlayerResult(
            second,
            generation: first.generation,
            result: Result(url: "https://stale.example.test/video.mp4"),
            preferredSignature: nil
        )
        #expect(staleResult.failure == .staleSession)
        #expect(staleResult.state.intent?.episode.url == "episode-2")

        let cancelled = PlaybackSessionCore.cancel(second)
        let staleResolved = PlaybackSessionCore.receiveResolvedCandidate(
            cancelled,
            generation: second.generation,
            result: Result(url: "https://stale.example.test/resolved.mp4")
        )
        #expect(staleResolved.failure == .staleSession)
        #expect(staleResolved.state.phase == .idle)
        #expect(staleResolved.state.selection == nil)
    }

    @Test func episodeMatchingAndRelativeNavigationPreserveServerOrder() {
        let episodes = [
            Episode(name: "Pilot", url: "line-a-1"),
            Episode(name: "Episode 2", url: "line-a-2"),
            Episode(name: "Finale", url: "line-a-3")
        ]
        #expect(PlaybackSessionCore.episode(
            in: episodes,
            metadataEpisodeURL: "line-a-2",
            fallbackPlaybackURL: "stream-url",
            metadataEpisodeName: nil
        )?.name == "Episode 2")
        #expect(PlaybackSessionCore.episode(
            in: episodes,
            metadataEpisodeURL: "",
            fallbackPlaybackURL: "line-a-1",
            metadataEpisodeName: nil
        )?.name == "Pilot")
        #expect(PlaybackSessionCore.episode(
            in: episodes,
            metadataEpisodeURL: "missing",
            fallbackPlaybackURL: "stream-url",
            metadataEpisodeName: "Finale"
        )?.url == "line-a-3")

        let context = PlaybackSessionCore.episodeContext(
            episodes: episodes,
            metadataEpisodeURL: "line-a-2",
            fallbackPlaybackURL: "stream-url",
            metadataEpisodeName: "Episode 2",
            progressText: "Watched"
        )
        #expect(context.currentIndex == 1)
        #expect(context.previousEpisode?.url == "line-a-1")
        #expect(context.nextEpisode?.url == "line-a-3")
        #expect(PlaybackSessionCore.relativeEpisode(in: episodes, context: context, offset: -1)?.url == "line-a-1")
        #expect(PlaybackSessionCore.relativeEpisode(in: episodes, context: context, offset: 1)?.url == "line-a-3")
        #expect(PlaybackSessionCore.relativeEpisode(in: episodes, context: context, offset: 2) == nil)
    }

    @Test func ambiguousEpisodeNameDoesNotSelectAcrossFlags() {
        let episodes = [
            Episode(name: "Episode 1", url: "line-a"),
            Episode(name: "Episode 1", url: "line-b")
        ]
        #expect(PlaybackSessionCore.episode(
            in: episodes,
            metadataEpisodeURL: "missing",
            fallbackPlaybackURL: "stream-url",
            metadataEpisodeName: "Episode 1"
        ) == nil)
    }

    @Test func autoAdvanceIsReservedOnceAndClearedWhenPlaybackStarts() {
        let episodes = [
            Episode(name: "E1", url: "episode-1"),
            Episode(name: "E2", url: "episode-2")
        ]
        let context = PlaybackSessionCore.episodeContext(
            episodes: episodes,
            metadataEpisodeURL: "episode-1",
            fallbackPlaybackURL: "stream-url",
            metadataEpisodeName: "E1",
            progressText: nil
        )
        let first = PlaybackSessionCore.requestAutoAdvance(
            PlaybackSessionState(phase: .playing),
            episodeURL: "episode-1",
            context: context,
            isLoading: false
        )
        #expect(first.targetEpisode?.url == "episode-2")
        #expect(first.state.autoAdvanceEpisodeURL == "episode-1")

        let duplicate = PlaybackSessionCore.requestAutoAdvance(
            first.state,
            episodeURL: "episode-1",
            context: context,
            isLoading: false
        )
        #expect(duplicate.targetEpisode == nil)

        let loading = PlaybackSessionCore.beginEpisode(
            first.state,
            site: site,
            episode: episodes[1],
            automaticSelection: true
        )
        #expect(loading.autoAdvanceEpisodeURL == "episode-1")
        let starting = PlaybackSessionCore.receivePlayerResult(
            loading,
            generation: loading.generation,
            result: Result(url: "https://media.example.test/e2.mp4"),
            preferredSignature: nil
        )
        #expect(starting.state.autoAdvanceEpisodeURL == nil)
        let playing = PlaybackSessionCore.finishStarting(
            starting.state,
            generation: loading.generation
        )
        #expect(playing.phase == .playing)
    }

    private func candidate(id: String, provider: String, group: String) -> PlaybackCandidate {
        PlaybackCandidate(
            id: id,
            providerKey: provider,
            providerName: provider,
            kind: .directURL,
            status: .playable,
            url: "https://media.example.test/\(id).mp4",
            bingeGroup: group
        )
    }

    private func waitingState(candidates: [PlaybackCandidate]) -> PlaybackSessionState {
        let loading = PlaybackSessionCore.beginEpisode(
            PlaybackSessionState(),
            site: site,
            episode: episode,
            preferenceKey: "preference"
        )
        return PlaybackSessionCore.receivePlayerResult(
            loading,
            generation: loading.generation,
            result: Result(playbackCandidates: candidates),
            preferredSignature: nil
        ).state
    }
}
