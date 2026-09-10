import Foundation
import Testing
import ConfigEngine
import Models
import Networking
import SpiderEngine
import Storage
@testable import NetVplayerApp

@Suite("MacCMS direct VOD input", .serialized)
struct MacCMSInputTests {
    @Test func jsonDecoderAcceptsNumericAndStringFields() throws {
        let decoded = try MacCMSPayloadDecoder.decode(fixture("maccms_json", extension: "json"))

        #expect(decoded.format == .json)
        #expect(decoded.result.code == 1)
        #expect(decoded.result.page == 2)
        #expect(decoded.result.pagecount == 3)
        #expect(decoded.result.total == 4)
        #expect(decoded.result.types.map(\.typeId) == ["1", "2"])
        #expect(decoded.result.list.first?.vodId == "101")
        #expect(decoded.result.list.first?.parseFlags().count == 2)
    }

    @Test func xmlDecoderMapsClassesPaginationCDATAAndPlayLines() throws {
        let decoded = try MacCMSPayloadDecoder.decode(fixture("maccms_xml", extension: "xml"))
        let vod = try #require(decoded.result.list.first)
        let flags = vod.parseFlags()

        #expect(decoded.format == .xml)
        #expect(decoded.result.page == 2)
        #expect(decoded.result.pagecount == 8)
        #expect(decoded.result.total == 8)
        #expect(decoded.result.types.map(\.typeName) == ["电影", "剧集"])
        #expect(vod.vodName == "XML 示例影片")
        #expect(vod.vodContent.contains("CDATA"))
        #expect(vod.vodPlayFrom == "m3u8$$$backup")
        #expect(flags.map(\.name) == ["m3u8", "backup"])
        #expect(flags.first?.episodes.count == 2)
        #expect(flags.first?.episodes.first?.url.contains("token=a&quality=hd") == true)
    }

    @Test func decoderRejectsInvalidJSONHTMLAndBrokenXML() {
        #expect(throws: MacCMSPayloadError.self) {
            try MacCMSPayloadDecoder.decode("{\"code\":1,\"list\":[}")
        }
        #expect(throws: MacCMSPayloadError.self) {
            try MacCMSPayloadDecoder.decode("<html><body>Not a CMS response</body></html>")
        }
        #expect(throws: MacCMSPayloadError.self) {
            try MacCMSPayloadDecoder.decode("<rss><list><video></rss>")
        }
    }

    @Test func resolverPrioritizesConfigurationsAndNormalizesDirectSourceURLs() async throws {
        let client = makeHTTPClient()
        let resolver = ConfigResolver(httpClient: client)
        let json = fixture("maccms_json", extension: "json")
        MacCMSMockURLProtocol.reset()
        defer { MacCMSMockURLProtocol.reset() }
        MacCMSMockURLProtocol.register(path: "/api.php/provide/vod/from/hhm3u8/at/json/", body: json)
        MacCMSMockURLProtocol.register(path: "/api.php/provide/vod/from/hhm3u8/at/json", body: json)
        MacCMSMockURLProtocol.register(
            path: "/msg-source",
            body: json.replacingOccurrences(of: "{\n  \"code\": \"1\",", with: "{\n  \"code\": \"1\",\n  \"msg\": \"数据列表\",")
        )
        MacCMSMockURLProtocol.register(path: "/xml-source", body: fixture("maccms_xml", extension: "xml"), contentType: "application/xml")
        MacCMSMockURLProtocol.register(path: "/config.json", body: "{\"sites\":[{\"key\":\"demo\",\"name\":\"Demo\",\"type\":1,\"api\":\"https://cms.example.test/api\"}]}")

        let input = "https://www.example.test/api.php/provide/vod/from/hhm3u8/at/json/?ac=list&t=2&from=hhm3u8&at=json&token=secret&key=abc&pagesize=20"
        let resolved = try await resolver.loadVodInput(url: input)
        let canonicalItems = URLComponents(string: resolved.canonicalURL)?.queryItems ?? []
        let canonicalNames = Set(canonicalItems.map { $0.name.lowercased() })

        #expect(resolved.kind == .macCMSJSON)
        #expect(resolved.config.name == "MacCMS · example.test")
        #expect(resolved.config.home.hasPrefix("maccms_"))
        #expect(resolved.config.home.count == 19)
        #expect(!canonicalNames.contains("ac"))
        #expect(!canonicalNames.contains("t"))
        #expect(!canonicalNames.contains("pagesize"))
        #expect(canonicalNames.isSuperset(of: ["from", "at", "token", "key"]))
        #expect(resolved.initialResult?.list.first?.siteKey == resolved.config.home)

        let stable = try await resolver.loadVodInput(url: resolved.canonicalURL)
        #expect(stable.config.home == resolved.config.home)

        let noTrailingSlash = try await resolver.loadVodInput(
            url: "https://www.example.test/api.php/provide/vod/from/hhm3u8/at/json"
        )
        #expect(noTrailingSlash.kind == .macCMSJSON)
        #expect(noTrailingSlash.initialResult?.list.first?.vodId == "101")

        let withMessage = try await resolver.loadVodInput(url: "https://msg.example.test/msg-source")
        #expect(withMessage.kind == .macCMSJSON)
        #expect(withMessage.initialResult?.list.first?.vodId == "101")

        let xml = try await resolver.loadVodInput(url: "https://xml.example.test/xml-source?ac=list&at=xml")
        let xmlObject = try #require(JSONSerialization.jsonObject(with: Data(xml.json.utf8)) as? [String: Any])
        let xmlSites = try #require(xmlObject["sites"] as? [[String: Any]])
        #expect(xml.kind == .macCMSXML)
        #expect(xml.canonicalURL == "https://xml.example.test/xml-source?at=xml")
        #expect(xmlSites.first?["type"] as? Int == 0)

        let configuration = try await resolver.loadVodInput(url: "https://config.example.test/config.json")
        #expect(configuration.kind == .configuration)
        #expect(configuration.initialResult == nil)
        #expect(configuration.config.url == "https://config.example.test/config.json")

        var transportFailed = false
        do {
            _ = try await resolver.loadVodInput(url: "https://offline.example.test/unavailable")
        } catch {
            transportFailed = true
        }
        #expect(transportFailed)
        #expect(MacCMSMockURLProtocol.requestedUserAgents.allSatisfy { $0 == "okhttp/5.3.2" })
    }

    @Test func siteAPIUsesMacCMSRequestModesAndDecoderForJSONAndXML() async throws {
        MacCMSMockURLProtocol.reset()
        defer { MacCMSMockURLProtocol.reset() }
        MacCMSMockURLProtocol.register(path: "/json", body: fixture("maccms_json", extension: "json"))
        MacCMSMockURLProtocol.register(path: "/xml", body: fixture("maccms_xml", extension: "xml"), contentType: "application/xml")
        let api = SiteApi(httpClient: makeHTTPClient())
        let jsonSite = Site(key: "json", name: "JSON", type: 1, api: "https://cms.example.test/json")
        let xmlSite = Site(key: "xml", name: "XML", type: 0, api: "https://cms.example.test/xml")

        let home = try await api.homeContent(site: jsonSite)
        let category = try await api.categoryContent(
            key: jsonSite.key,
            tid: "2",
            page: "3",
            filter: true,
            extend: [:],
            sites: [jsonSite]
        )
        let search = try await api.searchContent(site: xmlSite, keyword: "示例", quick: false, page: "1")
        let detail = try await api.detailContent(key: xmlSite.key, id: "202", sites: [xmlSite])
        let player = try await api.playerContent(
            key: xmlSite.key,
            flag: "m3u8",
            id: "https://media.example.test/xml-1.m3u8",
            sites: [xmlSite]
        )
        let requestModes = MacCMSMockURLProtocol.requestedURLs.compactMap { url in
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "ac" })?.value
        }

        #expect(home.list.first?.siteKey == jsonSite.key)
        #expect(category.list.first?.siteKey == jsonSite.key)
        #expect(search.list.first?.vodPlayFrom == "m3u8$$$backup")
        #expect(detail.list.first?.siteKey == xmlSite.key)
        #expect(player.url == "https://media.example.test/xml-1.m3u8")
        #expect(requestModes.contains("list"))
        #expect(requestModes.contains("detail"))
        #expect(requestModes.contains("videolist"))
    }

    @MainActor
    @Test func appStateUsesInitialResultOnceAndDoesNotPersistInvalidInput() async throws {
        let previousPreference = UserPreferences.shared.currentVodConfigUrl
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NetVplayer-MacCMS-\(UUID().uuidString)", isDirectory: true)
        let storage = StorageManager(storageDirectory: storageURL)
        MacCMSMockURLProtocol.reset()
        MacCMSMockURLProtocol.register(path: "/direct", body: fixture("maccms_json", extension: "json"))
        MacCMSMockURLProtocol.register(path: "/invalid", body: "<html>not a CMS response</html>", contentType: "text/html")
        MacCMSMockURLProtocol.register(path: "/depot", body: fixture("depot_config", extension: "json"))
        defer {
            UserPreferences.shared.currentVodConfigUrl = previousPreference
            VodConfig.shared.clear()
            MacCMSMockURLProtocol.reset()
            try? FileManager.default.removeItem(at: storageURL)
        }

        let appState = AppState(
            loadDefaultConfig: false,
            startProxyServer: false,
            configResolver: ConfigResolver(httpClient: makeHTTPClient()),
            storageManager: storage
        )
        let sourceURL = "https://www.direct.example.test/direct?ac=list&token=keep"
        await appState.loadConfig(url: sourceURL)

        #expect(appState.configError == nil)
        #expect(appState.vods.first?.vodName == "JSON 示例影片")
        #expect(appState.categories.map(\.typeName) == ["电影", "剧集"])
        #expect(MacCMSMockURLProtocol.requestedURLs.count == 1)
        #expect(storage.loadConfigs().count == 1)
        #expect(storage.loadConfigs().first?.name == "MacCMS · direct.example.test")
        #expect(UserPreferences.shared.currentVodConfigUrl == "https://www.direct.example.test/direct?token=keep")

        let savedBeforeFailure = storage.loadConfigs()
        let preferenceBeforeFailure = UserPreferences.shared.currentVodConfigUrl
        let vodsBeforeFailure = appState.vods.map(\.vodId)
        await appState.loadConfig(url: "https://bad.example.test/invalid")

        #expect(appState.configError != nil)
        #expect(storage.loadConfigs().map(\.url) == savedBeforeFailure.map(\.url))
        #expect(UserPreferences.shared.currentVodConfigUrl == preferenceBeforeFailure)
        #expect(appState.vods.map(\.vodId) == vodsBeforeFailure)

        await appState.loadConfig(url: "https://depot.example.test/depot", persistUserConfig: false)
        #expect(appState.configError == "配置仓库需选择子配置")
        #expect(appState.availableDepots.map(\.name) == ["Primary", "Backup"])
        #expect(appState.currentVodInputKind == .configuration)
        #expect(appState.currentVodInputFingerprint == StableFingerprint.sha256Prefix(
            fixture("depot_config", extension: "json").trimmingCharacters(in: .whitespacesAndNewlines)
        ))
    }

    @Test func applyingAConfigClearsAbsentHomeParseAndLiveState() throws {
        let config = VodConfig(hygieneStore: nil)
        defer {
            config.clear()
            LiveConfig.shared.clear()
        }
        let original = """
        {
          "home": "old",
          "parse": "old-parse",
          "sites": [{"key":"old","name":"Old","type":1,"api":"https://old.example.test/api"}],
          "parses": [{"name":"old-parse","type":0,"url":"https://parse.example.test/?url="}],
          "lives": [{"name":"Old Live","url":"https://live.example.test/list.txt"}]
        }
        """
        try config.parse(json: original, config: .vod(url: "https://old.example.test/config.json"))
        #expect(config.home?.key == "old")
        #expect(config.currentParse?.name == "old-parse")
        #expect(LiveConfig.shared.lives.count == 1)

        let replacement = """
        {"sites":[{"key":"new","name":"New","type":1,"api":"https://new.example.test/api"}]}
        """
        try config.parse(json: replacement, config: .vod(url: "https://new.example.test/config.json"))

        #expect(config.home?.key == "new")
        #expect(config.currentParse == nil)
        #expect(LiveConfig.shared.lives.isEmpty)
    }

    @Test func realVodInputDiagnosticWhenEnabled() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["NETVPLAYER_REAL_VOD_INPUT_DIAGNOSTIC"] == "1" else { return }

        let urls = (environment["NETVPLAYER_REAL_VOD_INPUT_URLS"] ?? "")
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        #expect(!urls.isEmpty, "实时 VOD 输入诊断至少需要一个 URL")

        var failures: [String] = []
        for url in urls {
            do {
                let resolved = try await ConfigResolver.shared.loadVodInput(url: url)
                var siteCount = 0
                if resolved.kind == .configuration {
                    let config = VodConfig(hygieneStore: nil)
                    do {
                        try config.parse(json: resolved.json, config: resolved.config)
                        siteCount = config.sites.count
                    } catch ConfigError.isDepot(let depots) {
                        print("[REAL_VOD_INPUT] url=\(url) kind=depot depots=\(depots.count)")
                        continue
                    }
                }
                print(
                    "[REAL_VOD_INPUT] url=\(url) kind=\(resolved.kind) "
                        + "sites=\(siteCount) initialItems=\(resolved.initialResult?.list.count ?? 0)"
                )
            } catch {
                let message = "\(url): \(String(reflecting: error))"
                failures.append(message)
                print("[REAL_VOD_INPUT] failure=\(message)")
                print("[REAL_VOD_INPUT] diagnostic=\(await payloadParseDiagnostic(url: url))")
            }
        }

        #expect(failures.isEmpty, "实时 VOD 输入诊断失败:\n\(failures.joined(separator: "\n"))")
    }

    private func payloadParseDiagnostic(url: String) async -> String {
        do {
            let response = try await HTTPClient.shared.get(
                url: url,
                headers: ["User-Agent": "okhttp/5.3.2"]
            )
            let finalURL = response.finalURL?.absoluteString ?? url
            let decoded: String
            if let textDecoded = try? SourceDecoder.decode(response.text, url: finalURL) {
                decoded = textDecoded
            } else {
                decoded = try SourceDecoder.decodeFromImageData(response.data, url: finalURL)
            }
            guard let data = decoded.data(using: .utf8) else {
                return "status=\(response.statusCode) decodedUTF8=false"
            }
            do {
                _ = try JSONSerialization.jsonObject(with: data)
                return "status=\(response.statusCode) bytes=\(data.count) json=valid"
            } catch {
                let value = error as NSError
                let errorIndex = value.userInfo["NSJSONSerializationErrorIndex"] as? Int
                let context: String
                if let errorIndex {
                    let lowerBound = max(0, errorIndex - 80)
                    let upperBound = min(data.count, errorIndex + 80)
                    context = String(decoding: data[lowerBound..<upperBound], as: UTF8.self)
                        .replacingOccurrences(of: "\r", with: "\\r")
                        .replacingOccurrences(of: "\n", with: "\\n")
                } else {
                    context = "unavailable"
                }
                return "status=\(response.statusCode) bytes=\(data.count) "
                    + "jsonError=\(String(reflecting: error)) context=\(context)"
            }
        } catch {
            return "payloadError=\(String(reflecting: error))"
        }
    }

    private func fixture(_ name: String, extension fileExtension: String) -> String {
        let url = Bundle.module.url(forResource: name, withExtension: fileExtension, subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: name, withExtension: fileExtension)
        return (try? url.map { try String(contentsOf: $0, encoding: .utf8) }) ?? ""
    }

    private func makeHTTPClient() -> HTTPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MacCMSMockURLProtocol.self]
        return HTTPClient(session: URLSession(configuration: configuration))
    }
}

private final class MacCMSMockURLProtocol: URLProtocol, @unchecked Sendable {
    private struct Response: Sendable {
        let body: String
        let contentType: String
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [String: Response] = [:]
    nonisolated(unsafe) private(set) static var requestedURLs: [URL] = []
    nonisolated(unsafe) private(set) static var requestedUserAgents: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        guard let responseSpec = Self.response(
            for: url,
            userAgent: request.value(forHTTPHeaderField: "User-Agent")
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": responseSpec.contentType]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(responseSpec.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func register(path: String, body: String, contentType: String = "application/json") {
        lock.lock()
        defer { lock.unlock() }
        responses[path] = Response(body: body, contentType: contentType)
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        responses = [:]
        requestedURLs = []
        requestedUserAgents = []
    }

    private static func response(for url: URL, userAgent: String?) -> Response? {
        lock.lock()
        defer { lock.unlock() }
        requestedURLs.append(url)
        requestedUserAgents.append(userAgent ?? "")
        return responses[url.path]
    }
}
