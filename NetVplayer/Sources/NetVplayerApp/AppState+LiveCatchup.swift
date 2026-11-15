import Foundation
import Models
import LiveEngine
import PlayerEngine
import SpiderEngine

extension AppState {
    var liveArchiveScope: String { liveSourceRevision.uuidString + ":" + liveEpgRevision.uuidString }

    private func ownsXtreamChannel(_ channel: Channel) -> Bool {
        guard let resource = channel.currentUrl.flatMap({ try? XtreamResource($0) }) else { return true }
        guard let account = liveXtreamConfigurations.first(where: { $0.id == resource.accountID }),
              account.url == activeLive?.url,
              let identity = liveXtreamCredentialIdentity(for: account) else { return false }
        return channel.xtreamArchive?.credentialIdentity == identity
    }

    private func ownsXtreamProgramme(_ programme: EpgItem?, channel: Channel) -> Bool {
        guard channel.currentUrl.flatMap({ try? XtreamResource($0) }) != nil else { return true }
        guard ownsXtreamChannel(channel) else { return false }
        return programme?.xtreamArchive.map { $0.scope == liveArchiveScope } ?? true
    }
    var liveCatchupTimeZone: TimeZone? {
        guard let name = activeLive?.timeZone, !name.isEmpty else { return nil }
        return TimeZone(identifier: name)
    }

    func liveCatchupAvailability(channel: Channel, programme: EpgItem?, now: Date = Date(),
                                 revision: UUID? = nil) -> LiveCatchupAvailability {
        guard revision == nil || revision == liveSourceRevision,
              currentCatchupChannel(channel) != nil, ownsXtreamProgramme(programme, channel: channel) else { return .unavailable(.staleSource) }
        return LiveCatchupPolicy.availability(channel: channel, programme: programme, now: now, timeZone: liveCatchupTimeZone)
    }

    private func currentCatchupChannel(_ channel: Channel) -> Channel? {
        let key = LiveCatchupPolicy.channelFingerprint(channel)
        return channelGroups.lazy.flatMap(\.channels).first { LiveCatchupPolicy.channelFingerprint($0) == key }
    }

    func ownsLiveCatchup(_ context: LiveCatchupContext) -> Bool {
        !isTerminating && isLivePlayerPresented && liveCatchupContext == context
            && liveSourceRevision == context.sourceRevision
            && LiveCatchupPolicy.sourceFingerprint(activeLive) == context.sourceFingerprint
            && selectedChannel.map(LiveCatchupPolicy.channelFingerprint) == context.channelFingerprint
              && selectedChannel.map { ownsXtreamProgramme(context.programme, channel: $0) } == true
    }

    private func acceptsLiveCatchupSpec(_ spec: PlaySpec) -> Bool {
        guard let context = spec.liveCatchup, ownsLiveCatchup(context),
              spec.metadata["live.sessionID"] == livePlaybackSessionID.uuidString,
              livePlayerState.currentSpec?.liveCatchup == context else { return false }
        return liveCatchupPhase == .loading || liveCatchupPhase == .playing
    }

    func invalidateLiveCatchupForSourceRefresh() {
        guard liveCatchupContext != nil else { return }
        beginLivePlaybackSession(attempts: [])
        MPVPlayerEngine.live.stop()
        liveCatchupNotice = LiveCatchupUnavailableReason.staleSource.message
    }

    func playLiveCatchup(channel: Channel, programme: EpgItem, revision: UUID? = nil,
                         offset: Double = 0, nativeResume: Bool = false) async {
        guard !isTerminating, !Task.isCancelled, isLivePlayerPresented else { return }
        guard revision == nil || revision == liveSourceRevision, currentCatchupChannel(channel) != nil,
              ownsXtreamProgramme(programme, channel: channel) else {
            liveCatchupNotice = LiveCatchupUnavailableReason.staleSource.message
            return
        }
        let availability = LiveCatchupPolicy.availability(channel: channel, programme: programme,
            timeZone: liveCatchupTimeZone, offset: offset, nativeResume: nativeResume)
        guard case .available(let request) = availability else {
            liveCatchupNotice = availability.message
            return
        }
        beginLivePlaybackSession(attempts: [])
        MPVPlayerEngine.live.stop()
        selectedGroup = sourceGroup(forLiveChannel: channel) ?? selectedGroup
        selectedChannel = channel
        currentChannelUrlIndex = channel.currentUrlIndex
        let context = LiveCatchupContext(sourceFingerprint: LiveCatchupPolicy.sourceFingerprint(activeLive),
            sourceRevision: liveSourceRevision, channelFingerprint: LiveCatchupPolicy.channelFingerprint(channel),
            channelName: channel.name, programme: programme, mediaStartOffset: request.mediaStartOffset,
            supportsRequestSeek: request.supportsRequestSeek)
        liveCatchupContext = context
        liveCatchupPhase = .loading
        liveCatchupPosition = request.mediaStartOffset + (request.initialPosition ?? 0)
        liveError = nil
        livePlayerState.errorMessage = nil
        let sessionID = livePlaybackSessionID
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.liveCatchupContext?.requestID == context.requestID { self.liveCatchupTask = nil }
            }
            await self.prepareLiveCatchup(channel: channel, request: request, context: context, sessionID: sessionID)
        }
        liveCatchupTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if Task.isCancelled, ownsLiveCatchup(context) {
            beginLivePlaybackSession(attempts: [])
            MPVPlayerEngine.live.stop()
        }
    }

    private func prepareLiveCatchup(channel: Channel, request: LiveCatchupRequest,
                                     context: LiveCatchupContext, sessionID: UUID) async {
        let previewHold = livePreviews.beginPlayback()
        defer { livePreviews.endPlayback(previewHold) }
        if livePreviews.activeCount > 0 { await livePreviews.drain() }
        guard !Task.isCancelled, ownsLiveCatchup(context) else { return }
        do {
            var request = request
            if let ref = try? XtreamResource(request.url) {
                guard let account = liveXtreamConfigurations.first(where: { $0.id == ref.accountID }),
                      let provider = await SpiderReplacementRegistry.shared.nativeProvider(for: try account.site()) as? XtreamSiteProvider else {
                    throw LiveCatchupUnavailableReason.staleSource
                }
                guard ownsLiveCatchup(context), !Task.isCancelled else { return }
                request = try await provider.archiveRequest(channel: channel, programme: context.programme,
                    scope: liveArchiveScope, offset: request.mediaStartOffset + (request.initialPosition ?? 0))
                guard request.mediaStartOffset == context.mediaStartOffset else { throw LiveCatchupUnavailableReason.staleSource }
            }
            var spec = try await normalizedLivePlaySpec(channel: channel, url: request.url, logContext: "LIVE_CATCHUP")
            guard !Task.isCancelled, ownsLiveCatchup(context) else { return }
            // A bounded prefix probe is not proof of a valid archive.
            let probe = await livePlaybackProbe.probeArchive(spec: spec)
            guard !Task.isCancelled, ownsLiveCatchup(context) else { return }
            if LiveHLSRelayPolicy.shouldSkipDirectPlaybackForProbe(isPlayable: probe.isPlayable,
                statusCode: probe.statusCode, bodyPrefix: probe.bodyPrefix) {
                setLiveCatchupFailure(context)
                return
            }
            if probe.isPlayable, probe.isHLS {
                spec.format = "hls"
                if let finalURL = probe.finalURL { spec.url = finalURL.absoluteString }
            }
            spec.title = "\(channel.name) · \(context.programme.title)"
            spec.liveCatchup = context
            spec.initialStartPositionSeconds = request.initialPosition
            spec.metadata["playback.kind"] = "live"
            spec.metadata["live.sessionID"] = sessionID.uuidString
            spec.metadata["live.channelName"] = channel.name
            spec.metadata["live.urlIndex"] = String(channel.currentUrlIndex)
            spec = await proxiedPlaySpec(spec, logContext: "LIVE_CATCHUP", livePlayback: true)
            guard !Task.isCancelled, ownsLiveCatchup(context) else { return }
            await play(spec: spec)
            if ownsLiveCatchup(context), liveCatchupPhase == .loading, livePlayerState.errorMessage != nil {
                setLiveCatchupFailure(context)
            }
        } catch {
            guard !Task.isCancelled, ownsLiveCatchup(context) else { return }
            setLiveCatchupFailure(context)
            if let reason = error as? LiveCatchupUnavailableReason { liveError = reason.message }
        }
    }

    var liveCatchupCanSeek: Bool {
        guard let context = liveCatchupContext, liveCatchupPhase == .playing else { return false }
        return context.supportsRequestSeek || (livePlayerState.isSeekable == true && livePlayerState.duration > 0)
    }

    var liveCatchupSeekMessage: String {
        if liveCatchupPhase == .loading { return L10n.text("正在准备回放…") }
        if liveCatchupPhase == .ended { return L10n.text("本节目回放已结束。") }
        if livePlayerState.isSeekable == true, livePlayerState.duration > 0 { return L10n.text("可拖动节目进度") }
        if liveCatchupContext?.supportsRequestSeek == true { return L10n.text("跳转时将重新请求回放") }
        return L10n.text("此回放不支持跳转")
    }

    @discardableResult
    func seekLiveCatchup(to target: Double) async -> LiveCatchupSeekAction {
        guard let context = liveCatchupContext, ownsLiveCatchup(context), liveCatchupPhase == .playing else { return .unsupported }
        let action = LiveCatchupPolicy.seek(context: context, target: target,
            nativeSeekable: livePlayerState.isSeekable, mediaDuration: livePlayerState.duration)
        switch action {
        case .native(let position):
            MPVPlayerEngine.live.seek(to: Int64(position * 1_000))
        case .request(let position):
            guard var channel = selectedChannel else { return .unsupported }
            channel.currentUrlIndex = currentChannelUrlIndex
            await playLiveCatchup(channel: channel, programme: context.programme,
                revision: context.sourceRevision, offset: position)
        case .finish:
            finishLiveCatchup(context)
        case .unsupported:
            liveCatchupNotice = L10n.text("此回放不支持跳转")
        }
        return action
    }

    func retryLiveCatchup(fromBeginning: Bool = false) async {
        guard let context = liveCatchupContext, ownsLiveCatchup(context), var channel = selectedChannel else { return }
        channel.currentUrlIndex = currentChannelUrlIndex
        let offset = fromBeginning || liveCatchupPhase == .ended ? 0 : min(liveCatchupPosition, max(0, context.duration - 1))
        let nativeResume = livePlayerState.isSeekable == true || liveCatchupNativeResume
        await playLiveCatchup(channel: channel, programme: context.programme, revision: context.sourceRevision,
            offset: context.supportsRequestSeek || nativeResume ? offset : 0, nativeResume: nativeResume)
    }

    func changeLiveCatchupLine(_ index: Int) async {
        guard let context = liveCatchupContext, ownsLiveCatchup(context), var channel = selectedChannel,
              channel.urls.indices.contains(index) else { return }
        channel.currentUrlIndex = index
        // A different line has not proved native seek support. Request templates can preserve position.
        await playLiveCatchup(channel: channel, programme: context.programme, revision: context.sourceRevision,
            offset: context.supportsRequestSeek ? min(liveCatchupPosition, max(0, context.duration - 1)) : 0)
    }

    func returnToLiveFromCatchup() async {
        guard let context = liveCatchupContext, ownsLiveCatchup(context),
              var channel = selectedChannel, currentCatchupChannel(channel) != nil else { return }
        channel.currentUrlIndex = currentChannelUrlIndex
        beginLivePlaybackSession(attempts: [])
        await changeChannelUrlIndex(channel.currentUrlIndex)
    }

    func confirmLiveCatchupStarted(spec: PlaySpec) {
        guard acceptsLiveCatchupSpec(spec) else { return }
        liveCatchupPhase = .playing
        liveError = nil
        livePlayerState.errorMessage = nil
    }

    func updateLiveCatchupPosition(spec: PlaySpec, mediaPosition: Double) {
        guard mediaPosition.isFinite, acceptsLiveCatchupSpec(spec), let context = spec.liveCatchup else { return }
        liveCatchupPosition = context.programmePosition(mediaPosition: mediaPosition)
        if liveCatchupPosition >= context.duration { finishLiveCatchup(context) }
    }

    func endLiveCatchup(spec: PlaySpec) {
        guard acceptsLiveCatchupSpec(spec), let context = spec.liveCatchup else { return }
        let position = max(liveCatchupPosition, context.programmePosition(mediaPosition: livePlayerState.position))
        if position >= context.duration - 1 { finishLiveCatchup(context) }
        else { setLiveCatchupFailure(context, premature: true) }
    }

    func failLiveCatchup(spec: PlaySpec) {
        guard acceptsLiveCatchupSpec(spec), let context = spec.liveCatchup else { return }
        setLiveCatchupFailure(context)
    }

    private func setLiveCatchupFailure(_ context: LiveCatchupContext, premature: Bool = false) {
        guard ownsLiveCatchup(context) else { return }
        liveCatchupNativeResume = livePlayerState.isSeekable == true
        liveCatchupPhase = .failed
        liveError = premature ? L10n.text("回放提前结束，可重试或返回直播。") : L10n.text("回放加载失败，可重试或返回直播。")
        // Retire the connection. Context and programme progress remain available for retry.
        MPVPlayerEngine.live.stop()
    }

    private func finishLiveCatchup(_ context: LiveCatchupContext) {
        guard ownsLiveCatchup(context) else { return }
        liveCatchupPhase = .ended
        liveCatchupPosition = context.duration
        liveError = nil
        MPVPlayerEngine.live.stop()
    }
}
