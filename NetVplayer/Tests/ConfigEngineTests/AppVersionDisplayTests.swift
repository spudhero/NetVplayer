import Testing
@testable import NetVplayerApp

@Suite("App version display")
struct AppVersionDisplayTests {
    @Test func formatsReleaseVersionFromBundleMetadata() {
        #expect(AppVersionDisplay.label(info: ["CFBundleShortVersionString": "1.0.0"]) == "v1.0.0")
        #expect(AppVersionDisplay.label(info: ["CFBundleShortVersionString": " v1.0.0 "]) == "v1.0.0")
    }

    @Test func usesAnExplicitDevelopmentFallback() {
        #expect(AppVersionDisplay.label(info: [:]) == "开发构建")
        #expect(AppVersionDisplay.label(info: ["CFBundleShortVersionString": "  "]) == "开发构建")
    }
}
