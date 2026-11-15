import Foundation
import Testing
@testable import SpiderEngine

@Test func androidSharedAccountsMigrateLoginWithoutSourceCachesOrNativeAccounts() throws {
    let fixture = try SharedAccountFixture()
    defer { fixture.remove() }
    try fixture.save("opaque-uc-session", "files/uc_ut", at: fixture.first)
    try fixture.save("opaque-baidu-cookie", "files/mybd_cookie", at: fixture.first)
    try fixture.save("opaque-baidu-oauth", "files/mybd_oauth", at: fixture.first)
    try fixture.save("source-transfer-id", "files/baidu_fid", at: fixture.first)
    try fixture.save("source-database", "databases/source.db", at: fixture.first)
    try fixture.preferences(["uc_ck": "opaque-uc-cookie", "wogg_site": "source-one", "lastUcDownUrl": "source-url"], at: fixture.first)
    try fixture.preferences(["wogg_site": "source-two"], at: fixture.second)
    let checkout = try AndroidSharedAccountStore.checkout(root: fixture.root, source: fixture.second)
    #expect(checkout.requiresReload)
    try AndroidSharedAccountStore.apply(checkout)
    #expect(try fixture.text("files/uc_ut", at: fixture.second) == "opaque-uc-session")
    #expect(try fixture.text("files/mybd_oauth", at: fixture.second) == "opaque-baidu-oauth")
    #expect(try fixture.preference("uc_ck", at: fixture.second) == "opaque-uc-cookie")
    #expect(try fixture.preference("wogg_site", at: fixture.second) == "source-two")
    #expect(try fixture.preference("lastUcDownUrl", at: fixture.second) == nil)
    #expect(!fixture.exists("files/baidu_fid", at: fixture.second))
    #expect(!fixture.exists("databases/source.db", at: fixture.second))
    #expect(try fixture.text("databases/source.db", at: fixture.first) == "source-database")
    let separateRoot = fixture.root.appendingPathComponent("independent-audit")
    let isolated = try AndroidSharedAccountStore.checkout(root: separateRoot, source: separateRoot.appendingPathComponent("empty"))
    #expect(isolated.accounts.values.allSatisfy { $0.values.isEmpty })
    let permissions = try FileManager.default.attributesOfItem(atPath: fixture.root.appendingPathComponent("shared-accounts-v1/accounts.json").path)
    #expect((permissions[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

@Test func androidSharedAccountsNewLoginReloadsOtherSourceAndSurvivesRestart() throws {
    let fixture = try SharedAccountFixture()
    defer { fixture.remove() }
    let first = try fixture.checkout(fixture.first)
    let beforeLogin = try fixture.checkout(fixture.second)
    #expect(!beforeLogin.requiresReload)
    try fixture.save("new-sdk-login", "files/uc_ut", at: fixture.first)
    try fixture.preferences(["uc_ck": "new-sdk-cookie"], at: fixture.first)
    try AndroidSharedAccountStore.publish(first)
    let second = try fixture.checkout(fixture.second)
    #expect(second.requiresReload)
    #expect(try fixture.text("files/uc_ut", at: fixture.second) == "new-sdk-login")
    #expect(try fixture.preference("uc_ck", at: fixture.second) == "new-sdk-cookie")
    let restart = try fixture.checkout(fixture.second)
    #expect(!restart.requiresReload)
    // A save preceding a crash is recovered from the last checkout next launch.
    try fixture.save("refreshed-sdk-login", "files/uc_ut", at: fixture.second)
    _ = try fixture.checkout(fixture.second)
    _ = try fixture.checkout(fixture.first)
    #expect(try fixture.text("files/uc_ut", at: fixture.first) == "refreshed-sdk-login")
}

@Test func androidSharedAccountLogoutCannotBeRestoredByStaleHelper() throws {
    let fixture = try SharedAccountFixture()
    defer { fixture.remove() }
    try fixture.save("old-cookie", "files/mybd_cookie", at: fixture.first)
    try fixture.save("old-oauth", "files/mybd_oauth", at: fixture.first)
    let first = try fixture.checkout(fixture.first)
    let stale = try fixture.checkout(fixture.second)
    try FileManager.default.removeItem(at: fixture.first.appendingPathComponent("files/mybd_cookie"))
    try FileManager.default.removeItem(at: fixture.first.appendingPathComponent("files/mybd_oauth"))
    try AndroidSharedAccountStore.publish(first)
    try fixture.save("stale-refresh", "files/mybd_oauth", at: fixture.second)
    try AndroidSharedAccountStore.publish(stale)
    let reloaded = try fixture.checkout(fixture.second)
    #expect(reloaded.requiresReload)
    #expect(!fixture.exists("files/mybd_cookie", at: fixture.second))
    #expect(!fixture.exists("files/mybd_oauth", at: fixture.second))
    #expect(!fixture.exists("files/mybd_cookie", at: fixture.first))
}

@Test func androidSharedAccountsSelectWholeDriveRecordAndKeepOtherDrives() throws {
    let fixture = try SharedAccountFixture()
    defer { fixture.remove() }
    try fixture.save("first-cookie", "files/mybd_cookie", at: fixture.first)
    try fixture.save("first-oauth", "files/mybd_oauth", at: fixture.first)
    try fixture.save("second-cookie", "files/mybd_cookie", at: fixture.second)
    try fixture.save("second-oauth", "files/mybd_oauth", at: fixture.second)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)],
        ofItemAtPath: fixture.first.appendingPathComponent("files/mybd_cookie").path)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)],
        ofItemAtPath: fixture.first.appendingPathComponent("files/mybd_oauth").path)
    try fixture.save("ali-user", "files/ali_user", at: fixture.first)
    try fixture.save("ali-oauth", "files/ali_oauth", at: fixture.first)
    let checkout = try fixture.checkout(fixture.first)
    #expect(checkout.requiresReload)
    #expect(try fixture.text("files/mybd_cookie", at: fixture.first) == "second-cookie")
    #expect(try fixture.text("files/mybd_oauth", at: fixture.first) == "second-oauth")
    #expect(try fixture.text("files/ali_oauth", at: fixture.first) == "ali-oauth")
}

private struct SharedAccountFixture {
    let root: URL
    var first: URL { root.appendingPathComponent(String(repeating: "a", count: 64)) }
    var second: URL { root.appendingPathComponent(String(repeating: "b", count: 64)) }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AndroidSharedAccountTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for source in [first, second] { try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true) }
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func save(_ text: String, _ path: String, at source: URL) throws {
        let url = source.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    func text(_ path: String, at source: URL) throws -> String { try String(contentsOf: source.appendingPathComponent(path), encoding: .utf8) }
    func exists(_ path: String, at source: URL) -> Bool { FileManager.default.fileExists(atPath: source.appendingPathComponent(path).path) }
    func preferences(_ values: [String: String], at source: URL) throws {
        let map = XMLElement(name: "map")
        for (key, value) in values {
            let element = XMLElement(name: "string", stringValue: value)
            element.addAttribute(XMLNode.attribute(withName: "name", stringValue: key) as! XMLNode)
            map.addChild(element)
        }
        let url = source.appendingPathComponent("shared_prefs/spUtils.xml")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try XMLDocument(rootElement: map).xmlData.write(to: url)
    }
    func preference(_ key: String, at source: URL) throws -> String? {
        let doc = try XMLDocument(contentsOf: source.appendingPathComponent("shared_prefs/spUtils.xml"))
        return doc.rootElement()?.elements(forName: "string").first { $0.attribute(forName: "name")?.stringValue == key }?.stringValue
    }
    func checkout(_ source: URL) throws -> AndroidSharedAccountStore.Checkout {
        let checkout = try AndroidSharedAccountStore.checkout(root: root, source: source)
        try AndroidSharedAccountStore.apply(checkout)
        return checkout
    }
}
