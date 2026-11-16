#if DEBUG
import CryptoKit
import DriveEngine
import Foundation
import Models
import ProviderRuntime
import ProviderSDK
import Testing
@testable import SpiderEngine

@Test func developmentAiDjUsesOneCompleteImplementationWithoutHybridRouting() async throws {
    let signed = try DevelopmentSignedRouteFixture()
    let android = try DevelopmentAndroidBridgeFixture()
    defer { signed.remove(); android.remove() }
    try android.writeManifest(changes: ["bindings": [["key": "AiDj", "api": "csp_AiDjGuard", "className": "com.github.catvod.spider.AiDjGuard"]]])
    let runtime = try DevelopmentAndroidRuntimeLayout.load(root: android.runtime)
    let site = Site(key: "AiDj", name: "AiDj", type: 3, api: "csp_AiDjGuard")
    for preference in [ProviderExecutionPreference.automatic, .macPreferred, .androidPreferred] {
        let registry = SpiderReplacementRegistry()
        await registry.registerRemote(manifest: signed.document.manifest, manager: signed.manager)
        let registration = DevelopmentAndroidRuntimeRegistration(stateRoot: android.state, registry: registry, bundledArtifactForTesting: true,
            arguments: ["--android-provider-audit", "--android-provider-use-bundled-artifact"])
        try await registration.register(runtime: runtime, sites: [site], preference: preference,
            cloudCredentialProvider: { _ in
                Issue.record("Registration must not read host credentials for hybrid playback")
                return nil
            })
        let selected = try #require(await registry.nativeProvider(for: site))
        #expect(!(selected is AndroidCatalogPlaybackProvider))
        #expect((selected is DevelopmentAndroidSiteProvider) == preference.usesAndroid)
        #expect((selected is RemoteSiteContentProvider) == !preference.usesAndroid)
        #expect(await registration.isRegistered(site: site) == preference.usesAndroid)
        #expect(await registry.executionBackend(for: site) == (preference.usesAndroid ? .androidOriginal : .macExtension))
        await registration.shutdownAll()
    }
}

@Test func developmentMacPreferenceStillUsesOtherCompleteInstalledAdapters() async throws {
    let signed = try DevelopmentSignedRouteFixture(bindings: [
        .init(originalKeys: ["Other"], originalAPIs: ["csp_OtherGuard"])
    ])
    let android = try DevelopmentAndroidBridgeFixture()
    defer { signed.remove(); android.remove() }
    try android.writeManifest(changes: ["bindings": [["key": "Other", "api": "csp_OtherGuard", "className": "com.github.catvod.spider.OtherGuard"]]])
    let runtime = try DevelopmentAndroidRuntimeLayout.load(root: android.runtime)
    let site = Site(key: "Other", name: "Other", type: 3, api: "csp_OtherGuard")
    let registry = SpiderReplacementRegistry()
    await registry.registerRemote(manifest: signed.document.manifest, manager: signed.manager)
    let registration = DevelopmentAndroidRuntimeRegistration(stateRoot: android.state, registry: registry, bundledArtifactForTesting: true, arguments: [])
    try await registration.register(runtime: runtime, sites: [site], preference: .macPreferred)
    let selected = try #require(await registry.nativeProvider(for: site) as? RemoteSiteContentProvider)
    #expect(selected.providerID == signed.document.manifest.providerID)
    #expect(await registry.executionBackend(for: site) == .macExtension)
    await registration.shutdownAll()
    #expect(await registry.nativeProvider(for: site) is RemoteSiteContentProvider)
}

@Test func developmentInstalledRouteRejectsSplitAliasesIncompleteCapabilitiesAndMissingPackages() async throws {
    let site = Site(key: "AiDj", name: "AiDj", type: 3, api: "csp_AiDjGuard")
    let cases: [([ProviderSourceBinding], [ProviderCapability])] = [
        ([ProviderSourceBinding(originalKeys: ["AiDj"]), ProviderSourceBinding(originalAPIs: ["csp_AiDjGuard"])], [.home, .category, .detail, .player]),
        ([ProviderSourceBinding(originalKeys: ["AiDj"], originalAPIs: ["csp_AiDjGuard"])], [.home, .detail, .player]),
        ([ProviderSourceBinding(originalKeys: ["Other"], originalAPIs: ["csp_AiDjGuard"])], [.home, .category, .detail, .player])
    ]
    for (bindings, capabilities) in cases {
        let fixture = try DevelopmentSignedRouteFixture(bindings: bindings, capabilities: capabilities)
        defer { fixture.remove() }
        let registry = SpiderReplacementRegistry()
        await registry.registerRemote(manifest: fixture.document.manifest, manager: fixture.manager)
        #expect(await registry.exactInstalledRemoteProvider(for: site) == nil)
    }
    let fixture = try DevelopmentSignedRouteFixture(activate: false)
    defer { fixture.remove() }
    let registry = SpiderReplacementRegistry()
    await registry.registerRemote(manifest: fixture.document.manifest, manager: fixture.manager)
    #expect(await registry.exactInstalledRemoteProvider(for: site) == nil)
}

@Test func developmentInstalledAiDjPreferenceDoesNotCaptureChangedGuardIdentities() async throws {
    let signed = try DevelopmentSignedRouteFixture()
    let android = try DevelopmentAndroidBridgeFixture()
    defer { signed.remove(); android.remove() }
    let variants = [
        ["key": "AiDj-copy", "api": "csp_AiDjGuard", "className": "com.github.catvod.spider.AiDjGuard"],
        ["key": "AiDj", "api": "csp_AiDjOtherGuard", "className": "com.github.catvod.spider.AiDjGuard"],
        ["key": "AiDj", "api": "csp_AiDjGuard", "className": "com.github.catvod.spider.OtherGuard"]
    ]
    for binding in variants {
        try android.writeManifest(changes: ["bindings": [binding]])
        let runtime = try DevelopmentAndroidRuntimeLayout.load(root: android.runtime)
        let site = Site(key: binding["key"]!, name: "Changed identity", type: 3, api: binding["api"]!)
        let registry = SpiderReplacementRegistry()
        await registry.registerRemote(manifest: signed.document.manifest, manager: signed.manager)
        let registration = DevelopmentAndroidRuntimeRegistration(stateRoot: android.state, registry: registry, bundledArtifactForTesting: true, arguments: [])
        try await registration.register(runtime: runtime, sites: [site])
        #expect(await registration.isRegistered(site: site))
        _ = try #require(await registry.nativeProvider(for: site) as? DevelopmentAndroidSiteProvider)
        await registration.shutdownAll()
    }
}

@Test func developmentInstalledRouteRechecksAssetIntegrityAndDisabledState() async throws {
    let fixture = try DevelopmentSignedRouteFixture()
    defer { fixture.remove() }
    let site = Site(key: "AiDj", name: "AiDj", type: 3, api: "csp_AiDjGuard")
    let registry = SpiderReplacementRegistry()
    await registry.registerRemote(manifest: fixture.document.manifest, manager: fixture.manager)
    #expect(await registry.exactInstalledRemoteProvider(for: site) != nil)
    try await fixture.store.setDisabled(true)
    #expect(await registry.exactInstalledRemoteProvider(for: site) == nil)
    try await fixture.store.setDisabled(false)
    let active = try await fixture.store.activePackage(providerID: fixture.document.manifest.providerID).0
    try Data("tampered source".utf8).write(to: active.appendingPathComponent("provider.py"))
    #expect(await registry.exactInstalledRemoteProvider(for: site) == nil)
}

@Test func developmentAuditProviderStateDoesNotReuseOrChangeInstalledCredentials() async throws {
    let fixture = try DevelopmentSignedRouteFixture()
    defer { fixture.remove() }
    let ordinary = try await fixture.store.stateDirectory(providerID: "fixture.installed.aidj")
    let credential = ordinary.appendingPathComponent("credentials.json")
    let original = Data("private-fixture-credentials".utf8)
    try original.write(to: credential)
    let isolated = ProviderPackageStore(rootURL: fixture.installed, verifier: fixture.verifier,
        stateDirectoryRootURL: fixture.root.appendingPathComponent("audit/provider-state", isDirectory: true))
    let state = try await isolated.stateDirectory(providerID: "fixture.installed.aidj")
    #expect(state.path != ordinary.path)
    #expect(!FileManager.default.fileExists(atPath: state.appendingPathComponent("credentials.json").path))
    try Data("audit writes".utf8).write(to: state.appendingPathComponent("credentials.json"))
    #expect(try Data(contentsOf: credential) == original)
    #expect(try await isolated.activePackage(providerID: "fixture.installed.aidj").1.manifest.version == "1.0.0")
}

@Test func developmentInstalledOnlyBootstrapCannotFetchOrInstallFromDistribution() async throws {
    let fixture = try DevelopmentSignedRouteFixture()
    defer { fixture.remove() }
    let bundleURL = fixture.root.appendingPathComponent("trust.bundle", isDirectory: true)
    try FileManager.default.createDirectory(at: bundleURL.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    let info: [String: Any] = [
        "CFBundleIdentifier": "fixture.audit.trust", "CFBundlePackageType": "BNDL", "CFBundleShortVersionString": "1.1.4",
        ProviderTrustConfiguration.manifestKeyName: fixture.verifier.publicKey.rawRepresentation.base64EncodedString(),
        ProviderTrustConfiguration.distributionKeyName: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString(),
        "NetVplayerProviderDistributionIndexURL": "https://never-contact.example.test/index.json"
    ]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: bundleURL.appendingPathComponent("Contents/Info.plist"))
    let bundle = try #require(Bundle(url: bundleURL))
    let bootstrap = try #require(ProviderRuntimeBootstrap.makeDefault(bundle: bundle,
        stateDirectoryRootURL: fixture.root.appendingPathComponent("audit-state"), installedOnly: true))
    await bootstrap.configureDistributionProxy(port: 7897)
    await #expect(throws: ProviderRuntimeBootstrapError.distributionNotConfigured) { try await bootstrap.fetchCatalog() }
    await #expect(throws: ProviderRuntimeBootstrapError.distributionNotConfigured) { try await bootstrap.synchronizeAvailableProviders() }
}

private struct DevelopmentSignedRouteFixture {
    let root: URL
    let installed: URL
    let verifier: ProviderManifestVerifier
    let store: ProviderPackageStore
    let manager: ProviderManager
    let document: SignedProviderManifest

    init(bindings: [ProviderSourceBinding] = [.init(originalKeys: ["AiDj"], originalAPIs: ["csp_AiDjGuard"])],
         capabilities: [ProviderCapability] = [.home, .category, .detail, .player], activate: Bool = true,
         providerID: String = "fixture.installed.aidj", version: String = "1.0.0") throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("installed-aidj-route-\(UUID().uuidString)", isDirectory: true)
        installed = root.appendingPathComponent("installed", isDirectory: true)
        let package = root.appendingPathComponent("package", isDirectory: true)
        try FileManager.default.createDirectory(at: package.appendingPathComponent("LICENSES"), withIntermediateDirectories: true)
        let assets = try ["provider.py", "runner.py", "LICENSES/PROVIDER.txt"].map { path in
            let file = package.appendingPathComponent(path)
            try Data("signed-local-fixture".utf8).write(to: file)
            return ProviderAsset(path: path, sha256: try ProviderManifestVerifier.sha256(of: file))
        }
        let key = Curve25519.Signing.PrivateKey()
        verifier = try ProviderManifestVerifier(publicKeyData: key.publicKey.rawRepresentation, shellVersion: "1.1.4")
        let manifest = ProviderManifest(providerID: providerID, version: version, shellMinimumVersion: "1.0.0",
            macOSMinimumVersion: "1.0", architectures: [ProviderManifestVerifier.currentArchitecture], runtime: .python,
            entrypoint: "provider.py", runner: "runner.py", capabilities: capabilities, assets: assets,
            hostCapabilities: [], sourceBindings: bindings, sourcePolicy: .userConfiguredCatalog, license: "MIT")
        document = SignedProviderManifest(manifest: manifest,
            signature: try key.signature(for: JSONEncoder.providerCanonical.encode(manifest)).base64EncodedString())
        let versionRoot = installed.appendingPathComponent("\(providerID)/\(version)", isDirectory: true)
        try FileManager.default.createDirectory(at: versionRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: package, to: versionRoot)
        try JSONEncoder.providerCanonical.encode(document).write(to: versionRoot.appendingPathComponent("signed-manifest.json"))
        if activate { try Data(version.utf8).write(to: versionRoot.deletingLastPathComponent().appendingPathComponent("active-version")) }
        store = ProviderPackageStore(rootURL: installed, verifier: verifier)
        manager = ProviderManager(store: store)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
#endif
