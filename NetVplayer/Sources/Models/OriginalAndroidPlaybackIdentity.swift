import Foundation
import CryptoKit

/// Stable original SDK file identity. Unknown structures are hashed in full.
public enum OriginalAndroidPlaybackIdentity {
    public static func stableCloudSHA256(for id: String) -> String? {
        guard var object = cloudObject(for: id), let marker = object["flag"] as? String else { return nil }
        let transient = marker == "嘟嘟盘" ? ["seKey"]
            : marker == "阿狸盘" ? ["sToken"] : ["sToken", "share_fid_token"]
        for key in transient { object.removeValue(forKey: key) }
        guard let canonical = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
    }

    /// Read provenance without changing the opaque ID sent back to the Provider.
    /// Unknown SDK schemas keep their original, ungrouped presentation.
    public static func episodeSeries(for id: String) -> EpisodeSeries? {
        guard let object = cloudObject(for: id), let marker = object["flag"] as? String else { return nil }
        let share: [String]
        let directory: String
        var name = ""
        switch marker {
        case "阿狸盘", "夸父盘", "优汐盘":
            guard let shareID = text(object, "sId", limit: 1024), !shareID.isEmpty,
                  let parent = text(object, marker == "阿狸盘" ? "parent_file_id" : "pdir_fid", limit: 4096) else { return nil }
            share = [shareID]
            directory = parent
            // Only a supplied directory path can provide a readable name. The
            // collection title and file name cannot establish a version label.
            if let path = text(object, "parent", limit: 4096), path.hasPrefix("/") {
                name = (path as NSString).lastPathComponent
            }
        case "嘟嘟盘":
            guard let owner = text(object, "uk", limit: 1024), !owner.isEmpty,
                  let shareID = text(object, "share_id", limit: 1024), !shareID.isEmpty,
                  let rawPath = text(object, "path", limit: 16 * 1024) else { return nil }
            share = [owner, shareID]
            // The SDK supplies either an absolute path or its percent-encoded
            // form. Decode once, leaving literal percent sequences in raw paths.
            let path = rawPath.hasPrefix("/") ? rawPath : (rawPath.removingPercentEncoding ?? rawPath)
            guard path.isEmpty || path.hasPrefix("/"),
                  path.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
            directory = path.isEmpty ? "" : (path as NSString).deletingLastPathComponent
            name = (directory as NSString).lastPathComponent
        default: return nil
        }
        // Hash length-delimited fields so neither account/share identifiers nor
        // SDK sessions become visible group IDs or playback metadata.
        let boundary = ([marker] + share + [directory]).map { "\($0.utf8.count):\($0)" }.joined()
        let digest = SHA256.hash(data: Data(boundary.utf8)).map { String(format: "%02x", $0) }.joined()
        return EpisodeSeries(id: "android-series:" + digest, name: name == "/" ? "" : name)
    }

    private static func text(_ object: [String: Any], _ key: String, limit: Int) -> String? {
        guard let value = object[key] as? String, value.utf8.count <= limit,
              value.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return value
    }

    private static func cloudObject(for id: String) -> [String: Any]? {
        guard id.utf8.count <= 64 * 1024,
              let object = try? JSONSerialization.jsonObject(with: Data(id.utf8)) as? [String: Any],
              let marker = object["flag"] as? String else { return nil }
        let keys: Set<String>
        switch marker {
        case "阿狸盘":
            keys = ["drive_id", "parent_file_id", "sToken", "size", "file_id", "sub", "sId", "name", "flag", "vodName"]
        case "嘟嘟盘":
            keys = ["pg", "parent", "share_id", "uk", "surl", "fs_id", "shareUser", "path", "seKey", "vodName", "sub", "size", "isdir", "flag", "server_filename"]
        case "夸父盘":
            keys = ["pg", "parent", "l_created_at", "sId", "sToken", "shareUser", "share_fid_token", "fid", "format_type", "vodName", "pdir_fid", "sub", "size", "flag", "file_name"]
        case "优汐盘":
            keys = ["pg", "parent", "sId", "sToken", "shareUser", "share_fid_token", "fid", "vodName", "pdir_fid", "sub", "size", "flag", "file_name"]
        default: return nil
        }
        guard Set(object.keys) == keys else { return nil }
        return object
    }

    public static func episodeSHA256(for id: String) -> String? {
        guard !id.isEmpty, id.utf8.count <= 64 * 1024 else { return nil }
        if let known = stableCloudSHA256(for: id) { return known }
        return SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
