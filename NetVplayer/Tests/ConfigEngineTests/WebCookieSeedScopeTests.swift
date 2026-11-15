import Foundation
import Testing
import WebKit
import Network
import Security
@testable import ParseEngine

@Suite(.serialized)
@MainActor
struct WebCookieSeedScopeTests {
    @Test func legalParentDomainMatchesBrowserResponseOnSiblingAndChild() async throws {
        for domain in ["example.test", ".example.test", ".ExAmPlE.TeSt"] {
            let fixture = try SeedScopeFixture()
            defer { fixture.stop() }
            let seed = "seed=parent; Domain=\(domain); Path=/scope; HttpOnly"
            let seeded = try await fixture.browse(seed: seed)
            let response = try await fixture.browse(seed: seed, response: true)
            #expect(seeded == response)
            #expect(seeded.original == "seed=parent" && seeded.child == "seed=parent" && seeded.sibling == "seed=parent")
            #expect(seeded.outside.isEmpty && seeded.pathBoundary.isEmpty && seeded.crossSite.isEmpty && seeded.suffixTrap.isEmpty)
            #expect(seeded.script.isEmpty)
        }
    }

    @Test func hostOnlyAndExplicitExactDomainHaveDifferentChildScope() async throws {
        let fixture = try SeedScopeFixture(); defer { fixture.stop() }
        for (attribute, child) in [("", ""), ("; Domain=video.example.test", "seed=scoped")] {
            let seed = "seed=scoped; Path=/scope" + attribute
            let seeded = try await fixture.browse(seed: seed)
            let response = try await fixture.browse(seed: seed, response: true)
            #expect(seeded == response)
            #expect(seeded.original == "seed=scoped" && seeded.child == child && seeded.sibling.isEmpty)
        }
    }

    @Test func defaultPathAndSingleSetCookieValueMatchResponse() async throws {
        let fixture = try SeedScopeFixture(); defer { fixture.stop() }
        let seed = "seed=a=b; second=not-another-cookie"
        let seeded = try await fixture.browse(seed: seed)
        #expect(seeded == (try await fixture.browse(seed: seed, response: true)))
        #expect(seeded.original == "seed=a=b" && seeded.deep == "seed=a=b")
        #expect(seeded.outside.isEmpty && seeded.pathBoundary.isEmpty && seeded.child.isEmpty)
        #expect(seeded.script == "seed=a=b")
    }

    @Test func unrelatedAndPublicSuffixDomainsCannotSendCookies() async throws {
        let fixture = try SeedScopeFixture(); defer { fixture.stop() }
        for (host, domain) in [("video.example.test","other.test"),("video.example.test","test"),
                              ("video.example.test","ample.test"),("video.example.co.uk","co.uk"),
                              ("video.tenant.github.io","github.io"),("video.b.ck","b.ck")] {
            let seed = "seed=forbidden; Domain=\(domain); Path=/scope"
            let result = try await fixture.browse(seed: seed, host: host)
            #expect(result.original.isEmpty && result.child.isEmpty && result.sibling.isEmpty && result.crossSite.isEmpty)
        }
    }

    @Test func publicSuffixExceptionAllowsRegistrableParent() async throws {
        let fixture = try SeedScopeFixture(); defer { fixture.stop() }
        let seed = "seed=exception; Domain=www.ck; Path=/scope"
        let result = try await fixture.browse(seed: seed, host: "video.www.ck")
        #expect(result == (try await fixture.browse(seed: seed, host: "video.www.ck", response: true)))
        #expect(result.original == "seed=exception")
    }

    @Test func secureAndHttpOnlySeedUsesTLSAndNeverDowngradeOrScript() async throws {
        let fixture = try SeedScopeFixture(); defer { fixture.stop() }
        let seed = "seed=secure; Domain=example.test; Path=/scope; Secure; HttpOnly; SameSite=Lax"
        let result = try await fixture.browse(seed: seed, secure: true, downgrade: true)
        #expect(result == (try await fixture.browse(seed: seed, secure: true, downgrade: true, response: true)))
        #expect(result.original == "seed=secure" && result.child == "seed=secure" && result.sibling == "seed=secure")
        #expect(result.plain.isEmpty && result.script.isEmpty)
        #expect((try await fixture.browse(seed: seed)).original.isEmpty)
    }

    @Test func expiredSeedsAndMaxAgePrecedenceMatchBrowser() async throws {
        let fixture = try SeedScopeFixture(); defer { fixture.stop() }
        for suffix in ["Max-Age=0", "Max-Age=-1", "Expires=Thu, 01 Jan 1970 00:00:00 GMT",
                       "Max-Age=0; Expires=Wed, 01 Jan 2042 00:00:00 GMT"] {
            let seed = "seed=expired; Path=/scope; " + suffix
            #expect((try await fixture.browse(seed: seed)).original.isEmpty)
        }
        let future = "seed=alive; Path=/scope; Max-Age=600; Expires=Thu, 01 Jan 1970 00:00:00 GMT"
        #expect((try await fixture.browse(seed: future)).original == "seed=alive")
    }

    @Test func securityPrefixesCannotBypassOriginOrHostOnlyConstraints() async throws {
        let fixture = try SeedScopeFixture(); defer { fixture.stop() }
        for seed in ["__Secure-id=x; Path=/", "__Host-id=x; Secure; Path=/scope", "__Host-id=x; Secure; Path=/; Domain=video.example.test"] {
            let native = try await fixture.browse(seed: seed, secure: true)
            let response = try await fixture.browse(seed: seed, secure: true, response: true)
            #expect(native == response)
            #expect(native.original.isEmpty)
        }
        let valid = try await fixture.browse(seed: "__Host-id=x; Secure; Path=/; HttpOnly", secure: true)
        #expect(valid.original == "__Host-id=x" && valid.child.isEmpty && valid.script.isEmpty)
    }

    @Test func sameSiteSeedMatchesResponseAcrossCrossSiteTopLevelNavigation() async throws {
        let fixture = try SeedScopeFixture(); defer { fixture.stop() }
        for (policy, expected) in [("Strict", ""), ("Lax", "seed=same-site"), ("None", "seed=same-site")] {
            let seed = "seed=same-site; Path=/scope; Secure; SameSite=" + policy
            let result = try await fixture.browse(seed: seed, secure: true, crossSite: true)
            #expect(result == (try await fixture.browse(seed: seed, secure: true, response: true, crossSite: true)))
            #expect(result.landing == expected)
        }
        // Current WK's response path accepts this HTTP cookie. Match observed
        // behavior; this is not evidence of Android/Chromium's None policy.
        let insecure = "seed=wk-none; Path=/scope; SameSite=None"
        let native = try await fixture.browse(seed: insecure)
        #expect(native == (try await fixture.browse(seed: insecure, response: true)))
        #expect(native.original == "seed=wk-none")
    }

    @Test func malformedOrAmbiguousDomainsAndPrefixesFailClosed() throws {
        let url = try #require(URL(string: "https://video.example.test/scope/start"))
        for seed in ["seed=x; Domain=example.test; Domain=other.test", "seed=x; Domain=other.test; Domain=example.test",
                     "seed=x; Domain=..example.test", "seed=x; Domain=example.test.", "seed=x; Domain=example.test/",
                     "seed=x; Domain=example.test:443", "seed=x; Domain=example.test@other.test", "seed=x; Domain=exa mple.test",
                     "seed=x\r\nInjected: y", "__Host-id=x; Secure; Path=/scope; Path=/"] {
            #expect(WebViewSniffer.seedCookies(headers: ["Cookie": seed], url: url).isEmpty)
        }
        let scope = try #require(CookieSeedScope.shared)
        for domain in ["com", "co.uk", "github.io", "b.ck", "test"] { #expect(scope.isPublicSuffix(domain)) }
        for domain in ["example.com", "tenant.github.io", "www.ck", "example.test"] { #expect(!scope.isPublicSuffix(domain)) }
    }

    @Test func parentSeedsUseSharedSnifferAndExpireOnCompletionCancellationReplacement() async throws {
        let fixture = try SeedScopeFixture(); defer { fixture.stop() }
        let sniffer = WebViewSniffer(diagnosticDirectory: fixture.root, configureStore: { fixture.configure($0) })
        _ = try await sniffer.sniff(url: "http://video.example.test/scope/start", headers: ["Cookie":"seed=parent; Domain=example.test; Path=/scope"], timeout: 10)
        #expect((try await fixture.rows()).first { $0.host == "sibling.example.test" }?.cookie == "seed=parent")
        for cancel in [true,false] {
            let count = try await fixture.rows().filter { $0.path == "/scope/held" }.count
            let old = Task { try await sniffer.sniff(url: "http://video.example.test/scope/hold", headers: ["Cookie":"seed=stale; Domain=example.test; Path=/scope"], timeout: 10) }
            try await fixture.waitForHeld(count: count + 1)
            if cancel { old.cancel() }
            let new = Task { try await sniffer.sniff(url: "http://video.example.test/scope/start", timeout: 10) }
            do { _ = try await old.value; Issue.record("retired session completed") } catch { #expect(error is CancellationError) }
            _ = try await new.value
        }
        _ = try await sniffer.sniff(url: "http://video.example.test/scope/start", timeout: 10)
        #expect((try await fixture.rows()).filter { $0.host == "sibling.example.test" }.map(\.cookie) == ["seed=parent","","",""])
    }
}

fileprivate struct SeedObservation: Equatable {
    let original: String, deep: String, child: String, sibling: String, outside: String, pathBoundary: String, crossSite: String, suffixTrap: String, script: String, plain: String, landing: String?
}
fileprivate struct SeedRow: Decodable {
    let host: String, path: String, query: String, cookie: String
    let tls: Bool
}

/// This delegate exists only in the test target. TLS trust is restricted to the
/// generated fixture leaf; no trust changes or certificate bypass in the app.
@MainActor
class SeedBrowser: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let certificate: Data
    var result: String?
    init(certificate: Data) { self.certificate = certificate }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        result = message.body as? String
    }
    func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        evaluate(challenge)
    }
    private func evaluate(_ challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first,
              SecCertificateCopyData(leaf) as Data == certificate else { return (.cancelAuthenticationChallenge, nil) }
        SecTrustSetAnchorCertificates(trust, [leaf] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        guard SecTrustEvaluateWithError(trust, nil) else { return (.cancelAuthenticationChallenge, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { result = String(describing: error) }
}

@MainActor
final class SeedScopeFixture {
    let root: URL
    let process: Process
    let port: Int
    let certificate: Data
    init(scriptName: String = "web_cookie_seed_fixture.py", evidenceEnvironment: String = "NETVPLAYER_COOKIE_SEED_EVIDENCE_DIR") throws {
        let parent = ProcessInfo.processInfo.environment[evidenceEnvironment].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        root = parent.appendingPathComponent("seed-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try "[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=video.example.test\n[ext]\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:*.example.test,DNS:*.video.example.test,DNS:other.test,DNS:example.test.evil.test,DNS:video.tenant.github.io,DNS:video.example.co.uk,DNS:video.b.ck,DNS:video.www.ck\n".write(to: root.appendingPathComponent("openssl.cnf"),atomically:true,encoding:.utf8)
        func run(_ args: [String]) throws {
            let task=Process();task.executableURL=URL(fileURLWithPath:"/usr/bin/openssl");task.arguments=args;task.standardOutput=FileHandle.nullDevice;task.standardError=FileHandle.nullDevice;try task.run();task.waitUntilExit();guard task.terminationStatus==0 else {throw URLError(.cannotCreateFile)}
        }
        try run(["req","-x509","-sha256","-newkey","rsa:2048","-nodes","-days","2","-config",root.appendingPathComponent("openssl.cnf").path,"-keyout",root.appendingPathComponent("key.pem").path,"-out",root.appendingPathComponent("cert.pem").path])
        try run(["x509","-in",root.appendingPathComponent("cert.pem").path,"-outform","DER","-out",root.appendingPathComponent("cert.der").path])
        certificate=try Data(contentsOf:root.appendingPathComponent("cert.der"))
        let script=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("script/fixtures/web-transport/" + scriptName)
        let task=Process(),pipe=Pipe();task.executableURL=URL(fileURLWithPath:"/usr/bin/python3");task.arguments=["-B","-u",script.path,"--root",root.path];task.standardOutput=pipe
        let log=root.appendingPathComponent("server.log");FileManager.default.createFile(atPath:log.path,contents:nil);task.standardError=try FileHandle(forWritingTo:log)
        try task.run();process=task
        guard let text=String(data:pipe.fileHandleForReading.availableData,encoding:.utf8), let port=Int(text.trimmingCharacters(in:.whitespacesAndNewlines)) else {task.terminate();throw URLError(.cannotConnectToHost)}
        self.port=port
    }
    func configure(_ store: WKWebsiteDataStore) {
        var proxy = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!))
        proxy.allowFailover = false
        store.proxyConfigurations = [proxy]
    }
    func stop() { if process.isRunning { process.terminate();process.waitUntilExit() } }
    fileprivate func rows() async throws -> [SeedRow] {
        let (data,_)=try await URLSession.shared.data(from:URL(string:"http://127.0.0.1:\(port)/records")!)
        return try JSONDecoder().decode([SeedRow].self,from:data)
    }
    func waitForHeld(count: Int) async throws {
        for _ in 0..<200 {
            if try await rows().filter({$0.path == "/scope/held"}).count >= count {return}
            try await Task.sleep(for:.milliseconds(25))
        }
        throw URLError(.timedOut)
    }
    fileprivate func browse(seed: String, host: String="video.example.test", secure: Bool=false, downgrade: Bool=false, response: Bool=false, crossSite: Bool=false) async throws -> SeedObservation {
        let offset=try await rows().count
        let config=WKWebViewConfiguration();config.websiteDataStore = .nonPersistent();configure(config.websiteDataStore)
        let delegate=SeedBrowser(certificate:certificate);config.userContentController.add(delegate,name:"done")
        let browser=WKWebView(frame:.zero,configuration:config);browser.navigationDelegate=delegate
        defer {browser.stopLoading();browser.navigationDelegate=nil;config.userContentController.removeScriptMessageHandler(forName:"done")}
        let base="\(secure ? "https" : "http")://\(host)/scope/\(response ? "response" : "start")"
        var components=URLComponents(string:base)!;components.queryItems=[URLQueryItem(name:"seed",value:seed),URLQueryItem(name:"downgrade",value:downgrade ? "1":"0"),URLQueryItem(name:"cross",value:crossSite ? "1":"0")]
        let url=components.url!
        await config.websiteDataStore.httpCookieStore.setCookiePolicy(.allow)
        if !response { for cookie in WebViewSniffer.seedCookies(headers:["Cookie":seed],url:url) { await config.websiteDataStore.httpCookieStore.setCookie(cookie) } }
        browser.load(URLRequest(url:url))
        for _ in 0..<400 {
            if delegate.result != nil {break}
            // Keep the detached WK view active without using cookies/JS as wire evidence.
            _ = try? await browser.evaluateJavaScript("void(0)")
            try await Task.sleep(for:.milliseconds(25))
        }
        #expect(delegate.result == "done", "browser completion: \(delegate.result ?? "timeout")")
        let rows=Array(try await self.rows().dropFirst(offset))
        func cookie(_ target: String, _ path: String) throws -> String { try #require(rows.first{$0.host==target && $0.path==path}).cookie }
        let script=try #require(rows.first{$0.path=="/scope/js"}).query
        let js=URLComponents(string:"http://fixture/?"+script)?.queryItems?.first?.value ?? ""
        return try SeedObservation(original:cookie(host,"/scope/probe"),deep:cookie(host,"/scope/deep/probe"),child:cookie("child.video.example.test","/scope/probe"),sibling:cookie("sibling.example.test","/scope/probe"),outside:cookie(host,"/outside/probe"),pathBoundary:cookie(host,"/scopeevil/probe"),crossSite:cookie("other.test","/scope/probe"),suffixTrap:cookie("example.test.evil.test","/scope/probe"),script:js,plain:rows.first{$0.path=="/scope/plain"}?.cookie ?? "",landing:rows.first{$0.path=="/scope/landing"}?.cookie)
    }
}
