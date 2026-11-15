import Darwin
import Foundation

/// Shares opaque SDK account records between Android sources, never native accounts.
/// Source databases, transfer IDs, URLs and caches remain in their original Context.
enum AndroidSharedAccountStore {
    struct Account: Codable, Equatable {
        var revision = UUID().uuidString
        var values: [String: Data] = [:]
    }

    struct Checkout {
        let root, source: URL
        let accounts: [String: Account]
        let requiresReload: Bool
    }

    private struct Archive: Codable {
        var schema = 1
        var accounts: [String: Account]
    }

    // Observed original SDK storage contract. Cookies in spUtils are encrypted
    // strings; preserve them verbatim rather than translating native credentials.
    private static let files = [
        "ali": ["ali_user", "ali_info", "ali_oauth"],
        "baidu": ["mybd_cookie", "mybd_oauth"],
        "quark": ["quark_ut"],
        "uc": ["uc_ut", "uc_user"]
    ]
    private static let preferences = ["quark": "quark_ck", "uc": "uc_ck"]
    private static let mutex = NSLock()

    static func checkout(root: URL, source: URL) throws -> Checkout {
        try locked(root: root) { directory in
            var shared = try load(directory: directory, legacyRoot: root)
            let current = try readAccounts(source)
            // Recover an SDK save made before the previous process exited. A
            // revision check prevents an old helper from restoring a stale login.
            if let previous = try readArchive(marker(source)) {
                merge(current, baseline: previous.accounts, into: &shared)
                try write(shared, to: directory.appendingPathComponent("accounts.json"))
            }
            return Checkout(root: root, source: source, accounts: shared.accounts,
                requiresReload: shared.accounts.contains { current[$0.key] != $0.value.values })
        }
    }

    /// Call only after the source's old helper has exited when requiresReload is true.
    static func apply(_ checkout: Checkout) throws {
        let current = try readAccounts(checkout.source)
        for drive in files.keys.sorted() {
            let desired = checkout.accounts[drive]?.values ?? [:]
            for name in files[drive] ?? [] {
                let key = "file/" + name
                guard current[drive]?[key] != desired[key] else { continue }
                let path = checkout.source.appendingPathComponent("files/" + name)
                if let data = desired[key] { try writeData(data, to: path) }
                else if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
            }
        }
        try applyPreferences(checkout)
        try write(Archive(accounts: checkout.accounts), to: marker(checkout.source))
    }

    /// Publish even when playerContent fails: a successful scan can precede an
    /// empty media result. Deletions are revisions too, so logout is not resurrected.
    static func publish(_ checkout: Checkout) throws {
        try locked(root: checkout.root) { directory in
            var shared = try load(directory: directory, legacyRoot: checkout.root)
            let current = try readAccounts(checkout.source)
            merge(current, baseline: checkout.accounts, into: &shared)
            try write(shared, to: directory.appendingPathComponent("accounts.json"))
            var baseline = checkout.accounts
            for (drive, account) in shared.accounts where account.values == current[drive] {
                baseline[drive] = account
            }
            try write(Archive(accounts: baseline), to: marker(checkout.source))
        }
    }

    private static func merge(_ values: [String: [String: Data]], baseline: [String: Account], into shared: inout Archive) {
        for drive in files.keys {
            guard let before = baseline[drive], let now = values[drive], now != before.values,
                  shared.accounts[drive]?.revision == before.revision else { continue }
            shared.accounts[drive] = Account(values: now)
        }
    }

    private static func load(directory: URL, legacyRoot: URL) throws -> Archive {
        let path = directory.appendingPathComponent("accounts.json")
        if let existing = try readArchive(path) { return existing }
        var accounts: [String: Account] = [:]
        let sources = try FileManager.default.contentsOfDirectory(at: legacyRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]).filter {
                $0.lastPathComponent.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
            }.sorted { $0.path < $1.path }
        var dates: [String: Date] = [:]
        for source in sources {
            let attributes = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard attributes.isDirectory == true, attributes.isSymbolicLink != true else { continue }
            let values = try readAccounts(source)
            for drive in files.keys where !(values[drive] ?? [:]).isEmpty {
                let paths = (files[drive] ?? []).map { source.appendingPathComponent("files/" + $0) }
                    + (preferences[drive] == nil ? [] : [source.appendingPathComponent("shared_prefs/spUtils.xml")])
                let date = paths.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max() ?? .distantPast
                if accounts[drive] == nil || date > (dates[drive] ?? .distantPast) {
                    accounts[drive] = Account(values: values[drive] ?? [:])
                    dates[drive] = date
                }
            }
        }
        for drive in files.keys where accounts[drive] == nil { accounts[drive] = Account() }
        let archive = Archive(accounts: accounts)
        try write(archive, to: path)
        return archive
    }

    private static func readAccounts(_ source: URL) throws -> [String: [String: Data]] {
        let document = try readPreferences(source)
        var result: [String: [String: Data]] = [:]
        for drive in files.keys {
            var values: [String: Data] = [:]
            for name in files[drive] ?? [] {
                if let data = try readData(source.appendingPathComponent("files/" + name)) {
                    values["file/" + name] = data
                }
            }
            if let key = preferences[drive], let value = preference(document, key)?.stringValue {
                values["pref/" + key] = Data(value.utf8)
            }
            result[drive] = values
        }
        return result
    }

    private static func readPreferences(_ source: URL) throws -> XMLDocument? {
        guard let data = try readData(source.appendingPathComponent("shared_prefs/spUtils.xml")) else { return nil }
        let document = try XMLDocument(data: data, options: [])
        guard document.rootElement()?.name == "map", document.dtd == nil else { throw StoreError.invalidData }
        return document
    }

    private static func preference(_ document: XMLDocument?, _ key: String) -> XMLElement? {
        document?.rootElement()?.elements(forName: "string").first { $0.attribute(forName: "name")?.stringValue == key }
    }

    private static func applyPreferences(_ checkout: Checkout) throws {
        let existing = try readPreferences(checkout.source)
        let document = existing ?? XMLDocument(rootElement: XMLElement(name: "map"))
        var changed = false
        for (drive, key) in preferences {
            let desired = checkout.accounts[drive]?.values["pref/" + key]
            let current = preference(document, key)
            let currentData = current?.stringValue.map { Data($0.utf8) }
            guard currentData != desired else { continue }
            current?.detach()
            if let desired {
                guard let text = String(data: desired, encoding: .utf8) else { throw StoreError.invalidData }
                let node = XMLElement(name: "string", stringValue: text)
                node.addAttribute(XMLNode.attribute(withName: "name", stringValue: key) as! XMLNode)
                document.rootElement()?.addChild(node)
            }
            changed = true
        }
        if changed { try writeData(document.xmlData, to: checkout.source.appendingPathComponent("shared_prefs/spUtils.xml")) }
    }

    private static func marker(_ source: URL) -> URL { source.appendingPathComponent(".runtime/shared-account-checkout.json") }

    private static func readArchive(_ path: URL) throws -> Archive? {
        guard let data = try readData(path) else { return nil }
        let archive = try JSONDecoder().decode(Archive.self, from: data)
        guard archive.schema == 1, Set(archive.accounts.keys) == Set(files.keys) else { throw StoreError.invalidData }
        for (drive, account) in archive.accounts {
            let allowed = Set((files[drive] ?? []).map { "file/" + $0 } + (preferences[drive].map { ["pref/" + $0] } ?? []))
            guard Set(account.values.keys).isSubset(of: allowed) else { throw StoreError.invalidData }
        }
        return archive
    }

    private static func readData(_ path: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let values = try path.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? .max) <= 1_048_576 else {
            throw StoreError.invalidData
        }
        return try Data(contentsOf: path)
    }

    private static func write(_ archive: Archive, to path: URL) throws {
        try writeData(JSONEncoder().encode(archive), to: path)
    }

    private static func writeData(_ data: Data, to path: URL) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try data.write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

    private static func locked<T>(root: URL, _ body: (URL) throws -> T) throws -> T {
        mutex.lock()
        defer { mutex.unlock() }
        let directory = root.appendingPathComponent("shared-accounts-v1", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let fd = open(directory.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw StoreError.unavailable }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw StoreError.unavailable }
        defer { flock(fd, LOCK_UN) }
        return try body(directory)
    }

    private enum StoreError: Error { case invalidData, unavailable }
}
