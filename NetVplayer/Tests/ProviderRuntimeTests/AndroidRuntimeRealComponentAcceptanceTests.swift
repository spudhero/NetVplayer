import CryptoKit
import Darwin
import Foundation
import Testing
import Models
import ProviderRuntime
import ProviderSDK
@testable import SpiderEngine

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_REAL_COMPONENT_EVIDENCE_DIR"] != nil))
@MainActor
struct AndroidRuntimeRealComponentAcceptanceTests {
    @Test func signedCurrentPackagesInstallUpdateRollbackAndRejectDamageOffline() async throws {
        let env = ProcessInfo.processInfo.environment
        let root = URL(fileURLWithPath: try #require(env["NETVPLAYER_REAL_COMPONENT_EVIDENCE_DIR"]))
        let old = URL(fileURLWithPath: try #require(env["NETVPLAYER_REAL_COMPONENT_PREVIOUS"]))
        let current = URL(fileURLWithPath: try #require(env["NETVPLAYER_REAL_COMPONENT_CURRENT"]))
        let damaged = root.appendingPathComponent("negative-package")
        let storeRoot = root.appendingPathComponent("isolated-store")
        let fm = FileManager.default
        var stages = [[String: Any]]()
        func hash(_ url: URL) throws -> String { try ProviderManifestVerifier.sha256(of: url) }
        func save(_ name: String, _ value: Any) throws {
            try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent(name), options: .atomic)
        }
        func record(_ name: String, _ extra: [String: Any] = [:]) throws {
            stages.append(extra.merging(["stage": name, "UTC": ISO8601DateFormatter().string(from: Date())]) { _, new in new })
            try save("stages.private.json", stages)
        }
        func package(_ version: String) -> URL {
            storeRoot.appendingPathComponent("versions/android-original-runtime/" + version)
        }
        func selection() throws -> Data { try Data(contentsOf: storeRoot.appendingPathComponent("selection.json")) }
        func rejected(_ name: String, _ operation: () async throws -> Void) async throws {
            let before = try selection()
            do { try await operation(); Issue.record("Unexpected component admission: \(name)"); throw URLError(.badServerResponse) }
            catch let error as URLError where error.code == .badServerResponse { throw error }
            catch { try record(name, ["error_type": String(reflecting: type(of: error))]) }
            try #require(try selection() == before)
        }

        // A live parent listener makes EPERM/EACCES distinguish offline denial
        // from an unused loopback port. No source or account service is contacted.
        let portText = try #require(env["NETVPLAYER_OFFLINE_PROBE_PORT"])
        let port = try #require(UInt16(portText))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        try #require(inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        let result: Int32
        let denied: Int32
        if fd < 0 { result = -1; denied = errno }
        else {
            result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            denied = errno
            close(fd)
        }
        try #require(result == -1 && [EPERM, EACCES].contains(denied))
        try record("OS_network_denial_verified", ["errno": denied])

        let app = try #require(Bundle(path: "/Applications/NetVplayer.app"))
        let trust = try ProviderTrustConfiguration.load(bundle: app)
        let version = try #require(app.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        let verifier = try trust.manifestVerifier(shellVersion: version)
        let store = AndroidRuntimeComponentStore(root: storeRoot, verifier: verifier)
        try #require(try await store.status().version == nil)
        try #require(try hash(old.appendingPathComponent("signed-manifest.json")) == "e436da89078d255d65d3152fe29085de786785140344d509cfac119ef0f0c936")
        try #require(try hash(current.appendingPathComponent("signed-manifest.json")) == "2af3afc6974b4fb7ca0701d63352254c4095696202b1c3b89a08248d00980d4d")
        let first = try await store.install(directory: old)
        try #require(first.version == "1.0.7" && first.previousVersion == nil)
        let previousRuntime = try #require(try await store.activeRuntime())
        try #require(previousRuntime.providerSHA256 == "88e67402129e7db92669fb351397ecd4d09709e6c70b577f22a19cfb0ad5f204")
        struct FrozenConfiguration: Decodable { let sites: [Site] }
        let configURL = URL(fileURLWithPath: try #require(env["NETVPLAYER_REAL_COMPONENT_CONFIG"]))
        let configSHA256 = try hash(configURL)
        try #require(configSHA256 == "a1f6c35620d5b67d6160958f9bd5be4e430fdf284aac017c0d3f55f305305265")
        let configuration = try JSONDecoder().decode(FrozenConfiguration.self, from: Data(contentsOf: configURL))
        try #require(configuration.sites.count == 48)
        let selected = previousRuntime.selectingOriginalBindings(sites: configuration.sites)
        let binding = try #require(selected.manifest.bindings.first { $0.key == "MTV" })
        try #require(binding.api == "csp_BiliGuard" && binding.className == "com.github.catvod.spider.BiliGuard")
        let previousIdentity = try previousRuntime.stateIdentity(binding: binding)
        try record("real_1_0_7_installed_with_production_probe", ["state_identity": previousIdentity,
            "installed_manifest_SHA256": try hash(package("1.0.7").appendingPathComponent("signed-manifest.json")),
            "frozen_config_SHA256": configSHA256, "selected_original_binding_count": selected.manifest.bindings.count,
            "binding_key": binding.key, "binding_API": binding.api, "binding_class": binding.className])

        let next = try await store.install(directory: current)
        try #require(next.version == "1.0.8" && next.previousVersion == "1.0.7")
        let currentRuntime = try #require(try await store.activeRuntime())
        try #require(currentRuntime.providerSHA256 == "898e9d7e787c01c2f24ff2457de08533f6b81b165a18103768e1898ba935693c")
        let currentIdentity = try currentRuntime.stateIdentity(binding: binding)
        try #require(currentIdentity != previousIdentity)
        let converted = "converted/provider-jvm.jar"
        try #require(try hash(previousRuntime.root.appendingPathComponent(converted)) == hash(currentRuntime.root.appendingPathComponent(converted)))
        try record("real_1_0_8_upgrade_isolates_changed_full_JAR_with_equal_converted_classes", [
            "previous_state_identity": previousIdentity, "current_state_identity": currentIdentity,
            "converted_JAR_SHA256": try hash(currentRuntime.root.appendingPathComponent(converted)),
            "installed_manifest_SHA256": try hash(package("1.0.8").appendingPathComponent("signed-manifest.json"))])
        let reopened = AndroidRuntimeComponentStore(root: storeRoot, verifier: verifier)
        try #require(try await reopened.status().version == "1.0.8")
        try #require(try await reopened.activeRuntime()?.stateIdentity(binding: binding) == currentIdentity)
        try record("persisted_offline_selection_reopened")
        let rolled = try await store.rollback()
        try #require(rolled.version == "1.0.7" && rolled.previousVersion == "1.0.8")
        try #require(try await store.activeRuntime()?.stateIdentity(binding: binding) == previousIdentity)
        try record("explicit_rollback_revalidates_previous_package_and_identity")

        let manifestURL = damaged.appendingPathComponent("signed-manifest.json")
        let originalManifest = try Data(contentsOf: manifestURL)
        var document = try JSONDecoder().decode(SignedProviderManifest.self, from: originalManifest)
        document.signature = Data(repeating: 0, count: 64).base64EncodedString()
        try JSONEncoder.providerCanonical.encode(document).write(to: manifestURL, options: .atomic)
        try await rejected("wrong_signature_rejected_without_selection_change") {
            _ = try await store.install(directory: damaged)
        }
        try originalManifest.write(to: manifestURL, options: .atomic)
        let originalJAR = damaged.appendingPathComponent("AndroidProviderRuntime/inputs/provider.jar")
        let bytes = try Data(contentsOf: originalJAR)
        var changed = bytes
        changed[changed.count - 1] ^= 1
        try changed.write(to: originalJAR, options: .atomic)
        try await rejected("changed_complete_JAR_rejected_without_selection_change") {
            _ = try await store.install(directory: damaged)
        }
        try bytes.write(to: originalJAR, options: .atomic)
        try #require(try hash(originalJAR) == currentRuntime.providerSHA256)
        try #require(try await store.install(directory: current).version == "1.0.8")
        let activeAdapter = package("1.0.8").appendingPathComponent("AndroidProviderRuntime/lib/android-adapter.jar")
        let adapterBytes = try Data(contentsOf: activeAdapter)
        var changedAdapter = adapterBytes
        changedAdapter[changedAdapter.count - 1] ^= 1
        try changedAdapter.write(to: activeAdapter, options: .atomic)
        try await rejected("corrupted_active_package_fails_closed") {
            _ = try await store.activeRuntime()
        }
        let recovered = try await store.rollback()
        try #require(recovered.version == "1.0.7" && recovered.previousVersion == nil)
        try #require(try await store.activeRuntime()?.stateIdentity(binding: binding) == previousIdentity)
        try record("rollback_from_corruption_does_not_advertise_damaged_version")

        try #require(try hash(old.appendingPathComponent("signed-manifest.json")) == "e436da89078d255d65d3152fe29085de786785140344d509cfac119ef0f0c936")
        try #require(try hash(current.appendingPathComponent("signed-manifest.json")) == "2af3afc6974b4fb7ca0701d63352254c4095696202b1c3b89a08248d00980d4d")
        try selection().write(to: root.appendingPathComponent("final-selection.private.json"))
        try save("report.safe.json", ["passed": true, "stages": stages,
            "production_signature_verifier_and_launch_probe": true,
            "original_packages": ["1.0.7", "1.0.8"], "OS_network_denied": true,
            "SDK_calls": 0, "target_App_starts": 0, "live_component_selection_changed": false,
            "whole_plan_complete": false])
        // These are duplicate rehearsal inputs and outputs. Original sealed
        // packages, stage receipts and final selection remain available.
        try fm.removeItem(at: storeRoot.appendingPathComponent("versions"))
        try fm.removeItem(at: damaged)
        try record("duplicate_rehearsal_trees_removed_original_packages_preserved")
    }
}
