import Foundation
import Models
import Networking
import ProviderRuntime
import ProviderSDK
import ProxyServer
import Testing

@Test func newCzSignedPythonProviderRelaysLiveMediaWhenEnabled() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["NETVPLAYER_REAL_NEW_CZ_PYTHON_TEST"] == "1" else { return }
    let packageRootPath = try #require(environment["NETVPLAYER_PYTHON_CATALOG_ROOT"])
    let packageRoot = URL(fileURLWithPath: packageRootPath, isDirectory: true)
    let state = FileManager.default.temporaryDirectory
        .appendingPathComponent("newcz-python-live-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: state) }
    let client = ProviderProcessClient(command: ProviderCommand(
        executableURL: packageRoot.appendingPathComponent("runtimes/cpython/bin/python3"),
        arguments: [
            "-I", "-S", packageRoot.appendingPathComponent("provider_runner.pyc").path,
            "--provider", packageRoot.appendingPathComponent("provider.pyc").path,
            "--class", "Spider"
        ],
        currentDirectoryURL: packageRoot,
        stateDirectoryURL: state,
        environment: [
            "NETVPLAYER_PROVIDER_ID": "netvplayer.catalog.python",
            "NETVPLAYER_PROVIDER_ROOT": packageRoot.path,
            "NETVPLAYER_PROVIDER_STATE": state.path,
            "NETVPLAYER_PROVIDER_PROTOCOL": "1"
        ]
    ))
    let site = Site(key: "厂长", name: "厂长", type: 3, api: "csp_NewCzGuard", timeout: 30)

    do {
        _ = try await client.request(ProviderRequest(
            providerID: "netvplayer.catalog.python",
            operation: .handshake
        ), timeout: .seconds(10))
        _ = try await client.request(ProviderRequest(
            providerID: "netvplayer.catalog.python",
            operation: .initialize,
            site: site,
            arguments: ["extend": .string("")]
        ), timeout: .seconds(30))
        let homeResponse = try await client.request(ProviderRequest(
            providerID: "netvplayer.catalog.python",
            operation: .home,
            site: site,
            arguments: ["filter": .bool(true)]
        ), timeout: .seconds(30))
        let home = try homeResponse.decodedResult(Result.self)
        let seed = try #require(home.list.first)
        let detailResponse = try await client.request(ProviderRequest(
            providerID: "netvplayer.catalog.python",
            operation: .detail,
            site: site,
            arguments: ["id": .string(seed.vodId)]
        ), timeout: .seconds(30))
        let detail = try detailResponse.decodedResult(Result.self)
        let flag = try #require(detail.vod?.parseFlags().first)
        let episode = try #require(flag.episodes.first)
        let playerResponse = try await client.request(ProviderRequest(
            providerID: "netvplayer.catalog.python",
            operation: .player,
            site: site,
            arguments: [
                "flag": .string(flag.name),
                "id": .string(episode.url),
                "vip_flags": .array([])
            ]
        ), timeout: .seconds(30))
        let player = try playerResponse.decodedResult(Result.self)
        let refererHost = player.header["Referer"].flatMap { URL(string: $0)?.host } ?? ""
        print("[REAL_NEW_CZ_PYTHON_HEADERS] keys=\(player.header.keys.sorted()) refererHost=\(refererHost)")
        let headerData = try JSONSerialization.data(withJSONObject: player.header, options: [.sortedKeys])
        let headerJSON = String(decoding: headerData, as: UTF8.self)
        var handlers = [("direct", ProxyPlaybackHandler.make())]
        if let rawPort = environment["NETVPLAYER_PROVIDER_PROXY_PORT"], let port = Int(rawPort) {
            let configuration = URLSessionConfiguration.default
            configuration.connectionProxyDictionary = [
                "HTTPEnable": 1,
                "HTTPProxy": "127.0.0.1",
                "HTTPPort": port,
                "HTTPSEnable": 1,
                "HTTPSProxy": "127.0.0.1",
                "HTTPSPort": port,
            ]
            let session = URLSession(configuration: configuration)
            handlers.append(("proxy", ProxyPlaybackHandler.make(httpClient: HTTPClient(session: session))))
        }

        var verifiedPlaylist = false
        var verifiedSegment = false
        for (transport, handler) in handlers {
            for hls in [false, true] {
                var parameters = [
                    "u64": ProxyURLCodec.encode(player.url),
                    "h64": ProxyURLCodec.encode(headerJSON)
                ]
                if hls { parameters["hls"] = "1" }
                let response = try #require(await handler(parameters))
                let prefix = String(decoding: response.data.prefix(80), as: UTF8.self)
                    .replacingOccurrences(of: "\n", with: "\\n")
                print(
                    "[REAL_NEW_CZ_PYTHON_PROXY] transport=\(transport) hls=\(hls) "
                        + "status=\(response.statusCode) mime=\(response.contentType) "
                        + "bytes=\(response.data.count) prefix=\(prefix)"
                )
                guard response.data.starts(with: Data("#EXTM3U".utf8)) else { continue }
                verifiedPlaylist = true
                guard transport == "direct", hls, !verifiedSegment else { continue }

                let playlist = String(decoding: response.data, as: UTF8.self)
                let segmentLine = try #require(playlist
                    .split(whereSeparator: \.isNewline)
                    .map(String.init)
                    .first { !$0.isEmpty && !$0.hasPrefix("#") })
                let segmentURL = try #require(URLComponents(string: segmentLine))
                let segmentParameters = Dictionary(
                    uniqueKeysWithValues: (segmentURL.queryItems ?? []).compactMap { item in
                        item.value.map { (item.name, $0) }
                    }
                )
                let segment = try #require(await handler(segmentParameters))
                #expect(segment.statusCode == 200)
                #expect(segment.contentType == "video/mp2t")
                #expect(segment.data.count > 188)
                #expect(segment.data.first == 0x47)
                verifiedSegment = true
                print(
                    "[REAL_NEW_CZ_PYTHON_SEGMENT] status=\(segment.statusCode) "
                        + "mime=\(segment.contentType) bytes=\(segment.data.count)"
                )

                if let evidencePath = environment["NETVPLAYER_NEW_CZ_EVIDENCE_DIR"] {
                    let evidenceDirectory = URL(fileURLWithPath: evidencePath, isDirectory: true)
                    try FileManager.default.createDirectory(
                        at: evidenceDirectory,
                        withIntermediateDirectories: true
                    )
                    try response.data.write(
                        to: evidenceDirectory.appendingPathComponent("playlist.m3u8"),
                        options: .atomic
                    )
                    try segment.data.write(
                        to: evidenceDirectory.appendingPathComponent("segment.ts"),
                        options: .atomic
                    )
                }
            }
        }
        #expect(verifiedPlaylist)
        #expect(verifiedSegment)
        print(
            "[REAL_NEW_CZ_PYTHON_PLAYER] title=\(seed.vodName) "
                + "host=\(URL(string: player.url)?.host ?? "") format=\(player.format)"
        )
        await client.stop()
    } catch {
        await client.stop(graceful: false)
        throw error
    }
}
