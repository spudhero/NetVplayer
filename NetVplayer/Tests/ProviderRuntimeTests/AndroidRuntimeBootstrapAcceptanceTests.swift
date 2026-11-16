import Foundation
import Testing
import ProviderRuntime
@testable import SpiderEngine

/// Draft bytes are supplied through a controlled transport; dependency downloads,
/// signatures, portable installer, assembly, JVM probe and activation are real.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_ANDROID_BOOTSTRAP_ACCEPTANCE"] != nil))
struct AndroidRuntimeBootstrapAcceptanceTests {
    @Test func emptyInstallationPreparesAndReopensOffline() async throws {
        let input = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["NETVPLAYER_ANDROID_BOOTSTRAP_ACCEPTANCE"]))
        let trust = try JSONSerialization.jsonObject(with: Data(contentsOf: input.appendingPathComponent("trust.json"))) as! [String: Any]
        let signedIndex = try JSONSerialization.jsonObject(with: Data(contentsOf: input.appendingPathComponent("index.json"))) as! [String: Any]
        let index = signedIndex["index"] as! [String: Any]
        let release = (index["releases"] as! [[String: Any]])[0]
        let archiveURL = try #require(URL(string: release["archive_url"] as! String))
        let indexURL = URL(string: "https://android-bootstrap-fixture.invalid/index.json")!
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("bootstrap-client-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: work) }
        let bundleURL = work.appendingPathComponent("Client.bundle")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "com.netvplayer.bootstrap.acceptance",
            "CFBundleShortVersionString": "2.0.0", "CFBundlePackageType": "BNDL",
            ProviderTrustConfiguration.manifestKeyName: trust["manifest_public_key"]!,
            ProviderTrustConfiguration.distributionKeyName: trust["distribution_public_key"]!,
            "NetVplayerAndroidRuntimeBootstrapIndexURL": indexURL.absoluteString]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: bundleURL.appendingPathComponent("Info.plist"))
        let bundle = try #require(Bundle(url: bundleURL))
        let root = work.appendingPathComponent("components")
        let archive = input.appendingPathComponent(archiveURL.lastPathComponent)
        BootstrapAcceptanceTransport.install([indexURL: input.appendingPathComponent("index.json"), archiveURL: archive])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BootstrapAcceptanceTransport.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); BootstrapAcceptanceTransport.install([:]) }
        let client = ProviderDistributionClient(session: session)
        let phases = BootstrapAcceptancePhases()
        try await AndroidRuntimeBootstrap.install(bundle: bundle, progress: { await phases.append($0) }, root: root, distribution: client)
        let verifier = try ProviderTrustConfiguration.load(bundle: bundle).manifestVerifier(shellVersion: "2.0.0")
        let store = AndroidRuntimeComponentStore(root: root, verifier: verifier)
        #expect(try await store.status().version == release["version"] as? String)
        #expect(try await store.activeRuntime()?.manifest.schema == 3)
        let observed = await phases.values
        #expect(observed.first == "checking" && observed.last == "ready")
        #expect(observed.contains("downloading-java") && observed.contains("preparing-host") && observed.contains("activating"))
        // An empty transport will fail every request. A verified existing
        // selection must reopen without fetching the catalog or dependencies.
        BootstrapAcceptanceTransport.install([:])
        try await AndroidRuntimeBootstrap.install(bundle: bundle, progress: { _ in
            Issue.record("Offline reopening must not start preparation")
        }, root: root, distribution: client)
        let receipt: [String: Any] = ["empty_installation": "passed", "offline_reopen": "passed",
            "version": release["version"]!, "phases": observed,
            "archive_sha256": try ProviderManifestVerifier.sha256(of: archive)]
        try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys, .prettyPrinted])
            .write(to: input.appendingPathComponent("client-acceptance.json"))
    }
}

private actor BootstrapAcceptancePhases {
    var values: [String] = []
    func append(_ phase: String) { values.append(phase) }
}

private final class BootstrapAcceptanceTransport: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var files: [URL: URL] = [:]
    static func install(_ value: [URL: URL]) { lock.lock(); defer { lock.unlock() }; files = value }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let file = request.url.flatMap { Self.files[$0] }
        Self.lock.unlock()
        do {
            let file = try #require(file)
            let data = try Data(contentsOf: file, options: .mappedIfSafe)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": String(data.count)])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
