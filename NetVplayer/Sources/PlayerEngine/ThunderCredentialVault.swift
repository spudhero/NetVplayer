import Foundation
import Security

/// The console API Key stays in the user-designated file or macOS Keychain. Only the short-lived SDK
/// token is written to the private runtime directory; neither enters a bundle.
actor ThunderCredentialVault {
    static let shared = ThunderCredentialVault()
    static let service = "com.netvplayer.app.xunlei-open-platform.v1"
    private struct Key: Decodable {
        let appID: String; let apiKey: String
        enum CodingKeys: String, CodingKey { case appID = "app_id", apiKey = "api_key" }
    }
    private struct Response: Decodable {
        let code: Int
        let data: Token
        struct Token: Decodable {
            let token: String; let expiresIn: Double
            enum CodingKeys: String, CodingKey { case token, expiresIn = "expires_in" }
        }
    }
    private var refresh: Task<ThunderDownloadConfiguration?, Never>?
    private var lastFailureAt = Date.distantPast

    nonisolated static func parseLiteralKey(_ text: String) -> [String: String]? {
        let aliases = ["APP_ID": "app_id", "API_KEY": "api_key", "NETVPLAYER_XUNLEI_APP_ID": "app_id", "NETVPLAYER_XUNLEI_API_KEY": "api_key"]
        var values: [String: String] = [:]
        for raw in text.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let target = aliases[parts[0].trimmingCharacters(in: .whitespaces).uppercased()], values[target] == nil else { return nil }
            var value = parts[1].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, ["\"", "'"].contains(first), value.last == first { value = String(value.dropFirst().dropLast()) }
            guard !value.isEmpty, !value.contains(where: { "\r\n\0`$*•●".contains($0) }) else { return nil }
            values[target] = value
        }
        return values.count == 2 ? values : nil
    }

    private nonisolated static func savedKey() -> Key? {
        // Prefer the user's current file so updating it cannot silently keep
        // using an older Keychain key. It also survives ad-hoc signing changes.
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/netvplayer/thunder.env")
        if let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
           ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 64 * 1024,
           let text = try? String(contentsOf: file, encoding: .utf8), let key = parseLiteralKey(text),
           let appID = key["app_id"], let apiKey = key["api_key"] {
            return Key(appID: appID, apiKey: apiKey)
        }
        var request = query(); request[kSecReturnData as String] = true
        var value: CFTypeRef?
        if SecItemCopyMatching(request as CFDictionary, &value) == errSecSuccess,
           let data = value as? Data, let key = try? JSONDecoder().decode(Key.self, from: data) { return key }
        return nil
    }

    private nonisolated static func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "NetVplayer", kSecAttrSynchronizable as String: false,
         kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
    }

    nonisolated static var hasRefreshAuthorization: Bool {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let data = try? Data(contentsOf: root.appendingPathComponent("NetVplayer/ThunderDownload/credentials.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return json["refresh_authorized"] as? Bool == true
    }

    func configuration() async -> ThunderDownloadConfiguration? {
        if let current = ThunderDownloadConfiguration.load() { return current }
        guard Self.hasRefreshAuthorization else { return nil }
        if let refresh { return await refresh.value }
        guard Date().timeIntervalSince(lastFailureAt) >= 60 else { return nil }
        let task = Task<ThunderDownloadConfiguration?, Never> {
            guard let key = Self.savedKey(),
                  !key.appID.isEmpty, !key.apiKey.isEmpty else { return nil }
            do {
                var request = URLRequest(url: URL(string: "https://open.xunlei.com/api/v1/sdk/login_token")!)
                request.httpMethod = "POST"; request.timeoutInterval = 15
                request.setValue(key.apiKey, forHTTPHeaderField: "x-api-key")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let token = try? JSONDecoder().decode(Response.self, from: data), token.code == 0,
                      !token.data.token.isEmpty, token.data.expiresIn.isFinite, token.data.expiresIn > 60,
                      let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
                let directory = root.appendingPathComponent("NetVplayer/ThunderDownload", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let url = directory.appendingPathComponent("credentials.json")
                let output = try JSONSerialization.data(withJSONObject: ["app_id": key.appID, "login_token": token.data.token,
                    "issued_at": Date().timeIntervalSince1970, "expires_in": token.data.expiresIn, "refresh_authorized": true])
                try output.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                return ThunderDownloadConfiguration.load()
            } catch { return nil }
        }
        refresh = task
        let result = await task.value
        refresh = nil
        if result == nil { lastFailureAt = Date() }
        return result
    }
}
