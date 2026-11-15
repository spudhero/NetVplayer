// NetVplayerApp/Views/WebImage.swift
// 支持自定义 Headers 和自动防盗链校验的网络图片加载器

import SwiftUI
import Cocoa
import CryptoKit
import ImageIO
import Models
import Networking
import Storage
import ProxyServer
import MediaServerEngine

/// 自定义网络图片视图
public struct WebImage: View {
    let urlString: String
    let siteHeader: [String: String]?
    let showsLoadingIndicator: Bool
    let timeout: TimeInterval
    let fallbackText: String?
    let fallbackSystemImage: String
    let fallbackIconFont: Font
    let maxPixelSize: CGFloat

    @StateObject private var loader: ImageLoader
    @State private var loadingIndicatorVisible = false
    @State private var demandObservationEnabled = false

    public init(
        urlString: String,
        siteHeader: [String: String]? = nil,
        showsLoadingIndicator: Bool = true,
        timeout: TimeInterval = 15,
        fallbackText: String? = nil,
        fallbackSystemImage: String = "film",
        fallbackIconFont: Font = .largeTitle,
        maxPixelSize: CGFloat = 1_200
    ) {
        self.urlString = urlString
        self.siteHeader = siteHeader
        self.showsLoadingIndicator = showsLoadingIndicator
        self.timeout = timeout
        self.fallbackText = fallbackText
        self.fallbackSystemImage = fallbackSystemImage
        self.fallbackIconFont = fallbackIconFont
        self.maxPixelSize = max(64, maxPixelSize)
        _loader = StateObject(wrappedValue: ImageLoader(
            from: urlString, headers: siteHeader, maxPixelSize: max(64, maxPixelSize), demand: .nearby
        ))
    }

    public var body: some View {
        Group {
            if let image = loader.image {
                Image(nsImage: image)
                    .resizable()
            } else if loader.isLoading && showsLoadingIndicator && loadingIndicatorVisible {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.1))
                    .overlay(
                        ProgressView()
                            .scaleEffect(0.6)
                    )
            } else {
                fallbackContent
            }
        }
        .background(PosterDemandVisibility(enabled: demandObservationEnabled) { demand in
            loader.setDemand(demand)
            loader.load(from: urlString, headers: siteHeader, timeout: timeout, maxPixelSize: maxPixelSize)
        })
        .onAppear {
            demandObservationEnabled = true
            loader.load(from: urlString, headers: siteHeader, timeout: timeout, maxPixelSize: maxPixelSize)
        }
        .onDisappear {
            demandObservationEnabled = false
            loader.setDemand(.inactive)
            loader.cancel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .posterWorkCapacityDidChange).receive(on: RunLoop.main)) { _ in
            guard loader.isDeferred else { return }
            loader.load(from: urlString, headers: siteHeader, timeout: timeout, maxPixelSize: maxPixelSize)
        }
        .task(id: loader.isLoading) {
            loadingIndicatorVisible = false
            guard loader.isLoading && showsLoadingIndicator else { return }
            do { try await Task.sleep(for: .milliseconds(150)) }
            catch { return }
            guard !Task.isCancelled, loader.isLoading else { return }
            loadingIndicatorVisible = true
        }
        .onChange(of: urlString) { _, newValue in
            loader.load(from: newValue, headers: siteHeader, timeout: timeout, maxPixelSize: maxPixelSize)
        }
        .onChange(of: siteHeader ?? [:]) { _, newValue in
            loader.load(from: urlString, headers: newValue, timeout: timeout, maxPixelSize: maxPixelSize)
        }
        .onChange(of: maxPixelSize) { _, newValue in
            loader.load(from: urlString, headers: siteHeader, timeout: timeout, maxPixelSize: newValue)
        }
    }

    @ViewBuilder
    private var fallbackContent: some View {
        if let fallbackText {
            let style = PosterFallbackStyle(title: fallbackText)
            Rectangle()
                .fill(style.color)
                .overlay {
                    Text(style.initial)
                        .font(.system(size: 38, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.94))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .padding(12)
                }
                .accessibilityHidden(true)
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.15))
                .overlay(
                    Image(systemName: fallbackSystemImage)
                        .font(fallbackIconFont)
                        .foregroundColor(.gray.opacity(0.3))
                )
        }
    }
}

/// Keep speculative work close to the visible rows and independent of cell reuse.
struct PosterImagePrefetchRequest: Equatable, Sendable {
    let urls: [String]
    let headers: [String: String]?
    let maxPixelSize: CGFloat

    init(urls: [String], headers: [String: String]? = nil, maxPixelSize: CGFloat) {
        var seen = Set<String>()
        var unique: [String] = []
        for url in urls where !url.isEmpty && seen.insert(url).inserted {
            unique.append(url)
            if unique.count == 64 { break }
        }
        self.urls = unique
        self.headers = headers
        self.maxPixelSize = ImageLoader.thumbnailPixelSize(maxPixelSize)
    }
}

/// Mirrors FongMi's title drawable: first character plus the Material 400 palette.
struct PosterFallbackStyle: Equatable {
    let initial: String
    let rgb: UInt32

    init(title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        initial = trimmed.first.map(String.init) ?? "！"
        rgb = Self.material400Palette[Self.paletteIndex(for: initial)]
    }

    var color: Color {
        Color(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }

    static func paletteIndex(for text: String) -> Int {
        var hash: Int32 = 0
        for codeUnit in text.utf16 {
            hash = hash &* 31 &+ Int32(codeUnit)
        }
        return Int(hash & Int32.max) % material400Palette.count
    }

    private static let material400Palette: [UInt32] = [
        0xEF5350, 0xEC407A, 0xAB47BC, 0x7E57C2, 0x5C6BC0,
        0x42A5F5, 0x29B6F6, 0x26C6DA, 0x26A69A, 0x66BB6A,
        0x9CCC65, 0xD4E157, 0xFFEE58, 0xFFCA28, 0xFFA726,
        0xFF7043, 0x8D6E63, 0xBDBDBD, 0x78909C,
    ]
}

struct EmbeddedImageSource: Equatable {
    let url: URL
    let headers: [String: String]

    static func parse(_ rawValue: String) -> EmbeddedImageSource? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let expression = try? NSRegularExpression(pattern: "@(Headers|Cookie|Referer|User-Agent)=")
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        let matches = expression?.matches(in: value, range: range) ?? []
        let rawURL: String
        var headers: [String: String] = [:]

        if let firstMatch = matches.first {
            rawURL = (value as NSString).substring(to: firstMatch.range.location)
            for (index, match) in matches.enumerated() {
                let name = (value as NSString).substring(with: match.range(at: 1))
                let valueStart = match.range.location + match.range.length
                let valueEnd = index + 1 < matches.count ? matches[index + 1].range.location : range.length
                let encodedValue = (value as NSString).substring(
                    with: NSRange(location: valueStart, length: max(0, valueEnd - valueStart))
                )
                let decodedValue = encodedValue.removingPercentEncoding ?? encodedValue
                addHeader(name: name, value: decodedValue, to: &headers)
            }
        } else {
            rawURL = value
        }

        guard let url = URLHelper.formatUrl(rawURL) else { return nil }
        if url.scheme == MediaServerArtworkReference.scheme {
            guard let reference = MediaServerArtworkReference(locator: rawURL), headers.isEmpty,
                  let canonicalURL = URL(string: reference.locator) else { return nil }
            return EmbeddedImageSource(url: canonicalURL, headers: [:])
        }
        return EmbeddedImageSource(url: url, headers: headers)
    }

    private static func addHeader(name: String, value: String, to headers: inout [String: String]) {
        if name.caseInsensitiveCompare("Headers") == .orderedSame,
           let data = value.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (key, value) in object {
                headers[URLHelper.fixHeaderKey(key)] = String(describing: value)
            }
            return
        }

        headers[URLHelper.fixHeaderKey(name)] = value
    }
}

enum PosterImageError: Error {
    case httpStatus(Int)
    case invalidData(Int)
    case placeholderImage(width: CGFloat, height: CGFloat, bytes: Int)
}

struct DecodedPosterImage: @unchecked Sendable {
    let cgImage: CGImage
    let byteCount: Int

    var memoryCost: Int {
        max(byteCount, cgImage.width * cgImage.height * 4)
    }
}

actor PosterImagePipeline {
    static let shared = PosterImagePipeline()

    private struct Waiter: Sendable {
        let continuation: CheckedContinuation<DecodedPosterImage, Error>
        let token: PosterDemandToken
    }

    private struct ImageInFlight: Sendable {
        let id: UUID
        let generation: UInt64
        let dataKey: String
        let dataID: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: Waiter]
        var demand: PosterDemand { waiters.values.map { $0.token.value }.min() ?? .inactive }
    }

    private struct DataInFlight: Sendable {
        let id: UUID
        let generation: UInt64
        let task: Task<Void, Never>
        var consumers: Int
        var result: Swift.Result<Data, Error>?
        var waiters: [UUID: CheckedContinuation<Data, Error>] = [:]
    }

    private let session: URLSession
    private let mediaServerRuntime: MediaServerRuntime
    private let cacheDirectory: URL
    private let fileManager: FileManager
    private let maximumDiskBytes: Int64
    private let ttl: TimeInterval
    private let now: @Sendable () -> Date
    private enum WorkStage: Sendable { case download, decode }
    private let backgroundBudget: PlaybackBackgroundBudget
    private var budgetObservation: Task<Void, Never>?
    private let downloads: PosterWorkQueue
    private let decodes: PosterWorkQueue
    private let maximumOutstandingImages: Int
    private let decoder: @Sendable (Data, CGFloat) throws -> DecodedPosterImage
    private var peakOutstandingImages = 0
    private var deferredCount = 0
    private var imageTaskCount = 0
    private var capacityNotificationScheduled = false
    private var inFlight: [String: ImageInFlight] = [:]
    private var dataInFlight: [String: DataInFlight] = [:]
    private var generation: UInt64 = 0

    init(
        session: URLSession? = nil,
        cacheDirectory: URL? = nil,
        fileManager: FileManager = .default,
        maximumDiskBytes: Int64 = 256 * 1024 * 1024,
        ttl: TimeInterval = 7 * 24 * 60 * 60,
        maximumConcurrentDownloads: Int = 8,
        maximumConcurrentDecodes: Int = 2,
        maximumOutstandingImages: Int = 96,
        backgroundBudget: PlaybackBackgroundBudget = .shared,
        decoder: (@Sendable (Data, CGFloat) throws -> DecodedPosterImage)? = nil,
        now: @escaping @Sendable () -> Date = Date.init,
        mediaServerRuntime: MediaServerRuntime = .shared
    ) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.httpMaximumConnectionsPerHost = maximumConcurrentDownloads
            self.session = URLSession(configuration: configuration)
        }
        self.cacheDirectory = cacheDirectory ?? CacheManager.shared.directory(for: .posters)
        self.fileManager = fileManager
        self.maximumDiskBytes = max(1, maximumDiskBytes)
        self.ttl = max(0, ttl)
        self.maximumOutstandingImages = max(1, maximumOutstandingImages)
        self.backgroundBudget = backgroundBudget
        let permits: (PosterDemand) -> Bool = { demand in
            demand.isSpeculative ? backgroundBudget.permitsOptionalWork : backgroundBudget.permitsVisibleWork
        }
        self.downloads = PosterWorkQueue(limit: maximumConcurrentDownloads, speculativeLimit: 2,
            maximumWaiting: max(1, maximumOutstandingImages), permits: permits)
        self.decodes = PosterWorkQueue(limit: maximumConcurrentDecodes, speculativeLimit: 1,
            maximumWaiting: max(1, maximumOutstandingImages), permits: permits)
        self.decoder = decoder ?? Self.decode
        self.now = now
        self.mediaServerRuntime = mediaServerRuntime
        try? fileManager.createDirectory(at: self.cacheDirectory, withIntermediateDirectories: true)
    }

    deinit { budgetObservation?.cancel() }

    private func observeBudgetIfNeeded() {
        guard budgetObservation == nil else { return }
        let changes = backgroundBudget.permissionChanges()
        budgetObservation = Task { [weak self] in
            for await _ in changes {
                guard !Task.isCancelled else { break }
                await self?.refreshDemand()
            }
        }
    }

    func waitForPrefetchPermission() async throws {
        try await backgroundBudget.waitForOptionalPermission()
    }

    func image(
        request: URLRequest,
        key: String,
        maxPixelSize: CGFloat,
        demand token: PosterDemandToken = PosterDemandToken()
    ) async throws -> DecodedPosterImage {
        try Task.checkCancellation()
        observeBudgetIfNeeded()
        let sizedKey = "\(key)-\(Int(maxPixelSize.rounded()))"
        let requestGeneration = generation
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            let image: DecodedPosterImage = try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled, requestGeneration == generation else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                addWaiter(
                    continuation, id: waiterID, sizedKey: sizedKey,
                    request: request, key: key, maxPixelSize: maxPixelSize, token: token
                )
            }
            try Task.checkCancellation()
            guard requestGeneration == generation else { throw CancellationError() }
            return image
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID, sizedKey: sizedKey) }
        }
    }

    private func addWaiter(
        _ continuation: CheckedContinuation<DecodedPosterImage, Error>,
        id waiterID: UUID,
        sizedKey: String,
        request: URLRequest,
        key: String,
        maxPixelSize: CGFloat,
        token: PosterDemandToken
    ) {
        let requestGeneration = generation
        if var existing = inFlight[sizedKey], existing.generation == requestGeneration {
            existing.waiters[waiterID] = Waiter(continuation: continuation, token: token)
            inFlight[sizedKey] = existing
            refreshDemand()
            return
        }

        guard token.value.tier != .inactive else {
            continuation.resume(throwing: CancellationError())
            return
        }
        if inFlight.count >= maximumOutstandingImages {
            guard let victim = inFlight.max(by: { $0.value.demand < $1.value.demand }),
                  token.value < victim.value.demand else {
                deferredCount += 1
                continuation.resume(throwing: PosterWorkDeferred())
                return
            }
            evictRequest(sizedKey: victim.key)
        }

        let dataID: UUID
        if var existing = dataInFlight[key], existing.generation == requestGeneration {
            existing.consumers += 1
            dataInFlight[key] = existing
            dataID = existing.id
        } else {
            dataID = UUID()
            let downloadID = dataID
            let dataTask = Task {
                do {
                    let bytes = try await data(request: request, key: key, id: downloadID, generation: requestGeneration)
                    finishData(key: key, id: downloadID, result: .success(bytes))
                } catch { finishData(key: key, id: downloadID, result: .failure(error)) }
            }
            dataInFlight[key] = DataInFlight(
                id: dataID, generation: requestGeneration, task: dataTask, consumers: 1
            )
        }
        let requestID = UUID()
        imageTaskCount += 1
        let decodeTask = Task {
            defer { imageTaskCount -= 1 }
            do {
                let data = try await awaitData(key: key, id: dataID, consumerID: requestID)
                try Task.checkCancellation()
                guard requestGeneration == generation else { throw CancellationError() }
                let image = try await decodeImage(data, maxPixelSize: maxPixelSize, id: requestID, sizedKey: sizedKey)
                try Task.checkCancellation()
                guard requestGeneration == generation else { throw CancellationError() }
                // A full/read-only disk must not discard a successfully decoded poster.
                do {
                    try persistIfNeeded(data, key: key, generation: requestGeneration)
                } catch {
                    DiagnosticLog.write("[POSTER_CACHE_WRITE_FAILED] error=\(error.localizedDescription)")
                }
                finishRequest(id: requestID, sizedKey: sizedKey, result: .success(image))
            } catch {
                if inFlight[sizedKey]?.id == requestID, requestGeneration == generation,
                   error is PosterImageError {
                    try? fileManager.removeItem(at: cacheFileURL(for: key))
                }
                finishRequest(id: requestID, sizedKey: sizedKey, result: .failure(error))
            }
        }
        inFlight[sizedKey] = ImageInFlight(
            id: requestID, generation: requestGeneration, dataKey: key, dataID: dataID,
            task: decodeTask, waiters: [waiterID: Waiter(continuation: continuation, token: token)]
        )
        peakOutstandingImages = max(peakOutstandingImages, inFlight.count)
        refreshDemand()
    }

    private func cancelWaiter(id: UUID, sizedKey: String) {
        guard var request = inFlight[sizedKey],
              let waiter = request.waiters.removeValue(forKey: id) else { return }
        if request.waiters.isEmpty {
            inFlight[sizedKey] = nil
            decodes.cancel(id: request.id)
            cancelDataWaiter(key: request.dataKey, id: request.dataID, consumerID: request.id)
            request.task.cancel()
            releaseDataConsumer(key: request.dataKey, id: request.dataID)
        } else {
            inFlight[sizedKey] = request
        }
        waiter.continuation.resume(throwing: CancellationError())
        refreshDemand()
        notifyCapacityChange()
    }

    private func finishRequest(
        id: UUID,
        sizedKey: String,
        result: Swift.Result<DecodedPosterImage, Error>
    ) {
        guard let request = inFlight[sizedKey], request.id == id else { return }
        inFlight[sizedKey] = nil
        releaseDataConsumer(key: request.dataKey, id: request.dataID)
        for waiter in request.waiters.values { waiter.continuation.resume(with: result) }
        refreshDemand()
        notifyCapacityChange()
    }

    private func releaseDataConsumer(key: String, id: UUID) {
        // A cancelled decode may finish after the same key has started a new download.
        guard var request = dataInFlight[key], request.id == id else { return }
        request.consumers -= 1
        if request.consumers == 0 {
            dataInFlight[key] = nil
            downloads.cancel(id: request.id)
            request.task.cancel()
            for waiter in request.waiters.values { waiter.resume(throwing: CancellationError()) }
        } else {
            dataInFlight[key] = request
        }
    }

    private func awaitData(key: String, id: UUID, consumerID: UUID) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled, var data = dataInFlight[key], data.id == id else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if let result = data.result { continuation.resume(with: result) }
                else {
                    data.waiters[consumerID] = continuation
                    dataInFlight[key] = data
                }
            }
        } onCancel: {
            Task { await self.cancelDataWaiter(key: key, id: id, consumerID: consumerID) }
        }
    }

    private func finishData(key: String, id: UUID, result: Swift.Result<Data, Error>) {
        guard var data = dataInFlight[key], data.id == id else { return }
        let waiters = data.waiters.values
        data.result = result
        data.waiters.removeAll()
        dataInFlight[key] = data
        for waiter in waiters { waiter.resume(with: result) }
    }

    private func cancelDataWaiter(key: String, id: UUID, consumerID: UUID) {
        guard dataInFlight[key]?.id == id else { return }
        dataInFlight[key]?.waiters.removeValue(forKey: consumerID)?.resume(throwing: CancellationError())
    }

    func updateDemand(_ token: PosterDemandToken) {
        // Tokens belonging to old requests cannot alter a replacement's demand.
        guard inFlight.values.contains(where: { $0.waiters.values.contains { $0.token === token } }) else { return }
        refreshDemand()
    }

    private func refreshDemand() {
        var dataDemands: [UUID: PosterDemand] = [:]
        for request in inFlight.values {
            let demand = request.demand
            decodes.update(id: request.id, demand: demand)
            dataDemands[request.dataID] = min(dataDemands[request.dataID] ?? .inactive, demand)
        }
        for data in dataInFlight.values {
            downloads.update(id: data.id, demand: dataDemands[data.id] ?? .inactive)
        }
        downloads.drain()
        decodes.drain()
    }

    private func evictRequest(sizedKey: String) {
        guard let request = inFlight.removeValue(forKey: sizedKey) else { return }
        deferredCount += 1
        decodes.cancel(id: request.id)
        cancelDataWaiter(key: request.dataKey, id: request.dataID, consumerID: request.id)
        request.task.cancel()
        releaseDataConsumer(key: request.dataKey, id: request.dataID)
        for waiter in request.waiters.values { waiter.continuation.resume(throwing: PosterWorkDeferred()) }
    }

    private func workQueue(_ stage: WorkStage) -> PosterWorkQueue {
        switch stage { case .download: downloads; case .decode: decodes }
    }

    private func acquireWork(id: UUID, demand: PosterDemand, stage: WorkStage) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                workQueue(stage).enqueue(id: id, demand: demand, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancelWork(id: id, stage: stage) }
        }
    }

    private func cancelWork(id: UUID, stage: WorkStage) { workQueue(stage).cancel(id: id) }
    private func releaseWork(id: UUID, stage: WorkStage) { workQueue(stage).release(id: id) }

    private func decodeImage(_ data: Data, maxPixelSize: CGFloat, id: UUID, sizedKey: String) async throws -> DecodedPosterImage {
        try Task.checkCancellation()
        try await acquireWork(id: id, demand: inFlight[sizedKey]?.demand ?? .inactive, stage: .decode)
        defer { releaseWork(id: id, stage: .decode) }
        try Task.checkCancellation()
        let decoder = self.decoder
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            return try decoder(data, maxPixelSize)
        }
        // Cancelling a waiter cannot release a slot while ImageIO is still running.
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    func schedulingMetrics() -> (downloads: PosterWorkMetrics, decodes: PosterWorkMetrics, outstanding: Int, peakOutstanding: Int, deferred: Int, imageTasks: Int, dataWaiters: Int) {
        (downloads.metrics, decodes.metrics, inFlight.count, peakOutstandingImages, deferredCount,
            imageTaskCount, dataInFlight.values.reduce(0) { $0 + $1.waiters.count })
    }

    private func notifyCapacityChange() {
        guard !capacityNotificationScheduled else { return }
        capacityNotificationScheduled = true
        Task {
            await Task.yield()
            capacityNotificationScheduled = false
            NotificationCenter.default.post(name: .posterWorkCapacityDidChange, object: nil)
        }
    }

    func diskUsage() -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: cacheDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileAllocatedSizeKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .fileAllocatedSizeKey, .fileSizeKey]
            ), values.isRegularFile == true else { continue }
            total += Int64(values.fileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
    }

    func clearDiskCache() throws {
        generation &+= 1
        for request in inFlight.values {
            decodes.cancel(id: request.id)
            request.task.cancel()
            for waiter in request.waiters.values {
                waiter.continuation.resume(throwing: CancellationError())
            }
        }
        for request in dataInFlight.values {
            downloads.cancel(id: request.id)
            request.task.cancel()
            for waiter in request.waiters.values { waiter.resume(throwing: CancellationError()) }
        }
        inFlight.removeAll()
        dataInFlight.removeAll()
        if fileManager.fileExists(atPath: cacheDirectory.path) {
            try fileManager.removeItem(at: cacheDirectory)
        }
        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        NotificationCenter.default.post(name: .netVplayerCacheDidChange, object: nil)
    }

    private func data(request: URLRequest, key: String, id: UUID, generation requestGeneration: UInt64) async throws -> Data {
        try Task.checkCancellation()
        guard requestGeneration == generation else { throw CancellationError() }
        if let url = request.url, url.isFileURL {
            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            let data = try handle.read(upToCount: 4 * 1024 * 1024 + 1) ?? Data()
            guard !data.isEmpty, data.count <= 4 * 1024 * 1024 else { throw PosterImageError.invalidData(data.count) }
            return data
        }
        let fileURL = cacheFileURL(for: key)
        if let values = try? fileURL.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey]),
           let storedAt = values.creationDate ?? values.contentModificationDate,
           now().timeIntervalSince(storedAt) <= ttl,
           let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]),
           !data.isEmpty {
            guard requestGeneration == generation else { throw CancellationError() }
            try? fileManager.setAttributes([.modificationDate: now()], ofItemAtPath: fileURL.path)
            return data
        }
        try? fileManager.removeItem(at: fileURL)

        let demand = inFlight.values.filter { $0.dataID == id }.map(\.demand).min() ?? .inactive
        try await acquireWork(id: id, demand: demand, stage: .download)
        let responseData: Data
        let response: URLResponse
        do {
            try Task.checkCancellation()
            guard requestGeneration == generation else { throw CancellationError() }
            var uncachedRequest = request
            uncachedRequest.cachePolicy = .reloadIgnoringLocalCacheData
            if let url = uncachedRequest.url, url.scheme == MediaServerArtworkReference.scheme {
                guard let reference = MediaServerArtworkReference(locator: url.absoluteString),
                      let imageResponse = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
                else { throw PosterImageError.invalidData(0) }
                responseData = try await mediaServerRuntime.artwork(reference)
                response = imageResponse
            } else if let url = uncachedRequest.url, SourceResourceTransport.supportsPoster(url) {
                let resource = try await SourceResourceTransport.response(
                    for: url, headers: uncachedRequest.allHTTPHeaderFields ?? [:],
                    timeout: uncachedRequest.timeoutInterval
                )
                guard let httpResponse = HTTPURLResponse(
                    url: url, statusCode: resource.statusCode, httpVersion: "HTTP/1.1", headerFields: nil
                ) else { throw URLError(.badServerResponse) }
                (responseData, response) = (resource.data, httpResponse)
            } else {
                (responseData, response) = try await session.data(for: uncachedRequest)
            }
            releaseWork(id: id, stage: .download)
        } catch {
            releaseWork(id: id, stage: .download)
            throw error
        }
        try Task.checkCancellation()
        guard requestGeneration == generation else { throw CancellationError() }
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw PosterImageError.httpStatus(httpResponse.statusCode)
        }
        guard !responseData.isEmpty else { throw PosterImageError.invalidData(0) }
        return responseData
    }

    private func persistIfNeeded(_ data: Data, key: String, generation requestGeneration: UInt64) throws {
        guard requestGeneration == generation else { throw CancellationError() }
        let fileURL = cacheFileURL(for: key)
        guard !fileManager.fileExists(atPath: fileURL.path) else { return }
        try data.write(to: fileURL, options: .atomic)
        // Creation time is the fixed TTL anchor; modification time tracks LRU access.
        try fileManager.setAttributes([.creationDate: now(), .modificationDate: now()], ofItemAtPath: fileURL.path)
        try trimIfNeeded()
        NotificationCenter.default.post(name: .netVplayerCacheDidChange, object: nil)
    }

    private func cacheFileURL(for key: String) -> URL {
        cacheDirectory.appendingPathComponent(key).appendingPathExtension("img")
    }

    private func trimIfNeeded() throws {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileAllocatedSizeKey, .fileSizeKey, .contentModificationDateKey]
        guard let urls = try? fileManager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return }

        var files: [(url: URL, bytes: Int64, date: Date)] = []
        var total: Int64 = 0
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }
            let bytes = Int64(values.fileAllocatedSize ?? values.fileSize ?? 0)
            total += bytes
            files.append((url, bytes, values.contentModificationDate ?? .distantPast))
        }
        guard total > maximumDiskBytes else { return }
        let target = Int64(Double(maximumDiskBytes) * 0.9)
        for file in files.sorted(by: { $0.date < $1.date }) where total > target {
            try? fileManager.removeItem(at: file.url)
            total -= file.bytes
        }
    }

    nonisolated static func decode(data: Data, maxPixelSize: CGFloat) throws -> DecodedPosterImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw PosterImageError.invalidData(data.count)
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        guard !ImageLoader.isPlaceholderImage(width: width, height: height, dataCount: data.count) else {
            throw PosterImageError.placeholderImage(width: width, height: height, bytes: data.count)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(64, Int(maxPixelSize.rounded())),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw PosterImageError.invalidData(data.count)
        }
        return DecodedPosterImage(cgImage: image, byteCount: data.count)
    }
}

/// 线程安全的图片下载与缓存加载器
@MainActor
final class ImageLoader: ObservableObject {
    @Published var image: NSImage? = nil
    @Published var isLoading: Bool = false
    private(set) var isDeferred = false
    #if DEBUG
    private(set) var diagnosticFailure: (domain: String, code: Int)?
    #endif

    typealias ImageLoadError = PosterImageError

    private static let imageCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()
    private static var failedAt: [String: Date] = [:]
    private static var memoryGeneration: UInt64 = 0
    private static let failureTTL: TimeInterval = 60
    private static let woggFallbackPosterURL = "https://cos.ffnews.cn/feedback/20251217/6941c9f5c06e2.jpg"

    private var currentTask: Task<Void, Never>? = nil
    private var currentKey: String = ""
    private var currentRequestID = UUID()
    private var currentGeneration: UInt64
    private let pipeline: PosterImagePipeline
    private var demand: PosterDemand
    private var demandToken = PosterDemandToken()

    init(
        from urlString: String? = nil,
        headers: [String: String]? = nil,
        maxPixelSize: CGFloat = 1_200,
        pipeline: PosterImagePipeline = .shared,
        demand: PosterDemand = .visible
    ) {
        self.pipeline = pipeline
        self.demand = demand
        currentGeneration = Self.memoryGeneration
        // A rebuilt SwiftUI cell should have its cached image on the first frame,
        // before onAppear. Initialization performs no I/O or speculative download.
        if let urlString, let source = EmbeddedImageSource.parse(urlString) {
            let effectiveHeaders = Self.mergedHeaders(siteHeaders: headers, embeddedHeaders: source.headers)
            let key = Self.cacheKey(url: source.url, headers: effectiveHeaders)
            let imageKey = "\(key)-\(Int(Self.thumbnailPixelSize(maxPixelSize)))"
            if let cached = Self.imageCache.object(forKey: imageKey as NSString) {
                image = cached
                currentKey = imageKey
            }
        }
    }

    deinit {
        currentTask?.cancel()
    }

    func setDemand(_ demand: PosterDemand) {
        guard self.demand != demand else { return }
        self.demand = demand
        demandToken.update(demand)
        if demand.tier == .inactive { cancel(); return }
        let token = demandToken
        let pipeline = pipeline
        Task { await pipeline.updateDemand(token) }
    }

    func cancel() {
        isDeferred = false
        currentRequestID = UUID()
        currentTask?.cancel()
        currentTask = nil
        // Keep a completed image associated with its source while offscreen.
        // Explicit cache clearing is handled by currentGeneration in load().
        isLoading = false
    }

    func load(
        from urlString: String,
        headers: [String: String]? = nil,
        timeout: TimeInterval = 15,
        maxPixelSize: CGFloat = 1_200
    ) {
        guard demand.tier != .inactive else { return }
        guard let source = EmbeddedImageSource.parse(urlString) else {
            cancel()
            self.image = nil
            return
        }

        let url = source.url
        let effectiveHeaders = Self.mergedHeaders(siteHeaders: headers, embeddedHeaders: source.headers)
        let requestKey = Self.cacheKey(url: url, headers: effectiveHeaders)
        let pixelSize = Self.thumbnailPixelSize(maxPixelSize)
        let imageKey = "\(requestKey)-\(Int(pixelSize))"
        if currentGeneration == Self.memoryGeneration,
           currentKey == imageKey, image != nil || isLoading {
            return
        }
        currentTask?.cancel()
        currentTask = nil
        isDeferred = false
        demandToken = PosterDemandToken(demand)
        let token = demandToken
        currentKey = imageKey
        currentGeneration = Self.memoryGeneration
        let requestID = UUID()
        currentRequestID = requestID

        if let cached = Self.imageCache.object(forKey: imageKey as NSString) {
            self.image = cached
            self.isLoading = false
            return
        }

        if Self.isRecentlyFailed(requestKey) {
            self.image = nil
            self.isLoading = false
            return
        }

        self.image = nil
        self.isLoading = true
        #if DEBUG
        diagnosticFailure = nil
        #endif

        let request = Self.makeRequest(
            url: url,
            headers: headers,
            embeddedHeaders: source.headers,
            timeout: timeout
        )
        let requestGeneration = Self.memoryGeneration
        let pipeline = self.pipeline
        currentTask = Task { [weak self] in
            do {
                let decoded = try await pipeline.image(
                    request: request,
                    key: requestKey,
                    maxPixelSize: pixelSize, demand: token
                )
                try Task.checkCancellation()
                guard requestGeneration == Self.memoryGeneration else { throw CancellationError() }
                let nsImage = NSImage(
                    cgImage: decoded.cgImage,
                    size: NSSize(width: decoded.cgImage.width, height: decoded.cgImage.height)
                )
                Self.imageCache.setObject(nsImage, forKey: imageKey as NSString, cost: decoded.memoryCost)
                guard let self, self.currentRequestID == requestID else { return }
                self.image = nsImage
                self.isLoading = false
            } catch is CancellationError {
                guard let self, self.currentRequestID == requestID else { return }
                self.isLoading = false
            } catch {
                if error is PosterWorkDeferred {
                    guard let self, self.currentRequestID == requestID else { return }
                    self.isDeferred = !Task.isCancelled && requestGeneration == Self.memoryGeneration
                    self.isLoading = false
                    return
                }
                guard !Task.isCancelled, requestGeneration == Self.memoryGeneration else {
                    if let self, self.currentRequestID == requestID { self.isLoading = false }
                    return
                }
                if let fallbackURL = Self.fallbackURL(for: url, headers: effectiveHeaders, error: error) {
                    let fallbackRequestKey = Self.cacheKey(url: fallbackURL, headers: effectiveHeaders)
                    let fallbackImageKey = "\(fallbackRequestKey)-\(Int(pixelSize))"
                    if !Self.isRecentlyFailed(fallbackRequestKey) {
                        do {
                            let fallbackRequest = Self.makeRequest(
                                url: fallbackURL,
                                headers: headers,
                                embeddedHeaders: source.headers,
                                timeout: timeout
                            )
                            let decoded = try await pipeline.image(
                                request: fallbackRequest,
                                key: fallbackRequestKey,
                                maxPixelSize: pixelSize, demand: token
                            )
                            try Task.checkCancellation()
                            guard requestGeneration == Self.memoryGeneration else { throw CancellationError() }
                            let fallbackImage = NSImage(
                                cgImage: decoded.cgImage,
                                size: NSSize(width: decoded.cgImage.width, height: decoded.cgImage.height)
                            )
                            Self.imageCache.setObject(fallbackImage, forKey: imageKey as NSString, cost: decoded.memoryCost)
                            Self.imageCache.setObject(fallbackImage, forKey: fallbackImageKey as NSString, cost: decoded.memoryCost)
                            Self.logFallback(from: url, to: fallbackURL, reason: error)
                            guard let self, self.currentRequestID == requestID else { return }
                            self.image = fallbackImage
                            self.isLoading = false
                            return
                        } catch {
                            if error is PosterWorkDeferred {
                                guard let self, self.currentRequestID == requestID else { return }
                                self.isDeferred = !Task.isCancelled && requestGeneration == Self.memoryGeneration
                                self.isLoading = false
                                return
                            }
                            guard !Task.isCancelled, requestGeneration == Self.memoryGeneration,
                                  !(error is CancellationError) else {
                                if let self, self.currentRequestID == requestID { self.isLoading = false }
                                return
                            }
                            Self.markFailed(fallbackRequestKey)
                            Self.logFailure(error, url: fallbackURL, timeout: timeout)
                        }
                    }
                }
                Self.markFailed(requestKey)
                Self.logFailure(error, url: url, timeout: timeout)
                guard let self, self.currentRequestID == requestID else { return }
                #if DEBUG
                let failure = error as NSError
                self.diagnosticFailure = (failure.domain, failure.code)
                #endif
                self.image = nil
                self.isLoading = false
            }
        }
    }

    /// Nearby layout sizes share one decoded thumbnail instead of flashing on resize.
    nonisolated static func thumbnailPixelSize(_ requested: CGFloat) -> CGFloat {
        max(64, ceil(requested / 32) * 32)
    }

    static func prefetch(_ request: PosterImagePrefetchRequest, pipeline: PosterImagePipeline = .shared) async {
        guard !request.urls.isEmpty, !Task.isCancelled else { return }
        let requestGeneration = memoryGeneration
        await withTaskGroup(of: Void.self) { group in
            let initialCount = min(2, request.urls.count)
            for url in request.urls.prefix(initialCount) {
                group.addTask(priority: .utility) {
                    await prefetchImage(url, request: request, generation: requestGeneration, pipeline: pipeline)
                }
            }
            var next = initialCount
            for await _ in group {
                guard !Task.isCancelled, requestGeneration == memoryGeneration else { group.cancelAll(); break }
                if next < request.urls.count {
                    let url = request.urls[next]
                    next += 1
                    group.addTask(priority: .utility) {
                        await prefetchImage(url, request: request, generation: requestGeneration, pipeline: pipeline)
                    }
                }
            }
        }
    }

    private static func prefetchImage(
        _ url: String, request: PosterImagePrefetchRequest, generation: UInt64, pipeline: PosterImagePipeline
    ) async {
        do { try await pipeline.waitForPrefetchPermission() } catch { return }
        guard !Task.isCancelled, generation == memoryGeneration else { return }
        let loader = ImageLoader(from: url, headers: request.headers, maxPixelSize: request.maxPixelSize, pipeline: pipeline, demand: .prefetch)
        defer { loader.cancel() }
        loader.load(from: url, headers: request.headers, maxPixelSize: request.maxPixelSize)
        let work = loader.currentTask
        await withTaskCancellationHandler {
            await work?.value
        } onCancel: {
            work?.cancel()
        }
    }

    static func makeRequest(
        url: URL,
        headers: [String: String]?,
        embeddedHeaders: [String: String] = [:],
        timeout: TimeInterval
    ) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: timeout)
        // Native artwork resolves the account and attaches credentials only inside MediaServerRuntime.
        if url.scheme == MediaServerArtworkReference.scheme { return request }

        // 1. 注入通用的 User-Agent，避免某些 CDN 拒绝命令爬取
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")

        // 2. 覆盖注入当前站点专属的 HTTP 头部配置 (如果有)
        if let headers = headers {
            for (key, val) in headers {
                request.setValue(val, forHTTPHeaderField: key)
            }
        }

        // 3. 根据图片本身的 URL Host，自动推断并注入防盗链 Referer
        // 已知图片 CDN 的防盗链通常跟图片源站绑定，不能继承视频站点 Referer。
        if let host = url.host {
            if host.hasSuffix("doubanio.com") {
                request.setValue("https://www.douban.com/", forHTTPHeaderField: "Referer")
            } else if host.hasSuffix("baidu.com"), url.path.contains("/gimg") {
                request.setValue("https://image.baidu.com/", forHTTPHeaderField: "Referer")
            } else if host.contains("douyu") {
                request.setValue("https://www.douyu.com", forHTTPHeaderField: "Referer")
            } else if host.contains("huya") {
                request.setValue("https://www.huya.com", forHTTPHeaderField: "Referer")
            } else if request.value(forHTTPHeaderField: "Referer") == nil {
                request.setValue("https://\(host)", forHTTPHeaderField: "Referer")
            }
        }

        // URL-embedded headers are explicit source instructions and take final precedence.
        for (key, value) in embeddedHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        return request
    }

    static func mergedHeaders(
        siteHeaders: [String: String]?,
        embeddedHeaders: [String: String]
    ) -> [String: String] {
        var result = siteHeaders ?? [:]
        for (key, value) in embeddedHeaders {
            if let existingKey = result.keys.first(where: { $0.caseInsensitiveCompare(key) == .orderedSame }) {
                result.removeValue(forKey: existingKey)
            }
            result[key] = value
        }
        return result
    }

    nonisolated static func cacheKey(url: URL, headers: [String: String]?) -> String {
        var canonical = url.absoluteString
        for (key, value) in (headers ?? [:]).sorted(by: { $0.key.lowercased() < $1.key.lowercased() }) {
            canonical += "\n\(key.lowercased()):\(value)"
        }
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func isRecentlyFailed(_ key: String) -> Bool {
        guard let failedDate = failedAt[key] else { return false }
        if Date().timeIntervalSince(failedDate) < failureTTL {
            return true
        }
        failedAt.removeValue(forKey: key)
        return false
    }

    private static func markFailed(_ key: String) {
        failedAt[key] = Date()
    }

    static func fallbackURL(for url: URL, headers: [String: String]?, error: Error) -> URL? {
        if let ygpFallback = ygpFallbackURL(for: url, error: error) {
            return ygpFallback
        }
        guard shouldUseWoggFallbackPoster(for: url, headers: headers, error: error),
              url.absoluteString != woggFallbackPosterURL else {
            return nil
        }
        return URL(string: woggFallbackPosterURL)
    }

    private static func ygpFallbackURL(for url: URL, error: Error) -> URL? {
        guard isRecoverableImageFailure(error),
              let host = url.host?.lowercased(),
              host == "6huo.com" || host.hasSuffix(".6huo.com"),
              url.path != "/files/mpic/default.jpg",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = "/files/mpic/default.jpg"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private static func shouldUseWoggFallbackPoster(for url: URL, headers: [String: String]?, error: Error) -> Bool {
        guard isRecoverableImageFailure(error),
              let host = url.host?.lowercased() else {
            return false
        }

        if headers?.contains(where: { key, value in
            key.lowercased() == "referer" && value.lowercased().contains("wogg.net")
        }) == true {
            return true
        }
        if host.hasSuffix("baidu.com"), url.path.contains("/gimg") {
            return true
        }
        if host.hasSuffix("doubanio.com") {
            return true
        }
        return false
    }

    private static func isRecoverableImageFailure(_ error: Error) -> Bool {
        if case ImageLoadError.httpStatus = error { return true }
        if case ImageLoadError.placeholderImage = error { return true }
        if case ImageLoadError.invalidData = error { return true }
        return false
    }

    private static func logFailure(_ error: Error, url: URL, timeout: TimeInterval) {
        if isTimeout(error) {
            DiagnosticLog.write("[WEB_IMAGE_TIMEOUT] url=\(redactedURL(url)) timeout=\(String(format: "%.1f", timeout))s")
        } else if case ImageLoadError.placeholderImage(let width, let height, let bytes) = error {
            DiagnosticLog.write("[WEB_IMAGE_PLACEHOLDER] url=\(redactedURL(url)) size=\(Int(width))x\(Int(height)) bytes=\(bytes)")
        } else if case ImageLoadError.httpStatus(let statusCode) = error {
            DiagnosticLog.write("[WEB_IMAGE_HTTP_ERROR] status=\(statusCode) url=\(redactedURL(url))")
        } else if case ImageLoadError.invalidData(let bytes) = error {
            DiagnosticLog.write("[WEB_IMAGE_INVALID_DATA] url=\(redactedURL(url)) bytes=\(bytes)")
        } else {
            #if DEBUG
            let failure = error as NSError
            DiagnosticLog.write("[WEB_IMAGE_NETWORK_ERROR] domain=\(failure.domain) code=\(failure.code) url=\(redactedURL(url))")
            #endif
        }
    }

    private static func logFallback(from url: URL, to fallbackURL: URL, reason: Error) {
        DiagnosticLog.write("[WEB_IMAGE_FALLBACK] from=\(redactedURL(url)) to=\(redactedURL(fallbackURL)) reason=\(failureReason(reason))")
    }

    private static func failureReason(_ error: Error) -> String {
        if case ImageLoadError.httpStatus(let statusCode) = error {
            return "http-\(statusCode)"
        }
        if case ImageLoadError.placeholderImage(let width, let height, let bytes) = error {
            return "placeholder-\(Int(width))x\(Int(height))-\(bytes)b"
        }
        if case ImageLoadError.invalidData(let bytes) = error {
            return "invalid-\(bytes)b"
        }
        if isTimeout(error) {
            return "timeout"
        }
        return "error"
    }

    nonisolated static func isPlaceholderImage(_ image: NSImage, dataCount: Int) -> Bool {
        isPlaceholderImage(width: image.size.width, height: image.size.height, dataCount: dataCount)
    }

    nonisolated static func isPlaceholderImage(width: CGFloat, height: CGFloat, dataCount: Int) -> Bool {
        let width = max(0, width)
        let height = max(0, height)
        guard width > 0, height > 0 else { return true }
        if dataCount <= 256, width <= 16, height <= 16 {
            return true
        }
        if dataCount <= 2_500, width >= 120, height >= 120 {
            return true
        }
        return false
    }

    static func clearMemoryCache() {
        memoryGeneration &+= 1
        imageCache.removeAllObjects()
        failedAt.removeAll()
    }

    private static func isTimeout(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return urlError.code == .timedOut
        }
        return error.localizedDescription.lowercased().contains("timed out")
    }

    private static func redactedURL(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems
        components?.queryItems = queryItems?.map { URLQueryItem(name: $0.name, value: "<redacted>") }
        return components?.url?.absoluteString ?? "\(url.scheme ?? "")://\(url.host ?? "")\(url.path)"
    }

}
