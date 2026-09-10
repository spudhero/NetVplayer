// NetVplayerApp/Views/WebImage.swift
// 支持自定义 Headers 和自动防盗链校验的网络图片加载器

import SwiftUI
import Cocoa
import Models
import Networking

/// 自定义网络图片视图
public struct WebImage: View {
    let urlString: String
    let siteHeader: [String: String]?
    let showsLoadingIndicator: Bool
    let timeout: TimeInterval
    let fallbackText: String?
    let fallbackSystemImage: String
    let fallbackIconFont: Font

    @StateObject private var loader = ImageLoader()

    public init(
        urlString: String,
        siteHeader: [String: String]? = nil,
        showsLoadingIndicator: Bool = true,
        timeout: TimeInterval = 15,
        fallbackText: String? = nil,
        fallbackSystemImage: String = "film",
        fallbackIconFont: Font = .largeTitle
    ) {
        self.urlString = urlString
        self.siteHeader = siteHeader
        self.showsLoadingIndicator = showsLoadingIndicator
        self.timeout = timeout
        self.fallbackText = fallbackText
        self.fallbackSystemImage = fallbackSystemImage
        self.fallbackIconFont = fallbackIconFont
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
            loader.load(from: urlString, headers: siteHeader, timeout: timeout)
        }
        .onChange(of: urlString) { _, newValue in
            loader.load(from: newValue, headers: siteHeader, timeout: timeout)
        }
        .onChange(of: siteHeader ?? [:]) { _, newValue in
            loader.load(from: urlString, headers: newValue, timeout: timeout)
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

/// 线程安全的图片下载与缓存加载器
@MainActor
final class ImageLoader: ObservableObject {
    @Published var image: NSImage? = nil
    @Published var isLoading: Bool = false

    private static let imageCache = NSCache<NSString, NSImage>()
    private static var failedAt: [String: Date] = [:]
    private static var inFlight: [String: Task<Data, Error>] = [:]
    private static let failureTTL: TimeInterval = 60
    private static let woggFallbackPosterURL = "https://cos.ffnews.cn/feedback/20251217/6941c9f5c06e2.jpg"

    private var currentTask: Task<Void, Never>? = nil
    private var currentKey: String = ""

    func load(from urlString: String, headers: [String: String]? = nil, timeout: TimeInterval = 15) {
        guard let source = EmbeddedImageSource.parse(urlString) else {
            currentTask?.cancel()
            currentKey = ""
            self.image = nil
            self.isLoading = false
            return
        }

        let url = source.url
        let effectiveHeaders = Self.mergedHeaders(siteHeaders: headers, embeddedHeaders: source.headers)
        let cacheKey = Self.cacheKey(url: url, headers: effectiveHeaders)
        if currentKey == cacheKey, image != nil || isLoading {
            return
        }
        currentTask?.cancel()
        currentKey = cacheKey

        if let cached = Self.imageCache.object(forKey: cacheKey as NSString) {
            self.image = cached
            self.isLoading = false
            return
        }

        if Self.isRecentlyFailed(cacheKey) {
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
                let imageData = try await Self.fetchImageData(request: request, key: cacheKey)
                guard let nsImage = NSImage(data: imageData) else {
                    throw ImageLoadError.invalidData(imageData.count)
                }

                Self.imageCache.setObject(nsImage, forKey: cacheKey as NSString)
                await MainActor.run {
                    guard let self, self.currentKey == cacheKey else { return }
                    self.image = nsImage
                    self.isLoading = false
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard let self, self.currentKey == cacheKey else { return }
                    self.isLoading = false
                }
            } catch {
                if let fallbackURL = Self.fallbackURL(for: url, headers: effectiveHeaders, error: error) {
                    let fallbackKey = Self.cacheKey(url: fallbackURL, headers: effectiveHeaders)
                    if !Self.isRecentlyFailed(fallbackKey) {
                        do {
                            let fallbackRequest = Self.makeRequest(
                                url: fallbackURL,
                                headers: headers,
                                embeddedHeaders: source.headers,
                                timeout: timeout
                            )
                            let fallbackData = try await Self.fetchImageData(request: fallbackRequest, key: fallbackKey)
                            guard let fallbackImage = NSImage(data: fallbackData) else {
                                throw ImageLoadError.invalidData(fallbackData.count)
                            }
                            Self.imageCache.setObject(fallbackImage, forKey: cacheKey as NSString)
                            Self.imageCache.setObject(fallbackImage, forKey: fallbackKey as NSString)
                            Self.logFallback(from: url, to: fallbackURL, reason: error)
                            await MainActor.run {
                                guard let self, self.currentKey == cacheKey else { return }
                                self.image = fallbackImage
                                self.isLoading = false
                            }
                            return
                        } catch {
                            Self.markFailed(fallbackKey)
                            Self.logFailure(error, url: fallbackURL, timeout: timeout)
                        }
                    }
                }
                Self.markFailed(cacheKey)
                Self.logFailure(error, url: url, timeout: timeout)
                await MainActor.run {
                    guard let self, self.currentKey == cacheKey else { return }
                    self.image = nil
                    self.isLoading = false
                }
            }
        }
    }

    private static func fetchImageData(request: URLRequest, key: String) async throws -> Data {
        if let existingTask = inFlight[key] {
            return try await existingTask.value
        }

        let task = Task { try await fetchImageData(request: request) }
        inFlight[key] = task
        do {
            let data = try await task.value
            inFlight.removeValue(forKey: key)
            return data
        } catch {
            inFlight.removeValue(forKey: key)
            throw error
        }
    }

    private static func fetchImageData(request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        try Task.checkCancellation()

        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw ImageLoadError.httpStatus(httpResponse.statusCode)
        }

        guard let nsImage = NSImage(data: data) else {
            throw ImageLoadError.invalidData(data.count)
        }
        guard !isPlaceholderImage(nsImage, dataCount: data.count) else {
            throw ImageLoadError.placeholderImage(width: nsImage.size.width, height: nsImage.size.height, bytes: data.count)
        }
        return data
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

    private static func cacheKey(url: URL, headers: [String: String]?) -> String {
        var hasher = Hasher()
        for (key, value) in (headers ?? [:]).sorted(by: { $0.key.lowercased() < $1.key.lowercased() }) {
            let normalizedKey = key.lowercased()
            guard !sensitiveHeaderNames.contains(normalizedKey) else { continue }
            hasher.combine(normalizedKey)
            hasher.combine(value)
        }
        return "\(url.absoluteString)|\(hasher.finalize())"
    }

    private static var sensitiveHeaderNames: Set<String> {
        ["authorization", "cookie", "set-cookie", "x-token", "x-auth-token"]
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

    static func isPlaceholderImage(_ image: NSImage, dataCount: Int) -> Bool {
        let width = max(0, image.size.width)
        let height = max(0, image.size.height)
        guard width > 0, height > 0 else { return true }
        if dataCount <= 256, width <= 16, height <= 16 {
            return true
        }
        if dataCount <= 2_500, width >= 120, height >= 120 {
            return true
        }
        return false
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

    enum ImageLoadError: Error {
        case httpStatus(Int)
        case invalidData(Int)
        case placeholderImage(width: CGFloat, height: CGFloat, bytes: Int)
    }
}
