import Darwin
import Foundation
import ProviderSDK

struct QuickJSPersistenceHost: @unchecked Sendable {
    private let store: QuickJSPersistenceStore

    init(stateDirectoryURL: URL) {
        store = QuickJSPersistenceStore(stateDirectoryURL: stateDirectoryURL)
    }

    func handle(_ request: QuickJSHostControl) async -> QuickJSHostResponse {
        guard request.capability == "persistence" else {
            return failure(
                requestID: request.requestID,
                code: "unsupported_host_request",
                message: "Unsupported QuickJS persistence request"
            )
        }
        do {
            let options = request.options ?? [:]
            let rule = string(options["rule"]) ?? ""
            let key = try requiredString(options["key"], name: "key")
            let value: String?
            switch request.operation {
            case "get":
                value = store.get(rule: rule, key: key)
            case "set":
                let stored = try requiredString(options["value"], name: "value")
                try store.set(rule: rule, key: key, value: stored)
                value = nil
            case "delete":
                try store.delete(rule: rule, key: key)
                value = nil
            default:
                throw QuickJSPersistenceHostError(code: "unsupported_operation", message: "QuickJS persistence operation is unsupported")
            }
            return QuickJSHostResponse(
                requestID: request.requestID,
                ok: true,
                result: .object(["value": value.map(ProviderJSONValue.string) ?? .null])
            )
        } catch let error as QuickJSPersistenceHostError {
            return failure(requestID: request.requestID, code: error.code, message: error.message)
        } catch {
            return failure(requestID: request.requestID, code: "persistence_failed", message: "QuickJS persistence operation failed")
        }
    }

    private func string(_ value: ProviderJSONValue?) -> String? {
        guard case .string(let value) = value else { return nil }
        return value
    }

    private func requiredString(_ value: ProviderJSONValue?, name: String) throws -> String {
        guard let value = string(value) else {
            throw QuickJSPersistenceHostError(code: "invalid_\(name)", message: "Persistence \(name) is invalid")
        }
        return value
    }

    private func failure(requestID: String, code: String, message: String) -> QuickJSHostResponse {
        QuickJSHostResponse(
            requestID: requestID,
            ok: false,
            error: ProviderErrorPayload(code: code, message: message)
        )
    }
}

private final class QuickJSPersistenceStore: @unchecked Sendable {
    private final class SharedState: @unchecked Sendable {
        let fileURL: URL
        let lockURL: URL
        let lock = NSLock()
        var values: [String: String]

        init(fileURL: URL) {
            self.fileURL = fileURL
            lockURL = fileURL.appendingPathExtension("lock")
            values = QuickJSPersistenceStore.load(from: fileURL)
        }
    }

    private final class WeakState {
        weak var value: SharedState?

        init(_ value: SharedState) {
            self.value = value
        }
    }

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [URL: WeakState] = [:]
    private static let legacyPreferencesFileName = "shared_prefs.xml"
    private static let legacyMigrationMarkerName = "shared_prefs.xml.migrated"
    private let shared: SharedState

    init(stateDirectoryURL: URL) {
        let fileURL = stateDirectoryURL
            .standardizedFileURL
            .appendingPathComponent("quickjs-local.json", isDirectory: false)
        Self.registryLock.lock()
        if let existing = Self.registry[fileURL]?.value {
            shared = existing
        } else {
            let created = SharedState(fileURL: fileURL)
            Self.registry[fileURL] = WeakState(created)
            shared = created
        }
        Self.registryLock.unlock()
        migrateLegacyPreferencesIfNeeded(
            from: fileURL.deletingLastPathComponent().appendingPathComponent(Self.legacyPreferencesFileName),
            marker: fileURL.deletingLastPathComponent().appendingPathComponent(Self.legacyMigrationMarkerName)
        )
    }

    func get(rule: String, key: String) -> String {
        shared.lock.lock()
        defer { shared.lock.unlock() }
        do {
            return try withFileLock {
                shared.values = Self.load(from: shared.fileURL)
                return shared.values[storageKey(rule: rule, key: key)] ?? ""
            }
        } catch {
            // Android Prefers.getString catches storage failures and returns the default.
            return ""
        }
    }

    func set(rule: String, key: String, value: String) throws {
        shared.lock.lock()
        defer { shared.lock.unlock() }
        try withFileLock {
            shared.values = Self.load(from: shared.fileURL)
            shared.values[storageKey(rule: rule, key: key)] = value
            try persistLocked()
        }
    }

    func delete(rule: String, key: String) throws {
        shared.lock.lock()
        defer { shared.lock.unlock() }
        try withFileLock {
            shared.values = Self.load(from: shared.fileURL)
            shared.values.removeValue(forKey: storageKey(rule: rule, key: key))
            try persistLocked()
        }
    }

    private func storageKey(rule: String, key: String) -> String {
        "cache_" + (rule.isEmpty ? "" : "\(rule)_") + key
    }

    private func persistLocked() throws {
        let data = try JSONSerialization.data(withJSONObject: shared.values, options: [.sortedKeys])
        try FileManager.default.createDirectory(
            at: shared.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: shared.fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: shared.fileURL.path)
    }

    private func withFileLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(
            at: shared.lockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor = open(shared.lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw QuickJSPersistenceHostError(code: "persistence_lock_failed", message: "Persistence lock cannot be opened")
        }
        guard flock(descriptor, LOCK_EX) == 0 else {
            close(descriptor)
            throw QuickJSPersistenceHostError(code: "persistence_lock_failed", message: "Persistence lock cannot be acquired")
        }
        defer {
            _ = flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        return try body()
    }

    private static func load(from url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object.reduce(into: [:]) { result, item in
            if let value = item.value as? String {
                result[item.key] = value
            }
        }
    }

    private func migrateLegacyPreferencesIfNeeded(from legacyURL: URL, marker: URL) {
        shared.lock.lock()
        defer { shared.lock.unlock() }
        do {
            try withFileLock {
                let fileManager = FileManager.default
                guard fileManager.fileExists(atPath: legacyURL.path),
                      !fileManager.fileExists(atPath: marker.path),
                      let data = try? Data(contentsOf: legacyURL),
                      let imported = QuickJSSharedPreferencesXML.parse(data: data) else {
                    return
                }
                shared.values = Self.load(from: shared.fileURL)
                for (key, value) in imported where shared.values[key] == nil {
                    shared.values[key] = value
                }
                try persistLocked()
                try Data("migrated\n".utf8).write(to: marker, options: .atomic)
                try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
            }
        } catch {
            // A malformed or inaccessible legacy file remains available for a later retry.
        }
    }
}

private enum QuickJSSharedPreferencesXML {
    static func parse(data: Data) -> [String: String]? {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), delegate.isValid else { return nil }
        return delegate.values.filter { $0.key.hasPrefix("cache_") }
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var values: [String: String] = [:]
        var isValid = false
        private var currentName: String?
        private var currentValue = ""

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            switch elementName {
            case "map":
                isValid = true
            case "string":
                currentName = attributeDict["name"]
                currentValue = ""
            case "boolean", "int", "long", "float":
                if let name = attributeDict["name"], let value = attributeDict["value"] {
                    values[name] = value
                }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if currentName != nil { currentValue.append(string) }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            guard elementName == "string", let name = currentName else { return }
            values[name] = currentValue
            currentName = nil
            currentValue = ""
        }
    }
}

private struct QuickJSPersistenceHostError: Error {
    let code: String
    let message: String
}
