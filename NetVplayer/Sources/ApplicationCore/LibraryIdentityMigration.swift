import Foundation
import Models

public enum LibraryIdentityMigration {
    /// Unbound records can migrate automatically only when exactly one saved VOD configuration exists.
    public static func migrate(_ state: ApplicationLibraryState, configuration: Config, sites: [Site]) -> ApplicationLibraryState {
        guard configuration.id > 0 else { return state }
        let onlyConfiguration = state.configs.filter { $0.type == .vod }.count == 1
        func eligible(_ id: Int) -> Bool { id == configuration.id || (id == 0 && onlyConfiguration) }
        var result = state
        result.history = state.history.map { record in
            guard record.sourceFingerprint.isEmpty, eligible(record.configId),
                  let site = sites.first(where: { $0.key == record.siteKey }) else { return record }
            return bind(record, configuration: configuration, site: site)
        }
        result.keeps = state.keeps.map { record in
            guard record.type == .vod, record.sourceFingerprint.isEmpty, eligible(record.configId),
                  let identity = LibrarySourceIdentity.legacyIdentity(key: record.key, sites: sites),
                  let site = sites.first(where: { $0.key == identity.siteKey }) else { return record }
            return bind(record, vodID: identity.vodID, configuration: configuration, site: site)
        }
        // A migrated legacy duplicate must not overwrite a newer explicitly bound record.
        var historyKeys = Set<String>()
        result.history = result.history.sorted { $0.createTime > $1.createTime }.filter { historyKeys.insert($0.key).inserted }
        var keepKeys = Set<String>()
        result.keeps = result.keeps.sorted { $0.createTime > $1.createTime }.filter { keepKeys.insert("\($0.type.rawValue):\($0.key)").inserted }
        return result
    }

    public static func bind(_ record: History, configuration: Config, site: Site) -> History {
        var result = record
        result.configId = configuration.id
        result.sourceFingerprint = LibrarySourceIdentity.fingerprint(configurationURL: configuration.url, site: site)
        result.key = LibrarySourceIdentity.key(source: result.sourceFingerprint, siteKey: site.key, vodID: record.vodId)
        return result
    }

    public static func bind(_ record: Keep, vodID: String, configuration: Config, site: Site) -> Keep {
        var result = record
        result.configId = configuration.id
        result.sourceFingerprint = LibrarySourceIdentity.fingerprint(configurationURL: configuration.url, site: site)
        result.key = LibrarySourceIdentity.key(source: result.sourceFingerprint, siteKey: site.key, vodID: vodID)
        return result
    }
}
