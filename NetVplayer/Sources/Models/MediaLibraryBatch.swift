import Foundation

/// A batch adds libraries to one existing connection without changing its identity or credentials.
public enum MediaLibraryBatch {
    public static func overlaps(_ first: String, _ second: String) -> Bool {
        guard let first = try? FileServicePath.normalize(first),
              let second = try? FileServicePath.normalize(second) else { return false }
        return first == second || first == "/" || second == "/"
            || first.hasPrefix(second + "/") || second.hasPrefix(first + "/")
    }

    public static func validated(_ drafts: [MediaLibraryConfiguration], serviceID: UUID,
                                 existing: [MediaLibraryConfiguration]) throws -> [MediaLibraryConfiguration] {
        guard !drafts.isEmpty else {
            throw FileServiceError.invalidConfiguration(L10n.text("请至少选择一个文件夹"))
        }
        var result: [MediaLibraryConfiguration] = []
        var identifiers = Set(existing.map(\.id))
        let existingPaths = existing.filter { $0.serviceID == serviceID }.map(\.path)
        for var draft in drafts {
            guard draft.serviceID == serviceID, identifiers.insert(draft.id).inserted else {
                throw FileServiceError.invalidConfiguration(L10n.text("文件夹所属连接已改变，请重新选择"))
            }
            draft.path = try FileServicePath.normalize(draft.path)
            draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !draft.name.isEmpty else {
                throw FileServiceError.invalidConfiguration(L10n.text("请填写媒体库名称"))
            }
            guard !(existingPaths + result.map(\.path)).contains(where: { overlaps($0, draft.path) }) else {
                throw FileServiceError.invalidConfiguration(L10n.text("文件夹已添加或与已有目录重叠：{0}", [draft.path]))
            }
            result.append(draft)
        }
        return result
    }
}
