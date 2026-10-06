import SwiftUI
import WebKit
import MediaLibraryEngine

struct DoubanVerificationView: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL
    @State private var cookieStore: WKHTTPCookieStore?
    @State private var resuming = false
    var onRecovered: () -> Void = {}
    var body: some View {
        VStack(spacing: 12) {
            HStack { Text("豆瓣网页验证").font(.headline); Spacer(); Button("稍后") { dismiss() } }
            Text("仅当页面要求时完成验证；正常影片页会自动读取并继续匹配。") .font(.caption).foregroundStyle(.secondary)
            DoubanVerificationBrowser(url: url, cookieStore: $cookieStore) { html, text, pageURL, store in
                guard !resuming else { return }
                resuming = true
                Task { @MainActor in
                    guard await DoubanMetadataProvider.shared.acceptPublicPage(html: html, text: text, at: pageURL) else { resuming = false; return }
                    await resumeMatching(cookies: store.allCookies())
                }
            }
            Button("重试匹配") {
                resuming = true
                cookieStore?.getAllCookies { cookies in
                    Task { @MainActor in await resumeMatching(cookies: cookies) }
                }
            }.disabled(cookieStore == nil || resuming).keyboardShortcut(.defaultAction)
        }.padding(20).frame(width: 780, height: 680)
        .themedPresentation()
    }
    private func resumeMatching(cookies: [HTTPCookie]) async {
        await DoubanMetadataProvider.shared.setCookies(cookies)
        await MetadataMatcher.shared.resumeAfterVerification()
        FileServicesState.shared.verificationURL = nil
        dismiss(); onRecovered()
    }
}

private struct DoubanVerificationBrowser: NSViewRepresentable {
    let url: URL
    @Binding var cookieStore: WKHTTPCookieStore?
    let onPublicPage: @MainActor (String, String, URL, WKHTTPCookieStore) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onPublicPage: onPublicPage) }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator; webView.customUserAgent = DoubanMetadataProvider.userAgent
        let url = url
        DispatchQueue.main.async { cookieStore = webView.configuration.websiteDataStore.httpCookieStore }
        if Coordinator.allowed(url) { webView.load(URLRequest(url: url)) }
        return webView
    }
    func updateNSView(_ view: WKWebView, context: Context) { context.coordinator.onPublicPage = onPublicPage }
    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var onPublicPage: @MainActor (String, String, URL, WKHTTPCookieStore) -> Void
        init(onPublicPage: @escaping @MainActor (String, String, URL, WKHTTPCookieStore) -> Void) { self.onPublicPage = onPublicPage }
        static func allowed(_ url: URL) -> Bool {
            url.scheme == "https" && url.user == nil && url.password == nil && ["movie.douban.com", "sec.douban.com", "accounts.douban.com", "www.douban.com"].contains(url.host ?? "")
        }
        @MainActor
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.request.url.map(Self.allowed) == true ? .allow : .cancel)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                guard let url = webView.url, url.host == "movie.douban.com",
                      let parts = try? await webView.evaluateJavaScript("[document.documentElement.outerHTML, document.body ? document.body.innerText : '']") as? [String],
                      parts.count == 2, webView.url == url else { return }
                onPublicPage(parts[0], parts[1], url, webView.configuration.websiteDataStore.httpCookieStore)
            }
        }
    }
}
