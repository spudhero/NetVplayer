import Foundation
import Testing
@testable import FileServiceEngine

struct FileServiceRedirectTests {
    @Test func directoryRedirectRetainsAuthentication() throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let originalURL = try #require(URL(string: "http://127.0.0.1:18781/Movies"))
        var original = URLRequest(url: originalURL)
        original.httpMethod = "PROPFIND"
        original.setValue("Basic dGVzdGVyOnRlc3Q=", forHTTPHeaderField: "Authorization")
        let task = session.dataTask(with: original)
        let response = try #require(HTTPURLResponse(url: originalURL, statusCode: 301, httpVersion: nil, headerFields: nil))
        var next = URLRequest(url: originalURL.appendingPathComponent(""))
        next.httpMethod = "PROPFIND"
        var accepted: URLRequest?
        FileHTTPRedirectDelegate().urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: next) { accepted = $0 }
        #expect(accepted?.value(forHTTPHeaderField: "Authorization") == original.value(forHTTPHeaderField: "Authorization"))
        #expect(accepted?.httpMethod == "PROPFIND")
        #expect(accepted?.url == next.url)
    }

    @Test(arguments: ["http://other.local/Movies/", "http://nas.local:8080/Movies/", "https://nas.local/Movies/"])
    func redirectNeverForwardsCredentialsAcrossOrigins(destination: String) throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let originalURL = try #require(URL(string: "http://nas.local/Movies"))
        var original = URLRequest(url: originalURL)
        original.setValue("Basic dGVzdGVyOnRlc3Q=", forHTTPHeaderField: "Authorization")
        let response = try #require(HTTPURLResponse(url: originalURL, statusCode: 301, httpVersion: nil, headerFields: nil))
        let next = URLRequest(url: try #require(URL(string: destination)))
        var called = false
        var accepted: URLRequest?
        FileHTTPRedirectDelegate().urlSession(session, task: session.dataTask(with: original), willPerformHTTPRedirection: response, newRequest: next) {
            called = true
            accepted = $0
        }
        #expect(called)
        #expect(accepted == nil)
    }
}
