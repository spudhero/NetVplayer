import Foundation

/// A process-local preference overlay. Registration domains are shared between
/// UserDefaults instances, so an audit must never use register(defaults:).
final class SessionUserDefaults: UserDefaults, @unchecked Sendable {
    private let valueLock = NSRecursiveLock()
    private var values: [String: Any]

    init(values: [String: Any] = [:]) {
        self.values = values
        super.init(suiteName: "com.netvplayer.audit.memory." + UUID().uuidString)!
    }

    override func object(forKey defaultName: String) -> Any? {
        valueLock.lock()
        defer { valueLock.unlock() }
        return values[defaultName]
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        valueLock.lock()
        defer { valueLock.unlock() }
        values[defaultName] = value
    }

    override func removeObject(forKey defaultName: String) {
        valueLock.lock()
        defer { valueLock.unlock() }
        values.removeValue(forKey: defaultName)
    }

    override func dictionaryRepresentation() -> [String: Any] {
        valueLock.lock()
        defer { valueLock.unlock() }
        return values
    }

    // A copied credentialLegacyDomains key must not grant an audit access to
    // persistent domains, including when saveCredential cleans legacy values.
    override func persistentDomain(forName domainName: String) -> [String: Any]? { nil }
    override func setPersistentDomain(_ domain: [String: Any], forName domainName: String) {}
    override func removePersistentDomain(forName domainName: String) {}

    func discard() {
        valueLock.lock()
        defer { valueLock.unlock() }
        values.removeAll()
    }
}
