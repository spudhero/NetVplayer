import CryptoKit
import Darwin
import Foundation
import Models
import ProviderSDK
import SpiderEngine
import Testing
@testable import ProviderRuntime

@Test func sandboxAuditStateAcceptsOnlyFreshScopedSessionsAndRejectsSymlinks() async throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("sandbox-audit-path-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temporary) }
    let support = temporary.appendingPathComponent("Application Support")
    let installed = support.appendingPathComponent("NetVplayer/Providers")
    let key = Curve25519.Signing.PrivateKey()
    let verifier = try ProviderManifestVerifier(publicKeyData: key.publicKey.rawRepresentation, shellVersion: "1.1.4")
    let first = ProviderPackageStore(rootURL: installed, verifier: verifier,
        stateDirectoryRootURL: temporary.appendingPathComponent("audit-output/provider-state"))
    let second = ProviderPackageStore(rootURL: installed, verifier: verifier,
        stateDirectoryRootURL: temporary.appendingPathComponent("audit-output/provider-state"))
    let providerID = "fixture.sandbox-state"
    let state = try await first.stateDirectory(providerID: providerID, sandboxed: true)
    let other = try await second.stateDirectory(providerID: providerID, sandboxed: true)
    let ordinary = installed.appendingPathComponent(".state/\(providerID)")
    #expect(state != ordinary)
    #expect(state != other)
    #expect(state.deletingLastPathComponent() == ordinary.appendingPathComponent(".audit", isDirectory: true))
    try ProviderSandboxVerifier.verifyStateDirectory(state, providerID: providerID, applicationSupport: support)
    try ProviderSandboxVerifier.verifyStateDirectory(ordinary, providerID: providerID, applicationSupport: support)
    for invalid in [temporary.appendingPathComponent("audit-output/provider-state/\(providerID)"),
                    ordinary.appendingPathComponent(".audit/not-a-session"),
                    ordinary.appendingPathComponent(".audit/\(UUID().uuidString)/nested")] {
        #expect(throws: ProviderSandboxVerificationError.invalidStateLocation(invalid.path)) {
            try ProviderSandboxVerifier.verifyStateDirectory(invalid, providerID: providerID, applicationSupport: support)
        }
    }
    let alias = ordinary.appendingPathComponent(".audit/\(UUID().uuidString)")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: ordinary)
    #expect(throws: ProviderSandboxVerificationError.invalidStateLocation(alias.path)) {
        try ProviderSandboxVerifier.verifyStateDirectory(alias, providerID: providerID, applicationSupport: support)
    }
    try FileManager.default.removeItem(at: state.deletingLastPathComponent())
    try FileManager.default.createSymbolicLink(at: state.deletingLastPathComponent(), withDestinationURL: temporary)
    await #expect(throws: ProviderPackageStoreError.self) {
        try await first.stateDirectory(providerID: providerID, sandboxed: true)
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_RUN_SIGNED_SANDBOX_HOME_TEST"] == "1"))
func signedSandboxAuditExecutesHomeWithoutReadingOrChangingOrdinaryState() async throws {
    // Home-relative sandbox exceptions resolve against the OS account, not an
    // overridden HOME. Run this integration explicitly from that account home.
    let account = try #require(getpwuid(getuid()))
    let accountHome = URL(fileURLWithPath: String(cString: account.pointee.pw_dir))
        .standardizedFileURL.resolvingSymlinksInPath()
    try #require(FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.resolvingSymlinksInPath() == accountHome)
    let fixture = try SandboxAuditHomeFixture()
    defer { fixture.remove() }
    let provider = RemoteSiteContentProvider(providerID: fixture.providerID, manager: fixture.manager)
    let site = Site(key: "AuditSignedHome", name: "Fixture", type: 3, api: "csp_AuditSignedHome")
    let home: Result
    do {
        home = try await provider.homeContent(site: site)
    } catch {
        await fixture.manager.shutdownAll()
        throw error
    }
    await fixture.manager.shutdownAll()
    #expect(home.types.map(\.typeId) == ["fixture"])
    #expect(home.list.first?.vodName == "Isolated signed home")
    let isolated = try await fixture.store.stateDirectory(providerID: fixture.providerID, sandboxed: true)
    let recorded = try String(contentsOf: isolated.appendingPathComponent("home.marker"), encoding: .utf8)
    #expect(recorded == "\(isolated.path)\n\(isolated.appendingPathComponent("home").path)\n\(isolated.appendingPathComponent("cache").path)\n")
    #expect(!FileManager.default.fileExists(atPath: isolated.appendingPathComponent("credentials.json").path))
    #expect(try Data(contentsOf: fixture.credential) == fixture.sentinel)
    #expect(try await fixture.store.activePackage(providerID: fixture.providerID).1.manifest.providerID == fixture.providerID)
}

private struct SandboxAuditHomeFixture {
    let providerID: String
    let root: URL
    let packageParent: URL
    let ordinary: URL
    let credential: URL
    let sentinel = Data("test-only-credential-sentinel".utf8)
    let store: ProviderPackageStore
    let manager: ProviderManager

    init() throws {
        providerID = "fixture.audit-home." + UUID().uuidString.lowercased()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(providerID)
        let support = try #require(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        let installed = support.appendingPathComponent("NetVplayer/Providers", isDirectory: true)
        packageParent = installed.appendingPathComponent(providerID, isDirectory: true)
        let package = packageParent.appendingPathComponent("1.0.0", isDirectory: true)
        ordinary = installed.appendingPathComponent(".state/\(providerID)", isDirectory: true)
        credential = ordinary.appendingPathComponent("credentials.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: package.appendingPathComponent("LICENSES"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ordinary, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try sentinel.write(to: credential)
        let bundle = package.appendingPathComponent("Sandbox/ProviderSandboxLauncher.app")
        let launcher = bundle.appendingPathComponent("Contents/MacOS/ProviderSandboxLauncher")
        try FileManager.default.createDirectory(at: launcher.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        try Self.run("/usr/bin/xcrun", ["swiftc", sourceRoot.appendingPathComponent("Sources/ProviderSandboxLauncher/main.swift").path,
            "-module-cache-path", root.appendingPathComponent("ModuleCache").path, "-o", launcher.path])
        let runnerSource = root.appendingPathComponent("runner.c")
        try Self.runner.write(to: runnerSource, atomically: true, encoding: .utf8)
        let runner = package.appendingPathComponent("runner")
        try Self.run("/usr/bin/xcrun", ["clang", "-O2", runnerSource.path, "-o", runner.path])
        try Self.run("/usr/bin/codesign", ["--force", "--sign", "-", runner.path])
        let identifier = ProviderSandboxVerifier.expectedBundleIdentifier(providerID: providerID)
        let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleExecutable": "ProviderSandboxLauncher",
            "CFBundleName": "ProviderSandboxLauncher", "CFBundlePackageType": "APPL", "CFBundleVersion": "1",
            "LSBackgroundOnly": true]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        let entitlements: [String: Any] = [
            "com.apple.security.app-sandbox": true, "com.apple.security.network.client": true,
            "com.apple.security.temporary-exception.files.home-relative-path.read-only": [ProviderSandboxVerifier.expectedPackageReadPath(providerID: providerID)],
            "com.apple.security.temporary-exception.files.home-relative-path.read-write": [ProviderSandboxVerifier.expectedStateWritePath(providerID: providerID)]
        ]
        let entitlementFile = root.appendingPathComponent("entitlements.plist")
        try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0).write(to: entitlementFile)
        try Self.run("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", identifier,
            "--entitlements", entitlementFile.path, bundle.path])
        try Data("fixture-only".utf8).write(to: package.appendingPathComponent("provider.js"))
        try Data("MIT fixture".utf8).write(to: package.appendingPathComponent("LICENSES/PROVIDER.txt"))
        let packageRoot = package.standardizedFileURL.resolvingSymlinksInPath()
        let files = try #require(FileManager.default.enumerator(at: packageRoot, includingPropertiesForKeys: [.isRegularFileKey]))
        let assets = try files.compactMap { item -> ProviderAsset? in
            guard let file = item as? URL, try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { return nil }
            let prefix = packageRoot.path + "/"
            let path = file.standardizedFileURL.resolvingSymlinksInPath().path
            guard path.hasPrefix(prefix) else { throw URLError(.badURL) }
            let relative = String(path.dropFirst(prefix.count))
            return ProviderAsset(path: relative, sha256: try ProviderManifestVerifier.sha256(of: file))
        }
        let key = Curve25519.Signing.PrivateKey()
        let verifier = try ProviderManifestVerifier(publicKeyData: key.publicKey.rawRepresentation, shellVersion: "1.1.4")
        let manifest = ProviderManifest(providerID: providerID, version: "1.0.0", shellMinimumVersion: "1.0.0",
            macOSMinimumVersion: "14.0", architectures: [ProviderManifestVerifier.currentArchitecture], runtime: .javaScript,
            entrypoint: "provider.js", runner: "runner", sandbox: .init(launcher: "Sandbox/ProviderSandboxLauncher.app/Contents/MacOS/ProviderSandboxLauncher",
                bundleIdentifier: identifier, releaseProfile: .communityAdhoc), capabilities: [.home], assets: assets,
            sourcePolicy: .userConfiguredCatalog, license: "MIT")
        let document = SignedProviderManifest(manifest: manifest,
            signature: try key.signature(for: JSONEncoder.providerCanonical.encode(manifest)).base64EncodedString())
        try JSONEncoder.providerCanonical.encode(document).write(to: package.appendingPathComponent("signed-manifest.json"))
        try Data("1.0.0".utf8).write(to: packageParent.appendingPathComponent("active-version"))
        store = ProviderPackageStore(rootURL: installed, verifier: verifier,
            stateDirectoryRootURL: root.appendingPathComponent("audit-output/provider-state"))
        manager = ProviderManager(store: store)
    }

    func remove() {
        try? FileManager.default.removeItem(at: packageParent)
        try? FileManager.default.removeItem(at: ordinary)
        try? FileManager.default.removeItem(at: root)
        let container = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Containers/" + ProviderSandboxVerifier.expectedBundleIdentifier(providerID: providerID))
        try? FileManager.default.removeItem(at: container)
    }

    private static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "SandboxAuditHomeFixture", code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)])
        }
    }

    private static let runner = #"""
    #include <stdio.h>
    #include <stdlib.h>
    #include <string.h>
    #include <unistd.h>
    int main(void) {
        char line[65536], identifier[256];
        while (fgets(line, sizeof(line), stdin)) {
            const char *start = strstr(line, "\"request_id\"");
            if (!start || !(start = strchr(start, ':'))) return 64;
            while (*++start == ' ') {}
            if (*start++ != '"') return 64;
            const char *end = strchr(start, '"');
            if (!end || end-start >= sizeof(identifier)) return 64;
            memcpy(identifier, start, end-start); identifier[end-start] = 0;
            if (strstr(line, "\"operation\":\"handshake\"")) {
                printf("{\"request_id\":\"%s\",\"ok\":true,\"result\":{\"protocol\":1,\"provider_id\":\"%s\",\"capabilities\":[]}}\n", identifier, getenv("NETVPLAYER_PROVIDER_ID"));
            } else if (strstr(line, "\"operation\":\"home\"")) {
                char path[4096]; const char *state = getenv("NETVPLAYER_PROVIDER_STATE");
                snprintf(path, sizeof(path), "%s/credentials.json", state);
                if (access(path, F_OK) == 0) return 65;
                snprintf(path, sizeof(path), "%s/home.marker", state);
                FILE *marker = fopen(path, "w"); if (!marker) return 66;
                fprintf(marker, "%s\n%s\n%s\n", state, getenv("HOME"), getenv("XDG_CACHE_HOME")); fclose(marker);
                printf("{\"request_id\":\"%s\",\"ok\":true,\"result\":{\"class\":[{\"type_id\":\"fixture\",\"type_name\":\"Fixture\"}],\"list\":[{\"vod_id\":\"one\",\"vod_name\":\"Isolated signed home\"}]}}\n", identifier);
            } else {
                printf("{\"request_id\":\"%s\",\"ok\":true,\"result\":{}}\n", identifier);
            }
            fflush(stdout);
            if (strstr(line, "\"operation\":\"shutdown\"")) return 0;
        }
        return 0;
    }
    """#
}
