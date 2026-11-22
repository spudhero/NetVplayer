import AppKit
import CoreFoundation
import CryptoKit
import DriveEngine
import Foundation
import Models
import ProviderRuntime
import ProviderSDK
import ProxyServer

/// Original Android execution using a verified, independently installed runtime component.
public actor DevelopmentAndroidSiteProvider: SiteContentProvider, SiteContentCacheClearing {
    // Foreground playback can spend its existing preparation retry on a new SDK session.
    @TaskLocal public static var allowsSDKMediaHTTPRecovery = false

    public nonisolated let providerID: String
    private let runtime: DevelopmentAndroidRuntimeLayout
    private let binding: DevelopmentAndroidRuntimeManifest.Binding
    private let stateDirectory: URL
    private let sessionStateRoot: URL
    private let probeSDKMedia: @Sendable (String, [String: String]) async throws -> [Int64]
    private var client: ProviderProcessClient?
    private var initializedConfiguration: Data?
    private var initializedDrive: DriveProvider?
    private var operationTail: Task<Void, Never>?
    private var requests: [UUID: (ProviderOperation, Task<ProviderResponse, Error>)] = [:]
    private var streams: [UUID: Task<Void, Error>] = [:]
    private var shutdownJob: Task<Void, Never>?
    private var idleShutdown: Task<Void, Never>?
    private let idleShutdownDelay: Duration
    private var preparingPlaybackCount = 0
    private var hasPlayback = false
    private var releaseWhenIdle = false
    private var contentCacheEpoch: UInt64 = 0
    private let diagnosticSession = UUID().uuidString
    private var helperGeneration: UInt64 = 0
    private var webMediaGeneration: UInt64 = 0
    private struct WebMediaLease: Sendable {
        let epoch: UInt64
        let helper: UInt64
        let playback: UInt64
        let configuration: Data
    }
    private struct ProxyRoute {
        let parameters: [String: String]
        let originalURL: String
        let headers: [String: String]
        var role: DevelopmentAndroidHLS.Role? = nil
        var remote = false
        var playerInputSHA256: String? = nil
        var parentRouteID: String? = nil
        var codecPatchOffsets: [Int64] = []
    }
    private var proxyRoutes: [String: ProxyRoute] = [:]
    private var closed = false
    private var retired = false

    init(
        runtime: DevelopmentAndroidRuntimeLayout,
        binding: DevelopmentAndroidRuntimeManifest.Binding,
        stateDirectory: URL,
        sessionStateRoot: URL? = nil,
        baiduCookieProvider: (@Sendable () async -> String?)? = nil,
        cloudCredentialProvider: (@Sendable (DriveProvider) async -> String?)? = nil,
        idleShutdownDelay: Duration = .seconds(15),
        probeSDKMedia: @escaping @Sendable (String, [String: String]) async throws -> [Int64] = {
            try await DevelopmentAndroidMP4CodecRepair.probe($0, headers: $1)
        }
    ) {
        self.runtime = runtime
        self.binding = binding
        self.stateDirectory = stateDirectory
        self.sessionStateRoot = sessionStateRoot ?? stateDirectory.appendingPathComponent("source-sessions-v1", isDirectory: true)
        self.probeSDKMedia = probeSDKMedia
        self.idleShutdownDelay = idleShutdownDelay
        // Native account callbacks remain accepted for source compatibility.
        // Original Android sources own their login and never read these stores.
        providerID = runtime.manifest.providerID
    }

    /// Opaque identity shared by desktop playback context and its Android source.
    public static func sourceIdentity(site: Site) -> String {
        sourceIdentity(key: site.key, api: site.api)
    }

    static func sourceIdentity(key: String, api: String) -> String {
        SHA256.hash(data: Data((key + "\0" + api).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// First-use preparation is shared with configuration loading. A first
    /// installation can be used immediately; replacing an active runtime still
    /// retains the existing restart boundary.
    public static func prepareRuntime(progress: @escaping @Sendable (String) async -> Void = { _ in }) async throws {
        _ = try await AndroidRuntimeComponentSession.shared.runtime(bundle: .main, progress: progress)
    }

    public static func cancelRuntimePreparation() async {
        await AndroidRuntimeComponentSession.shared.cancelPreparation()
    }

    /// The release path uses the pinned component selected at process startup.
    /// Unsigned legacy bundles remain restricted to DEBUG builds.
    public static func registerIfEnabled(
        sites: [Site], bundle: Bundle = .main,
        preference: ProviderExecutionPreference = .macPreferred,
        baiduCookieProvider: (@Sendable () async -> String?)? = nil,
        cloudCredentialProvider: (@Sendable (DriveProvider) async -> String?)? = nil,
        runtimeProgress: @escaping @Sendable (String) async -> Void = { _ in }
    ) async throws {
        // Select the implementation before consulting or downloading its runtime.
        guard preference.usesAndroid else { return }
        guard sites.contains(where: { AndroidOriginalProviderPolicy.className(for: $0) != nil && !$0.jar.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            if preference == .androidPreferred {
                for site in sites where AndroidOriginalProviderPolicy.applies(to: site) {
                    let reason: AndroidOriginalUnavailableReason = AndroidOriginalProviderPolicy.className(for: site) == nil
                        ? .unsupportedSourceAPI : .missingProviderArtifact
                    await AndroidOriginalProviderPolicy.registerUnavailable(sites: [site], reason: reason)
                }
            }
            return
        }
        try await registerIfEnabled(sites: sites, bundle: bundle, preference: preference,
            baiduCookieProvider: baiduCookieProvider, cloudCredentialProvider: cloudCredentialProvider,
            componentRuntime: {
                do { return try await AndroidRuntimeComponentSession.shared.runtime(bundle: $0, progress: runtimeProgress) }
                catch is CancellationError { throw CancellationError() }
                catch {
                    await runtimeProgress("failed")
                    throw AndroidRuntimePreparationError.failed
                }
            })
    }

    // Fixtures supply a component selection without consulting the user's
    // installation. Runtime trust and route error handling remain in this path.
    static func registerIfEnabled(
        sites: [Site], bundle: Bundle,
        preference: ProviderExecutionPreference = .macPreferred,
        baiduCookieProvider: (@Sendable () async -> String?)? = nil,
        cloudCredentialProvider: (@Sendable (DriveProvider) async -> String?)? = nil,
        componentRuntime: @Sendable (Bundle) async throws -> DevelopmentAndroidRuntimeLayout?
    ) async throws {
        guard preference.usesAndroid else { return }
        if CommandLine.arguments.contains("--android-provider-audit"),
           CommandLine.arguments.contains("--android-provider-native-baseline") { return }
        let runtime: DevelopmentAndroidRuntimeLayout?
        do {
            #if DEBUG
            if let enabled = bundle.object(forInfoDictionaryKey: "NetVplayerDevelopmentAndroidRuntime") as? NSNumber,
               CFGetTypeID(enabled) == CFBooleanGetTypeID(), enabled.boolValue, let resources = bundle.resourceURL {
                runtime = try await Task.detached(priority: .utility) {
                    try DevelopmentAndroidRuntimeLayout.load(root: resources.appendingPathComponent("AndroidProviderRuntime"))
                }.value
            } else { runtime = try await componentRuntime(bundle) }
            #else
            runtime = try await componentRuntime(bundle)
            #endif
        } catch {
            await DevelopmentAndroidRuntimeRegistration.shared.shutdownAll()
            if error is CancellationError { throw error }
            if error is AndroidRuntimePreparationError {
                await AndroidOriginalProviderPolicy.registerUnavailable(sites: sites, reason: .preparationFailed)
                return
            }
            if preference == .androidPreferred {
                // Preserve the configuration and let the source show the
                // actionable component error instead of a generic config error.
                await AndroidOriginalProviderPolicy.registerUnavailable(sites: sites, reason: .runtimeInvalid)
                return
            }
            throw error
        }
        guard let runtime else {
            await DevelopmentAndroidRuntimeRegistration.shared.shutdownAll()
            if preference == .androidPreferred {
                await AndroidOriginalProviderPolicy.registerUnavailable(sites: sites, reason: .runtimeUnavailable)
            }
            return
        }
        try await DevelopmentAndroidRuntimeRegistration.shared.register(runtime: runtime, sites: sites,
            preference: preference, baiduCookieProvider: baiduCookieProvider, cloudCredentialProvider: cloudCredentialProvider)
    }

    public static func isBundled(in bundle: Bundle = .main) -> Bool {
        #if DEBUG
        guard let enabled = bundle.object(forInfoDictionaryKey: "NetVplayerDevelopmentAndroidRuntime") as? NSNumber,
              CFGetTypeID(enabled) == CFBooleanGetTypeID(), enabled.boolValue,
              let resources = bundle.resourceURL else { return false }
        return FileManager.default.fileExists(atPath: resources.appendingPathComponent("AndroidProviderRuntime/manifest.json").path)
        #else
        return false
        #endif
    }

    /// Releases helper processes while retaining the bundle's exact site registrations.
    public static func shutdownAll() async {
        await DevelopmentAndroidRuntimeRegistration.shared.shutdownAll()
    }

    public static func isRegistered(site: Site) async -> Bool {
        await DevelopmentAndroidRuntimeRegistration.shared.isRegistered(site: site)
    }

    /// Actual content identity after following the configured JAR declaration.
    public static func effectiveProviderSHA256(site: Site) async -> String? {
        await DevelopmentAndroidRuntimeRegistration.shared.effectiveProviderSHA256(site: site)
    }

    /// A development raw-proxy hook; callers must fall back to the signed proxy handler on nil.
    public static func proxyResponseIfEnabled(parameters: [String: String]) async throws -> ProxyResponse? {
        try await DevelopmentAndroidRuntimeRegistration.shared.proxyResponse(parameters: parameters)
    }

    public func homeContent(site: Site) async throws -> Result {
        try await result(operation: .home, site: site, arguments: ["filter": .bool(true)])
    }

    public func homeVideoContent(site: Site) async throws -> Result? {
        let value = try await response(operation: .homeVideo, site: site)
        return try Self.decodeContent(value, operation: .homeVideo, site: site, allowsEmpty: true)
    }

    public func categoryContent(site: Site, tid: String, page: String, filter: Bool, extend: [String: String]) async throws -> Result {
        try await result(operation: .category, site: site, arguments: [
            "tid": .string(tid), "page": .string(page), "filter": .bool(filter), "extend": .object(extend)
        ])
    }

    public func detailContent(site: Site, id: String) async throws -> Result {
        await shutdownJob?.value
        let epoch = try beginContentAccess(site)
        let detail = try await result(operation: .detail, site: site, arguments: ["id": .string(id)])
        try validateContentAccess(site, epoch: epoch)
        return detail
    }

    public func clearContentCache() async {
        invalidateContentAccess()
    }

    /// Keep the original Spider that produced this playback result. A later
    /// player/init/retirement must never revive a stale browser callback.
    public func webMediaPolicy(site: Site, rules: [Rule]) throws -> WebMediaPolicy {
        let epoch = try beginContentAccess(site)
        guard client != nil, initializedConfiguration == (try JSONEncoder.providerCanonical.encode(site)) else {
            throw Self.staleContent()
        }
        let lease = WebMediaLease(epoch: epoch, helper: helperGeneration, playback: webMediaGeneration,
                                  configuration: initializedConfiguration!)
        return WebMediaPolicy(rules: rules, check: { [self] url in
            try await checkWebMedia(url: url, site: site, lease: lease)
        })
    }

    private func validateWebMediaLease(_ lease: WebMediaLease, site: Site) throws {
        try validateContentAccess(site, epoch: lease.epoch)
        guard client != nil, helperGeneration == lease.helper, webMediaGeneration == lease.playback,
              initializedConfiguration == lease.configuration,
              lease.configuration == (try JSONEncoder.providerCanonical.encode(site)) else {
            throw Self.staleContent()
        }
    }

    private func checkWebMedia(url: String, site: Site, lease: WebMediaLease) async throws -> Bool? {
        try validateWebMediaLease(lease, site: site)
        do {
            let manual = try await response(operation: .manualVideoCheck, site: site, webLease: lease)
            try validateWebMediaLease(lease, site: site)
            guard case .bool(let enabled) = manual.result else { throw Self.invalidContent("a non-boolean video check") }
            guard enabled else { return nil }
            let result = try await response(operation: .isVideoFormat, site: site, arguments: ["url": .string(url)], webLease: lease)
            try validateWebMediaLease(lease, site: site)
            guard case .bool(let accepted) = result.result else { throw Self.invalidContent("a non-boolean video format") }
            return accepted
        } catch {
            // g50 catches Spider exceptions and invokes eb3.c. Lifecycle/cancel
            // failures are checked first and cannot fall through into success.
            try validateWebMediaLease(lease, site: site)
            return nil
        }
    }

    public func playerContent(site: Site, flag: String, id: String) async throws -> Result {
        await shutdownJob?.value
        webMediaGeneration &+= 1
        let epoch = try beginContentAccess(site)
        releaseWhenIdle = false
        preparingPlaybackCount += 1
        defer {
            preparingPlaybackCount -= 1
            scheduleIdleShutdown()
        }
        let arguments: [String: ProviderJSONValue] = ["flag": .string(flag), "id": .string(id), "vip_flags": .array([])]
        let playerInput = DevelopmentAndroidLifecycleDiagnostics.sha256(try JSONEncoder.providerCanonical.encode(arguments))
        let decoded = try await result(operation: .player, site: site, arguments: arguments)
        try validateContentAccess(site, epoch: epoch)
        if let interaction = decoded.interaction {
            throw PlaybackInteractionRequiredError(interaction: interaction)
        }
        guard !Self.hasUnresolvedPlayerPayload(decoded, id: id) else {
            throw Self.unresolvedPlayerError(retryable: false)
        }
        var localized = decoded
        for index in localized.playbackCandidates.indices where localized.playbackCandidates[index].isPlayable {
            localized.playbackCandidates[index].providerName = site.name
            var input = decoded
            input.playbackCandidates = []
            input.danmaku = []
            input.url = localized.playbackCandidates[index].url
            input.header = localized.playbackCandidates[index].headers
            input.format = localized.playbackCandidates[index].format
            input.subs = localized.playbackCandidates[index].subtitles.isEmpty
                ? decoded.subs : localized.playbackCandidates[index].subtitles
            let candidate = try await localizePlaybackURL(input, site: site, epoch: epoch, playerInput: playerInput)
            try validateContentAccess(site, epoch: epoch)
            localized.playbackCandidates[index].url = candidate.url
            localized.playbackCandidates[index].headers = candidate.header
            localized.playbackCandidates[index].format = candidate.format
            localized.playbackCandidates[index].externalAudioURL = candidate.externalAudioURL
            localized.playbackCandidates[index].subtitles = candidate.subs
        }
        if let first = localized.playbackCandidates.first(where: \.isPlayable) {
            localized.url = first.url
            localized.header = first.headers
            localized.externalAudioURL = first.externalAudioURL ?? ""
            localized.subs = first.subtitles
            localized.danmaku = try localizeDanmaku(decoded.danmaku, site: site, epoch: epoch)
            localized.format = first.format
            localized.parse = 0
            localized.jx = 0
            hasPlayback = true
            return localized
        }
        let result = try await localizePlaybackURL(decoded, site: site, epoch: epoch, playerInput: playerInput)
        try validateContentAccess(site, epoch: epoch)
        hasPlayback = true
        return result
    }

    private static func hasUnresolvedPlayerPayload(_ result: Result, id: String) -> Bool {
        guard result.interaction == nil, result.playbackCandidates.isEmpty else { return false }
        func isDescriptor(_ value: String) -> Bool {
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.utf8.count <= 65_536, text.first == "{" || text.first == "[",
                  let value = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else { return false }
            return value is [String: Any] || value is [Any]
        }
        return isDescriptor(result.url)
            || (result.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && isDescriptor(id))
    }

    private static func unresolvedPlayerError(retryable: Bool) -> ProviderErrorPayload {
        ProviderErrorPayload(code: "android_player_address_missing",
            message: L10n.text("视频源未返回播放地址，请重试或切换线路。"), retryable: retryable)
    }

    private func localizePlaybackURL(_ decoded: Result, site: Site, epoch: UInt64, playerInput: String) async throws -> Result {
        var localized = try await localizeMediaURL(decoded, site: site, epoch: epoch, playerInput: playerInput)
        for index in localized.subs.indices {
            // CatVod also serves generated subtitles (for example MusicGuard's
            // SSA lyrics) through its Android loopback proxy. Preserve the
            // subtitle metadata and original parameters, using the same bound
            // route and lifetime as media instead of passing an Android port to mpv.
            let subtitle = Result(url: localized.subs[index].url, header: decoded.header)
            let routeID = UUID().uuidString
            if let route = try DevelopmentAndroidCatVodProxyAdapter.localize(
                subtitle, site: site, binding: binding, providerID: providerID, routeID: routeID, permitsDirectLocalServer: true
            ) {
                try validateContentAccess(site, epoch: epoch)
                try registerProxyRoute(route.parameters, id: routeID, url: subtitle.url, headers: subtitle.header)
                localized.subs[index].url = route.result.url
            }
        }
        localized.danmaku = try localizeDanmaku(decoded.danmaku, site: site, epoch: epoch)
        return localized
    }

    private func localizeDanmaku(_ tracks: [ProviderDanmaku], site: Site, epoch: UInt64) throws -> [ProviderDanmaku] {
        var localized = tracks
        for index in localized.indices {
            let attachment = Result(url: localized[index].url)
            let routeID = UUID().uuidString
            if let route = try DevelopmentAndroidCatVodProxyAdapter.localize(
                attachment, site: site, binding: binding, providerID: providerID, routeID: routeID, permitsDirectLocalServer: true
            ) {
                try validateContentAccess(site, epoch: epoch)
                try registerProxyRoute(route.parameters, id: routeID, url: attachment.url, headers: [:])
                localized[index].url = route.result.url
            }
        }
        return localized
    }

    private func registerProxyRoute(_ parameters: [String: String], id routeID: String,
                                    url: String, headers: [String: String], role: DevelopmentAndroidHLS.Role? = nil,
                                    remote: Bool = false, playerInput: String? = nil, parent: String? = nil,
                                    codecPatchOffsets: [Int64] = []) throws {
        guard proxyRoutes.count < 8192 else { throw DevelopmentAndroidProxyManifest.unsupported() }
        proxyRoutes[routeID] = ProxyRoute(parameters: parameters, originalURL: url, headers: headers,
            role: role, remote: remote, playerInputSHA256: playerInput, parentRouteID: parent, codecPatchOffsets: codecPatchOffsets)
    }

    private func localizeMediaURL(_ decoded: Result, site: Site, epoch: UInt64, playerInput: String) async throws -> Result {
        try validateContentAccess(site, epoch: epoch)
        var decoded = decoded
        let routeID = UUID().uuidString
        let repairsCodec = DevelopmentAndroidMP4CodecRepair.accepts(
            decoded.url, site: site, binding: binding, policy: runtime.compatibilityPolicy)
        if repairsCodec || Self.isSDKMediaAddress(decoded.url) {
            let lease = WebMediaLease(epoch: epoch, helper: helperGeneration, playback: webMediaGeneration,
                configuration: try JSONEncoder.providerCanonical.encode(site))
            let listeners = await client?.listeningTCPPorts()
            try validateWebMediaLease(lease, site: site)
            guard let listeners, var address = URLComponents(string: decoded.url) else {
                throw Self.unverifiedSDKMediaServer()
            }
            let sdkPorts = listeners.filter { (6677..<7000).contains($0) }
            if sdkPorts.isEmpty {
                // A different source may still be serving the cached port. Do
                // not send this source's media parameters to that other helper.
                try await retireSDKMediaServer(site: site, lease: lease)
                throw Self.unverifiedSDKMediaServer()
            }
            if !sdkPorts.contains(address.port ?? 0) {
                guard sdkPorts.count == 1, let port = sdkPorts.first else {
                    throw Self.unverifiedSDKMediaServer()
                }
                // SDK discovery can cache a different helper's port just before shutting it down.
                // Correct only the port, using the current child's actual listening socket.
                address.port = port
                guard let corrected = address.string else { throw DevelopmentAndroidProxyManifest.unsupported() }
                decoded.url = corrected
                DiagnosticLog.write("[ANDROID_SDK_MEDIA_PORT] ownership=current_helper corrected=true")
            }
        }
        if repairsCodec {
            let lease = WebMediaLease(epoch: epoch, helper: helperGeneration, playback: webMediaGeneration,
                configuration: try JSONEncoder.providerCanonical.encode(site))
            let patches: [Int64]
            do {
                patches = try await probeSDKMedia(decoded.url, decoded.header)
            } catch DevelopmentAndroidMP4CodecRepair.ProbeFailure.sdkHTTP500 {
                try Task.checkCancellation()
                try validateWebMediaLease(lease, site: site)
                if Self.allowsSDKMediaHTTPRecovery {
                    try await retireSDKMediaServer(site: site, lease: lease, failure: .http500)
                }
                throw SDKMediaServerFailure.http500.payload(retryable: false)
            } catch {
                let failure = error as NSError
                guard failure.domain == NSURLErrorDomain,
                      failure.code == URLError.cannotConnectToHost.rawValue else { throw error }
                // Another SDK instance can shut down this helper's HTTP server
                // without exiting its JVM. AppState owns the single retry budget.
                try await retireSDKMediaServer(site: site, lease: lease)
                throw error
            }
            try validateContentAccess(site, epoch: epoch)
            if !patches.isEmpty {
                var local = URLComponents(string: ProxyServer.shared.getAddress("/proxy"))!
                local.queryItems = [URLQueryItem(name: DevelopmentAndroidCatVodProxyAdapter.markerKey, value: "1"),
                    URLQueryItem(name: "from", value: "catvod"), URLQueryItem(name: "providerID", value: providerID),
                    URLQueryItem(name: "siteKey", value: site.key), URLQueryItem(name: "siteAPI", value: site.api),
                    URLQueryItem(name: "siteType", value: String(site.type)),
                    URLQueryItem(name: DevelopmentAndroidCatVodProxyAdapter.routeKey, value: routeID)]
                guard let url = local.url?.absoluteString else { throw DevelopmentAndroidProxyManifest.unsupported() }
                try registerProxyRoute([:], id: routeID, url: decoded.url, headers: decoded.header,
                    role: .opaque, remote: true, playerInput: playerInput, codecPatchOffsets: patches)
                DiagnosticLog.write("[ANDROID_MP4_CODEC_REPAIR] sample_entries=\(patches.count) avc1_to_hvc1=true")
                var result = decoded
                result.url = url
                return result
            }
        }
        if let route = try DevelopmentAndroidCatVodProxyAdapter.localize(
            // Like attachments, SDK media may use a real helper-owned server
            // whose port is chosen at startup. Rebind only CatVod host ports.
            decoded, site: site, binding: binding, providerID: providerID, routeID: routeID,
            permitsDirectLocalServer: true
        ) {
            try registerProxyRoute(route.parameters, id: routeID, url: decoded.url, headers: decoded.header, playerInput: playerInput)
            let diagnostic = "[ANDROID_PROVIDER_PROXY_ROUTE] backend=emulated site=\(ProviderDiagnostics.redact(site.key)) local_proxy=true"
            DiagnosticLog.write(diagnostic)
            print(diagnostic)
            return route.result
        }
        return try RemoteProviderPlayerResultAdapter.localize(decoded, site: site, providerID: providerID)
    }

    private static func isSDKMediaAddress(_ raw: String) -> Bool {
        guard raw.utf8.count <= 128 * 1024, let url = URLComponents(string: raw), url.scheme == "http",
              ["127.0.0.1", "localhost", "::1", "[::1]"].contains(url.host ?? ""),
              let port = url.port, (6677..<7000).contains(port),
              url.user == nil, url.password == nil, url.fragment == nil else { return false }
        return true
    }

    private static func unverifiedSDKMediaServer() -> ProviderErrorPayload {
        ProviderErrorPayload(code: "android_sdk_media_unverified", message: L10n.text("无法连接到服务地址。"))
    }

    private enum SDKMediaServerFailure: String {
        case connectionRefused = "sdk_media_connection_refused"
        case http500 = "sdk_media_http_500"

        func payload(retryable: Bool) -> ProviderErrorPayload {
            switch self {
            case .connectionRefused:
                ProviderErrorPayload(code: "android_sdk_media_disconnected",
                    message: L10n.text("无法连接到服务地址。"), retryable: retryable)
            case .http500:
                ProviderErrorPayload(code: "android_sdk_media_http_500",
                    message: "Android SDK HTTP 500", retryable: retryable)
            }
        }
    }

    private func retireSDKMediaServer(site: Site, lease: WebMediaLease,
                                      failure: SDKMediaServerFailure = .connectionRefused) async throws {
        let previous = operationTail
        let task = Task<ProviderResponse, Error> { [self] in
            await previous?.value
            try Task.checkCancellation()
            try validateWebMediaLease(lease, site: site)
            try await discardSession()
            try Task.checkCancellation()
            try validateContentAccess(site, epoch: lease.epoch)
            guard webMediaGeneration == lease.playback else { throw Self.staleContent() }
            DiagnosticLog.write("[ANDROID_PLAYER_RECOVERY] reason=\(failure.rawValue) action=retire_helper")
            throw failure.payload(retryable: true)
        }
        let requestID = UUID()
        requests[requestID] = (.player, task)
        defer { requests.removeValue(forKey: requestID) }
        operationTail = Task { _ = try? await task.value }
        _ = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    public func searchContent(site: Site, keyword: String, quick: Bool, page: String) async throws -> Result {
        try await result(operation: .search, site: site, arguments: [
            "keyword": .string(keyword), "quick": .bool(quick), "page": .string(page)
        ])
    }

    public func action(site: Site, action: String, value: String) async throws {
        _ = try await response(operation: .action, site: site, arguments: ["action": .string(action), "value": .string(value)])
    }

    func proxy(site: Site, parameters: [String: String]) async throws -> ProxyResponse {
        let value = try await response(operation: .proxy, site: site, arguments: ["parameters": .object(parameters)])
        guard let payload = value.proxy else { throw DevelopmentAndroidRuntimeError.missingProxyPayload }
        let response = try ProviderProxyResponseAdapter.response(from: payload)
        DevelopmentAndroidProxyDiagnostics.captureProxy(response, site: site)
        let diagnostic = DevelopmentAndroidProxyDiagnostics.summary(response: response, payload: payload)
        DiagnosticLog.write(diagnostic)
        print(diagnostic)
        return response
    }

    private func proxyParameters(site: Site, parameters: [String: String]) throws -> [String: String] {
        try validate(site)
        guard DevelopmentAndroidCatVodProxyAdapter.matchesRoute(parameters, site: site, providerID: providerID),
              let routeID = parameters[DevelopmentAndroidCatVodProxyAdapter.routeKey],
              let route = proxyRoutes[routeID] else {
            throw ProviderErrorPayload(code: "android_proxy_route_expired", message: "Android development local proxy route is unavailable; request playback again", retryable: true)
        }
        var original = route.parameters
        // The HTTP server adds player request headers to this dictionary. Keep
        // only the range header needed by a provider, never Host or credentials.
        if let range = parameters["__downstream_range"] {
            guard range.utf8.count <= 256,
                  range.range(of: "^bytes=(?:[0-9]+-[0-9]*|-[0-9]+)(?:,(?:[0-9]+-[0-9]*|-[0-9]+))*$", options: .regularExpression) != nil else {
                throw DevelopmentAndroidCatVodProxyAdapter.invalidDescriptor()
            }
            original["range"] = range
        }
        if let value = parameters["__downstream_if_range"], value.utf8.count <= 4096,
           value.rangeOfCharacter(from: .controlCharacters) == nil { original["if-range"] = value }
        return original
    }

    private func mediaContext(route: ProxyRoute, id: String, arguments: [String: String]) throws -> DevelopmentAndroidProxyDiagnostics.MediaContext {
        let input: [String: ProviderJSONValue] = ["parameters": .object(arguments)]
        return .init(routeID: id, parentRouteID: route.parentRouteID, playerInputSHA256: route.playerInputSHA256,
            proxyInputSHA256: route.remote ? nil : DevelopmentAndroidLifecycleDiagnostics.sha256(try JSONEncoder.providerCanonical.encode(input)),
            originalURLSHA256: DevelopmentAndroidLifecycleDiagnostics.sha256(Data(route.originalURL.utf8)),
            role: route.role?.rawValue ?? "provider")
    }

    private func hlsReference(_ value: String, role: DevelopmentAndroidHLS.Role, site: Site,
                              parent: ProxyRoute, parentID: String) throws -> String? {
        let existing = proxyRoutes.first { $0.value.originalURL == value && $0.value.headers == parent.headers
            && $0.value.role == role && $0.value.parentRouteID == parentID }
        let id = existing?.key ?? UUID().uuidString
        if let local = try DevelopmentAndroidCatVodProxyAdapter.localize(Result(url: value, header: parent.headers),
            site: site, binding: binding, providerID: providerID, routeID: id) {
            if existing == nil {
                try registerProxyRoute(local.parameters, id: id, url: value, headers: parent.headers,
                    role: role, playerInput: parent.playerInputSHA256, parent: parentID)
            }
            return local.result.url
        }
        guard let scheme = URLComponents(string: value)?.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return nil }
        _ = try DevelopmentAndroidHLSRemoteTransport.validate(value)
        if existing == nil {
            try registerProxyRoute([:], id: id, url: value, headers: parent.headers,
                role: role, remote: true, playerInput: parent.playerInputSHA256, parent: parentID)
        }
        var local = URLComponents(string: ProxyServer.shared.getAddress("/proxy"))!
        local.queryItems = [URLQueryItem(name: DevelopmentAndroidCatVodProxyAdapter.markerKey, value: "1"),
            URLQueryItem(name: "from", value: "catvod"), URLQueryItem(name: "providerID", value: providerID),
            URLQueryItem(name: "siteKey", value: site.key), URLQueryItem(name: "siteAPI", value: site.api),
            URLQueryItem(name: "siteType", value: String(site.type)),
            URLQueryItem(name: DevelopmentAndroidCatVodProxyAdapter.routeKey, value: id)]
        guard let url = local.url?.absoluteString else { throw DevelopmentAndroidProxyManifest.unsupported() }
        return url
    }

    private func mappedResponse(_ response: ProxyResponse, site: Site, routeID: String, base: String? = nil) throws -> ProxyResponse {
        guard let route = proxyRoutes[routeID] else { throw DevelopmentAndroidProxyManifest.unsupported() }
        return try DevelopmentAndroidProxyManifest.map(response, originalURL: base ?? route.originalURL,
            hlsLocalize: { try self.hlsReference($0, role: $1, site: site, parent: route, parentID: routeID) }) { value in
            let existing = self.proxyRoutes.first { $0.value.originalURL == value && $0.value.headers == route.headers
                && $0.value.parentRouteID == routeID && $0.value.role == nil }
            let id = existing?.key ?? UUID().uuidString
            guard let child = try DevelopmentAndroidCatVodProxyAdapter.localize(Result(url: value, header: route.headers), site: site,
                binding: self.binding, providerID: self.providerID, routeID: id) else { return nil }
            if existing == nil { try self.registerProxyRoute(child.parameters, id: id, url: value, headers: route.headers,
                playerInput: route.playerInputSHA256, parent: routeID) }
            return child.result.url
        }
    }

    private func mappedProxy(_ payload: ProviderProxyPayload, site: Site, routeID: String) throws -> ProxyResponse {
        try mappedResponse(ProviderProxyResponseAdapter.response(from: payload), site: site, routeID: routeID)
    }

    private func routePayload(site: Site, parameters: [String: String],
                              context: DevelopmentAndroidProxyDiagnostics.MediaContext? = nil) async throws -> (ProviderProxyPayload, String) {
        let arguments = try proxyParameters(site: site, parameters: parameters)
        let routeID = parameters[DevelopmentAndroidCatVodProxyAdapter.routeKey]!
        let value = try await response(operation: .proxy, site: site, arguments: ["parameters": .object(arguments)])
        try Task.checkCancellation()
        guard proxyRoutes[routeID] != nil, let payload = value.proxy else { throw DevelopmentAndroidProxyManifest.unsupported() }
        let route = proxyRoutes[routeID]!
        let context = try context ?? mediaContext(route: route, id: routeID, arguments: arguments)
        let original = try ProviderProxyResponseAdapter.response(from: payload)
        if payload.localStreamURL == nil {
            DevelopmentAndroidProxyDiagnostics.captureExchange(original, context: context)
            DevelopmentAndroidProxyDiagnostics.captureProxy(original, site: site)
        }
        return (payload, routeID)
    }

    func proxyRoute(site: Site, parameters: [String: String]) async throws -> ProxyResponse {
        if let id = parameters[DevelopmentAndroidCatVodProxyAdapter.routeKey], proxyRoutes[id]?.remote == true {
            throw ProviderErrorPayload(code: "android_proxy_streaming_required", message: "原版媒体流需要流式播放器连接")
        }
        let (payload, id) = try await routePayload(site: site, parameters: parameters)
        guard payload.localStreamURL == nil else {
            throw ProviderErrorPayload(code: "android_proxy_streaming_required", message: "原版媒体流需要流式播放器连接")
        }
        return try mappedProxy(payload, site: site, routeID: id)
    }

    func streamProxyRoute(site: Site, parameters: [String: String],
                          sendHead: @escaping @Sendable (ProxyStreamingResponseHead) async throws -> Void,
                          sendBody: @escaping @Sendable (Data) async throws -> Void) async throws {
        let arguments = try proxyParameters(site: site, parameters: parameters)
        let id = parameters[DevelopmentAndroidCatVodProxyAdapter.routeKey]!
        let route = proxyRoutes[id]!
        let context = try mediaContext(route: route, id: id, arguments: arguments)
        let headOnly = parameters["__downstream_method"] == "HEAD"
        let output = DevelopmentAndroidHLSStream(role: route.role, headOnly: headOnly,
            rangeRequested: !DevelopmentAndroidHLS.isWholeBodyRequest(parameters["__downstream_range"]), sendHead: sendHead, sendBody: sendBody,
            observe: { DevelopmentAndroidProxyDiagnostics.captureStream($0, context: context) })
        let work = Task {
            do {
                if route.remote {
                    let repair = route.codecPatchOffsets.isEmpty ? nil : DevelopmentAndroidMP4CodecRepairStream(offsets: route.codecPatchOffsets)
                    var headers = route.headers
                    if let range = arguments["range"] { headers["Range"] = range }
                    if let range = arguments["if-range"] { headers["If-Range"] = range }
                    try await DevelopmentAndroidHLSRemoteTransport.send(url: route.originalURL, headers: headers,
                        role: route.role ?? .opaque, headOnly: headOnly,
                        mapPlaylist: { response, base in
                            DevelopmentAndroidProxyDiagnostics.captureExchange(response, context: context)
                            return try await self.mappedResponse(response, site: site, routeID: id, base: base)
                        }, sendHead: { head in
                            try await output.head(repair == nil ? head : try await repair!.head(head))
                        }, sendBody: { data in
                            try await output.body(repair == nil ? data : try await repair!.body(data))
                        })
                } else {
                    let (payload, _) = try await routePayload(site: site, parameters: parameters, context: context)
                    if payload.localStreamURL != nil {
                        try await DevelopmentAndroidStreamTransport.send(payload, headOnly: headOnly,
                            sendHead: { try await output.head($0) }, sendBody: { try await output.body($0) })
                    } else {
                        let response = try mappedProxy(payload, site: site, routeID: id)
                        try await output.head(ProxyStreamingResponseHead(statusCode: response.statusCode,
                            contentType: response.contentType, contentLength: response.data.count,
                            headers: response.headers, closeConnection: true))
                        if !headOnly { try await output.body(response.data) }
                    }
                }
                try await output.finish()
            } catch {
                await output.failed()
                throw error
            }
        }
        let token = UUID()
        streams[token] = work
        defer {
            streams.removeValue(forKey: token)
            scheduleIdleShutdown()
        }
        try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    public static func streamProxyIfEnabled(parameters: [String: String],
        sendHead: @escaping @Sendable (ProxyStreamingResponseHead) async throws -> Void,
        sendBody: @escaping @Sendable (Data) async throws -> Void) async throws -> Bool {
        try await DevelopmentAndroidRuntimeRegistration.shared.streamProxy(parameters: parameters,
            sendHead: sendHead, sendBody: sendBody)
    }

    func cancelPlayback() async {
        invalidateContentAccess()
        proxyRoutes.removeAll()
        hasPlayback = false
        releaseWhenIdle = true
        for (operation, request) in requests.values where [.player, .proxy, .manualVideoCheck, .isVideoFormat].contains(operation) { request.cancel() }
        for stream in streams.values { stream.cancel() }
        if canStopIdleHelper { await shutdown() }
    }

    private var canStopIdleHelper: Bool {
        client != nil && !closed && !hasPlayback && preparingPlaybackCount == 0 && requests.isEmpty && streams.isEmpty
    }

    private func scheduleIdleShutdown() {
        idleShutdown?.cancel()
        idleShutdown = nil
        guard canStopIdleHelper else { return }
        let delay = releaseWhenIdle ? Duration.zero : idleShutdownDelay
        idleShutdown = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            await self?.stopIdleHelper()
        }
    }

    private func stopIdleHelper() async {
        guard !Task.isCancelled, canStopIdleHelper else { return }
        idleShutdown = nil
        await shutdown()
    }

    public static func cancelPlaybackIfEnabled(site: Site) async {
        await DevelopmentAndroidRuntimeRegistration.shared.cancelPlayback(site: site)
    }

    func shutdown() async {
        idleShutdown?.cancel()
        idleShutdown = nil
        hasPlayback = false
        releaseWhenIdle = false
        invalidateContentAccess()
        if let shutdownJob { await shutdownJob.value; return }
        closed = true
        for (_, request) in requests.values { request.cancel() }
        for stream in streams.values { stream.cancel() }
        let pending = operationTail
        let job = Task { [self] in
            await pending?.value
            if let client {
                if await client.isRunning {
                    _ = try? await client.request(ProviderRequest(providerID: providerID, operation: .destroy), timeout: .seconds(3))
                }
                await client.stop()
                try? await client.stopAndConfirmExit()
            }
            client = nil
            initializedConfiguration = nil
            initializedDrive = nil
            proxyRoutes.removeAll()
            shutdownJob = nil
            closed = false
        }
        shutdownJob = job
        await job.value
    }

    /// Registration replacement is permanent; a stale UI/proxy reference must
    /// not restart an old artifact after it has been removed from configuration.
    func retire() async {
        retired = true
        await shutdown()
    }

    private func result(operation: ProviderOperation, site: Site, arguments: [String: ProviderJSONValue] = [:]) async throws -> Result {
        let value = try await response(operation: operation, site: site, arguments: arguments)
        guard var result = try Self.decodeContent(value, operation: operation, site: site) else {
            throw ProviderErrorPayload(code: "missing_result", message: "Android development Provider response did not contain a result")
        }
        result.list = result.list.map { vod in
            var original = vod
            original.originalAndroidEpisodeParsing = true
            return original
        }
        return result
    }

    /// CatVod returns JSON text; a provider may encode that text again before
    /// the runner sees it. Normalize only this development bridge's payload.
    private static func decodeContent(_ response: ProviderResponse, operation: ProviderOperation, site: Site, allowsEmpty: Bool = false) throws -> Result? {
        try requireSuccess(response)
        if operation == .category {
            let result = decodeCategoryPayload(response.result)
            if let shape = result.androidCategoryPayload, shape != .object {
                DiagnosticLog.write("[ANDROID_PROVIDER_CATEGORY_EMPTY] site=\(ProviderDiagnostics.redact(site.key)) payload=\(shape.rawValue) \(resultShape(response.result))")
            }
            return result
        }
        do {
            return try decodePayload(response.result, allowsEmpty: allowsEmpty)
        } catch {
            let diagnostic = "[ANDROID_PROVIDER_RESULT_SHAPE] site=\(ProviderDiagnostics.redact(site.key)) op=\(operation.rawValue) \(resultShape(response.result))"
            DiagnosticLog.write(diagnostic)
            print(diagnostic)
            throw error
        }
    }

    /// ja3.call -> Result.fromJson catches JSON errors and returns Result.empty.
    /// Transport/Spider errors have already been checked above and still throw.
    private static func decodeCategoryPayload(_ payload: ProviderJSONValue?) -> Result {
        func empty(_ shape: Result.AndroidCategoryPayload) -> Result {
            var result = Result.empty
            result.androidCategoryPayload = shape
            return result
        }
        var value = payload ?? .null
        let padding = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))
        for _ in 0..<2 {
            guard case .string(let text) = value else { break }
            let trimmed = text.trimmingCharacters(in: padding)
            if trimmed.isEmpty { return empty(.emptyText) }
            guard let decoded = try? JSONDecoder().decode(ProviderJSONValue.self, from: Data(trimmed.utf8)) else {
                return empty(.invalidJSON)
            }
            value = decoded
        }
        if value == .null { return empty(.nullValue) }
        guard case .object(let object) = value else { return empty(.invalidJSON) }
        // Gson rejects a non-array list as a whole Result, rather than keeping
        // other fields from a partly decoded object (for example pagecount).
        if let list = object["list"], list != .null {
            guard case .array = list else { return empty(.invalidObject) }
        }
        // The original Result getter returns zero for missing/null pagecount.
        // Provider JSON cannot supply our Swift-only known-value bookkeeping.
        var categoryObject = object
        categoryObject.removeValue(forKey: "pageCountIsKnown")
        categoryObject.removeValue(forKey: "pageIsKnown")
        if categoryObject["pagecount"] == nil || categoryObject["pagecount"] == .null {
            categoryObject["pagecount"] = .number(0)
        }
        guard var result = try? decodePayload(.object(categoryObject), allowsEmpty: false) else { return empty(.invalidObject) }
        result.androidCategoryPayload = .object
        return result
    }

    private static func decodePayload(_ payload: ProviderJSONValue?, allowsEmpty: Bool) throws -> Result? {
        guard var value = payload else {
            if allowsEmpty { return nil }
            throw ProviderErrorPayload(code: "missing_result", message: "Android development Provider response did not contain a result")
        }
        let padding = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))
        for _ in 0..<2 {
            guard case .string(let text) = value else { break }
            let trimmed = text.trimmingCharacters(in: padding)
            if trimmed.isEmpty {
                if allowsEmpty { return nil }
                throw invalidContent("an empty string")
            }
            guard let decoded = try? JSONDecoder().decode(ProviderJSONValue.self, from: Data(trimmed.utf8)) else {
                throw invalidContent("text that is not JSON")
            }
            value = decoded
        }
        if allowsEmpty, value == .null { return nil }
        guard case .object(var object) = value else {
            throw invalidContent("a non-object JSON value or more than two JSON string wrappers")
        }
        if case .string(let header) = object["header"] {
            let trimmed = header.trimmingCharacters(in: padding)
            if trimmed.isEmpty {
                object["header"] = .object([String: ProviderJSONValue]())
            } else {
                guard let headers = try? JSONDecoder().decode([String: String].self, from: Data(trimmed.utf8)) else {
                    throw ProviderErrorPayload(code: "invalid_android_header", message: "Android development Provider returned a header string that is not a JSON object of strings")
                }
                object["header"] = .object(headers)
            }
        }
        let qualities = try qualityURLs(object["url"])
        if let first = qualities.first { object["url"] = .string(first.url) }
        try normalizeFolders(&object)
        var decoded = try ProviderJSONValue.object(object).decode(Result.self)
        if !qualities.isEmpty {
            guard decoded.playbackCandidates.isEmpty else { throw invalidQualityURLs() }
            decoded.playbackCandidates = qualities.map { quality in
                PlaybackCandidate(providerKey: AndroidRuntimeComponentStore.providerID, providerName: "Android Provider",
                    name: quality.name, kind: .directURL, status: .playable, url: quality.url,
                    headers: decoded.header, format: decoded.format, subtitles: decoded.subs,
                    bingeGroup: "catvod-quality:" + quality.name)
            }
        }
        return decoded
    }

    /// CatVod uses alternating quality labels and URLs, including local proxy
    /// descriptors. Preserve every option for the existing playback picker.
    private static func qualityURLs(_ value: ProviderJSONValue?) throws -> [(name: String, url: String)] {
        guard case .array(let values) = value else { return [] }
        guard !values.isEmpty, values.count <= 64, values.count.isMultiple(of: 2) else { throw invalidQualityURLs() }
        var qualities = [(name: String, url: String)]()
        for index in stride(from: 0, to: values.count, by: 2) {
            guard case .string(let name) = values[index], case .string(let url) = values[index + 1],
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 256,
                  !url.isEmpty, url.utf8.count <= 128 * 1024,
                  !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  !url.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw invalidQualityURLs()
            }
            qualities.append((name, url))
        }
        return qualities
    }

    private static func invalidQualityURLs() -> ProviderErrorPayload {
        ProviderErrorPayload(code: "invalid_android_player_urls", message: "Android development Provider returned an invalid labelled playback URL array")
    }

    private static func normalizeFolders(_ object: inout [String: ProviderJSONValue]) throws {
        guard case .array(var list) = object["list"] else { return }
        for index in list.indices {
            guard case .object(var vod) = list[index] else { continue }
            // FongMi Vod.isFolder: exact tag or a non-null Cate presentation.
            // IDs and playback fields are opaque and never change folder semantics.
            let hasCate: Bool
            switch vod["cate"] {
            case nil, .null: hasCate = false
            case .object: hasCate = true
            default: throw invalidContent("an invalid folder cate")
            }
            vod["is_folder"] = .bool(vod["vod_tag"] == .string("folder") || hasCate)
            list[index] = .object(vod)
        }
        object["list"] = .array(list)
    }

    private static func invalidContent(_ shape: String) -> ProviderErrorPayload {
        ProviderErrorPayload(code: "invalid_android_result", message: "Android development Provider returned \(shape); expected a JSON object")
    }

    /// Deliberately records types and lengths only: no provider text, URLs or headers.
    private static func resultShape(_ value: ProviderJSONValue?, includesHeader: Bool = true) -> String {
        guard let value else { return "result_type=missing" }
        switch value {
        case .null: return "result_type=null"
        case .bool: return "result_type=boolean"
        case .number: return "result_type=number"
        case .array: return "result_type=array json_object=false json_array=true"
        case .object(let object):
            let header = includesHeader ? (object["header"].map { " header_" + resultShape($0, includesHeader: false) } ?? "") : ""
            return "result_type=object json_object=true json_array=false" + header
        case .string(let text):
            let padding = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))
            let trimmed = text.trimmingCharacters(in: padding)
            let parsed = try? JSONDecoder().decode(ProviderJSONValue.self, from: Data(trimmed.utf8))
            let isObject: Bool
            let isArray: Bool
            if case .object = parsed { isObject = true } else { isObject = false }
            if case .array = parsed { isArray = true } else { isArray = false }
            return "result_type=string utf8_bytes=\(text.utf8.count) empty=\(trimmed.isEmpty) json_valid=\(parsed != nil) json_object=\(isObject) json_array=\(isArray)"
        }
    }

    private func response(operation: ProviderOperation, site: Site, arguments: [String: ProviderJSONValue] = [:], webLease: WebMediaLease? = nil) async throws -> ProviderResponse {
        await shutdownJob?.value
        try Task.checkCancellation()
        try validate(site)
        let enqueued = ProcessInfo.processInfo.systemUptime
        let previous = operationTail
        let task = Task { [self] in
            await previous?.value
            try Task.checkCancellation()
            if let webLease { try validateWebMediaLease(webLease, site: site) }
            return try await requestUnlocked(operation: operation, site: site, arguments: arguments, enqueued: enqueued, webLease: webLease)
        }
        let requestID = UUID()
        requests[requestID] = (operation, task)
        defer {
            requests.removeValue(forKey: requestID)
            scheduleIdleShutdown()
        }
        operationTail = Task { _ = try? await task.value }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func requestUnlocked(operation: ProviderOperation, site: Site, arguments: [String: ProviderJSONValue], enqueued: TimeInterval, webLease: WebMediaLease?) async throws -> ProviderResponse {
        try validate(site)
        let started = ProcessInfo.processInfo.systemUptime
        var observation = DevelopmentAndroidLifecycleDiagnostics.Event(.providerRequest, siteKey: site.key)
        if DevelopmentAndroidLifecycleDiagnostics.isEnabled {
            observation.operation = operation.rawValue
            observation.helperSession = diagnosticSession
            observation.cacheEpoch = contentCacheEpoch
            observation.queueMS = max(0, (started - enqueued) * 1_000)
            observation.inputSHA256 = (try? JSONEncoder.providerCanonical.encode(arguments)).map(DevelopmentAndroidLifecycleDiagnostics.sha256)
            observation.siteConfigurationSHA256 = (try? JSONEncoder.providerCanonical.encode(site)).map(DevelopmentAndroidLifecycleDiagnostics.sha256)
        }
        observation.outcome = "failed"
        defer {
            observation.helperGeneration = helperGeneration
            observation.elapsedMS = max(0, (ProcessInfo.processInfo.systemUptime - started) * 1_000)
            DevelopmentAndroidLifecycleDiagnostics.record(observation)
        }
        // An original SDK may spend its full 30-second authorization window
        // inside playerContent. Leave time for Activity creation and callbacks
        // before the process deadline can retire that live authorization UI.
        let minimumTimeout = operation == .player && runtime.desktopUIEnabled ? 45 : 30
        let timeout = Duration.seconds(min(max(site.timeout, minimumTimeout), 45))
        var failureStage = DevelopmentAndroidLifecycleDiagnostics.FailureStage.session
        do {
            let configuration = try JSONEncoder.providerCanonical.encode(site)
            // Android sources share SDK-owned cloud accounts. Native account
            // changes never select or populate this Android account store.
            let selectedDrive = runtime.compatibilityPolicy.flatMap { policy in
                guard case .string(let id) = arguments["id"] else { return nil as DriveProvider? }
                return policy.cloudDrive(api: binding.api, className: binding.className,
                    operation: operation.rawValue, id: id).flatMap(DriveProvider.init(rawValue:))
            }
                ?? ((operation == .player || operation == .detail) ? nil : initializedDrive)
            if initializedConfiguration != nil, initializedConfiguration != configuration {
                try await discardSession()
                if webLease != nil { throw Self.staleContent() }
                if operation == .proxy {
                    throw ProviderErrorPayload(code: "android_proxy_route_expired",
                        message: "视频源配置已变化，请重新打开当前剧集", retryable: true)
                }
            }
            let persistentData = try runtime.persistentDataDirectory(base: sessionStateRoot, binding: binding, site: site)
            let accountCheckout: AndroidSharedAccountStore.Checkout?
            if operation != .proxy, webLease == nil,
               client == nil || operation == .player || operation == .detail {
                let checkout = try AndroidSharedAccountStore.checkout(root: sessionStateRoot, source: persistentData)
                if checkout.requiresReload {
                    try await discardSession()
                    DiagnosticLog.write("[ANDROID_SHARED_ACCOUNT] action=reload_source_session")
                }
                try AndroidSharedAccountStore.apply(checkout)
                accountCheckout = checkout
            } else {
                accountCheckout = nil
            }
            defer {
                if let accountCheckout {
                    do { try AndroidSharedAccountStore.publish(accountCheckout) }
                    catch { DiagnosticLog.write("[ANDROID_SHARED_ACCOUNT] action=publish_failed") }
                }
            }
            let sessionStart = ProcessInfo.processInfo.systemUptime
            let client = try await session(persistentData: persistentData, authorizationDrive: selectedDrive)
            // A retained helper can switch cloud drives without changing its
            // account scope. Update only the presentation enum, never a token.
            try (selectedDrive?.rawValue ?? "").write(
                to: persistentData.appendingPathComponent(".runtime/authorization-drive"),
                atomically: true, encoding: .utf8)
            if let webLease {
                do { try validateWebMediaLease(webLease, site: site) }
                catch { try await discardSession(); throw error }
            }
            observation.sessionMS = max(0, (ProcessInfo.processInfo.systemUptime - sessionStart) * 1_000)
            if initializedConfiguration != configuration {
                failureStage = .initialize
                let initializeStart = ProcessInfo.processInfo.systemUptime
                let initialized = try await client.request(ProviderRequest(
                    providerID: providerID, operation: .initialize, site: site, arguments: ["extend": .string(site.ext)]
                ), timeout: .seconds(40))
                observation.initializeMS = max(0, (ProcessInfo.processInfo.systemUptime - initializeStart) * 1_000)
                try Self.requireSuccess(initialized)
                initializedConfiguration = configuration
            }
            // Drive is presentation context only; all drives share this source
            // Context while the SDK owns their separate account records.
            initializedDrive = selectedDrive
            failureStage = .operation
            let operationStart = ProcessInfo.processInfo.systemUptime
            if let webLease { try validateWebMediaLease(webLease, site: site) }
            let value = try await client.request(ProviderRequest(
                providerID: providerID, operation: operation, site: site, arguments: arguments
            ), timeout: timeout, interaction: runtime.desktopUIEnabled && operation == .player
                ? ProviderInteractionPolicy(directory: persistentData.appendingPathComponent(".runtime"),
                    onDialogActive: Self.activateInteractionHelper) : nil)
            observation.operationMS = max(0, (ProcessInfo.processInfo.systemUptime - operationStart) * 1_000)
            try Self.requireSuccess(value)
            observation.outcome = "received"
            if DevelopmentAndroidLifecycleDiagnostics.isEnabled, let result = value.result {
                observation.resultSHA256 = (try? JSONEncoder.providerCanonical.encode(result)).map(DevelopmentAndroidLifecycleDiagnostics.sha256)
            }
            DevelopmentAndroidProxyDiagnostics.captureResult(value, operation: operation, site: site)
            // Some UC SDK sessions retain their pre-login state after saving the
            // successful QR login. Retire only that helper; the source Context
            // and its saved account remain intact. AppState owns the one retry
            // budget, so this must not introduce another retry loop here.
            if operation == .player, selectedDrive == .uc,
               case .string(let id) = arguments["id"],
               let decoded = try Self.decodeContent(value, operation: operation, site: site),
               Self.hasUnresolvedPlayerPayload(decoded, id: id) {
                observation.outcome = "unresolved_player"
                try Task.checkCancellation()
                try await discardSession()
                DiagnosticLog.write("[ANDROID_PLAYER_RECOVERY] reason=unresolved_uc_address action=retire_helper")
                throw Self.unresolvedPlayerError(retryable: true)
            }
            return value
        } catch let error as ProviderInteractionError {
            observation.outcome = error == .canceled ? "canceled" : "interaction_timeout"
            observation.failure = .init(error, stage: failureStage)
            try await discardSession()
            if error == .canceled { throw CancellationError() }
            // An authorization timeout must not silently restart the SDK and QR.
            throw error
        } catch let error as ProviderProcessError {
            observation.outcome = "process_error"
            observation.failure = .init(error, stage: failureStage)
            try await discardSession()
            throw error
        } catch {
            observation.failure = .init(error, stage: failureStage)
            // A rejected init can already have run JNI_OnLoad or registered
            // native methods. Retrying with a second loader in this VM is unsafe.
            if failureStage == .initialize { try await discardSession() }
            throw error
        }
    }

    private func discardSession() async throws {
        if let client {
            await client.stop(graceful: false)
            try await client.stopAndConfirmExit()
        }
        client = nil
        initializedConfiguration = nil
        initializedDrive = nil
        proxyRoutes.removeAll()
    }

    @MainActor
    private static func activateInteractionHelper(processID: Int32) async {
        let host = NSRunningApplication.current
        for _ in 0..<6 {
            guard !Task.isCancelled,
                  let helper = NSRunningApplication(processIdentifier: processID),
                  !helper.isTerminated else { return }
            if helper.isActive { return }
            // The user may have switched apps while the provider was loading.
            guard host.isActive, let app = NSApp else { return }
            app.yieldActivation(to: helper)
            _ = helper.activate(from: host, options: [.activateAllWindows])
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        }
    }

    private func session(persistentData: URL, authorizationDrive: DriveProvider?) async throws -> ProviderProcessClient {
        if let client, await client.isRunning { return client }
        if let client { try await client.stopAndConfirmExit() }
        initializedConfiguration = nil
        initializedDrive = nil
        try FileManager.default.createDirectory(at: sessionStateRoot, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sessionStateRoot.path)
        let command = try runtime.command(binding: binding, stateDirectory: stateDirectory,
            persistentDataDirectory: persistentData, authorizationDrive: authorizationDrive)
        helperGeneration &+= 1
        if DevelopmentAndroidLifecycleDiagnostics.isEnabled {
            var observation = DevelopmentAndroidLifecycleDiagnostics.Event(.providerSession, siteKey: binding.key)
            observation.helperSession = diagnosticSession
            observation.persistentStateSHA256 = DevelopmentAndroidLifecycleDiagnostics.sha256(Data(persistentData.path.utf8))
            observation.helperGeneration = helperGeneration
            observation.cacheEpoch = contentCacheEpoch
            // Hash actual loaded bytes, including the converted artifact and
            // classpath; the declared manifest alone is insufficient evidence.
            observation.artifactSHA256 = try? runtime.diagnosticArtifactHashes()
            observation.outcome = observation.artifactSHA256 == nil ? "identity_unavailable" : "starting"
            DevelopmentAndroidLifecycleDiagnostics.record(observation)
        }
        let candidate = ProviderProcessClient(command: command)
        client = candidate
        DiagnosticLog.write("[ANDROID_PROVIDER_DEVELOPMENT] backend=emulated site=\(ProviderDiagnostics.redact(binding.key)) class=\(binding.className)")
        do {
            let handshake = try await candidate.request(ProviderRequest(providerID: providerID, operation: .handshake), timeout: .seconds(15))
            try Self.requireSuccess(handshake)
            guard case .object(let result) = handshake.result,
                  result["provider_id"] == .string(providerID), result["protocol"] == .number(1) else {
                throw DevelopmentAndroidRuntimeError.invalidHandshake
            }
            return candidate
        } catch {
            await candidate.stop(graceful: false)
            try await candidate.stopAndConfirmExit()
            client = nil
            throw error
        }
    }

    private func validate(_ site: Site) throws {
        guard !closed, !retired else { throw DevelopmentAndroidRuntimeError.closed }
        guard site.key == binding.key, site.api == binding.api else {
            throw DevelopmentAndroidRuntimeError.siteMismatch
        }
    }

    private func invalidateContentAccess() {
        contentCacheEpoch &+= 1
    }

    private func beginContentAccess(_ site: Site) throws -> UInt64 {
        try Task.checkCancellation()
        try validate(site)
        return contentCacheEpoch
    }

    private func validateContentAccess(_ site: Site, epoch: UInt64) throws {
        try Task.checkCancellation()
        guard epoch == contentCacheEpoch, !closed else { throw Self.staleContent() }
        try validate(site)
    }

    private static func staleContent() -> ProviderErrorPayload {
        ProviderErrorPayload(code: "android_content_stale", message: "站点内容已清理或重启，请重新打开详情后重试", retryable: true)
    }

    private static func requireSuccess(_ response: ProviderResponse) throws {
        guard response.ok else {
            throw (response.error ?? ProviderErrorPayload(code: "provider_failed", message: "Android development Provider request failed")).redacted
        }
    }
}

/// The observed Quark episode is already a file reference. Use our existing
/// account flow only for that exact schema, without carrying the share session.
enum DevelopmentAndroidQuarkEpisodeAdapter {
    private static let keys: Set<String> = [
        "pg", "parent", "l_created_at", "sId", "sToken", "shareUser", "share_fid_token", "fid",
        "format_type", "vodName", "pdir_fid", "sub", "size", "flag", "file_name"
    ]

    static func reference(id: String, flag: String) -> DriveFileReference? {
        // Observed providers use both unnumbered labels and positive numbered
        // variants of the same Quark episode schema.
        guard flag.utf8.count <= 32,
              flag.range(of: "^夸父(?:原|智)(?:[1-9][0-9]*)?$", options: .regularExpression) == (flag.startIndex..<flag.endIndex),
              id.utf8.count <= 64 * 1024,
              case .object(let object) = try? JSONDecoder().decode(ProviderJSONValue.self, from: Data(id.utf8)),
              Set(object.keys) == keys, object["flag"] == .string("夸父盘"),
              let shareID = text(object["sId"], limit: 128),
              shareID.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil,
              let fid = text(object["fid"], limit: 1024),
              let fidToken = text(object["share_fid_token"], limit: 16 * 1024),
              let fileName = text(object["file_name"], limit: 4096),
              let collectionName = text(object["vodName"], limit: 4096, allowsEmpty: true),
              let formatType = text(object["format_type"], limit: 128, allowsEmpty: true) else { return nil }
        let size: Int64?
        switch object["size"] {
        case .number(let value): size = Int64(exactly: value)
        case .string(let value): size = Int64(value)
        default: size = nil
        }
        guard let size, size >= 0 else { return nil }
        return DriveFileReference(provider: .quark, shareURL: "https://pan.quark.cn/s/" + shareID, pwdID: shareID,
            fid: fid, fidToken: fidToken, fileName: fileName, collectionName: collectionName, size: size, formatType: formatType)
    }

    private static func text(_ value: ProviderJSONValue?, limit: Int, allowsEmpty: Bool = false) -> String? {
        guard case .string(let text) = value, text.utf8.count <= limit,
              allowsEmpty || !text.isEmpty, text.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return text
    }
}

/// Only a verified development provider can turn a CatVod loopback descriptor
/// into one of this process's opaque routes. No upstream URL reaches the generic
/// playback handlers, which run before the raw CatVod hook.
enum DevelopmentAndroidCatVodProxyAdapter {
    static let markerKey = "android_runtime"
    static let routeKey = "android_route"
    private static func accepts(providerID: String) -> Bool {
        if providerID == AndroidRuntimeComponentStore.providerID { return true }
        #if DEBUG
        return providerID == "android-runtime-experiment"
        #else
        return false
        #endif
    }
    private static let ports: Set<String> = ["-1", "9978", "9979", "9999"]
    private static let routingKeys: Set<String> = [
        "from", "sitekey", "site_key", "siteapi", "sitetype", "site_type", "providerid", "provider_id", markerKey, routeKey
    ]

    static func localize(
        _ result: Result, site: Site, binding: DevelopmentAndroidRuntimeManifest.Binding,
        providerID: String, routeID: String, permitsDirectLocalServer: Bool = false,
        proxyAddress: String = ProxyServer.shared.getAddress("/proxy")
    ) throws -> (result: Result, parameters: [String: String])? {
        guard let separator = result.url.range(of: "://") else { return nil }
        let scheme = result.url[..<separator.lowerBound].lowercased()
        let remainder = result.url[separator.upperBound...]
        let boundary = remainder.firstIndex(where: { "/?#".contains($0) }) ?? remainder.endIndex
        let authority = String(remainder[..<boundary]).lowercased()
        let suffix = String(remainder[boundary...])
        let host: String
        let port: String?
        if authority.hasPrefix("["), let closing = authority.firstIndex(of: "]") {
            host = String(authority[...closing])
            let tail = authority[authority.index(after: closing)...]
            port = tail.hasPrefix(":") ? String(tail.dropFirst()) : nil
        } else {
            let parts = authority.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count <= 2 else { return nil }
            host = parts.first.map(String.init) ?? ""
            port = parts.count == 2 ? String(parts[1]) : nil
        }
        guard ["127.0.0.1", "localhost", "[::1]"].contains(host),
              let descriptor = URLComponents(string: "http://127.0.0.1" + suffix),
              descriptor.percentEncodedPath == "/proxy" else { return nil }
        // Cloud SDKs can own real HTTP servers in the helper process (for
        // example port 6677). Their attachment URLs must reach that server;
        // only the original host's CatVod ports are rebound to proxy callbacks.
        if permitsDirectLocalServer, let port, !ports.contains(port) { return nil }
        guard scheme == "http", port.map(ports.contains) == true, descriptor.fragment == nil,
              result.url.utf8.count <= 128 * 1024,
              accepts(providerID: providerID), site.key == binding.key, site.api == binding.api else {
            throw invalidDescriptor()
        }
        let items = descriptor.queryItems ?? []
        guard items.count <= 64, Set(items.map(\.name)).count == items.count else { throw invalidDescriptor() }
        var original: [String: String] = [:]
        for item in items where !routingKeys.contains(item.name.lowercased()) && !item.name.hasPrefix("__") {
            guard !item.name.isEmpty, item.name.utf8.count <= 128 else { throw invalidDescriptor() }
            original[item.name] = item.value ?? ""
        }
        guard let operation = original["do"], !operation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw invalidDescriptor()
        }
        if !result.header.isEmpty, original["header"] == nil, original["headers"] == nil {
            original["headers"] = String(decoding: try JSONEncoder.providerCanonical.encode(result.header), as: UTF8.self)
        }
        guard original.reduce(0, { $0 + $1.key.utf8.count + $1.value.utf8.count }) <= 128 * 1024,
              var local = URLComponents(string: proxyAddress), local.scheme == "http", local.host == "127.0.0.1",
              local.path == "/proxy", local.port.map({ (1...65535).contains($0) }) == true else {
            throw invalidDescriptor()
        }
        local.queryItems = [
            URLQueryItem(name: markerKey, value: "1"), URLQueryItem(name: "from", value: "catvod"),
            URLQueryItem(name: "providerID", value: providerID), URLQueryItem(name: "siteKey", value: site.key),
            URLQueryItem(name: "siteAPI", value: site.api), URLQueryItem(name: "siteType", value: String(site.type)),
            URLQueryItem(name: routeKey, value: routeID)
        ]
        guard let url = local.url?.absoluteString else { throw invalidDescriptor() }
        var localized = result
        localized.url = url
        localized.parse = 0
        localized.jx = 0
        // HLS/DASH manifests can reference the provider's CDN directly. mpv
        // must carry the same media headers to those segment requests as the
        // Android player; only downstream headers entering the helper are filtered.
        localized.header = result.header
        localized.key = site.key
        return (localized, original)
    }

    static func matchesRoute(_ parameters: [String: String], site: Site, providerID: String) -> Bool {
        accepts(providerID: providerID) && parameters[markerKey] == "1" && parameters["from"] == "catvod"
            && parameters["providerID"] == providerID && parameters["siteKey"] == site.key
            && parameters["siteAPI"] == site.api && parameters["siteType"] == String(site.type)
    }

    static func invalidDescriptor() -> ProviderErrorPayload {
        ProviderErrorPayload(code: "invalid_android_proxy", message: "Android development Provider returned an invalid CatVod local proxy descriptor")
    }
}

enum DevelopmentAndroidRuntimeError: LocalizedError, Equatable {
    case invalidBundle(String)
    case siteMismatch
    case invalidHandshake
    case missingProxyPayload
    case closed

    var errorDescription: String? {
        switch self {
        case .invalidBundle(let reason): return "Android development runtime: \(reason)"
        case .siteMismatch: return "Android development Provider does not match this exact site key and API"
        case .invalidHandshake: return "Android development Provider handshake did not match the bundled runtime"
        case .missingProxyPayload: return "Android development Provider returned no proxy payload"
        case .closed: return "Android development Provider has been stopped"
        }
    }
}

struct DevelopmentAndroidRuntimeManifest: Decodable, Sendable {
    struct Binding: Codable, Hashable, Sendable {
        let key: String
        let api: String
        let className: String
    }
    let schema: Int
    let providerID: String
    let backend: String?
    let providerSHA256: String
    let hostSHA256: String
    let bindings: [Binding]
    let bootstrapClass: String?
    let package: String?
    var compatibility: AndroidCompatibilityPolicy? = nil
    var modules: [String]? = nil
}

struct DevelopmentAndroidRuntimeLayout: Sendable {
    let root: URL
    var compatibilityPolicy: AndroidCompatibilityPolicy? { manifest.compatibility ?? .bundled }

    var desktopUIEnabled: Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent("desktop-ui-framework-provenance.json").path)
    }
    let manifest: DevelopmentAndroidRuntimeManifest
    let classPath: [URL]
    let providerArtifact: DevelopmentAndroidProviderArtifact?
    let componentIdentity: String?
    var providerSHA256: String { providerArtifact?.sha256 ?? manifest.providerSHA256 }

    func stateIdentity(binding: DevelopmentAndroidRuntimeManifest.Binding) throws -> String {
        struct Identity: Encodable {
            let schema = 3
            let binding: DevelopmentAndroidRuntimeManifest.Binding
            let provider, host, bootstrap, package, component, conversion: String
        }
        let identity = Identity(binding: binding, provider: providerSHA256, host: manifest.hostSHA256,
            bootstrap: manifest.bootstrapClass ?? "com.github.catvod.spider.Init", package: manifest.package ?? "com.fongmi.android.tv",
            component: try conversionIdentity(), conversion: try providerArtifact?.convertedSHA256 ?? Self.digest(root.appendingPathComponent("converted/provider-jvm.jar")))
        return SHA256.hash(data: try JSONEncoder.providerCanonical.encode(identity)).map { String(format: "%02x", $0) }.joined()
    }

    func persistentDataDirectory(base: URL, binding: DevelopmentAndroidRuntimeManifest.Binding, site: Site) throws -> URL {
        struct SourceSession: Encodable {
            let schema = 1
            let binding: DevelopmentAndroidRuntimeManifest.Binding
            let type: Int
            let ext, bootstrap, package: String
        }
        // The session outlives helper, component and SDK updates. Presentation
        // metadata and native account values cannot select another login scope.
        // Actual source configuration changes still receive an isolated Context.
        let source = SourceSession(binding: binding, type: site.type, ext: site.ext,
            bootstrap: manifest.bootstrapClass ?? "com.github.catvod.spider.Init",
            package: manifest.package ?? "com.fongmi.android.tv")
        let identity = SHA256.hash(data: try JSONEncoder.providerCanonical.encode(source)).map { String(format: "%02x", $0) }.joined()
        return base.appendingPathComponent(identity, isDirectory: true)
    }

    func diagnosticArtifactHashes() throws -> [String: String] {
        var files: [String: URL] = [:]
        for (index, file) in classPath.enumerated() {
            files["classpath[\(index)]/\(file.lastPathComponent)"] = file
        }
        files["provider.jar"] = providerArtifact?.original ?? root.appendingPathComponent("inputs/provider.jar")
        files["provider-jvm.jar"] = providerArtifact?.converted ?? root.appendingPathComponent("converted/provider-jvm.jar")
        var runtimeFiles = ["inputs/host.apk", "converted/host-jvm.jar", "jdk/bin/java"]
        runtimeFiles += (manifest.modules ?? []).flatMap { ["inputs/\($0).apk", "converted/\($0)-jvm.jar"] }
        if manifest.schema < 3 || FileManager.default.fileExists(atPath: root.appendingPathComponent("evidence.json").path) {
            runtimeFiles.append("evidence.json")
        }
        for relative in runtimeFiles {
            files[relative] = root.appendingPathComponent(relative)
        }
        return try files.mapValues { try Self.digest($0) }
    }

    init(root: URL, manifest: DevelopmentAndroidRuntimeManifest, classPath: [URL],
         providerArtifact: DevelopmentAndroidProviderArtifact? = nil, componentIdentity: String? = nil) {
        self.root = root
        self.manifest = manifest
        self.classPath = classPath
        self.providerArtifact = providerArtifact
        self.componentIdentity = componentIdentity
    }

    func using(artifact: DevelopmentAndroidProviderArtifact) -> Self {
        Self(root: root, manifest: manifest, classPath: classPath, providerArtifact: artifact, componentIdentity: componentIdentity)
    }

    /// Runtime asset integrity is unchanged. Only the in-memory source list is
    /// derived from the actual configuration for the independent original path.
    func selectingOriginalBindings(sites: [Site]) -> Self {
        let bindings = sites.compactMap { site -> DevelopmentAndroidRuntimeManifest.Binding? in
            guard let name = AndroidOriginalProviderPolicy.className(for: site) else { return nil }
            return .init(key: site.key, api: site.api, className: name)
        }
        var selected = DevelopmentAndroidRuntimeManifest(schema: manifest.schema,
            providerID: manifest.providerID, backend: manifest.backend,
            providerSHA256: manifest.providerSHA256, hostSHA256: manifest.hostSHA256,
            bindings: bindings, bootstrapClass: manifest.bootstrapClass, package: manifest.package)
        selected.compatibility = manifest.compatibility
        selected.modules = manifest.modules
        return Self(root: root, manifest: selected, classPath: classPath, providerArtifact: providerArtifact, componentIdentity: componentIdentity)
    }

    /// All signed assets (including JDK libraries/Python/platform code) participate.
    /// Legacy development layouts derive an identity from their actual classpath.
    func conversionIdentity() throws -> String {
        if let componentIdentity { return componentIdentity }
        let files = Array(Set(classPath + ["lib/macapk-loader.jar", "lib/android-framework.jar", "jdk/bin/java"].map { root.appendingPathComponent($0) }))
            .sorted { $0.path < $1.path }
        return SHA256.hash(data: Data(try files.map { try Self.digest($0) }.joined(separator: ":").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    static func load(root: URL, componentIdentity: String? = nil) throws -> Self {
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        let manifestURL = try containedFile("manifest.json", root: root)
        let data = try Data(contentsOf: manifestURL)
        guard data.count <= 1024 * 1024 else { throw DevelopmentAndroidRuntimeError.invalidBundle("Manifest is too large") }
        let manifest = try JSONDecoder().decode(DevelopmentAndroidRuntimeManifest.self, from: data)
        guard ((manifest.schema == 1 && manifest.providerID == "android-runtime-experiment")
                || ((manifest.schema == 2 || manifest.schema == 3) && manifest.providerID == AndroidRuntimeComponentStore.providerID && componentIdentity != nil)),
              manifest.backend == nil || manifest.backend == "emulated" else {
            throw DevelopmentAndroidRuntimeError.invalidBundle("Expected schema 1 and the explicit emulated development runtime")
        }
        guard (manifest.schema >= 2 || !manifest.bindings.isEmpty),
              manifest.bindings.allSatisfy({ !$0.key.isEmpty && !$0.api.isEmpty && validClassName($0.className) }),
              Set(manifest.bindings.map { DevelopmentAndroidSiteIdentity(key: $0.key, api: $0.api) }).count == manifest.bindings.count,
              manifest.bootstrapClass.map({ $0.isEmpty || validClassName($0) }) ?? true,
              manifest.package.map(validClassName) ?? true else {
            throw DevelopmentAndroidRuntimeError.invalidBundle("Invalid or duplicate exact site bindings")
        }
        for (relative, expected) in [("inputs/provider.jar", manifest.providerSHA256), ("inputs/host.apk", manifest.hostSHA256)] {
            guard expected.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil,
                  try digest(containedFile(relative, root: root)) == expected.lowercased() else {
                throw DevelopmentAndroidRuntimeError.invalidBundle("SHA-256 mismatch for \(relative)")
            }
        }
        _ = try containedFile("converted/provider-jvm.jar", root: root)
        _ = try containedFile("converted/host-jvm.jar", root: root)
        guard manifest.modules?.allSatisfy({ $0 == "quickjs" }) ?? true,
              Set(manifest.modules ?? []).count == (manifest.modules ?? []).count else {
            throw DevelopmentAndroidRuntimeError.invalidBundle("Unsupported runtime modules")
        }
        for module in manifest.modules ?? [] {
            _ = try containedFile("inputs/" + module + ".apk", root: root)
            _ = try containedFile("converted/" + module + "-jvm.jar", root: root)
        }
        let java = try containedFile("jdk/bin/java", root: root)
        guard FileManager.default.isExecutableFile(atPath: java.path) else {
            throw DevelopmentAndroidRuntimeError.invalidBundle("Bundled Java is not executable")
        }
        let libraries = try ["android-adapter.jar", "java-runner.jar", "gson.jar", "android-framework.jar", "macapk-loader.jar"]
            .map { try containedFile("lib/" + $0, root: root) }
        let bcprov = try jars(in: "lib", root: root).filter { $0.lastPathComponent.hasPrefix("bcprov-") }
        let compat = try jars(in: "compat", root: root)
        let names = Set(compat.map(\.lastPathComponent))
        let required = ["unidbg-android-0.9.8.jar", "unidbg-api-0.9.8.jar", "unidbg-unicorn2-0.9.8.jar", "asm-9.7.1.jar", "jna-5.10.0.jar"]
        guard !bcprov.isEmpty, required.allSatisfy(names.contains) else {
            throw DevelopmentAndroidRuntimeError.invalidBundle("Missing emulated runtime dependencies")
        }
        return Self(root: root, manifest: manifest, classPath: libraries + bcprov + compat, componentIdentity: componentIdentity)
    }

    func command(binding: DevelopmentAndroidRuntimeManifest.Binding, stateDirectory: URL,
                 persistentDataDirectory: URL? = nil, authorizationDrive: DriveProvider? = nil) throws -> ProviderCommand {
        guard manifest.bindings.contains(binding) else { throw DevelopmentAndroidRuntimeError.siteMismatch }
        for relative in ["", "home", "tmp", "data", "native-cache", "native-cache/jna", "java-prefs"] {
            let directory = relative.isEmpty ? stateDirectory : stateDirectory.appendingPathComponent(relative, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let modulePaths: [String] = (manifest.modules ?? []).flatMap {
            ["converted/" + $0 + "-jvm.jar", "inputs/" + $0 + ".apk"]
        }
        let hostClassPath = (["converted/host-jvm.jar", "inputs/host.apk"] + modulePaths)
            .map { root.appendingPathComponent($0).path }.joined(separator: ":")
        let properties: [(String, String)] = [
            ("dexPath", (providerArtifact?.original ?? root.appendingPathComponent("inputs/provider.jar")).path),
            ("convertedPath", (providerArtifact?.converted ?? root.appendingPathComponent("converted/provider-jvm.jar")).path),
            ("classPath", hostClassPath),
            ("providerClass", binding.className),
            ("sourceIdentity", DevelopmentAndroidSiteProvider.sourceIdentity(key: binding.key, api: binding.api)),
            ("bootstrapClass", manifest.bootstrapClass ?? "com.github.catvod.spider.Init"),
            ("contextFactory", "com.netvplayer.provider.android.ExperimentContext"),
            ("loaderFactory", "com.netvplayer.provider.android.AndroidArtifactClassLoader"),
            ("dataDir", stateDirectory.appendingPathComponent("data").path),
            ("nativeCache", stateDirectory.appendingPathComponent("native-cache").path),
            ("backend", "emulated"),
            ("hostApk", root.appendingPathComponent("inputs/host.apk").path),
            ("package", manifest.package ?? "com.fongmi.android.tv")
        ]
        var arguments = properties.map { "-Dnetvplayer.android.\($0.0)=\($0.1)" }
        let presentation = desktopUIEnabled ? AndroidDialogPresentation.configuration : nil
        if desktopUIEnabled {
            arguments.append("-Dnetvplayer.android.desktopUI=true")
        }
        if let presentation {
            arguments.append("-Dnetvplayer.android.themeFile=" + presentation.theme.path)
            if let dark = presentation.darkAppearance {
                arguments.append("-Dapple.awt.application.appearance=" + (dark ? "NSAppearanceNameDarkAqua" : "NSAppearanceNameAqua"))
            }
            if let authorizationDrive, [.baidu, .ali, .quark, .uc].contains(authorizationDrive) {
                // Presentation context only. The original SDK owns authorization.
                arguments.append("-Dnetvplayer.android.authorizationDrive=" + authorizationDrive.rawValue)
            }
        }
        var environment = [
            "NETVPLAYER_PROVIDER_ID": manifest.providerID,
            "NETVPLAYER_PROVIDER_PROTOCOL": "1",
            "NETVPLAYER_PROVIDER_ROOT": root.path,
            "NETVPLAYER_PROVIDER_STATE": stateDirectory.path
        ]
        let python = root.appendingPathComponent("python", isDirectory: true)
        if FileManager.default.fileExists(atPath: python.path) {
            // The optional component executes APK resources with the original Chaquopy API.
            // It is separate from signed, source-specific Python Providers.
            for file in ["manifest.json", "home/lib/python3.10/os.py", "lib/libchaquopy_java.dylib",
                         "original/app/base/spider.pyc", "original/cacert.pem"] {
                _ = try Self.containedFile("python/" + file, root: root)
            }
            arguments += ["-Dnetvplayer.android.pythonRoot=" + python.path,
                          "-Djava.library.path=" + python.appendingPathComponent("lib").path]
            environment["PYTHONHOME"] = python.appendingPathComponent("home").path
            environment["PYTHONPATH"] = ["app", "requirements", "bootstrap"]
                .map { python.appendingPathComponent("original/" + $0).path }.joined(separator: ":")
            environment["PYTHONNOUSERSITE"] = "1"
            environment["PYTHONDONTWRITEBYTECODE"] = "1"
            environment["SSL_CERT_FILE"] = python.appendingPathComponent("original/cacert.pem").path
        }
        let scopedRuntime = persistentDataDirectory?.appendingPathComponent(".runtime", isDirectory: true) ?? stateDirectory
        if let persistentDataDirectory {
            try FileManager.default.createDirectory(at: persistentDataDirectory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: persistentDataDirectory.path)
            for path in ["", "home", "tmp", "java-prefs", "native-cache", "native-cache/jna"] {
                let folder = path.isEmpty ? scopedRuntime : scopedRuntime.appendingPathComponent(path, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            arguments.append("-Dnetvplayer.android.persistentDataDir=" + persistentDataDirectory.path)
            arguments.append("-Dnetvplayer.android.nativeCache=" + scopedRuntime.appendingPathComponent("native-cache").path)
        }
        if let captureRoot = ProcessInfo.processInfo.environment["NETVPLAYER_ANDROID_DIAGNOSTIC_CAPTURE_ROOT"],
           !captureRoot.isEmpty {
            arguments.append("-Dnetvplayer.android.httpDiagnosticsDirectory=" + captureRoot)
        }
        arguments += [
            // Keep the OS dual-stack address order used by the Android host.
            // JDK defaults otherwise move IPv4 ahead of a usable IPv6 route.
            "-Djava.net.preferIPv6Addresses=system",
            "-Duser.home=" + scopedRuntime.appendingPathComponent("home").path,
            "-Djava.io.tmpdir=" + scopedRuntime.appendingPathComponent("tmp").path,
            "-Djava.util.prefs.userRoot=" + scopedRuntime.appendingPathComponent("java-prefs").path,
            "-Djna.tmpdir=" + scopedRuntime.appendingPathComponent("native-cache/jna").path,
            "--add-opens=java.base/java.lang=ALL-UNNAMED",
            "--add-opens=java.base/java.nio=ALL-UNNAMED",
            "--add-opens=java.base/sun.net.www.protocol.jar=ALL-UNNAMED",
            "--add-exports=java.base/sun.net.www.protocol.http=ALL-UNNAMED",
            "--add-exports=java.base/sun.net.www.protocol.https=ALL-UNNAMED",
            "-cp", ((presentation.map { [$0.archive] } ?? []) + classPath).map(\.path).joined(separator: ":"),
            "com.netvplayer.provider.android.AndroidRuntimeRunner",
            "--provider", root.appendingPathComponent("lib/android-adapter.jar").path,
            "--class", "com.netvplayer.provider.android.ExperimentalAndroidProviderFactory"
        ]
        return ProviderCommand(
            executableURL: root.appendingPathComponent("jdk/bin/java"), arguments: arguments,
            currentDirectoryURL: stateDirectory, stateDirectoryURL: stateDirectory,
            environment: environment
        )
    }

    private static func validClassName(_ value: String) -> Bool {
        value.range(of: "^([A-Za-z_$][A-Za-z0-9_$]*\\.)+[A-Za-z_$][A-Za-z0-9_$]*$", options: .regularExpression) != nil
    }

    private static func containedFile(_ relative: String, root: URL) throws -> URL {
        let value = root.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
        var directory: ObjCBool = false
        guard value.path.hasPrefix(root.path + "/"),
              FileManager.default.fileExists(atPath: value.path, isDirectory: &directory), !directory.boolValue else {
            throw DevelopmentAndroidRuntimeError.invalidBundle("Missing or external runtime file: \(relative)")
        }
        return value
    }

    private static func jars(in relative: String, root: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(relative), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jar" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { try containedFile(relative + "/" + $0.lastPathComponent, root: root) }
    }

    private static func digest(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty { hash.update(data: bytes) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private struct DevelopmentAndroidSiteIdentity: Hashable, Sendable {
    let key: String
    let api: String
}

actor DevelopmentAndroidRuntimeRegistration {
    static let shared = DevelopmentAndroidRuntimeRegistration()
    private var providers: [DevelopmentAndroidSiteIdentity: DevelopmentAndroidSiteProvider] = [:]
    private var proxySites: [DevelopmentAndroidSiteIdentity: (Site, DevelopmentAndroidSiteProvider)] = [:]
    private let auditSessionID: String?
    private let stateRoot: URL?
    private let registry: SpiderReplacementRegistry
    private let forceAndroidForAudit: Bool
    private let forceBundledArtifactForAudit: Bool
    private let artifactStore: DevelopmentAndroidArtifactStore
    private var providerArtifacts: [DevelopmentAndroidSiteIdentity: String] = [:]
    private var providerStateIdentities: [DevelopmentAndroidSiteIdentity: String] = [:]
    private var registrationRevision = UUID()

    init(stateRoot: URL? = nil, registry: SpiderReplacementRegistry = .shared,
         bundledArtifactForTesting: Bool = false,
         arguments: [String] = CommandLine.arguments, artifactStore: DevelopmentAndroidArtifactStore = .shared) {
        self.stateRoot = stateRoot
        self.registry = registry
        self.artifactStore = artifactStore
        auditSessionID = arguments.contains("--android-provider-audit") ? UUID().uuidString : nil
        #if DEBUG
        // Controlled bridge fixtures exercise lifecycle/state without fetching
        // a source JAR. Release builds never accept this injection.
        forceBundledArtifactForAudit = bundledArtifactForTesting || (arguments.contains("--android-provider-audit")
            && arguments.contains("--android-provider-use-bundled-artifact"))
        forceAndroidForAudit = arguments.contains("--android-provider-audit")
            && arguments.contains("--android-provider-force-android")
        #else
        forceBundledArtifactForAudit = false
        forceAndroidForAudit = false
        #endif
    }

    func isRegistered(site: Site) -> Bool {
        proxySites[DevelopmentAndroidSiteIdentity(key: site.key, api: site.api)] != nil
    }

    func effectiveProviderSHA256(site: Site) -> String? {
        let identity = DevelopmentAndroidSiteIdentity(key: site.key, api: site.api)
        guard proxySites[identity] != nil else { return nil }
        return providerArtifacts[identity]
    }

    private func requireCurrent(_ revision: UUID) throws {
        try Task.checkCancellation()
        guard revision == registrationRevision else { throw CancellationError() }
    }

    func register(
        runtime: DevelopmentAndroidRuntimeLayout, sites: [Site],
        preference: ProviderExecutionPreference = .androidPreferred,
        baiduCookieProvider: (@Sendable () async -> String?)? = nil,
        cloudCredentialProvider: (@Sendable (DriveProvider) async -> String?)? = nil
    ) async throws {
        guard preference.usesAndroid else { return }
        let revision = UUID()
        registrationRevision = revision
        let runtime = (preference == .androidPreferred || runtime.manifest.schema >= 2) ? runtime.selectingOriginalBindings(sites: sites) : runtime
        guard let support = stateRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw DevelopmentAndroidRuntimeError.invalidBundle("Application Support is unavailable")
        }
        proxySites.removeAll()
        let active = Set(sites.compactMap { site -> DevelopmentAndroidSiteIdentity? in
            guard runtime.manifest.bindings.contains(where: { $0.key == site.key && $0.api == site.api }) else { return nil }
            return .init(key: site.key, api: site.api)
        })
        for identity in Array(providers.keys) where !active.contains(identity) {
            let removed = providers.removeValue(forKey: identity)
            providerArtifacts.removeValue(forKey: identity)
            providerStateIdentities.removeValue(forKey: identity)
            await removed?.retire()
            try requireCurrent(revision)
            if let removed {
                await registry.removeDevelopmentAndroidProvider(key: identity.key, api: identity.api, matching: removed)
                try requireCurrent(revision)
            }
        }
        var resolvedArtifacts: [String: DevelopmentAndroidRuntimeLayout] = [:]
        var failedArtifacts: Set<String> = []
        sourceLoop: for site in sites {
            try requireCurrent(revision)
            if preference == .androidPreferred, AndroidOriginalProviderPolicy.applies(to: site) {
                let reason: AndroidOriginalUnavailableReason?
                if AndroidOriginalProviderPolicy.className(for: site) == nil { reason = .unsupportedSourceAPI }
                else if site.jar.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !forceBundledArtifactForAudit { reason = .missingProviderArtifact }
                else { reason = nil }
                if let reason {
                    let identity = DevelopmentAndroidSiteIdentity(key: site.key, api: site.api)
                    if let previous = providers.removeValue(forKey: identity) { await previous.retire() }
                    try requireCurrent(revision)
                    providerArtifacts.removeValue(forKey: identity)
                    await registry.register(originalKey: site.key, originalAPI: site.api,
                        provider: AndroidOriginalUnavailableProvider(reason: reason))
                    try requireCurrent(revision)
                    continue
                }
            }
            guard let binding = runtime.manifest.bindings.first(where: { $0.key == site.key && $0.api == site.api }) else { continue }
            try requireCurrent(revision)
            if failedArtifacts.contains(site.jar) { continue }
            if runtime.manifest.schema == 3 && site.jar.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await registry.register(originalKey: site.key, originalAPI: site.api,
                    provider: AndroidOriginalUnavailableProvider(reason: .missingProviderArtifact))
                try requireCurrent(revision)
                continue
            }
            let effectiveRuntime: DevelopmentAndroidRuntimeLayout
            if forceBundledArtifactForAudit || site.jar.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                effectiveRuntime = runtime
            } else if let resolved = resolvedArtifacts[site.jar] {
                effectiveRuntime = resolved
            } else {
                let artifact: DevelopmentAndroidProviderArtifact
                do {
                    // Every Android route uses the original loader. Framework and dynamic classes
                    // need not be present in the source JAR's static class list.
                    // The artifact store still verifies checksums and ZIP structure.
                    artifact = try await artifactStore.resolve(declaration: site.jar, runtime: runtime,
                        bindings: [])
                    try requireCurrent(revision)
                } catch {
                    try requireCurrent(revision)

                    let failure = DevelopmentAndroidArtifactFailureProvider(error: error as? DevelopmentAndroidArtifactError ?? .downloadFailed)
                    for affected in sites where affected.jar == site.jar {
                        try requireCurrent(revision)
                        guard runtime.manifest.bindings.contains(where: { $0.key == affected.key && $0.api == affected.api }) else { continue }
                        let affectedIdentity = DevelopmentAndroidSiteIdentity(key: affected.key, api: affected.api)
                        if let previous = providers.removeValue(forKey: affectedIdentity) { await previous.retire() }
                        try requireCurrent(revision)
                        providerArtifacts.removeValue(forKey: affectedIdentity)
                        await registry.register(originalKey: affected.key, originalAPI: affected.api, provider: failure)
                        try requireCurrent(revision)
                    }
                    // Keep failures local to this artifact in every preference.
                    // Later entries can still register their native/installed
                    // implementation or resolve an independent healthy artifact.
                    failedArtifacts.insert(site.jar)
                    continue sourceLoop
                }
                effectiveRuntime = runtime.using(artifact: artifact)
                resolvedArtifacts[site.jar] = effectiveRuntime
                DiagnosticLog.write("[ANDROID_PROVIDER_ARTIFACT] backend=emulated providerSHA256=\(artifact.sha256) bundledMatch=\(artifact.sha256 == runtime.manifest.providerSHA256)")
            }
            let identity = DevelopmentAndroidSiteIdentity(key: site.key, api: site.api)
            let stateIdentity = try effectiveRuntime.stateIdentity(binding: binding)
            let provider: DevelopmentAndroidSiteProvider
            if let existing = providers[identity], providerStateIdentities[identity] == stateIdentity { provider = existing }
            else {
                let previous = providers.removeValue(forKey: identity)
                providerStateIdentities.removeValue(forKey: identity)
                providerArtifacts.removeValue(forKey: identity)
                if let previous { await previous.retire() }
                try requireCurrent(revision)
                // Normal windows retain Android state; an explicit audit always
                // starts in a fresh namespace, including its account-free mode.
                let scope = auditSessionID.map { "audit/" + $0 } ?? "persistent-v2"
                let state = support.appendingPathComponent("NetVplayer/DevelopmentAndroidRuntime/\(scope)/\(stateIdentity)", isDirectory: true)
                let sessionScope = auditSessionID.map { "audit/" + $0 + "/source-sessions-v1" } ?? "source-sessions-v1"
                let sessionRoot = support.appendingPathComponent("NetVplayer/DevelopmentAndroidRuntime/" + sessionScope, isDirectory: true)
                provider = DevelopmentAndroidSiteProvider(runtime: effectiveRuntime, binding: binding, stateDirectory: state,
                    sessionStateRoot: sessionRoot)
                providers[identity] = provider
                providerArtifacts[identity] = effectiveRuntime.providerSHA256
                providerStateIdentities[identity] = stateIdentity
            }
            try requireCurrent(revision)
            await registry.register(originalKey: site.key, originalAPI: site.api, provider: provider)
            try requireCurrent(revision)
            proxySites[identity] = (site, provider)
        }
        DiagnosticLog.write("[ANDROID_PROVIDER_DEVELOPMENT] backend=emulated registeredSites=\(proxySites.count) forcedAndroidAudit=\(forceAndroidForAudit)")
    }

    func proxyResponse(parameters: [String: String]) async throws -> ProxyResponse? {
        // Only opaque routes to the original Provider proxy are accepted here.
        guard parameters[DevelopmentAndroidCatVodProxyAdapter.markerKey] == "1" else { return nil }
        guard let key = parameters["siteKey"], let api = parameters["siteAPI"],
              let (site, provider) = proxySites[DevelopmentAndroidSiteIdentity(key: key, api: api)],
              DevelopmentAndroidCatVodProxyAdapter.matchesRoute(parameters, site: site, providerID: provider.providerID) else {
            throw DevelopmentAndroidCatVodProxyAdapter.invalidDescriptor()
        }
        return try await provider.proxyRoute(site: site, parameters: parameters)
    }

    func streamProxy(parameters: [String: String],
        sendHead: @escaping @Sendable (ProxyStreamingResponseHead) async throws -> Void,
        sendBody: @escaping @Sendable (Data) async throws -> Void) async throws -> Bool {
        guard parameters[DevelopmentAndroidCatVodProxyAdapter.markerKey] == "1" else { return false }
        guard let key = parameters["siteKey"], let api = parameters["siteAPI"],
              let (site, provider) = proxySites[DevelopmentAndroidSiteIdentity(key: key, api: api)],
              DevelopmentAndroidCatVodProxyAdapter.matchesRoute(parameters, site: site, providerID: provider.providerID) else {
            throw DevelopmentAndroidCatVodProxyAdapter.invalidDescriptor()
        }
        try await provider.streamProxyRoute(site: site, parameters: parameters, sendHead: sendHead, sendBody: sendBody)
        return true
    }

    func cancelPlayback(site: Site) async {
        await providers[DevelopmentAndroidSiteIdentity(key: site.key, api: site.api)]?.cancelPlayback()
    }

    func shutdownAll() async {
        let active = Array(providers.values)
        for provider in active { await provider.shutdown() }
    }
}
