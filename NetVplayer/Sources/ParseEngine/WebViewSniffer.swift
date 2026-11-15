// ParseEngine/WebViewSniffer.swift
// Browser media discovery shared by provider paths. The original player URL and
// headers remain the inputs; no site-specific parser or alternate route is used.

import AppKit
import Foundation
import WebKit
import Models
import Networking
import CryptoKit

@MainActor
protocol WebMediaSniffing: AnyObject, Sendable {
    func sniff(url: String, headers: [String: String], clickScript: String, timeout: TimeInterval, policy: WebMediaPolicy?) async throws -> PlaySpec
    func cancel()
}

enum WebViewSnifferError: LocalizedError, Equatable {
    case noMediaFound
    case credentialedCrossOriginNavigation

    var errorDescription: String? {
        switch self {
        case .noMediaFound: return "网页嗅探未找到媒体地址"
        case .credentialedCrossOriginNavigation: return "已阻止携带登录凭据的网页跨域跳转，请使用不需要跨域传递凭据的播放地址"
        }
    }
}

@MainActor
public final class WebViewSniffer: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WebMediaSniffing, @unchecked Sendable {
    private var webView: WKWebView?
    private var browserWindow: NSWindow?
    private var continuation: CheckedContinuation<PlaySpec, Error>?
    private var timer: Timer?
    private var scanTimer: Timer?
    private var pageURL = ""
    private var requestHeaders: [String: String] = [:]
    private var sessionID: UUID?
    private let diagnosticDirectory: URL?
    private let configureStore: (@MainActor (WKWebsiteDataStore) -> Void)?
    private let configureBrowser: (@MainActor (WKWebView) -> Void)?
    private var diagnosticURL: URL?
    private var diagnosticEvents: [[String: Any]] = []
    private var startedAt: TimeInterval = 0
    private var preparing: Task<Void, Never>?
    private var mediaPolicy: WebMediaPolicy?
    private var clickScript = ""
    private var candidateTask: Task<Void, Never>?
    private var scriptTask: Task<Void, Never>?
    private var documentID = UUID()
    private struct Candidate {
        let message: WKScriptMessage
        let body: [String: Any]
        let document: UUID
        let token: String
    }
    private var documentCommitted = false
    private var candidateTaskID: UUID?
    private var candidates: [Candidate] = []
    private var candidateCount = 0

    public override init() { diagnosticDirectory = nil; configureStore = nil; configureBrowser = nil; super.init() }

    init(diagnosticDirectory: URL, configureBrowser: (@MainActor (WKWebView) -> Void)? = nil, configureStore: (@MainActor (WKWebsiteDataStore) -> Void)? = nil) {
        self.configureBrowser = configureBrowser
        self.configureStore = configureStore
        self.diagnosticDirectory = diagnosticDirectory
        super.init()
    }

    public func sniff(url urlString: String, headers: [String: String] = [:], clickScript: String = "", timeout: TimeInterval = 15, policy: WebMediaPolicy? = nil) async throws -> PlaySpec {
        try Task.checkCancellation()
        guard let url = URL(string: urlString),
              ["http", "https"].contains(url.scheme?.lowercased()), url.host != nil else {
            throw URLError(.badURL)
        }
        cancel()
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                sessionID = id
                pageURL = url.absoluteString
                mediaPolicy = policy
                self.clickScript = clickScript
                requestHeaders = Self.mergingHeaders([:], headers)
                startedAt = ProcessInfo.processInfo.systemUptime
                if let root = diagnosticDirectory {
                    diagnosticURL = root.appendingPathComponent("web-sniff-" + id.uuidString + ".json")
                } else if let root = ProcessInfo.processInfo.environment["NETVPLAYER_ANDROID_DIAGNOSTIC_CAPTURE_ROOT"], !root.isEmpty {
                    diagnosticURL = URL(fileURLWithPath: root).appendingPathComponent("web-sniff-" + id.uuidString + ".json")
                }
                record("start", url: urlString, extra: ["initialHeaders": Self.headerSummary(requestHeaders)])
                let config = WKWebViewConfiguration()
                // A sniff has no persistent account identity. Never share its
                // cookies, local storage or cache with another sniff/login UI.
                config.websiteDataStore = .nonPersistent()
                configureStore?(config.websiteDataStore)
                config.mediaTypesRequiringUserActionForPlayback = []
                let controller = config.userContentController
                controller.add(self, name: "sniffer")
                controller.addUserScript(WKUserScript(source: Self.discoveryScript.replacingOccurrences(of: "__ORIGINAL_POLICY__", with: policy == nil ? "false" : "true"), injectionTime: .atDocumentStart, forMainFrameOnly: false))
                if policy == nil && !clickScript.isEmpty {
                    controller.addUserScript(WKUserScript(source: clickScript, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
                }
                // Detached WKWebViews can suspend native media loading,
                // even if its frame is nonzero and JS polling remains active. Give
                // the original page a real, never-presented AppKit lifecycle; do
                // not change its preload/autoplay attributes or invoke play().
                _ = NSApplication.shared
                let frame = NSRect(x: 0, y: 0, width: 320, height: 240)
                let browser = WKWebView(frame: frame, configuration: config)
                let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = browser
                browserWindow = window
                webView = browser
                browser.navigationDelegate = self
                // Internal fixture hook; production always uses the delegate above.
                configureBrowser?(browser)
                // load(URLRequest) headers alone do not set navigator.userAgent or
                // the UA of frames/scripts. FongMi h50 sets WebSettings' UA too.
                browser.customUserAgent = requestHeaders["User-Agent"]
                var request = URLRequest(url: url)
                for (key, value) in requestHeaders { request.setValue(value, forHTTPHeaderField: key) }
                timer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
                    Task { @MainActor in
                        guard self?.sessionID == id else { return }
                        self?.finish(.failure(WebViewSnifferError.noMediaFound))
                    }
                }
                // A hidden WKWebView can suspend page timers while idle. A
                // bounded native DOM sample keeps asynchronous page discovery
                // active for the same lifetime as the sniff, without reloading.
                scanTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        guard self?.sessionID == id else { return }
                        self?.webView?.evaluateJavaScript("window.dispatchEvent(new Event('netvplayer-sniff-poll'))", completionHandler: nil)
                    }
                }
                let seeds = Self.seedCookies(headers: requestHeaders, url: url)
                let store = config.websiteDataStore.httpCookieStore
                preparing = Task { @MainActor [weak self, weak browser] in
                    await store.setCookiePolicy(.allow)
                    for cookie in seeds {
                        guard self?.sessionID == id, !Task.isCancelled else { return }
                        await store.setCookie(cookie)
                    }
                    guard let self, let browser, self.sessionID == id, !Task.isCancelled else { return }
                    self.record("cookieSeed", extra: [
                        "store": "nonPersistentPerSniff", "seedScope": "originDomainWithPublicSuffixCheck",
                        "seededCount": seeds.count, "cookiePolicy": "allow",
                        "inputCookiePresent": request.value(forHTTPHeaderField: "Cookie") != nil,
                        "thirdPartyCookiePolicy": "webkit-system-policy",
                        "wireHeadersObserved": false
                    ])
                    browser.load(request)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.sessionID == id else { return }
                self?.finish(.failure(CancellationError()))
            }
        }
    }

    public func cancel() { finish(.failure(CancellationError())) }

    private func finish(_ result: Swift.Result<PlaySpec, Error>) {
        switch result {
        case .success(let spec): record("media", url: spec.url)
        case .failure(let error):
            let nsError = error as NSError
            record("failure", extra: ["domain": nsError.domain, "code": nsError.code])
        }
        if let destination = diagnosticURL,
           let data = try? JSONSerialization.data(withJSONObject: ["schema": 7, "events": diagnosticEvents], options: [.sortedKeys]) {
            try? data.write(to: destination, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }
        diagnosticURL = nil
        diagnosticEvents = []
        sessionID = nil
        candidateTask?.cancel()
        candidateTask = nil
        candidateTaskID = nil
        documentCommitted = false
        scriptTask?.cancel()
        scriptTask = nil
        candidates = []
        candidateCount = 0
        mediaPolicy = nil
        clickScript = ""
        preparing?.cancel()
        preparing = nil
        timer?.invalidate()
        timer = nil
        scanTimer?.invalidate()
        scanTimer = nil
        let browser = webView, window = browserWindow
        browser?.configuration.userContentController.removeScriptMessageHandler(forName: "sniffer")
        webView = nil
        browserWindow = nil
        pageURL = ""
        requestHeaders = [:]
        let pending = continuation
        continuation = nil
        if let browser, let window {
            // Keep the old view attached until its empty document commits. A new
            // sniff owns independent state while this bounded retirement drains.
            SnifferBrowserRetirement(browser: browser, window: window) {
                pending?.resume(with: result)
            }.start()
        } else {
            pending?.resume(with: result)
        }
    }

    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let browser = webView, message.webView === browser,
              let body = message.body as? [String: Any] else { return }
        if let kind = body["kind"] as? String, kind != "media" {
            if kind == "discoveryLimit", let reason = body["reason"] as? String,
               ["count", "contextSize"].contains(reason) {
                record("discoveryLimit", extra: ["reason": reason, "mainFrame": message.frameInfo.isMainFrame])
            }
            if ["ready", "scriptError"].contains(kind) {
                record(kind, url: body["url"] as? String, extra: ["mainFrame": message.frameInfo.isMainFrame,
                    "userAgentSHA256": Self.digest(body["userAgent"] as? String ?? "")])
            }
            return
        }
        guard documentCommitted, let id = sessionID,
              let token = body["documentToken"] as? String, UUID(uuidString: token) != nil else { return }
        guard candidateCount < 512 else {
            record("candidateLimit", extra: ["limit": 512]); return
        }
        candidateCount += 1
        candidates.append(Candidate(message: message, body: body, document: documentID, token: token))
        guard candidateTask == nil else { return }
        let worker = UUID()
        candidateTaskID = worker
        candidateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                // A cancelled callback may outlive navigation and its replacement
                // worker. It must never clear the replacement's task/queue state.
                if self.candidateTaskID == worker { self.candidateTask = nil; self.candidateTaskID = nil }
            }
            while self.sessionID == id, !Task.isCancelled, !self.candidates.isEmpty {
                let candidate = self.candidates.removeFirst(), body = candidate.body
                guard let value = body["url"] as? String, let url = URL(string: value),
                      ["http", "https"].contains(url.scheme?.lowercased()), url.host != nil,
                      url.absoluteString != self.pageURL else { continue }
                guard await self.isCurrent(candidate, session: id, phase: "beforeCheck") else { continue }
                do {
                    let accepted = try await self.mediaPolicy?.accepts(value) ?? true
                    guard await self.isCurrent(candidate, session: id, phase: "afterCheck") else { continue }
                    self.record("mediaCheck", url: value, extra: ["accepted": accepted,
                        "policy": self.mediaPolicy == nil ? "legacyDiscovery" : "originalRuleSpider",
                        "spiderBound": self.mediaPolicy?.check != nil])
                    if accepted, await self.acceptCandidate(candidate, session: id) { return }
                } catch {
                    // A late error belongs to the same document/frame as a late
                    // success, even if the provider ignores Task cancellation.
                    guard await self.isCurrent(candidate, session: id, phase: "checkError") else { continue }
                    self.finish(.failure(error))
                    return
                }
            }
        }
    }

    private func retireDocumentCandidates() {
        documentID = UUID()
        documentCommitted = false
        candidateTask?.cancel()
        candidateTask = nil
        candidateTaskID = nil
        candidates = []
        scriptTask?.cancel()
        scriptTask = nil
    }

    private func isCurrent(_ candidate: Candidate, session: UUID, phase: String) async -> Bool {
        func stillOwned() -> Bool {
            sessionID == session && documentCommitted && documentID == candidate.document && !Task.isCancelled
        }
        var current = false
        if stillOwned(), let browser = webView {
            // WKFrameInfo and URLs alone are not document identities: a frame can
            // navigate to the same URL, or its DOM slot/name can be reused. Target
            // the actual frame and compare its discovery closure's document token.
            let value = try? await browser.callAsyncJavaScript(
                "return window.__netvplayerSniffIsCurrentDocument?.(token) === true",
                arguments: ["token": candidate.token], in: candidate.message.frameInfo, contentWorld: .page)
            current = value as? Bool == true && stillOwned() && webView === browser
        }
        if !current, sessionID == session {
            record("staleCandidate", url: candidate.body["url"] as? String,
                   extra: ["phase": phase, "mainFrame": candidate.message.frameInfo.isMainFrame])
        }
        return current
    }

    private func acceptCandidate(_ candidate: Candidate, session id: UUID) async -> Bool {
        let message = candidate.message, body = candidate.body
        guard let browser = webView, sessionID == id,
              let value = body["url"] as? String, let url = URL(string: value) else { return false }
        // WK does not expose HTTP subresource request headers. These are page-
        // supplied fetch/XHR fields, not a claim of observing wire headers.
        let source = body["source"] as? String ?? "unknown"
        let supplied = ["fetch", "xhr"].contains(source)
            ? Self.pageRequestHeaders(body["headers"] as? [String: String] ?? [:]) : [:]
        // load(URLRequest)'s fields belong to the page navigation. WebKit
        // does not inherit them for every subrequest. Only the configured UA
        // is global; forwarding the page map leaks Cookie/auth/custom tokens
        // across credentials modes, hosts and paths. Do not infer wire fields
        // from a cookie-store snapshot or a document URL.
        var headers = Self.mergingHeaders([:], supplied)
        if let ua = body["userAgent"] as? String, !ua.isEmpty { headers["User-Agent"] = ua }
        let method = body["method"] as? String ?? ""
        let credentials = body["credentials"] as? String ?? "unknown"
        var details: [String: Any] = [
            "source": ["fetch", "xhr", "dom", "resource"].contains(source) ? source : "unknown",
            "mainFrame": message.frameInfo.isMainFrame,
            "documentURLSHA256": Self.digest(message.frameInfo.request.url?.absoluteString ?? ""),
            "method": ["GET", "POST", "HEAD", "PUT", "PATCH", "DELETE", "OPTIONS"].contains(method) ? method : "unknown",
            "pageSuppliedHeaders": Self.headerSummary(supplied),
            "playbackHeaders": Self.headerSummary(headers),
            "headerPolicy": "replacePageHeaders",
            "initialHeadersInherited": false,
            "automaticCookieForwarded": false,
            "wireHeadersObserved": false,
            // A fetch/XHR wrapper runs before the browser's CORS gate. DOM and
            // resource entries also omit request headers and redirect/cache state.
            // These observations cannot certify native-player replay eligibility.
            "requestEvidence": ["fetch", "xhr"].contains(source) ? "pageAPIIntent"
                : source == "resource" ? "resourceEntry" : source == "dom" ? "DOMReference" : "unknown",
            "replayEligibility": "unverified",
            "browserResponseObserved": false,
            "redirectChainObserved": false,
            "cacheDispositionObserved": false,
            "credentialsMode": ["omit", "same-origin", "include"].contains(credentials) ? credentials : "unknown"
        ]
        // Reading the store cannot reveal which cookies WebKit actually sent:
        // SameSite, ITP, redirects and request timing still affect eligibility.
        // Keep this diagnostic separate; never manufacture Cookie/Referer/Origin
        // playback headers from this snapshot.
        if diagnosticURL != nil {
            let cookies = await browser.configuration.websiteDataStore.httpCookieStore.allCookies()
            details["cookieStoreSnapshot"] = Self.cookieSummary(cookies)
        }
        guard await isCurrent(candidate, session: id, phase: "beforeCompletion") else { return false }
        record("candidate", url: url.absoluteString, extra: details)
        finish(.success(PlaySpec(url: url.absoluteString, headers: headers, headerPolicy: .replace)))
        return true
    }

    // h50 forwards one complete Set-Cookie value. Native WK insertion has no
    // response origin: validate Domain and security constraints before inserting.
    // Foundation retains host-only vs Domain, default Path, HttpOnly and expiry.
    static func seedCookies(headers: [String: String], url: URL) -> [HTTPCookie] {
        guard let host = url.host?.lowercased(),
              let value = headers.first(where: { $0.key.caseInsensitiveCompare("Cookie") == .orderedSame })?.value,
              !value.unicodeScalars.contains(where: { $0.value < 0x20 && $0.value != 0x09 || $0.value == 0x7f }) else { return [] }
        let parts = value.split(separator: ";", omittingEmptySubsequences: false)
        var attributes: [String: String] = [:]
        for part in parts.dropFirst() {
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
            // Ambiguous native-parser security attributes are not safe to import.
            if ["domain", "path", "secure", "samesite"].contains(name), attributes[name] != nil { return [] }
            attributes[name] = pair.count == 2 ? pair[1].trimmingCharacters(in: .whitespaces) : ""
        }
        let explicitDomain = attributes["domain"]
        if let input = explicitDomain, !input.isEmpty {
            guard let domain = CookieSeedScope.canonicalDomain(input),
                  host == domain || host.hasSuffix("." + domain) else { return [] }
            // IP literals can only match exactly; never match an IP's suffix.
            let isIP = host.contains(":") || host.split(separator: ".").allSatisfy { UInt8($0) != nil }
            if isIP {
                guard host == domain else { return [] }
            } else {
                // A missing/corrupt list fails closed for Domain seeds.
                guard let scope = CookieSeedScope.shared, !scope.isPublicSuffix(domain) else { return [] }
            }
        }
        let secureOrigin = url.scheme?.lowercased() == "https"
        return HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": value], for: url).filter { cookie in
            let expectedDomain = explicitDomain.flatMap { $0.isEmpty ? nil : CookieSeedScope.canonicalDomain($0) } ?? host
            let actualDomain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()).lowercased() : cookie.domain.lowercased()
            guard actualDomain == expectedDomain,
                  explicitDomain != nil || !cookie.domain.hasPrefix("."),
                  !cookie.isSecure || secureOrigin else { return false }
            if cookie.name.hasPrefix("__Secure-") || cookie.name.hasPrefix("__Host-") {
                guard cookie.isSecure && secureOrigin else { return false }
            }
            if cookie.name.hasPrefix("__Host-") {
                guard explicitDomain == nil, attributes["path"] == "/" else { return false }
            }
            return true
        }
    }

    private static func cookieSummary(_ cookies: [HTTPCookie]) -> [String: Any] {
        let fields: [[String: Any]] = cookies.sorted {
            ($0.domain, $0.path, $0.name) < ($1.domain, $1.path, $1.name)
        }.prefix(64).map {
            ["nameSHA256": digest($0.name), "valueSHA256": digest($0.value),
             "domainSHA256": digest($0.domain), "pathSHA256": digest($0.path),
             "secure": $0.isSecure, "httpOnly": $0.isHTTPOnly,
             "sessionOnly": $0.isSessionOnly]
        }
        return ["provenance": "WKHTTPCookieStore", "requestEligibilityEvaluated": false,
                "count": cookies.count, "fields": fields, "truncated": cookies.count > fields.count]
    }

    // A media override must not leave a second, differently cased page value.
    static func mergingHeaders(_ base: [String: String], _ overrides: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for map in [base, overrides] {
            for (key, value) in map.sorted(by: { $0.key < $1.key }) {
                let name = key.lowercased() == "user-agent" ? "User-Agent" : URLHelper.fixHeaderKey(key)
                for existing in Array(result.keys) where existing.caseInsensitiveCompare(name) == .orderedSame {
                    result.removeValue(forKey: existing)
                }
                result[name] = value
            }
        }
        return result
    }

    private static func pageRequestHeaders(_ fields: [String: String]) -> [String: String] {
        // Scripts can supply these names to Headers, but the browser controls or
        // rejects them. Never promote them into playback credentials/options.
        let browserControlled: Set<String> = ["accept-charset", "accept-encoding", "access-control-request-headers",
            "access-control-request-method", "connection", "content-length", "cookie", "cookie2", "date", "dnt",
            "expect", "host", "keep-alive", "origin", "referer", "set-cookie", "te", "trailer",
            "transfer-encoding", "upgrade", "user-agent", "ua", "via"]
        return fields.filter { key, value in
            let name = key.lowercased()
            return !name.isEmpty && !browserControlled.contains(name)
                && !name.hasPrefix("sec-") && !name.hasPrefix("proxy-")
                && !key.contains(where: { $0 == "\r" || $0 == "\n" || $0 == ":" })
                && !value.contains(where: { $0 == "\r" || $0 == "\n" })
        }
    }

    private static func headerSummary(_ headers: [String: String]) -> [String: Any] {
        let fields = headers.sorted(by: { $0.key.lowercased() < $1.key.lowercased() }).prefix(64).map {
            ["nameSHA256": digest($0.key.lowercased()), "valueSHA256": digest($0.value)]
        }
        return ["count": headers.count, "fields": fields, "truncated": headers.count > fields.count]
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func record(_ stage: String, url: String? = nil, extra: [String: Any] = [:]) {
        guard diagnosticURL != nil, diagnosticEvents.count < 128 else { return }
        var event = extra
        event["stage"] = stage
        event["elapsedMS"] = (ProcessInfo.processInfo.systemUptime - startedAt) * 1000
        if let url { event["urlSHA256"] = Self.digest(url) }
        diagnosticEvents.append(event)
    }

    // These callbacks describe navigation lifecycle and delegate-visible input.
    // WKNavigationAction.request is not an HTTP capture: automatic cookies,
    // redirects and browser-controlled fields may differ on the wire. Never use
    // these observations to reapply the initial map or build playback headers.
    public func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        if self.webView === webView {
            // Older WebKit can forward an explicit Cookie header across origins.
            // Cancel before the target request instead of replaying a rewritten
            // navigation or treating delegate headers as proof of wire safety.
            let credentialed = requestHeaders.contains { key, value in
                ["cookie", "authorization", "proxy-authorization"].contains(key.lowercased()) && !value.isEmpty
            }
            if action.targetFrame?.isMainFrame == true, credentialed,
               Self.originRelation(action.request.url, to: URL(string: pageURL)) != "sameOrigin" {
                record("credentialBoundary", extra: ["mainFrame": true, "action": "blocked"])
                decisionHandler(.cancel)
                finish(.failure(WebViewSnifferError.credentialedCrossOriginNavigation))
                return
            }
            let kind: String
            switch action.navigationType {
            case .linkActivated: kind = "link"
            case .formSubmitted: kind = "form"
            case .backForward: kind = "backForward"
            case .reload: kind = "reload"
            case .formResubmitted: kind = "formResubmitted"
            case .other: kind = "other"
            @unknown default: kind = "unknown"
            }
            record("navigationAction", url: action.request.url?.absoluteString, extra: [
                "mainFrame": action.targetFrame?.isMainFrame ?? false,
                "navigationType": kind,
                "originRelation": Self.originRelation(action.request.url, to: URL(string: pageURL)),
                "delegateHeaders": Self.headerSummary(action.request.allHTTPHeaderFields ?? [:]),
                "requestEvidence": "WKNavigationAction", "wireHeadersObserved": false,
                "initialHeadersReapplied": false
            ])
        }
        decisionHandler(.allow)
    }

    private static func originRelation(_ target: URL?, to initial: URL?) -> String {
        guard let target, let initial, let host = target.host?.lowercased(),
              let originalHost = initial.host?.lowercased(),
              let scheme = target.scheme?.lowercased(), let originalScheme = initial.scheme?.lowercased(),
              ["http", "https"].contains(scheme), ["http", "https"].contains(originalScheme) else { return "unknown" }
        guard host == originalHost else { return "crossHost" }
        let port = target.port ?? (scheme == "https" ? 443 : 80)
        let originalPort = initial.port ?? (originalScheme == "https" ? 443 : 80)
        return scheme == originalScheme && port == originalPort ? "sameOrigin" : "sameHost"
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard self.webView === webView else { return }
        retireDocumentCandidates()
        record("navigationStarted", url: webView.url?.absoluteString,
               extra: ["requestEvidence": "WKNavigationDelegate", "wireHeadersObserved": false])
    }

    public func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        guard self.webView === webView else { return }
        record("navigationRedirect", url: webView.url?.absoluteString,
               extra: ["requestEvidence": "WKNavigationDelegate", "wireHeadersObserved": false,
                       "completeRedirectChainObserved": false])
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        if self.webView === webView, let response = navigationResponse.response as? HTTPURLResponse {
            record("navigationResponse", url: response.url?.absoluteString,
                   extra: ["mainFrame": navigationResponse.isForMainFrame, "status": response.statusCode])
        }
        decisionHandler(.allow)
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard self.webView === webView else { return }
        retireDocumentCandidates()
        documentCommitted = true
        record("committed", url: webView.url?.absoluteString)
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard self.webView === webView else { return }
        record("finished", url: webView.url?.absoluteString)
        guard let policy = mediaPolicy, let id = sessionID,
              let url = webView.url?.absoluteString, url != "about:blank" else { return }
        let document = documentID
        let scripts = policy.scripts(for: url, click: clickScript)
        scriptTask?.cancel()
        scriptTask = Task { @MainActor [weak self, weak webView] in
            for (index, script) in scripts.enumerated() {
                guard let self, let webView, self.sessionID == id, self.documentID == document,
                      !Task.isCancelled else { return }
                // FongMi h50.a/f50 waits for each evaluation callback, ignoring
                // its return value. A thrown script does not suppress later ones.
                do { _ = try await webView.evaluateJavaScript(script) }
                catch { /* Keep the original callback chain after script errors. */ }
                guard self.sessionID == id, self.documentID == document, !Task.isCancelled else { return }
                self.record("ruleScript", extra: ["index": index, "scriptSHA256": Self.digest(script)])
            }
        }
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard self.webView === webView else { return }
        finish(.failure(error))
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard self.webView === webView else { return }
        finish(.failure(error))
    }

    // WKWebView has no public Android-style shouldInterceptRequest for HTTP
    // subresources. Observe page APIs and actual DOM/resource entries in every
    // frame; this does not claim full Android network-stack equivalence.
    private static let discoveryScript = #"""
    (() => {
        const sent = new Set(), observedURLs = new Set(), reportedLimits = new Set();
        const candidateLimit = 512, contextLimit = 16384;
        function limit(reason) {
            if (reportedLimits.has(reason)) return;
            reportedLimits.add(reason);
            window.webkit.messageHandlers.sniffer.postMessage({kind: 'discoveryLimit', reason});
        }
        // getRandomValues also works on ordinary HTTP pages; randomUUID is
        // restricted to secure contexts and would disable their discovery script.
        function newDocumentToken() {
            const hex = Array.from(crypto.getRandomValues(new Uint8Array(16)), value => value.toString(16).padStart(2, '0')).join('');
            return [hex.slice(0, 8), hex.slice(8, 12), hex.slice(12, 16), hex.slice(16, 20), hex.slice(20)].join('-');
        }
        let documentToken = newDocumentToken(), active = true;
        const originalDocument = document;
        Object.defineProperty(window, '__netvplayerSniffIsCurrentDocument', {
            value: token => active && document === originalDocument && token === documentToken
        });
        window.addEventListener('pagehide', () => {
            active = false; documentToken = newDocumentToken(); sent.clear(); observedURLs.clear(); reportedLimits.clear();
        });
        window.addEventListener('pageshow', () => { active = true; scan(document.documentElement); });
        const originalPolicy = __ORIGINAL_POLICY__;
        const status = kind => window.webkit.messageHandlers.sniffer.postMessage({kind, url: location.href, userAgent: navigator.userAgent});
        window.addEventListener('error', () => status('scriptError'));
        document.addEventListener('DOMContentLoaded', () => status('ready'));
        const mediaPath = /\.(m3u8|mp4|flv|mpd|m4v|mov|mkv|mp3|m4a|aac|ogg|wav)(?:$|\/)/i;
        function report(value, mediaElement = false, context = {source: 'dom'}) {
            try {
                if (!active || !value) return;
                const url = new URL(String(value), document.baseURI);
                if (!/^https?:$/.test(url.protocol) || (!originalPolicy && !mediaElement && !mediaPath.test(url.pathname))) return;
                // Each API intent owns its captured context. A rejected first
                // request cannot suppress a later request with different fields;
                // neither may a later request overwrite an in-flight candidate.
                // Passive DOM/resource repeats carry no request context and must
                // not replace an API observation with an empty header map.
                const request = context.source === 'fetch' || context.source === 'xhr';
                if (url.href.length > contextLimit) return limit('contextSize');
                if (!request && observedURLs.has(url.href)) return;
                if (sent.size >= candidateLimit || (!observedURLs.has(url.href) && observedURLs.size >= candidateLimit)) return limit('count');
                observedURLs.add(url.href);
                const fields = Object.entries(context.headers || {}).sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0);
                const key = request ? JSON.stringify([url.href, context.source, context.method, context.credentials, fields]) : url.href;
                // Bound retained keys and bridge payloads; keep the page's actual
                // request untouched even when discovery exceeds this budget.
                if (key.length > contextLimit) return limit('contextSize');
                if (sent.has(key)) return;
                sent.add(key);
                window.webkit.messageHandlers.sniffer.postMessage({...context, kind: 'media', documentToken, url: url.href, userAgent: navigator.userAgent});
            } catch (_) {}
        }
        function scan(node) {
            if (!node || node.nodeType !== 1) return;
            function media(el) {
                const attachedMedia = el.matches('video,audio') || (el.matches('source') && el.parentElement && el.parentElement.matches('video,audio'));
                report(el.currentSrc || el.src, attachedMedia);
            }
            if (node.matches('video,audio,source')) media(node);
            node.querySelectorAll('video,audio,source').forEach(media);
        }
        const observer = new MutationObserver(changes => changes.forEach(change => {
            if (change.type === 'attributes') scan(change.target);
            else change.addedNodes.forEach(scan);
        }));
        observer.observe(document, {subtree: true, childList: true, attributes: true, attributeFilter: ['src']});
        document.addEventListener('DOMContentLoaded', () => scan(document.documentElement));
        document.addEventListener('loadstart', event => scan(event.target), true);
        window.addEventListener('netvplayer-sniff-poll', () => scan(document.documentElement));
        // Intercept the correct prototype for each element, including detached
        // sources. Using the media element setter on HTMLSourceElement throws.
        for (const proto of [HTMLMediaElement.prototype, HTMLSourceElement.prototype]) {
            const descriptor = Object.getOwnPropertyDescriptor(proto, 'src');
            if (descriptor && descriptor.set && descriptor.configurable) {
                Object.defineProperty(proto, 'src', {...descriptor, set(value) {
                    descriptor.set.call(this, value);
                    report(this.src, this instanceof HTMLMediaElement || (this.parentElement && this.parentElement.matches('video,audio')));
                }});
            }
        }
        const requests = new WeakMap();
        const open = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function(method, url) {
            const result = open.apply(this, arguments);
            try { requests.set(this, {url, method: String(method).toUpperCase(), headers: new Headers()}); } catch (_) {}
            return result;
        };
        const setHeader = XMLHttpRequest.prototype.setRequestHeader;
        XMLHttpRequest.prototype.setRequestHeader = function(name, value) {
            const result = setHeader.apply(this, arguments);
            try { requests.get(this)?.headers.append(name, value); } catch (_) {}
            return result;
        };
        const send = XMLHttpRequest.prototype.send;
        XMLHttpRequest.prototype.send = function() {
            const result = send.apply(this, arguments);
            try {
                const request = requests.get(this);
                if (request) report(request.url, false, {source: 'xhr', method: request.method,
                    credentials: this.withCredentials ? 'include' : 'same-origin', headers: Object.fromEntries(request.headers)});
            } catch (_) {}
            return result;
        };
        const originalFetch = window.fetch;
        window.fetch = function(input, init) {
            const result = originalFetch.apply(this, arguments);
            try {
                const request = input instanceof Request ? input : null;
                const headers = init && init.headers !== undefined ? init.headers : request?.headers;
                const method = String(init?.method ?? request?.method ?? 'GET').toUpperCase();
                // Let WebKit apply the Request mode's header guard (notably
                // no-cors) without cloning/consuming the original request body.
                const context = new Request(request ? request.url : input, {method, headers,
                    mode: init?.mode ?? request?.mode ?? 'cors'});
                report(context.url, false, {source: 'fetch', method,
                    credentials: init?.credentials ?? request?.credentials ?? 'same-origin', headers: Object.fromEntries(context.headers)});
            } catch (_) {}
            return result;
        };
        if (window.PerformanceObserver) {
            new PerformanceObserver(list => list.getEntries().forEach(entry => report(entry.name, false, {source: 'resource'})))
                .observe({type: 'resource', buffered: true});
        }
    })();
    """#
}


/// Owns only the retired browser; it can never finish or mutate a later sniff.
@MainActor
private final class SnifferBrowserRetirement: NSObject, WKNavigationDelegate {
    private let browser: WKWebView
    private let window: NSWindow
    private var deadline: Timer?
    private var blankNavigation: WKNavigation?
    private var completion: (() -> Void)?

    init(browser: WKWebView, window: NSWindow, completion: @escaping () -> Void) {
        self.browser = browser
        self.window = window
        self.completion = completion
    }

    func start() {
        browser.navigationDelegate = self
        browser.stopLoading()
        // The timer also retains this delegate until completion. A failed WebKit
        // process must not leave a continuation or hidden window alive forever.
        deadline = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [self] _ in
            Task { @MainActor in finish() }
        }
        blankNavigation = browser.load(URLRequest(url: URL(string: "about:blank")!))
        if blankNavigation == nil { finish() }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if navigation === blankNavigation, webView.url?.absoluteString == "about:blank" { finish() }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        // stopLoading may report an older navigation cancellation first.
        if navigation === blankNavigation { finish() }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        // stopLoading may report an older navigation cancellation first.
        if navigation === blankNavigation { finish() }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish() }

    private func finish() {
        guard let completion else { return }
        self.completion = nil
        deadline?.invalidate()
        deadline = nil
        blankNavigation = nil
        browser.navigationDelegate = nil
        browser.stopLoading()
        window.contentView = nil
        window.close()
        completion()
    }
}
