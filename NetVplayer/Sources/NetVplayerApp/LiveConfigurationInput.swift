import Foundation
import ConfigEngine
import LiveEngine
import Models
import Networking

/// A configuration lists sources; a playlist lists channels for one source.
struct LiveConfigurationInput: Sendable {
    let sources: [Live]
    let initialGroups: [ChannelGroup]?

    static func parse(text: String, url: String) throws -> Self {
        if let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
           let array = object["lives"] as? [[String: Any]] {
            let config = LiveConfig()
            config.parse(livesArray: array)
            guard !config.lives.isEmpty else { throw InputError.noSources }
            let sources = config.lives.map { live in
                var live = live
                if !live.url.isEmpty {
                    live.url = URLHelper.resolve(base: url, relative: live.url)
                }
                return live
            }
            return Self(sources: sources, initialGroups: nil)
        }

        let groups = LiveParser.parse(text: text)
        guard groups.contains(where: { !$0.channels.isEmpty }) else { throw InputError.noSources }
        return Self(
            sources: [Live(name: L10n.text("自定义直播"), url: url)],
            initialGroups: groups
        )
    }

    func selectedSource(preferredName: String) -> Live? {
        sources.first(where: { $0.name == preferredName })
            ?? sources.first(where: \.boot)
            ?? sources.first
    }

    enum InputError: Error {
        case noSources
    }
}
