#if DEBUG
import CryptoKit
import Foundation
import Models
import Testing
@testable import SpiderEngine

@Test func developmentAndroidArtifactUsesDeclaredRevisionAndReusesVerifiedCacheAcrossLaunches() async throws {
    let fixture = try AndroidArtifactFixture()
    defer { fixture.remove() }
    let counters = ArtifactCounters()
    let store = fixture.store(fetch: { _, _ in await counters.fetched(); return AndroidArtifactFixture.new },
                              convert: { _, _, output in await counters.converted(); try AndroidArtifactFixture.converted.write(to: output) })
    let artifact = try await store.resolve(declaration: fixture.reference(), runtime: fixture.runtime, bindings: [fixture.binding])
    #expect(artifact.sha256 == fixture.sha(AndroidArtifactFixture.new))
    #expect(artifact.sha256 != fixture.runtime.manifest.providerSHA256)
    #expect(try Data(contentsOf: artifact.original) == AndroidArtifactFixture.new)
    let secondLaunch = fixture.store(fetch: { _, _ in throw ArtifactFixtureFailure.unexpectedNetwork },
                                    convert: { _, _, _ in throw ArtifactFixtureFailure.unexpectedConversion })
    let cached = try await secondLaunch.resolve(declaration: fixture.reference(), runtime: fixture.runtime, bindings: [fixture.binding])
    #expect(cached.original == artifact.original && cached.converted == artifact.converted)
    #expect(await counters.fetches == 1)
    #expect(await counters.conversions == 1)
    for url in try FileManager.default.contentsOfDirectory(at: fixture.cache, includingPropertiesForKeys: nil) where url.pathExtension == "json" {
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains("secret-source-token") && !text.contains("https://"))
    }
    let command = try fixture.runtime.using(artifact: artifact).command(binding: fixture.binding, stateDirectory: fixture.root.appendingPathComponent("state"))
    #expect(command.arguments.contains("-Dnetvplayer.android.dexPath=" + artifact.original.path))
    #expect(command.arguments.contains("-Dnetvplayer.android.convertedPath=" + artifact.converted.path))
    #expect(command.arguments.contains("-Dnetvplayer.android.hostApk=" + fixture.runtime.root.appendingPathComponent("inputs/host.apk").path))
}

@Test func developmentAndroidArtifactChecksumFailureNeverFallsBackToBundledBusinessCode() async throws {
    let fixture = try AndroidArtifactFixture()
    defer { fixture.remove() }
    let counters = ArtifactCounters()
    let store = fixture.store(fetch: { _, _ in AndroidArtifactFixture.old }, convert: { _, _, _ in await counters.converted() })
    let registry = SpiderReplacementRegistry()
    let registration = DevelopmentAndroidRuntimeRegistration(stateRoot: fixture.root, registry: registry, arguments: [], artifactStore: store)
    try await registration.register(runtime: fixture.runtime, sites: [fixture.site()])
    let failure = try #require(await registry.nativeProvider(for: fixture.site()) as? DevelopmentAndroidArtifactFailureProvider)
    await #expect(throws: DevelopmentAndroidArtifactError.checksumMismatch) { try await failure.homeContent(site: fixture.site()) }
    #expect(await counters.conversions == 0)
    #expect(try Data(contentsOf: fixture.runtime.root.appendingPathComponent("inputs/provider.jar")) == AndroidArtifactFixture.old)
}

@Test func developmentAndroidArtifactRefreshFailureRetiresAnAlreadyRegisteredOlderHelper() async throws {
    let fixture = try AndroidArtifactFixture()
    defer { fixture.remove() }
    let store = fixture.store(fetch: { _, _ in AndroidArtifactFixture.new }, convert: { _, _, output in try AndroidArtifactFixture.converted.write(to: output) })
    let registry = SpiderReplacementRegistry()
    let registration = DevelopmentAndroidRuntimeRegistration(stateRoot: fixture.root, registry: registry, arguments: [], artifactStore: store)
    let site = fixture.site()
    try await registration.register(runtime: fixture.runtime, sites: [site])
    #expect(await registry.nativeProvider(for: site) is DevelopmentAndroidSiteProvider)
    var changed = site
    changed.jar = fixture.reference(newer: true)
    try await registration.register(runtime: fixture.runtime, sites: [changed])
    let failure = try #require(await registry.nativeProvider(for: changed) as? DevelopmentAndroidArtifactFailureProvider)
    await #expect(throws: DevelopmentAndroidArtifactError.checksumMismatch) { try await failure.homeContent(site: changed) }
    await registration.shutdownAll()
}

@Test func developmentAndroidUnversionedArtifactChecksContentAgainOnConfigurationRefresh() async throws {
    let fixture = try AndroidArtifactFixture()
    defer { fixture.remove() }
    let counters = ArtifactCounters()
    let store = fixture.store(fetch: { _, _ in
        let n = await counters.fetched()
        return n == 1 ? AndroidArtifactFixture.new : AndroidArtifactFixture.newer
    }, convert: { _, _, output in await counters.converted(); try AndroidArtifactFixture.converted.write(to: output) })
    let url = "https://source.example.test/current.jar?token=secret-source-token"
    let first = try await store.resolve(declaration: url, runtime: fixture.runtime, bindings: [fixture.binding])
    let second = try await store.resolve(declaration: url, runtime: fixture.runtime, bindings: [fixture.binding])
    #expect(first.sha256 != second.sha256 && first.original != second.original)
    #expect(await counters.fetches == 2)
    #expect(await counters.conversions == 2)
}

@Test func developmentAndroidArtifactFailedConversionCannotPublishOrReusePartialOutput() async throws {
    let fixture = try AndroidArtifactFixture()
    defer { fixture.remove() }
    let store = fixture.store(fetch: { _, _ in AndroidArtifactFixture.new }, convert: { _, _, output in
        try Data("partial bytecode".utf8).write(to: output)
        throw ArtifactFixtureFailure.unexpectedConversion
    })
    await #expect(throws: DevelopmentAndroidArtifactError.conversionFailed) {
        try await store.resolve(declaration: fixture.reference(), runtime: fixture.runtime, bindings: [fixture.binding])
    }
    let cacheFiles = try FileManager.default.contentsOfDirectory(at: fixture.cache, includingPropertiesForKeys: nil)
    #expect(cacheFiles.isEmpty)
    let retry = fixture.store(fetch: { _, _ in AndroidArtifactFixture.new }, convert: { _, _, output in try AndroidArtifactFixture.converted.write(to: output) })
    let result = try await retry.resolve(declaration: fixture.reference(), runtime: fixture.runtime, bindings: [fixture.binding])
    #expect(try Data(contentsOf: result.converted) == AndroidArtifactFixture.converted)
}

@Test func developmentAndroidArtifactRejectsRevisionWithoutTheExactGuardBinding() async throws {
    let fixture = try AndroidArtifactFixture()
    defer { fixture.remove() }
    let store = fixture.store(fetch: { _, _ in AndroidArtifactFixture.new }, convert: { _, _, output in try AndroidArtifactFixture.converted.write(to: output) })
    let binding = DevelopmentAndroidRuntimeManifest.Binding(key: "fixture", api: "csp_OtherGuard", className: "com.github.catvod.spider.OtherGuard")
    await #expect(throws: DevelopmentAndroidArtifactError.invalidArchive) {
        try await store.resolve(declaration: fixture.reference(), runtime: fixture.runtime, bindings: [binding])
    }
}

@Test func developmentAndroidOriginalUsesDeclaredArtifactWithoutStaticClassOrNativeRegistration() async throws {
    let fixture = try AndroidArtifactFixture()
    defer { fixture.remove() }
    let counters = ArtifactCounters()
    let store = fixture.store(fetch: { _, _ in await counters.fetched(); return AndroidArtifactFixture.new },
        convert: { _, _, output in await counters.converted(); try AndroidArtifactFixture.converted.write(to: output) })
    var site = fixture.site()
    site.key = "new-original-source"
    site.api = "org.example.DynamicProvider"
    #expect(!fixture.runtime.manifest.bindings.contains { $0.key == site.key || $0.api == site.api })
    let registry = SpiderReplacementRegistry()
    let registration = DevelopmentAndroidRuntimeRegistration(stateRoot: fixture.root, registry: registry, arguments: [], artifactStore: store)
    try await registration.register(runtime: fixture.runtime, sites: [site], preference: .androidPreferred)
    #expect(await registration.isRegistered(site: site))
    #expect(await registry.executionBackend(for: site) == .androidOriginal)
    #expect(await counters.fetches == 1)
    #expect(await counters.conversions == 1)
    // This fixture proves registration/artifact selection, not execution of a
    // dynamic class. The real original loader must resolve or reject that class.
    await registration.shutdownAll()
}

@Test(arguments: [ProviderExecutionPreference.automatic, .macPreferred])
func developmentMacConfigurationNeverFetchesOrConvertsAndroidArtifacts(preference: ProviderExecutionPreference) async throws {
    let fixture = try AndroidArtifactFixture()
    defer { fixture.remove() }
    let store = fixture.store(fetch: { _, _ in
        Issue.record("Mac mode fetched an Android source JAR")
        return AndroidArtifactFixture.new
    }, convert: { _, _, _ in Issue.record("Mac mode converted an Android artifact") })
    let registry = SpiderReplacementRegistry()
    let site = fixture.site()
    let registration = DevelopmentAndroidRuntimeRegistration(stateRoot: fixture.root, registry: registry,
        arguments: ["--android-provider-audit", "--android-provider-force-android"], artifactStore: store)
    try await registration.register(runtime: fixture.configurationRuntime, sites: [site], preference: preference)
    #expect(await registry.nativeProvider(for: site) == nil)
    #expect(await !registration.isRegistered(site: site))
}

@Test(arguments: [ProviderExecutionPreference.androidPreferred])
func developmentAndroidOriginalArtifactFailureDoesNotBlockOtherSources(preference: ProviderExecutionPreference) async throws {
    let fixture = try AndroidArtifactFixture()
    defer { fixture.remove() }
    let counters = ArtifactCounters()
    let store = fixture.store(fetch: { _, _ in await counters.fetched(); return AndroidArtifactFixture.new },
        convert: { _, _, output in await counters.converted(); try AndroidArtifactFixture.converted.write(to: output) })
    let good = fixture.site()
    var bad = good
    bad.key = "unavailable-original-source"
    bad.jar = fixture.reference(newer: true)
    var sameArtifact = bad
    sameArtifact.key += "-copy"
    let registry = SpiderReplacementRegistry()
    let registration = DevelopmentAndroidRuntimeRegistration(stateRoot: fixture.root, registry: registry, arguments: [], artifactStore: store)
    try await registration.register(runtime: fixture.configurationRuntime, sites: [bad, sameArtifact, good], preference: preference)
    for site in [bad, sameArtifact] {
        #expect(await registry.executionBackend(for: site) == .androidUnavailable)
        let failure = try #require(await registry.nativeProvider(for: site) as? DevelopmentAndroidArtifactFailureProvider)
        await #expect(throws: DevelopmentAndroidArtifactError.checksumMismatch) { try await failure.homeContent(site: site) }
    }
    #expect(await registry.executionBackend(for: good) == .androidOriginal)
    #expect(await registration.isRegistered(site: good))
    #expect(await counters.fetches == 2)
    #expect(await counters.conversions == 1)
    await registration.shutdownAll()
}

@Test(arguments: [ProviderExecutionPreference.androidPreferred])
func developmentAndroidMixedConfigurationDefersClassesToOriginalLoader(preference: ProviderExecutionPreference) async throws {
    let fixture = try AndroidArtifactFixture()
    defer { fixture.remove() }
    let counters = ArtifactCounters()
    let store = fixture.store(fetch: { _, _ in await counters.fetched(); return AndroidArtifactFixture.new },
        convert: { _, _, output in await counters.converted(); try AndroidArtifactFixture.converted.write(to: output) })
    let good = fixture.site()
    let script = Site(key: "script", name: "Script", type: 3,
        api: "https://source.example.test/drpy2.js", jar: good.jar)
    let missing = Site(key: "cc", name: "Notice", type: 3, api: "csp_XPathGuard", jar: good.jar)
    let native = Site(key: "玩偶", name: "Native", type: 3, api: "csp_WoGGGuard", jar: good.jar)
    let registry = SpiderReplacementRegistry()
    await registry.register(originalKey: native.key, originalAPI: native.api,
        provider: ConfigurationCenterPublicProvider())
    let registration = DevelopmentAndroidRuntimeRegistration(stateRoot: fixture.root, registry: registry,
        arguments: [], artifactStore: store)

    try await registration.register(runtime: fixture.configurationRuntime,
        sites: [good, script, missing, native], preference: preference)

    for site in [good, script, missing] {
        #expect(await registration.isRegistered(site: site))
        #expect(await registry.executionBackend(for: site) == .androidOriginal)
        #expect(await registration.effectiveProviderSHA256(site: site) == fixture.sha(AndroidArtifactFixture.new))
    }
    #expect(await registry.executionBackend(for: native) == .androidOriginal)
    #expect(await counters.fetches == 1)
    #expect(await counters.conversions == 1)
    // Registration must succeed; the actual loader still resolves or rejects
    // each class when that source is used. No fixture bytecode is executed.
    await registration.shutdownAll()
}

@Test func developmentAndroidArtifactRevisionChangeReplacesTheWholeHelperAndSharesOneFetch() async throws {
    let fixture = try AndroidArtifactFixture(twoSites: true)
    defer { fixture.remove() }
    let counters = ArtifactCounters()
    let store = fixture.store(fetch: { url, _ in
        await counters.fetched()
        return url.path.contains("newer") ? AndroidArtifactFixture.newer : AndroidArtifactFixture.new
    }, convert: { _, _, output in await counters.converted(); try AndroidArtifactFixture.converted.write(to: output) })
    let registry = SpiderReplacementRegistry()
    let registration = DevelopmentAndroidRuntimeRegistration(stateRoot: fixture.root, registry: registry, arguments: [], artifactStore: store)
    let initial = [fixture.site(), fixture.site(key: "fixture-2")]
    try await registration.register(runtime: fixture.runtime, sites: initial)
    let first = try #require(await registry.nativeProvider(for: initial[0]) as? DevelopmentAndroidSiteProvider)
    try await registration.register(runtime: fixture.runtime, sites: initial)
    let same = try #require(await registry.nativeProvider(for: initial[0]) as? DevelopmentAndroidSiteProvider)
    #expect(first === same)
    let changed = initial.map { old in var site = old; site.jar = fixture.reference(newer: true); return site }
    try await registration.register(runtime: fixture.runtime, sites: changed)
    let replaced = try #require(await registry.nativeProvider(for: changed[0]) as? DevelopmentAndroidSiteProvider)
    #expect(first !== replaced)
    #expect(await counters.fetches == 2)
    #expect(await counters.conversions == 2)
    await registration.shutdownAll()
}

@Test func developmentAndroidArtifactOlderConfigurationCannotOverwriteANewerCompletedRefresh() async throws {
    let fixture = try AndroidArtifactFixture()
    defer { fixture.remove() }
    let gate = ArtifactFetchGate()
    let store = fixture.store(fetch: { url, _ in
        if url.path.contains("newer") { return AndroidArtifactFixture.newer }
        await gate.block()
        return AndroidArtifactFixture.new
    }, convert: { _, _, output in try AndroidArtifactFixture.converted.write(to: output) })
    let registry = SpiderReplacementRegistry()
    let registration = DevelopmentAndroidRuntimeRegistration(stateRoot: fixture.root, registry: registry, arguments: [], artifactStore: store)
    let site = fixture.site()
    let olderRefresh = Task { try await registration.register(runtime: fixture.runtime, sites: [site]) }
    await gate.waitUntilBlocked()
    var changed = site
    changed.jar = fixture.reference(newer: true)
    do { try await registration.register(runtime: fixture.runtime, sites: [changed]) }
    catch { await gate.open(); throw error }
    let newestProvider = try #require(await registry.nativeProvider(for: changed) as? DevelopmentAndroidSiteProvider)
    await gate.open()
    await #expect(throws: CancellationError.self) { try await olderRefresh.value }
    #expect(await registration.effectiveProviderSHA256(site: changed) == fixture.sha(AndroidArtifactFixture.newer))
    let retained = try #require(await registry.nativeProvider(for: changed) as? DevelopmentAndroidSiteProvider)
    #expect(retained === newestProvider)
    await registration.shutdownAll()
}

@Test func developmentAndroidBundledArtifactOverrideRequiresAnExplicitAuditProcess() async throws {
    let fixture = try AndroidArtifactFixture()
    defer { fixture.remove() }
    var site = fixture.site()
    site.jar = "invalid-source-reference"
    let store = fixture.store(fetch: { _, _ in throw ArtifactFixtureFailure.unexpectedNetwork }, convert: { _, _, _ in throw ArtifactFixtureFailure.unexpectedConversion })
    let ordinaryRegistry = SpiderReplacementRegistry()
    let ordinary = DevelopmentAndroidRuntimeRegistration(stateRoot: fixture.root, registry: ordinaryRegistry,
        arguments: ["--android-provider-use-bundled-artifact"], artifactStore: store)
    try await ordinary.register(runtime: fixture.runtime, sites: [site])
    #expect(await ordinaryRegistry.executionBackend(for: site) == .androidUnavailable)
    let failure = try #require(await ordinaryRegistry.nativeProvider(for: site) as? DevelopmentAndroidArtifactFailureProvider)
    await #expect(throws: DevelopmentAndroidArtifactError.invalidReference) { try await failure.homeContent(site: site) }
    let registry = SpiderReplacementRegistry()
    let audit = DevelopmentAndroidRuntimeRegistration(stateRoot: fixture.root, registry: registry,
        arguments: ["--android-provider-audit", "--android-provider-use-bundled-artifact"], artifactStore: store)
    try await audit.register(runtime: fixture.runtime, sites: [site])
    #expect(await registry.nativeProvider(for: site) is DevelopmentAndroidSiteProvider)
    await audit.shutdownAll()
}

@Test func developmentAndroidArtifactCorruptCacheIsNotExecutedWhenTheSourceIsUnavailable() async throws {
    let fixture = try AndroidArtifactFixture()
    defer { fixture.remove() }
    let initial = fixture.store(fetch: { _, _ in AndroidArtifactFixture.new }, convert: { _, _, output in try AndroidArtifactFixture.converted.write(to: output) })
    let artifact = try await initial.resolve(declaration: fixture.reference(), runtime: fixture.runtime, bindings: [fixture.binding])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: artifact.converted.path)
    try Data("corrupt cache".utf8).write(to: artifact.converted)
    let retry = fixture.store(fetch: { _, _ in throw ArtifactFixtureFailure.unexpectedNetwork }, convert: { _, _, _ in throw ArtifactFixtureFailure.unexpectedConversion })
    await #expect(throws: DevelopmentAndroidArtifactError.downloadFailed) {
        try await retry.resolve(declaration: fixture.reference(), runtime: fixture.runtime, bindings: [fixture.binding])
    }
}

@Test func developmentAndroidArtifactRemoteChecksumIsBoundedAndValidatedBeforeDownload() async throws {
    let fixture = try AndroidArtifactFixture()
    defer { fixture.remove() }
    let store = fixture.store(fetch: { url, limit in
        if url.path.hasSuffix(".md5") { #expect(limit == 1024); return Data((fixture.md5(AndroidArtifactFixture.new) + "\n").utf8) }
        #expect(limit == DevelopmentAndroidArtifactStore.maximumBytes)
        return AndroidArtifactFixture.new
    }, convert: { _, _, output in try AndroidArtifactFixture.converted.write(to: output) })
    let artifact = try await store.resolve(declaration: "https://source.example.test/current.jar;md5;https://source.example.test/current.md5", runtime: fixture.runtime, bindings: [fixture.binding])
    #expect(artifact.sha256 == fixture.sha(AndroidArtifactFixture.new))
}

private enum ArtifactFixtureFailure: Error { case unexpectedNetwork, unexpectedConversion }
private actor ArtifactCounters {
    private(set) var fetches = 0
    private(set) var conversions = 0
    @discardableResult func fetched() -> Int { fetches += 1; return fetches }
    func converted() { conversions += 1 }
}

private actor ArtifactFetchGate {
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var blocked: CheckedContinuation<Void, Never>?
    func block() async {
        started = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
        await withCheckedContinuation { blocked = $0 }
    }
    func waitUntilBlocked() async {
        if started { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() { blocked?.resume(); blocked = nil }
}

@Test func developmentAndroidComponentUpdateRebuildsConversionOfUnchangedCompleteJAR() async throws {
    let fixture = try AndroidArtifactFixture()
    defer { fixture.remove() }
    let counters = ArtifactCounters()
    let store = fixture.store(fetch: { _, _ in await counters.fetched(); return AndroidArtifactFixture.new },
        convert: { _, _, output in await counters.converted(); try AndroidArtifactFixture.converted.write(to: output) })
    let first = try await store.resolve(declaration: fixture.reference(), runtime: fixture.runtime, bindings: [])
    let changed = DevelopmentAndroidRuntimeLayout(root: fixture.runtime.root, manifest: fixture.runtime.manifest,
        classPath: fixture.runtime.classPath, componentIdentity: String(repeating: "b", count: 64))
    let second = try await store.resolve(declaration: fixture.reference(), runtime: changed, bindings: [])
    #expect(first.sha256 == second.sha256 && first.converted != second.converted)
    #expect(await counters.conversions == 2)
    #expect(await counters.fetches == 2)
}

private struct AndroidArtifactFixture: Sendable {
    let root: URL
    let cache: URL
    let runtime: DevelopmentAndroidRuntimeLayout
    let binding = DevelopmentAndroidRuntimeManifest.Binding(key: "fixture", api: "csp_FixtureGuard", className: "com.github.catvod.spider.FixtureGuard")
    // Small ZIP fixtures. Their bytes never run; the injected converter models only converter I/O.
    static let old = Data(base64Encoded: "UEsDBBQAAAAAAAAAWF03DK/lCwAAAAsAAAALAAAAY2xhc3Nlcy5kZXhkZXgKMDM1AG9sZFBLAQIUAxQAAAAAAAAAWF03DK/lCwAAAAsAAAALAAAAAAAAAAAAAACAAQAAAABjbGFzc2VzLmRleFBLBQYAAAAAAQABADkAAAA0AAAAAAA=")!
    static let new = Data(base64Encoded: "UEsDBBQAAAAAAAAAWF2XnBGxCwAAAAsAAAALAAAAY2xhc3Nlcy5kZXhkZXgKMDM1AG5ld1BLAQIUAxQAAAAAAAAAWF2XnBGxCwAAAAsAAAALAAAAAAAAAAAAAACAAQAAAABjbGFzc2VzLmRleFBLBQYAAAAAAQABADkAAAA0AAAAAAA=")!
    static let newer = Data(base64Encoded: "UEsDBBQAAAAAAAAAWF2u7+EgDQAAAA0AAAALAAAAY2xhc3Nlcy5kZXhkZXgKMDM1AG5ld2VyUEsBAhQDFAAAAAAAAABYXa7v4SANAAAADQAAAAsAAAAAAAAAAAAAAIABAAAAAGNsYXNzZXMuZGV4UEsFBgAAAAABAAEAOQAAADYAAAAAAA==")!
    static let converted = Data(base64Encoded: "UEsDBBQAAAAAAAAAWF00aLugCwAAAAsAAAArAAAAY29tL2dpdGh1Yi9jYXR2b2Qvc3BpZGVyL0ZpeHR1cmVHdWFyZC5jbGFzc8r+ur5maXh0dXJlUEsBAhQDFAAAAAAAAABYXTRou6ALAAAACwAAACsAAAAAAAAAAAAAAIABAAAAAGNvbS9naXRodWIvY2F0dm9kL3NwaWRlci9GaXh0dXJlR3VhcmQuY2xhc3NQSwUGAAAAAAEAAQBZAAAAVAAAAAAA")!

    init(twoSites: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("android-artifact-test-" + UUID().uuidString, isDirectory: true)
        cache = root.appendingPathComponent("cache", isDirectory: true)
        let bundle = root.appendingPathComponent("runtime", isDirectory: true)
        for dir in ["inputs", "converted", "lib", "jdk/bin"] { try FileManager.default.createDirectory(at: bundle.appendingPathComponent(dir), withIntermediateDirectories: true) }
        try Self.old.write(to: bundle.appendingPathComponent("inputs/provider.jar"))
        try Self.converted.write(to: bundle.appendingPathComponent("converted/provider-jvm.jar"))
        for file in ["lib/macapk-loader.jar", "lib/android-framework.jar", "jdk/bin/java"] { try Data(file.utf8).write(to: bundle.appendingPathComponent(file)) }
        var bindings = [["key": "fixture", "api": "csp_FixtureGuard", "className": "com.github.catvod.spider.FixtureGuard"]]
        if twoSites { bindings.append(["key": "fixture-2", "api": "csp_FixtureGuard", "className": "com.github.catvod.spider.FixtureGuard"]) }
        let object: [String: Any] = ["schema": 1, "providerID": "android-runtime-experiment", "providerSHA256": SHA256.hash(data: Self.old).map { String(format: "%02x", $0) }.joined(), "hostSHA256": String(repeating: "a", count: 64), "bindings": bindings]
        let manifest = try JSONDecoder().decode(DevelopmentAndroidRuntimeManifest.self, from: JSONSerialization.data(withJSONObject: object))
        runtime = DevelopmentAndroidRuntimeLayout(root: bundle, manifest: manifest, classPath: [])
    }
    func store(fetch: @escaping DevelopmentAndroidArtifactStore.Fetch, convert: @escaping DevelopmentAndroidArtifactStore.Convert) -> DevelopmentAndroidArtifactStore {
        DevelopmentAndroidArtifactStore(root: cache, fetch: fetch, convert: convert)
    }
    var configurationRuntime: DevelopmentAndroidRuntimeLayout {
        let manifest = DevelopmentAndroidRuntimeManifest(schema: 2, providerID: "android-original-runtime",
            backend: "emulated", providerSHA256: runtime.manifest.providerSHA256,
            hostSHA256: runtime.manifest.hostSHA256, bindings: [], bootstrapClass: nil, package: nil)
        return DevelopmentAndroidRuntimeLayout(root: runtime.root, manifest: manifest, classPath: runtime.classPath)
    }
    func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    func md5(_ data: Data) -> String { Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    func reference(newer: Bool = false) -> String { "https://source.example.test/\(newer ? "newer" : "current").jar?token=secret-source-token;md5;" + md5(newer ? Self.newer : Self.new) }
    func site(key: String = "fixture") -> Site { Site(key: key, name: "Fixture", type: 3, api: binding.api, jar: reference()) }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
#endif
