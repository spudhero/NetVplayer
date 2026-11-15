import Foundation
import LiveEngine
import Models
import SpiderEngine

extension AppState {
    var livePreviewIdentity: String {
        let credential = liveXtreamConfigurations.first(where: { $0.url == activeLive?.url })
            .flatMap { liveXtreamCredentialIdentity(for: $0) } ?? ""
        return LiveCatchupPolicy.sourceFingerprint(activeLive) + ":" + liveSourceRevision.uuidString + ":" + credential
    }

    func refreshLivePreviews() {
        let identity = livePreviewIdentity
        livePreviews.setSource(identity)
        livePreviews.refresh { [weak self] channel in
            guard let self, !self.isTerminating, self.livePreviewIdentity == identity else { throw CancellationError() }
            var channel = channel; channel.currentUrlIndex = 0
            guard let url = channel.currentUrl, channel.drm == nil else { throw LivePreviewError.unsupported }
            let key = LiveCatchupPolicy.channelFingerprint(channel)
            guard self.channelGroups.lazy.flatMap(\.channels).contains(where: {
                LiveCatchupPolicy.channelFingerprint($0) == key
            }) else { throw CancellationError() }
            if url.hasPrefix("xtr1.") {
                let resource = try XtreamResource(url)
                guard resource.kind == "live",
                      let account = self.liveXtreamConfigurations.first(where: { $0.id == resource.accountID }),
                      account.url == self.activeLive?.url,
                      let provider = await SpiderReplacementRegistry.shared.nativeProvider(for: try account.site()) as? XtreamSiteProvider
                else { throw LivePreviewError.unsupported }
                let spec = try await provider.livePreviewSpec(channel: channel)
                guard self.livePreviewIdentity == identity else { throw CancellationError() }
                return spec
            }
            // A preview must not invoke browser sniffing, click scripts or a second
            // provider playback session. Unsupported channels keep their normal play path.
            // Plain playlists have no account quota evidence. Do not risk taking
            // a primary player's connection, even when its buffer is currently full.
            guard self.playerState.currentSpec == nil, self.livePlayerState.currentSpec == nil
            else { throw LivePreviewError.connectionLimit }
            guard channel.parseFlag != 1, channel.clickScript.isEmpty,
                  let parts = URLComponents(string: url), ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
                  parts.host?.isEmpty == false, !url.contains(where: { $0.isWhitespace || $0 == "\0" })
            else { throw LivePreviewError.unsupported }
            return PlaySpec(url: url, headers: channel.requestHeaders, format: channel.format, title: channel.name)
        }
    }
}
