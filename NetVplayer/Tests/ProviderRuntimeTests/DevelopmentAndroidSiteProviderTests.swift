#if DEBUG
import CryptoKit
import DriveEngine
import Foundation
import Models
import ProviderSDK
import ProviderRuntime
import ProxyServer
import Storage
import Testing
@testable import SpiderEngine

@Test func developmentAndroidLegacyOptInRequiresBooleanAndOtherwiseValidatesSignedTrust() async throws {
    let fixture = try DevelopmentAndroidBridgeFixture()
    defer { fixture.remove() }
    for flag: Any? in [nil, false, "true", 1] {
        let bundle = try fixture.bundle(flag: flag)
        try await DevelopmentAndroidSiteProvider.registerIfEnabled(sites: [fixture.site], bundle: bundle, preference: .androidPreferred,
            componentRuntime: { try await AndroidRuntimeComponentStore.application(bundle: $0).activeRuntime() })
        let unavailable = try #require(await SpiderReplacementRegistry.shared.nativeProvider(for: fixture.site) as? AndroidOriginalUnavailableProvider)
        #expect(unavailable.reason == .runtimeInvalid)
    }
    let enabled = try fixture.bundle(flag: true)
    try await DevelopmentAndroidSiteProvider.registerIfEnabled(sites: [fixture.site], bundle: enabled, preference: .androidPreferred,
        componentRuntime: { _ in
            Issue.record("A boolean legacy opt-in must use the bundled DEBUG runtime")
            return nil
        })
    let unavailable = try #require(await SpiderReplacementRegistry.shared.nativeProvider(for: fixture.site) as? AndroidOriginalUnavailableProvider)
    #expect(unavailable.reason == .runtimeInvalid)
}

@Test func developmentProviderPreferencesSelectOnlyTheirWholeImplementation() async throws {
    for preference in ProviderExecutionPreference.allCases {
        let fixture = try DevelopmentAndroidBridgeFixture()
        defer { fixture.remove() }
        let runtime = try DevelopmentAndroidRuntimeLayout.load(root: fixture.runtime)
        let registry = SpiderReplacementRegistry()
        let native = DevelopmentAndroidNativeRouteFixture()
        await registry.register(originalKey: fixture.site.key, originalAPI: fixture.site.api, provider: native)
        let arguments = preference == .androidPreferred ? ["--android-provider-audit", "--android-provider-use-bundled-artifact"] : []
        let registration = DevelopmentAndroidRuntimeRegistration(stateRoot: fixture.state, registry: registry, bundledArtifactForTesting: true, arguments: arguments)
        try await registration.register(runtime: runtime, sites: [fixture.site], preference: preference)
        let selected = try #require(await registry.nativeProvider(for: fixture.site))
        if preference == .macPreferred {
            #expect(selected as? DevelopmentAndroidNativeRouteFixture === native)
            #expect(await registry.executionBackend(for: fixture.site) == .macNative)
            _ = try await selected.homeContent(site: fixture.site)
            _ = try await selected.categoryContent(site: fixture.site, tid: "category", page: "1", filter: false, extend: [:])
            _ = try await selected.detailContent(site: fixture.site, id: "vod")
            _ = try await selected.playerContent(site: fixture.site, flag: "native-online", id: "native-episode")
            #expect(await native.operations == ["home", "category", "detail", "player"])
        } else {
            #expect(selected is DevelopmentAndroidSiteProvider)
            #expect(await registry.executionBackend(for: fixture.site) == .androidOriginal)
            #expect(await native.operations.isEmpty)
        }
        #expect(await registration.isRegistered(site: fixture.site) == (preference != .macPreferred))
        await registration.shutdownAll()
    }
}

@Test func developmentMacPreferenceKeepsAliasesWithoutAndroidFallback() async throws {
    let fixture = try DevelopmentAndroidBridgeFixture()
    defer { fixture.remove() }
    let runtime = try DevelopmentAndroidRuntimeLayout.load(root: fixture.runtime)
    let registry = SpiderReplacementRegistry()
    // Android registration cannot override Mac aliases even without an exact pair.
    await registry.register(originalAPI: fixture.site.api, provider: DevelopmentAndroidNativeRouteFixture())
    let registration = DevelopmentAndroidRuntimeRegistration(stateRoot: fixture.state, registry: registry, bundledArtifactForTesting: true, arguments: [])
    try await registration.register(runtime: runtime, sites: [fixture.site], preference: .macPreferred)
    #expect(await registry.executionBackend(for: fixture.site) == .macNative)
    #expect(await !registration.isRegistered(site: fixture.site))
    await registration.shutdownAll()
}

@Test func developmentAndroidPreferenceBypassesAllValidatedNativeBindings() async throws {
    let fixture = try DevelopmentAndroidBridgeFixture()
    defer { fixture.remove() }
    try fixture.writeManifest(changes: ["bindings": nativeRouteBindings])
    let runtime = try DevelopmentAndroidRuntimeLayout.load(root: fixture.runtime)
    let registry = SpiderReplacementRegistry()
    let sites = nativeRouteBindings.map { Site(key: $0["key"]!, name: "Route", type: 3, api: $0["api"]!) }
    for site in sites { await registry.register(originalKey: site.key, originalAPI: site.api, provider: DevelopmentAndroidNativeRouteFixture()) }
    let registration = DevelopmentAndroidRuntimeRegistration(stateRoot: fixture.state, registry: registry, bundledArtifactForTesting: true,
        arguments: ["--android-provider-audit", "--android-provider-use-bundled-artifact"])
    try await registration.register(runtime: runtime, sites: sites, preference: .androidPreferred)
    for site in sites {
        #expect(await registration.isRegistered(site: site))
        #expect(await registry.executionBackend(for: site) == .androidOriginal)
    }
    await registration.shutdownAll()
}

@Test func developmentAndroidOriginalDerivesUnlistedBindingsAndNeverUsesNativeAliases() async throws {
    let fixture = try DevelopmentAndroidBridgeFixture()
    defer { fixture.remove() }
    let runtime = try DevelopmentAndroidRuntimeLayout.load(root: fixture.runtime)
    var site = fixture.site
    site.key += "-new-source"
    site.api = "csp_NewGuard"
    let selectedRuntime = runtime.selectingOriginalBindings(sites: [site])
    let binding = try #require(selectedRuntime.manifest.bindings.first)
    #expect(binding.className == "com.github.catvod.spider.NewGuard")
    #expect(runtime.manifest.bindings.first?.className == "com.github.catvod.spider.FixtureGuard")
    #expect(!runtime.manifest.bindings.contains(binding))
    let command = try selectedRuntime.command(binding: binding, stateDirectory: fixture.state)
    #expect(command.arguments.contains("-Dnetvplayer.android.providerClass=com.github.catvod.spider.NewGuard"))
    let registry = SpiderReplacementRegistry()
    let native = DevelopmentAndroidNativeRouteFixture()
    await registry.register(originalAPI: site.api, provider: native)
    await registry.register(originalKey: site.key, originalAPI: site.api, provider: native)
    let registration = DevelopmentAndroidRuntimeRegistration(stateRoot: fixture.state, registry: registry, bundledArtifactForTesting: true,
        arguments: ["--android-provider-audit", "--android-provider-use-bundled-artifact"])
    try await registration.register(runtime: runtime, sites: [site], preference: .androidPreferred)
    let provider = try #require(await registry.nativeProvider(for: site) as? DevelopmentAndroidSiteProvider)
    do {
        _ = try await provider.homeContent(site: site)
        let category = try await provider.categoryContent(site: site, tid: "category", page: "1", filter: false, extend: [:])
        #expect(category.list.first?.vodId == "category")
        #expect(await registry.executionBackend(for: site) == .androidOriginal)
        #expect(await native.operations.isEmpty)
        await registration.shutdownAll()
    } catch {
        await registration.shutdownAll()
        throw error
    }
}

@Test func developmentAndroidOriginalRejectsMissingInputsInsteadOfFallingBackToNative() async throws {
    let fixture = try DevelopmentAndroidBridgeFixture()
    defer { fixture.remove() }
    let runtime = try DevelopmentAndroidRuntimeLayout.load(root: fixture.runtime)
    let registry = SpiderReplacementRegistry()
    let native = DevelopmentAndroidNativeRouteFixture()
    var script = fixture.site
    script.key += "-script"
    script.api = "https://fixture.example.test/original.py"
    let sites = [fixture.site, script]
    for site in sites { await registry.register(originalKey: site.key, originalAPI: site.api, provider: native) }
    // A bundled-input flag alone must not make a normal session execute an old
    // bundled business artifact when its configuration declares no JAR.
    let registration = DevelopmentAndroidRuntimeRegistration(stateRoot: fixture.state, registry: registry, bundledArtifactForTesting: false,
        arguments: ["--android-provider-use-bundled-artifact"])
    try await registration.register(runtime: runtime, sites: sites, preference: .androidPreferred)
    for (site, reason) in [(fixture.site, AndroidOriginalUnavailableReason.missingProviderArtifact), (script, .unsupportedSourceAPI)] {
        let provider = try #require(await registry.nativeProvider(for: site) as? AndroidOriginalUnavailableProvider)
        #expect(provider.reason == reason)
        #expect(await registry.executionBackend(for: site) == .androidUnavailable)
        #expect(await !registration.isRegistered(site: site))
        await #expect(throws: ProviderErrorPayload.self) { try await provider.homeContent(site: site) }
        await #expect(throws: ProviderErrorPayload.self) { try await provider.homeVideoContent(site: site) }
        await #expect(throws: ProviderErrorPayload.self) { try await provider.categoryContent(site: site, tid: "1", page: "1", filter: true, extend: [:]) }
        await #expect(throws: ProviderErrorPayload.self) { try await provider.detailContent(site: site, id: "id") }
        await #expect(throws: ProviderErrorPayload.self) { try await provider.playerContent(site: site, flag: "flag", id: "id") }
        await #expect(throws: ProviderErrorPayload.self) { try await provider.searchContent(site: site, keyword: "query", quick: false, page: "1") }
        await #expect(throws: ProviderErrorPayload.self) { try await provider.action(site: site, action: "action", value: "value") }
    }
    #expect(await native.operations.isEmpty)
}

@Test func developmentAndroidOriginalReportsInvalidTrustAndPreservesIndependentInterfaces() async throws {
    let fixture = try DevelopmentAndroidBridgeFixture()
    defer { fixture.remove() }
    let bundle = try fixture.bundle(flag: false)
    await SpiderReplacementRegistry.shared.register(originalKey: fixture.site.key, originalAPI: fixture.site.api,
        provider: DevelopmentAndroidNativeRouteFixture())
    try await DevelopmentAndroidSiteProvider.registerIfEnabled(sites: [fixture.site], bundle: bundle, preference: .androidPreferred,
        componentRuntime: { try await AndroidRuntimeComponentStore.application(bundle: $0).activeRuntime() })
    let selected = try #require(await SpiderReplacementRegistry.shared.nativeProvider(for: fixture.site) as? AndroidOriginalUnavailableProvider)
    #expect(selected.reason == .runtimeInvalid)
    let registry = SpiderReplacementRegistry()
    let native = DevelopmentAndroidNativeRouteFixture()
    let sites = [Site(key: "local", name: "Local", type: 3, api: "netvplayer-local"),
                 Site(key: "cms", name: "CMS", type: 1, api: "https://cms.example.test")]
    for site in sites { await registry.register(originalKey: site.key, originalAPI: site.api, provider: native) }
    await AndroidOriginalProviderPolicy.registerUnavailable(sites: sites, reason: .runtimeUnavailable, registry: registry)
    for site in sites { #expect(await registry.nativeProvider(for: site) as? DevelopmentAndroidNativeRouteFixture === native) }
}

@Test func developmentAndroidPreparationFailurePreservesOtherSourcesAndCanRetry() async throws {
    let fixture = try DevelopmentAndroidBridgeFixture(); defer { fixture.remove() }
    let bundle = try fixture.bundle(flag: false)
    let registry = SpiderReplacementRegistry.shared
    let native = DevelopmentAndroidNativeRouteFixture()
    var android = fixture.site
    android.key += "-unavailable"
    let independent = Site(key: fixture.site.key + "-local", name: "Local", type: 3, api: "netvplayer-local")
    for site in [fixture.site, independent] {
        await registry.register(originalKey: site.key, originalAPI: site.api, provider: native)
    }
    try await DevelopmentAndroidSiteProvider.registerIfEnabled(sites: [fixture.site, android, independent], bundle: bundle,
        componentRuntime: { _ in
            Issue.record("Mac mode must not prepare Android, even if preparation would fail")
            throw AndroidRuntimePreparationError.failed
        })
    for site in [fixture.site, independent] {
        #expect(await registry.nativeProvider(for: site) as? DevelopmentAndroidNativeRouteFixture === native)
    }
    #expect(await registry.nativeProvider(for: android) == nil)
    // The preference must still be honored if the user explicitly chose Android.
    try await DevelopmentAndroidSiteProvider.registerIfEnabled(sites: [fixture.site], bundle: bundle, preference: .androidPreferred,
        componentRuntime: { _ in throw AndroidRuntimePreparationError.failed })
    #expect(await registry.nativeProvider(for: fixture.site) is AndroidOriginalUnavailableProvider)
}

@Test func developmentAndroidOriginalInvalidRuntimeShowsComponentFailureWithoutNativeFallback() async throws {
    let fixture = try DevelopmentAndroidBridgeFixture(); defer { fixture.remove() }
    let bundle = try fixture.bundle(flag: true) // Enabled but missing runtime files.
    let native = DevelopmentAndroidNativeRouteFixture()
    await SpiderReplacementRegistry.shared.register(originalKey: fixture.site.key, originalAPI: fixture.site.api, provider: native)
    var site = fixture.site
    site.jar = "https://fixture.example.test/provider.jar"
    try await DevelopmentAndroidSiteProvider.registerIfEnabled(sites: [site], bundle: bundle, preference: .androidPreferred)
    let selected = try #require(await SpiderReplacementRegistry.shared.nativeProvider(for: fixture.site) as? AndroidOriginalUnavailableProvider)
    #expect(selected.reason == .runtimeInvalid)
    await #expect(throws: ProviderErrorPayload.self) { try await selected.homeContent(site: fixture.site) }
    #expect(await native.operations.isEmpty)
}

@Test func developmentAndroidOriginalClassNamesFollowTheConfiguredJavaAPI() {
    for (api, expected) in [("csp_NewGuard", "com.github.catvod.spider.NewGuard"),
                            ("org.example.Provider$Nested", "org.example.Provider$Nested"),
                            ("https://fixture.example.test/api.js?version=1", "com.fongmi.quickjs.crawler.Spider")] {
        #expect(AndroidOriginalProviderPolicy.className(for: Site(key: "key", name: "name", type: 3, api: api)) == expected)
    }
    for api in ["csp_", "csp_Bad/Guard", "com.example.Provider\n", "https://example.test/provider.py", "https://example.test/provider.py?next=.js", "netvplayer-local"] {
        #expect(AndroidOriginalProviderPolicy.className(for: Site(key: "key", name: "name", type: 3, api: api)) == nil)
    }
}

@Test func developmentAndroidRuntimePreservesValidatedModulePathsWhenSelectingSources() throws {
    let fixture = try DevelopmentAndroidBridgeFixture(); defer { fixture.remove() }
    for file in ["inputs/quickjs.apk", "converted/quickjs-jvm.jar"] {
        try Data("controlled module".utf8).write(to: fixture.runtime.appendingPathComponent(file))
    }
    try fixture.writeManifest(changes: ["modules": ["quickjs"]])
    let runtime = try DevelopmentAndroidRuntimeLayout.load(root: fixture.runtime)
    let selected = runtime.selectingOriginalBindings(sites: [fixture.site])
    #expect(selected.manifest.modules == ["quickjs"])
    let command = try selected.command(binding: #require(selected.manifest.bindings.first), stateDirectory: fixture.state)
    #expect(command.arguments.contains { $0.hasPrefix("-Dnetvplayer.android.classPath=") && $0.contains("converted/quickjs-jvm.jar") && $0.contains("inputs/quickjs.apk") })
    try fixture.writeManifest(changes: ["modules": ["../outside"]])
    #expect(throws: (any Error).self) { try DevelopmentAndroidRuntimeLayout.load(root: fixture.runtime) }
}

@Test func developmentAndroidRegistrationIsExactAndSurvivesProcessShutdown() async throws {
    let fixture = try DevelopmentAndroidBridgeFixture()
    defer { fixture.remove() }
    let bundle = try fixture.bundle(flag: true)
    let resources = try #require(bundle.resourceURL)
    try FileManager.default.copyItem(at: fixture.runtime, to: resources.appendingPathComponent("AndroidProviderRuntime"))
    var unlisted = fixture.site
    unlisted.key += "-unlisted"
    unlisted.api = "csp_Unlisted" + UUID().uuidString.replacingOccurrences(of: "-", with: "") + "Guard"
    let runtime = try DevelopmentAndroidRuntimeLayout.load(root: resources.appendingPathComponent("AndroidProviderRuntime"))
    // AppState configuration tests clear the shared registry's content caches concurrently.
    // This lifecycle fixture owns its registry so unrelated cleanup cannot retire its request.
    let registry = SpiderReplacementRegistry()
    let registration = DevelopmentAndroidRuntimeRegistration(stateRoot: fixture.state, registry: registry, bundledArtifactForTesting: true)
    try await registration.register(runtime: runtime, sites: [fixture.site, unlisted])
    let firstMatch = await registry.nativeProvider(for: fixture.site)
    let first = try #require(firstMatch as? DevelopmentAndroidSiteProvider)
    let missingMatch = await registry.nativeProvider(for: unlisted)
    #expect(missingMatch is DevelopmentAndroidSiteProvider)
    await registration.shutdownAll()
    let secondMatch = await registry.nativeProvider(for: fixture.site)
    let second = try #require(secondMatch as? DevelopmentAndroidSiteProvider)
    #expect(first === second)
    do {
        let player = try await first.playerContent(site: fixture.site, flag: "fixture", id: "proxy-fixture")
        let local = try #require(URLComponents(string: player.url))
        var parameters = Dictionary(uniqueKeysWithValues: (local.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(local.host == "127.0.0.1" && local.path == "/proxy")
        #expect(parameters["url"] == nil && parameters["u64"] == nil)
        #expect(parameters["siteKey"] == fixture.site.key && parameters["siteAPI"] == fixture.site.api)
        let generic = ProxyPlaybackHandler.makeHandlers()
        #expect(try await generic.prefetched(parameters) == nil)
        #expect(try await generic.buffered(parameters) == nil)
        let streamed = try await generic.streaming(parameters, { _ in Issue.record("Unexpected generic response") }, { _ in Issue.record("Unexpected generic body") })
        #expect(!streamed)
        parameters["host"] = "player-request-context.invalid"
        parameters["authorization"] = "secret-fixture-marker"
        parameters["url"] = "https://unexpected.example.test/"
        parameters["__downstream_range"] = "bytes=0-99"
        let response = try #require(try await registration.proxyResponse(parameters: parameters))
        #expect(response.statusCode == 200)
        let forwarded = try JSONDecoder().decode([String: String].self, from: response.data)
        #expect(forwarded["do"] == "fixture")
        #expect(forwarded["url"] == "https://media.example.test/proxy.m3u8?token=a+b&part=1")
        #expect(forwarded["headers"] == "{\"User-Agent\":\"Fixture\"}")
        #expect(forwarded["range"] == "bytes=0-99")
        #expect(forwarded["host"] == nil && forwarded["authorization"] == nil && forwarded["siteKey"] == nil)
        var forged = parameters
        forged[DevelopmentAndroidCatVodProxyAdapter.routeKey] = UUID().uuidString
        await #expect(throws: ProviderErrorPayload.self) { try await registration.proxyResponse(parameters: forged) }
        var invalidRange = parameters
        invalidRange["__downstream_range"] = "bytes=-"
        await #expect(throws: ProviderErrorPayload.self) { try await registration.proxyResponse(parameters: invalidRange) }
        var wrongAPI = parameters
        wrongAPI["siteAPI"] = "csp_OtherGuard"
        await #expect(throws: ProviderErrorPayload.self) {
            try await registration.proxyResponse(parameters: wrongAPI)
        }
        var signedRoute = parameters
        signedRoute.removeValue(forKey: DevelopmentAndroidCatVodProxyAdapter.markerKey)
        #expect(try await registration.proxyResponse(parameters: signedRoute) == nil)
        await registration.shutdownAll()
        await #expect(throws: ProviderErrorPayload.self) {
            try await registration.proxyResponse(parameters: parameters)
        }
        let logs = FileManager.default.enumerator(at: fixture.state, includingPropertiesForKeys: nil)?.allObjects
            .compactMap { $0 as? URL }.filter { $0.lastPathComponent == "operations.jsonl" } ?? []
        let proxyCalls = try logs.flatMap { try String(contentsOf: $0, encoding: .utf8).split(separator: "\n") }
            .filter { $0.contains("\"operation\": \"proxy\"") }
        #expect(proxyCalls.count == 1)
    } catch {
        await registration.shutdownAll()
        throw error
    }
}

@Test func developmentAndroidRuntimeRejectsUnpinnedOrExternalInputs() throws {
    let fixture = try DevelopmentAndroidBridgeFixture()
    defer { fixture.remove() }
    _ = try DevelopmentAndroidRuntimeLayout.load(root: fixture.runtime)
    try Data("changed provider".utf8).write(to: fixture.runtime.appendingPathComponent("inputs/provider.jar"))
    #expect(throws: DevelopmentAndroidRuntimeError.self) { try DevelopmentAndroidRuntimeLayout.load(root: fixture.runtime) }
    try Data("provider fixture".utf8).write(to: fixture.runtime.appendingPathComponent("inputs/provider.jar"))
    let outside = fixture.root.appendingPathComponent("outside.jar")
    try Data("provider fixture".utf8).write(to: outside)
    let input = fixture.runtime.appendingPathComponent("inputs/provider.jar")
    try FileManager.default.removeItem(at: input)
    try FileManager.default.createSymbolicLink(at: input, withDestinationURL: outside)
    #expect(throws: DevelopmentAndroidRuntimeError.self) { try DevelopmentAndroidRuntimeLayout.load(root: fixture.runtime) }
}

@Test func developmentMacRegistrationPreservesCompleteNativeSources() async throws {
    let fixture = try DevelopmentAndroidBridgeFixture()
    defer { fixture.remove() }
    let bindings = nativeRouteBindings
    try fixture.writeManifest(changes: ["bindings": bindings + [fixture.bindingJSON]])
    let runtime = try DevelopmentAndroidRuntimeLayout.load(root: fixture.runtime)
    let registry = SpiderReplacementRegistry()
    let native = DevelopmentAndroidNativeRouteFixture()
    let sites = bindings.map { Site(key: $0["key"]!, name: "Native route", type: 3, api: $0["api"]!) }
    for site in sites {
        await registry.register(originalKey: site.key, originalAPI: site.api, provider: native)
    }
    let registration = DevelopmentAndroidRuntimeRegistration(stateRoot: fixture.state, registry: registry, bundledArtifactForTesting: true, arguments: [])
    try await registration.register(runtime: runtime, sites: sites + [fixture.site], preference: .macPreferred)
    for site in sites {
        let selected = try #require(await registry.nativeProvider(for: site))
        #expect(selected as? DevelopmentAndroidNativeRouteFixture === native)
        #expect(await !registration.isRegistered(site: site))
        _ = try await selected.homeContent(site: site)
        _ = try await selected.categoryContent(site: site, tid: "native-category", page: "1", filter: false, extend: [:])
        let detail = try await selected.detailContent(site: site, id: "native-vod")
        #expect(detail.list.first?.vodPlayUrl == "第01集$native-episode")
        let player = try await selected.playerContent(site: site, flag: "native-online", id: "native-episode")
        #expect(player.url == "https://media.example.test/native.m3u8")
    }
    #expect(await native.operations == Array(repeating: ["home", "category", "detail", "player"], count: sites.count).flatMap { $0 })
    #expect(await !registration.isRegistered(site: fixture.site))
    #expect(await registry.nativeProvider(for: fixture.site) == nil)
    #expect(!FileManager.default.fileExists(atPath: fixture.state.appendingPathComponent("operations.jsonl").path))
    // Re-registering a refreshed config and shutting helpers down must retain
    // the same native objects and their coherent detail/player ID contract.
    try await registration.register(runtime: runtime, sites: sites + [fixture.site], preference: .macPreferred)
    await registration.shutdownAll()
    for site in sites {
        #expect(await registry.nativeProvider(for: site) as? DevelopmentAndroidNativeRouteFixture === native)
    }
}

@Test func developmentAndroidModeIgnoresNativeIdentityMatches() async throws {
    let fixture = try DevelopmentAndroidBridgeFixture()
    defer { fixture.remove() }
    for original in nativeRouteBindings {
        let variants = [
            ["key": original["key"]! + "-copy", "api": original["api"]!, "className": original["className"]!],
            ["key": original["key"]!, "api": original["api"]! + "Other", "className": original["className"]!],
            ["key": original["key"]!, "api": original["api"]!, "className": "com.github.catvod.spider.OtherGuard"]
        ]
        for binding in variants {
            try fixture.writeManifest(changes: ["bindings": [binding]])
            let runtime = try DevelopmentAndroidRuntimeLayout.load(root: fixture.runtime)
            let registry = SpiderReplacementRegistry()
            let site = Site(key: binding["key"]!, name: "Changed identity", type: 3, api: binding["api"]!)
            await registry.register(originalKey: site.key, originalAPI: site.api, provider: DevelopmentAndroidNativeRouteFixture())
            let registration = DevelopmentAndroidRuntimeRegistration(stateRoot: fixture.state, registry: registry, bundledArtifactForTesting: true, arguments: [])
            try await registration.register(runtime: runtime, sites: [site])
            #expect(await registration.isRegistered(site: site))
            #expect(await registry.nativeProvider(for: site) is DevelopmentAndroidSiteProvider)
            await registration.shutdownAll()
        }
        // Android owns the route even when a Mac alias exists.
        try fixture.writeManifest(changes: ["bindings": [original]])
        let runtime = try DevelopmentAndroidRuntimeLayout.load(root: fixture.runtime)
        let registry = SpiderReplacementRegistry()
        let site = Site(key: original["key"]!, name: "No keyed native", type: 3, api: original["api"]!)
        await registry.register(originalAPI: site.api, provider: DevelopmentAndroidNativeRouteFixture())
        let registration = DevelopmentAndroidRuntimeRegistration(stateRoot: fixture.state, registry: registry, bundledArtifactForTesting: true, arguments: [])
        try await registration.register(runtime: runtime, sites: [site])
        #expect(await registration.isRegistered(site: site))
        #expect(await registry.nativeProvider(for: site) is DevelopmentAndroidSiteProvider)
        await registration.shutdownAll()
    }
}

@Test func developmentMacModeCannotBeOverriddenByAndroidAuditFlags() async throws {
    let fixture = try DevelopmentAndroidBridgeFixture()
    defer { fixture.remove() }
    for binding in nativeRouteBindings {
        try fixture.writeManifest(changes: ["bindings": [binding]])
        let runtime = try DevelopmentAndroidRuntimeLayout.load(root: fixture.runtime)
        let site = Site(key: binding["key"]!, name: "Audit route", type: 3, api: binding["api"]!)
        for arguments in [["--android-provider-force-android"], ["--android-provider-audit"],
                          ["--android-provider-audit", "--android-provider-force-android"]] {
            let registry = SpiderReplacementRegistry()
            let native = DevelopmentAndroidNativeRouteFixture()
            await registry.register(originalKey: site.key, originalAPI: site.api, provider: native)
            let registration = DevelopmentAndroidRuntimeRegistration(stateRoot: fixture.state, registry: registry, bundledArtifactForTesting: true, arguments: arguments)
            try await registration.register(runtime: runtime, sites: [site], preference: .macPreferred)
            #expect(await !registration.isRegistered(site: site))
            let selected = try #require(await registry.nativeProvider(for: site))
            #expect(selected as? DevelopmentAndroidNativeRouteFixture === native)
            await registration.shutdownAll()
        }
    }
}

@Test func developmentMacNativeRouteSurvivesConfigurationReloads() async throws {
    let fixture = try DevelopmentAndroidBridgeFixture()
    defer { fixture.remove() }
    let binding = ["key": "风云", "api": "csp_FyGuard", "className": "com.github.catvod.spider.FyGuard"]
    try fixture.writeManifest(changes: ["bindings": [binding]])
    let runtime = try DevelopmentAndroidRuntimeLayout.load(root: fixture.runtime)
    let site = Site(key: "风云", name: "风云", type: 3, api: "csp_FyGuard")
    let registry = SpiderReplacementRegistry()
    #if !NETVPLAYER_INCLUDE_PRIVATE_PROVIDERS
    let native = DevelopmentAndroidNativeRouteFixture()
    #endif
    let registration = DevelopmentAndroidRuntimeRegistration(stateRoot: fixture.state, registry: registry, bundledArtifactForTesting: true, arguments: [])
    for _ in 0..<2 {
        #if NETVPLAYER_INCLUDE_PRIVATE_PROVIDERS
        await registry.registerBuiltInNativeProviders()
        #else
        await registry.register(originalKey: site.key, originalAPI: site.api, provider: native)
        #endif
        try await registration.register(runtime: runtime, sites: [site], preference: .macPreferred)
        #if NETVPLAYER_INCLUDE_PRIVATE_PROVIDERS
        #expect(await registry.nativeProvider(for: site) is FyNativeProvider)
        #else
        #expect(await registry.nativeProvider(for: site) as? DevelopmentAndroidNativeRouteFixture === native)
        #endif
        #expect(await !registration.isRegistered(site: site))
    }
    #expect(await registry.nativeProvider(for: Site(key: "风云-copy", name: "Other", type: 3, api: "csp_FyGuard")) == nil)
    #expect(!FileManager.default.fileExists(atPath: fixture.state.appendingPathComponent("operations.jsonl").path))
    await registration.shutdownAll()
}

@Test func developmentAndroidRuntimeRejectsNativeAndDuplicateBindings() throws {
    let fixture = try DevelopmentAndroidBridgeFixture()
    defer { fixture.remove() }
    for changes in [
        ["schema": 2],
        ["backend": "native"],
        ["providerID": "netvplayer.catalog.java"],
        ["bindings": [fixture.bindingJSON, fixture.bindingJSON]],
        ["bindings": [["key": fixture.site.key, "api": fixture.site.api, "className": "bad;class"]]]
    ] as [[String: Any]] {
        try fixture.writeManifest(changes: changes)
        #expect(throws: DevelopmentAndroidRuntimeError.self) { try DevelopmentAndroidRuntimeLayout.load(root: fixture.runtime) }
    }
}

@Test func developmentAndroidCommandUsesMovableBundleAndPrivateState() throws {
    let fixture = try DevelopmentAndroidBridgeFixture()
    defer { fixture.remove() }
    let runtime = try DevelopmentAndroidRuntimeLayout.load(root: fixture.runtime)
    let binding = try #require(runtime.manifest.bindings.first)
    let command = try runtime.command(binding: binding, stateDirectory: fixture.state)
    #expect(command.executableURL.path == fixture.runtime.appendingPathComponent("jdk/bin/java").path)
    #expect(command.currentDirectoryURL == fixture.state)
    #expect(command.stateDirectoryURL == fixture.state)
    #expect(command.arguments.contains("-Dnetvplayer.android.backend=emulated"))
    #expect(command.arguments.contains("--add-exports=java.base/sun.net.www.protocol.http=ALL-UNNAMED"))
    #expect(command.arguments.contains("--add-exports=java.base/sun.net.www.protocol.https=ALL-UNNAMED"))
    #expect(command.arguments.contains("-Dnetvplayer.android.providerClass=" + binding.className))
    #expect(command.arguments.contains("-Dnetvplayer.android.dataDir=" + fixture.state.appendingPathComponent("data").path))
    #expect(command.environment["NETVPLAYER_PROVIDER_ROOT"] == fixture.runtime.path)
    #expect(command.environment["NETVPLAYER_PROVIDER_STATE"] == fixture.state.path)
    #expect(!command.arguments.contains(where: { $0.contains("/private/tmp/macapk") || $0.contains("-noverify") || $0.contains("libmacapk-bionic-shim") }))
    let relocated = fixture.root.appendingPathComponent("moved runtime", isDirectory: true)
    try FileManager.default.moveItem(at: fixture.runtime, to: relocated)
    let moved = try DevelopmentAndroidRuntimeLayout.load(root: relocated)
    let movedCommand = try moved.command(binding: binding, stateDirectory: fixture.state)
    #expect(movedCommand.executableURL.path.hasPrefix(relocated.path + "/"))
    #expect(!movedCommand.arguments.contains(where: { $0.contains(fixture.runtime.path) }))
}

@Test func developmentAndroidCommandUsesAppOwnedPresentationOnlyWithDesktopFramework() throws {
    let fixture = try DevelopmentAndroidBridgeFixture()
    defer { fixture.remove() }
    let archive = fixture.root.appendingPathComponent("android-presentation.jar")
    let theme = fixture.root.appendingPathComponent("theme.properties")
    try Data("fixture".utf8).write(to: archive)
    try Data("background=080411".utf8).write(to: theme)
    AndroidDialogPresentation.configure(.init(archive: archive, theme: theme, darkAppearance: true))
    let runtime = try DevelopmentAndroidRuntimeLayout.load(root: fixture.runtime)
    let binding = try #require(runtime.manifest.bindings.first)
    let unsupported = try runtime.command(binding: binding, stateDirectory: fixture.state)
    #expect(!unsupported.arguments.contains("-Dnetvplayer.android.themeFile=" + theme.path))
    try Data("{}".utf8).write(to: fixture.runtime.appendingPathComponent("desktop-ui-framework-provenance.json"))
    let supported = try runtime.command(binding: binding, stateDirectory: fixture.state, authorizationDrive: .quark)
    let classPathIndex = try #require(supported.arguments.firstIndex(of: "-cp")) + 1
    #expect(supported.arguments[classPathIndex].hasPrefix(archive.path + ":"))
    #expect(supported.arguments.contains("-Dnetvplayer.android.themeFile=" + theme.path))
    #expect(supported.arguments.contains("-Dnetvplayer.android.authorizationDrive=quark"))
    #expect(supported.arguments.contains("-Dapple.awt.application.appearance=NSAppearanceNameDarkAqua"))
    let anonymous = try runtime.command(binding: binding, stateDirectory: fixture.state)
    #expect(!anonymous.arguments.contains(where: { $0.hasPrefix("-Dnetvplayer.android.authorizationDrive=") }))
    AndroidDialogPresentation.configure(.init(archive: archive, theme: theme, darkAppearance: false))
    let light = try runtime.command(binding: binding, stateDirectory: fixture.state, authorizationDrive: .p115)
    #expect(light.arguments.contains("-Dapple.awt.application.appearance=NSAppearanceNameAqua"))
    #expect(!light.arguments.contains(where: { $0.hasPrefix("-Dnetvplayer.android.authorizationDrive=") }))
    try FileManager.default.removeItem(at: archive)
    let missing = try runtime.command(binding: binding, stateDirectory: fixture.state)
    #expect(!missing.arguments.contains("-Dnetvplayer.android.themeFile=" + theme.path))
    #expect(missing.arguments.contains("-Dnetvplayer.android.desktopUI=true"))
}

@Test func developmentAndroidPersistentSessionUsesSourceConfigurationAndStableRuntimeRoots() throws {
    let fixture = try DevelopmentAndroidBridgeFixture()
    defer { fixture.remove() }
    let runtime = try DevelopmentAndroidRuntimeLayout.load(root: fixture.runtime)
    let binding = try #require(runtime.manifest.bindings.first)
    let session = try runtime.persistentDataDirectory(base: fixture.state, binding: binding, site: fixture.site)
    var decorated = fixture.site
    decorated.name = "Renamed"
    decorated.timeout = 43
    decorated.searchable = 0
    #expect(session == (try runtime.persistentDataDirectory(base: fixture.state, binding: binding, site: decorated)))
    var changed = fixture.site
    changed.ext = "different-source-configuration"
    #expect(session != (try runtime.persistentDataDirectory(base: fixture.state, binding: binding, site: changed)))
    let other = DevelopmentAndroidRuntimeManifest.Binding(key: binding.key + "-other", api: binding.api, className: binding.className)
    #expect(session != (try runtime.persistentDataDirectory(base: fixture.state, binding: other, site: fixture.site)))
    let command = try runtime.command(binding: binding, stateDirectory: fixture.state, persistentDataDirectory: session)
    let permissions = try FileManager.default.attributesOfItem(atPath: session.path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o700)
    #expect(command.arguments.contains("-Dnetvplayer.android.persistentDataDir=" + session.path))
    #expect(command.arguments.contains("-Duser.home=" + session.appendingPathComponent(".runtime/home").path))
    #expect(command.arguments.contains("-Djava.util.prefs.userRoot=" + session.appendingPathComponent(".runtime/java-prefs").path))
    #expect(command.arguments.contains("-Dnetvplayer.android.sourceIdentity=" + DevelopmentAndroidSiteProvider.sourceIdentity(site: fixture.site)))
    #expect(!command.arguments.contains(where: { $0.contains("different-source-configuration") }))
    // Updating SDK/component bytes replaces executable caches, never login state.
    try Data("replacement-conversion".utf8).write(to: fixture.runtime.appendingPathComponent("converted/provider-jvm.jar"))
    #expect(session == (try runtime.persistentDataDirectory(base: fixture.state, binding: binding, site: fixture.site)))
}

@Test func developmentAndroidRemovedSourcesRetireTheirHelpersAndStaleReferences() async throws {
    let fixture = try DevelopmentAndroidBridgeFixture()
    defer { fixture.remove() }
    let runtime = try DevelopmentAndroidRuntimeLayout.load(root: fixture.runtime)
    let registry = SpiderReplacementRegistry()
    let registration = DevelopmentAndroidRuntimeRegistration(stateRoot: fixture.state, registry: registry, bundledArtifactForTesting: true, arguments: [])
    try await registration.register(runtime: runtime, sites: [fixture.site])
    let removed = try #require(await registry.exactNativeProvider(for: fixture.site) as? DevelopmentAndroidSiteProvider)
    _ = try await removed.homeContent(site: fixture.site)
    try await registration.register(runtime: runtime, sites: [])
    #expect(await registry.exactNativeProvider(for: fixture.site) == nil)
    #expect(await !registration.isRegistered(site: fixture.site))
    await #expect(throws: DevelopmentAndroidRuntimeError.closed) { try await removed.homeContent(site: fixture.site) }
    let logs = try #require(FileManager.default.enumerator(at: fixture.state, includingPropertiesForKeys: nil))
        .allObjects.compactMap { $0 as? URL }.filter { $0.lastPathComponent == "operations.jsonl" }
    let events = try logs.flatMap { try String(contentsOf: $0, encoding: .utf8).split(separator: "\n") }
    #expect(events.filter { $0.contains("\"operation\": \"destroy\"") }.count == 1)
    #expect(events.filter { $0.contains("\"operation\": \"handshake\"") }.count == 1)
}

@Test func developmentAndroidHostReplacementRetiresOldArtifactEvenWithSameProviderSHA() async throws {
    let fixture = try DevelopmentAndroidBridgeFixture()
    defer { fixture.remove() }
    let first = try DevelopmentAndroidRuntimeLayout.load(root: fixture.runtime)
    let registry = SpiderReplacementRegistry()
    let registration = DevelopmentAndroidRuntimeRegistration(stateRoot: fixture.state, registry: registry, bundledArtifactForTesting: true, arguments: [])
    try await registration.register(runtime: first, sites: [fixture.site])
    let previous = try #require(await registry.exactNativeProvider(for: fixture.site) as? DevelopmentAndroidSiteProvider)
    _ = try await previous.homeContent(site: fixture.site)
    let data = Data("different-host-fixture".utf8)
    try data.write(to: fixture.runtime.appendingPathComponent("inputs/host.apk"))
    try fixture.writeManifest(changes: ["hostSHA256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()])
    let second = try DevelopmentAndroidRuntimeLayout.load(root: fixture.runtime)
    #expect(first.providerSHA256 == second.providerSHA256)
    try await registration.register(runtime: second, sites: [fixture.site])
    let current = try #require(await registry.exactNativeProvider(for: fixture.site) as? DevelopmentAndroidSiteProvider)
    #expect(previous !== current)
    await #expect(throws: DevelopmentAndroidRuntimeError.closed) { try await previous.homeContent(site: fixture.site) }
    _ = try await current.homeContent(site: fixture.site)
    await registration.shutdownAll()
}

@Test func developmentAndroidRejectedInitializationNeverReusesTheFailedLoader() async throws {
    let fixture = try DevelopmentAndroidBridgeFixture()
    defer { fixture.remove() }
    let runtime = try DevelopmentAndroidRuntimeLayout.load(root: fixture.runtime)
    let provider = DevelopmentAndroidSiteProvider(runtime: runtime, binding: try #require(runtime.manifest.bindings.first), stateDirectory: fixture.state)
    var rejected = fixture.site
    rejected.ext = "reject-init"
    for _ in 0..<2 {
        await #expect(throws: ProviderErrorPayload.self) { try await provider.homeContent(site: rejected) }
    }
    _ = try await provider.homeContent(site: fixture.site)
    await provider.shutdown()
    let events = try String(contentsOf: fixture.state.appendingPathComponent("operations.jsonl"), encoding: .utf8).split(separator: "\n")
    #expect(events.filter { $0.contains("\"operation\": \"handshake\"") }.count == 3)
    #expect(events.filter { $0.contains("\"operation\": \"home\"") }.count == 1)
}

@Test func developmentAndroidNormalRegistrationsRetainStateWhileAuditsStayFresh() async throws {
    let fixture = try DevelopmentAndroidBridgeFixture()
    defer { fixture.remove() }
    let runtime = try DevelopmentAndroidRuntimeLayout.load(root: fixture.runtime)
    let registry = SpiderReplacementRegistry()
    for arguments in [[], [], ["--android-provider-audit"], ["--android-provider-audit"]] {
        let registration = DevelopmentAndroidRuntimeRegistration(stateRoot: fixture.state, registry: registry, bundledArtifactForTesting: true, arguments: arguments)
        try await registration.register(runtime: runtime, sites: [fixture.site])
        let provider = try #require(await registry.exactNativeProvider(for: fixture.site) as? DevelopmentAndroidSiteProvider)
        _ = try await provider.homeContent(site: fixture.site)
        await registration.shutdownAll()
    }
    let logs = try #require(FileManager.default.enumerator(at: fixture.state, includingPropertiesForKeys: nil))
        .allObjects.compactMap { $0 as? URL }.filter { $0.lastPathComponent == "operations.jsonl" }
    let events = try logs.flatMap { try String(contentsOf: $0, encoding: .utf8).split(separator: "\n") }
        .map { try JSONDecoder().decode([String: String].self, from: Data($0.utf8)) }.filter { $0["operation"] == "init" }
    let groups = Dictionary(grouping: events, by: { $0["state_sha256"] ?? "missing" })
    #expect(events.count == 4 && groups.count == 3)
    #expect(!groups.keys.contains("missing"))
    #expect(groups.values.map(\.count).sorted() == [1, 1, 2])
}

@Test func developmentAndroidBridgeSerializesConfigurationAndPropagatesErrors() async throws {
    let fixture = try DevelopmentAndroidBridgeFixture()
    defer { fixture.remove() }
    let runtime = try DevelopmentAndroidRuntimeLayout.load(root: fixture.runtime)
    let provider = DevelopmentAndroidSiteProvider(runtime: runtime, binding: try #require(runtime.manifest.bindings.first), stateDirectory: fixture.state)
    do {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<12 {
                var site = fixture.site
                site.ext = "configuration-\(index)"
                group.addTask {
                    let result = try await provider.homeContent(site: site)
                    #expect(result.url == site.ext)
                }
            }
            try await group.waitForAll()
        }
        let homeVideo = try await provider.homeVideoContent(site: fixture.site)
        #expect(homeVideo == nil)
        let category = try await provider.categoryContent(site: fixture.site, tid: "category-2", page: "3", filter: true, extend: ["type": "动作"])
        #expect(category.list.first?.vodId == "category-2")
        let player = try await provider.playerContent(site: fixture.site, flag: "direct", id: "episode-1")
        #expect(player.url == "https://media.example.test/direct.m3u8")
        #expect(player.header["User-Agent"] == "Fixture")
        await #expect(throws: ProviderErrorPayload.self) {
            try await provider.action(site: fixture.site, action: "fixture", value: "reject")
        }
        var other = fixture.site
        other.api = "csp_OtherGuard"
        await #expect(throws: DevelopmentAndroidRuntimeError.siteMismatch) { try await provider.homeContent(site: other) }
        await provider.shutdown()
        let reopened = try await provider.homeContent(site: fixture.site)
        #expect(reopened.url == fixture.site.ext)
        await provider.shutdown()
        let events = try String(contentsOf: fixture.state.appendingPathComponent("operations.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try JSONDecoder().decode([String: String].self, from: Data($0.utf8)) }
        // Every changed configuration gets its own JVM: original JNI classes
        // cannot be initialized under a second defining loader in the same VM.
        #expect(events.filter { $0["operation"] == "handshake" }.count == 14)
        #expect(events.filter { $0["operation"] == "destroy" }.count == 2)
        #expect(events.filter { $0["operation"] == "init" }.count == 14)
        for index in events.indices where events[index]["operation"] == "home" {
            #expect(index > 0 && events[index - 1]["operation"] == "init")
            #expect(events[index]["extend"] == events[index - 1]["extend"])
        }
    } catch {
        await provider.shutdown()
        throw error
    }
}

@Test func developmentAndroidOriginalCommandKeepsHTTPInTheOriginalHost() throws {
    let fixture = try DevelopmentAndroidBridgeFixture()
    defer { fixture.remove() }
    for className in ["com.github.catvod.spider.FixtureGuard", "com.github.catvod.spider.SeedhubGuard", "com.github.catvod.spider.T4Guard"] {
        var bindingJSON = fixture.bindingJSON
        bindingJSON["className"] = className
        try fixture.writeManifest(changes: ["bindings": [bindingJSON]])
        let runtime = try DevelopmentAndroidRuntimeLayout.load(root: fixture.runtime)
        let command = try runtime.command(binding: #require(runtime.manifest.bindings.first), stateDirectory: fixture.state)
        #expect(!command.arguments.contains(where: { $0.contains("sourceTransportBase") || $0.contains("seedTransportBase") }))
    }
}

@Test func developmentAndroidBridgeDecodesCatVodJSONStringsAndStringHeaders() async throws {
    let fixture = try DevelopmentAndroidBridgeFixture()
    defer { fixture.remove() }
    let runtime = try DevelopmentAndroidRuntimeLayout.load(root: fixture.runtime)
    let provider = DevelopmentAndroidSiteProvider(runtime: runtime, binding: try #require(runtime.manifest.bindings.first), stateDirectory: fixture.state)
    do {
        for mode in ["wire-json", "wire-double-json", "wire-bom-json"] {
            var site = fixture.site
            site.ext = mode
            let home = try await provider.homeContent(site: site)
            #expect(home.types.first?.typeId == "wire-category")
            #expect(home.list.first?.vodId == "wire-vod")
            let homeVideo = try await provider.homeVideoContent(site: site)
            #expect(homeVideo?.list.first?.vodName == "CatVod JSON fixture")
            let category = try await provider.categoryContent(site: site, tid: "wire-category", page: "1", filter: true, extend: [:])
            #expect(category.list.first?.vodId == "wire-vod")
            let search = try await provider.searchContent(site: site, keyword: "fixture", quick: false, page: "1")
            #expect(search.list.first?.vodId == "wire-vod")
            let detail = try await provider.detailContent(site: site, id: mode)
            #expect(detail.list.first?.vodName == "CatVod JSON fixture")
            let player = try await provider.playerContent(site: site, flag: "direct", id: "wire-episode")
            #expect(player.url == "https://media.example.test/catvod.m3u8")
            #expect(player.header == ["User-Agent": "CatVod fixture", "Referer": "https://catalog.example.test/"])
        }
        var emptyHeaderSite = fixture.site
        emptyHeaderSite.ext = "wire-empty-header"
        let emptyHeader = try await provider.playerContent(site: emptyHeaderSite, flag: "direct", id: "wire-episode")
        #expect(emptyHeader.header.isEmpty)
        await provider.shutdown()
    } catch {
        await provider.shutdown()
        throw error
    }
}

@Test func developmentAndroidBridgeRejectsInvalidCatVodStringsWithoutExposingPayload() async throws {
    let fixture = try DevelopmentAndroidBridgeFixture()
    defer { fixture.remove() }
    let runtime = try DevelopmentAndroidRuntimeLayout.load(root: fixture.runtime)
    let provider = DevelopmentAndroidSiteProvider(runtime: runtime, binding: try #require(runtime.manifest.bindings.first), stateDirectory: fixture.state)
    do {
        for (mode, code) in [
            ("wire-invalid-json", "invalid_android_result"),
            ("wire-empty", "invalid_android_result"),
            ("wire-array", "invalid_android_result"),
            ("wire-wrappers", "invalid_android_result"),
            ("wire-invalid-header", "invalid_android_header")
        ] {
            var site = fixture.site
            site.ext = mode
            do {
                _ = try await provider.homeContent(site: site)
                Issue.record("Expected rejection of \(mode)")
            } catch let error as ProviderErrorPayload {
                #expect(error.code == code)
                #expect(!error.message.contains("secret-fixture-marker"))
                #expect(!error.message.contains("https://"))
            }
        }
        for mode in ["wire-empty", "wire-null", "wire-null-json"] {
            var site = fixture.site
            site.ext = mode
            let result = try await provider.homeVideoContent(site: site)
            #expect(result == nil)
        }
        await provider.shutdown()
    } catch {
        await provider.shutdown()
        throw error
    }
}

@Test func developmentAndroidBridgePreservesAndLocalizesEveryLabelledQuality() async throws {
    let fixture = try DevelopmentAndroidBridgeFixture()
    defer { fixture.remove() }
    let runtime = try DevelopmentAndroidRuntimeLayout.load(root: fixture.runtime)
    let provider = DevelopmentAndroidSiteProvider(runtime: runtime, binding: try #require(runtime.manifest.bindings.first), stateDirectory: fixture.state)
    do {
        let result = try await provider.playerContent(site: fixture.site, flag: "B站", id: "quality-array")
        #expect(result.playbackCandidates.map(\.name) == ["清晰 480P", "流畅 360P"])
        #expect(result.playbackCandidates.allSatisfy { $0.isPlayable })
        #expect(result.url == result.playbackCandidates.first?.url && !result.url.isEmpty)
        var routeIDs = Set<String>()
        for (index, candidate) in result.playbackCandidates.enumerated() {
            let components = try #require(URLComponents(string: candidate.url))
            let parameters = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            routeIDs.insert(try #require(parameters[DevelopmentAndroidCatVodProxyAdapter.routeKey]))
            #expect(parameters["quality"] == nil && !candidate.url.contains("secret-fixture"))
            #expect(candidate.headers == ["User-Agent": "Fixture quality"])
            let response = try await provider.proxyRoute(site: fixture.site, parameters: parameters)
            let forwarded = try JSONDecoder().decode([String: String].self, from: response.data)
            #expect(forwarded["quality"] == (index == 0 ? "480" : "360"))
            #expect(forwarded["headers"]?.contains("Fixture quality") == true)
        }
        #expect(routeIDs.count == 2)
        for id in ["quality-odd", "quality-mixed", "quality-empty", "quality-control"] {
            do {
                _ = try await provider.playerContent(site: fixture.site, flag: "B站", id: id)
                Issue.record("Expected rejection of invalid quality array")
            } catch let error as ProviderErrorPayload {
                #expect(error.code == "invalid_android_player_urls")
                #expect(!error.message.contains("secret-fixture"))
            }
        }
        await provider.shutdown()
    } catch {
        await provider.shutdown()
        throw error
    }
}

@Test func developmentAndroidBridgeLocalizesProxySubtitlesAndPreservesOtherSubtitleSources() async throws {
    let fixture = try DevelopmentAndroidBridgeFixture()
    defer { fixture.remove() }
    let runtime = try DevelopmentAndroidRuntimeLayout.load(root: fixture.runtime)
    let provider = DevelopmentAndroidSiteProvider(runtime: runtime, binding: try #require(runtime.manifest.bindings.first), stateDirectory: fixture.state)
    do {
        let result = try await provider.playerContent(site: fixture.site, flag: "fixture", id: "subtitle-fixture")
        #expect(result.url == "https://media.example.test/direct.m3u8")
        #expect(result.subs.map(\.name) == ["歌词", "Translation", "Remote", "Inline"])
        #expect(result.danmaku.map(\.name) == ["XML", "Remote", "SDK server"])
        #expect(result.danmaku[2].url == "http://127.0.0.1:6677/proxy?do=danmu&url=opaque-sdk-input")
        #expect(result.danmaku[1].url == "https://comments.example.test/d.xml?signature=a%2Bb")
        let dm = try #require(URLComponents(string: result.danmaku[0].url))
        let dmParameters = Dictionary(uniqueKeysWithValues: (dm.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(!result.danmaku[0].url.contains("secret-fixture"))
        let dmResponse = try await provider.proxyRoute(site: fixture.site, parameters: dmParameters)
        let dmForwarded = try JSONDecoder().decode([String: String].self, from: dmResponse.data)
        #expect(dmForwarded["do"] == "dm" && dmForwarded["token"] == "secret-fixture-dm")
        #expect(dmForwarded["headers"] == nil || dmForwarded["headers"] == "{}")
        #expect(result.subs.map(\.format) == ["text/x-ssa", "ssa", "srt", "ass"])
        #expect(result.subs[0].lang == "zh" && result.subs[1].lang == "en")
        #expect(result.subs[2].url == "https://subtitle.example.test/remote.srt")
        #expect(result.subs[3].url == "data:text/x-ssa;base64,Zml4dHVyZQ==")
        var routes: [[String: String]] = []
        for (index, subtitle) in result.subs.prefix(2).enumerated() {
            let components = try #require(URLComponents(string: subtitle.url))
            #expect(components.host == "127.0.0.1" && components.path == "/proxy")
            #expect(components.port != -1)
            let parameters = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            #expect(parameters["csp"] == nil && parameters["token"] == nil)
            #expect(!subtitle.url.contains("secret-fixture"))
            let response = try await provider.proxyRoute(site: fixture.site, parameters: parameters)
            let forwarded = try JSONDecoder().decode([String: String].self, from: response.data)
            #expect(forwarded["do"] == "ssa" && forwarded["csp"] == "FixtureGuard")
            #expect(forwarded["track"] == String(index))
            #expect(forwarded["token"] == "secret-fixture-lyrics")
            #expect(forwarded["headers"]?.contains("Fixture subtitles") == true)
            routes.append(parameters)
        }
        #expect(routes[0][DevelopmentAndroidCatVodProxyAdapter.routeKey] != routes[1][DevelopmentAndroidCatVodProxyAdapter.routeKey])
        await provider.shutdown()
        await #expect(throws: (any Error).self) { try await provider.proxyRoute(site: fixture.site, parameters: routes[0]) }
    } catch {
        await provider.shutdown()
        throw error
    }
}

@Test func developmentAndroidBridgeKeepsProxySubtitlesOnEveryPlaybackQuality() async throws {
    let fixture = try DevelopmentAndroidBridgeFixture()
    defer { fixture.remove() }
    let runtime = try DevelopmentAndroidRuntimeLayout.load(root: fixture.runtime)
    let provider = DevelopmentAndroidSiteProvider(runtime: runtime, binding: try #require(runtime.manifest.bindings.first), stateDirectory: fixture.state)
    do {
        let result = try await provider.playerContent(site: fixture.site, flag: "fixture", id: "quality-subtitles")
        #expect(result.playbackCandidates.count == 2)
        #expect(result.subs.count == 1)
        #expect(result.subs.first?.url == result.playbackCandidates.first?.subtitles.first?.url)
        for candidate in result.playbackCandidates {
            let subtitle = try #require(candidate.subtitles.first)
            #expect(candidate.subtitles.count == 1 && subtitle.name == "歌词" && subtitle.format == "text/x-ssa")
            let components = try #require(URLComponents(string: subtitle.url))
            let parameters = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            let response = try await provider.proxyRoute(site: fixture.site, parameters: parameters)
            let forwarded = try JSONDecoder().decode([String: String].self, from: response.data)
            #expect(forwarded["do"] == "ssa" && forwarded["csp"] == "FixtureGuard")
            #expect(forwarded["headers"]?.contains("Fixture quality") == true)
        }
        await provider.shutdown()
    } catch {
        await provider.shutdown()
        throw error
    }
}

@Test(arguments: ["numbered-subtitles-direct", "numbered-subtitles-qualities"])
func developmentAndroidBridgeOmitsOtherEpisodesFromSubtitleTracks(mode: String) async throws {
    let fixture = try DevelopmentAndroidBridgeFixture()
    defer { fixture.remove() }
    let runtime = try DevelopmentAndroidRuntimeLayout.load(root: fixture.runtime)
    let provider = DevelopmentAndroidSiteProvider(runtime: runtime, binding: try #require(runtime.manifest.bindings.first), stateDirectory: fixture.state)
    var site = fixture.site
    site.ext = mode
    do {
        let result = try await provider.playerContent(
            site: site, flag: "fixture", id: #"{"path":"%2FExample.S03E49%2FSeries.S01E200.mkv"}"#
        )
        let expected = ["series.S1E0200.zh.srt", "中文", "Series.S01E199-E200", "Series.S01E199.S01E200", "Other.S01E79"]
        #expect(result.subs.map(\.name) == expected)
        #expect(result.playbackCandidates.count == (mode == "numbered-subtitles-qualities" ? 2 : 0))
        for candidate in result.playbackCandidates {
            #expect(candidate.subtitles.map(\.name) == expected)
        }
        let current = try #require(result.subs.first)
        #expect(current.lang == "zh" && current.format == "application/x-subrip")
        let components = try #require(URLComponents(string: current.url))
        let parameters = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let response = try await provider.proxyRoute(site: site, parameters: parameters)
        let forwarded = try JSONDecoder().decode([String: String].self, from: response.data)
        #expect(forwarded["track"] == "0")

        let unnumbered = try await provider.playerContent(
            site: site, flag: "fixture", id: #"{"path":"%2FSeries.S01E200%2Fmovie.mkv"}"#
        )
        #expect(unnumbered.subs.contains { $0.name == "Series.S01E79" })
        await provider.shutdown()
    } catch {
        await provider.shutdown()
        throw error
    }
}

@Test func developmentAndroidOriginalForwardsOpaqueDriveAndStateIDsToGuard() async throws {
    let fixture = try DevelopmentAndroidBridgeFixture()
    defer { fixture.remove() }
    let runtime = try DevelopmentAndroidRuntimeLayout.load(root: fixture.runtime)
    let provider = DevelopmentAndroidSiteProvider(runtime: runtime, binding: try #require(runtime.manifest.bindings.first), stateDirectory: fixture.state)
    let ids = ["netvplayer-drive://quark/file?fid=incomplete", "netvplayer-pending://episode/0/0/0",
               "netvplayer-unavailable://remote-provider-drive-share?reason=fixture", "magnet:?xt=urn:btih:fixture"]
    do {
        for id in ids {
            let result = try await provider.playerContent(site: fixture.site, flag: "夸克", id: id)
            #expect(result.url == "https://media.example.test/direct.m3u8")
        }
        await provider.shutdown()
        let events = try String(contentsOf: fixture.state.appendingPathComponent("operations.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try JSONDecoder().decode([String: String].self, from: Data($0.utf8)) }
        #expect(events.filter { $0["operation"] == "player" }.map { $0["id"]! } == ids)
    } catch { await provider.shutdown(); throw error }
}

@Test func developmentAndroidCatVodProxyLocalizesOnlyKnownLoopbackDescriptors() throws {
    let fixture = try DevelopmentAndroidBridgeFixture()
    defer { fixture.remove() }
    let runtime = try DevelopmentAndroidRuntimeLayout.load(root: fixture.runtime)
    let binding = try #require(runtime.manifest.bindings.first)
    let target = "https://media.example.test/master.m3u8?token=a+b&part=1"
    let headers = "{\"User-Agent\":\"Fixture + 中文\"}"
    var originalQuery = URLComponents()
    originalQuery.queryItems = [
        URLQueryItem(name: "do", value: "fixture"), URLQueryItem(name: "url", value: target),
        URLQueryItem(name: "headers", value: headers), URLQueryItem(name: "token", value: "a+b&c=1"),
        URLQueryItem(name: "from", value: "untrusted"), URLQueryItem(name: "siteKey", value: "other-site"),
        URLQueryItem(name: "providerID", value: "signed-provider"), URLQueryItem(name: "__context", value: "unused")
    ]
    for authority in ["127.0.0.1:-1", "localhost:9978", "127.0.0.1:9979", "[::1]:9999"] {
        let input = Result(url: "http://" + authority + "/proxy?" + (originalQuery.percentEncodedQuery ?? ""), parse: 1, jx: 1,
            flag: "fixture", header: ["X-Player-Context": "unused"], key: "other-site")
        let route = try #require(try DevelopmentAndroidCatVodProxyAdapter.localize(input, site: fixture.site, binding: binding,
            providerID: runtime.manifest.providerID, routeID: "fixture-route", proxyAddress: "http://127.0.0.1:9986/proxy"))
        let localized = try #require(URLComponents(string: route.result.url))
        let values = Dictionary(uniqueKeysWithValues: (localized.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(localized.host == "127.0.0.1" && localized.port == 9986 && localized.path == "/proxy")
        #expect(values["from"] == "catvod" && values["siteKey"] == fixture.site.key)
        #expect(values["providerID"] == runtime.manifest.providerID && values["android_route"] == "fixture-route")
        #expect(values["url"] == nil && values["u64"] == nil && values["headers"] == nil)
        #expect(route.parameters == ["do": "fixture", "url": target, "headers": headers, "token": "a+b&c=1"])
        #expect(route.result.header == input.header && route.result.parse == 0 && route.result.jx == 0)
        #expect(route.result.key == fixture.site.key && route.result.flag == "fixture")
        #expect(!route.result.url.contains("media.example.test"))
    }
    let input = Result(url: "http://127.0.0.1:-1/proxy?do=fixture&url=opaque-value", header: ["User-Agent": "Fixture"])
    let route = try #require(try DevelopmentAndroidCatVodProxyAdapter.localize(input, site: fixture.site, binding: binding,
        providerID: runtime.manifest.providerID, routeID: "header-fixture"))
    let recoveredHeaders = try JSONDecoder().decode([String: String].self, from: Data(try #require(route.parameters["headers"]).utf8))
    #expect(recoveredHeaders == input.header)
}

@Test func developmentAndroidCatVodProxyRejectsUnsafeOrUnboundDescriptors() throws {
    let fixture = try DevelopmentAndroidBridgeFixture()
    defer { fixture.remove() }
    let runtime = try DevelopmentAndroidRuntimeLayout.load(root: fixture.runtime)
    let binding = try #require(runtime.manifest.bindings.first)
    for url in [
        "http://127.0.0.1:8080/proxy?do=fixture&url=opaque",
        "http://127.0.0.1:-2/proxy?do=fixture&url=opaque",
        "http://127.0.0.1/proxy?do=fixture&url=opaque",
        "https://localhost:9978/proxy?do=fixture&url=opaque",
        "http://localhost:9978/proxy?do=fixture&url=a&url=b",
        "http://localhost:9978/proxy?url=opaque",
        "http://localhost:9978/proxy?do=fixture&url=opaque#fragment"
    ] {
        #expect(throws: ProviderErrorPayload.self) {
            try DevelopmentAndroidCatVodProxyAdapter.localize(Result(url: url), site: fixture.site, binding: binding,
                providerID: runtime.manifest.providerID, routeID: "fixture")
        }
    }
    for url in [
        "https://media.example.test/proxy?do=fixture&url=opaque",
        "http://127.0.0.1.evil.example:9978/proxy?do=fixture&url=opaque",
        "http://127.0.0.1:9978/other?do=fixture&url=opaque",
        "http://user@127.0.0.1:9978/proxy?do=fixture&url=opaque"
    ] {
        let route = try DevelopmentAndroidCatVodProxyAdapter.localize(Result(url: url), site: fixture.site, binding: binding,
            providerID: runtime.manifest.providerID, routeID: "fixture")
        #expect(route == nil)
    }
    let input = Result(url: "http://127.0.0.1:-1/proxy?do=fixture&url=opaque")
    #expect(throws: ProviderErrorPayload.self) {
        try DevelopmentAndroidCatVodProxyAdapter.localize(input, site: fixture.site, binding: binding,
            providerID: "netvplayer.catalog.java", routeID: "fixture")
    }
    var wrongSite = fixture.site
    wrongSite.api = "csp_OtherGuard"
    #expect(throws: ProviderErrorPayload.self) {
        try DevelopmentAndroidCatVodProxyAdapter.localize(input, site: wrongSite, binding: binding,
            providerID: runtime.manifest.providerID, routeID: "fixture")
    }
}

@Test func developmentAndroidOriginalPreservesShippedEpisodeParsingAndRawStrings() async throws {
    let fixture = try DevelopmentAndroidBridgeFixture()
    defer { fixture.remove() }
    let runtime = try DevelopmentAndroidRuntimeLayout.load(root: fixture.runtime)
    let provider = DevelopmentAndroidSiteProvider(runtime: runtime, binding: try #require(runtime.manifest.bindings.first), stateDirectory: fixture.state)
    var site = fixture.site
    site.ext = "original-episode-parsing"
    do {
        let result = try await provider.detailContent(site: site, id: "original-vod")
        let vod = try #require(result.list.first)
        #expect(vod.originalAndroidEpisodeParsing)
        #expect(vod.vodPlayFrom == " original ")
        #expect(vod.vodPlayUrl == "bare#  label  $ raw$id #$named")
        #expect(vod.parseFlags().map(\.name) == ["original"])
        #expect(vod.parseFlags()[0].episodes.map(\.name) == ["01", "label", "03"])
        #expect(vod.parseFlags()[0].episodes.map(\.url) == ["bare", " raw$id ", "named"])
        let cached = try JSONDecoder().decode(Result.self, from: JSONEncoder().encode(result))
        #expect(cached.list[0].parseFlags()[0].episodes.map(\.url) == ["bare", " raw$id ", "named"])
        await provider.shutdown()
        let events = try String(contentsOf: fixture.state.appendingPathComponent("operations.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try JSONDecoder().decode([String: String].self, from: Data($0.utf8)) }
        #expect(events.filter { $0["operation"] == "player" }.isEmpty)
    } catch { await provider.shutdown(); throw error }
}

@Test func developmentAndroidOriginalForwardsEveryDriveEpisodeWithoutNativeConversion() async throws {
    let fixture = try DevelopmentAndroidBridgeFixture()
    defer { fixture.remove() }
    let runtime = try DevelopmentAndroidRuntimeLayout.load(root: fixture.runtime)
    let provider = DevelopmentAndroidSiteProvider(runtime: runtime, binding: try #require(runtime.manifest.bindings.first), stateDirectory: fixture.state)
    let ali: [String: ProviderJSONValue] = ["drive_id": .string("owner"), "parent_file_id": .string("parent"),
        "sToken": .string("session"), "size": .number(4096), "file_id": .string("exact-file"), "sub": .string(""),
        "sId": .string("exact-share"), "name": .string("197.mp4"), "flag": .string("阿狸盘"), "vodName": .string("Fixture")]
    var uc = DevelopmentAndroidBridgeFixture.quarkEpisode
    uc["flag"] = .string("UC")
    let cases = [("夸父原1", DevelopmentAndroidBridgeFixture.quarkEpisode), ("阿狸原", ali), ("UC原", uc)]
    var ids = [String]()
    do {
        for (flag, episode) in cases {
            let id = "  " + String(decoding: try JSONEncoder.providerCanonical.encode(episode), as: UTF8.self) + " "
            ids.append(id)
            let result = try await provider.playerContent(site: fixture.site, flag: flag, id: id)
            #expect(result.url == "https://media.example.test/direct.m3u8")
        }
        await provider.shutdown()
        let events = try String(contentsOf: fixture.state.appendingPathComponent("operations.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try JSONDecoder().decode([String: String].self, from: Data($0.utf8)) }
        let players = events.filter { $0["operation"] == "player" }
        #expect(players.map { $0["id"]! } == ids)
        #expect(players.map { $0["flag"]! } == cases.map { $0.0 })
    } catch { await provider.shutdown(); throw error }
}

@Test func developmentAndroidQuarkEpisodeLeavesUnmatchedContractsToGuard() async throws {
    let fixture = try DevelopmentAndroidBridgeFixture()
    defer { fixture.remove() }
    let runtime = try DevelopmentAndroidRuntimeLayout.load(root: fixture.runtime)
    let provider = DevelopmentAndroidSiteProvider(runtime: runtime, binding: try #require(runtime.manifest.bindings.first), stateDirectory: fixture.state)
    let original = DevelopmentAndroidBridgeFixture.quarkEpisode
    var missing = original
    missing.removeValue(forKey: "share_fid_token")
    let cases: [(String, [String: ProviderJSONValue])] = [
        ("UC", original), ("夸父原1", missing),
        ("夸父原1", original.merging(["flag": .string("UC")]) { _, new in new }),
        ("夸父原1", original.merging(["sId": .string("fixture-share/../other")]) { _, new in new }),
        ("夸父原1", original.merging(["fid": .number(7)]) { _, new in new }),
        ("夸父原1", original.merging(["size": .number(-1)]) { _, new in new }),
        ("夸父原1", original.merging(["uc_token": .string("unknown-schema")]) { _, new in new })
    ]
    do {
        for (flag, episode) in cases {
            let id = String(decoding: try JSONEncoder.providerCanonical.encode(episode), as: UTF8.self)
            let result = try await provider.playerContent(site: fixture.site, flag: flag, id: id)
            #expect(result.url == "https://media.example.test/direct.m3u8")
        }
        await provider.shutdown()
        let events = try String(contentsOf: fixture.state.appendingPathComponent("operations.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try JSONDecoder().decode([String: String].self, from: Data($0.utf8)) }
        #expect(events.filter { $0["operation"] == "player" }.count == cases.count)
    } catch {
        await provider.shutdown()
        throw error
    }
}

@Test func developmentAndroidQuarkEpisodeAcceptsOnlyObservedFlags() throws {
    let id = String(decoding: try JSONEncoder.providerCanonical.encode(DevelopmentAndroidBridgeFixture.quarkEpisode), as: UTF8.self)
    for flag in ["夸父原", "夸父智", "夸父原1", "夸父智1", "夸父原2", "夸父智12"] {
        #expect(DevelopmentAndroidQuarkEpisodeAdapter.reference(id: id, flag: flag) != nil)
    }
    for flag in ["夸父盘", "夸父原0", "夸父智0", "夸父原01", "夸父智01", "夸父原-1", "夸父智1 extra", " 夸父原1", "夸父原１", "夸父原\n", "夸父智\r\n", "夸父原1\n", "夸父智1\r\n", "夸父原" + String(repeating: "1", count: 24)] {
        #expect(DevelopmentAndroidQuarkEpisodeAdapter.reference(id: id, flag: flag) == nil)
    }
}

@Test func developmentAndroidAllliveFoldersPreserveOriginalCategoryIDsForEveryAPI() async throws {
    let fixture = try DevelopmentAndroidBridgeFixture()
    defer { fixture.remove() }
    for api in ["csp_AllliveGuard", "csp_FixtureGuard"] {
        var site = fixture.site
        site.api = api
        site.ext = "alllive-folders"
        try fixture.writeManifest(changes: ["bindings": [["key": site.key, "api": api, "className": "com.github.catvod.spider.FixtureGuard"]]])
        let runtime = try DevelopmentAndroidRuntimeLayout.load(root: fixture.runtime)
        let provider = DevelopmentAndroidSiteProvider(runtime: runtime, binding: try #require(runtime.manifest.bindings.first),
            stateDirectory: fixture.state.appendingPathComponent(api))
        do {
            let result = try await provider.categoryContent(site: site, tid: "huya", page: "1", filter: true, extend: [:])
            let ids = result.list.map(\.vodId)
            let folders = ["huya_1", "huya_862", "douyu_2", "bilibili_3:4"]
            #expect(Array(ids.prefix(4)) == folders)
            #expect(Array(ids.dropFirst(4)) == ["huya_123", "huya_9", "other_1", "huya_room", "huya_", "huya_10", "huya_1_2"])
            let nested = try await provider.categoryContent(site: site, tid: "huya_1", page: "1", filter: true, extend: [:])
            #expect(nested.list.first?.vodId == "huya_1")
            await provider.shutdown()
        } catch {
            await provider.shutdown()
            throw error
        }
    }
}

@Test func developmentAndroidCatVodFolderSemanticsMatchTheOriginalHost() async throws {
    let fixture = try DevelopmentAndroidBridgeFixture()
    defer { fixture.remove() }
    let runtime = try DevelopmentAndroidRuntimeLayout.load(root: fixture.runtime)
    var site = fixture.site
    site.ext = "catvod-folders"
    let provider = DevelopmentAndroidSiteProvider(runtime: runtime,
        binding: try #require(runtime.manifest.bindings.first), stateDirectory: fixture.state)
    let opaqueID = " opaque/+%20= "
    let jsonID = #" { "file_id":"原样/+", "meta":{"value":"%2F\\n"} } "#
    do {
        let result = try await provider.searchContent(site: site, keyword: "fixture", quick: false, page: "1")
        #expect(result.list.map(\.vodId) == [opaqueID, jsonID, "room", "case-sensitive", "play-from", "play-url", "", "cate", "null-cate", "forged"])
        #expect(result.list.map(\.isFolder) == [true, true, false, false, true, true, true, true, false, false])
        #expect(result.list[4].vodPlayFrom == "fixture")
        #expect(result.list[5].vodPlayUrl == "fixture$episode")
        // categoryContent must forward the original JSON string, without URL
        // conversion, trimming, or re-encoding the embedded JSON object.
        let nested = try await provider.categoryContent(site: site, tid: jsonID, page: "1", filter: true, extend: [:])
        #expect(nested.list.first?.vodId == jsonID)
        #expect(nested.list.first?.isFolder == false)
        await provider.shutdown()
    } catch {
        await provider.shutdown()
        throw error
    }
}

@Test func developmentAndroidOriginalRetainsShareDetailsAndPagePlayerResults() async throws {
    let fixture = try DevelopmentAndroidBridgeFixture()
    defer { fixture.remove() }
    var binding = fixture.bindingJSON
    binding["className"] = "com.github.catvod.spider.DoubaoGuard"
    try fixture.writeManifest(changes: ["bindings": [binding]])
    let runtime = try DevelopmentAndroidRuntimeLayout.load(root: fixture.runtime)
    let provider = DevelopmentAndroidSiteProvider(runtime: runtime, binding: try #require(runtime.manifest.bindings.first), stateDirectory: fixture.state)
    var site = fixture.site
    site.ext = "original-detail"
    do {
        let detail = try await provider.detailContent(site: site, id: " original/+%2F ")
        #expect(detail.list.first?.vodId == " original/+%2F ")
        #expect(detail.list.first?.vodPlayUrl == "原链接$https://pan.quark.cn/s/fixture-share?pwd=A%2Bb")
        let player = try await provider.playerContent(site: site, flag: "same-line", id: "original-page")
        #expect(player.url == "https://live.doubao.example.test/play/123")
        #expect(player.parse == 1 && player.jx == 1 && player.format == "text/html")
        #expect(player.header == ["User-Agent": "Original page", "Referer": "https://fixture.test/"])
        await provider.shutdown()
    } catch { await provider.shutdown(); throw error }
}

@Test(arguments: ["uc-stale-empty", "uc-stale-descriptor"])
func developmentAndroidUCReopensSavedLoginAfterUnresolvedPlayer(mode: String) async throws {
    let fixture = try DevelopmentAndroidBridgeFixture()
    defer { fixture.remove() }
    var site = fixture.site
    site.api = "csp_WoGGGuard"
    site.ext = mode
    try fixture.writeManifest(changes: ["bindings": [["key": site.key, "api": site.api,
        "className": "com.github.catvod.spider.WoGGGuard"]],
        "compatibility": ["cloud": [["classes": ["com.github.catvod.spider.WoGGGuard"], "shareHosts": [:],
            "playerFlags": ["优汐盘": ["drive": "uc", "fileKey": "fid"]]]], "media": []]])
    let runtime = try DevelopmentAndroidRuntimeLayout.load(root: fixture.runtime)
    let provider = DevelopmentAndroidSiteProvider(runtime: runtime,
        binding: try #require(runtime.manifest.bindings.first), stateDirectory: fixture.state)
    let id = #"{"flag":"优汐盘","fid":"fixture-file","sToken":"secret-fixture"}"#
    do {
        do {
            _ = try await provider.playerContent(site: site, flag: "优汐无限1", id: id)
            Issue.record("An unresolved cloud descriptor must never become a media URL")
        } catch let error as ProviderErrorPayload {
            #expect(error.code == "android_player_address_missing")
            #expect(error.retryable)
            #expect(!String(describing: error).contains("secret-fixture"))
        }
        let recovered = try await provider.playerContent(site: site, flag: "优汐无限1", id: id)
        #expect(recovered.url == "https://media.example.test/uc.mp4")
        await provider.shutdown()
        let events = try String(contentsOf: fixture.state.appendingPathComponent("operations.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try JSONDecoder().decode([String: ProviderJSONValue].self, from: Data($0.utf8)) }
        #expect(events.filter { $0["operation"] == .string("handshake") }.count == 2)
        let players = events.filter { $0["operation"] == .string("player") }
        #expect(players.count == 2)
        #expect(players.allSatisfy { $0["id"] == .string(id) && $0["flag"] == .string("优汐无限1") })
        #expect(try #require(players.first?["state_sha256"]) == players.last?["state_sha256"])
    } catch { await provider.shutdown(); throw error }
}

@Test func developmentAndroidRejectsOpaquePlayerPayloadWithoutRetryingOtherSources() async throws {
    let fixture = try DevelopmentAndroidBridgeFixture()
    defer { fixture.remove() }
    let runtime = try DevelopmentAndroidRuntimeLayout.load(root: fixture.runtime)
    let provider = DevelopmentAndroidSiteProvider(runtime: runtime,
        binding: try #require(runtime.manifest.bindings.first), stateDirectory: fixture.state)
    var site = fixture.site
    site.ext = "uc-stale-descriptor"
    do {
        do {
            _ = try await provider.playerContent(site: site, flag: "direct", id: #"{"fid":"fixture"}"#)
            Issue.record("Opaque player payload must be rejected")
        } catch let error as ProviderErrorPayload {
            #expect(error.code == "android_player_address_missing")
            #expect(!error.retryable)
        }
        await provider.shutdown()
        let log = try String(contentsOf: fixture.state.appendingPathComponent("operations.jsonl"), encoding: .utf8)
        #expect(log.split(separator: "\n").filter { $0.contains("\"operation\": \"player\"") }.count == 1)
    } catch { await provider.shutdown(); throw error }
}

@Test func developmentAndroidOriginalRejectsInvalidFolderPresentation() async throws {
    let fixture = try DevelopmentAndroidBridgeFixture()
    defer { fixture.remove() }
    let runtime = try DevelopmentAndroidRuntimeLayout.load(root: fixture.runtime)
    let provider = DevelopmentAndroidSiteProvider(runtime: runtime, binding: try #require(runtime.manifest.bindings.first), stateDirectory: fixture.state)
    var site = fixture.site
    site.ext = "invalid-cate"
    await #expect(throws: ProviderErrorPayload.self) { try await provider.searchContent(site: site, keyword: "fixture", quick: false, page: "1") }
    await provider.shutdown()
}

private let nativeRouteBindings = [
    ["key": "新6V", "api": "csp_SixVGuard", "className": "com.github.catvod.spider.SixVGuard"],
    ["key": "奥特", "api": "csp_AueteGuard", "className": "com.github.catvod.spider.AueteGuard"],
    ["key": "荐片", "api": "csp_JPJGuard", "className": "com.github.catvod.spider.JPJGuard"],
    ["key": "比特", "api": "csp_BttwooGuard", "className": "com.github.catvod.spider.BttwooGuard"],
    ["key": "海绵", "api": "csp_HmysGuard", "className": "com.github.catvod.spider.HmysGuard"],
    ["key": "风云", "api": "csp_FyGuard", "className": "com.github.catvod.spider.FyGuard"],
    ["key": "玩偶", "api": "csp_WoGGGuard", "className": "com.github.catvod.spider.WoGGGuard"],
    ["key": "视界", "api": "csp_App99Guard", "className": "com.github.catvod.spider.App99Guard"],
    ["key": "糯米", "api": "csp_NmyswvGuard", "className": "com.github.catvod.spider.NmyswvGuard"],
    ["key": "光影", "api": "csp_T4Guard", "className": "com.github.catvod.spider.T4Guard"],
    ["key": "剧圈", "api": "csp_AppSxGuard", "className": "com.github.catvod.spider.AppSxGuard"]
]

private actor DevelopmentAndroidNativeRouteFixture: SiteContentProvider {
    private(set) var operations: [String] = []
    func homeContent(site: Site) async throws -> Result { operations.append("home"); return Result() }
    func categoryContent(site: Site, tid: String, page: String, filter: Bool, extend: [String: String]) async throws -> Result {
        operations.append("category")
        return Result(list: [Vod(vodId: "native-vod", vodName: "Native series")])
    }
    func detailContent(site: Site, id: String) async throws -> Result {
        operations.append("detail")
        return Result(list: [Vod(vodId: id, vodName: "Native series", vodPlayFrom: "native-online", vodPlayUrl: "第01集$native-episode")])
    }
    func playerContent(site: Site, flag: String, id: String) async throws -> Result {
        operations.append("player")
        #expect(flag == "native-online" && id == "native-episode")
        return Result(url: "https://media.example.test/native.m3u8", parse: 0)
    }
    func searchContent(site: Site, keyword: String, quick: Bool, page: String) async throws -> Result { Result() }
}

@Test func developmentAndroidComponentUpdateRetiresSameJARAndHostSession() async throws {
    let fixture = try DevelopmentAndroidBridgeFixture()
    defer { fixture.remove() }
    let old = try DevelopmentAndroidRuntimeLayout.load(root: fixture.runtime)
    let next = DevelopmentAndroidRuntimeLayout(root: old.root, manifest: old.manifest, classPath: old.classPath,
        componentIdentity: String(repeating: "b", count: 64))
    let registry = SpiderReplacementRegistry()
    let registration = DevelopmentAndroidRuntimeRegistration(stateRoot: fixture.state, registry: registry, bundledArtifactForTesting: true, arguments: [])
    try await registration.register(runtime: old, sites: [fixture.site])
    let previous = try #require(await registry.nativeProvider(for: fixture.site) as? DevelopmentAndroidSiteProvider)
    _ = try await previous.homeContent(site: fixture.site)
    try await registration.register(runtime: next, sites: [fixture.site])
    let current = try #require(await registry.nativeProvider(for: fixture.site) as? DevelopmentAndroidSiteProvider)
    #expect(previous !== current)
    await #expect(throws: DevelopmentAndroidRuntimeError.closed) { try await previous.homeContent(site: fixture.site) }
    _ = try await current.homeContent(site: fixture.site)
    await registration.shutdownAll()
}

struct DevelopmentAndroidBridgeFixture {
    let root: URL
    let runtime: URL
    let state: URL
    var site: Site { Site(key: "development-fixture-" + root.lastPathComponent, name: "Fixture", type: 3, api: "csp_FixtureGuard", ext: "original") }
    var bindingJSON: [String: String] { ["key": site.key, "api": site.api, "className": "com.github.catvod.spider.FixtureGuard"] }
    static var quarkEpisode: [String: ProviderJSONValue] { [
        "pg": .number(1), "parent": .string(""), "l_created_at": .number(0), "sId": .string("fixture-share"),
        "sToken": .string("secret-fixture-share-session"), "shareUser": .string("fixture-user"),
        "share_fid_token": .string("fixture-file-token"), "fid": .string("fixture-file"), "format_type": .string("video"),
        "vodName": .string("Fixture collection"), "pdir_fid": .string("fixture-parent"), "sub": .array([]),
        "size": .number(4096), "flag": .string("夸父盘"), "file_name": .string("中文 fixture.mp4")
    ] }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("android-bridge-\(UUID().uuidString)", isDirectory: true)
        runtime = root.appendingPathComponent("AndroidProviderRuntime", isDirectory: true)
        state = root.appendingPathComponent("state", isDirectory: true)
        for path in ["jdk/bin", "lib", "compat", "inputs", "converted"] {
            try FileManager.default.createDirectory(at: runtime.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        let files = [
            "lib/android-adapter.jar", "lib/java-runner.jar", "lib/gson.jar", "lib/android-framework.jar", "lib/macapk-loader.jar", "lib/bcprov-fixture.jar",
            "compat/unidbg-android-0.9.8.jar", "compat/unidbg-api-0.9.8.jar", "compat/unidbg-unicorn2-0.9.8.jar", "compat/asm-9.7.1.jar", "compat/jna-5.10.0.jar",
            "converted/provider-jvm.jar", "converted/host-jvm.jar"
        ]
        for file in files { try Data().write(to: runtime.appendingPathComponent(file)) }
        try Data("provider fixture".utf8).write(to: runtime.appendingPathComponent("inputs/provider.jar"))
        try Data("host fixture".utf8).write(to: runtime.appendingPathComponent("inputs/host.apk"))
        try Self.helper.write(to: runtime.appendingPathComponent("jdk/bin/java"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runtime.appendingPathComponent("jdk/bin/java").path)
        try writeManifest()
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func writeManifest(changes: [String: Any] = [:], repairsSDKMedia: Bool = false) throws {
        func hash(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
        var value: [String: Any] = [
            "schema": 1, "providerID": "android-runtime-experiment", "backend": "emulated",
            "providerSHA256": hash("provider fixture"), "hostSHA256": hash("host fixture"), "bindings": [bindingJSON]
        ]
        value.merge(changes) { _, new in new }
        if value["compatibility"] == nil {
            let bindings = value["bindings"] as? [[String: String]] ?? []
            value["compatibility"] = ["cloud": [], "media": (repairsSDKMedia ? bindings : []).map { binding in
                ["key": binding["key"] ?? "", "api": binding["api"] ?? "", "className": binding["className"] ?? "",
                 "path": "/proxy", "queryName": "do", "queryValue": "hg"]
            }]
        }
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: runtime.appendingPathComponent("manifest.json"))
    }

    func bundle(flag: Any?) throws -> Bundle {
        let bundle = root.appendingPathComponent(UUID().uuidString + ".bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleIdentifier": "test.android." + UUID().uuidString, "CFBundlePackageType": "BNDL"]
        if let flag { info["NetVplayerDevelopmentAndroidRuntime"] = flag }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        return try #require(Bundle(url: bundle))
    }

    private static let helper = #"""
#!/usr/bin/python3
import hashlib, http.server, json, os, sys, threading, time, urllib.parse
from pathlib import Path
extension = None
state_path = next((v.split('=', 1)[1] for v in sys.argv if v.startswith('-Dnetvplayer.android.persistentDataDir=')), '')
uc_login = Path(state_path) / 'uc-login.fixture'
loaded_uc_login = uc_login.exists()
sdk_recovery = Path(state_path) / 'sdk-server-recovery.fixture'
loaded_sdk_recovery = sdk_recovery.exists()
sdk_http_recovery = Path(state_path) / 'sdk-http-recovery.fixture'
loaded_sdk_http_recovery = sdk_http_recovery.exists()
sdk_server = None
for raw in sys.stdin:
    request = json.loads(raw)
    operation = request['operation']
    args = request.get('arguments', {})
    site = request.get('site') or {}
    requested_extension = site.get('ext', '')
    if operation == 'init':
        extension = args.get('extend', '')
    with open('operations.jsonl', 'a') as log:
        log.write(json.dumps({'operation': operation, 'pid': str(os.getpid()), 'extend': extension or '', 'state_sha256': hashlib.sha256(state_path.encode()).hexdigest(), 'id': args.get('id', ''), 'flag': args.get('flag', '')}) + '\n')
    response = {'request_id': request['request_id'], 'ok': True}
    if operation == 'handshake':
        result = {'provider_id': request['provider_id'], 'protocol': 1}
    elif operation == 'init' and requested_extension == 'reject-init':
        response.update(ok=False, error={'code': 'init_rejected', 'message': 'synthetic init failure', 'retryable': False})
        result = {}
    elif operation in ('init', 'destroy', 'shutdown'):
        result = {}
    elif requested_extension != extension:
        response.update(ok=False, error={'code': 'interleaved_init', 'message': 'site configuration was interleaved', 'retryable': False})
        result = None
    elif operation == 'home':
        time.sleep(0.01)
        result = {'url': extension, 'list': []}
    elif operation == 'home_video':
        result = ''
    elif operation == 'category':
        result = {'list': [{'vod_id': args['tid'], 'vod_name': extension}]}
    elif operation == 'player':
        if requested_extension.startswith('uc-stale-'):
            if loaded_uc_login:
                result = {'url': 'https://media.example.test/uc.mp4'}
            else:
                uc_login.write_text('saved-login')
                result = {'url': args['id'] if requested_extension == 'uc-stale-descriptor' else ''}
        elif args.get('id', '').startswith('quality-'):
            result = {'url': ['清晰 480P', 'http://127.0.0.1:-1/proxy?do=fixture&quality=480&token=secret-fixture',
                              '流畅 360P', 'http://127.0.0.1:-1/proxy?do=fixture&quality=360&token=secret-fixture'],
                      'header': json.dumps({'User-Agent': 'Fixture quality'})}
            if args['id'] == 'quality-odd': result['url'].pop()
            if args['id'] == 'quality-mixed': result['url'][1] = {'url': 'secret-fixture'}
            if args['id'] == 'quality-empty': result['url'] = []
            if args['id'] == 'quality-control': result['url'][0] = 'secret-fixture\nlabel'
            if args['id'] == 'quality-subtitles':
                result['subs'] = [{'name': '歌词', 'format': 'text/x-ssa',
                                   'url': 'http://127.0.0.1:-1/proxy?do=ssa&csp=FixtureGuard'}]
        elif requested_extension.startswith('numbered-subtitles-'):
            media = 'https://media.example.test/episode.mkv'
            names = ['series.S1E0200.zh.srt', 'Series.S01E79', 'Series.S02E200', '中文',
                     'Series.S01E199-E200', 'Series.S01E199.S01E200', 'Other.S01E79']
            result = {
                'url': ['HD', media, 'SD', media + '?quality=sd'] if requested_extension.endswith('qualities') else media,
                'subs': [{'name': name, 'lang': 'zh', 'format': 'application/x-subrip',
                          'url': f'http://127.0.0.1:9978/proxy?do=subtitles&track={i}'} for i, name in enumerate(names)]
            }
        elif args.get('id') == 'original-page':
            result = {'url': 'https://live.doubao.example.test/play/123', 'parse': 1, 'jx': 1, 'format': 'text/html',
                      'header': {'User-Agent': 'Original page', 'Referer': 'https://fixture.test/'}}
        elif args.get('id') == 'subtitle-fixture':
            result = {'url': 'https://media.example.test/direct.m3u8', 'header': {'User-Agent': 'Fixture subtitles'},
                      'danmaku': [{'name':'XML','url':'http://127.0.0.1:-1/proxy?do=dm&csp=FixtureGuard&token=secret-fixture-dm'},
                                  {'name':'Remote','url':'https://comments.example.test/d.xml?signature=a%2Bb'},
                                  {'name':'SDK server','url':'http://127.0.0.1:6677/proxy?do=danmu&url=opaque-sdk-input'}],
                      'subs': [{'name': '歌词', 'lang': 'zh', 'format': 'text/x-ssa',
                                'url': 'http://127.0.0.1:-1/proxy?do=ssa&csp=FixtureGuard&track=0&token=secret-fixture-lyrics'},
                               {'name': 'Translation', 'lang': 'en', 'format': 'ssa',
                                'url': 'http://127.0.0.1:9978/proxy?do=ssa&csp=FixtureGuard&track=1&token=secret-fixture-lyrics'},
                               {'name': 'Remote', 'format': 'srt', 'url': 'https://subtitle.example.test/remote.srt'},
                               {'name': 'Inline', 'format': 'ass', 'url': 'data:text/x-ssa;base64,Zml4dHVyZQ=='}]}
        elif args.get('id', '').startswith(('sdk-recover-', 'sdk-owned-', 'sdk-http-500-', 'sdk-delayed-')):
            fails_http = args['id'].startswith('sdk-http-500-')
            delayed_listen = args['id'].startswith('sdk-delayed-')
            owns_server = fails_http or delayed_listen or args['id'].startswith('sdk-owned-') or loaded_sdk_recovery
            if not owns_server:
                sdk_recovery.write_text('saved SDK session')
            elif sdk_server is None:
                returns_http_500 = fails_http and (not loaded_sdk_http_recovery or args['id'].startswith('sdk-http-500-always-'))
                if returns_http_500:
                    sdk_http_recovery.write_text('saved SDK session')
                class SDKHandler(http.server.BaseHTTPRequestHandler):
                    def do_GET(self):
                        body = Path('sdk-media-body.fixture')
                        data = body.read_bytes() if body.exists() else b'SDK media fixture'
                        with open('sdk-http.jsonl', 'a') as log:
                            log.write(json.dumps({'path': self.path, 'range': self.headers.get('Range', ''),
                                                  'user_agent': self.headers.get('User-Agent', '')}) + '\n')
                        if returns_http_500:
                            data = b'Synthetic SDK error'
                        self.send_response(500 if returns_http_500 else 200)
                        self.send_header('Content-Type', 'text/plain' if returns_http_500 else 'video/mp4')
                        self.send_header('Content-Length', str(len(data)))
                        self.end_headers()
                        self.wfile.write(data)
                    def log_message(self, *args): pass
                for candidate in range(6677, 7000):
                    server = http.server.ThreadingHTTPServer(('127.0.0.1', candidate), SDKHandler, bind_and_activate=False)
                    try:
                        server.server_bind()
                    except OSError:
                        server.server_close()
                        continue
                    sdk_server = server
                    break
                assert sdk_server is not None
                def serve_sdk(server):
                    server.server_activate()
                    server.serve_forever()
                if delayed_listen:
                    thread = threading.Timer(0.35, serve_sdk, args=(sdk_server,))
                    thread.daemon = True
                    thread.start()
                else:
                    sdk_server.server_activate()
                    threading.Thread(target=sdk_server.serve_forever, daemon=True).start()
            # A new SDK instance still reports a stale port. Only its owned listener is valid.
            reported_port = int(args['id'].rsplit('-', 1)[1])
            result = {'url': f'http://127.0.0.1:{reported_port}/proxy?do=hg&vid=fixture',
                      'parse': 0, 'header': {'User-Agent': 'SDK fixture'}}
        elif args.get('id', '').startswith('sdk-media-'):
            port = int(args['id'].removeprefix('sdk-media-'))
            result = {'url': f'http://127.0.0.1:{port}/proxy?do=hg&vid=1234567890123456789',
                      'parse': 0, 'header': {'User-Agent': 'SDK fixture'}}
        elif args.get('id') == 'proxy-fixture':
            query = urllib.parse.urlencode({'do': 'fixture', 'url': 'https://media.example.test/proxy.m3u8?token=a+b&part=1',
                                           'headers': '{"User-Agent":"Fixture"}', 'siteKey': 'forged-context'})
            result = {'url': 'http://127.0.0.1:-1/proxy?' + query}
        else:
            result = {'url': 'https://media.example.test/direct.m3u8', 'header': {'User-Agent': 'Fixture'}}
    elif operation == 'proxy':
        response['proxy'] = {'status_code': 200, 'content_type': 'application/json',
                             'body': json.dumps(args.get('parameters', {})), 'headers': {}}
        result = {}
    elif operation == 'action':
        response.update(ok=False, error={'code': 'fixture_rejected', 'message': 'fixture rejected action', 'retryable': False})
        result = None
    else:
        result = {}
    if requested_extension == 'original-episode-parsing' and operation == 'detail':
        result = {'list': [{'vod_id': args['id'], 'vod_play_from': ' original ', 'vod_play_url': 'bare#  label  $ raw$id #$named', '_netvplayer_android_original_episodes': False}]}
    if requested_extension == 'original-detail' and operation == 'detail':
        result = {'list': [{'vod_id': args['id'], 'vod_name': 'Original share', 'vod_play_from': '夸克',
                           'vod_play_url': '原链接$https://pan.quark.cn/s/fixture-share?pwd=A%2Bb'}]}
    if requested_extension == 'invalid-cate' and operation == 'search':
        result = {'list': [{'vod_id': 'invalid', 'cate': 'invalid'}]}
    if requested_extension == 'catvod-folders' and operation == 'search':
        result = {'list': [
            {'vod_id': ' opaque/+%20= ', 'vod_name': 'Opaque folder', 'vod_tag': 'folder'},
            {'vod_id': ' { "file_id":"原样/+", "meta":{"value":"%2F\\\\n"} } ',
             'vod_name': 'JSON folder', 'vod_tag': 'folder', 'vod_play_from': None, 'vod_play_url': ''},
            {'vod_id': 'room', 'vod_name': 'Room', 'vod_tag': 'room'},
            {'vod_id': 'case-sensitive', 'vod_name': 'Unknown tag', 'vod_tag': 'Folder'},
            {'vod_id': 'play-from', 'vod_name': 'Playback flag', 'vod_tag': 'folder', 'vod_play_from': 'fixture'},
            {'vod_id': 'play-url', 'vod_name': 'Episode', 'vod_tag': 'folder', 'vod_play_url': 'fixture$episode'},
            {'vod_id': '', 'vod_name': 'Missing identifier', 'vod_tag': 'folder'},
            {'vod_id': 'cate', 'vod_name': 'Styled folder', 'cate': {}},
            {'vod_id': 'null-cate', 'vod_name': 'Not styled', 'cate': None},
            {'vod_id': 'forged', 'vod_name': 'Extra unsupported flag', 'is_folder': True}
        ]}
    if requested_extension == 'alllive-folders' and operation == 'category':
        if args.get('tid') == 'huya_1':
            result = {'list': [{'vod_id': 'huya_1', 'vod_name': 'Fixture room'}]}
        else:
            result = {'list': [
                {'vod_id': 'huya_1', 'vod_name': 'Category 1', 'vod_tag': 'folder'},
                {'vod_id': 'huya_862', 'vod_name': 'Category 862', 'vod_tag': 'folder'},
                {'vod_id': 'douyu_2', 'vod_name': 'Category 2', 'vod_tag': 'folder', 'vod_play_url': ''},
                {'vod_id': 'bilibili_3:4', 'vod_name': 'Category 3', 'vod_tag': 'folder'},
                {'vod_id': 'huya_123', 'vod_name': 'Room', 'vod_tag': 'room'},
                {'vod_id': 'huya_9', 'vod_name': 'Playable', 'vod_tag': 'folder', 'vod_play_url': 'fixture$room'},
                {'vod_id': 'other_1', 'vod_name': 'Other', 'vod_tag': 'folder'},
                {'vod_id': 'huya_room', 'vod_name': 'Unknown suffix', 'vod_tag': 'folder'},
                {'vod_id': 'huya_', 'vod_name': 'Empty suffix', 'vod_tag': 'folder'},
                {'vod_id': 'huya_10', 'vod_name': 'Unknown tag', 'vod_tag': 'Folder'},
                {'vod_id': 'huya_1_2', 'vod_name': 'Unknown suffix separator', 'vod_tag': 'folder'}
            ]}
    if requested_extension.startswith('wire-') and operation in ('home', 'home_video', 'category', 'search', 'detail', 'player'):
        result = {'class': [{'type_id': 'wire-category', 'type_name': 'Fixture category'}],
                  'list': [{'vod_id': 'wire-vod', 'vod_name': 'CatVod JSON fixture'}],
                  'url': 'https://media.example.test/catvod.m3u8',
                  'header': json.dumps({'User-Agent': 'CatVod fixture', 'Referer': 'https://catalog.example.test/'})}
        mode = requested_extension
        if mode == 'wire-json':
            result = json.dumps(result)
        elif mode == 'wire-double-json':
            result = json.dumps(json.dumps(result))
        elif mode == 'wire-bom-json':
            result = '\ufeff' + json.dumps(result)
        elif mode == 'wire-invalid-json':
            result = 'secret-fixture-marker https://secret.example.test/'
        elif mode == 'wire-empty':
            result = ''
        elif mode == 'wire-array':
            result = []
        elif mode == 'wire-wrappers':
            result = json.dumps(json.dumps(json.dumps(result)))
        elif mode == 'wire-invalid-header':
            result['header'] = 'secret-fixture-marker https://secret.example.test/'
        elif mode == 'wire-empty-header':
            result['header'] = ' \n'
        elif mode == 'wire-null':
            result = None
        elif mode == 'wire-null-json':
            result = 'null'
    response['result'] = result
    print(json.dumps(response), flush=True)
    if operation == 'shutdown':
        break
"""#
}
#endif
