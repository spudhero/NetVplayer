import Foundation

/// Converts a user-facing folder URL to the existing, credential-free SMB configuration.
public struct SMBFolderAddress: Equatable, Sendable {
    public let serverAddress: String
    public let share: String
    public let rootPath: String
    public let port: Int

    public init(_ input: String) throws {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.contains("://") { value = "smb://" + value }
        guard var components = URLComponents(string: value),
              components.scheme?.lowercased() == "smb",
              let host = components.host, !host.isEmpty,
              let authorityStart = value.range(of: "://")?.upperBound else {
            throw FileServiceError.invalidConfiguration(L10n.text("请填写 SMB 文件夹地址，例如 smb://nas.local/家庭共享/电影"))
        }
        guard components.user == nil, components.password == nil else {
            throw FileServiceError.invalidConfiguration(L10n.text("地址中不要包含账号密码，请在下方单独填写。"))
        }
        guard components.query == nil, components.fragment == nil else {
            throw FileServiceError.invalidConfiguration(L10n.text("文件夹名称中的 #、? 和 % 请分别写成 %23、%3F 和 %25。"))
        }
        let port = components.port ?? 445
        guard (1...65535).contains(port) else {
            throw FileServiceError.invalidConfiguration(L10n.text("端口须为 1–65535"))
        }
        // URLComponents can re-escape existing percent sequences when the same URL
        // also contains raw spaces or Unicode. Decode the original path exactly once.
        let pathStart = value[authorityStart...].firstIndex(of: "/")
        let path = pathStart.map { String(value[$0...]) } ?? ""
        let parts = try path.split(separator: "/").map { part in
            guard let decoded = String(part).removingPercentEncoding,
                  !decoded.contains("/"), !decoded.contains("\\"), !decoded.contains("\0"),
                  decoded != "..", decoded != "." else {
                throw FileServiceError.invalidConfiguration(L10n.text("文件夹地址包含无效路径，请检查文件夹名称。"))
            }
            return decoded
        }
        guard let share = parts.first, !share.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw FileServiceError.invalidConfiguration(L10n.text("请在服务器地址后加上共享文件夹，例如 smb://nas.local/家庭共享"))
        }
        components.scheme = "smb"
        components.path = ""
        components.port = port
        guard let url = components.url else {
            throw FileServiceError.invalidConfiguration(L10n.text("请填写 SMB 文件夹地址，例如 smb://nas.local/家庭共享/电影"))
        }
        self.serverAddress = url.absoluteString
        self.share = share
        self.rootPath = try FileServicePath.normalize(parts.dropFirst().joined(separator: "/"))
        self.port = port
    }

    public func applying(to configuration: FileServiceConfiguration) -> FileServiceConfiguration {
        var copy = configuration
        copy.address = serverAddress
        copy.share = share
        copy.rootPath = rootPath
        // Preserve an unchanged legacy port override and its credential binding.
        // A pasted address is authoritative when the destination port changes.
        copy.port = configuration.port == port ? configuration.port : nil
        return copy
    }

    public static func formatted(_ configuration: FileServiceConfiguration) -> String {
        var address = configuration.address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return "" }
        if !address.contains("://") { address = "smb://" + address }
        guard var components = URLComponents(string: address) else { return address }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        components.port = configuration.port ?? components.port
        if components.port == 445 { components.port = nil }
        components.path = ""
        let root = configuration.rootPath == "/" ? "" : configuration.rootPath
        let suffix = root.isEmpty || root.hasPrefix("/") ? root : "/" + root
        let path = configuration.share.isEmpty ? "" : "/" + configuration.share + suffix
        // Keep Chinese and spaces readable, while reserved URL characters round-trip literally.
        let reserved = CharacterSet(charactersIn: "%?#\\").union(.controlCharacters)
        let displayPath = path.unicodeScalars.map { scalar in
            reserved.contains(scalar)
                ? String(scalar).addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
                : String(scalar)
        }.joined()
        return (components.string ?? address) + displayPath
    }
}
