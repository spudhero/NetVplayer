import Foundation
import Testing
import QuickJSRuntime

private func makeQuickJSExecutable(at url: URL, bytes: Data = Data("#!/bin/sh\nexit 0\n".utf8)) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try bytes.write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

@Test func quickJSRuntimeLocatorPrefersConfiguredThenBundled() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("NetVplayer-QuickJSLocator-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let resources = root.appendingPathComponent("Resources", isDirectory: true)
    let bundled = resources.appendingPathComponent("QuickJSRuntime/bin/qjs")
    let configured = root.appendingPathComponent("configured-qjs")
    try makeQuickJSExecutable(at: bundled, bytes: Data([0x4D, 0x5A, 0x71, 0x46, 0x70, 0x44, 0x3D, 0x27]))
    try makeQuickJSExecutable(at: configured)

    let override = try #require(QuickJSRuntimeLocator.locate(
        environment: ["NETVPLAYER_QUICKJS_PATH": configured.path],
        bundleResourceURL: resources
    ))
    #expect(override.runtimeURL == configured)
    #expect(override.executableURL == configured)
    #expect(override.commandArguments(["-e", "1"]) == ["-e", "1"])

    let packaged = try #require(QuickJSRuntimeLocator.locate(
        environment: [:],
        bundleResourceURL: resources
    ))
    #expect(packaged.runtimeURL == bundled)
    #expect(packaged.executableURL.path == "/bin/sh")
    #expect(packaged.commandArguments(["-e", "1"]) == [bundled.path, "-e", "1"])
    #expect(packaged.source == .bundled)
}

@Test func quickJSRuntimeLocatorFallsBackToHostPATH() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("NetVplayer-QuickJSPath-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let qjs = root.appendingPathComponent("bin/qjs")
    try makeQuickJSExecutable(at: qjs)
    let location = try #require(QuickJSRuntimeLocator.locate(
        environment: ["PATH": qjs.deletingLastPathComponent().path],
        bundleResourceURL: root.appendingPathComponent("MissingResources")
    ))
    #expect(location.runtimeURL == qjs)
    #expect(location.source == .host)
}
