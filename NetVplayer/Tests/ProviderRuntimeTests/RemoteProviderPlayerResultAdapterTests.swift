import CryptoKit
import Foundation
import Models
import ProviderRuntime
import ProviderSDK
import ProxyServer
import Testing
@testable import SpiderEngine

@Test func remoteProviderPlayerResultAdapterLocalizesSignedHLSDescriptor() throws {
    let mediaURL = "http://media.example.test/vod/index.m3u8?k=abc&uid=7"
    let headers = #"{"Accept":"*/*","User-Agent":"Mozi"}"#
    let secret = "fixture-sign-secret"
    var descriptor = URLComponents()
    descriptor.scheme = RemoteProviderPlayerResultAdapter.proxyScheme
    descriptor.host = "hmys-hls-v1"
    descriptor.queryItems = [
        URLQueryItem(name: "url", value: mediaURL),
        URLQueryItem(name: "headers", value: headers),
        URLQueryItem(name: "sign_secret", value: secret)
    ]
    let result = Result(url: try #require(descriptor.url?.absoluteString))
    let server = ProxyServer()

    let localized = try RemoteProviderPlayerResultAdapter.localize(
        result,
        site: Site(key: "海绵", name: "海绵", type: 3, api: "csp_HmysGuard"),
        providerID: "migration.hmys.java",
        proxyServer: server
    )

    let components = try #require(URLComponents(string: localized.url))
    let query: [String: String] = Dictionary(
        uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
    )
    #expect(components.host == "127.0.0.1")
    #expect(components.port == server.port)
    #expect(components.path == "/proxy.m3u8")
    #expect(ProxyURLCodec.decode(query["u64"] ?? "") == mediaURL)
    #expect(ProxyURLCodec.decode(query["h64"] ?? "") == headers)
    #expect(ProxyURLCodec.decode(query["hs64"] ?? "") == secret)
    #expect(query["hls"] == "1")
    #expect(localized.format == "m3u8")
    #expect(localized.key == "海绵")
}

@Test func remoteProviderPlayerResultAdapterLeavesDirectResultsUntouched() throws {
    let original = Result(
        url: "https://media.example.test/video.mp4",
        header: ["User-Agent": "Fixture"],
        format: "mp4",
        key: "direct"
    )

    let localized = try RemoteProviderPlayerResultAdapter.localize(
        original,
        site: Site(key: "direct", name: "Direct", type: 3, api: "csp_Direct"),
        providerID: "migration.direct.java"
    )

    #expect(localized.url == original.url)
    #expect(localized.header == original.header)
    #expect(localized.format == original.format)
    #expect(localized.key == original.key)
}

@Test func remoteProviderPlayerResultAdapterRejectsUnsafeDescriptors() {
    #expect(throws: RemoteProviderPlayerResultError.invalidTargetURL) {
        try RemoteProviderPlayerResultAdapter.localize(
            Result(url: "netvplayer-provider-proxy://hmys-hls-v1?url=file:///tmp/video.m3u8&headers=%7B%7D&sign_secret=x"),
            site: Site(key: "unsafe", name: "Unsafe", type: 3, api: "csp_Unsafe"),
            providerID: "migration.hmys.java"
        )
    }
    #expect(throws: RemoteProviderPlayerResultError.invalidHeaderJSON) {
        try RemoteProviderPlayerResultAdapter.localize(
            Result(url: "netvplayer-provider-proxy://hmys-hls-v1?url=https://media.example.test/a.m3u8&headers=%5B%5D&sign_secret=x"),
            site: Site(key: "unsafe", name: "Unsafe", type: 3, api: "csp_Unsafe"),
            providerID: "migration.hmys.java"
        )
    }
    #expect(throws: RemoteProviderPlayerResultError.unauthorizedProvider) {
        try RemoteProviderPlayerResultAdapter.localize(
            Result(url: "netvplayer-provider-proxy://hmys-hls-v1?url=https://media.example.test/a.m3u8&headers=%7B%7D&sign_secret=x"),
            site: Site(key: "unsafe", name: "Unsafe", type: 3, api: "csp_Unsafe"),
            providerID: "migration.other.java"
        )
    }
}

@Test func signedRemoteBindingOverridesLegacyNativeAliasButNotExactKeyedProvider() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("remote-provider-precedence-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let privateKey = Curve25519.Signing.PrivateKey()
    let verifier = try ProviderManifestVerifier(
        publicKeyData: privateKey.publicKey.rawRepresentation,
        shellVersion: "1.0.0"
    )
    let manager = ProviderManager(store: ProviderPackageStore(rootURL: root, verifier: verifier))
    let registry = SpiderReplacementRegistry()
    let site = Site(key: "海绵", name: "海绵", type: 3, api: "csp_HmysGuard")

    await registry.register(
        originalAPI: site.api,
        provider: RemoteSiteContentProvider(providerID: "legacy.swift", manager: manager)
    )
    await registry.registerRemote(
        originalAPI: site.api,
        providerID: "migration.hmys.java",
        manager: manager
    )
    let signed = await registry.nativeProvider(for: site) as? RemoteSiteContentProvider
    #expect(signed?.providerID == "migration.hmys.java")

    await registry.register(
        originalKey: site.key,
        originalAPI: site.api,
        provider: RemoteSiteContentProvider(providerID: "exact.override", manager: manager)
    )
    let exact = await registry.nativeProvider(for: site) as? RemoteSiteContentProvider
    #expect(exact?.providerID == "exact.override")
}

@Test func signedRemoteBindingCannotOverridePublicUtilityOwnership() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("remote-provider-public-utility-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let privateKey = Curve25519.Signing.PrivateKey()
    let verifier = try ProviderManifestVerifier(
        publicKeyData: privateKey.publicKey.rawRepresentation,
        shellVersion: "1.0.0"
    )
    let manager = ProviderManager(store: ProviderPackageStore(rootURL: root, verifier: verifier))
    let registry = SpiderReplacementRegistry()
    let publicMyDrive = RemoteSiteContentProvider(providerID: "public.mydrive", manager: manager)
    let publicConfig = RemoteSiteContentProvider(providerID: "public.config", manager: manager)
    await registry.registerPublicUtilityProviders(
        myDrive: publicMyDrive,
        configurationCenter: publicConfig
    )
    await registry.registerRemote(
        originalAPI: "csp_ConfigGuard",
        providerID: "signed.override",
        manager: manager
    )

    let selected = await registry.nativeProvider(for: Site(
        key: "配置中心",
        name: "配置中心",
        type: 3,
        api: "csp_ConfigGuard"
    )) as? RemoteSiteContentProvider

    #expect(selected?.providerID == "public.config")
}

@Test func hmysJavaHelperCompletesLiveSwiftProxyAndDecodeWhenEnabled() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["NETVPLAYER_REAL_HMYS_JAVA_TEST"] == "1" else { return }
    let javaPath = try #require(environment["NETVPLAYER_JAVA_EXECUTABLE"])
    let runnerPath = try #require(environment["NETVPLAYER_JAVA_RUNNER"])
    let providerPath = try #require(environment["NETVPLAYER_JAVA_HMYS_PROVIDER"])
    let packageRootPath = try #require(environment["NETVPLAYER_HMYS_JAVA_PACKAGE_ROOT"])
    let ffprobePath = try #require(environment["NETVPLAYER_FFPROBE"])
    let state = FileManager.default.temporaryDirectory
        .appendingPathComponent("hmys-java-live-state-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: state) }
    let packageRoot = URL(fileURLWithPath: packageRootPath, isDirectory: true)
    let command = ProviderCommand(
        executableURL: URL(fileURLWithPath: javaPath),
        arguments: [
            "-jar", runnerPath,
            "--provider", providerPath,
            "--class", "com.netvplayer.privateprovider.hmys.HmysProvider"
        ],
        currentDirectoryURL: packageRoot,
        stateDirectoryURL: state,
        environment: [
            "NETVPLAYER_PROVIDER_ID": "migration.hmys.java",
            "NETVPLAYER_PROVIDER_ROOT": packageRoot.path,
            "NETVPLAYER_PROVIDER_STATE": state.path,
            "NETVPLAYER_PROVIDER_PROTOCOL": "1"
        ]
    )
    let client = ProviderProcessClient(command: command)
    let site = Site(key: "海绵", name: "海绵", type: 3, api: "csp_HmysGuard", timeout: 30)

    do {
        let handshake = try await client.request(ProviderRequest(
            providerID: "migration.hmys.java",
            operation: .handshake
        ), timeout: .seconds(10))
        #expect(handshake.ok)
        let initialized = try await client.request(ProviderRequest(
            providerID: "migration.hmys.java",
            operation: .initialize,
            site: site,
            arguments: ["extend": .string("")]
        ), timeout: .seconds(30))
        #expect(initialized.ok)
        let homeResponse = try await client.request(ProviderRequest(
            providerID: "migration.hmys.java",
            operation: .home,
            site: site,
            arguments: ["filter": .bool(true)]
        ), timeout: .seconds(30))
        let home = try homeResponse.decodedResult(Result.self)
        #expect(!home.list.isEmpty)

        var mediaResponse: ProxyResponse?
        var detailsAttempted = 0
        var playersAttempted = 0
        let proxyHandler = ProxyPlaybackHandler.make()
        for seed in home.list.prefix(8) {
            detailsAttempted += 1
            do {
                let detailResponse = try await client.request(ProviderRequest(
                    providerID: "migration.hmys.java",
                    operation: .detail,
                    site: site,
                    arguments: ["id": .string(seed.vodId)]
                ), timeout: .seconds(30))
                let detail = try detailResponse.decodedResult(Result.self)
                guard let flag = detail.vod?.parseFlags().first,
                      let episode = flag.episodes.first else { continue }
                playersAttempted += 1
                let playerResponse = try await client.request(ProviderRequest(
                    providerID: "migration.hmys.java",
                    operation: .player,
                    site: site,
                    arguments: [
                        "flag": .string(flag.name),
                        "id": .string(episode.url),
                        "vip_flags": .array([])
                    ]
                ), timeout: .seconds(30))
                let player = try playerResponse.decodedResult(Result.self)
                let localized = try RemoteProviderPlayerResultAdapter.localize(
                    player,
                    site: site,
                    providerID: "migration.hmys.java"
                )
                let components = try #require(URLComponents(string: localized.url))
                var query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map {
                    ($0.name, $0.value ?? "")
                })
                for _ in 0..<6 {
                    guard let response = try await proxyHandler(query),
                          (200..<300).contains(response.statusCode),
                          !response.data.isEmpty else { break }
                    guard let manifest = String(data: response.data, encoding: .utf8),
                          manifest.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") else {
                        mediaResponse = response
                        break
                    }
                    guard let relay = manifest.split(whereSeparator: \.isNewline)
                        .map(String.init)
                        .first(where: { !$0.isEmpty && !$0.hasPrefix("#") }),
                          let relayComponents = URLComponents(string: relay),
                          relayComponents.host == "127.0.0.1" else { break }
                    query = Dictionary(uniqueKeysWithValues: (relayComponents.queryItems ?? []).map {
                        ($0.name, $0.value ?? "")
                    })
                }
                if mediaResponse != nil { break }
            } catch {
                continue
            }
        }
        let media = try #require(mediaResponse)
        let suffix = media.contentType.lowercased().contains("mp2t") ? "ts" : "bin"
        let sample = FileManager.default.temporaryDirectory
            .appendingPathComponent("hmys-java-live-media-\(UUID().uuidString).\(suffix)")
        defer { try? FileManager.default.removeItem(at: sample) }
        try media.data.write(to: sample, options: .atomic)
        let ffprobe = Process()
        let stdout = Pipe()
        ffprobe.executableURL = URL(fileURLWithPath: ffprobePath)
        ffprobe.arguments = [
            "-v", "error",
            "-show_entries", "format=format_name:stream=codec_type,codec_name,width,height",
            "-of", "json", sample.path
        ]
        ffprobe.standardOutput = stdout
        ffprobe.standardError = Pipe()
        try ffprobe.run()
        ffprobe.waitUntilExit()
        #expect(ffprobe.terminationStatus == 0)
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let decoded = try #require(JSONSerialization.jsonObject(with: output) as? [String: Any])
        let streams = try #require(decoded["streams"] as? [[String: Any]])
        let streamTypes = Set(streams.compactMap { $0["codec_type"] as? String })
        let codecNames = Set(streams.compactMap { $0["codec_name"] as? String })
        #expect(streamTypes.isSuperset(of: ["video", "audio"]))
        #expect(codecNames.isSuperset(of: ["h264", "aac"]))
        print(
            "[REAL_HMYS_JAVA] home=\(home.list.count) details=\(detailsAttempted) "
                + "players=\(playersAttempted) mediaBytes=\(media.data.count) streams=\(streams.count)"
        )
        await client.stop()
    } catch {
        await client.stop(graceful: false)
        throw error
    }
}
