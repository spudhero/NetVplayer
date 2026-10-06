import CryptoKit
import Darwin
import Foundation
import Testing
@testable import ProviderRuntime
@testable import ProviderSDK

private struct MaintenanceFixture {
    let temporary: URL
    let root: URL
    let source: URL
    let store: ProviderPackageStore
    let key: Curve25519.Signing.PrivateKey
    let assets: [ProviderAsset]
    static let providerID = "fixture.maintenance"

    init(runnerText: String = "#!/bin/sh\nexit 0\n") throws {
        temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("provider-maintenance-tests-\(UUID().uuidString)", isDirectory: true)
        root = temporary.appendingPathComponent("installed", isDirectory: true)
        source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let runner = source.appendingPathComponent("runner")
        try Data(runnerText.utf8).write(to: runner)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runner.path)
        let license = source.appendingPathComponent(ProviderManifestVerifier.providerLicensePath)
        try FileManager.default.createDirectory(at: license.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("Fixture MIT license\n".utf8).write(to: license)
        assets = [
            ProviderAsset(path: "runner", sha256: try ProviderManifestVerifier.sha256(of: runner), executable: true),
            ProviderAsset(path: ProviderManifestVerifier.providerLicensePath, sha256: try ProviderManifestVerifier.sha256(of: license))
        ]
        key = Curve25519.Signing.PrivateKey()
        store = ProviderPackageStore(rootURL: root, verifier: try ProviderManifestVerifier(
            publicKeyData: key.publicKey.rawRepresentation, shellVersion: "1.0.0"
        ))
    }

    func document(_ version: String) throws -> SignedProviderManifest {
        let manifest = ProviderManifest(
            providerID: Self.providerID, version: version,
            shellMinimumVersion: "1.0.0", macOSMinimumVersion: "1.0",
            architectures: [ProviderManifestVerifier.currentArchitecture],
            runtime: .javaScript, entrypoint: "runner", runner: "runner",
            capabilities: [.home], assets: assets, license: "MIT"
        )
        return SignedProviderManifest(manifest: manifest,
            signature: try key.signature(for: JSONEncoder.providerCanonical.encode(manifest)).base64EncodedString())
    }

    func installVersions() async throws {
        for version in ["1.0.0", "2.0.0", "3.0.0"] {
            _ = try await store.install(packageDirectory: source, document: document(version))
            try await store.activate(providerID: Self.providerID, version: version)
        }
    }

    func version(_ version: String) -> URL { root.appendingPathComponent(Self.providerID + "/" + version) }
    func cleanup() { try? FileManager.default.removeItem(at: temporary) }
}

@Test func maintenancePlanIsReadOnlyAndPreservesCurrentRollbackAndState() async throws {
    let fixture = try MaintenanceFixture()
    defer { fixture.cleanup() }
    try await fixture.installVersions()
    let state = try await fixture.store.stateDirectory(providerID: MaintenanceFixture.providerID)
    let credential = state.appendingPathComponent("session.fixture")
    try Data("private-state-fixture".utf8).write(to: credential)
    let before = try FileManager.default.subpathsOfDirectory(atPath: fixture.root.path).sorted()

    let plan = try await fixture.store.prepareMaintenance(.obsoleteVersions)
    #expect(plan.paths == [MaintenanceFixture.providerID + "/1.0.0"])
    #expect(try FileManager.default.subpathsOfDirectory(atPath: fixture.root.path).sorted() == before)
    #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(".maintenance").path))
    #expect(try await fixture.store.executeMaintenance(planID: plan.id) == false)
    #expect(!FileManager.default.fileExists(atPath: fixture.version("1.0.0").path))
    #expect(FileManager.default.fileExists(atPath: fixture.version("2.0.0").path))
    #expect(FileManager.default.fileExists(atPath: fixture.version("3.0.0").path))
    #expect(try String(contentsOf: credential, encoding: .utf8) == "private-state-fixture")
}

@Test func maintenanceStorageUsageDoesNotInvalidatePreparedPlan() async throws {
    let fixture = try MaintenanceFixture()
    defer { fixture.cleanup() }
    try await fixture.installVersions()
    let plan = try await fixture.store.prepareMaintenance(.obsoleteVersions)
    _ = try await fixture.store.storageUsage()
    #expect(try await fixture.store.executeMaintenance(planID: plan.id) == false)
}

@Test func maintenanceRejectsPlanWhenObsoleteVersionBecomesActive() async throws {
    let fixture = try MaintenanceFixture()
    defer { fixture.cleanup() }
    try await fixture.installVersions()
    let plan = try await fixture.store.prepareMaintenance(.obsoleteVersions)
    try await fixture.store.activate(providerID: MaintenanceFixture.providerID, version: "1.0.0")

    await #expect(throws: ProviderMaintenanceError.self) {
        _ = try await fixture.store.executeMaintenance(planID: plan.id)
    }
    #expect(FileManager.default.fileExists(atPath: fixture.version("1.0.0").path))
}

@Test func maintenanceRejectsPlanWhenObsoleteVersionBecomesRollbackTarget() async throws {
    let fixture = try MaintenanceFixture()
    defer { fixture.cleanup() }
    try await fixture.installVersions()
    let plan = try await fixture.store.prepareMaintenance(.obsoleteVersions)
    try await fixture.store.activate(providerID: MaintenanceFixture.providerID, version: "1.0.0")
    try await fixture.store.activate(providerID: MaintenanceFixture.providerID, version: "3.0.0")

    await #expect(throws: ProviderMaintenanceError.self) {
        _ = try await fixture.store.executeMaintenance(planID: plan.id)
    }
    #expect(FileManager.default.fileExists(atPath: fixture.version("1.0.0").path))
}

@Test func maintenanceRejectsChangedFilesAndOneShotPlanReuse() async throws {
    let fixture = try MaintenanceFixture()
    defer { fixture.cleanup() }
    try await fixture.installVersions()
    let plan = try await fixture.store.prepareMaintenance(.obsoleteVersions)
    let unrecognized = fixture.version("1.0.0").appendingPathComponent("new-user-file")
    try Data("must-preserve".utf8).write(to: unrecognized)
    await #expect(throws: ProviderMaintenanceError.self) {
        _ = try await fixture.store.executeMaintenance(planID: plan.id)
    }
    #expect(try String(contentsOf: unrecognized, encoding: .utf8) == "must-preserve")
    await #expect(throws: ProviderMaintenanceError.self) {
        _ = try await fixture.store.executeMaintenance(planID: plan.id)
    }
}

@Test func maintenanceRejectsSupersededPlanWithoutConsumingItsReplacement() async throws {
    let fixture = try MaintenanceFixture()
    defer { fixture.cleanup() }
    try await fixture.installVersions()
    let first = try await fixture.store.prepareMaintenance(.obsoleteVersions)
    let replacement = try await fixture.store.prepareMaintenance(.obsoleteVersions)
    await #expect(throws: ProviderMaintenanceError.self) {
        _ = try await fixture.store.executeMaintenance(planID: first.id)
    }
    #expect(try await fixture.store.executeMaintenance(planID: replacement.id) == false)
}

@Test func maintenanceRejectsExpiredPlanAndReplacedRootIdentity() async throws {
    let fixture = try MaintenanceFixture()
    defer { fixture.cleanup() }
    try await fixture.installVersions()
    let expiring = ProviderMaintenance(root: fixture.root, planLifetime: .zero)
    let expired = try expiring.prepare(
        paths: [MaintenanceFixture.providerID + "/1.0.0"],
        mode: .obsoleteVersions
    )
    #expect(throws: ProviderMaintenanceError.self) { _ = try expiring.execute(id: expired.id) }
    #expect(FileManager.default.fileExists(atPath: fixture.version("1.0.0").path))

    let engine = ProviderMaintenance(root: fixture.root)
    let plan = try engine.prepare(
        paths: [MaintenanceFixture.providerID + "/1.0.0"],
        mode: .obsoleteVersions
    )
    let oldRoot = fixture.temporary.appendingPathComponent("old-installed")
    try FileManager.default.moveItem(at: fixture.root, to: oldRoot)
    try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
    #expect(throws: ProviderMaintenanceError.self) { _ = try engine.execute(id: plan.id) }
    #expect(FileManager.default.fileExists(
        atPath: oldRoot.appendingPathComponent(MaintenanceFixture.providerID + "/1.0.0").path
    ))
}

@Test func maintenanceUninstallRetainsStateAndDisablesAutomaticLaunchAndInstall() async throws {
    let fixture = try MaintenanceFixture()
    defer { fixture.cleanup() }
    try await fixture.installVersions()
    let state = try await fixture.store.stateDirectory(providerID: MaintenanceFixture.providerID)
    let stateFile = state.appendingPathComponent("token.fixture")
    try Data("state-survives".utf8).write(to: stateFile)
    let manager = ProviderManager(store: fixture.store)
    let plan = try await manager.prepareMaintenance(.uninstall)
    #expect(try await manager.performMaintenance(plan) == false)
    #expect(await manager.isDisabled())
    #expect(try String(contentsOf: stateFile, encoding: .utf8) == "state-survives")
    await #expect(throws: ProviderMaintenanceError.self) {
        _ = try await manager.health(providerID: MaintenanceFixture.providerID)
    }
    await #expect(throws: ProviderMaintenanceError.self) {
        _ = try await manager.install(packageDirectory: fixture.source, document: fixture.document("4.0.0"))
    }
}

@Test func maintenanceCanDisableAutomaticInstallWhenNoRecognizedComponentsRemain() async throws {
    let fixture = try MaintenanceFixture()
    defer { fixture.cleanup() }
    try FileManager.default.removeItem(at: fixture.root)
    let manager = ProviderManager(store: fixture.store)
    let plan = try await manager.prepareMaintenance(.uninstall)
    #expect(plan.paths.isEmpty)
    #expect(try await manager.performMaintenance(plan) == false)
    #expect(await manager.isDisabled())
    await #expect(throws: ProviderMaintenanceError.self) {
        _ = try await manager.install(
            packageDirectory: fixture.source,
            document: fixture.document("1.0.0")
        )
    }
}

@Test func maintenanceRejectedUninstallDoesNotLeaveComponentsDisabled() async throws {
    let fixture = try MaintenanceFixture()
    defer { fixture.cleanup() }
    try await fixture.installVersions()
    let manager = ProviderManager(store: fixture.store)
    let plan = try await manager.prepareMaintenance(.uninstall)
    let newFile = fixture.version("1.0.0").appendingPathComponent("changed-after-preview")
    try Data("preserve".utf8).write(to: newFile)
    await #expect(throws: ProviderMaintenanceError.self) {
        _ = try await manager.performMaintenance(plan)
    }
    #expect(!(await manager.isDisabled()))
    #expect(FileManager.default.fileExists(atPath: fixture.version("3.0.0").path))
}

private enum MaintenanceInjectedFailure: Error { case stop }

@Test func maintenancePrecommitFailureRestoresFilesAndActiveMarker() async throws {
    let fixture = try MaintenanceFixture()
    defer { fixture.cleanup() }
    try await fixture.installVersions()
    let engine = ProviderMaintenance(root: fixture.root)
    let marker = MaintenanceFixture.providerID + "/active-version"
    let plan = try engine.prepare(paths: [MaintenanceFixture.providerID + "/3.0.0", marker], mode: .uninstall)
    engine.checkpoint = { if $0 == "commit" { throw MaintenanceInjectedFailure.stop } }
    #expect(throws: MaintenanceInjectedFailure.self) { _ = try engine.execute(id: plan.id) }
    #expect(!engine.hasPending())
    #expect(FileManager.default.fileExists(atPath: fixture.version("3.0.0").path))
    #expect(try String(contentsOf: fixture.root.appendingPathComponent(marker), encoding: .utf8) == "3.0.0")
}

@Test func maintenanceFailedRollbackCanRecoverAfterEngineRecreation() async throws {
    let fixture = try MaintenanceFixture()
    defer { fixture.cleanup() }
    try await fixture.installVersions()
    let engine = ProviderMaintenance(root: fixture.root)
    let plan = try engine.prepare(paths: [MaintenanceFixture.providerID + "/1.0.0"], mode: .obsoleteVersions)
    engine.checkpoint = { if $0 == "commit" || $0 == "restore" { throw MaintenanceInjectedFailure.stop } }
    #expect(throws: MaintenanceInjectedFailure.self) { _ = try engine.execute(id: plan.id) }
    #expect(engine.hasPending())
    let restarted = ProviderMaintenance(root: fixture.root)
    try restarted.recover()
    #expect(!restarted.hasPending())
    #expect(FileManager.default.fileExists(atPath: fixture.version("1.0.0").path))
}

@Test func maintenancePartialDeletionResumesWithoutRestoringCommittedPackages() async throws {
    let fixture = try MaintenanceFixture()
    defer { fixture.cleanup() }
    try await fixture.installVersions()
    let engine = ProviderMaintenance(root: fixture.root)
    let plan = try engine.prepare(paths: [MaintenanceFixture.providerID + "/1.0.0"], mode: .obsoleteVersions)
    var deletionCount = 0
    engine.checkpoint = {
        if $0 == "delete" {
            deletionCount += 1
            if deletionCount == 2 { throw MaintenanceInjectedFailure.stop }
        }
    }
    #expect(try engine.execute(id: plan.id))
    #expect(engine.hasPending())
    #expect(!FileManager.default.fileExists(atPath: fixture.version("1.0.0").path))
    let restarted = ProviderMaintenance(root: fixture.root)
    try restarted.recover()
    #expect(!restarted.hasPending())
    #expect(!FileManager.default.fileExists(atPath: fixture.version("1.0.0").path))
}

@Test func maintenanceRecoveryPreservesUnexpectedNewQuarantineContents() async throws {
    let fixture = try MaintenanceFixture()
    defer { fixture.cleanup() }
    try await fixture.installVersions()
    let engine = ProviderMaintenance(root: fixture.root)
    let relative = MaintenanceFixture.providerID + "/1.0.0"
    let plan = try engine.prepare(paths: [relative], mode: .obsoleteVersions)
    engine.checkpoint = { if $0 == "delete" { throw MaintenanceInjectedFailure.stop } }
    #expect(try engine.execute(id: plan.id))
    let unexpected = fixture.root.appendingPathComponent(".maintenance/\(plan.id.uuidString)/files/\(relative)/new-user-file")
    try Data("must-preserve".utf8).write(to: unexpected)
    let restarted = ProviderMaintenance(root: fixture.root)
    #expect(throws: ProviderMaintenanceError.self) { try restarted.recover() }
    #expect(restarted.hasPending())
    #expect(try String(contentsOf: unexpected, encoding: .utf8) == "must-preserve")
}

@Test func maintenanceCommittedRecoveryPreservesUnexpectedTransactionSiblings() async throws {
    let fixture = try MaintenanceFixture()
    defer { fixture.cleanup() }
    try await fixture.installVersions()
    let engine = ProviderMaintenance(root: fixture.root)
    let relative = MaintenanceFixture.providerID + "/1.0.0"
    let plan = try engine.prepare(paths: [relative], mode: .obsoleteVersions)
    engine.checkpoint = { if $0 == "delete" { throw MaintenanceInjectedFailure.stop } }
    #expect(try engine.execute(id: plan.id))
    let transaction = fixture.root.appendingPathComponent(".maintenance/\(plan.id.uuidString)")
    let filesSibling = transaction.appendingPathComponent("files/unexpected-user-file")
    let rootSibling = transaction.appendingPathComponent("unexpected-root-file")
    try Data("preserve-files".utf8).write(to: filesSibling)
    try Data("preserve-root".utf8).write(to: rootSibling)

    let restarted = ProviderMaintenance(root: fixture.root)
    #expect(throws: ProviderMaintenanceError.self) { try restarted.recover() }
    #expect(try String(contentsOf: filesSibling, encoding: .utf8) == "preserve-files")
    #expect(try String(contentsOf: rootSibling, encoding: .utf8) == "preserve-root")
}

@Test func maintenanceRollbackPreservesUnexpectedTransactionSibling() async throws {
    let fixture = try MaintenanceFixture()
    defer { fixture.cleanup() }
    try await fixture.installVersions()
    let engine = ProviderMaintenance(root: fixture.root)
    let relative = MaintenanceFixture.providerID + "/1.0.0"
    let plan = try engine.prepare(paths: [relative], mode: .obsoleteVersions)
    engine.checkpoint = { if $0 == "commit" || $0 == "restore" { throw MaintenanceInjectedFailure.stop } }
    #expect(throws: MaintenanceInjectedFailure.self) { _ = try engine.execute(id: plan.id) }
    let unexpected = fixture.root
        .appendingPathComponent(".maintenance/\(plan.id.uuidString)/unexpected-root-file")
    try Data("must-preserve".utf8).write(to: unexpected)

    let restarted = ProviderMaintenance(root: fixture.root)
    #expect(throws: ProviderMaintenanceError.self) { try restarted.recover() }
    #expect(FileManager.default.fileExists(atPath: fixture.version("1.0.0").path))
    #expect(try String(contentsOf: unexpected, encoding: .utf8) == "must-preserve")
}

@Test func maintenanceUncommittedRecoveryRejectsSymlinkQuarantineRoot() async throws {
    let fixture = try MaintenanceFixture()
    defer { fixture.cleanup() }
    try await fixture.installVersions()
    let engine = ProviderMaintenance(root: fixture.root)
    let plan = try engine.prepare(paths: [MaintenanceFixture.providerID + "/1.0.0"], mode: .obsoleteVersions)
    engine.checkpoint = { if $0 == "commit" || $0 == "restore" { throw MaintenanceInjectedFailure.stop } }
    #expect(throws: MaintenanceInjectedFailure.self) { _ = try engine.execute(id: plan.id) }
    let quarantine = fixture.root.appendingPathComponent(".maintenance/\(plan.id.uuidString)/files")
    let external = fixture.temporary.appendingPathComponent("outside-quarantine")
    try FileManager.default.moveItem(at: quarantine, to: external)
    try FileManager.default.createSymbolicLink(at: quarantine, withDestinationURL: external)

    let restarted = ProviderMaintenance(root: fixture.root)
    #expect(throws: ProviderMaintenanceError.self) { try restarted.recover() }
    #expect(FileManager.default.fileExists(atPath: external.appendingPathComponent(MaintenanceFixture.providerID + "/1.0.0").path))
}

@Test func maintenanceRejectsSymlinkInsidePackageAndPreservesExternalTarget() async throws {
    let fixture = try MaintenanceFixture()
    defer { fixture.cleanup() }
    try await fixture.installVersions()
    let external = fixture.temporary.appendingPathComponent("outside-fixture")
    try Data("must-not-delete".utf8).write(to: external)
    let link = fixture.version("1.0.0").appendingPathComponent("outside-link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
    await #expect(throws: ProviderMaintenanceError.self) {
        _ = try await fixture.store.prepareMaintenance(.obsoleteVersions)
    }
    #expect(try String(contentsOf: external, encoding: .utf8) == "must-not-delete")
}

@Test func maintenanceRejectsSymlinkRoot() async throws {
    let fixture = try MaintenanceFixture()
    defer { fixture.cleanup() }
    try await fixture.installVersions()
    let link = fixture.temporary.appendingPathComponent("linked-root")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.root)
    let engine = ProviderMaintenance(root: link)
    #expect(throws: ProviderMaintenanceError.self) {
        _ = try engine.prepare(paths: [MaintenanceFixture.providerID + "/1.0.0"], mode: .obsoleteVersions)
    }
    #expect(FileManager.default.fileExists(atPath: fixture.version("1.0.0").path))
}

@Test func maintenanceRejectsRegularFileRoot() throws {
    let fixture = try MaintenanceFixture()
    defer { fixture.cleanup() }
    try FileManager.default.removeItem(at: fixture.root)
    try Data("not-a-directory".utf8).write(to: fixture.root)
    let engine = ProviderMaintenance(root: fixture.root)
    #expect(throws: ProviderMaintenanceError.self) {
        _ = try engine.prepare(paths: [], mode: .uninstall)
    }
}

@Test func maintenanceRecoversEmptyTransactionCreatedBeforeJournal() throws {
    let fixture = try MaintenanceFixture()
    defer { fixture.cleanup() }
    let transaction = fixture.root.appendingPathComponent(".maintenance/\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: transaction.appendingPathComponent("files"),
        withIntermediateDirectories: true
    )
    let engine = ProviderMaintenance(root: fixture.root)
    try engine.recover()
    #expect(!FileManager.default.fileExists(atPath: transaction.path))
}

private let maintenanceDelayedRunner = """
#!/bin/sh
: > "$NETVPLAYER_PROVIDER_STATE/started"
i=0
while [ ! -f "$NETVPLAYER_PROVIDER_STATE/release" ] && [ "$i" -lt 100 ]; do
    /bin/sleep 0.05
    i=$((i + 1))
done
exit 17

"""

private let maintenanceStubbornProviderRunner = """
#!/usr/bin/python3
import json, os, signal, sys, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
with open(os.environ["NETVPLAYER_PROVIDER_STATE"] + "/stubborn-pids", "a") as output:
    output.write(str(os.getpid()) + "\\n")
    output.flush()
for line in sys.stdin:
    request = json.loads(line)
    if request.get("operation") == "handshake":
        result = {"provider_id": request["provider_id"], "protocol": request["protocol"], "capabilities": []}
    else:
        result = {}
    print(json.dumps({"request_id": request["request_id"], "ok": True, "result": result}), flush=True)
while True:
    time.sleep(1)
"""

private let maintenanceCountingProviderRunner = """
#!/usr/bin/python3
import json, os, sys
state = os.environ["NETVPLAYER_PROVIDER_STATE"]
with open(state + "/counting-pids", "a") as output:
    output.write(str(os.getpid()) + "\\n")
lock = state + "/counting-active"
try:
    descriptor = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    os.close(descriptor)
except FileExistsError:
    with open(state + "/counting-overlap", "w") as output:
        output.write("overlap")
for line in sys.stdin:
    request = json.loads(line)
    operation = request.get("operation")
    if operation == "handshake":
        result = {"provider_id": request["provider_id"], "protocol": request["protocol"], "capabilities": []}
    else:
        result = {}
    print(json.dumps({"request_id": request["request_id"], "ok": True, "result": result}), flush=True)
    if operation == "shutdown":
        try: os.unlink(lock)
        except FileNotFoundError: pass
        sys.exit(0)
"""

private let maintenanceInvalidStubbornRunner = """
#!/usr/bin/python3
import json, os, signal, sys, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
with open(os.environ["NETVPLAYER_PROVIDER_STATE"] + "/invalid-stubborn-pid", "w") as output:
    output.write(str(os.getpid()))
for line in sys.stdin:
    request = json.loads(line)
    result = {"provider_id": "wrong-provider", "protocol": request["protocol"], "capabilities": []}
    print(json.dumps({"request_id": request["request_id"], "ok": True, "result": result}), flush=True)
while True:
    time.sleep(1)
"""

private func waitForMaintenanceFixtureMarker(_ marker: URL) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

@Test func maintenanceRejectsPlanningWhileProviderInstallationHandshakeIsRunning() async throws {
    let fixture = try MaintenanceFixture(runnerText: maintenanceDelayedRunner)
    defer { fixture.cleanup() }
    let state = try await fixture.store.stateDirectory(providerID: MaintenanceFixture.providerID)
    let manager = ProviderManager(store: fixture.store)
    let document = try fixture.document("1.0.0")
    let install = Task { try await manager.install(packageDirectory: fixture.source, document: document) }
    let started = state.appendingPathComponent("started")
    await waitForMaintenanceFixtureMarker(started)
    #expect(FileManager.default.fileExists(atPath: started.path))
    await #expect(throws: ProviderMaintenanceError.self) {
        _ = try await manager.prepareMaintenance(.uninstall)
    }
    try Data().write(to: state.appendingPathComponent("release"))
    _ = try? await install.value
    await manager.shutdownAll()
}

@Test func maintenanceRejectsPlanningWhileExistingPackageIsLaunching() async throws {
    let fixture = try MaintenanceFixture(runnerText: maintenanceDelayedRunner)
    defer { fixture.cleanup() }
    _ = try await fixture.store.install(packageDirectory: fixture.source, document: fixture.document("1.0.0"))
    try await fixture.store.activate(providerID: MaintenanceFixture.providerID, version: "1.0.0")
    let state = try await fixture.store.stateDirectory(providerID: MaintenanceFixture.providerID)
    let manager = ProviderManager(store: fixture.store)
    let request = Task { try await manager.health(providerID: MaintenanceFixture.providerID) }
    let started = state.appendingPathComponent("started")
    await waitForMaintenanceFixtureMarker(started)
    #expect(FileManager.default.fileExists(atPath: started.path))
    await #expect(throws: ProviderMaintenanceError.self) {
        _ = try await manager.prepareMaintenance(.uninstall)
    }
    try Data().write(to: state.appendingPathComponent("release"))
    _ = try? await request.value
    await manager.shutdownAll()
}

@Test func maintenanceRepeatedStopConfirmationNeverForgetsALiveProcess() async throws {
    let fixture = try MaintenanceFixture()
    defer { fixture.cleanup() }
    let pidFile = fixture.temporary.appendingPathComponent("stubborn-process.pid")
    let client = ProviderProcessClient(command: ProviderCommand(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "trap '' TERM; echo $$ > \"$NETVPLAYER_PROVIDER_STATE/stubborn-process.pid\"; i=0; while [ \"$i\" -lt 30 ]; do /bin/sleep 1; i=$((i + 1)); done"],
        currentDirectoryURL: fixture.temporary,
        stateDirectoryURL: fixture.temporary,
        environment: ["NETVPLAYER_PROVIDER_STATE": fixture.temporary.path]
    ))
    try await client.start()
    await waitForMaintenanceFixtureMarker(pidFile)
    let rawPID = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    let pid = try #require(Int32(rawPID))
    defer { _ = kill(pid, SIGKILL) }

    await #expect(throws: ProviderMaintenanceError.self) { try await client.stopAndConfirmExit() }
    #expect(kill(pid, 0) == 0)
    await #expect(throws: ProviderMaintenanceError.self) { try await client.stopAndConfirmExit() }
    #expect(kill(pid, 0) == 0)
}

@Test func maintenanceRefusesReplacementSessionUntilRetiredProcessActuallyExits() async throws {
    let fixture = try MaintenanceFixture(runnerText: maintenanceStubbornProviderRunner)
    defer { fixture.cleanup() }
    _ = try await fixture.store.install(
        packageDirectory: fixture.source,
        document: fixture.document("1.0.0")
    )
    try await fixture.store.activate(
        providerID: MaintenanceFixture.providerID,
        version: "1.0.0"
    )
    let state = try await fixture.store.stateDirectory(providerID: MaintenanceFixture.providerID)
    let pidFile = state.appendingPathComponent("stubborn-pids")
    let manager = ProviderManager(store: fixture.store)
    _ = try await manager.health(providerID: MaintenanceFixture.providerID)
    let firstPID = try #require(
        String(contentsOf: pidFile, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .first
            .flatMap { Int32($0) }
    )
    var observedPIDs = [firstPID]
    defer { for pid in observedPIDs { _ = kill(pid, SIGKILL) } }

    let plan = try await manager.prepareMaintenance(.uninstall)
    await #expect(throws: ProviderMaintenanceError.self) {
        _ = try await manager.performMaintenance(plan)
    }
    await #expect(throws: ProviderMaintenanceError.self) {
        _ = try await manager.health(providerID: MaintenanceFixture.providerID)
    }
    #expect(
        try String(contentsOf: pidFile, encoding: .utf8)
            .split(whereSeparator: \.isNewline).count == 1
    )

    _ = kill(firstPID, SIGKILL)
    let exitDeadline = ContinuousClock.now.advanced(by: .seconds(2))
    while kill(firstPID, 0) == 0, ContinuousClock.now < exitDeadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    _ = try await manager.health(providerID: MaintenanceFixture.providerID)
    let allPIDs = try String(contentsOf: pidFile, encoding: .utf8)
        .split(whereSeparator: \.isNewline).compactMap { Int32($0) }
    observedPIDs = allPIDs
    #expect(allPIDs.count == 2)
}

@Test func providerLifecycleSerializesConcurrentSessionCreationAndInstallReplacement() async throws {
    let fixture = try MaintenanceFixture(runnerText: maintenanceCountingProviderRunner)
    defer { fixture.cleanup() }
    _ = try await fixture.store.install(
        packageDirectory: fixture.source,
        document: fixture.document("1.0.0")
    )
    try await fixture.store.activate(
        providerID: MaintenanceFixture.providerID,
        version: "1.0.0"
    )
    let state = try await fixture.store.stateDirectory(providerID: MaintenanceFixture.providerID)
    let manager = ProviderManager(store: fixture.store)

    async let firstHealth = manager.health(providerID: MaintenanceFixture.providerID)
    async let secondHealth = manager.health(providerID: MaintenanceFixture.providerID)
    _ = try await (firstHealth, secondHealth)
    var pids = try String(contentsOf: state.appendingPathComponent("counting-pids"), encoding: .utf8)
        .split(whereSeparator: \.isNewline)
    #expect(pids.count == 1, "Concurrent first requests must share one helper")

    async let firstInstall = manager.install(
        packageDirectory: fixture.source,
        document: fixture.document("2.0.0")
    )
    async let secondInstall = manager.install(
        packageDirectory: fixture.source,
        document: fixture.document("3.0.0")
    )
    _ = try await (firstInstall, secondInstall)
    pids = try String(contentsOf: state.appendingPathComponent("counting-pids"), encoding: .utf8)
        .split(whereSeparator: \.isNewline)
    #expect(pids.count == 3)
    #expect(!FileManager.default.fileExists(atPath: state.appendingPathComponent("counting-overlap").path))
    #expect((try await manager.activeManifests()).count == 1)
    await manager.shutdownAll()
}

@Test func invalidHandshakeRetainsStubbornHelperAndBlocksPackageRemoval() async throws {
    let fixture = try MaintenanceFixture(runnerText: maintenanceInvalidStubbornRunner)
    defer { fixture.cleanup() }
    _ = try await fixture.store.install(
        packageDirectory: fixture.source,
        document: fixture.document("1.0.0")
    )
    try await fixture.store.activate(
        providerID: MaintenanceFixture.providerID,
        version: "1.0.0"
    )
    let state = try await fixture.store.stateDirectory(providerID: MaintenanceFixture.providerID)
    let manager = ProviderManager(store: fixture.store)
    await #expect(throws: ProviderManagerError.self) {
        _ = try await manager.health(providerID: MaintenanceFixture.providerID)
    }
    let pid = try #require(Int32(
        String(contentsOf: state.appendingPathComponent("invalid-stubborn-pid"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    ))
    defer { _ = kill(pid, SIGKILL) }
    #expect(kill(pid, 0) == 0)
    let plan = try await manager.prepareMaintenance(.uninstall)
    await #expect(throws: ProviderMaintenanceError.self) {
        _ = try await manager.performMaintenance(plan)
    }
    #expect(FileManager.default.fileExists(atPath: fixture.version("1.0.0").path))
}
