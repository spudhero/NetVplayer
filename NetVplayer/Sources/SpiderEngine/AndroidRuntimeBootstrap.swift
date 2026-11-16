import Foundation
import Darwin
import ProviderRuntime
import ProviderSDK

/// Installs only the dedicated signed bootstrap, then verifies its assembled
/// output with the ordinary component verifier before changing the selection.
actor AndroidRuntimeBootstrap {
    typealias Progress = @Sendable (String) async -> Void
    typealias Operation = @Sendable (Bundle, @escaping Progress) async throws -> Void
    static let shared = AndroidRuntimeBootstrap()
    static let providerID = AndroidRuntimeComponentStore.providerID
    private let operation: Operation
    private var pending: Task<Void, Error>?

    init(operation: @escaping Operation = { bundle, progress in
        try await AndroidRuntimeBootstrap.install(bundle: bundle, progress: progress)
    }) {
        self.operation = operation
    }

    func prepare(bundle: Bundle = .main, progress: @escaping Progress = { _ in }) async throws {
        if let pending { return try await pending.value }
        let operation = operation
        let task = Task { try await operation(bundle, progress) }
        pending = task
        defer { pending = nil }
        try await task.value
    }

    func cancel() async {
        let task = pending
        task?.cancel()
        _ = await task?.result
    }

    static func install(bundle: Bundle, progress: @escaping Progress,
                        root: URL = AndroidRuntimeComponentStore.defaultRoot,
                        distribution: ProviderDistributionClient = ProviderDistributionClient()) async throws {
        let trust = try ProviderTrustConfiguration.load(bundle: bundle)
        let shellVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let verifier = try trust.manifestVerifier(shellVersion: shellVersion)
        let component = AndroidRuntimeComponentStore(root: root, verifier: verifier)
        if try await component.status().version != nil { return }
        await progress("checking")
        let rawURL = bundle.object(forInfoDictionaryKey: "NetVplayerAndroidRuntimeIndexURL") as? String
            ?? "https://spudhero.github.io/NetVplayer-Provider-Distribution/android/runtime/index.json"
        guard let url = URL(string: rawURL), url.scheme == "https" else {
            throw AndroidRuntimeComponentError.invalidPackage
        }
        let releases = try await distribution.fetchIndex(from: url, verifier: trust.distributionVerifier())
        guard let release = releases.filter({ $0.providerID == providerID &&
            ($0.architectures.contains(ProviderManifestVerifier.currentArchitecture) || $0.architectures.contains("universal2")) }).max(by: {
            ProviderManifestVerifier.compareVersions($0.version, $1.version) < 0
        }) else { throw ProviderRuntimeBootstrapError.releaseNotFound(providerID) }
        await progress("downloading-runtime")
        let downloaded = try await distribution.downloadAndExtract(release)
        do {
            let document = try JSONDecoder().decode(SignedProviderManifest.self,
                from: Data(contentsOf: downloaded.rootURL.appendingPathComponent("signed-manifest.json")))
            guard document.manifest.providerID == providerID, document.manifest.version == release.version,
                  document.manifest.sourcePolicy == .userConfiguredOnly,
                  document.manifest.capabilities.isEmpty, document.manifest.hostCapabilities.isEmpty,
                  document.manifest.sourceBindings?.isEmpty ?? true else {
                throw AndroidRuntimeComponentError.invalidPackage
            }
            await progress("activating")
            // The component store verifies the complete signed tree and probes
            // its bundled JVM. Installation never fetches or assembles dependencies.
            _ = try await component.install(directory: downloaded.rootURL)
            await progress("ready")
        } catch {
            await distribution.removeTemporaryPackage(downloaded)
            throw error
        }
        await distribution.removeTemporaryPackage(downloaded)
    }

    static func runInstaller(installed: URL, assembled: URL, cache: URL,
                                     progress: @escaping Progress) async throws {
        let worker = Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = installed.appendingPathComponent("runtimes/cpython/bin/python3")
            process.arguments = ["-I", "-S", installed.appendingPathComponent("bootstrap.pyc").path,
                                 "--destination", assembled.path, "--cache", cache.path]
            process.currentDirectoryURL = installed
            process.standardInput = FileHandle.nullDevice
            let log = assembled.deletingLastPathComponent().appendingPathComponent("progress.jsonl")
            _ = FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let output = try FileHandle(forWritingTo: log)
            defer { try? output.close() }
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8",
                "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                "TMPDIR": NSTemporaryDirectory(), "SSL_CERT_FILE": "/etc/ssl/cert.pem", "TZ": "UTC"]
            try Task.checkCancellation()
            try process.run()
            defer { terminateInstaller(process) }
            let deadline = Date().addingTimeInterval(15 * 60)
            var lastPhase: String?
            while process.isRunning {
                try Task.checkCancellation()
                guard Date() < deadline else { throw AndroidRuntimeComponentError.launchFailed }
                let data = try Data(contentsOf: log)
                guard data.count <= 64 * 1024 else { throw AndroidRuntimeComponentError.invalidPackage }
                if let line = data.split(separator: 10).last,
                   let event = try? JSONDecoder().decode(BootstrapEvent.self, from: Data(line)),
                   event.phase != lastPhase {
                    lastPhase = event.phase
                    // The installer finishing assembly is not activation.
                    if event.phase != "ready" { await progress(event.phase) }
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                throw AndroidRuntimeComponentError.launchFailed
            }
        }
        try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }

    private struct BootstrapEvent: Decodable { let phase: String }

    private static func terminateInstaller(_ process: Process) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        // The installer creates its own group before starting any children.
        // Never signal an inherited group belonging to the application.
        if getpgid(pid) == pid { kill(-pid, SIGTERM) } else { process.terminate() }
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning {
            if getpgid(pid) == pid { kill(-pid, SIGKILL) } else { kill(pid, SIGKILL) }
        }
    }
}
