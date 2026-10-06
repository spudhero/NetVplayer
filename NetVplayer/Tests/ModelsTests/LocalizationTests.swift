import XCTest
@testable import Models

final class LocalizationTests: XCTestCase {
    func testInstalledAppFindsLocalizedResourcesWithoutBuildDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Fixture.app")
        let contents = app.appendingPathComponent("Contents")
        let resources = contents.appendingPathComponent("Resources/NetVplayer_Models.bundle")
        let english = resources.appendingPathComponent("en.lproj")
        try FileManager.default.createDirectory(at: english, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "test.netvplayer.localization", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try "\"probe\" = \"Packaged translation\";".write(
            to: english.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8
        )
        let applicationBundle = try XCTUnwrap(Bundle(url: app))
        let packaged = try XCTUnwrap(L10n.packagedResourceBundle(in: applicationBundle))
        XCTAssertEqual(packaged.bundleURL.standardizedFileURL, resources.standardizedFileURL)
        let localized = try XCTUnwrap(Bundle(path: try XCTUnwrap(packaged.path(forResource: "en", ofType: "lproj"))))
        XCTAssertEqual(localized.localizedString(forKey: "probe", value: nil, table: "Localizable"), "Packaged translation")
    }

    func testLanguageResolutionAndStableIDs() {
        XCTAssertEqual(L10n.resolvedLanguage(mode: "system", preferred: ["zh-CN", "en"]), "zh-Hans")
        XCTAssertEqual(L10n.resolvedLanguage(mode: "system", preferred: ["fr", "zh-CN"]), "en")
        XCTAssertEqual(L10n.resolvedLanguage(mode: "en", preferred: ["zh-CN"]), "en")
        XCTAssertEqual(L10n.resolvedLanguage(mode: "zh-Hans", preferred: ["en"]), "zh-Hans")
        XCTAssertEqual(DriveProvider.quark.rawValue, "quark")
        XCTAssertEqual(DriveProvider.quark.displayName, "夸克网盘")
        XCTAssertEqual(DriveProvider.quark.localizedDisplayName(language: "en"), "Quark Drive")
        let history = History(vodFlag: DriveProvider.quark.displayName)
        XCTAssertEqual(history.vodFlag, "夸克网盘", "Persisted route identity must not change with UI language")
        let season = PlaybackFlagPresentation.xtreamSeasonID("2")
        XCTAssertEqual(season, "xtream-season:2")
        XCTAssertEqual(PlaybackFlagPresentation.title(season, language: "zh-Hans"), "第 2 季")
        XCTAssertEqual(PlaybackFlagPresentation.title(season, language: "en"), "Season 2")
    }
    func testBothBundlesAndReorderedArguments() {
        XCTAssertEqual(L10n.text("设置", language: "en"), "Settings")
        XCTAssertEqual(L10n.text("设置", language: "zh-Hans"), "设置")
        XCTAssertEqual(L10n.text("{0} 个频道", ["1"], language: "en"), "Channels: 1")
        let text = L10n.text("频道“{0}”的线路 {1} 不可用。请切换线路或直播源。", ["{1}", "2"], language: "en")
        XCTAssertTrue(text.contains("Route 2"))
        XCTAssertTrue(text.contains("“{1}”"), "Provider arguments must not be translated or interpolated again")
        XCTAssertEqual(L10n.text("A provider-supplied title", language: "en"), "A provider-supplied title")
    }
    func testXtreamPathCredentialsAreRedacted() {
        let redacted = XtreamLogRedaction.redact("open https://fixture.example/base/movie/user-fixture/password-fixture/3.mp4")
        XCTAssertFalse(redacted.contains("user-fixture"))
        XCTAssertFalse(redacted.contains("password-fixture"))
        XCTAssertTrue(redacted.contains("/3.mp4"))
        for kind in ["movie", "series", "live"] {
            let nested = XtreamLogRedaction.redact(
                "https://fixture.example/\(kind)/catalog/\(kind)/user-fixture/password-fixture/3.mp4"
            )
            XCTAssertFalse(nested.contains("user-fixture"))
            XCTAssertFalse(nested.contains("password-fixture"))
            XCTAssertTrue(nested.contains("/\(kind)/catalog/\(kind)/<account>/<secret>/3.mp4"))
        }
    }
}
