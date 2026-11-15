import Foundation
import Testing
import WebKit
@testable import ParseEngine

/// Actual HTTP/TLS receipts are the oracle. Uncredentialed navigation follows
/// native WebKit; explicit credentials never cross the initial origin.
@Suite(.serialized)
@MainActor
struct WebNavigationHeaderContractTests {
    @Test func sameOriginRedirectStatusesMatchUnmodifiedWebKit() async throws {
        let h = try NavigationHarness(); defer { h.fixture.stop() }
        for code in [301, 302, 303, 307, 308] {
            let target = h.url("/nav/page")
            let url = h.redirect(target, code: code)
            let native = try await h.run(url, label: "same-\(code)", shared: false)
            let shared = try await h.run(url, label: "same-\(code)", shared: true)
            #expect(native.signature == shared.signature)
            #expect(shared.rows.first?.headers["authorization"] == "Bearer navigation-only")
            #expect(shared.rows.first?.headers["cookie"] == NavigationHarness.cookie)
            #expect(shared.navigation.count == 2)
            #expect(shared.navigation.last?.headers["authorization"] == "Bearer navigation-only")
            #expect(shared.navigation.last?.headers["cookie"] == NavigationHarness.cookie)
            #expect(shared.navigation.last?.headers["x-navigation-token"] == "fixture-custom-only")
            let probe = try #require(shared.rows.first { $0.path == "/nav/probe" })
            #expect(probe.headers["cookie"] == "nav=initial")
            #expect(probe.headers["authorization"] == nil && probe.headers["x-navigation-token"] == nil)
        }
    }

    @Test func crossHostAndCrossSiteRedirectsMatchUnmodifiedWebKit() async throws {
        let h = try NavigationHarness(); defer { h.fixture.stop() }
        let headers = NavigationHarness.uncredentialedHeaders
        for secure in [false, true] {
            for host in ["sibling.example.test", "other.test"] {
                let target = h.url("/nav/page", host: host, secure: secure)
                let url = h.redirect(target, secure: secure)
                let native = try await h.run(url, label: "cross-\(host)-\(secure)", headers: headers, shared: false)
                let shared = try await h.run(url, label: "cross-\(host)-\(secure)", headers: headers, shared: true)
                #expect(native.signature == shared.signature)
                let landing = try #require(shared.navigation.last)
                #expect(landing.host == host)
                #expect(landing.headers["authorization"] == nil)
                #expect(landing.headers["cookie"] == nil)
                #expect(landing.headers["x-navigation-token"] == "fixture-custom-only")
            }
        }
    }

    @Test func schemeChangesExposeExplicitCookieSeparateFromSecureStorePolicy() async throws {
        let h = try NavigationHarness(); defer { h.fixture.stop() }
        for secure in [false, true] {
            for host in ["video.example.test", "other.test"] {
                var headers = NavigationHarness.headers
                headers["Cookie"] = "nav=secure; Path=/nav; Secure; HttpOnly"
                let url = h.redirect(h.url("/nav/page", host: host, secure: !secure), secure: secure)
                try await h.expectCredentialBoundary(url, headers: headers)
            }
        }
    }

    @Test func explicitCredentialsNeverReachACrossOriginRedirectTarget() async throws {
        let h = try NavigationHarness(); defer { h.fixture.stop() }
        for field in ["Cookie", "Authorization", "Proxy-Authorization"] {
            var headers = NavigationHarness.uncredentialedHeaders
            headers[field] = field == "Cookie" ? NavigationHarness.cookie : "Bearer fixture-only"
            for host in ["sibling.example.test", "other.test"] {
                try await h.expectCredentialBoundary(h.redirect(h.url("/nav/page", host: host)), headers: headers)
            }
        }
        // The same sniffer remains reusable; a retired credential map cannot
        // affect a later uncredentialed request.
        _ = try await h.run(h.url("/nav/page", host: "other.test"), label: "boundary-reuse", headers: [:], shared: true)
    }

    @Test func rejectedSeedStillSubmitsExplicitInitialCookie() async throws {
        let h = try NavigationHarness(); defer { h.fixture.stop() }
        for value in ["nav=rejected; Domain=other.test; Path=/nav", "nav=rejected; Domain=test; Path=/nav", "__Secure-id=rejected; Path=/nav"] {
            let url = h.url("/nav/page")
            #expect(WebViewSniffer.seedCookies(headers: ["Cookie": value], url: url).isEmpty)
            var headers = NavigationHarness.headers; headers["Cookie"] = value
            let result = try await h.run(url, label: "rejected", headers: headers, shared: true)
            #expect(result.navigation.first?.headers["cookie"] == value)
            #expect(result.rows.first { $0.path == "/nav/probe" }?.headers["cookie"] == nil)
        }
    }

    @Test func redirectCookieRotationAndReturnHopUseBrowserState() async throws {
        let h = try NavigationHarness(); defer { h.fixture.stop() }
        let landing = h.url("/nav/page")
        let foreign = h.redirect(landing, host: "other.test")
        let url = h.redirect(foreign, rotate: true)
        let native = try await h.run(url, label: "return-rotation", headers: NavigationHarness.uncredentialedHeaders, shared: false)
        let shared = try await h.run(url, label: "return-rotation", headers: NavigationHarness.uncredentialedHeaders, shared: true)
        #expect(native.signature == shared.signature)
        #expect(shared.navigation.count == 3)
        #expect(shared.navigation[1].headers["cookie"] == nil)
        #expect(shared.navigation[2].headers["cookie"] == "nav=rotated")
        #expect(shared.navigation[2].headers["authorization"] == nil)
    }

    @Test func pageReloadUsesCurrentCookiesWithoutReapplyingInputMap() async throws {
        let h = try NavigationHarness(); defer { h.fixture.stop() }
        let url = h.url("/nav/page", query: ["mode": "reload", "case": "reload"])
        let native = try await h.run(url, label: "reload", shared: false)
        let shared = try await h.run(url, label: "reload", shared: true)
        #expect(native.signature == shared.signature)
        #expect(shared.navigation.count == 2)
        #expect(shared.navigation.last?.headers["cookie"]?.contains("dynamic=updated") == true)
        #expect(shared.rows.filter { $0.path == "/nav/probe" }.count == 2)
        #expect(shared.navigation.last?.headers["authorization"] == nil)
        #expect(shared.navigation.last?.headers["x-navigation-token"] == nil)
    }

    @Test func scriptReplacementDoesNotInheritNavigationMap() async throws {
        let h = try NavigationHarness(); defer { h.fixture.stop() }
        for host in ["video.example.test", "other.test"] {
            let url = h.url("/nav/page", query: ["mode": "replace", "next": h.url("/nav/page", host: host).absoluteString])
            let native = try await h.run(url, label: "replace-\(host)", headers: NavigationHarness.uncredentialedHeaders, shared: false)
            let shared = try await h.run(url, label: "replace-\(host)", headers: NavigationHarness.uncredentialedHeaders, shared: true)
            #expect(native.signature == shared.signature)
            #expect(shared.navigation.count == 2)
            #expect(shared.navigation.last?.headers["authorization"] == nil)
            #expect(shared.navigation.last?.headers["x-navigation-token"] == nil)
        }
    }

    @Test func completionCancellationAndReplacementRetireNavigationCredentials() async throws {
        let h = try NavigationHarness(); defer { h.fixture.stop() }
        _ = try await h.run(h.url("/nav/page"), label: "complete-seeded", shared: true)
        let empty = try await h.run(h.url("/nav/page"), label: "complete-empty", headers: [:], shared: true)
        #expect(empty.navigation.first?.headers["cookie"] == nil)
        #expect(empty.navigation.first?.headers["authorization"] == nil)
        for cancel in [true, false] {
            let gate = "retire-\(cancel)"
            let target = h.url("/nav/page", query: ["case": "stale-\(gate)"])
            let held = h.redirect(target, hold: gate)
            let old = Task { try await h.sniffer.sniff(url: held.absoluteString, headers: NavigationHarness.headers, timeout: 10) }
            try await h.waitForGate(gate)
            if cancel { old.cancel() }
            let current = Task { try await h.run(h.url("/nav/page"), label: "retired-empty-\(cancel)", headers: [:], shared: true) }
            do { _ = try await old.value; Issue.record("retired navigation completed") }
            catch { #expect(error is CancellationError) }
            try await h.release(gate)
            let result = try await current.value
            #expect(result.navigation.first?.headers["cookie"] == nil)
            #expect(result.navigation.first?.headers["authorization"] == nil)
            #expect(result.navigation.first?.headers["x-navigation-token"] == nil)
            #expect(!(try await h.rows()).contains { $0.path == "/nav/page" && $0.query.contains("stale-") })
        }
    }

    @Test func navigationDiagnosticsSeparateDelegateRequestsFromWireEvidence() async throws {
        let h = try NavigationHarness(); defer { h.fixture.stop() }
        var headers = NavigationHarness.uncredentialedHeaders
        for i in 0..<70 { headers["X-Field-\(i)"] = "synthetic-private-value" }
        let url = h.redirect(h.url("/nav/page", host: "other.test", query: ["private": "synthetic-query-value"]))
        _ = try await h.run(url, label: "diagnostics", headers: headers, shared: true)
        let files = try FileManager.default.contentsOfDirectory(at: h.fixture.root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("web-sniff-") }
        let data = try Data(contentsOf: #require(files.first))
        let text = String(decoding: data, as: UTF8.self)
        for secret in ["synthetic-private-value", "synthetic-query-value", "navigation-only", "video.example.test", "other.test"] { #expect(!text.contains(secret)) }
        let report = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let events = try #require(report["events"] as? [[String: Any]])
        #expect(events.count <= 128)
        let action = try #require(events.first { $0["stage"] as? String == "navigationAction" })
        #expect(action["requestEvidence"] as? String == "WKNavigationAction")
        #expect(action["wireHeadersObserved"] as? Bool == false)
        #expect(action["initialHeadersReapplied"] as? Bool == false)
        let redirect = try #require(events.first { $0["stage"] as? String == "navigationRedirect" })
        #expect(redirect["wireHeadersObserved"] as? Bool == false)
        #expect(events.contains { $0["stage"] as? String == "navigationAction" && $0["originRelation"] as? String == "crossHost" })
        let start = try #require(events.first { $0["stage"] as? String == "start" })
        let fields = try #require(start["initialHeaders"] as? [String: Any])
        #expect(fields["truncated"] as? Bool == true)
        let permissions = try FileManager.default.attributesOfItem(atPath: #require(files.first).path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test func timeoutAndFailureRetireCredentialsBeforeReuse() async throws {
        let h = try NavigationHarness(); defer { h.fixture.stop() }
        let gate = "timeout"
        let held = h.redirect(h.url("/nav/page", query: ["case": "stale-timeout"]), hold: gate)
        let pending = Task { try await h.sniffer.sniff(url: held.absoluteString, headers: NavigationHarness.headers, timeout: 3) }
        try await h.waitForGate(gate)
        do { _ = try await pending.value; Issue.record("held navigation completed") }
        catch { #expect(error is WebViewSnifferError) }
        try await h.release(gate)
        let result = try await h.run(h.url("/nav/page"), label: "timeout-empty", headers: [:], shared: true)
        #expect(result.navigation.first?.headers["cookie"] == nil)
        // The production delegate must still reject the fixture certificate.
        let untrusted = WebViewSniffer(diagnosticDirectory: h.fixture.root, configureStore: h.fixture.configure)
        do { _ = try await untrusted.sniff(url: h.url("/nav/page", secure: true).absoluteString, headers: NavigationHarness.headers, timeout: 5); Issue.record("untrusted TLS accepted") }
        catch { #expect((error as NSError).domain == NSURLErrorDomain) }
        _ = try await untrusted.sniff(url: h.url("/nav/page").absoluteString, timeout: 5)
        let lastPage = try #require(try await h.rows().last { $0.path == "/nav/page" })
        #expect(lastPage.headers["cookie"] == nil && lastPage.headers["authorization"] == nil)
    }
}

private struct NavigationRow: Codable {
    let host: String, path: String, query: String, method: String
    let tls: Bool
    let status: Int
    let headers: [String: String]
}

private struct NavigationObservation {
    let rows: [NavigationRow]
    var navigation: [NavigationRow] { rows.filter { ["/nav/redirect", "/nav/page"].contains($0.path) } }
    var signature: [[String: String]] {
        rows.filter { $0.path.hasPrefix("/nav/") }.map { row in
            var fields = row.headers.filter { ["cookie", "authorization", "x-navigation-token", "user-agent"].contains($0.key) }
            if let cookie = fields["cookie"] { fields["cookie"] = cookie.components(separatedBy: "; ").sorted().joined(separator: "; ") }
            fields["host"] = row.host; fields["path"] = row.path; fields["tls"] = String(row.tls); fields["status"] = String(row.status)
            return fields
        }
    }
}

@MainActor
private final class NavigationBrowser: SeedBrowser {
    weak var target: (any WKNavigationDelegate)?
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        target?.webView?(webView, decidePolicyFor: action, decisionHandler: decisionHandler) ?? decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        target?.webView?(webView, decidePolicyFor: response, decisionHandler: decisionHandler) ?? decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { target?.webView?(webView, didStartProvisionalNavigation: navigation) }
    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) { target?.webView?(webView, didReceiveServerRedirectForProvisionalNavigation: navigation) }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { target?.webView?(webView, didCommit: navigation) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { target?.webView?(webView, didFinish: navigation) }
    override func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        super.webView(webView, didFailProvisionalNavigation: navigation, withError: error)
        target?.webView?(webView, didFailProvisionalNavigation: navigation, withError: error)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        result = String(describing: error); target?.webView?(webView, didFail: navigation, withError: error)
    }
}

@MainActor
private final class NavigationHarness {
    static let cookie = "nav=initial; Path=/nav; HttpOnly"
    static let headers = ["Cookie": cookie, "Authorization": "Bearer navigation-only", "X-Navigation-Token": "fixture-custom-only", "User-Agent": "NetVplayer-Local-Navigation/1"]
    static let uncredentialedHeaders = headers.filter { !["Cookie", "Authorization"].contains($0.key) }
    let fixture: SeedScopeFixture
    private var delegates: [NavigationBrowser] = []
    lazy var sniffer = WebViewSniffer(diagnosticDirectory: fixture.root, configureBrowser: { [weak self] browser in
        guard let self else { return }
        let delegate = NavigationBrowser(certificate: self.fixture.certificate)
        delegate.target = browser.navigationDelegate
        self.delegates.append(delegate)
        browser.navigationDelegate = delegate
    }, configureStore: fixture.configure)

    init() throws { fixture = try SeedScopeFixture(scriptName: "web_navigation_fixture.py", evidenceEnvironment: "NETVPLAYER_NAVIGATION_EVIDENCE_DIR") }
    func url(_ path: String, host: String = "video.example.test", secure: Bool = false, query: [String: String] = [:]) -> URL {
        var c = URLComponents(string: "\(secure ? "https" : "http")://\(host)\(path)")!
        if !query.isEmpty { c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        return c.url!
    }
    func redirect(_ target: URL, host: String = "video.example.test", secure: Bool = false, code: Int = 302, rotate: Bool = false, hold: String? = nil) -> URL {
        var q = ["target": target.absoluteString, "code": String(code), "rotate": rotate ? "1" : "0"]
        if let hold { q["hold"] = hold }
        return url("/nav/redirect", host: host, secure: secure, query: q)
    }
    func rows() async throws -> [NavigationRow] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(fixture.port)/records")!)
        return try JSONDecoder().decode([NavigationRow].self, from: data)
    }
    func waitForGate(_ id: String) async throws {
        for _ in 0..<200 {
            if try await rows().contains(where: { $0.query.contains("hold=" + id) }) { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw URLError(.timedOut)
    }
    func release(_ id: String) async throws {
        _ = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(fixture.port)/control/release?id=\(id)")!)
        for _ in 0..<200 {
            let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(fixture.port)/control/status")!)
            if try JSONDecoder().decode([String].self, from: data).contains(id) { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw URLError(.timedOut)
    }
    func run(_ url: URL, label: String, headers: [String: String] = NavigationHarness.headers, shared: Bool) async throws -> NavigationObservation {
        let start = try await rows().count
        if shared {
            let spec = try await sniffer.sniff(url: url.absoluteString, headers: headers, timeout: 12)
            #expect(spec.headers.keys.allSatisfy { $0.lowercased() == "user-agent" })
        } else {
            let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent(); fixture.configure(config.websiteDataStore)
            let delegate = NavigationBrowser(certificate: fixture.certificate)
            config.userContentController.add(delegate, name: "done")
            let browser = WKWebView(frame: .zero, configuration: config); browser.navigationDelegate = delegate
            defer { browser.stopLoading(); browser.navigationDelegate = nil; config.userContentController.removeScriptMessageHandler(forName: "done") }
            await config.websiteDataStore.httpCookieStore.setCookiePolicy(.allow)
            for cookie in WebViewSniffer.seedCookies(headers: headers, url: url) { await config.websiteDataStore.httpCookieStore.setCookie(cookie) }
            browser.customUserAgent = headers["User-Agent"]
            var request = URLRequest(url: url)
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            browser.load(request)
            for _ in 0..<480 {
                if delegate.result != nil { break }
                _ = try? await browser.evaluateJavaScript("void(0)")
                try await Task.sleep(for: .milliseconds(25))
            }
            #expect(delegate.result == "done", "raw WK completion \(delegate.result ?? "timeout")")
        }
        let observed = NavigationObservation(rows: Array(try await rows().dropFirst(start)))
        let summary: [String: Any] = ["label": label, "shared": shared, "inputURL": url.absoluteString, "inputHeaders": headers, "signature": observed.signature, "start": start, "count": observed.rows.count]
        let data = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]) + Data([10])
        let path = fixture.root.appendingPathComponent("observations.jsonl")
        if !FileManager.default.fileExists(atPath: path.path) { FileManager.default.createFile(atPath: path.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        let file = try FileHandle(forWritingTo: path); try file.seekToEnd(); try file.write(contentsOf: data); try file.close()
        return observed
    }

    func expectCredentialBoundary(_ url: URL, headers: [String: String]) async throws {
        let start = try await rows().count
        await #expect(throws: WebViewSnifferError.credentialedCrossOriginNavigation) {
            try await sniffer.sniff(url: url.absoluteString, headers: headers, timeout: 12)
        }
        let observed = Array(try await rows().dropFirst(start))
        #expect(observed.count == 1)
        #expect(observed.first?.path == "/nav/redirect")
        #expect(observed.first?.host == "video.example.test")
        #expect(observed.first?.headers["cookie"] == headers["Cookie"])
    }
}
