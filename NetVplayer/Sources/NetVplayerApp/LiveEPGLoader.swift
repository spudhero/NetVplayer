import Foundation
import Models
import LiveEngine
import SpiderEngine

/// A value snapshot of account configuration keeps an old guide request from changing sources.
struct LiveEPGLoader: Sendable {
    var accounts: [XtreamConfiguration]
    var sourceTimeZone = ""
    var scope = UUID().uuidString
    var allowedChannels: Set<String>?
    var repository: XMLTVRepository = .shared

    func load(channel: Channel, window: DateInterval, forceRefresh: Bool) async -> EpgLoadResult {
        guard allowedChannels?.contains(LiveCatchupPolicy.channelFingerprint(channel)) != false,
              window.duration > 0, window.duration <= 86_400 else {
            return EpgLoadResult(data: EpgData(channelName: channel.name), availability: .unavailable)
        }
        if let resource = channel.urls.compactMap({ try? XtreamResource($0) }).first(where: { $0.kind == "live" }) {
            guard let account = accounts.first(where: { $0.id == resource.accountID }),
                  let site = try? account.site(),
                  let provider = await SpiderReplacementRegistry.shared.nativeProvider(for: site) as? XtreamSiteProvider else {
                return EpgLoadResult(data: EpgData(channelName: channel.name), availability: .unavailable, discardsPreviousData: true)
            }
            return await provider.guideEpg(channel: channel, window: window, scope: scope, forceRefresh: forceRefresh)
        }
        let template = channel.epg.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !template.isEmpty else { return EpgLoadResult(data: EpgData(channelName: channel.name), availability: .unconfigured) }
        let channelID = [channel.tvgId, channel.epgName, channel.tvgName, channel.name].first { !$0.isEmpty } ?? channel.name
        // Escape a substituted value as a component, including query delimiters and slashes.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        func encode(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        let url = template.replacingOccurrences(of: "{id}", with: encode(channelID))
            .replacingOccurrences(of: "{name}", with: encode(channel.tvgName.isEmpty ? channel.name : channel.tvgName))
            .replacingOccurrences(of: "{epg}", with: encode(channel.epgName.isEmpty ? channel.name : channel.epgName))
        let hasDate = url.contains("{date}") || url.contains("{date:yyyyMMdd}")
        guard hasDate else {
            return await repository.programmes(url: url, channelID: channelID, channelName: channel.name,
                window: window, forceRefresh: forceRefresh, scope: scope)
        }
        guard let zone = TimeZone(identifier: sourceTimeZone.trimmingCharacters(in: .whitespacesAndNewlines)),
              let dates = try? TVBoxEPGRequest.dates(window: window, timeZone: zone) else {
            return EpgLoadResult(data: EpgData(channelName: channel.name), availability: .unavailable,
                message: L10n.text("日期节目单需要明确的来源时区，请设置直播源 timeZone。"))
        }
        var items: [EpgItem] = [], failed = false, succeeded = false
        // Sequential dates keep the guide's four concurrent row slots a real network bound.
        for date in dates {
            guard !Task.isCancelled else { return EpgLoadResult(data: EpgData(channelName: channel.name), availability: .unavailable) }
            let endpoint = url.replacingOccurrences(of: "{date}", with: date)
                .replacingOccurrences(of: "{date:yyyyMMdd}", with: date.replacingOccurrences(of: "-", with: ""))
            let result = await repository.programmes(url: endpoint, channelID: channelID, channelName: channel.name,
                window: window, forceRefresh: forceRefresh, scope: scope,
                dateRequest: TVBoxEPGRequest(date: date, timeZone: zone, channelID: channelID, channelName: channel.name))
            if result.availability == .unavailable || result.availability == .stale { failed = true }
            if result.availability != .unavailable { succeeded = true }
            // The later source date is authoritative at a cross-midnight boundary.
            let fresh = result.data.items
            items.removeAll { old in fresh.contains { $0.start < old.end && $0.end > old.start } }
            items.append(contentsOf: fresh)
        }
        return EpgLoadResult(data: EpgData(channelName: channel.name, items: Array(items.sorted { $0.start < $1.start }.prefix(128))),
            availability: failed ? (succeeded ? .stale : .unavailable) : (items.isEmpty ? .empty : .available),
            message: failed ? L10n.text("部分日期的节目单未能加载，当前节目覆盖不完整。") : nil)
    }
}
