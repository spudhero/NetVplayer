#if DEBUG
import CryptoKit
import Foundation
import Models
import ProviderRuntime
import ProviderSDK
import SpiderEngine
import Testing
@testable import NetVplayerApp

@Suite("Installed provider audit", .serialized)
@MainActor
struct DevelopmentInstalledProviderAuditTests {
    @Test func auditRegistersVerifiedLocalProvidersBeforeSourceSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("audit-installed-provider-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let providerID = "fixture.audit." + UUID().uuidString
        let key = Curve25519.Signing.PrivateKey()
        let verifier = try ProviderManifestVerifier(publicKeyData: key.publicKey.rawRepresentation, shellVersion: "1.1.4")
        let installed = root.appendingPathComponent("installed", isDirectory: true)
        let package = installed.appendingPathComponent("\(providerID)/1.0.0", isDirectory: true)
        try FileManager.default.createDirectory(at: package.appendingPathComponent("LICENSES"), withIntermediateDirectories: true)
        let assets = try ["provider.py", "runner.py", "LICENSES/PROVIDER.txt"].map { relative in
            let file = package.appendingPathComponent(relative)
            try Data("verified-local-audit-fixture".utf8).write(to: file)
            return ProviderAsset(path: relative, sha256: try ProviderManifestVerifier.sha256(of: file))
        }
        let sourceKey = "audit-local-" + UUID().uuidString
        let sourceAPI = "audit-api-" + UUID().uuidString
        let manifest = ProviderManifest(providerID: providerID, version: "1.0.0", shellMinimumVersion: "1.0.0", macOSMinimumVersion: "1.0",
            architectures: [ProviderManifestVerifier.currentArchitecture], runtime: .python, entrypoint: "provider.py", runner: "runner.py",
            capabilities: [.home, .category, .detail, .player], assets: assets, hostCapabilities: [],
            sourceBindings: [.init(originalKeys: [sourceKey], originalAPIs: [sourceAPI])], sourcePolicy: .userConfiguredCatalog, license: "MIT")
        let document = SignedProviderManifest(manifest: manifest,
            signature: try key.signature(for: JSONEncoder.providerCanonical.encode(manifest)).base64EncodedString())
        try JSONEncoder.providerCanonical.encode(document).write(to: package.appendingPathComponent("signed-manifest.json"))
        try Data("1.0.0".utf8).write(to: package.deletingLastPathComponent().appendingPathComponent("active-version"))
        let store = ProviderPackageStore(rootURL: installed, verifier: verifier,
            stateDirectoryRootURL: root.appendingPathComponent("audit/provider-state"))
        let bootstrap = ProviderRuntimeBootstrap(manager: ProviderManager(store: store))
        let plan = try JSONDecoder().decode(DevelopmentAndroidAppAudit.Plan.self, from: JSONSerialization.data(withJSONObject: [
            "config": root.appendingPathComponent("config.json").path, "output": root.appendingPathComponent("audit").path
        ]))
        let state = DevelopmentAndroidAppAudit.makeState(plan, installedProviderBootstrap: bootstrap)
        await state.providerRuntimeStartupTask?.value
        #expect(state.providerRuntimeInstalled.map(\.manifest.providerID) == [providerID])
        #expect(!state.providerRuntimeHasFailure)
        let selected = await SpiderReplacementRegistry.shared.nativeProvider(for: Site(key: sourceKey, name: "Fixture", type: 3, api: sourceAPI))
        #expect((selected as? RemoteSiteContentProvider)?.providerID == providerID)
        await SpiderReplacementRegistry.shared.removeRemoteBindings(providerID: providerID)
        try await state.prepareForApplicationTermination()
        await bootstrap.shutdown()
        #expect(!FileManager.default.fileExists(atPath: installed.appendingPathComponent(".state").path))
    }
}
#endif
