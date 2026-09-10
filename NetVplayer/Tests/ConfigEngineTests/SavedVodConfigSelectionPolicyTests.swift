import Testing
@testable import NetVplayerApp

@Test func savedVodConfigSelectionRestoresTheActiveConfigAfterViewReentry() {
    let savedURLs = [
        "https://first.example/config.json",
        "https://active.example/config.json"
    ]

    let selection = SavedVodConfigSelectionPolicy.resolvedSelection(
        savedURLs: savedURLs,
        activeURL: "https://active.example/config.json"
    )

    #expect(selection == "https://active.example/config.json")
}

@Test func savedVodConfigSelectionReturnsTheStoredTagWhenActiveURLHasWhitespace() {
    let savedURL = "https://active.example/config.json"

    let selection = SavedVodConfigSelectionPolicy.resolvedSelection(
        savedURLs: [savedURL],
        activeURL: "  \(savedURL)\n"
    )

    #expect(selection == savedURL)
}

@Test func savedVodConfigSelectionFallsBackToFirstSavedConfig() {
    let selection = SavedVodConfigSelectionPolicy.resolvedSelection(
        savedURLs: ["https://first.example/config.json", "https://second.example/config.json"],
        activeURL: "https://missing.example/config.json"
    )

    #expect(selection == "https://first.example/config.json")
}

@Test func savedVodConfigSelectionIsEmptyWithoutSavedConfigs() {
    #expect(SavedVodConfigSelectionPolicy.resolvedSelection(
        savedURLs: [],
        activeURL: "https://active.example/config.json"
    ).isEmpty)
}
