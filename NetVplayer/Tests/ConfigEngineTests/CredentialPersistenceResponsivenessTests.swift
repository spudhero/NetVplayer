import AppKit
import Models
import Storage
import SwiftUI
import Testing
@testable import NetVplayerApp

@Suite("Credential status main-thread responsiveness", .serialized) @MainActor
struct CredentialPersistenceResponsivenessTests {
    @Test func initialStatusReadDoesNotBlockUI() async throws {
        try await checkStatusRead(notification: false)
    }

    @Test func credentialChangeDoesNotBlockUI() async throws {
        try await checkStatusRead(notification: true)
    }

    @Test func settingsSnapshotWaitsOffMainThreadAndKeepsProviderStatus() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        try fixture.preferences.saveCredential("synthetic-uc", for: "ucCookie")
        fixture.preferences.markCloudAccountVerified(.uc)
        try fixture.preferences.saveCredential("synthetic-baidu", for: "baiduCookie")
        let worker = await holdCredentialLock(fixture)
        let start = ContinuousClock.now
        let snapshot = Task.detached { CloudAccountSettingsSnapshot(preferences: fixture.preferences) }
        try await Task.sleep(for: .milliseconds(80))
        #expect(start.duration(to: .now) < .milliseconds(400))
        fixture.store.release.signal()
        _ = await worker.value
        let result = await snapshot.value
        #expect(result.statuses[.uc] == .verified)
        #expect(result.statuses[.baidu] == .saved)
        #expect(result.statuses[.quark] == .disconnected)
        #expect(result.values["ucCookie"] == "synthetic-uc")
    }

    private func checkStatusRead(notification: Bool) async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        _ = NSApplication.shared
        let host = NSHostingView(rootView: VStack {
            Text("Synthetic credential status")
            CredentialPersistenceStatusView(preferences: fixture.preferences)
        }.frame(width: 600, height: 200))
        let window = NSWindow(contentRect: .init(x: -3000, y: 0, width: 600, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        if notification {
            window.orderFront(nil)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
        }
        let worker = await holdCredentialLock(fixture)
        let start = ContinuousClock.now
        if notification {
            NotificationCenter.default.post(name: UserPreferences.credentialsDidChange, object: nil)
        } else {
            window.orderFront(nil)
            host.layoutSubtreeIfNeeded()
        }
        // A held credential lock must not delay the main actor's next turn.
        // The store's one-second fallback also lets the old code fail without
        // leaving the test process permanently deadlocked.
        try await Task.sleep(for: .milliseconds(80))
        #expect(start.duration(to: .now) < .milliseconds(400))
        fixture.store.release.signal()
        _ = await worker.value
        try await Task.sleep(for: .milliseconds(50))
    }

    private func holdCredentialLock(_ fixture: Fixture) async -> Task<String, Never> {
        let worker = Task.detached { fixture.preferences.credential("synthetic-blocked-read") }
        let entered = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: fixture.store.entered.wait(timeout: .now() + 2))
            }
        }
        #expect(entered == .success)
        return worker
    }

    private final class BlockingStore: CredentialStore, @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        private let backing = MemoryCredentialStore()
        func read(_ key: String) throws -> String? {
            if key == "synthetic-blocked-read" {
                entered.signal()
                _ = release.wait(timeout: .now() + 1)
                return nil
            }
            return backing.read(key)
        }
        func write(_ value: String, for key: String) throws { backing.write(value, for: key) }
        func remove(_ key: String) throws { backing.remove(key) }
    }

    private final class Fixture: @unchecked Sendable {
        let name = "credential-ui-" + UUID().uuidString
        let store = BlockingStore()
        let defaults: UserDefaults
        let preferences: UserPreferences
        init() {
            defaults = UserDefaults(suiteName: name)!
            preferences = UserPreferences(defaults: defaults, credentialStore: store)
        }
        func clean() { defaults.removePersistentDomain(forName: name) }
    }
}
