import CryptoKit
import Darwin
import Foundation
import ProviderRuntime
import ProviderSDK

public enum AndroidRuntimeComponentError: LocalizedError, Equatable {
    case invalidPackage, invalidSelection, busy, noPreviousVersion, launchFailed

    public var errorDescription: String? {
        switch self {
        case .invalidPackage: return "Android 原版组件不完整、签名无效或与当前版本不兼容。"
        case .invalidSelection: return "Android 原版组件选择记录损坏，请重新安装组件。"
        case .busy: return "另一个组件安装正在进行，请稍后重试。"
        case .noPreviousVersion: return "没有可以回滚的原版组件版本。"
        case .launchFailed: return "Android 原版组件启动验证失败，当前版本未更改。"
        }
    }
}

/// Uses the same manifest trust root and asset verifier as signed Providers, but
/// keeps the original host out of per-site Provider registration/maintenance.
public actor AndroidRuntimeComponentStore {
    public static let providerID = "android-original-runtime"
    public static var defaultRoot: URL {
        if CommandLine.arguments.contains("--android-provider-audit"),
           let path = ProcessInfo.processInfo.environment["NETVPLAYER_ANDROID_COMPONENT_ROOT"], path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NetVplayer/AndroidOriginalComponents", isDirectory: true)
    }
    public struct Status: Sendable {
        public let version: String?
        public let previousVersion: String?
    }
    private struct Selection: Codable {
        let schema: Int
        let active: String
        let previous: String?
    }
    private let root: URL
    private let verifier: ProviderManifestVerifier
    private let packages: ProviderPackageStore
    private let probe: @Sendable (URL) throws -> Void

    public static func application(bundle: Bundle = .main) throws -> AndroidRuntimeComponentStore {
        let trust = try ProviderTrustConfiguration.load(bundle: bundle)
        return AndroidRuntimeComponentStore(root: defaultRoot,
            verifier: try trust.manifestVerifier(shellVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"))
    }

    public init(root: URL, verifier: ProviderManifestVerifier) {
        self.root = root
        self.verifier = verifier
        self.packages = ProviderPackageStore(rootURL: root.appendingPathComponent("versions"), verifier: verifier)
        self.probe = Self.probeRuntime
    }

    // Inject only the platform launch probe in behavioral fixtures. Signature,
    // complete-tree validation, staging and selection transactions are real.
    init(root: URL, verifier: ProviderManifestVerifier, probe: @escaping @Sendable (URL) throws -> Void) {
        self.root = root
        self.verifier = verifier
        self.packages = ProviderPackageStore(rootURL: root.appendingPathComponent("versions"), verifier: verifier)
        self.probe = probe
    }

    public func status() throws -> Status {
        guard let selection = try readSelection() else { return Status(version: nil, previousVersion: nil) }
        _ = try verifiedRuntime(at: packageURL(selection.active), version: selection.active)
        return Status(version: selection.active, previousVersion: selection.previous)
    }

    public func previousVersion() throws -> String? {
        guard let previous = try readSelection()?.previous else { return nil }
        _ = try verifiedRuntime(at: packageURL(previous), version: previous)
        return previous
    }

    func activeRuntime() throws -> DevelopmentAndroidRuntimeLayout? {
        guard let selection = try readSelection() else { return nil }
        return try verifiedRuntime(at: packageURL(selection.active), version: selection.active)
    }

    /// Import an extracted signed component directory. No network or business
    /// init runs during installation. Failed imports leave the selection intact.
    public func install(directory: URL) async throws -> Status {
        try Task.checkCancellation()
        let lock = try acquireLock()
        defer { flock(lock, LOCK_UN); close(lock) }
        let document = try document(at: directory)
        _ = try verifiedRuntime(at: directory, version: document.manifest.version)
        let installed = try await packages.install(packageDirectory: directory, document: document)
        _ = try verifiedRuntime(at: installed, version: document.manifest.version)
        try probe(installed.appendingPathComponent("AndroidProviderRuntime"))
        // A damaged selection can be repaired by a verified explicit install;
        // it cannot introduce an unverified previous version.
        let old = try? readSelection()
        let version = document.manifest.version
        var previous: String?
        if let old, old.active == version { previous = old.previous }
        else if let old, (try? verifiedRuntime(at: packageURL(old.active), version: old.active)) != nil { previous = old.active }
        try Task.checkCancellation()
        try writeSelection(Selection(schema: 1, active: version, previous: previous))
        return Status(version: version, previousVersion: previous)
    }

    public func rollback() throws -> Status {
        let lock = try acquireLock()
        defer { flock(lock, LOCK_UN); close(lock) }
        guard let selection = try readSelection(), let previous = selection.previous else {
            throw AndroidRuntimeComponentError.noPreviousVersion
        }
        _ = try verifiedRuntime(at: packageURL(previous), version: previous)
        try probe(packageURL(previous).appendingPathComponent("AndroidProviderRuntime"))
        // A corrupt current version is not advertised as a valid future rollback.
        let currentValid = (try? verifiedRuntime(at: packageURL(selection.active), version: selection.active)) != nil
        try writeSelection(Selection(schema: 1, active: previous, previous: currentValid ? selection.active : nil))
        return Status(version: previous, previousVersion: currentValid ? selection.active : nil)
    }

    private func verifiedRuntime(at directory: URL, version: String) throws -> DevelopmentAndroidRuntimeLayout {
        let document = try document(at: directory)
        let m = document.manifest
        guard m.providerID == Self.providerID, Self.validVersion(version), m.version == version,
              m.runtime == .java, m.status == .partial || m.status == .compatible,
              m.entrypoint == "AndroidProviderRuntime/lib/android-adapter.jar",
              m.runner == "AndroidProviderRuntime/lib/java-runner.jar",
              m.runtimeExecutable == "AndroidProviderRuntime/jdk/bin/java",
              m.sourceBindings?.isEmpty ?? true,
              m.macOSMinimumVersion == "14.0", m.protocolVersion == 1,
              !m.assets.isEmpty, m.assets.count <= 15000,
              Set(m.assets.map(\.path)).count == m.assets.count else { throw AndroidRuntimeComponentError.invalidPackage }
        try Self.validateTree(directory, document: document)
        try verifier.verify(document, packageRoot: directory)
        let identity = SHA256.hash(data: try JSONEncoder.providerCanonical.encode(m)).map { String(format: "%02x", $0) }.joined()
        let runtime = try DevelopmentAndroidRuntimeLayout.load(root: directory.appendingPathComponent("AndroidProviderRuntime"), componentIdentity: identity)
        guard (runtime.manifest.schema == 2 || runtime.manifest.schema == 3), runtime.manifest.providerID == Self.providerID else {
            throw AndroidRuntimeComponentError.invalidPackage
        }
        return runtime
    }

    private static func validateTree(_ directory: URL, document: SignedProviderManifest) throws {
        let assets = document.manifest.assets
        let rootValues = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else { throw AndroidRuntimeComponentError.invalidPackage }
        let directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        var actual = Set<String>()
        var bytes: Int64 = 0
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey]) else {
            throw AndroidRuntimeComponentError.invalidPackage
        }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey])
            guard values.isSymbolicLink != true else { throw AndroidRuntimeComponentError.invalidPackage }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else { throw AndroidRuntimeComponentError.invalidPackage }
            let relative = String(url.standardizedFileURL.resolvingSymlinksInPath().path.dropFirst(directory.path.count + 1))
            guard relative.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
                throw AndroidRuntimeComponentError.invalidPackage
            }
            actual.insert(relative)
            guard let size = values.fileSize, (0...512 * 1024 * 1024).contains(size) else { throw AndroidRuntimeComponentError.invalidPackage }
            bytes += Int64(size)
            guard actual.count <= 15001, bytes <= 2 * 1024 * 1024 * 1024 else { throw AndroidRuntimeComponentError.invalidPackage }
        }
        let metadata: Set<String> = ["manifest.json", "signature.ed25519", "SHA256SUMS"]
        guard actual.subtracting(metadata) == Set(assets.map(\.path)).union(["signed-manifest.json"]) else {
            throw AndroidRuntimeComponentError.invalidPackage
        }
        // Distribution archives carry redundant metadata; imported legacy
        // directories may omit it. Any present copy must match the signed data.
        for name in actual.intersection(metadata) {
            let url = directory.appendingPathComponent(name)
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 4 * 1024 * 1024 else {
                throw AndroidRuntimeComponentError.invalidPackage
            }
            let data = try Data(contentsOf: url)
            let valid: Bool
            switch name {
            case "manifest.json":
                let manifest = try JSONDecoder().decode(ProviderManifest.self, from: data)
                valid = try JSONEncoder.providerCanonical.encode(manifest) == JSONEncoder.providerCanonical.encode(document.manifest)
            case "signature.ed25519": valid = data == Data(base64Encoded: document.signature)
            default:
                valid = data == Data(assets.map { $0.sha256 + "  " + $0.path + "\n" }.joined().utf8)
            }
            guard valid else { throw AndroidRuntimeComponentError.invalidPackage }
        }
    }

    private func document(at directory: URL) throws -> SignedProviderManifest {
        let url = directory.appendingPathComponent("signed-manifest.json")
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 4 * 1024 * 1024 else {
            throw AndroidRuntimeComponentError.invalidPackage
        }
        return try JSONDecoder().decode(SignedProviderManifest.self, from: Data(contentsOf: url))
    }

    private func packageURL(_ version: String) -> URL {
        root.appendingPathComponent("versions/" + Self.providerID + "/" + version, isDirectory: true)
    }
    private static func validVersion(_ version: String) -> Bool {
        version.range(of: "\\A[0-9]+\\.[0-9]+\\.[0-9]+\\z", options: .regularExpression) != nil && version.utf8.count < 64
    }
    private func readSelection() throws -> Selection? {
        let file = root.appendingPathComponent("selection.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 4096,
              let selection = try? JSONDecoder().decode(Selection.self, from: Data(contentsOf: file)),
              selection.schema == 1, Self.validVersion(selection.active), selection.previous.map(Self.validVersion) ?? true else {
            throw AndroidRuntimeComponentError.invalidSelection
        }
        return selection
    }
    private func writeSelection(_ selection: Selection) throws {
        try JSONEncoder().encode(selection).write(to: root.appendingPathComponent("selection.json"), options: .atomic)
    }
    private func acquireLock() throws -> Int32 {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw AndroidRuntimeComponentError.invalidPackage }
        for path in ["versions", "versions/" + Self.providerID] {
            let directory = root.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: directory.path) {
                let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { throw AndroidRuntimeComponentError.invalidPackage }
            }
        }
        let fd = open(root.appendingPathComponent(".install-lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw AndroidRuntimeComponentError.busy }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw AndroidRuntimeComponentError.busy }
        return fd
    }
    private static func probeRuntime(_ runtime: URL) throws {
        for relative in ["bin/java", "lib/libjli.dylib", "lib/server/libjvm.dylib"] {
            try run(URL(fileURLWithPath: "/usr/bin/codesign"), ["--verify", "--strict", runtime.appendingPathComponent("jdk/" + relative).path])
        }
        try run(runtime.appendingPathComponent("jdk/bin/java"), ["-version"])
    }
    private static func run(_ executable: URL, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
        try process.run()
        let deadline = Date().addingTimeInterval(15)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { throw AndroidRuntimeComponentError.launchFailed }
    }
}

/// Installation never changes a running process's selected runtime. A settings
/// update/rollback takes effect on restart, retaining old files and state.
actor AndroidRuntimeComponentSession {
    static let shared = AndroidRuntimeComponentSession()
    private var selections: [URL: Task<DevelopmentAndroidRuntimeLayout?, Error>] = [:]
    func cancelPreparation() async {
        for task in selections.values { task.cancel() }
        await AndroidRuntimeBootstrap.shared.cancel()
    }
    func runtime(bundle: Bundle, progress: @escaping AndroidRuntimeBootstrap.Progress = { _ in }) async throws -> DevelopmentAndroidRuntimeLayout? {
        if let cached = selections[bundle.bundleURL] { return try await cached.value }
        // Publish the load before awaiting it: concurrent config loads must all
        // observe one selection, even if settings activates an update meanwhile.
        let load = Task<DevelopmentAndroidRuntimeLayout?, Error> {
            let store = try AndroidRuntimeComponentStore.application(bundle: bundle)
            if !AndroidRuntimeBootstrap.supportsRuntimeVersion(try await store.status().version) {
                try await AndroidRuntimeBootstrap.shared.prepare(bundle: bundle, progress: progress)
            }
            return try await store.activeRuntime()
        }
        selections[bundle.bundleURL] = load
        do {
            let runtime = try await load.value
            if runtime == nil { selections[bundle.bundleURL] = nil }
            return runtime
        } catch {
            // A transient download failure must not poison this process.
            selections[bundle.bundleURL] = nil
            throw error
        }
    }
}
