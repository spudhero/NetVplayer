import Foundation
import Models
import LiveEngine
import SpiderEngine

/// A value snapshot of account configuration keeps an old guide request from changing sources.
struct LiveEPGLoader: Sendable {
    var accounts: [XtreamConfiguration]

    func load(channel: Channel, window: DateInterval, forceRefresh: Bool) async -> EpgLoadResult {
        if let resource = channel.urls.compactMap({ try? XtreamResource($0) }).first(where: { $0.kind == "live" }) {
            guard let account = accounts.first(where: { $0.id == resource.accountID }),
                  let site = try? account.site(),
                  let provider = await SpiderReplacementRegistry.shared.nativeProvider(for: site) as? XtreamSiteProvider else {
                return EpgLoadResult(data: EpgData(channelName: channel.name), availability: .unavailable)
            }
            var result = await provider.shortEpgResult(streamID: resource.streamID, forceRefresh: forceRefresh)
            result.data.channelName = channel.name
            result.data.items = result.data.items.filter { $0.start < window.end && $0.end > window.start }
            if result.availability == .available, result.data.items.isEmpty { result.availability = .empty }
            return result
        }
        let template = channel.epg.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !template.isEmpty else { return EpgLoadResult(data: EpgData(channelName: channel.name), availability: .unconfigured) }
        let channelID = [channel.tvgId, channel.epgName, channel.tvgName, channel.name].first { !$0.isEmpty } ?? channel.name
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd"
        // Escape a substituted value as a component, including query delimiters and slashes.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encoded = channelID.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        let url = template.replacingOccurrences(of: "{id}", with: encoded)
            .replacingOccurrences(of: "{name}", with: encoded)
            .replacingOccurrences(of: "{date}", with: formatter.string(from: window.start))
        return await XMLTVRepository.shared.programmes(url: url, channelID: channelID, channelName: channel.name,
                                                       window: window, forceRefresh: forceRefresh)
    }
}
