import Foundation

public enum SystemHDRStatus: Equatable, Sendable {
    case inactive, unavailable, nativeEDR, alreadyEnabled, waitingForAudio, requesting, enabledTemporarily, userOverride, failed
}

public struct SystemHDRTransition: Equatable, Sendable {
    public let displayID: UInt32
    public let displayUUID: UUID
    public let enabling: Bool
}

/// A crash leaves an ambiguous system preference: a user may have subsequently
/// enabled HDR themselves. These records require an explicit recovery action.
public struct SystemHDRInterruptedChange: Codable, Equatable, Sendable {
    public let displayUUID: UUID
    public let originalHDR: Bool
    public let configurationFingerprint: String
    public let createdAt: Date
}

struct SystemHDRDisplaySnapshot: Equatable, Sendable {
    let displayID: UInt32
    let displayUUID: UUID
    let supportsHDR: Bool
    let prefersHDR: Bool
    let isBuiltin: Bool
    let configurationFingerprint: String
}

@MainActor protocol SystemHDRDisplayBackend: AnyObject {
    func displays() throws -> [SystemHDRDisplaySnapshot]
    func setHDR(_ enabled: Bool, displayUUID: UUID) throws
}

@MainActor protocol SystemHDRJournal: AnyObject {
    func load() throws -> [SystemHDRInterruptedChange]
    func save(_ records: [SystemHDRInterruptedChange]) throws
}

/// No OS access: production and tests supply the same display/journal boundary.
/// All owners of one display share one original preference and one restore.
@MainActor final class SystemHDRLeaseCoordinator {
    private enum Phase {
        case waitingToEnable, enabling(until: TimeInterval), active, waitingToRestore, restoring(until: TimeInterval), overridden, failed
    }
    private struct Lease {
        let original: SystemHDRDisplaySnapshot
        var owners: Set<UUID>
        var changedByUs = false
        var phase: Phase
    }

    private let backend: any SystemHDRDisplayBackend
    private let journal: any SystemHDRJournal
    private let now: () -> Date
    private let uptime: () -> TimeInterval
    private var leases: [UUID: Lease] = [:]
    private var ownerDisplays: [UUID: UUID] = [:]
    private var records: [UUID: SystemHDRInterruptedChange] = [:]
    private var interrupted: [UUID: SystemHDRInterruptedChange] = [:]
    private var latest: [UUID: SystemHDRDisplaySnapshot] = [:]
    private var readFailed = false
    private var applying = false

    var prepareForDisplayChange: ((SystemHDRTransition) -> Bool)?
    var didRequestDisplayChange: ((SystemHDRTransition) -> Void)?
    var didUpdate: (() -> Void)?
    var pendingRecovery: [SystemHDRInterruptedChange] {
        interrupted.values.sorted { $0.displayUUID.uuidString < $1.displayUUID.uuidString }
    }
    var hasWork: Bool {
        leases.values.contains {
            switch $0.phase {
            case .waitingToEnable, .enabling, .waitingToRestore, .restoring: return true
            case .active, .overridden, .failed: return false
            }
        }
    }

    func observedHDR(for uuid: UUID) -> Bool? { readFailed ? nil : latest[uuid]?.prefersHDR }

    /// Read-only observation, refreshed by update/refresh. This does not create a
    /// lease, including when the user's HDR preference is already enabled.
    func observedHDR(forDisplayID displayID: UInt32?) -> Bool? {
        guard !readFailed, let displayID else { return nil }
        return latest.values.first { $0.displayID == displayID }?.prefersHDR
    }

    func rejectPendingTransition(_ transition: SystemHDRTransition) {
        guard let lease = leases[transition.displayUUID] else { return }
        switch lease.phase {
        case .waitingToEnable where transition.enabling: break
        case .waitingToRestore where !transition.enabling: break
        default: return // A stale preparation must not revoke a newer decision.
        }
        abandon(uuid: transition.displayUUID, lease: lease, preserveRecovery: lease.changedByUs, failed: true)
    }

    init(backend: any SystemHDRDisplayBackend, journal: any SystemHDRJournal,
         now: @escaping () -> Date = Date.init,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.backend = backend
        self.journal = journal
        self.now = now
        self.uptime = uptime
        // Never restore on startup merely because a preference still reads ON.
        for record in (try? journal.load()) ?? [] { interrupted[record.displayUUID] = record }
    }

    @discardableResult
    func update(ownerID: UUID, displayID: UInt32?, wantsHDR: Bool) -> SystemHDRStatus {
        guard !applying else { return status(ownerID: ownerID) }
        refresh()
        if readFailed {
            if !wantsHDR { releaseOwner(ownerID: ownerID) }
            return wantsHDR ? .unavailable : .inactive
        }
        guard wantsHDR, let displayID,
              let display = latest.values.first(where: { $0.displayID == displayID }) else {
            releaseOwner(ownerID: ownerID)
            return wantsHDR ? .unavailable : .inactive
        }
        if ownerDisplays[ownerID] != display.displayUUID { releaseOwner(ownerID: ownerID) }
        if display.isBuiltin { return .nativeEDR }
        guard display.supportsHDR else { return .unavailable }
        let uuid = display.displayUUID
        if var lease = leases[uuid] {
            lease.owners.insert(ownerID)
            leases[uuid] = lease
        } else {
            // An interrupted record is not adopted: keeping an already-ON
            // display ON must not grant ownership of the user's new preference.
            leases[uuid] = Lease(original: display, owners: [ownerID],
                                 phase: display.prefersHDR ? .active : .waitingToEnable)
        }
        ownerDisplays[ownerID] = uuid
        advance(uuid: uuid)
        return status(ownerID: ownerID)
    }

    func status(ownerID: UUID) -> SystemHDRStatus {
        guard let uuid = ownerDisplays[ownerID], let lease = leases[uuid] else { return .inactive }
        if readFailed { return .unavailable }
        switch lease.phase {
        case .waitingToEnable: return .waitingForAudio
        case .enabling, .waitingToRestore, .restoring: return .requesting
        case .active: return lease.changedByUs ? .enabledTemporarily : .alreadyEnabled
        case .overridden: return .userOverride
        case .failed: return readFailed ? .unavailable : .failed
        }
    }

    func release(ownerID: UUID) {
        guard ownerDisplays[ownerID] != nil else { return }
        if !applying { refresh() }
        releaseOwner(ownerID: ownerID)
    }

    // update() already read the displays. Reuse that snapshot when an owner
    // stops requesting HDR or changes screens instead of enumerating twice.
    private func releaseOwner(ownerID: UUID) {
        guard let uuid = ownerDisplays.removeValue(forKey: ownerID), var lease = leases[uuid] else { return }
        lease.owners.remove(ownerID)
        leases[uuid] = lease
        guard lease.owners.isEmpty else { return }
        if lease.changedByUs {
            // The enable request may still be in flight. Wait for it before
            // restoring, instead of declaring success from the old OFF value.
            if case .enabling = lease.phase { return }
            lease.phase = .waitingToRestore
            leases[uuid] = lease
            advance(uuid: uuid)
        } else {
            leases.removeValue(forKey: uuid)
        }
    }

    func restoreAll() {
        for owner in Array(ownerDisplays.keys) { release(ownerID: owner) }
        refresh()
    }

    func refresh() {
        guard !applying else { return }
        let previousDisplays = latest
        let statusesBefore = Dictionary(uniqueKeysWithValues: ownerDisplays.keys.map { ($0, status(ownerID: $0)) })
        let recoveryBefore = pendingRecovery
        do {
            let displays = try backend.displays()
            latest = Dictionary(displays.map { ($0.displayUUID, $0) }, uniquingKeysWith: { first, _ in first })
            readFailed = false
        } catch {
            let changed = !readFailed
            readFailed = true
            if changed { didUpdate?() }
            return // A transient read failure never authorizes a write/restore.
        }
        for (uuid, record) in interrupted {
            if let display = latest[uuid], !display.prefersHDR
                || display.configurationFingerprint != record.configurationFingerprint {
                interrupted.removeValue(forKey: uuid)
                persistBestEffort()
            }
        }
        for uuid in Array(leases.keys) { advance(uuid: uuid) }
        let statusesAfter = Dictionary(uniqueKeysWithValues: ownerDisplays.keys.map { ($0, status(ownerID: $0)) })
        if previousDisplays != latest || statusesBefore != statusesAfter || recoveryBefore != pendingRecovery { didUpdate?() }
    }

    /// Explicit UI action, never called automatically from init or refresh.
    @discardableResult
    func restoreInterruptedChange(displayUUID: UUID) -> Bool {
        guard !applying else { return false }
        refresh()
        guard !readFailed, let record = interrupted[displayUUID],
              let display = latest[displayUUID], !display.isBuiltin,
              display.configurationFingerprint == record.configurationFingerprint,
              leases[displayUUID]?.changedByUs != true,
              leases[displayUUID]?.owners.isEmpty != false else { return false }
        if display.prefersHDR == record.originalHDR {
            interrupted.removeValue(forKey: displayUUID)
            persistBestEffort()
            return true
        }
        let transition = SystemHDRTransition(displayID: display.displayID, displayUUID: displayUUID, enabling: record.originalHDR)
        guard prepareForDisplayChange?(transition) != false else { return false }
        applying = true
        defer { applying = false }
        do {
            try backend.setHDR(record.originalHDR, displayUUID: displayUUID)
            didRequestDisplayChange?(transition)
            // Keep the journal until a readback confirms the original state.
            return true
        } catch { return false }
    }

    private func advance(uuid: UUID) {
        guard !readFailed, !applying, var lease = leases[uuid] else { return }
        guard let display = latest[uuid] else {
            // Detachment invalidates CGDisplayID. Keep a recovery record but
            // relinquish control; never apply it to a newly attached display.
            abandon(uuid: uuid, lease: lease, preserveRecovery: lease.changedByUs)
            return
        }
        guard display.configurationFingerprint == lease.original.configurationFingerprint else {
            abandon(uuid: uuid, lease: lease, preserveRecovery: false)
            return
        }
        switch lease.phase {
        case .overridden, .failed: return
        case .active:
            guard display.prefersHDR else {
                abandon(uuid: uuid, lease: lease, preserveRecovery: false)
                return
            }
        case .waitingToEnable:
            if display.prefersHDR { // Somebody else enabled it before our write.
                abandon(uuid: uuid, lease: lease, preserveRecovery: false)
                return
            }
            guard !lease.owners.isEmpty else { leases.removeValue(forKey: uuid); return }
            submit(enabling: true, uuid: uuid, lease: lease, display: display)
        case .enabling(let deadline):
            if display.prefersHDR {
                lease.phase = lease.owners.isEmpty ? .waitingToRestore : .active
                leases[uuid] = lease
                if lease.owners.isEmpty { advance(uuid: uuid) }
            } else if uptime() >= deadline {
                abandon(uuid: uuid, lease: lease, preserveRecovery: true, failed: true)
            }
        case .waitingToRestore:
            if !display.prefersHDR {
                finishRestore(uuid: uuid, lease: lease)
            } else {
                submit(enabling: lease.original.prefersHDR, uuid: uuid, lease: lease, display: display)
            }
        case .restoring(let deadline):
            if display.prefersHDR == lease.original.prefersHDR {
                finishRestore(uuid: uuid, lease: lease)
            } else if uptime() >= deadline {
                abandon(uuid: uuid, lease: lease, preserveRecovery: true, failed: true)
            }
        }
    }

    private func submit(enabling: Bool, uuid: UUID, lease: Lease, display: SystemHDRDisplaySnapshot) {
        let transition = SystemHDRTransition(displayID: display.displayID, displayUUID: uuid, enabling: enabling)
        applying = true
        defer { applying = false }
        guard prepareForDisplayChange?(transition) != false else { return }
        // A synchronous notification/callback may have released an owner.
        guard var changed = leases[uuid], !enabling || !changed.owners.isEmpty else { return }
        do {
            if enabling {
                records[uuid] = SystemHDRInterruptedChange(displayUUID: uuid,
                    originalHDR: lease.original.prefersHDR,
                    configurationFingerprint: lease.original.configurationFingerprint, createdAt: now())
                // A failed durable journal write must prevent enabling HDR.
                try persist()
            }
            try backend.setHDR(enabling, displayUUID: uuid)
            changed.changedByUs = true
            changed.phase = enabling ? .enabling(until: uptime() + 4) : .restoring(until: uptime() + 4)
            leases[uuid] = changed
            didRequestDisplayChange?(transition)
        } catch {
            // A throwing private setter could have partially succeeded. Keep
            // ambiguous state for explicit recovery and suppress automatic retry.
            abandon(uuid: uuid, lease: changed, preserveRecovery: records[uuid] != nil, failed: true)
        }
    }

    private func abandon(uuid: UUID, lease: Lease, preserveRecovery: Bool, failed: Bool = false) {
        if let record = records.removeValue(forKey: uuid), preserveRecovery { interrupted[uuid] = record }
        var abandoned = lease
        abandoned.changedByUs = false
        abandoned.phase = failed ? .failed : .overridden
        if abandoned.owners.isEmpty { leases.removeValue(forKey: uuid) }
        else { leases[uuid] = abandoned }
        persistBestEffort()
    }

    private func finishRestore(uuid: UUID, lease: Lease) {
        records.removeValue(forKey: uuid)
        persistBestEffort()
        if lease.owners.isEmpty { leases.removeValue(forKey: uuid) }
        else {
            var next = lease
            next.changedByUs = false
            next.phase = .waitingToEnable
            leases[uuid] = next
        }
    }

    private func persist() throws { try journal.save(Array(records.values) + Array(interrupted.values)) }
    private func persistBestEffort() { try? persist() }
}
