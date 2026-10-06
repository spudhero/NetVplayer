import XCTest
import Testing
import Models

final class TestRuntimeTests: XCTestCase {
    func testRecognizesBothSwiftPMTestEntryPoints() {
        XCTAssertTrue(TestRuntime.detect(arguments: ["/build/NetVplayerPackageTests"], environment: [:]))
        XCTAssertTrue(TestRuntime.detect(arguments: ["/build/runner", "--testing-library", "swift-testing"], environment: [:]))
        XCTAssertTrue(TestRuntime.detect(arguments: ["/build/NetVplayerTests.xctest/Contents/MacOS/tests"], environment: [:]))
    }

    func testRecognizesXcodeConfigurationAndBundleArgument() {
        XCTAssertTrue(TestRuntime.detect(arguments: ["/usr/bin/xctest", "/build/NetVplayerTests.xctest"], environment: [:]))
        XCTAssertTrue(TestRuntime.detect(arguments: ["/build/host"], environment: ["XCTestConfigurationFilePath": "/tmp/fixture"]))
    }

    func testProductionAppAndOrdinaryPathsDoNotEnableTestIsolation() {
        XCTAssertFalse(TestRuntime.detect(arguments: ["/Applications/NetVplayer.app/Contents/MacOS/NetVplayerApp"], environment: [:]))
        XCTAssertFalse(TestRuntime.detect(arguments: ["/source/tests/NetVplayerApp", "https://example.test/video"], environment: [:]))
        XCTAssertFalse(TestRuntime.detect(arguments: [], environment: [:]))
        XCTAssertTrue(TestRuntime.isRunning)
    }
}

@Test func swiftTestingUsesIsolatedRuntimeAndDeterministicLanguage() {
    let runner = URL(fileURLWithPath: ProcessInfo.processInfo.arguments.first ?? "").lastPathComponent
    let arguments = ProcessInfo.processInfo.arguments.map { URL(fileURLWithPath: $0).lastPathComponent }
    #expect(TestRuntime.isRunning, "runner=\(runner) arguments=\(arguments)")
    #expect(L10n.language == "zh-Hans")
    #expect(L10n.text("暮海橙光") == "暮海橙光")
    #expect(L10n.text("设置", language: "zh-Hans") == "设置")
    #expect(L10n.text("设置", language: "zh-hans") == "设置")
    #expect(L10n.text("设置", language: "en") == "Settings")
}
