import Darwin
import DriveEngine
import Foundation
import Models
import ProxyServer

struct ThunderDownloadConfiguration: Sendable {
    let appID: String
    let loginToken: String
    let libraryURL: URL
    let configDirectory: URL
    let cacheDirectory: URL

    private struct CredentialFile: Decodable {
        let appID: String
        let loginToken: String
        let issuedAt: Double?
        let expiresIn: Double?

        enum CodingKeys: String, CodingKey {
            case appID = "app_id"
            case loginToken = "login_token"
            case issuedAt = "issued_at", expiresIn = "expires_in"
        }
    }

    static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> ThunderDownloadConfiguration? {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?.appendingPathComponent("NetVplayer/ThunderDownload", isDirectory: true)
        let bundledLibraryURLs = [
            bundle.privateFrameworksURL?.appendingPathComponent("libdk.dylib"),
            bundle.resourceURL?.appendingPathComponent("ThunderDownloadSDK/libdk.dylib"),
        ].compactMap { $0 }
        let libraryURL = environment["NETVPLAYER_XUNLEI_SDK_LIBRARY"].map {
            URL(fileURLWithPath: $0)
        } ?? bundledLibraryURLs.first(where: { fileManager.fileExists(atPath: $0.path) })
        guard let applicationSupport,
              let libraryURL,
              fileManager.fileExists(atPath: libraryURL.path) else {
            return nil
        }

        let environmentAppID = environment["NETVPLAYER_XUNLEI_APP_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let environmentToken = environment["NETVPLAYER_XUNLEI_LOGIN_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let credentials: CredentialFile?
        if let environmentAppID, !environmentAppID.isEmpty,
           let environmentToken, !environmentToken.isEmpty {
            credentials = CredentialFile(appID: environmentAppID, loginToken: environmentToken, issuedAt: nil, expiresIn: nil)
        } else {
            let credentialsURL = applicationSupport.appendingPathComponent("credentials.json")
            let saved = (try? Data(contentsOf: credentialsURL))
                .flatMap { try? JSONDecoder().decode(CredentialFile.self, from: $0) }
            credentials = saved.flatMap { credentialsAreFresh(issuedAt: $0.issuedAt, expiresIn: $0.expiresIn) ? $0 : nil }
        }
        guard let credentials,
              !credentials.appID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !credentials.loginToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return ThunderDownloadConfiguration(
            appID: credentials.appID,
            loginToken: credentials.loginToken,
            libraryURL: libraryURL,
            configDirectory: applicationSupport.appendingPathComponent("sdk-state", isDirectory: true),
            cacheDirectory: fileManager.temporaryDirectory
                .appendingPathComponent("NetVplayer-ThunderNextEpisode", isDirectory: true)
        )
    }

    static func credentialsAreFresh(issuedAt: Double?, expiresIn: Double?, now: Double = Date().timeIntervalSince1970) -> Bool {
        guard let issuedAt, let expiresIn, issuedAt.isFinite, expiresIn.isFinite, now.isFinite,
              expiresIn > 60, issuedAt <= now + 60 else { return false }
        return now < issuedAt + expiresIn - 60
    }
}

struct ThunderDownloadRequest: Sendable {
    let url: String
    let headers: [String: String]
    let destinationURL: URL
    let expectedSize: Int64?

    func removePartialFiles() {
        // SDK 1.0.3 leaves these sidecars after delete_task(delete_file: 1)
        // returns success. Only remove the exact files owned by this request.
        for suffix in ["", ".xltd", ".xltd.cfg"] {
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: destinationURL.path + suffix)
            )
        }
    }
}

struct ThunderDownloadResult: Sendable {
    let fileURL: URL
    let downloadedBytes: Int64
}

protocol ThunderDownloadRuntime: Sendable {
    func download(
        _ request: ThunderDownloadRequest,
        configuration: ThunderDownloadConfiguration
    ) async throws -> ThunderDownloadResult
}

enum ThunderDownloadError: LocalizedError {
    case unavailable
    case sdk(Int32)
    case task(UInt32)
    case invalidFile
    case noAcceleration

    var errorDescription: String? {
        switch self {
        case .unavailable: return "迅雷下载运行时不可用"
        case let .sdk(code): return "迅雷下载 SDK 错误（\(code)）"
        case let .task(code): return "迅雷下载任务失败（\(code)）"
        case .invalidFile: return "迅雷下载文件校验失败"
        case .noAcceleration: return "未发现迅雷加速流量，继续使用原播放线路"
        }
    }
}

private final class ThunderAccelerationAvailability: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = true

    var isAvailable: Bool { lock.withLock { enabled } }
    func disable() { lock.withLock { enabled = false } }
}

public actor ThunderNextEpisodeCache {
    private static let configuredAtLaunch = ThunderDownloadConfiguration.load() != nil
        || (ThunderCredentialVault.hasRefreshAuthorization && bundledLibraryAvailable)
    private static var bundledLibraryAvailable: Bool {
        [ProcessInfo.processInfo.environment["NETVPLAYER_XUNLEI_SDK_LIBRARY"],
         Bundle.main.privateFrameworksURL?.appendingPathComponent("libdk.dylib").path,
         Bundle.main.resourceURL?.appendingPathComponent("ThunderDownloadSDK/libdk.dylib").path]
            .compactMap { $0 }.contains { FileManager.default.fileExists(atPath: $0) }
    }

    private struct DownloadSource {
        let spec: PlaySpec
        let expectedSize: Int64?
    }

    public static let shared = ThunderNextEpisodeCache(refreshesCredentials: true)
    static let maximumCacheBytes: Int64 = 2 * 1024 * 1024 * 1024
    static let cachePathMetadataKey = "thunder.cache.path"
    static let originalURLMetadataKey = "thunder.originalURL"

    private nonisolated let accelerationAvailability = ThunderAccelerationAvailability()
    private var runtime: (any ThunderDownloadRuntime)?
    private let runtimeFactory: @Sendable (URL) throws -> any ThunderDownloadRuntime
    private let configurationProvider: @Sendable () -> ThunderDownloadConfiguration?
    private let refreshesCredentials: Bool
    private var isPreparing = false

    init(
        runtime: (any ThunderDownloadRuntime)? = nil,
        runtimeFactory: @escaping @Sendable (URL) throws -> any ThunderDownloadRuntime = {
            try NativeThunderDownloadRuntime(libraryURL: $0)
        },
        refreshesCredentials: Bool = false,
        configurationProvider: @escaping @Sendable () -> ThunderDownloadConfiguration? = {
            ThunderDownloadConfiguration.load()
        }
    ) {
        self.runtime = runtime
        self.runtimeFactory = runtimeFactory
        self.configurationProvider = configurationProvider
        self.refreshesCredentials = refreshesCredentials
    }

    nonisolated var canAttemptAcceleration: Bool { accelerationAvailability.isAvailable }

    public nonisolated static var isConfigured: Bool {
        configuredAtLaunch
    }

    public nonisolated static func supports(_ spec: PlaySpec) -> Bool {
        downloadSource(for: spec) != nil
    }

    public nonisolated static func shouldStartPreload(
        for spec: PlaySpec,
        positionSeconds: Double,
        bufferedUntilSeconds: Double,
        isLoading: Bool,
        isSeeking: Bool
    ) -> Bool {
        shouldStartPreload(
            for: spec,
            positionSeconds: positionSeconds,
            bufferedUntilSeconds: bufferedUntilSeconds,
            isLoading: isLoading,
            isSeeking: isSeeking,
            configurationAvailable: isConfigured && shared.canAttemptAcceleration
        )
    }

    nonisolated static func shouldStartPreload(
        for spec: PlaySpec,
        positionSeconds: Double,
        bufferedUntilSeconds: Double,
        isLoading: Bool,
        isSeeking: Bool,
        configurationAvailable: Bool
    ) -> Bool {
        configurationAvailable
            && supports(spec)
            && positionSeconds > 0
            && bufferedUntilSeconds - positionSeconds >= 15
            && !isLoading
            && !isSeeking
    }

    public func prepare(
        _ spec: PlaySpec,
        while isStillNeeded: @escaping @Sendable () async -> Bool = { true }
    ) async -> PlaySpec? {
        guard !isPreparing, canAttemptAcceleration,
              let source = Self.downloadSource(for: spec) else {
            return nil
        }
        isPreparing = true
        defer { isPreparing = false }
        var resolvedConfiguration = configurationProvider()
        if resolvedConfiguration == nil, refreshesCredentials { resolvedConfiguration = await ThunderCredentialVault.shared.configuration() }
        guard let configuration = resolvedConfiguration, !Task.isCancelled else { return nil }
        let upstream = ProxyServer.shared.remoteStreamPlaybackInfo(forLocalURL: source.spec.url)
        let sourceURL = upstream?.url ?? source.spec.url
        let headers = upstream?.headers ?? source.spec.headers
        guard let remoteURL = URL(string: sourceURL),
              remoteURL.scheme?.lowercased() == "https" else {
            return nil
        }

        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: configuration.cacheDirectory,
                withIntermediateDirectories: true
            )
            let existingBytes = (try fileManager.contentsOfDirectory(at: configuration.cacheDirectory, includingPropertiesForKeys: [.fileSizeKey]))
                .reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            let free = (try fileManager.attributesOfFileSystem(forPath: configuration.cacheDirectory.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
            guard let expected = source.expectedSize, expected > 0,
                  existingBytes <= Self.maximumCacheBytes - expected, free >= expected + 1024 * 1024 * 1024 else { return nil }
            try await PlaybackBackgroundBudget.shared.waitForBackgroundPermission()
            try fileManager.createDirectory(
                at: configuration.configDirectory,
                withIntermediateDirectories: true
            )
            let declaredName = source.spec.metadata[DrivePlaybackMetadataKey.fileName]
                ?? remoteURL.lastPathComponent
            let pathExtension = URL(fileURLWithPath: declaredName).pathExtension
            let destination = configuration.cacheDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(pathExtension.isEmpty ? "mp4" : pathExtension)
            let request = ThunderDownloadRequest(
                url: sourceURL,
                headers: headers,
                destinationURL: destination,
                expectedSize: source.expectedSize
            )
            let activeRuntime: any ThunderDownloadRuntime
            if let retainedRuntime = runtime {
                activeRuntime = retainedRuntime
            } else {
                let createdRuntime = try runtimeFactory(configuration.libraryURL)
                runtime = createdRuntime
                activeRuntime = createdRuntime
            }
            DiagnosticLog.write("[THUNDER_PRELOAD] stage=begin expectedBytes=\(source.expectedSize ?? 0)")
            let result = try await withThrowingTaskGroup(
                of: ThunderDownloadResult.self
            ) { group in
                group.addTask {
                    try await activeRuntime.download(request, configuration: configuration)
                }
                group.addTask {
                    while await isStillNeeded() {
                        try await Task.sleep(for: .seconds(1))
                    }
                    throw CancellationError()
                }
                guard let first = try await group.next() else {
                    throw ThunderDownloadError.unavailable
                }
                group.cancelAll()
                return first
            }
            var localSpec = source.spec
            localSpec.url = result.fileURL.absoluteString
            localSpec.headers = [:]
            localSpec.fallbackHeaders = [:]
            localSpec.contentLength = result.downloadedBytes
            var profile = PlaybackTransferPolicy.profile(for: source.spec)
            profile.context.connection = .local
            localSpec.transferProfile = profile
            localSpec.mpvOptions.removeValue(forKey: "http-proxy")
            localSpec.mpvOptions.removeValue(forKey: "stream-lavf-o")
            localSpec.metadata[Self.cachePathMetadataKey] = result.fileURL.path
            localSpec.metadata[Self.originalURLMetadataKey] = sourceURL
            DiagnosticLog.write("[THUNDER_PRELOAD] stage=ready bytes=\(result.downloadedBytes)")
            return localSpec
        } catch ThunderDownloadError.noAcceleration {
            accelerationAvailability.disable()
            DiagnosticLog.write("[THUNDER_PRELOAD] stage=unaccelerated fallback=true sessionDisabled=true")
            return nil
        } catch is CancellationError {
            DiagnosticLog.write("[THUNDER_PRELOAD] stage=cancelled")
            return nil
        } catch {
            DiagnosticLog.write("[THUNDER_PRELOAD] stage=failed errorKind=\((error as NSError).code)")
            return nil
        }
    }

    private nonisolated static func downloadSource(for spec: PlaySpec) -> DownloadSource? {
        guard PlaybackTransferPolicy.media(for: spec) == .video else { return nil }
        let metadataProvider = spec.metadata[DrivePlaybackMetadataKey.provider]
        guard spec.drivePlaybackPlan?.provider == .uc
                || metadataProvider == DriveProvider.uc.rawValue else {
            return nil
        }
        if let plan = spec.drivePlaybackPlan,
           let candidate = DrivePlaybackRoutePolicy.candidate(for: spec),
           candidate.kind == .original, candidate.providerRoute == DrivePlaybackRoute.ucOriginalProxy,
           plan.candidates.contains(where: { $0.id == candidate.id }) {
            guard let size = candidate.expectedSize > 0 ? candidate.expectedSize : declaredSize(of: spec),
                  size > 0, size <= maximumCacheBytes else { return nil }
            let routed = DrivePlaybackRoutePolicy.spec(
                for: candidate,
                basedOn: spec,
                manualSelection: false
            )
            return DownloadSource(
                spec: routed,
                expectedSize: size
            )
        }
        if spec.drivePlaybackPlan != nil { return nil }
        guard spec.metadata[DrivePlaybackMetadataKey.route] == DrivePlaybackRoute.ucOriginalProxy,
              let size = declaredSize(of: spec), size > 0, size <= maximumCacheBytes else {
            return nil
        }
        return DownloadSource(spec: spec, expectedSize: size)
    }

    private nonisolated static func declaredSize(of spec: PlaySpec) -> Int64? {
        spec.contentLength ?? spec.metadata[DrivePlaybackMetadataKey.size].flatMap(Int64.init)
    }

    public nonisolated static func releaseCachedFile(
        spec: PlaySpec?,
        replacingWith replacement: PlaySpec? = nil,
        cacheDirectory: URL? = nil
    ) {
        guard let rawPath = spec?.metadata[cachePathMetadataKey],
              replacement?.metadata[cachePathMetadataKey] != rawPath else {
            return
        }
        let root = (cacheDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("NetVplayer-ThunderNextEpisode", isDirectory: true))
            .standardizedFileURL.path + "/"
        let fileURL = URL(fileURLWithPath: rawPath).standardizedFileURL
        guard fileURL.path.hasPrefix(root) else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}

private actor NativeThunderDownloadRuntime: ThunderDownloadRuntime {
    private typealias InitFunction = @convention(c) (UnsafeRawPointer?) -> Int32
    private typealias LoginFunction = @convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<CChar>?) -> Int32
    private typealias CreateFunction = @convention(c) (UnsafeRawPointer?, UnsafeMutablePointer<UInt64>?) -> Int32
    private typealias TaskFunction = @convention(c) (UInt64) -> Int32
    private typealias DeleteFunction = @convention(c) (UInt64, UInt8) -> Int32
    private typealias StateFunction = @convention(c) (UInt64, UnsafeMutableRawPointer?) -> Int32
    private typealias InfoFunction = @convention(c) (
        UInt64,
        UnsafePointer<CChar>?,
        UnsafeMutableRawPointer?,
        UnsafeMutablePointer<UInt32>?
    ) -> Int32
    private typealias HeaderFunction = @convention(c) (UInt64, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32
    private typealias ToggleFunction = @convention(c) (UInt32) -> Int32
    private typealias DynamicAccelerationFunction = @convention(c) (Bool) -> Int32

    // The SDK starts worker threads that outlive a cancelled task. Keep its
    // dlopen reference for the process lifetime so those threads retain code.
    private let handleAddress: UInt
    private let initializeFunction: InitFunction
    private let loginFunction: LoginFunction
    private let createFunction: CreateFunction
    private let startFunction: TaskFunction
    private let stopFunction: TaskFunction
    private let deleteFunction: DeleteFunction
    private let stateFunction: StateFunction
    private let infoFunction: InfoFunction
    private let headerFunction: HeaderFunction
    private let uploadFunction: ToggleFunction
    private let dynamicAccelerationFunction: DynamicAccelerationFunction
    private var initialized = false
    private var loggedInToken = ""

    init(libraryURL: URL) throws {
        guard let handle = dlopen(libraryURL.path, RTLD_NOW | RTLD_LOCAL) else {
            throw ThunderDownloadError.unavailable
        }
        handleAddress = UInt(bitPattern: handle)
        do {
            initializeFunction = try Self.symbol(handle, "xl_dl_init", as: InitFunction.self)
            loginFunction = try Self.symbol(handle, "xl_dl_login", as: LoginFunction.self)
            createFunction = try Self.symbol(handle, "xl_dl_create_p2sp_task", as: CreateFunction.self)
            startFunction = try Self.symbol(handle, "xl_dl_start_task", as: TaskFunction.self)
            stopFunction = try Self.symbol(handle, "xl_dl_stop_task", as: TaskFunction.self)
            deleteFunction = try Self.symbol(handle, "xl_dl_delete_task", as: DeleteFunction.self)
            stateFunction = try Self.symbol(handle, "xl_dl_get_task_state", as: StateFunction.self)
            infoFunction = try Self.symbol(handle, "xl_dl_get_task_info", as: InfoFunction.self)
            headerFunction = try Self.symbol(handle, "xl_dl_set_http_header", as: HeaderFunction.self)
            uploadFunction = try Self.symbol(handle, "xl_dl_set_upload_switch", as: ToggleFunction.self)
            dynamicAccelerationFunction = try Self.symbol(
                handle,
                "xl_dl_set_dynamic_link_acceleration",
                as: DynamicAccelerationFunction.self
            )
        } catch {
            dlclose(handle)
            throw error
        }
    }

    func download(
        _ request: ThunderDownloadRequest,
        configuration: ThunderDownloadConfiguration
    ) async throws -> ThunderDownloadResult {
        try initializeIfNeeded(configuration)
        let destination = request.destinationURL
        let savePath = destination.deletingLastPathComponent().path
        let saveName = destination.lastPathComponent
        var taskID: UInt64 = 0
        // Resolve the actor-owned entry point before borrowing nested C strings.
        let createTask = createFunction
        let createCode = savePath.withCString { savePathPointer in
            saveName.withCString { saveNamePointer in
                request.url.withCString { urlPointer in
                    let storage = UnsafeMutableRawPointer.allocate(byteCount: 24, alignment: 8)
                    defer { storage.deallocate() }
                    storage.storeBytes(of: savePathPointer, toByteOffset: 0, as: UnsafePointer<CChar>.self)
                    storage.storeBytes(of: saveNamePointer, toByteOffset: 8, as: UnsafePointer<CChar>.self)
                    storage.storeBytes(of: urlPointer, toByteOffset: 16, as: UnsafePointer<CChar>.self)
                    return createTask(storage, &taskID)
                }
            }
        }
        guard createCode == 0 else { throw ThunderDownloadError.sdk(createCode) }

        do {
            for (name, value) in request.headers where Self.allowedHeaderNames.contains(name.lowercased()) {
                let code = name.withCString { namePointer in
                    value.withCString { valuePointer in
                        headerFunction(taskID, namePointer, valuePointer)
                    }
                }
                guard code == 0 else { throw ThunderDownloadError.sdk(code) }
            }
            let startCode = startFunction(taskID)
            guard startCode == 0 else { throw ThunderDownloadError.sdk(startCode) }
            var activeProbeSeconds: TimeInterval = 0
            var lastProbeAt = ProcessInfo.processInfo.systemUptime
            var lastLoggedSecond = -1
            while true {
                try Task.checkCancellation()
                if !PlaybackBackgroundBudget.shared.permitsBackgroundWork {
                    let code = stopFunction(taskID)
                    guard code == 0 else { throw ThunderDownloadError.sdk(code) }
                    DiagnosticLog.write("[THUNDER_PRELOAD] stage=paused-for-playback")
                    try await PlaybackBackgroundBudget.shared.waitForBackgroundPermission()
                    let restart = startFunction(taskID)
                    guard restart == 0 else { throw ThunderDownloadError.sdk(restart) }
                    lastProbeAt = ProcessInfo.processInfo.systemUptime
                    DiagnosticLog.write("[THUNDER_PRELOAD] stage=resumed")
                }
                let probeAt = ProcessInfo.processInfo.systemUptime
                activeProbeSeconds += max(0, probeAt - lastProbeAt)
                lastProbeAt = probeAt
                let storage = UnsafeMutableRawPointer.allocate(byteCount: 40, alignment: 8)
                storage.initializeMemory(as: UInt8.self, repeating: 0, count: 40)
                defer { storage.deallocate() }
                let stateCode = stateFunction(taskID, storage)
                guard stateCode == 0 else { throw ThunderDownloadError.sdk(stateCode) }
                let speed = storage.load(fromByteOffset: 0, as: UInt64.self)
                let total = storage.load(fromByteOffset: 8, as: UInt64.self)
                let downloaded = storage.load(fromByteOffset: 16, as: UInt64.self)
                let status = storage.load(fromByteOffset: 24, as: UInt8.self)
                let taskError = storage.load(fromByteOffset: 28, as: UInt32.self)
                let elapsedSecond = Int(Date().timeIntervalSince1970)
                if elapsedSecond != lastLoggedSecond, elapsedSecond.isMultiple(of: 5) {
                    lastLoggedSecond = elapsedSecond
                    let traffic = taskTraffic(taskID)
                    DiagnosticLog.write(
                        "[THUNDER_PRELOAD] stage=progress speedMiBps=\(String(format: "%.2f", Double(speed) / 1_048_576)) downloaded=\(downloaded) total=\(total) trafficValid=\(traffic != nil) originBytes=\(traffic?.origin ?? 0) p2pBytes=\(traffic?.p2p ?? 0) p2sBytes=\(traffic?.p2s ?? 0) dcdnBytes=\(traffic?.dcdn ?? 0)"
                    )
                    // The public SDK can spend the whole episode doing slower
                    // origin-only downloads. Stop speculation without waiting
                    // for the entire file when valid counters show no gain.
                    if status != 8, activeProbeSeconds >= 45,
                       let traffic, traffic.p2p == 0, traffic.p2s == 0, traffic.dcdn == 0 {
                        throw ThunderDownloadError.noAcceleration
                    }
                }
                if status == 8 {
                    _ = deleteFunction(taskID, 0)
                    let actual = Self.fileSize(at: destination)
                    guard actual > 0,
                          request.expectedSize.map({ actual == $0 }) != false else {
                        throw ThunderDownloadError.invalidFile
                    }
                    return ThunderDownloadResult(fileURL: destination, downloadedBytes: actual)
                }
                if status == 9 { throw ThunderDownloadError.task(taskError) }
                try await Task.sleep(for: .milliseconds(500))
            }
        } catch {
            _ = stopFunction(taskID)
            _ = deleteFunction(taskID, 1)
            request.removePartialFiles()
            throw error
        }
    }

    private func initializeIfNeeded(_ configuration: ThunderDownloadConfiguration) throws {
        if !initialized {
            let initializeSDK = initializeFunction
            let code = configuration.appID.withCString { appIDPointer in
                "1.0".withCString { versionPointer in
                    configuration.configDirectory.path.withCString { configPointer in
                        let storage = UnsafeMutableRawPointer.allocate(byteCount: 32, alignment: 8)
                        defer { storage.deallocate() }
                        storage.initializeMemory(as: UInt8.self, repeating: 0, count: 32)
                        storage.storeBytes(of: appIDPointer, toByteOffset: 0, as: UnsafePointer<CChar>.self)
                        storage.storeBytes(of: versionPointer, toByteOffset: 8, as: UnsafePointer<CChar>.self)
                        storage.storeBytes(of: configPointer, toByteOffset: 16, as: UnsafePointer<CChar>.self)
                        storage.storeBytes(of: UInt8(0), toByteOffset: 24, as: UInt8.self)
                        return initializeSDK(storage)
                    }
                }
            }
            guard code == 0 || code == 9_101 else { throw ThunderDownloadError.sdk(code) }
            initialized = true
            _ = uploadFunction(0)
            _ = dynamicAccelerationFunction(true)
        }
        guard loggedInToken != configuration.loginToken else { return }
        var session = [CChar](repeating: 0, count: 4_096)
        let loginCode = configuration.loginToken.withCString { tokenPointer in
            loginFunction(tokenPointer, &session)
        }
        guard loginCode == 0 else { throw ThunderDownloadError.sdk(loginCode) }
        loggedInToken = configuration.loginToken
    }

    private func taskTraffic(_ taskID: UInt64) -> (
        origin: UInt64,
        p2p: UInt64,
        p2s: UInt64,
        dcdn: UInt64
    )? {
        "traffic".withCString { name in
            let storage = UnsafeMutableRawPointer.allocate(byteCount: 32, alignment: 8)
            defer { storage.deallocate() }
            storage.initializeMemory(as: UInt8.self, repeating: 0, count: 32)
            var length: UInt32 = 32
            let code = infoFunction(taskID, name, storage, &length)
            guard code == 0, length >= 32 else { return nil }
            return (
                storage.load(fromByteOffset: 0, as: UInt64.self),
                storage.load(fromByteOffset: 8, as: UInt64.self),
                storage.load(fromByteOffset: 16, as: UInt64.self),
                storage.load(fromByteOffset: 24, as: UInt64.self)
            )
        }
    }

    private static let allowedHeaderNames = Set(["cookie", "origin", "referer", "user-agent"])

    private static func fileSize(at url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func symbol<T>(
        _ handle: UnsafeMutableRawPointer,
        _ name: String,
        as type: T.Type
    ) throws -> T {
        guard let pointer = dlsym(handle, name) else { throw ThunderDownloadError.unavailable }
        return unsafeBitCast(pointer, to: type)
    }
}
