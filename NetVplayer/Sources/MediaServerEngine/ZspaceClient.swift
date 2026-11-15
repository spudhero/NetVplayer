import Foundation
import Models

/// The optional Emby compatibility service in recent 极影视 releases.
/// Older proprietary NAS RPC services are deliberately not treated as Emby.
extension MediaServerClient {
    private func zspaceJSON(_ path: [String], body: Data? = nil, authenticated: Bool = true) async throws -> ServerJSONValue {
        do {
            let (data, _) = try await transport.request(
                request(path, method: body == nil ? "GET" : "POST", body: body, authenticated: authenticated),
                maximumBytes: 4 * 1024 * 1024, origin: baseURL)
            return try JSONDecoder().decode(ServerJSONValue.self, from: data)
        } catch MediaServerError.http(401) { throw MediaServerError.authentication }
        catch MediaServerError.http(403) { throw MediaServerError.authentication }
        catch is DecodingError { throw MediaServerError.response }
    }

    func zspaceAuthenticate(username: String, password: String) async throws -> (MediaServerConfiguration, String) {
        // Some compatibility releases provide only authenticated System/Info.
        let body = try JSONSerialization.data(withJSONObject: ["Username": username, "Pw": password])
        let auth = try await zspaceJSON(["Users", "AuthenticateByName"], body: body, authenticated: false)
        guard let token = auth["AccessToken"].string, !token.isEmpty,
              let userID = auth["User"]["Id"].string, MediaServerReference.validID(userID) else { throw MediaServerError.authentication }
        let signedIn = try MediaServerClient(account: account, token: token, transport: transport)
        let system = try await signedIn.zspaceJSON(["System", "Info"])
        guard let serverID = system["Id"].string, !serverID.isEmpty,
              auth["ServerId"].string == nil || auth["ServerId"].string == serverID else { throw MediaServerError.authentication }
        var saved = account
        saved.serverID = serverID; saved.userID = userID
        saved.username = auth["User"]["Name"].string ?? username
        if (!account.userID.isEmpty && account.userID != userID) || (!account.serverID.isEmpty && account.serverID != serverID) { saved.id = UUID() }
        let client = try MediaServerClient(account: saved, token: token, transport: transport)
        _ = try await client.zspaceSessionUser()
        return (saved, token)
    }

    func zspaceSessionUser() async throws -> ServerUser {
        let system = try await zspaceJSON(["System", "Info"])
        guard system["Id"].string == account.serverID else { throw MediaServerError.authentication }
        // Users/Me is parsed as an invalid media UID on this service.
        let user: ServerJSONValue
        do { user = try await zspaceJSON(["Users", account.userID]) }
        catch MediaServerError.http(404) { throw MediaServerError.authentication }
        guard user["Id"].string == account.userID else { throw MediaServerError.authentication }
        return .init(Id: account.userID, Name: user["Name"].string)
    }
}
