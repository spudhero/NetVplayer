import Foundation
import Combine
import Diagnostics

enum StartupPhase: Equatable {
    case idle, recovery, starting, ready, failed, terminating, terminationFailed, stopped
}

enum StartupRestorationChoice { case restore, deferRestoration }

/// Owns the only business factory. Views, menus and delegate callbacks only read this owner.
@MainActor
final class StartupCoordinator<Runtime>: ObservableObject {
    @Published private(set) var phase: StartupPhase = .idle
    @Published private(set) var runtime: Runtime?
    @Published private(set) var failure: String?
    @Published private(set) var pendingFiles: [URL] = []
    @Published private(set) var rejectedFileCount = 0
    @Published private(set) var diagnostics = StartupDiagnosticsSnapshot(state: .inactive, crashedLastRun: false)
    private(set) var recoveryPending = false
    private var prepared = false
    private var startupTask: Task<Void, Never>?
    private var terminationTask: Task<Bool, Never>?
    private let store: StartupSessionStore?
    private let startDiagnostics: () -> StartupDiagnosticsSnapshot
    private let setDiagnosticsEnabled: (Bool) -> StartupDiagnosticsSnapshot
    private let stopDiagnostics: () -> Void
    private let factory: @MainActor (StartupRestorationChoice) async throws -> Runtime
    private let validate: (Runtime) throws -> Void
    private let cleanup: @MainActor (Runtime) async throws -> Void
    private let onReady: (Runtime) -> Void
    private let onTerminationRequested: (Runtime) -> Void

    init(store: StartupSessionStore?,
         startDiagnostics: @escaping () -> StartupDiagnosticsSnapshot = { .init(state: .inactive, crashedLastRun: false) },
         setDiagnosticsEnabled: @escaping (Bool) -> StartupDiagnosticsSnapshot = { _ in .init(state: .inactive, crashedLastRun: false) },
         stopDiagnostics: @escaping () -> Void = {},
         factory: @escaping @MainActor (StartupRestorationChoice) async throws -> Runtime,
         validate: @escaping (Runtime) throws -> Void = { _ in },
         cleanup: @escaping @MainActor (Runtime) async throws -> Void,
         onReady: @escaping (Runtime) -> Void = { _ in },
         onTerminationRequested: @escaping (Runtime) -> Void = { _ in }) {
        self.store = store
        self.startDiagnostics = startDiagnostics
        self.setDiagnosticsEnabled = setDiagnosticsEnabled
        self.stopDiagnostics = stopDiagnostics
        self.factory = factory
        self.validate = validate
        self.cleanup = cleanup
        self.onReady = onReady
        self.onTerminationRequested = onTerminationRequested
    }

    func prepare() {
        guard !prepared else { return }
        prepared = true
        do {
            recoveryPending = try store?.needsRecovery() ?? false
            // Persist before even starting diagnostics; a crash in setup is recoverable too.
            try store?.write(.preparing, recoveryPending: recoveryPending)
            diagnostics = startDiagnostics()
            recoveryPending = recoveryPending || diagnostics.crashedLastRun
            if recoveryPending {
                try store?.write(.recovery, recoveryPending: true)
                phase = .recovery
            }
        } catch {
            recoveryPending = true
            fail("无法保存启动状态，请检查本机存储空间和权限，然后退出重试。")
        }
    }

    func startIfNeeded() {
        prepare()
        guard phase == .idle else { return }
        start(.restore)
    }

    func start(_ choice: StartupRestorationChoice) {
        prepare()
        guard phase == .idle || phase == .recovery else { return }
        phase = .starting
        startupTask = Task { @MainActor in
            // Let the starting state render and allow termination before constructing services.
            await Task.yield()
            guard self.phase == .starting, !Task.isCancelled else { return }
            do {
                try self.store?.write(.starting, recoveryPending: self.recoveryPending)
                let runtime = try await self.factory(choice)
                self.runtime = runtime // Retain even a failed/late result so termination cleans it.
                guard self.phase == .starting, !Task.isCancelled else { return }
                try self.validate(runtime)
                try self.store?.write(.ready, recoveryPending: false)
                self.recoveryPending = false
                self.phase = .ready
                self.onReady(runtime)
            } catch {
                guard self.phase == .starting else { return }
                self.recoveryPending = true
                try? self.store?.write(.failed, recoveryPending: true)
                self.fail("应用初始化未完成。请退出后重试，并可选择暂缓恢复上次状态。")
            }
        }
    }

    /// Keep the first eight distinct local requests; no reads or playback while recovering.
    func enqueue(_ urls: [URL]) {
        guard ![.terminating, .terminationFailed, .stopped].contains(phase) else { return }
        for url in urls {
            guard url.isFileURL, url.absoluteString.utf8.count <= 4096 else {
                rejectedFileCount = min(999, rejectedFileCount + 1)
                continue
            }
            let normalized = url.standardizedFileURL
            guard !pendingFiles.contains(normalized) else { continue }
            guard pendingFiles.count < 8 else {
                rejectedFileCount = min(999, rejectedFileCount + 1)
                continue
            }
            pendingFiles.append(normalized)
        }
    }

    func takeFile(_ url: URL) -> URL? {
        guard phase == .ready, let index = pendingFiles.firstIndex(of: url) else { return nil }
        return pendingFiles.remove(at: index)
    }

    func discardFiles() { pendingFiles.removeAll(); rejectedFileCount = 0 }

    func changeDiagnosticsEnabled(_ enabled: Bool) {
        guard ![.terminating, .stopped].contains(phase) else { return }
        diagnostics = setDiagnosticsEnabled(enabled)
    }

    /// Repeated quit requests join one cleanup. No timeout is reported as successful cleanup.
    func terminate() -> Task<Bool, Never> {
        if let terminationTask { return terminationTask }
        // Persist playback progress before changing phase removes the player view.
        if let runtime { onTerminationRequested(runtime) }
        phase = .terminating
        failure = nil
        discardFiles()
        startupTask?.cancel()
        let task = Task { @MainActor in
            await self.startupTask?.value
            // Failure to persist "terminating" must not prevent actual cleanup.
            try? self.store?.write(.terminating, recoveryPending: self.recoveryPending)
            do {
                if let runtime = self.runtime { try await self.cleanup(runtime) }
                self.stopDiagnostics()
                self.diagnostics = .init(state: .inactive, crashedLastRun: self.diagnostics.crashedLastRun)
                // If storage became unavailable, leave the old marker for next-launch recovery.
                // Cleanup completed; inability to write a receipt must not trap the app open.
                try? self.store?.write(.clean, recoveryPending: self.recoveryPending)
                self.runtime = nil
                self.phase = .stopped
                return true
            } catch {
                self.phase = .terminationFailed
                self.failure = "清理尚未完成，应用仍在运行。请重试退出。"
                self.terminationTask = nil
                return false
            }
        }
        terminationTask = task
        return task
    }

    func waitForStartup() async { await startupTask?.value }

    private func fail(_ key: String) { failure = key; phase = .failed }
}
