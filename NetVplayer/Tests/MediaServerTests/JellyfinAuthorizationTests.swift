import Foundation
import Models
import Networking
import Testing
@testable import MediaServerEngine

@Suite("Jellyfin current authorization")
struct JellyfinAuthorizationTests {
    @Test func sessionAndLibraryWorkWhenLegacyAuthenticationIsDisabled() async throws {
        let account = MediaServerConfiguration(kind: .jellyfin, server: "https://server.invalid/stable",
            serverID: "server", userID: "user")
        let transport = MediaServerTransport(handler: { request, _ in
            let path = request.url!.path
            let isPublic = path.hasSuffix("/System/Info/Public")
            let authenticated = request.value(forHTTPHeaderField: "Authorization")?
                .contains("Token=\"fixture-token\"") == true
            // Deliberately ignore X-Emby-Token, as a server with legacy auth disabled does.
            let status = isPublic || authenticated ? 200 : 401
            let payload: [String: Any] = isPublic ? ["Id": "server"]
                : path.hasSuffix("/Users/Me") ? ["Id": "user", "Name": "demo"]
                : ["Items": [["Id": "movies", "Name": "Movies"]]]
            if isPublic { #expect(!authenticated) }
            return (try JSONSerialization.data(withJSONObject: payload),
                HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        })
        let client = try MediaServerClient(account: account, token: "fixture-token", transport: transport)
        #expect(try await client.sessionUser().Name == "demo")
        #expect(try await client.views().first?.Name == "Movies")
    }

    @Test(arguments: MediaServerKind.allCases)
    func mediaAuthenticationStaysOnItsOwnOrigin(_ kind: MediaServerKind) throws {
        let client = try MediaServerClient(account: .init(kind: kind, server: "https://server.invalid/base"),
            token: "fixture-token")
        let own = try #require(client.mediaRequest("https://server.invalid/base/video?ApiKey=fixture-token"))
        #expect(own.url?.absoluteString.contains("fixture-token") == false)
        let tokenHeader = kind == .fnos ? "Authorization" : kind == .plex ? "X-Plex-Token" : "X-Emby-Token"
        #expect(own.value(forHTTPHeaderField: tokenHeader) == "fixture-token")
        if kind == .jellyfin {
            #expect(own.value(forHTTPHeaderField: "Authorization")?.contains("Token=\"fixture-token\"") == true)
        }
        let cdn = try #require(client.mediaRequest("https://cdn.invalid/video?signature=public-test"))
        #expect(cdn.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(cdn.value(forHTTPHeaderField: "X-Emby-Token") == nil)
        #expect(cdn.value(forHTTPHeaderField: "X-Plex-Token") == nil)
        var proposed = own; proposed.url = cdn.url
        let redirect = try #require(HTTPRedirectPolicy.redirected(own, proposed: proposed, status: 302, hop: 1))
        #expect(redirect.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(redirect.value(forHTTPHeaderField: "X-Emby-Token") == nil)
        #expect(redirect.value(forHTTPHeaderField: "X-Plex-Token") == nil)
    }

    @Test func quotedTokenValuesCannotAddAuthorizationParameters() throws {
        let client = try MediaServerClient(account: .init(kind: .jellyfin, server: "https://server.invalid"),
            token: "a+\", DeviceId=\"injected")
        let request = client.request(["Users", "Me"])
        let authorization = try #require(request.value(forHTTPHeaderField: "Authorization"))
        #expect(authorization.contains("Token=\"a%2B%22%2C%20DeviceId%3D%22injected\""))
        #expect(!authorization.contains("DeviceId=\"injected"))
        let anonymous = client.request(["System", "Info", "Public"], authenticated: false)
        #expect(anonymous.value(forHTTPHeaderField: "Authorization")?.contains("Token=") == false)
        #expect(anonymous.value(forHTTPHeaderField: "X-Emby-Token") == nil)
    }
}
