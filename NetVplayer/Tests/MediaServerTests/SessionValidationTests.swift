import Foundation
import Testing
import Models
import MediaServerEngine

@Suite("Media server session endpoint compatibility")
struct SessionValidationTests {
    @Test(arguments: [MediaServerKind.emby, .jellyfin])
    func validatesUsingSupportedUserEndpoint(_ kind: MediaServerKind) async throws {
        let account = MediaServerConfiguration(kind: kind, server: "https://server.invalid/nested", serverID: "server1", userID: "user1")
        let prefix = kind == .emby ? "/nested/emby" : "/nested"
        let userPath = prefix + (kind == .emby ? "/Users/user1" : "/Users/Me")
        let transport = MediaServerTransport(handler: { request, _ in
            let path = request.url!.path
            let status: Int
            let payload: [String:String]
            if path == prefix + "/System/Info/Public" {
                #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == nil)
                status = 200; payload = ["Id":"server1"]
            } else if path == userPath {
                #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == "fixture-token")
                status = 200; payload = ["Id":"user1"]
            } else {
                status = 500; payload = [:]
            }
            return (try JSONEncoder().encode(payload), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        })
        try await MediaServerClient(account: account, token: "fixture-token", transport: transport).validateSession()
    }
}
