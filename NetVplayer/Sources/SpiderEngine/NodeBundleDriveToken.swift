// SpiderEngine/NodeBundleDriveToken.swift
// 将 OKVideoMac Node Provider 返回的 Base64(JSON) 网盘令牌转换为原生网盘引用。

import Foundation
import DriveEngine
import Models

public enum NodeBundleDriveToken {
    private struct Payload: Decodable {
        let providerID: String
        let shareID: String
        let fileID: String
        let name: String
        let playToken: String?

        enum CodingKeys: String, CodingKey {
            case providerID = "providerId"
            case shareID = "shareId"
            case fileID = "fileId"
            case name
            case playToken
        }
    }

    private struct PlayToken: Decodable {
        let fid: String?
        let shareFIDToken: String?
        let fileName: String?

        enum CodingKeys: String, CodingKey {
            case fid
            case shareFIDToken = "shareFidToken"
            case fileName
        }
    }

    /// Returns a `netvplayer-drive://` URL for a supported Node drive token.
    /// Non-Node, malformed, or unsupported values are left untouched by callers.
    public static func canonicalURL(for rawValue: String) -> String? {
        guard let payload = decodePayload(rawValue),
              let provider = provider(for: payload.providerID),
              !payload.shareID.isEmpty,
              !payload.fileID.isEmpty else {
            return nil
        }

        let token = payload.playToken.flatMap { decodePlayToken($0) }
        let fileID = token?.fid?.isEmpty == false ? token!.fid! : payload.fileID
        let fileName = token?.fileName?.isEmpty == false ? token!.fileName! : payload.name
        let shareURL = "\(provider.schemeName)://share/\(payload.shareID)"
        let reference = DriveFileReference(
            provider: provider,
            shareURL: shareURL,
            pwdID: payload.shareID,
            fid: fileID,
            fidToken: token?.shareFIDToken ?? "",
            fileName: fileName
        )
        return reference.encodedURL
    }

    private static func decodePayload(_ rawValue: String) -> Payload? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let normalized = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        guard let data = Data(base64Encoded: normalized + padding, options: [.ignoreUnknownCharacters]) else {
            return nil
        }
        return try? JSONDecoder().decode(Payload.self, from: data)
    }

    private static func decodePlayToken(_ rawValue: String) -> PlayToken? {
        guard let data = rawValue.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PlayToken.self, from: data)
    }

    private static func provider(for rawValue: String) -> DriveProvider? {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "quark": return .quark
        case "uc", "ucdrive": return .uc
        case "ali", "alipan", "aliyundrive": return .ali
        case "p115", "115": return .p115
        case "pikpak": return .pikpak
        case "baidu": return .baidu
        default: return nil
        }
    }
}

private extension DriveProvider {
    var schemeName: String {
        switch self {
        case .quark: return "quark"
        case .uc: return "uc"
        case .ali: return "ali"
        case .p115: return "p115"
        case .pikpak: return "pikpak"
        case .baidu: return "baidu"
        default: return rawValue
        }
    }
}
