import Testing
import Models
@testable import NetVplayerApp

@MainActor
@Test func testResetSearchStateClearsKeywordResultsAndLoading() {
    let appState = AppState(loadDefaultConfig: false, startProxyServer: false)
    appState.searchKeyword = "Dune"
    appState.searchResults = [
        SearchResult(
            siteName: "Test Source",
            siteKey: "test",
            vods: [Vod(vodId: "dune-2", vodName: "Dune: Part Two")]
        )
    ]
    appState.isSearching = true

    appState.resetSearchState()

    #expect(appState.searchKeyword.isEmpty)
    #expect(appState.searchResults.isEmpty)
    #expect(appState.isSearching == false)
}
