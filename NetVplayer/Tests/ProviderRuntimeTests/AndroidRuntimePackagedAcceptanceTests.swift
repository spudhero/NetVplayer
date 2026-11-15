import CryptoKit
import Foundation
import Testing
import Models
import ProviderRuntime
import ProviderSDK
@testable import SpiderEngine

/// Opt-in integration of real signed runtime, real DEX conversion and JVM
/// processes. The local HTTP fixture supplies two independently built complete
/// archives; it is never counted as a real-source playback/parity pass.
@Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_ANDROID_UPDATE_ACCEPTANCE"] != nil))
func originalPackagedRuntimeWholeJARUpdateRecovery() async throws {
    let input = try #require(ProcessInfo.processInfo.environment["NETVPLAYER_ANDROID_UPDATE_ACCEPTANCE"])
    let plan = try JSONDecoder().decode(PackagedUpdatePlan.self, from: Data(contentsOf: URL(fileURLWithPath: input)))
    let root = URL(fileURLWithPath: plan.output)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let key = try #require(Data(base64Encoded: plan.publicKey))
    let store = AndroidRuntimeComponentStore(root: root.appendingPathComponent("components"),
        verifier: try ProviderManifestVerifier(publicKeyData: key, shellVersion: "1.1.4"))
    _ = try await store.install(directory: URL(fileURLWithPath: plan.component))
    let runtime = try #require(try await store.activeRuntime())
    let registry = SpiderReplacementRegistry()
    let cache = root.appendingPathComponent("artifacts")
    let registration = DevelopmentAndroidRuntimeRegistration(stateRoot: root.appendingPathComponent("state"),
        registry: registry, arguments: [], artifactStore: DevelopmentAndroidArtifactStore(root: cache))
    var site = Site(key: "UpdateFixture", name: "Controlled update", type: 3, api: "csp_UpdateFixtureGuard", jar: plan.url)
    let serverFile = URL(fileURLWithPath: plan.servedFile)
    let a = try Data(contentsOf: URL(fileURLWithPath: plan.archiveA))
    let b = try Data(contentsOf: URL(fileURLWithPath: plan.archiveB))
    func publish(_ data: Data) throws { try data.write(to: serverFile, options: .atomic) }
    func provider() async throws -> DevelopmentAndroidSiteProvider {
        try #require(await registry.nativeProvider(for: site) as? DevelopmentAndroidSiteProvider)
    }
    func register() async throws { try await registration.register(runtime: runtime, sites: [site], preference: .androidPreferred) }
    func md5(_ data: Data) -> String { Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    var events: [[String: String]] = []
    do {
        try publish(a)
        try await register()
        let first = try await provider()
        let homeA = try await first.homeContent(site: site)
        #expect(homeA.list.first?.vodId == "A")
        #expect(homeA.list.first?.vodName == "Revision A A call=1")
        let shaA = try #require(await registration.effectiveProviderSHA256(site: site))
        try publish(b)
        try await register() // Same URL, no declared checksum: re-fetch whole bytes.
        let second = try await provider()
        #expect(second !== first)
        await #expect(throws: DevelopmentAndroidRuntimeError.closed) { try await first.homeContent(site: site) }
        let homeB = try await second.homeContent(site: site)
        #expect(homeB.list.first?.vodId == "B")
        #expect(homeB.list.first?.vodName == "Revision B B call=1")
        let shaB = try #require(await registration.effectiveProviderSHA256(site: site))
        #expect(shaA != shaB)
        events.append(["case": "same_url_new_complete_dex_resource_and_session", "first": shaA, "second": shaB])
        // A declared, already verified revision works while its server is absent.
        site.jar = plan.url + ";md5;" + md5(b)
        try await register()
        try FileManager.default.removeItem(at: serverFile)
        try await register()
        #expect(try await provider().homeContent(site: site).list.first?.vodId == "B")
        events.append(["case": "offline_verified_revision", "result": "passed"])
        // Corrupt converted bytes cannot execute or silently revive the old helper.
        let original = try #require(FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix(shaB + "-") })
        let converted = original.appendingPathComponent("provider-jvm.jar")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: converted.path)
        try Data("broken cache".utf8).write(to: converted)
        try await register()
        #expect(await registration.effectiveProviderSHA256(site: site) == nil)
        let failure = try #require(await registry.nativeProvider(for: site) as? DevelopmentAndroidArtifactFailureProvider)
        await #expect(throws: DevelopmentAndroidArtifactError.downloadFailed) { try await failure.homeContent(site: site) }
        await #expect(throws: DevelopmentAndroidRuntimeError.closed) { try await second.homeContent(site: site) }
        events.append(["case": "corrupt_cache_offline_no_old_business", "result": "passed"])
        try publish(b)
        try await register()
        #expect(try await provider().homeContent(site: site).list.first?.vodName == "Revision B B call=1")
        events.append(["case": "online_reconversion_after_corruption", "result": "passed"])
        let broken = try Data(contentsOf: URL(fileURLWithPath: plan.invalidArchive))
        try publish(broken)
        site.jar = plan.url + ";md5;" + md5(broken)
        try await register()
        let conversionFailure = try #require(await registry.nativeProvider(for: site) as? DevelopmentAndroidArtifactFailureProvider)
        await #expect(throws: DevelopmentAndroidArtifactError.conversionFailed) { try await conversionFailure.homeContent(site: site) }
        events.append(["case": "failed_real_conversion_no_partial_activation", "result": "passed"])
        try publish(b)
        site.jar = plan.url + ";md5;" + md5(b)
        try await register()
        #expect(try await provider().homeContent(site: site).list.first?.vodId == "B")
        events.append(["case": "recover_after_failed_conversion", "result": "passed"])
        try JSONSerialization.data(withJSONObject: events, options: [.sortedKeys, .prettyPrinted]).write(to: root.appendingPathComponent("results.safe.json"))
        await registration.shutdownAll()
    } catch {
        await registration.shutdownAll()
        throw error
    }
}

private struct PackagedUpdatePlan: Decodable {
    let component, publicKey, output, url, servedFile, archiveA, archiveB, invalidArchive: String
}
