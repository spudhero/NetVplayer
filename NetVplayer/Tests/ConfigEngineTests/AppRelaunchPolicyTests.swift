import XCTest
@testable import NetVplayerApp

final class AppRelaunchPolicyTests: XCTestCase {
    func testRelaunchWaitsForParentAndPassesBundlePathAsData() throws {
        let app = FileManager.default.temporaryDirectory
            .appendingPathComponent("Relaunch Test \(UUID().uuidString) $(touch injected).app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: app) }
        let command = try AppRelaunchPolicy.command(parentPID: 42, appURL: app)
        XCTAssertEqual(command.0.path, "/bin/sh")
        XCTAssertEqual(command.1[3], "42")
        XCTAssertEqual(command.1[4], app.path)
        XCTAssertFalse(command.1[1].contains(app.path))
        XCTAssertTrue(command.1[1].contains("kill -0"))
        XCTAssertTrue(command.1[1].contains("/usr/bin/open -n"))
    }

    func testRelaunchRejectsNonAppLocations() {
        XCTAssertThrowsError(try AppRelaunchPolicy.command(parentPID: 42, appURL: URL(fileURLWithPath: "/tmp/not-an-app")))
    }
}
