import Foundation
import Testing
import Models
import Storage
import FileServiceEngine

/// Isolates the unchanged file-service byte transport from libmpv and the proxy
/// when a real long film cannot sustain playback. No URL or credential export.
@MainActor
@Test(.disabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_RAW_NAS_ACCEPTANCE"] != "1"))
func rawNASReadThroughputWhenEnabled() async throws {
    let output = try #require(ProcessInfo.processInfo.environment["NETVPLAYER_RAW_NAS_OUTPUT"])
    let parent = URL(fileURLWithPath: output).deletingLastPathComponent()
    let permissions = try FileManager.default.attributesOfItem(atPath: parent.path)[.posixPermissions] as? NSNumber
    try #require((permissions?.intValue ?? 0) & 0o077 == 0)
    let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/NetVplayer")
    let history = try JSONDecoder().decode([History].self, from: Data(contentsOf: support.appendingPathComponent("history.json")))
    let entry = try #require(history.first { FileResourceReference(locator: $0.episodeUrl) != nil })
    let reference = try #require(FileResourceReference(locator: entry.episodeUrl))
    let defaults = try #require(UserDefaults(suiteName: UserPreferences.stableBundleIdentifier))
    let preferences = UserPreferences(defaults: defaults, credentialStore: LocalCredentialStore())
    let runtime = FileServiceRuntime(store: FileServiceStore(preferences: preferences))
    let client = try await runtime.client(for: reference.serviceID)
    defer { Task { await client.disconnect() } }
    let size = try await client.stat(path: reference.path).size
    var offset: Int64 = 0
    var waits: [Double] = []
    let began = ProcessInfo.processInfo.systemUptime
    while ProcessInfo.processInfo.systemUptime - began < 30, offset < min(size, 512 * 1024 * 1024) {
        let end = min(size, offset + 4 * 1024 * 1024)
        let start = ProcessInfo.processInfo.systemUptime
        let data = try await client.read(path: reference.path, range: offset..<end)
        try #require(data.count == end - offset)
        waits.append(ProcessInfo.processInfo.systemUptime - start)
        offset = end
    }
    let elapsed = ProcessInfo.processInfo.systemUptime - began
    let duration = Double(entry.duration) / 1000
    let record: [String: Any] = ["scope": "user-NAS-direct-file-service", "sourceBytes": size,
        "historyDurationSeconds": duration, "requiredAverageBytesPerSecond": duration > 0 ? Double(size) / duration : 0,
        "readBytes": offset, "elapsedSeconds": elapsed, "bytesPerSecond": Double(offset) / elapsed,
        "rangeBytes": 4 * 1024 * 1024, "rangeWaitSeconds": waits,
        "notes": "Sequential reads through the unchanged file-service client; no ProxyServer, cache or libmpv. This is a short transport observation, not smooth long-play acceptance."]
    let data = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: URL(fileURLWithPath: output), options: .withoutOverwriting)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output)
    print("[RAW_NAS_READ] bytes=\(offset) seconds=\(elapsed)")
}
