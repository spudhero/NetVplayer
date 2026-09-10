import AppKit
import Testing
@testable import NetVplayerApp

struct EpisodeDisplayModeTests {
    @Test
    func displayModesExposeAvailableSystemSymbols() {
        #expect(EpisodeDisplayMode.grid.title == "宫格")
        #expect(EpisodeDisplayMode.list.title == "列表")
        #expect(EpisodeDisplayMode.grid.systemImage == "square.grid.2x2")
        #expect(EpisodeDisplayMode.list.systemImage == "list.bullet")
        #expect(NSImage(systemSymbolName: EpisodeDisplayMode.grid.systemImage, accessibilityDescription: nil) != nil)
        #expect(NSImage(systemSymbolName: EpisodeDisplayMode.list.systemImage, accessibilityDescription: nil) != nil)
    }

    @Test
    func sortOrdersExposeAvailableSystemSymbolsAndReorderValues() {
        #expect(EpisodeSortOrder.ascending.title == "正序")
        #expect(EpisodeSortOrder.descending.title == "倒序")
        #expect(NSImage(systemSymbolName: EpisodeSortOrder.ascending.systemImage, accessibilityDescription: nil) != nil)
        #expect(NSImage(systemSymbolName: EpisodeSortOrder.descending.systemImage, accessibilityDescription: nil) != nil)
        #expect(EpisodeSortOrder.ascending.next == .descending)
        #expect(EpisodeSortOrder.descending.next == .ascending)

        let source = ["01", "02", "03"]
        #expect(EpisodeSortOrder.ascending.ordered(source) == ["01", "02", "03"])
        #expect(EpisodeSortOrder.descending.ordered(source) == ["03", "02", "01"])
    }

    @Test @MainActor
    func displayModeIsSharedForOneAppSessionAndDefaultsToGrid() {
        let appState = AppState(loadDefaultConfig: false, startProxyServer: false)

        #expect(appState.episodeDisplayMode == .grid)
        appState.episodeDisplayMode = .list
        #expect(appState.episodeDisplayMode == .list)

        let nextSession = AppState(loadDefaultConfig: false, startProxyServer: false)
        #expect(nextSession.episodeDisplayMode == .grid)
    }
}
