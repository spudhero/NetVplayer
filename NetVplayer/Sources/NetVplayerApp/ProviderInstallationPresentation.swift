import Foundation
import Models
import ProviderRuntime
import ProviderSDK

struct ProviderInstallationRow: Equatable, Identifiable {
    enum Status: Equatable {
        case queued
        case installing(ProviderInstallProgress)
        case ready
        case failed(String)
    }

    let id: ProviderVersionReference
    var status: Status
}

/// Installation state outlives SettingsView so navigation cannot discard progress or a manual disclosure choice.
struct ProviderInstallationPresentation: Equatable {
    enum Phase: Equatable {
        case idle
        case fetchingCatalog
        case installing
        case completed
        case failed(String)
    }

    private(set) var sessionID: UUID?
    private(set) var isInitialInstallation = false
    private(set) var phase: Phase = .idle
    private(set) var rows: [ProviderInstallationRow] = []
    private(set) var detailsExpanded = false
    private(set) var hasManualDisclosureChoice = false
    private var hasPresentedInitialInstallation = false

    var readyCount: Int { rows.filter { $0.status == .ready }.count }

    var shouldShowNetworkHint: Bool {
        isInitialInstallation && phase != .completed && phase != .idle
    }

    /// Returns whether the app should navigate to extension settings. Retries never take navigation back.
    @discardableResult
    mutating func begin(sessionID: UUID = UUID(), isInitialInstallation: Bool, retrying release: ProviderVersionReference? = nil) -> Bool {
        self.sessionID = sessionID
        self.isInitialInstallation = isInitialInstallation
        if let release {
            phase = .installing
            rows.removeAll { $0.id.providerID == release.providerID && $0.id != release }
            setStatus(.queued, for: release)
        } else {
            phase = .fetchingCatalog
            rows = []
        }

        guard isInitialInstallation, !hasPresentedInitialInstallation else { return false }
        hasPresentedInitialInstallation = true
        if !hasManualDisclosureChoice { detailsExpanded = true }
        return true
    }

    mutating func receiveCatalog(_ releases: [ProviderRelease], installedVersions: [String: String], sessionID: UUID) {
        guard self.sessionID == sessionID else { return }
        rows = releases.map { release in
            let reference = ProviderVersionReference(providerID: release.providerID, version: release.version)
            return ProviderInstallationRow(
                id: reference,
                status: Self.isInstalled(reference, versions: installedVersions) ? .ready : .queued
            )
        }
        phase = .installing
    }

    mutating func receiveProgress(_ progress: ProviderInstallProgress, sessionID: UUID) {
        guard self.sessionID == sessionID, progress.phase != .fetchingCatalog else { return }
        let reference = ProviderVersionReference(providerID: progress.providerID, version: progress.version)
        setStatus(progress.phase == .completed ? .ready : .installing(progress), for: reference)
    }

    mutating func receiveFailure(_ reference: ProviderVersionReference, message: String, sessionID: UUID) {
        guard self.sessionID == sessionID else { return }
        setStatus(.failed(message), for: reference)
    }

    /// A download/handshake completion is provisional until final registration confirms the component is available.
    mutating func reconcileInstalledVersions(_ versions: [String: String], sessionID: UUID) {
        guard self.sessionID == sessionID else { return }
        for index in rows.indices {
            if case .failed = rows[index].status { continue }
            rows[index].status = Self.isInstalled(rows[index].id, versions: versions)
                ? .ready
                : .failed(L10n.text("组件未能启用，请重试。"))
        }
    }

    @discardableResult
    mutating func finish(succeeded: Bool, message: String, sessionID: UUID) -> Bool {
        guard self.sessionID == sessionID else { return false }
        phase = succeeded ? .completed : .failed(message)
        return succeeded && isInitialInstallation && detailsExpanded && !hasManualDisclosureChoice
    }

    mutating func setDetailsExpanded(_ expanded: Bool) {
        hasManualDisclosureChoice = true
        detailsExpanded = expanded
    }

    mutating func collapseAfterSuccess(sessionID: UUID) {
        guard self.sessionID == sessionID, phase == .completed,
              isInitialInstallation, !hasManualDisclosureChoice else { return }
        detailsExpanded = false
    }

    mutating func clear() {
        sessionID = nil
        phase = .idle
        rows = []
        isInitialInstallation = false
        if !hasManualDisclosureChoice { detailsExpanded = false }
    }

    private mutating func setStatus(_ status: ProviderInstallationRow.Status, for reference: ProviderVersionReference) {
        if let index = rows.firstIndex(where: { $0.id == reference }) {
            rows[index].status = status
        } else {
            rows.append(ProviderInstallationRow(id: reference, status: status))
        }
    }

    private static func isInstalled(_ reference: ProviderVersionReference, versions: [String: String]) -> Bool {
        versions[reference.providerID].map {
            ProviderManifestVerifier.compareVersions($0, reference.version) >= 0
        } ?? false
    }
}
