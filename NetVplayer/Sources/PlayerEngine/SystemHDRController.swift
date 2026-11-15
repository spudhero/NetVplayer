import AppKit
import Foundation
import Models
import MPVShim

extension Notification.Name {
    public static let systemHDRWillChange = Notification.Name("NetVplayer.SystemHDR.willChange")
    public static let systemHDRDidRequestChange = Notification.Name("NetVplayer.SystemHDR.didRequestChange")
    public static let systemHDRStateDidChange = Notification.Name("NetVplayer.SystemHDR.stateDidChange")
}

/// Coordinates temporary system HDR preferences with all playback surfaces.
/// Call update before the public EDR headroom gate; current headroom still
/// determines actual HDR presentation. Built-in displays always use public EDR.
@MainActor public final class SystemHDRController {
    public static let shared = SystemHDRController()

    /// Release/stop HDMI audio asynchronously. Returning false cancels this
    /// transition; the finish callback still runs to restore any suspended AO.
    public var prepareForDisplayChange: (@MainActor (SystemHDRTransition) async -> Bool)?
    /// Called after preference readback settles, or after any failure/cancel.
    /// `success` verifies system preference, not television HDR metadata.
    public var didFinishDisplayChange: (@MainActor (SystemHDRTransition, Bool) async -> Void)?

    public var pendingRecovery: [SystemHDRInterruptedChange] { coordinator.pendingRecovery }
    public var isChangingDisplay: Bool { transitionTask != nil }

    private let coordinator: SystemHDRLeaseCoordinator
    private let ownHDMIHog: @MainActor () -> Int32
    private let postsNotifications: Bool
    private let observers = SystemHDRObserverBag()
    private var transitionTask: Task<Void, Never>?
    private var preparing: SystemHDRTransition?
    private var ready: SystemHDRTransition?
    private var submitted = false
    private var explicitRecovery: Set<UUID> = []
    private var terminating = false

    private convenience init() {
        self.init(coordinator: SystemHDRLeaseCoordinator(backend: SystemHDRMonitorPanelBackend(), journal: SystemHDRFileJournal()),
                  ownHDMIHog: { nv_system_hdr_has_own_hdmi_audio_hog() }, observeSystem: true)
    }

    init(coordinator: SystemHDRLeaseCoordinator, ownHDMIHog: @escaping @MainActor () -> Int32,
         observeSystem: Bool = false) {
        self.coordinator = coordinator
        self.ownHDMIHog = ownHDMIHog
        self.postsNotifications = observeSystem
        coordinator.prepareForDisplayChange = { [weak self] transition in self?.prepare(transition) ?? false }
        coordinator.didRequestDisplayChange = { [weak self] transition in
            guard let self else { return }
            self.submitted = true
            DiagnosticLog.write("[SYSTEM_HDR] requested enabled=\(transition.enabling) display=\(transition.displayID)")
            if self.postsNotifications {
                NotificationCenter.default.post(name: .systemHDRDidRequestChange, object: self,
                    userInfo: Self.userInfo(transition))
            }
        }
        coordinator.didUpdate = { [weak self] in
            guard let self else { return }
            if self.postsNotifications { NotificationCenter.default.post(name: .systemHDRStateDidChange, object: self) }
        }
        guard observeSystem else { return }
        observers.tokens.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.displayConfigurationDidChange() }
        })
        observers.workspaceTokens.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.restoreAll() }
        })
        observers.timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.coordinator.hasWork else { return }
                self.coordinator.refresh()
            }
        }
    }

    @discardableResult
    public func update(ownerID: UUID, displayID: UInt32?, wantsHDR: Bool) -> SystemHDRStatus {
        coordinator.update(ownerID: ownerID, displayID: displayID, wantsHDR: wantsHDR && !terminating)
    }

    /// Call after update/refresh; observing an already-enabled system preference
    /// must not acquire ownership or schedule any display/audio transition.
    func observedHDR(forDisplayID displayID: UInt32?) -> Bool? {
        coordinator.observedHDR(forDisplayID: displayID)
    }

    public func release(ownerID: UUID) { coordinator.release(ownerID: ownerID) }
    public func displayConfigurationDidChange() { coordinator.refresh() }

    /// Normal stop/close can release one owner. Before application termination,
    /// await this via applicationShouldTerminate's terminateLater path.
    public func restoreForTermination() async {
        terminating = true
        await restoreAll()
    }

    public func restoreAll() async {
        coordinator.restoreAll()
        // A pending prepare may become unnecessary; it still needs to finish
        // its audio cleanup before a queued restore can begin.
        while let task = transitionTask {
            await task.value
            coordinator.refresh()
        }
    }

    /// An explicit user action. Startup only reports pendingRecovery, preserving
    /// any HDR preference the user might have changed since the crash.
    public func restoreInterruptedChange(displayUUID: UUID) {
        explicitRecovery.insert(displayUUID)
        if coordinator.restoreInterruptedChange(displayUUID: displayUUID) {
            // A ready asynchronous transition will keep the journal until readback.
            explicitRecovery.remove(displayUUID)
        } else if preparing?.displayUUID != displayUUID {
            explicitRecovery.remove(displayUUID)
        }
    }

    private func prepare(_ transition: SystemHDRTransition) -> Bool {
        if ready == transition { return true }
        guard transitionTask == nil else { return false }
        preparing = transition
        transitionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if self.postsNotifications {
                NotificationCenter.default.post(name: .systemHDRWillChange, object: self,
                    userInfo: Self.userInfo(transition))
            }
            let prepared = await self.prepareForDisplayChange?(transition) ?? true
            // Unknown hardware reads are not evidence that hog has been released.
            let hog = self.ownHDMIHog()
            var success = false
            if prepared && hog == 0 && !Task.isCancelled {
                self.ready = transition
                self.submitted = false
                if self.explicitRecovery.contains(transition.displayUUID) {
                    _ = self.coordinator.restoreInterruptedChange(displayUUID: transition.displayUUID)
                } else {
                    // Recheck current UUID, mode, owners and user overrides after await.
                    self.coordinator.refresh()
                }
                self.ready = nil
                if self.submitted {
                    let deadline = ProcessInfo.processInfo.systemUptime + 4.5
                    var matchingSince: TimeInterval?
                    while !Task.isCancelled && ProcessInfo.processInfo.systemUptime < deadline {
                        self.coordinator.refresh()
                        let now = ProcessInfo.processInfo.systemUptime
                        if self.coordinator.observedHDR(for: transition.displayUUID) == transition.enabling {
                            matchingSince = matchingSince ?? now
                            if now - matchingSince! >= 0.3 { success = true; break }
                        } else { matchingSince = nil }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
            } else {
                DiagnosticLog.write("[SYSTEM_HDR] preparation declined ready=\(prepared) ownHDMIHog=\(hog)")
                self.coordinator.rejectPendingTransition(transition)
            }
            DiagnosticLog.write("[SYSTEM_HDR] finished enabled=\(transition.enabling) success=\(success) display=\(transition.displayID)")
            await self.didFinishDisplayChange?(transition, success)
            self.explicitRecovery.remove(transition.displayUUID)
            self.preparing = nil
            self.transitionTask = nil
            self.coordinator.refresh() // Process the latest coalesced request next.
        }
        return false
    }

    private static func userInfo(_ transition: SystemHDRTransition) -> [String: Any] {
        ["displayID": transition.displayID, "displayUUID": transition.displayUUID.uuidString,
         "enabling": transition.enabling]
    }
}

private final class SystemHDRObserverBag: @unchecked Sendable {
    var tokens: [NSObjectProtocol] = []
    var workspaceTokens: [NSObjectProtocol] = []
    var timer: Timer?
    deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        for token in workspaceTokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        timer?.invalidate()
    }
}

@MainActor private final class SystemHDRMonitorPanelBackend: SystemHDRDisplayBackend {
    private var reportedReadFailure = false
    func displays() throws -> [SystemHDRDisplaySnapshot] {
        // Existing renderer tests may construct real engines. Their singleton
        // must never change the user's display; controller tests inject a fake.
        if Bundle.main.bundleURL.pathExtension == "xctest"
            || CommandLine.arguments.first?.contains(".xctest/") == true {
            return []
        }
        do {
            let result = try NVSystemHDRDisplay.readDisplays().compactMap { state -> SystemHDRDisplaySnapshot? in
                guard let uuid = UUID(uuidString: state.displayUUID.uuidString) else { return nil }
                return SystemHDRDisplaySnapshot(displayID: state.displayID, displayUUID: uuid,
                    supportsHDR: state.supportsHDR, prefersHDR: state.prefersHDR, isBuiltin: state.isBuiltin,
                    configurationFingerprint: state.configurationFingerprint)
            }
            reportedReadFailure = false
            return result
        } catch {
            if !reportedReadFailure { DiagnosticLog.write("[SYSTEM_HDR] display read failed: \(error.localizedDescription)") }
            reportedReadFailure = true
            throw error
        }
    }
    func setHDR(_ enabled: Bool, displayUUID: UUID) throws {
        do { try NVSystemHDRDisplay.setPrefersHDR(enabled, forDisplay: displayUUID) }
        catch {
            DiagnosticLog.write("[SYSTEM_HDR] preference write failed: \(error.localizedDescription)")
            throw error
        }
    }
}

@MainActor private final class SystemHDRFileJournal: SystemHDRJournal {
    private let url: URL
    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        url = base.appendingPathComponent("NetVplayer/Playback/system-hdr-restore.json")
    }
    func load() throws -> [SystemHDRInterruptedChange] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([SystemHDRInterruptedChange].self, from: Data(contentsOf: url))
    }
    func save(_ records: [SystemHDRInterruptedChange]) throws {
        if records.isEmpty {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(records).write(to: url, options: .atomic)
    }
}
