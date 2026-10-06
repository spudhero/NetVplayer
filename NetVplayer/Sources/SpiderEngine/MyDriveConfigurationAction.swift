import Foundation
import Models

/// Public-shell UI contract for user-owned cloud-drive configuration cards.
public enum MyDriveConfigurationAction: Equatable, Sendable {
    case manageAccounts
    case clearCredential(DriveProvider)

    var encodedValue: String {
        switch self {
        case .manageAccounts:
            return "manage_accounts"
        case .clearCredential(let provider):
            return "clear_credential:\(provider.rawValue)"
        }
    }

    public static func decode(vodID: String) -> MyDriveConfigurationAction? {
        guard let object = decodeObject(vodID), let encodedValue = object["action"] else {
            return nil
        }
        if encodedValue == "manage_accounts" {
            return .manageAccounts
        }
        let prefix = "clear_credential:"
        guard encodedValue.hasPrefix(prefix),
              let provider = DriveProvider(rawValue: String(encodedValue.dropFirst(prefix.count))),
              provider != .unknown else {
            return nil
        }
        return .clearCredential(provider)
    }

    private static func decodeObject(_ vodID: String) -> [String: String]? {
        guard let url = URL(string: vodID),
              url.scheme == "mydrive",
              let encoded = url.pathComponents.last else {
            return nil
        }
        var base64 = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: String]
    }
}
