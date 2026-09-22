// NetVplayerApp/Views/WebImage.swift
// 支持自定义 Headers 和自动防盗链校验的网络图片加载器

import SwiftUI
import Cocoa
import CryptoKit
import ImageIO
import Models
import Networking
import Storage

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

    @StateObject private var loader = ImageLoader()

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
    }

    public var body: some View {
        Group {
            if let image = loader.image {
                Image(nsImage: image)
                    .resizable()
            } else if loader.isLoading && showsLoadingIndicator {
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
        .onAppear {
            loader.load(from: urlString, headers: siteHeader, timeout: timeout, maxPixelSize: maxPixelSize)
        }
        .onChange(of: urlString) { _, newValue in
            loader.load(from: newValue, headers: siteHeader, timeout: timeout, maxPixelSize: maxPixelSize)
        }
        .onChange(of: siteHeader ?? [:]) { _, newValue in
            loader.load(from: urlString, headers: newValue, timeout: timeout, maxPixelSize: maxPixelSize)
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

private actor PosterDownloadLimiter {
    private let limit: Int
    private var active = 0

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func acquire() async throws {
        while active >= limit {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(20))
        }
        active += 1
    }

    func release() {
        active = max(0, active - 1)
    }
}

actor PosterImagePipeline {
    static let shared = PosterImagePipeline()

    private struct ImageInFlight: Sendable {
        let generation: UInt64
        let task: Task<DecodedPosterImage, Error>
    }

    private struct DataInFlight: Sendable {
        let generation: UInt64
        let task: Task<Data, Error>
    }

    private let session: URLSession
    private let cacheDirectory: URL
    private let fileManager: FileManager
    private let maximumDiskBytes: Int64
    private let ttl: TimeInterval
    private let now: @Sendable () -> Date
    private let limiter: PosterDownloadLimiter
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
        now: @escaping @Sendable () -> Date = Date.init
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
        self.limiter = PosterDownloadLimiter(limit: maximumConcurrentDownloads)
        self.now = now
        try? fileManager.createDirectory(at: self.cacheDirectory, withIntermediateDirectories: true)
    }

    func image(
        request: URLRequest,
        key: String,
        maxPixelSize: CGFloat
    ) async throws -> DecodedPosterImage {
        let sizedKey = "\(key)-\(Int(maxPixelSize.rounded()))"
        if let existing = inFlight[sizedKey], existing.generation == generation {
            return try await existing.task.value
        }

        let requestGeneration = generation
        let dataTask: Task<Data, Error>
        if let existing = dataInFlight[key], existing.generation == requestGeneration {
            dataTask = existing.task
        } else {
            let created = Task { try await data(request: request, key: key, generation: requestGeneration) }
            dataInFlight[key] = DataInFlight(generation: requestGeneration, task: created)
            dataTask = created
        }
        let decodeTask = Task.detached(priority: .utility) {
            let data = try await dataTask.value
            return try Self.decode(data: data, maxPixelSize: maxPixelSize)
        }
        inFlight[sizedKey] = ImageInFlight(generation: requestGeneration, task: decodeTask)
        do {
            let image = try await decodeTask.value
            guard requestGeneration == generation else { throw CancellationError() }
            let data = try await dataTask.value
            try persistIfNeeded(data, key: key, generation: requestGeneration)
            if dataInFlight[key]?.generation == requestGeneration { dataInFlight[key] = nil }
            if inFlight[sizedKey]?.generation == requestGeneration { inFlight[sizedKey] = nil }
            return image
        } catch {
            if dataInFlight[key]?.generation == requestGeneration { dataInFlight[key] = nil }
            if inFlight[sizedKey]?.generation == requestGeneration { inFlight[sizedKey] = nil }
            if error is PosterImageError {
                try? fileManager.removeItem(at: cacheFileURL(for: key))
            }
            throw error
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
        for request in inFlight.values { request.task.cancel() }
        for request in dataInFlight.values { request.task.cancel() }
        inFlight.removeAll()
        dataInFlight.removeAll()
        if fileManager.fileExists(atPath: cacheDirectory.path) {
            try fileManager.removeItem(at: cacheDirectory)
        }
        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        NotificationCenter.default.post(name: .netVplayerCacheDidChange, object: nil)
    }

    private func data(request: URLRequest, key: String, generation requestGeneration: UInt64) async throws -> Data {
        let fileURL = cacheFileURL(for: key)
        if let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
           let modifiedAt = values.contentModificationDate,
           now().timeIntervalSince(modifiedAt) <= ttl,
           let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]),
           !data.isEmpty {
            guard requestGeneration == generation else { throw CancellationError() }
            try? fileManager.setAttributes([.modificationDate: now()], ofItemAtPath: fileURL.path)
            return data
        }
        try? fileManager.removeItem(at: fileURL)

        try await limiter.acquire()
        let responseData: Data
        let response: URLResponse
        do {
            var uncachedRequest = request
            uncachedRequest.cachePolicy = .reloadIgnoringLocalCacheData
            (responseData, response) = try await session.data(for: uncachedRequest)
            await limiter.release()
        } catch {
            await limiter.release()
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

    nonisolated private static func decode(data: Data, maxPixelSize: CGFloat) throws -> DecodedPosterImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw PosterImageError.invalidData(data.count)
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
        guard !ImageLoader.isPlaceholderImage(
            width: CGFloat(image.width),
            height: CGFloat(image.height),
            dataCount: data.count
        ) else {
            throw PosterImageError.placeholderImage(
                width: CGFloat(image.width),
                height: CGFloat(image.height),
                bytes: data.count
            )
        }
        return DecodedPosterImage(cgImage: image, byteCount: data.count)
    }
}

/// 线程安全的图片下载与缓存加载器
@MainActor
final class ImageLoader: ObservableObject {
    @Published var image: NSImage? = nil
    @Published var isLoading: Bool = false

    typealias ImageLoadError = PosterImageError

    private static let imageCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()
    private static var failedAt: [String: Date] = [:]
    private static let failureTTL: TimeInterval = 60
    private static let woggFallbackPosterURL = "https://cos.ffnews.cn/feedback/20251217/6941c9f5c06e2.jpg"

    private var currentTask: Task<Void, Never>? = nil
    private var currentKey: String = ""

    func load(
        from urlString: String,
        headers: [String: String]? = nil,
        timeout: TimeInterval = 15,
        maxPixelSize: CGFloat = 1_200
    ) {
        guard let source = EmbeddedImageSource.parse(urlString) else {
            currentTask?.cancel()
            currentKey = ""
            self.image = nil
            self.isLoading = false
            return
        }

        let url = source.url
        let effectiveHeaders = Self.mergedHeaders(siteHeaders: headers, embeddedHeaders: source.headers)
        let requestKey = Self.cacheKey(url: url, headers: effectiveHeaders)
        let imageKey = "\(requestKey)-\(Int(maxPixelSize.rounded()))"
        if currentKey == imageKey, image != nil || isLoading {
            return
        }
        currentTask?.cancel()
        currentKey = imageKey

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

        let request = Self.makeRequest(
            url: url,
            headers: headers,
            embeddedHeaders: source.headers,
            timeout: timeout
        )
        currentTask = Task { [weak self] in
            do {
                let decoded = try await PosterImagePipeline.shared.image(
                    request: request,
                    key: requestKey,
                    maxPixelSize: maxPixelSize
                )
                let nsImage = NSImage(
                    cgImage: decoded.cgImage,
                    size: NSSize(width: decoded.cgImage.width, height: decoded.cgImage.height)
                )
                Self.imageCache.setObject(nsImage, forKey: imageKey as NSString, cost: decoded.memoryCost)
                guard let self, self.currentKey == imageKey else { return }
                self.image = nsImage
                self.isLoading = false
            } catch is CancellationError {
                guard let self, self.currentKey == imageKey else { return }
                self.isLoading = false
            } catch {
                if let fallbackURL = Self.fallbackURL(for: url, headers: effectiveHeaders, error: error) {
                    let fallbackRequestKey = Self.cacheKey(url: fallbackURL, headers: effectiveHeaders)
                    let fallbackImageKey = "\(fallbackRequestKey)-\(Int(maxPixelSize.rounded()))"
                    if !Self.isRecentlyFailed(fallbackRequestKey) {
                        do {
                            let fallbackRequest = Self.makeRequest(
                                url: fallbackURL,
                                headers: headers,
                                embeddedHeaders: source.headers,
                                timeout: timeout
                            )
                            let decoded = try await PosterImagePipeline.shared.image(
                                request: fallbackRequest,
                                key: fallbackRequestKey,
                                maxPixelSize: maxPixelSize
                            )
                            let fallbackImage = NSImage(
                                cgImage: decoded.cgImage,
                                size: NSSize(width: decoded.cgImage.width, height: decoded.cgImage.height)
                            )
                            Self.imageCache.setObject(fallbackImage, forKey: imageKey as NSString, cost: decoded.memoryCost)
                            Self.imageCache.setObject(fallbackImage, forKey: fallbackImageKey as NSString, cost: decoded.memoryCost)
                            Self.logFallback(from: url, to: fallbackURL, reason: error)
                            guard let self, self.currentKey == imageKey else { return }
                            self.image = fallbackImage
                            self.isLoading = false
                            return
                        } catch {
                            Self.markFailed(fallbackRequestKey)
                            Self.logFailure(error, url: fallbackURL, timeout: timeout)
                        }
                    }
                }
                Self.markFailed(requestKey)
                Self.logFailure(error, url: url, timeout: timeout)
                guard let self, self.currentKey == imageKey else { return }
                self.image = nil
                self.isLoading = false
            }
        }
    }

    static func makeRequest(
        url: URL,
        headers: [String: String]?,
        embeddedHeaders: [String: String] = [:],
        timeout: TimeInterval
    ) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: timeout)

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

    private static func mergedHeaders(
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

    nonisolated private static func cacheKey(url: URL, headers: [String: String]?) -> String {
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
