import CryptoKit
import Foundation
import Testing
import Models
import ProviderRuntime
import ProviderSDK
@testable import SpiderEngine

@Test func originalComponentInstallUpgradeRollbackKeepsIsolatedStateAndVerifiedOfflineSelection() async throws {
    let f = try OriginalComponentFixture(); defer { f.remove() }
    let store = try f.store()
    #expect(try await store.status().version == nil)
    let first = try f.package(version: "1.0.0")
    #expect(try await store.install(directory: first).version == "1.0.0")
    let oldRuntime = try #require(try await store.activeRuntime())
    let second = try f.package(version: "1.1.0", adapter: "updated host")
    let newStatus = try await store.install(directory: second)
    #expect(newStatus.version == "1.1.0" && newStatus.previousVersion == "1.0.0")
    let current = try #require(try await store.activeRuntime())
    #expect(current.componentIdentity != oldRuntime.componentIdentity)
    let binding = DevelopmentAndroidRuntimeManifest.Binding(key: "fixture", api: "csp_Test", className: "com.fixture.Test")
    #expect(try oldRuntime.stateIdentity(binding: binding) != current.stateIdentity(binding: binding))
    #expect(try await f.store().status().version == "1.1.0")
    #expect(try await store.rollback().version == "1.0.0")
    #expect(try await store.activeRuntime()?.componentIdentity == oldRuntime.componentIdentity)
    #expect(FileManager.default.fileExists(atPath: f.installed("1.1.0").path))
}

@Test func originalSignedComponentLocalProxyKeepsTheVerifiedProviderIdentity() async throws {
    let f = try OriginalComponentFixture(); defer { f.remove() }
    let store = try f.store()
    _ = try await store.install(directory: f.package(version: "1.0.0"))
    let runtime = try #require(try await store.activeRuntime())
    let binding = DevelopmentAndroidRuntimeManifest.Binding(key: "fixture", api: "csp_Test", className: "com.fixture.Test")
    let site = Site(key: binding.key, name: "Fixture", type: 3, api: binding.api)
    let result = Models.Result(url: "http://127.0.0.1:-1/proxy?do=fixture&url=opaque-original-id")
    let route = try #require(try DevelopmentAndroidCatVodProxyAdapter.localize(result, site: site,
        binding: binding, providerID: runtime.manifest.providerID, routeID: "signed-component-route",
        proxyAddress: "http://127.0.0.1:9986/proxy"))
    let components = try #require(URLComponents(string: route.result.url))
    var parameters = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    #expect(parameters["providerID"] == AndroidRuntimeComponentStore.providerID)
    #expect(route.parameters["url"] == "opaque-original-id")
    #expect(DevelopmentAndroidCatVodProxyAdapter.matchesRoute(parameters, site: site, providerID: runtime.manifest.providerID))
    parameters["providerID"] = "different-provider"
    #expect(!DevelopmentAndroidCatVodProxyAdapter.matchesRoute(parameters, site: site, providerID: runtime.manifest.providerID))
}

@Test func originalComponentChecksDistributionMetadataAgainstSignedManifest() async throws {
    let f = try OriginalComponentFixture(); defer { f.remove() }
    let store = try f.store()
    _ = try await store.install(directory: f.package(version: "1.0.0"))
    for name in ["manifest.json", "signature.ed25519", "SHA256SUMS"] {
        let candidate = try f.package(version: "2.0.0", suffix: name)
        try Data("tampered metadata".utf8).write(to: candidate.appendingPathComponent(name))
        await #expect(throws: (any Error).self) { try await store.install(directory: candidate) }
        #expect(try await store.status().version == "1.0.0")
    }
    let candidate = try f.package(version: "2.0.0", suffix: "valid-metadata")
    let document = try f.read(candidate)
    try JSONEncoder.providerCanonical.encode(document.manifest).write(to: candidate.appendingPathComponent("manifest.json"))
    try #require(Data(base64Encoded: document.signature)).write(to: candidate.appendingPathComponent("signature.ed25519"))
    try Data(document.manifest.assets.map { $0.sha256 + "  " + $0.path + "\n" }.joined().utf8)
        .write(to: candidate.appendingPathComponent("SHA256SUMS"))
    #expect(try await store.install(directory: candidate).version == "2.0.0")
}

@Test func originalComponentWrongSignatureCorruptionAndUndeclaredCodeNeverActivate() async throws {
    let f = try OriginalComponentFixture(); defer { f.remove() }
    let store = try f.store()
    _ = try await store.install(directory: f.package(version: "1.0.0"))
    for mode in ["signature", "corrupt", "extra", "symlink", "duplicate", "identity", "incompatible"] {
        let candidate = try f.package(version: "2.0.0", suffix: mode)
        switch mode {
        case "signature":
            var document = try f.read(candidate)
            document.signature = Data(repeating: 0, count: 64).base64EncodedString()
            try f.write(document, at: candidate)
        case "corrupt": try Data("corrupt".utf8).write(to: candidate.appendingPathComponent("AndroidProviderRuntime/lib/android-adapter.jar"))
        case "extra": try Data("code".utf8).write(to: candidate.appendingPathComponent("AndroidProviderRuntime/lib/unlisted.jar"))
        case "symlink": try FileManager.default.createSymbolicLink(atPath: candidate.appendingPathComponent("external").path, withDestinationPath: "/tmp")
        default:
            var document = try f.read(candidate)
            if mode == "duplicate" { document.manifest.assets.append(document.manifest.assets[0]) }
            if mode == "identity" { document.manifest.providerID = "different-component" }
            if mode == "incompatible" { document.manifest.shellMinimumVersion = "999.0.0" }
            document.signature = try f.sign(document.manifest)
            try f.write(document, at: candidate)
        }
        await #expect(throws: (any Error).self) { try await store.install(directory: candidate) }
        #expect(try await store.status().version == "1.0.0")
    }
}

@Test func originalComponentFailedProbeAndVersionCollisionPreserveActiveVersion() async throws {
    let f = try OriginalComponentFixture(); defer { f.remove() }
    let store = try f.store()
    _ = try await store.install(directory: f.package(version: "1.0.0"))
    let candidate = try f.package(version: "2.0.0")
    let failing = try f.store(probe: { _ in throw AndroidRuntimeComponentError.launchFailed })
    await #expect(throws: AndroidRuntimeComponentError.launchFailed) {
        try await failing.install(directory: candidate)
    }
    #expect(try await store.status().version == "1.0.0")
    await #expect(throws: (any Error).self) {
        try await store.install(directory: f.package(version: "1.0.0", adapter: "different", suffix: "collision"))
    }
    #expect(try await store.status().version == "1.0.0")
    // Interrupted staging is neither discovered nor selected.
    try FileManager.default.createDirectory(at: f.root.appendingPathComponent("store/versions/.staging-interrupted"), withIntermediateDirectories: true)
    #expect(try await f.store().status().version == "1.0.0")
    #expect(try await store.install(directory: candidate).version == "2.0.0")
}

@Test func originalComponentCorruptActiveFailsClosedAndExplicitRollbackRevalidates() async throws {
    let f = try OriginalComponentFixture(); defer { f.remove() }
    let store = try f.store()
    _ = try await store.install(directory: f.package(version: "1.0.0"))
    _ = try await store.install(directory: f.package(version: "2.0.0"))
    try Data("broken".utf8).write(to: f.installed("2.0.0").appendingPathComponent("AndroidProviderRuntime/lib/android-adapter.jar"))
    await #expect(throws: (any Error).self) { try await store.activeRuntime() }
    #expect(try await store.previousVersion() == "1.0.0")
    #expect(try await store.rollback().version == "1.0.0")
    #expect(try await store.status().previousVersion == nil)
    _ = try await store.install(directory: f.package(version: "3.0.0"))
    try Data("broken".utf8).write(to: f.installed("1.0.0").appendingPathComponent("AndroidProviderRuntime/lib/android-adapter.jar"))
    await #expect(throws: (any Error).self) { try await store.rollback() }
    #expect(try await store.status().version == "3.0.0")
}

@Test func originalComponentRejectsTraversalSelectionAndCanRepairItByExplicitInstall() async throws {
    let f = try OriginalComponentFixture(); defer { f.remove() }
    let store = try f.store()
    _ = try await store.install(directory: f.package(version: "1.0.0"))
    try Data(#"{"schema":1,"active":"../../outside","previous":null}"#.utf8).write(to: f.root.appendingPathComponent("store/selection.json"))
    await #expect(throws: AndroidRuntimeComponentError.invalidSelection) { try await store.activeRuntime() }
    #expect(try await store.install(directory: f.package(version: "2.0.0")).previousVersion == nil)
}

@Test func bootstrappedComponentUsesConfiguredArtifactsAndRejectsMissingJAR() async throws {
    let f = try OriginalComponentFixture(); defer { f.remove() }
    let store = try f.store()
    _ = try await store.install(directory: f.package(version: "1.0.0", schema: 3))
    let runtime = try #require(try await store.activeRuntime())
    #expect(runtime.manifest.schema == 3)
    #expect(runtime.manifest.bindings.isEmpty)
    let site = Site(key: "bootstrap-fixture", name: "Fixture", type: 3, api: "csp_Unconfigured")
    let registry = SpiderReplacementRegistry()
    let registration = DevelopmentAndroidRuntimeRegistration(stateRoot: f.root.appendingPathComponent("state"),
        registry: registry, arguments: [])
    try await registration.register(runtime: runtime, sites: [site], preference: .automatic)
    let provider = try #require(await registry.nativeProvider(for: site) as? AndroidOriginalUnavailableProvider)
    #expect(provider.reason == .missingProviderArtifact)
    #expect(await !registration.isRegistered(site: site))
}

private struct OriginalComponentFixture: Sendable {
    let root: URL
    let key = Curve25519.Signing.PrivateKey()
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("original-component-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func installed(_ version: String) -> URL { root.appendingPathComponent("store/versions/android-original-runtime/" + version) }
    func store(probe: @escaping @Sendable (URL) throws -> Void = { _ in }) throws -> AndroidRuntimeComponentStore {
        AndroidRuntimeComponentStore(root: root.appendingPathComponent("store"),
            verifier: try ProviderManifestVerifier(publicKeyData: key.publicKey.rawRepresentation, shellVersion: "1.0.0"), probe: probe)
    }
    func sign(_ manifest: ProviderManifest) throws -> String {
        try key.signature(for: JSONEncoder.providerCanonical.encode(manifest)).base64EncodedString()
    }
    func read(_ directory: URL) throws -> SignedProviderManifest {
        try JSONDecoder().decode(SignedProviderManifest.self, from: Data(contentsOf: directory.appendingPathComponent("signed-manifest.json")))
    }
    func write(_ document: SignedProviderManifest, at directory: URL) throws {
        try JSONEncoder.providerCanonical.encode(document).write(to: directory.appendingPathComponent("signed-manifest.json"))
    }
    func package(version: String, adapter: String = "host", suffix: String = "", schema: Int = 2) throws -> URL {
        let directory = root.appendingPathComponent(version + suffix)
        let runtime = directory.appendingPathComponent("AndroidProviderRuntime")
        var files = ["lib/android-adapter.jar", "lib/java-runner.jar", "lib/gson.jar", "lib/android-framework.jar", "lib/macapk-loader.jar", "lib/bcprov-fixture.jar",
            "compat/unidbg-android-0.9.8.jar", "compat/unidbg-api-0.9.8.jar", "compat/unidbg-unicorn2-0.9.8.jar", "compat/asm-9.7.1.jar", "compat/jna-5.10.0.jar",
            "inputs/provider.jar", "inputs/host.apk", "converted/provider-jvm.jar", "converted/host-jvm.jar", "jdk/bin/java"]
        for file in files {
            let path = runtime.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((file == "lib/android-adapter.jar" ? adapter : file).utf8).write(to: path)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runtime.appendingPathComponent("jdk/bin/java").path)
        let value: [String: Any] = ["schema": schema, "providerID": "android-original-runtime", "backend": "emulated", "bindings": [],
            "providerSHA256": try ProviderManifestVerifier.sha256(of: runtime.appendingPathComponent("inputs/provider.jar")),
            "hostSHA256": try ProviderManifestVerifier.sha256(of: runtime.appendingPathComponent("inputs/host.apk"))]
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: runtime.appendingPathComponent("manifest.json"))
        files.append("manifest.json")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("LICENSES"), withIntermediateDirectories: true)
        try Data("Fixture only".utf8).write(to: directory.appendingPathComponent("LICENSES/PROVIDER.txt"))
        let paths = files.map { "AndroidProviderRuntime/" + $0 } + ["LICENSES/PROVIDER.txt"]
        let assets = try paths.map { path in ProviderAsset(path: path, sha256: try ProviderManifestVerifier.sha256(of: directory.appendingPathComponent(path)), executable: path.hasSuffix("bin/java")) }
        let manifest = ProviderManifest(providerID: "android-original-runtime", version: version, shellMinimumVersion: "1.0.0",
            architectures: [ProviderManifestVerifier.currentArchitecture], runtime: .java,
            entrypoint: "AndroidProviderRuntime/lib/android-adapter.jar", runner: "AndroidProviderRuntime/lib/java-runner.jar",
            runtimeExecutable: "AndroidProviderRuntime/jdk/bin/java", capabilities: [], assets: assets, license: "Fixture only", status: .partial, revoked: false)
        try write(SignedProviderManifest(manifest: manifest, signature: sign(manifest)), at: directory)
        return directory
    }
}
