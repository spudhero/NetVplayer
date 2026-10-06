import Foundation
import AppKit
import WebKit

/// Lets ordinary Douban page navigation finish before deciding that user interaction is needed.
@MainActor
final class DoubanPublicPageLoader: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private let requestedURL: URL
    private let cookieStorage: HTTPCookieStorage?
    private var responseStatus = 200
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), any Error>?
    private var timeout: Task<Void, Never>?

    static func load(_ url: URL, cookieStorage: HTTPCookieStorage?) async throws -> (Data, HTTPURLResponse) {
        guard DoubanMetadataProvider.publicPageKey(url) != nil else { throw MetadataProviderError.invalidResponse }
        let loader = DoubanPublicPageLoader(url: url, cookieStorage: cookieStorage)
        return try await loader.start()
    }
    private init(url: URL, cookieStorage: HTTPCookieStorage?) {
        // Command-line acceptance runs also need an AppKit application to service WebKit navigation.
        _ = NSApplication.shared
        requestedURL = url; self.cookieStorage = cookieStorage
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.customUserAgent = DoubanMetadataProvider.userAgent
    }
    private func start() async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(20)) } catch { return }
                    guard let self else { return }
                    // A security landing page can still be loading; only actual verification controls below require user input.
                    self.finish(.failure(MetadataProviderError.unavailable("豆瓣网页载入超时，现有资料已保留，可稍后重试")))
                }
                webView.load(URLRequest(url: requestedURL))
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }
    private func finish(_ result: Result<(Data, HTTPURLResponse), any Error>) {
        guard let continuation else { return }
        self.continuation = nil; timeout?.cancel(); timeout = nil
        webView.stopLoading(); webView.navigationDelegate = nil
        continuation.resume(with: result)
    }
    static func allowed(_ url: URL) -> Bool {
        url.scheme == "https" && url.user == nil && url.password == nil &&
            ["movie.douban.com", "sec.douban.com", "accounts.douban.com", "www.douban.com"].contains(url.host ?? "")
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url.map(Self.allowed) == true ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame, let response = navigationResponse.response as? HTTPURLResponse { responseStatus = response.statusCode }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            do {
                guard let url = webView.url, continuation != nil,
                      let parts = try await webView.evaluateJavaScript("[document.documentElement.outerHTML, document.body ? document.body.innerText : '']") as? [String],
                      parts.count == 2, webView.url == url, continuation != nil else { return }
                if DoubanMetadataProvider.requiresUserVerification(Data(parts[0].utf8)) {
                    finish(.failure(MetadataProviderError.verification(url))); return
                }
                // Security landing pages can redirect themselves. Await their normal navigation rather than showing them as a captcha.
                guard DoubanMetadataProvider.publicPageKey(url) == DoubanMetadataProvider.publicPageKey(requestedURL),
                      let data = DoubanMetadataProvider.publicPageData(html: parts[0], text: parts[1], at: url) else { return }
                let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
                for cookie in cookies where cookie.domain == "douban.com" || cookie.domain.hasSuffix(".douban.com") { cookieStorage?.setCookie(cookie) }
                finish(.success((data, HTTPURLResponse(url: url, statusCode: responseStatus, httpVersion: nil, headerFields: nil)!)))
            } catch { finish(.failure(error)) }
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { finish(.failure(error)) }
}
