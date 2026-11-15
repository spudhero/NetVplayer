#if DEBUG
import AppKit
import Combine
import Diagnostics
import Storage
import Models
import MediaLibraryEngine

/// Explicit, local-only native verification. Never arms a crash in a normal launch.
@MainActor
final class StartupRecoveryProbe {
    static let current: StartupRecoveryProbe? = {
        guard let path = ProcessInfo.processInfo.environment["NETVPLAYER_STARTUP_PROBE_ROOT"],
              path.hasPrefix("/private/tmp/ov87-startup-") else { return nil }
        return StartupRecoveryProbe(root: URL(fileURLWithPath: path))
    }()
    let root: URL
    private var observation: AnyCancellable?
    private var constructions = 0
    private var scanObservation: AnyCancellable?
    private var taskObservation: AnyCancellable?
    private(set) var scanState: FileServicesState?
    private init(root: URL) { self.root = root }

    func checkInitialization() {
        if ProcessInfo.processInfo.environment["NETVPLAYER_STARTUP_PROBE_MODE"] == "crash" {
            fatalError("OV87 isolated early AppState initialization crash")
        }
    }

    func makeCoordinator() -> AppStartupCoordinator {
        let suite = "netvplayer.startup.probe." + root.lastPathComponent
        let defaults = UserDefaults(suiteName: suite)!
        // This isolated suite, not the user's preference, opts out of remote events.
        defaults.set(false, forKey: DiagnosticReportingConfiguration.preferenceKey)
        let diagnostics = SentryDiagnostics(defaults: defaults)
        let coordinator = AppStartupCoordinator(
            store: StartupSessionStore(url: root.appendingPathComponent("session.json")),
            startDiagnostics: { diagnostics.start(); return diagnostics.startupSnapshot },
            setDiagnosticsEnabled: { _ in diagnostics.startupSnapshot },
            stopDiagnostics: { diagnostics.stop() },
            factory: { choice in
                let mode = ProcessInfo.processInfo.environment["NETVPLAYER_STARTUP_PROBE_MODE"]
                if mode == "fail" { throw ProbeFailure.initialization }
                self.constructions += 1
                let state = AppState(loadDefaultConfig: false, startProxyServer: false,
                                startProviderRuntime: false,
                                deferStartupRestoration: choice == .deferRestoration,
                                storageManager: StorageManager(storageDirectory: self.root.appendingPathComponent("library")),
                                userPreferences: UserPreferences(defaults: defaults), providerRuntimeBootstrap: nil)
                if mode == "drive-recovery" || mode == "task-diagnostics" { state.showsDriveTaskRecovery = true }
                  if mode == "scan-recovery" || mode == "task-diagnostics" {
                      let storage = StorageManager(storageDirectory: self.root.appendingPathComponent("scan-state"))
                      let store = FileServiceStore(storage: storage,
                          preferences: UserPreferences(defaults: defaults, credentialStore: MemoryCredentialStore()))
                      // Explicit fixture preparation uses this app's security-scope identity.
                      // It is separate from the ordinary read-only launch/reopen verification.
                      if ProcessInfo.processInfo.environment["NETVPLAYER_STARTUP_PROBE_PREPARE_SCAN_BOOKMARK"] == "1",
                           (self.root.path.hasPrefix("/private/tmp/ov87-startup-msc05-") || self.root.path.hasPrefix("/private/tmp/ov87-startup-msc06-") || self.root.path.hasPrefix("/private/tmp/ov87-startup-msc07-")),
                         let service = store.load().services.first, service.kind == .local {
                          let folder = self.root.appendingPathComponent("media", isDirectory: true)
                          guard folder.resolvingSymlinksInPath().path.hasPrefix(self.root.resolvingSymlinksInPath().path + "/") else {
                              throw ProbeFailure.initialization
                          }
                          let bookmark = try folder.bookmarkData(options: [.withSecurityScope],
                              includingResourceValuesForKeys: nil, relativeTo: nil)
                          try storage.save([service.id.uuidString: bookmark], to: "file-service-bookmarks.json")
                      }
                      let index = MediaIndex(url: self.root.appendingPathComponent("scan-index.sqlite"))
                      let scanner = MediaLibraryScanner(index: index, store: store, diagnostics: state.taskDiagnosticStore)
                      let files = FileServicesState(index: index, store: store, scanner: scanner)
                      self.scanState = files
                      self.scanObservation = files.objectWillChange.sink { [weak self, weak files] in
                          Task { @MainActor in
                              await Task.yield()
                              guard let self, let files else { return }
                              let checkpoint = files.selectedScanCheckpoint
                              var summary: [String: Any] = ["scanProgressEvents": files.scanProgress.count,
                                  "running": files.isRefreshing, "visibleRecords": files.mediaRecords.count,
                                  "checkpointPresent": checkpoint != nil, "checkpointError": files.scanCheckpointError != nil]
                              if let checkpoint {
                                  summary["phase"] = checkpoint.phase.rawValue
                                  summary["checkpointID"] = checkpoint.id.uuidString
                                  summary["failedDirectories"] = checkpoint.failedDirectories
                                  summary["canContinue"] = files.canContinueScan(checkpoint)
                                  summary["revisionMatches"] = files.scanCheckpointMatchesConfiguration(checkpoint)
                              }
                              if let library = files.selectedLibrary {
                                  summary["configurationRevision"] = try? MediaLibraryScanner.configurationRevision(library, store: store)
                              }
                              if let data = try? JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]) {
                                  try? data.write(to: self.root.appendingPathComponent("observed-scan.json"), options: .atomic)
                              }
                          }
                      }
                      if let service = store.load().services.first { files.selectService(service.id) }
                  }
                if mode == "task-diagnostics" {
                    self.taskObservation = state.objectWillChange.sink { [weak self, weak state] in
                        Task { @MainActor in
                            await Task.yield()
                            guard let self, let state else { return }
                            let summary: [String: Any] = ["historyCount": state.recentTaskDiagnostics.count,
                                "states": state.recentTaskDiagnostics.map { $0.latest.state.rawValue },
                                "kinds": state.recentTaskDiagnostics.map { $0.kind.rawValue },
                                "recoveryOperations": state.driveRecoveryOperations.count,
                                "recoveryCount": state.driveTaskSummaries.count]
                            if let data = try? JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]) {
                                try? data.write(to: self.root.appendingPathComponent("observed-tasks.json"), options: .atomic)
                            }
                        }
                    }
                }
                return state
            },
            cleanup: { try await $0.prepareForApplicationTermination() },
            onTerminationRequested: { $0.beginApplicationTermination() }
        )
        observation = coordinator.$phase.sink { [weak self, weak coordinator] phase in
            Task { @MainActor in
                guard let self, let coordinator else { return }
                var snapshot: [String: Any] = ["phase": String(describing: phase),
                    "constructions": self.constructions, "hasRuntime": coordinator.runtime != nil,
                    "pendingFiles": coordinator.pendingFiles.count,
                    "diagnostics": coordinator.diagnostics.state.rawValue]
                if let runtime = coordinator.runtime {
                    snapshot["transferTaskCount"] = runtime.driveTaskSummaries.count
                    snapshot["transferTasksRequiringReview"] = runtime.driveTaskSummaries.filter(\.canContinue).count
                    snapshot["transferTasksCancelled"] = runtime.driveTaskSummaries.filter(\.cancelled).count
                    snapshot["transferRecoveryOperations"] = runtime.driveRecoveryOperations.count
                    snapshot["transferStorageFailed"] = runtime.driveTaskStorageFailed
                }
                if let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]) {
                    try? data.write(to: self.root.appendingPathComponent("observed.json"), options: .atomic)
                }
            }
        }
        return coordinator
    }
    private enum ProbeFailure: Error { case initialization }
}
#endif
