#if DEBUG
import Foundation
import Models
import Networking
import Testing
@testable import SpiderEngine

private let sourceTransportTestToken = String(repeating: "0123456789abcdef", count: 4)

private func sourceTransportParameters(_ query: String?) -> [String: String] {
    let value = query.map { "q" + Data($0.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") } ?? "n"
    return [DevelopmentAndroidSourceTransport.markerKey: "1", DevelopmentAndroidSourceTransport.tokenKey: sourceTransportTestToken,
            DevelopmentAndroidSourceTransport.queryKey: value]
}

@Test func developmentAndroidSourceTransportPreservesRawQueryAndWhitelistedHeaders() throws {
    for query: String? in [nil, "", "ac=list&x=%2f%2F&k=a+b&k=a%20b&&empty=&flag&", "wd=%E4%B8%AD%E6%96%87&x=%23%40%2B"] {
        var parameters = sourceTransportParameters(query)
        parameters["user-agent"] = "Original Android Agent"
        parameters["referer"] = "https://catalog.example.test/"
        parameters["origin"] = "https://catalog.example.test"
        parameters["accept"] = "application/json"
        parameters["authorization"] = "fixture-secret"
        parameters["cookie"] = "fixture-cookie"
        parameters["host"] = "127.0.0.1:17978"
        parameters["connection"] = "keep-alive"
        parameters["accept-encoding"] = "gzip"
        let request = try #require(try DevelopmentAndroidSourceTransport.request(parameters: parameters, expectedToken: sourceTransportTestToken))
        #expect(request.url.absoluteString == "https://api.wsyzy.net/api.php/provide/vod/" + (query.map { "?" + $0 } ?? ""))
        #expect(request.headers == ["User-Agent": "Original Android Agent", "Referer": "https://catalog.example.test/",
                                   "Origin": "https://catalog.example.test", "Accept": "application/json"])
    }
    #expect(DevelopmentAndroidSourceTransport.baseURL(port: 17978, token: sourceTransportTestToken)
        == "http://127.0.0.1:17978/proxy?__android_source_transport=1&__android_source_token=" + sourceTransportTestToken)
    #expect(DevelopmentAndroidSourceTransport.baseURL(port: 0, token: sourceTransportTestToken) == nil)
    #expect(DevelopmentAndroidSourceTransport.baseURL(port: 65536, token: sourceTransportTestToken) == nil)
    #expect(DevelopmentAndroidSourceTransport.baseURL(port: 17978, token: "wrong") == nil)
    #expect(try DevelopmentAndroidSourceTransport.request(parameters: ["do": "other"], expectedToken: sourceTransportTestToken) == nil)
}

@Test func developmentAndroidSourceTransportRejectsForgedAndMalformedRequests() throws {
    let valid = sourceTransportParameters("ac=list")
    var invalid: [[String: String]] = []
    for (key, value) in [(DevelopmentAndroidSourceTransport.markerKey, "2"),
                          (DevelopmentAndroidSourceTransport.tokenKey, String(repeating: "a", count: 64)),
                          (DevelopmentAndroidSourceTransport.queryKey, "qA"),
                          (DevelopmentAndroidSourceTransport.queryKey, "qYWJj="),
                          (DevelopmentAndroidSourceTransport.queryKey, "qZg-+"),
                          ("url", "https://evil.example.test/"), ("u64", "encoded"),
                          ("user-agent", "bad\r\nHeader: value"), ("referer", "\0"),
                          ("origin", String(repeating: "x", count: 4097))] {
        var altered = valid; altered[key] = value; invalid.append(altered)
    }
    for key in [DevelopmentAndroidSourceTransport.tokenKey, DevelopmentAndroidSourceTransport.queryKey] {
        var altered = valid; altered.removeValue(forKey: key); invalid.append(altered)
    }
    for query in ["x=#fragment", "x=\r\nHeader: value", "x=%zz", "x=中文", "x=" + String(repeating: "a", count: 16 * 1024)] {
        invalid.append(sourceTransportParameters(query))
    }
    for parameters in invalid {
        #expect(throws: (any Error).self) {
            _ = try DevelopmentAndroidSourceTransport.request(parameters: parameters, expectedToken: sourceTransportTestToken)
        }
    }
    let boundary = try #require(try DevelopmentAndroidSourceTransport.request(
        parameters: sourceTransportParameters(String(repeating: "x", count: 16 * 1024)), expectedToken: sourceTransportTestToken))
    #expect(boundary.url.query?.utf8.count == 16 * 1024)
}

@Test func developmentAndroidSourceTransportReturnsOnlyOriginalResponseBytesStatusAndType() async throws {
    let response = try #require(try await DevelopmentAndroidSourceTransport.responseIfHandled(
        parameters: sourceTransportParameters("ac=list"), expectedToken: sourceTransportTestToken
    ) { request in
        HTTPResponse(data: Data("{\"list\":[]}".utf8), statusCode: 503,
                     headers: ["Content-Type": "application/json; charset=utf-8", "Content-Encoding": "gzip",
                               "Content-Length": "9999", "Set-Cookie": "fixture"], finalURL: request.url)
    })
    #expect(response.statusCode == 503 && response.contentType == "application/json; charset=utf-8")
    #expect(response.data == Data("{\"list\":[]}".utf8))
    #expect(response.headers == ["Cache-Control": "no-store"])
    await #expect(throws: URLError.self) {
        _ = try await DevelopmentAndroidSourceTransport.responseIfHandled(
            parameters: sourceTransportParameters(nil), expectedToken: sourceTransportTestToken
        ) { _ in HTTPResponse(data: Data(), statusCode: 200, finalURL: URL(string: "https://evil.example.test/")) }
    }
    await #expect(throws: URLError.self) {
        _ = try await DevelopmentAndroidSourceTransport.responseIfHandled(
            parameters: sourceTransportParameters(nil), expectedToken: sourceTransportTestToken
        ) { request in HTTPResponse(data: Data(repeating: 0, count: 4 * 1024 * 1024 + 1), statusCode: 200, finalURL: request.url) }
    }
    await #expect(throws: URLError.self) {
        _ = try await DevelopmentAndroidSourceTransport.responseIfHandled(
            parameters: sourceTransportParameters(nil), expectedToken: sourceTransportTestToken
        ) { _ in throw URLError(.secureConnectionFailed) }
    }
    await #expect(throws: CancellationError.self) {
        _ = try await DevelopmentAndroidSourceTransport.responseIfHandled(
            parameters: sourceTransportParameters(nil), expectedToken: sourceTransportTestToken
        ) { _ in throw CancellationError() }
    }
}

private actor SourceTransportRouteCalls {
    private var values: [String] = []
    func add(_ value: String) { values.append(value) }
    func snapshot() -> [String] { values }
}

@Test func developmentAndroidSourceTransportPrioritizesVerifiedIPv6WithoutIPv4Warmup() async throws {
    let calls = SourceTransportRouteCalls()
    let request = try #require(try DevelopmentAndroidSourceTransport.request(
        parameters: sourceTransportParameters("ac=list&x=%2f%2F"), expectedToken: sourceTransportTestToken))
    let response = try await DevelopmentAndroidSourceTransport.loadCatalog(request, budget: .seconds(10), record: { print($0) }, ipv6: { request, timeout, observe in
        await calls.add("ipv6")
        #expect(timeout > 4 && timeout <= 10)
        observe?("dns.complete", 200, nil, nil)
        return HTTPResponse(data: Data("original-native-response".utf8), statusCode: 200, finalURL: request.url)
    }, http1: { _, _ in
        await calls.add("http1")
        Issue.record("A verified successful IPv6 response must not wait for IPv4")
        throw URLError(.cannotConnectToHost)
    })
    #expect(response.data == Data("original-native-response".utf8))
    #expect(await calls.snapshot() == ["ipv6"])
}

@Test func developmentAndroidSourceTransportUsesHTTP1OnlyAfterUnavailableIPv6() async throws {
    let calls = SourceTransportRouteCalls()
    let request = try #require(try DevelopmentAndroidSourceTransport.request(
        parameters: sourceTransportParameters(nil), expectedToken: sourceTransportTestToken))
    let response = try await DevelopmentAndroidSourceTransport.loadCatalog(request, budget: .seconds(1), record: { print($0) }, ipv6: { _, _, _ in
        await calls.add("ipv6")
        return nil
    }, http1: { request, timeout in
        await calls.add("http1")
        #expect(timeout > 0 && timeout <= 1)
        return HTTPResponse(data: Data("fallback".utf8), statusCode: 200, finalURL: request.url)
    })
    #expect(response.text == "fallback")
    #expect(await calls.snapshot() == ["ipv6", "http1"])
}

@Test(arguments: [Duration.zero, .milliseconds(40)])
func developmentAndroidSourceTransportDeadlineLeavesNoWorkOrFallbackRunning(budget: Duration) async throws {
    let calls = SourceTransportRouteCalls()
    let request = try #require(try DevelopmentAndroidSourceTransport.request(
        parameters: sourceTransportParameters(nil), expectedToken: sourceTransportTestToken))
    let start = ContinuousClock.now
    do {
        _ = try await DevelopmentAndroidSourceTransport.loadCatalog(request, budget: budget, record: { print($0) }, ipv6: { _, _, _ in
            await calls.add("ipv6")
            do { try await Task.sleep(for: .seconds(3)) }
            catch { await calls.add("cancelled"); throw error }
            Issue.record("The overall deadline failed to cancel the DNS/address work")
            return nil
        }, http1: { _, _ in
            await calls.add("http1")
            throw URLError(.cannotConnectToHost)
        })
        Issue.record("Deadline must propagate an error")
    } catch let error as URLError {
        #expect(error.code == .timedOut)
    }
    #expect(start.duration(to: .now) < .seconds(1))
    let observed = await calls.snapshot()
    // A deadline can expire before the loader gets an executor slot. If it did
    // start, cancellation must have completed before this function returns.
    #expect(observed.isEmpty || observed == ["ipv6", "cancelled"])
    if budget == .zero { #expect(observed.isEmpty) }
}

@Test func developmentAndroidSourceTransportCallerCancellationJoinsStartedWork() async throws {
    let calls = SourceTransportRouteCalls()
    let request = try #require(try DevelopmentAndroidSourceTransport.request(
        parameters: sourceTransportParameters(nil), expectedToken: sourceTransportTestToken))
    let task = Task {
        try await DevelopmentAndroidSourceTransport.loadCatalog(request, budget: .seconds(10), record: { _ in }, ipv6: { _, _, _ in
            await calls.add("ipv6")
            do { try await Task.sleep(for: .seconds(30)) }
            catch { await calls.add("cancelled"); throw error }
            Issue.record("Caller cancellation left the route running")
            return nil
        }, http1: { _, _ in
            await calls.add("http1")
            throw URLError(.cannotConnectToHost)
        })
    }
    defer { task.cancel() }
    let startDeadline = ContinuousClock.now.advanced(by: .seconds(5))
    while await calls.snapshot().isEmpty, ContinuousClock.now < startDeadline { await Task.yield() }
    try #require(await calls.snapshot() == ["ipv6"])
    task.cancel()
    await #expect(throws: CancellationError.self) { _ = try await task.value }
    #expect(await calls.snapshot() == ["ipv6", "cancelled"])
}

@Test func developmentAndroidSourceTransportCancellationAndTrustErrorsCannotBecomeSuccess() async throws {
    let request = try #require(try DevelopmentAndroidSourceTransport.request(
        parameters: sourceTransportParameters(nil), expectedToken: sourceTransportTestToken))
    await #expect(throws: CancellationError.self) {
        _ = try await DevelopmentAndroidSourceTransport.loadCatalog(request, budget: .seconds(1), record: { print($0) }, ipv6: { _, _, _ in
            throw CancellationError()
        }, http1: { _, _ in
            Issue.record("Cancellation must stop further routes")
            throw URLError(.unknown)
        })
    }
    do {
        _ = try await DevelopmentAndroidSourceTransport.loadCatalog(request, budget: .seconds(1), record: { print($0) }, ipv6: { _, _, _ in nil }, http1: { _, _ in
            throw URLError(.serverCertificateUntrusted)
        })
        Issue.record("Certificate failures must remain failures")
    } catch let error as URLError {
        #expect(error.code == .serverCertificateUntrusted)
    }
}
#endif
