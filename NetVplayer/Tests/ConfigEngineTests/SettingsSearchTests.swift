import Foundation
import Models
import Storage
import Testing
@testable import NetVplayerApp

@Suite struct SettingsSearchTests {
    @Test func catalogHasUniqueStableDestinationsAndLocalizedPaths() {
        let entries = SettingsSearchIndex.entries
        #expect(Set(entries.map(\.id)) == Set(SettingsSearchTarget.allCases))
        #expect(Set(entries.map(\.id)).count == entries.count)
        #expect(Set(entries.map(\.section)) == Set(SettingsSection.allCases))
        for entry in entries {
            #expect(!entry.title.isEmpty && !entry.path.isEmpty)
            #expect(!L10n.text(entry.titleKey, language: "en").contains(" › "))
            // Every dynamic catalog key must be translated, not merely the literal calls found by the script.
            let english = L10n.text(entry.titleKey, language: "en")
            #expect(!english.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) })
            for key in entry.parents {
                #expect(!L10n.text(key, language: "en").unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) })
            }
        }
        #expect(SettingsSearchTarget.customProxy.rawValue == "customProxy")
        #expect(SettingsSearchIndex.entry(.toneMapping).page == .video)
        #expect(SettingsSearchIndex.entry(.audioDevice).page == .audio)
    }

    @Test(arguments: [
        ("硬解", SettingsSearchTarget.decode), ("hardware decode", .decode), ("HDR", .video),
        ("杜比视界", .dolbyVision), ("Dolby Vision", .dolbyVision), ("audio device", .audioDevice),
        ("字幕位置", .subtitlePosition), ("subtitle position", .subtitlePosition), ("NAS", .files),
        ("SFTP", .files), ("夸克", .quark), ("alipan", .ali), ("BDUSS", .baidu), ("PikPak", .pikpak),
        ("直连", .proxy), ("network custom port", .customProxy), ("cache", .cache), ("检查更新", .update),
        ("English", .language), ("TMDB token", .tmdbCredential), ("source hygiene", .hygiene)
    ]) func bilingualAliasesReachActualDestinations(_ sample: (String, SettingsSearchTarget)) {
        #expect(SettingsSearchIndex.matches(sample.0).contains { $0.id == sample.1 })
    }

    @Test func matchingIsBoundedNormalizedDeterministicAndRequiresAllWords() {
        #expect(SettingsSearchIndex.matches("").isEmpty)
        #expect(SettingsSearchIndex.matches(" \n\t ").isEmpty)
        #expect(SettingsSearchIndex.matches("unknown-no-such-setting").isEmpty)
        #expect(SettingsSearchIndex.matches("ＳＵＢＴＩＴＬＥ POSITION").map(\.id)
            == SettingsSearchIndex.matches("subtitle position").map(\.id))
        #expect(SettingsSearchIndex.matches("audio unknown-no-such-setting").isEmpty)
        #expect(SettingsSearchIndex.matches(String(repeating: "x", count: 10_000)).isEmpty)
        #expect(SettingsSearchIndex.matches("字幕大小").first?.id == .subtitleSize)
        #expect(SettingsSearchIndex.matches("playback subtitle").contains { $0.id == .subtitle })
        #expect(SettingsSearchIndex.matches("proxy").map(\.id) == SettingsSearchIndex.matches("proxy").map(\.id))
    }

    @Test func conditionalEntriesStayDiscoverableAndExplainTheirPrerequisites() {
        var context = SettingsSearchContext()
        for target: SettingsSearchTarget in [.customProxy, .danmakuOpacity, .danmakuSize, .danmakuOffset,
                                             .webHomeURL, .compatibility, .searchScope, .liveQuality] {
            #expect(context.reason(for: target) != nil)
            #expect(SettingsSearchIndex.entries.contains { $0.id == target })
        }
        #expect(context.anchor(for: .compatibility) == .diagnostics)
        context.customProxy = true; context.danmakuEnabled = true; context.webHomeEnabled = true
        context.hasExternalReports = true; context.hasSearchSites = true; context.hasLiveChannels = true
        for target: SettingsSearchTarget in [.customProxy, .danmakuOpacity, .danmakuSize, .danmakuOffset,
                                             .webHomeURL, .compatibility, .searchScope, .liveQuality] {
            #expect(context.reason(for: target) == nil)
            #expect(context.anchor(for: target) == target)
        }
        context.pcmControlsAvailable = false
        #expect(context.reason(for: .audioChannels) != nil && context.reason(for: .audioRate) != nil)
        context.pcmControlsAvailable = true
        #expect(context.reason(for: .audioChannels) == nil && context.reason(for: .audioRate) == nil)
    }

    @MainActor @Test func navigationNeverWritesPreferencesAndReselectingRenewsHighlight() throws {
        let suite = "settings-search-tests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(1, forKey: "proxyMode")
        defaults.set(false, forKey: "danmakuEnabled")
        defaults.set("retained", forKey: "fixture")
        let before = defaults.dictionaryRepresentation() as NSDictionary
        let navigation = SettingsSearchNavigation()
        for target in SettingsSearchTarget.allCases {
            navigation.reveal(target)
            let entry = SettingsSearchIndex.entry(target)
            #expect(navigation.section == entry.section && navigation.page == entry.page)
            #expect(navigation.target == target && navigation.isHighlighted)
        }
        navigation.reveal(.toneMapping)
        let old = navigation.requestID
        navigation.reveal(.toneMapping)
        #expect(navigation.requestID != old)
        navigation.expireHighlight(request: old)
        #expect(navigation.isHighlighted)
        navigation.expireHighlight(request: navigation.requestID)
        #expect(!navigation.isHighlighted && navigation.target == .toneMapping)
        navigation.select(section: .network)
        #expect(navigation.target == nil && navigation.page == .general && !navigation.isHighlighted)
        #expect(before == defaults.dictionaryRepresentation() as NSDictionary)
    }
}
