#if DEBUG
import Models
import Testing
@testable import NetVplayerApp

@MainActor
@Test func developmentAndroidFolderAuditPreservesOpaqueJSONThroughTwoLevels() async {
    let root = Vod(vodId: "opaque-search-folder", isFolder: true)
    let jsonID = " {\"files\":[\"a+b/%20\",\"\\u4e2d\"],\"padding\":\"" + String(repeating: "x", count: 8_000) + "\"} "
    let child = Vod(vodId: jsonID, isFolder: true)
    let leaf = Vod(vodId: "{\"file_id\":\"original-leaf\"}")
    var requests = [String]()
    let result = await DevelopmentAndroidFolderAudit.resolve(root, isFolder: \.isFolder) { folder in
        requests.append(folder.vodId)
        return .init(items: folder.vodId == root.vodId ? [child] : [leaf])
    }
    #expect(requests == [root.vodId, jsonID])
    #expect(result.leaf?.vodId == leaf.vodId)
    #expect(result.leafDepth == 2)
    #expect(result.visits.map(\.depth) == [1, 2])
    #expect(result.failure == nil)
}

@MainActor
@Test func developmentAndroidFolderAuditPrefersLeafAndDoesNotOpenItAsCategory() async {
    let root = Vod(vodId: "root", isFolder: true)
    var requests = [String]()
    let result = await DevelopmentAndroidFolderAudit.resolve(root, isFolder: \.isFolder) { folder in
        requests.append(folder.vodId)
        return .init(items: [Vod(vodId: "unneeded-folder", isFolder: true), Vod(vodId: "real-content")])
    }
    #expect(requests == ["root"])
    #expect(result.leaf?.vodId == "real-content")
}

@MainActor
@Test func developmentAndroidFolderAuditRejectsCyclesAndEmptyFolders() async {
    let root = Vod(vodId: "root", isFolder: true)
    var requests = 0
    let cycle = await DevelopmentAndroidFolderAudit.resolve(root, isFolder: \.isFolder) { _ in
        requests += 1
        return .init(items: [root])
    }
    #expect(requests == 1)
    #expect(cycle.leaf == nil)
    #expect(cycle.failure == "folder_cycle")
    let empty = await DevelopmentAndroidFolderAudit.resolve(root, isFolder: \.isFolder) { _ in .init(items: []) }
    #expect(empty.leaf == nil)
    #expect(empty.failure == "folder_empty")
}

@MainActor
@Test func developmentAndroidFolderAuditStopsAfterThreeCategories() async {
    var requests = 0
    let result = await DevelopmentAndroidFolderAudit.resolve(Vod(vodId: "0", isFolder: true), isFolder: \.isFolder) { folder in
        requests += 1
        return .init(items: [Vod(vodId: String((Int(folder.vodId) ?? 0) + 1), isFolder: true)])
    }
    #expect(requests == 3)
    #expect(result.leaf == nil)
    #expect(result.failure == "folder_depth_limit")
}

@MainActor
@Test func developmentAndroidFolderAuditBoundsWideEmptyCatalogs() async {
    var requests = 0
    let result = await DevelopmentAndroidFolderAudit.resolve(Vod(vodId: "root", isFolder: true),
        maximumFolderVisits: 4, isFolder: \.isFolder) { folder in
        requests += 1
        return .init(items: folder.vodId == "root"
            ? (0..<20).map { Vod(vodId: "branch-\($0)", isFolder: true) } : [])
    }
    #expect(requests == 4)
    #expect(result.leaf == nil)
    #expect(result.failure == "folder_visit_limit")
}

@MainActor
@Test func developmentAndroidFolderAuditDoesNotAcceptStaleCardsAfterCategoryError() async {
    let result = await DevelopmentAndroidFolderAudit.resolve(Vod(vodId: "root", isFolder: true), isFolder: \.isFolder) { _ in
        .init(items: [Vod(vodId: "stale-leaf")], error: "category failed")
    }
    #expect(result.leaf == nil)
    #expect(result.failure == "folder_category_error")
    #expect(result.visits.first?.error == "category failed")
}

@MainActor
@Test func developmentAndroidFolderAuditTriesSiblingAfterEmptyBranch() async {
    var requests = [String]()
    let result = await DevelopmentAndroidFolderAudit.resolve(Vod(vodId: "root", isFolder: true), isFolder: \.isFolder) { folder in
        requests.append(folder.vodId)
        switch folder.vodId {
        case "root": return .init(items: [Vod(vodId: "empty", isFolder: true), Vod(vodId: "content", isFolder: true)])
        case "content": return .init(items: [Vod(vodId: "leaf")])
        default: return .init(items: [])
        }
    }
    #expect(requests == ["root", "empty", "content"])
    #expect(result.leaf?.vodId == "leaf")
}

@MainActor
@Test func developmentAndroidFolderAuditKeepsExistingAlllivePredicate() async {
    let result = await DevelopmentAndroidFolderAudit.resolve(Vod(vodId: "alllive-category:huya:1"),
        isFolder: { $0.vodId.hasPrefix("alllive-category:") }) { _ in
        .init(items: [Vod(vodId: "room-1")])
    }
    #expect(result.visits.count == 1)
    #expect(result.leaf?.vodId == "room-1")
}

@MainActor
@Test func developmentAndroidFolderAuditKeepsEmptyIDsRejectedByDefault() async {
    for folder in [false, true] {
        var requests = [String]()
        let result = await DevelopmentAndroidFolderAudit.resolve(Vod(vodId: "", isFolder: folder),
            isFolder: \.isFolder) { card in
            requests.append(card.vodId)
            return .init(items: [Vod(vodId: "unexpected")])
        }
        #expect(requests.isEmpty)
        #expect(result.visits.isEmpty)
        #expect(result.leaf == nil)
        #expect(result.failure == "folder_empty")
    }
}

@MainActor
@Test func developmentAndroidFolderAuditLoadsExplicitEmptyCategoryRoot() async {
    var requests = [String]()
    let result = await DevelopmentAndroidFolderAudit.resolve(Vod(vodId: "", isFolder: true),
        allowEmptyRootID: true, isFolder: \.isFolder) { card in
        requests.append(card.vodId)
        return .init(items: [Vod(vodId: "original-match")])
    }
    #expect(requests == [""])
    #expect(result.visits.map(\.id) == [""])
    #expect(result.visits.map(\.depth) == [1])
    #expect(result.leaf?.vodId == "original-match")
    #expect(result.leafDepth == 1)
    #expect(result.failure == nil)
}

@MainActor
@Test func developmentAndroidFolderAuditEmptyRootSkipsEmptyChildrenAndTraversesOriginalIDs() async {
    let opaque = " {\"category\":\"原始分类/a+b%20\"} "
    var requests = [String]()
    let result = await DevelopmentAndroidFolderAudit.resolve(Vod(vodId: "", isFolder: true),
        allowEmptyRootID: true, isFolder: \.isFolder) { card in
        requests.append(card.vodId)
        return .init(items: card.vodId.isEmpty
            ? [Vod(vodId: ""), Vod(vodId: "", isFolder: true), Vod(vodId: opaque, isFolder: true)]
            : [Vod(vodId: ""), Vod(vodId: "", isFolder: true), Vod(vodId: "original-leaf")])
    }
    #expect(requests == ["", opaque])
    #expect(result.visits.map(\.id) == ["", opaque])
    #expect(result.leaf?.vodId == "original-leaf")
    #expect(result.leafDepth == 2)
    #expect(result.failure == nil)
}

@MainActor
@Test func developmentAndroidFolderAuditEmptyRootDoesNotAuthorizeEmptyLoopsOrOrdinaryCards() async {
    var requests = [String]()
    let root = Vod(vodId: "", isFolder: true)
    let loop = await DevelopmentAndroidFolderAudit.resolve(root, allowEmptyRootID: true,
        isFolder: \.isFolder) { card in
        requests.append(card.vodId)
        return .init(items: [root, Vod(vodId: "")])
    }
    #expect(requests == [""])
    #expect(loop.visits.count == 1)
    #expect(loop.leaf == nil)
    #expect(loop.failure == "folder_empty")
    let ordinary = await DevelopmentAndroidFolderAudit.resolve(Vod(vodId: ""),
        allowEmptyRootID: true, isFolder: \.isFolder) { _ in
        Issue.record("An empty ordinary card must never be opened as a category")
        return .init(items: [])
    }
    #expect(ordinary.visits.isEmpty)
    #expect(ordinary.leaf == nil)
    #expect(ordinary.failure == "folder_empty")
}
#endif
