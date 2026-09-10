import CryptoKit
import Foundation
import Testing
import Security
import Models
@testable import ProviderRuntime
@testable import ProviderSDK
import SpiderEngine
import ProxyServer

private func makeProviderLicense(in root: URL) throws -> ProviderAsset {
    let license = root.appendingPathComponent(ProviderManifestVerifier.providerLicensePath)
    try FileManager.default.createDirectory(
        at: license.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data("Fixture Provider License\n".utf8).write(to: license)
    return ProviderAsset(
        path: ProviderManifestVerifier.providerLicensePath,
        sha256: try ProviderManifestVerifier.sha256(of: license)
    )
}

private final class ProviderFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    struct Route: Sendable {
        let statusCode: Int
        let data: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [URL: Route] = [:]
    nonisolated(unsafe) private static var requests: [URLRequest] = []

    static func install(_ values: [URL: Route]) {
        lock.lock()
        routes = values
        requests = []
        lock.unlock()
    }

    static func recordedRequest(for url: URL) -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return requests.last { $0.url == url }
    }

    static func reset() {
        install([:])
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme == "https"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let route = request.url.flatMap { Self.routes[$0] }
        Self.lock.unlock()
        guard let url = request.url, let route else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: route.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": String(route.data.count)]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: route.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class QuickJSHostURLProtocol: URLProtocol, @unchecked Sendable {
    struct Route: Sendable {
        let statusCode: Int
        let headers: [String: String]
        let data: Data
        let delay: TimeInterval
        let redirectURL: URL?

        init(
            statusCode: Int,
            headers: [String: String] = [:],
            data: Data,
            delay: TimeInterval = 0,
            redirectURL: URL? = nil
        ) {
            self.statusCode = statusCode
            self.headers = headers
            self.data = data
            self.delay = delay
            self.redirectURL = redirectURL
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [URL: Route] = [:]
    nonisolated(unsafe) private static var observedHeaders: [URL: [String: String]] = [:]
    nonisolated(unsafe) private static var observedMethods: [URL: String] = [:]
    nonisolated(unsafe) private static var observedBodies: [URL: Data] = [:]

    static func install(_ values: [URL: Route]) {
        lock.lock()
        routes = values
        observedHeaders.removeAll()
        observedMethods.removeAll()
        observedBodies.removeAll()
        lock.unlock()
    }

    static func headers(for url: URL) -> [String: String]? {
        lock.lock()
        defer { lock.unlock() }
        return observedHeaders[url]
    }

    static func method(for url: URL) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return observedMethods[url]
    }

    static func body(for url: URL) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return observedBodies[url]
    }

    static func reset() {
        install([:])
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme == "https"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.lock.lock()
        let route = Self.routes[url]
        Self.observedHeaders[url] = request.allHTTPHeaderFields ?? [:]
        Self.observedMethods[url] = request.httpMethod
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        Self.observedBodies[url] = body
        Self.lock.unlock()
        guard let route else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        if route.delay > 0 { Thread.sleep(forTimeInterval: route.delay) }
        var headers = route.headers
        headers["Content-Length"] = String(route.data.count)
        let response = HTTPURLResponse(
            url: url,
            statusCode: route.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        if let redirectURL = route.redirectURL {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: redirectURL), redirectResponse: response)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: route.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class QuickJSRealHTTPFixture {
    private let root: URL
    private let process: Process
    let port: Int

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-quickjs-real-http-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("server.py")
        try Data(
            """
            from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

            class Handler(BaseHTTPRequestHandler):
                protocol_version = "HTTP/1.0"

                def do_GET(self):
                    if self.path == "/redirect":
                        body = b"redirect-body"
                        self.send_response(302)
                        self.send_header("Location", f"http://127.0.0.1:{self.server.server_address[1]}/final")
                    elif self.path == "/final":
                        body = b"final"
                        self.send_response(200)
                    elif self.path == "/latin1":
                        body = bytes([0xE9])
                        self.send_response(200)
                        self.send_header("Content-Type", "text/plain; charset=iso-8859-1")
                    elif self.path == "/gb18030":
                        body = bytes([0x95, 0x32, 0x82, 0x36])
                        self.send_response(200)
                        self.send_header("Content-Type", "text/plain; charset=gb18030")
                    elif self.path == "/multi-cookie":
                        body = b"cookies"
                        self.send_response(200)
                        self.send_header("Set-Cookie", "a=1; Path=/")
                        self.send_header("Set-Cookie", "b=2; Path=/")
                        self.send_header("X-Request-Cookie", self.headers.get("Cookie", ""))
                    else:
                        body = self.headers.get("X-Real", "").encode("utf-8")
                        self.send_response(200)
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)

                def log_message(self, *_):
                    pass

            server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            print(server.server_address[1], flush=True)
            server.serve_forever()
            """.utf8
        ).write(to: script)

        let serverProcess = Process()
        serverProcess.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        serverProcess.arguments = ["-u", script.path]
        let output = Pipe()
        serverProcess.standardOutput = output
        serverProcess.standardError = Pipe()
        try serverProcess.run()

        var line = Data()
        while line.last != 0x0A {
            let chunk = output.fileHandleForReading.readData(ofLength: 1)
            guard !chunk.isEmpty else {
                serverProcess.terminate()
                serverProcess.waitUntilExit()
                throw NSError(domain: "QuickJSRealHTTPFixture", code: 1)
            }
            line.append(chunk)
        }
        guard let port = Int(String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else {
            serverProcess.terminate()
            serverProcess.waitUntilExit()
            throw NSError(domain: "QuickJSRealHTTPFixture", code: 2)
        }
        self.process = serverProcess
        self.port = port
    }

    deinit {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        try? FileManager.default.removeItem(at: root)
    }
}

private actor ProviderProgressRecorder {
    private var values: [ProviderInstallProgress] = []

    func append(_ value: ProviderInstallProgress) {
        values.append(value)
    }

    func phases() -> [ProviderInstallPhase] {
        values.map(\.phase)
    }

    func downloadFractions() -> [Double] {
        values.compactMap(\.fractionCompleted)
    }
}

private func makeSignedProviderArchive(
    root: URL,
    fixtureRunner: URL,
    privateKey: Curve25519.Signing.PrivateKey,
    version: String,
    protocolVersion: Int = 1,
    runnerStarts: Bool = true,
    sourcePolicy: ProviderSourcePolicy? = .userConfiguredOnly
) throws -> URL {
    let package = root.appendingPathComponent("package-\(version)", isDirectory: true)
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    let runner = package.appendingPathComponent("runner")
    if runnerStarts {
        try FileManager.default.copyItem(at: fixtureRunner, to: runner)
    } else {
        try Data("#!/bin/sh\nexit 17\n".utf8).write(to: runner)
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runner.path)
    let entrypoint = package.appendingPathComponent("provider.mjs")
    try Data("export default {};\n".utf8).write(to: entrypoint)
    let licenseAsset = try makeProviderLicense(in: package)
    let manifest = ProviderManifest(
        providerID: "fixture.distribution",
        version: version,
        protocolVersion: protocolVersion,
        shellMinimumVersion: "1.0.0",
        macOSMinimumVersion: "1.0",
        architectures: [ProviderManifestVerifier.currentArchitecture],
        runtime: .javaScript,
        entrypoint: "provider.mjs",
        runner: "runner",
        capabilities: [.home, .search, .detail, .player],
        assets: [
            ProviderAsset(
                path: "runner",
                sha256: try ProviderManifestVerifier.sha256(of: runner),
                executable: true
            ),
            ProviderAsset(
                path: "provider.mjs",
                sha256: try ProviderManifestVerifier.sha256(of: entrypoint)
            ),
            licenseAsset,
        ],
        sourcePolicy: sourcePolicy,
        license: "MIT"
    )
    let signature = try privateKey.signature(for: JSONEncoder.providerCanonical.encode(manifest))
    let document = SignedProviderManifest(
        manifest: manifest,
        signature: signature.base64EncodedString()
    )
    try JSONEncoder.providerCanonical.encode(document).write(
        to: package.appendingPathComponent("signed-manifest.json")
    )

    let archive = root.appendingPathComponent("fixture-\(version).zip")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = ["-c", "-k", "--norsrc", package.path, archive.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw ProviderDistributionError.extractionFailed(process.terminationStatus)
    }
    return archive
}

private func makeSignedQuickJSArchive(
    root: URL,
    privateKey: Curve25519.Signing.PrivateKey,
    version: String
) throws -> URL {
    let package = root.appendingPathComponent("quickjs-package-\(version)", isDirectory: true)
    let runtimeDirectory = package.appendingPathComponent("runtimes/quickjs/bin", isDirectory: true)
    let providerDirectory = package.appendingPathComponent("provider-runners/quickjs", isDirectory: true)
    try FileManager.default.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: providerDirectory, withIntermediateDirectories: true)

    // This deterministic shim speaks the provider JSONL protocol while retaining
    // the same runtime tree names as a signed Cosmopolitan QuickJS package.
    let runtimeShim = """
    #!/bin/sh
    set -eu
    version='\(version)'
    while IFS= read -r line; do
        request_id=$(printf '%s' "$line" | sed -E 's/.*"request_id":"([^"]*)".*/\\1/')
        should_exit=0
        case "$line" in
            *handshake*) result='{"protocol":1,"provider_id":"'"$NETVPLAYER_PROVIDER_ID"'","runtime":"quickjs-fixture-'"$version"'","capabilities":["core-lifecycle","console"]}' ;;
            *health*) result='{"status":"ok","runtime":"quickjs-fixture-'"$version"'"}' ;;
            *shutdown*) result='{"shutdown":true}' ; should_exit=1 ;;
            *) result='{}' ;;
        esac
        printf '{"request_id":"%s","ok":true,"result":%s,"error":null}\\n' "$request_id" "$result"
        [ "$should_exit" -eq 1 ] && break
    done
    """
    let runtime = runtimeDirectory.appendingPathComponent("qjs")
    try Data(runtimeShim.utf8).write(to: runtime)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runtime.path)

    let polyglot = runtimeDirectory.appendingPathComponent("qjs-cosmo")
    try Data("cosmopolitan-quickjs-fixture-\(version)\n".utf8).write(to: polyglot)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: polyglot.path)
    let bootstrap = runtimeDirectory.appendingPathComponent(".ape-1.10")
    try Data("prewarmed-loader-fixture-\(version)\n".utf8).write(to: bootstrap)

    let runner = providerDirectory.appendingPathComponent("provider_runner.mjs")
    try Data("export default {};\n".utf8).write(to: runner)
    let entrypoint = package.appendingPathComponent("provider.mjs")
    try Data("export default { version: \"\(version)\" };\n".utf8).write(to: entrypoint)
    let unlisted = package.appendingPathComponent("unlisted-payload")
    try Data("must-not-install\n".utf8).write(to: unlisted)
    let licenseAsset = try makeProviderLicense(in: package)

    let assetURLs: [(String, URL, Bool)] = [
        ("runtimes/quickjs/bin/qjs", runtime, true),
        ("runtimes/quickjs/bin/qjs-cosmo", polyglot, true),
        ("runtimes/quickjs/bin/.ape-1.10", bootstrap, false),
        ("provider-runners/quickjs/provider_runner.mjs", runner, false),
        ("provider.mjs", entrypoint, false),
    ]
    let assets = try assetURLs.map { path, url, executable in
        ProviderAsset(path: path, sha256: try ProviderManifestVerifier.sha256(of: url), executable: executable)
    } + [licenseAsset]
    let manifest = ProviderManifest(
        providerID: "fixture.quickjs.lifecycle",
        version: version,
        shellMinimumVersion: "1.0.0",
        macOSMinimumVersion: "1.0",
        architectures: [ProviderManifestVerifier.currentArchitecture],
        runtime: .quickJS,
        entrypoint: "provider.mjs",
        runner: "provider-runners/quickjs/provider_runner.mjs",
        runtimeExecutable: "runtimes/quickjs/bin/qjs",
        capabilities: [.home, .search, .detail, .player],
        assets: assets,
        hostCapabilities: [.console],
        license: "MIT"
    )
    let signature = try privateKey.signature(for: JSONEncoder.providerCanonical.encode(manifest))
    let document = SignedProviderManifest(manifest: manifest, signature: signature.base64EncodedString())
    try JSONEncoder.providerCanonical.encode(document).write(
        to: package.appendingPathComponent("signed-manifest.json")
    )

    let archive = root.appendingPathComponent("quickjs-fixture-\(version).zip")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = ["-c", "-k", "--norsrc", package.path, archive.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw ProviderDistributionError.extractionFailed(process.terminationStatus)
    }
    return archive
}

private func signedDistributionDocument(
    releases: [ProviderRelease],
    privateKey: Curve25519.Signing.PrivateKey
) throws -> Data {
    let index = ProviderDistributionIndex(
        generatedAt: Date(timeIntervalSinceReferenceDate: 0),
        releases: releases
    )
    let signature = try privateKey.signature(for: JSONEncoder.providerCanonical.encode(index))
    return try JSONEncoder.providerCanonical.encode(SignedProviderDistributionIndex(
        index: index,
        signature: signature.base64EncodedString()
    ))
}

@Test func signedPackageVerificationRejectsTamperingAndPathEscape() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("provider-verification-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let runner = root.appendingPathComponent("runner")
    try Data("runner-v1".utf8).write(to: runner)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runner.path)
    let hash = try ProviderManifestVerifier.sha256(of: runner)
    let licenseAsset = try makeProviderLicense(in: root)
    let manifest = ProviderManifest(
        providerID: "example.provider",
        version: "1.0.0",
        shellMinimumVersion: "1.0.0",
        macOSMinimumVersion: "1.0",
        architectures: [ProviderManifestVerifier.currentArchitecture],
        runtime: .javaScript,
        entrypoint: "runner",
        runner: "runner",
        capabilities: [.home],
        assets: [ProviderAsset(path: "runner", sha256: hash, executable: true), licenseAsset],
        license: "MIT"
    )
    let privateKey = Curve25519.Signing.PrivateKey()
    let signature = try privateKey.signature(for: JSONEncoder.providerCanonical.encode(manifest))
    let document = SignedProviderManifest(manifest: manifest, signature: signature.base64EncodedString())
    let verifier = try ProviderManifestVerifier(
        publicKeyData: privateKey.publicKey.rawRepresentation,
        shellVersion: "1.0.0"
    )

    try verifier.verify(document, packageRoot: root)

    #expect(throws: ProviderVerificationError.invalidSignature) {
        try verifier.verify(
            SignedProviderManifest(manifest: manifest, signature: "invalid"),
            packageRoot: root
        )
    }

    try Data("tampered".utf8).write(to: runner)
    #expect(throws: ProviderVerificationError.hashMismatch("runner")) {
        try verifier.verify(document, packageRoot: root)
    }
    #expect(throws: ProviderVerificationError.unsafePath("../runner")) {
        _ = try ProviderManifestVerifier.resolve(relativePath: "../runner", inside: root)
    }
}

@Test func signedPackageRequiresSignedProviderLicenseAsset() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("provider-license-gate-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = root.appendingPathComponent("runner")
    try Data("runner".utf8).write(to: runner)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runner.path)
    let manifest = ProviderManifest(
        providerID: "fixture.missing-license",
        version: "1.0.0",
        shellMinimumVersion: "1.0.0",
        macOSMinimumVersion: "1.0",
        architectures: [ProviderManifestVerifier.currentArchitecture],
        runtime: .javaScript,
        entrypoint: "runner",
        runner: "runner",
        capabilities: [.home],
        assets: [ProviderAsset(
            path: "runner",
            sha256: try ProviderManifestVerifier.sha256(of: runner),
            executable: true
        )],
        license: "MIT"
    )
    let key = Curve25519.Signing.PrivateKey()
    let signature = try key.signature(for: JSONEncoder.providerCanonical.encode(manifest))
    let verifier = try ProviderManifestVerifier(
        publicKeyData: key.publicKey.rawRepresentation,
        shellVersion: "1.0.0"
    )

    #expect(throws: ProviderVerificationError.missingAsset(ProviderManifestVerifier.providerLicensePath)) {
        try verifier.verify(
            SignedProviderManifest(manifest: manifest, signature: signature.base64EncodedString()),
            packageRoot: root
        )
    }
}

@Test func signedManifestRejectsWildcardSourceBindings() throws {
    let privateKey = Curve25519.Signing.PrivateKey()
    let verifier = try ProviderManifestVerifier(
        publicKeyData: privateKey.publicKey.rawRepresentation,
        shellVersion: "1.0.0"
    )
    let manifest = ProviderManifest(
        providerID: "example.binding",
        version: "1.0.0",
        shellMinimumVersion: "1.0.0",
        macOSMinimumVersion: "1.0",
        architectures: [ProviderManifestVerifier.currentArchitecture],
        runtime: .javaScript,
        entrypoint: "runner",
        runner: "runner",
        capabilities: [.home],
        assets: [],
        sourceBindings: [ProviderSourceBinding(originalAPIs: ["https://example.test/*"])],
        license: "MIT"
    )

    #expect(throws: ProviderVerificationError.invalidSourceBinding("https://example.test/*")) {
        try verifier.verifyCompatibility(manifest)
    }
}

@Test func packageStoreActivatesAndRollsBackSignedVersions() async throws {
    let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent("provider-rollback-\(UUID().uuidString)", isDirectory: true)
    let package = temporary.appendingPathComponent("package", isDirectory: true)
    let installed = temporary.appendingPathComponent("installed", isDirectory: true)
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let runner = package.appendingPathComponent("runner")
    try Data("fixture".utf8).write(to: runner)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runner.path)
    let unlisted = package.appendingPathComponent("unlisted-payload")
    try Data("must-not-install".utf8).write(to: unlisted)
    let asset = ProviderAsset(
        path: "runner",
        sha256: try ProviderManifestVerifier.sha256(of: runner),
        executable: true
    )
    let licenseAsset = try makeProviderLicense(in: package)
    let privateKey = Curve25519.Signing.PrivateKey()
    let verifier = try ProviderManifestVerifier(
        publicKeyData: privateKey.publicKey.rawRepresentation,
        shellVersion: "1.0.0"
    )
    let store = ProviderPackageStore(rootURL: installed, verifier: verifier)

    func document(version: String) throws -> SignedProviderManifest {
        let manifest = ProviderManifest(
            providerID: "fixture.rollback",
            version: version,
            shellMinimumVersion: "1.0.0",
            macOSMinimumVersion: "1.0",
            architectures: [ProviderManifestVerifier.currentArchitecture],
            runtime: .javaScript,
            entrypoint: "runner",
            runner: "runner",
            capabilities: [.home],
            assets: [asset, licenseAsset],
            license: "MIT"
        )
        let signature = try privateKey.signature(for: JSONEncoder.providerCanonical.encode(manifest))
        return SignedProviderManifest(manifest: manifest, signature: signature.base64EncodedString())
    }

    _ = try await store.install(packageDirectory: package, document: document(version: "1.0.0"))
    #expect(!FileManager.default.fileExists(
        atPath: installed.appendingPathComponent("fixture.rollback/1.0.0/unlisted-payload").path
    ))
    try await store.activate(providerID: "fixture.rollback", version: "1.0.0")
    _ = try await store.install(packageDirectory: package, document: document(version: "2.0.0"))
    try await store.activate(providerID: "fixture.rollback", version: "2.0.0")
    _ = try await store.rollback(providerID: "fixture.rollback")
    let active = try await store.activePackage(providerID: "fixture.rollback")
    #expect(active.1.manifest.version == "1.0.0")
}

@Test func quickJSSignedPackageInstallsActivatesRollsBackAndHandshakes() async throws {
    let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent("provider-quickjs-lifecycle-\(UUID().uuidString)", isDirectory: true)
    let installed = temporary.appendingPathComponent("installed", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let privateKey = Curve25519.Signing.PrivateKey()
    let v1Archive = try makeSignedQuickJSArchive(root: temporary, privateKey: privateKey, version: "1.0.0")
    let v2Archive = try makeSignedQuickJSArchive(root: temporary, privateKey: privateKey, version: "2.0.0")

    func extract(_ archive: URL, version: String) throws -> URL {
        let package = temporary.appendingPathComponent("extracted-\(version)", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, package.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ProviderDistributionError.extractionFailed(process.terminationStatus)
        }
        return package
    }

    let packageV1 = try extract(v1Archive, version: "1.0.0")
    let packageV2 = try extract(v2Archive, version: "2.0.0")
    let documentV1 = try JSONDecoder().decode(
        SignedProviderManifest.self,
        from: Data(contentsOf: packageV1.appendingPathComponent("signed-manifest.json"))
    )
    let documentV2 = try JSONDecoder().decode(
        SignedProviderManifest.self,
        from: Data(contentsOf: packageV2.appendingPathComponent("signed-manifest.json"))
    )
    let verifier = try ProviderManifestVerifier(
        publicKeyData: privateKey.publicKey.rawRepresentation,
        shellVersion: "1.0.0"
    )
    let store = ProviderPackageStore(rootURL: installed, verifier: verifier)
    let manager = ProviderManager(store: store)

    let installedV1 = try await manager.install(packageDirectory: packageV1, document: documentV1)
    #expect(FileManager.default.isExecutableFile(
        atPath: installedV1.appendingPathComponent("runtimes/quickjs/bin/qjs").path
    ))
    #expect(FileManager.default.fileExists(
        atPath: installedV1.appendingPathComponent("runtimes/quickjs/bin/qjs-cosmo").path
    ))
    #expect(FileManager.default.fileExists(
        atPath: installedV1.appendingPathComponent("runtimes/quickjs/bin/.ape-1.10").path
    ))
    #expect(!FileManager.default.fileExists(
        atPath: installedV1.appendingPathComponent("unlisted-payload").path
    ))
    #expect((await manager.activeManifests()).first?.manifest.version == "1.0.0")

    let site = Site(
        key: "quickjs-lifecycle-site",
        name: "QuickJS lifecycle fixture",
        type: 3,
        api: "https://quickjs.example.test/provider.js"
    )
    try await manager.initialize(providerID: documentV1.manifest.providerID, site: site)
    let healthV1 = try await manager.health(providerID: documentV1.manifest.providerID)
    #expect(healthV1.result == .object([
        "status": .string("ok"),
        "runtime": .string("quickjs-fixture-1.0.0"),
    ]))

    _ = try await manager.install(packageDirectory: packageV2, document: documentV2)
    #expect((await manager.activeManifests()).first?.manifest.version == "2.0.0")
    let healthV2 = try await manager.health(providerID: documentV2.manifest.providerID)
    #expect(healthV2.result == .object([
        "status": .string("ok"),
        "runtime": .string("quickjs-fixture-2.0.0"),
    ]))

    try await manager.rollback(providerID: documentV2.manifest.providerID)
    #expect((await manager.activeManifests()).first?.manifest.version == "1.0.0")
    let rolledBackHealth = try await manager.health(providerID: documentV1.manifest.providerID)
    #expect(rolledBackHealth.result == .object([
        "status": .string("ok"),
        "runtime": .string("quickjs-fixture-1.0.0"),
    ]))
    await manager.shutdownAll()
}

@Test func quickJSJSPHostBridgeMatchesCatVodSelectorContracts() async throws {
    let html = """
    <body>
      <section class="catalog">
        <article class="card"><a href="/one"><span class="title"> One </span></a></article>
        <article class="card"><a href="/two" data-alt="/alternate"><span class="title"> Two </span></a></article>
      </section>
      <div class="poster" style="background-image: url('/poster.jpg')"></div>
    </body>
    """
    let host = QuickJSJSPHost()
    let arrayResponse = await host.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "jsp-array",
        capability: "jsp",
        operation: "query",
        options: [
            "mode": .string("pdfa"),
            "html": .string(html),
            "rule": .string("article.card"),
        ]
    ))
    guard case .object(let arrayEnvelope) = arrayResponse.result,
          case .array(let cards) = arrayEnvelope["value"] else {
        Issue.record("Expected jsp.pdfa array result")
        return
    }
    #expect(cards.count == 2)
    if case .string(let firstCard) = cards.first {
        #expect(firstCard.contains("<article class=\"card\">"))
        #expect(firstCard.contains("<span class=\"title\"> One </span>"))
    } else {
        Issue.record("Expected jsp.pdfa card HTML")
    }

    let textResponse = await host.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "jsp-text",
        capability: "jsp",
        operation: "query",
        options: [
            "mode": .string("pdfh"),
            "html": .string(html),
            "rule": .string("article.card&&.title&&Text"),
        ]
    ))
    #expect(textResponse.result == .object(["value": .string("One")]))

    let urlResponse = await host.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "jsp-url",
        capability: "jsp",
        operation: "query",
        options: [
            "mode": .string("pd"),
            "html": .string(html),
            "rule": .string("article.card:eq(1)&&a&&data-alt|href"),
            "base_url": .string("https://example.test/catalog/"),
        ]
    ))
    #expect(urlResponse.result == .object(["value": .string("https://example.test/alternate")]))

    let negativeIndexResponse = await host.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "jsp-negative-index",
        capability: "jsp",
        operation: "query",
        options: [
            "mode": .string("pd"),
            "html": .string(html),
            "rule": .string("article.card:eq(-1)&&a&&href"),
            "base_url": .string("https://example.test/catalog/"),
        ]
    ))
    #expect(negativeIndexResponse.result == .object(["value": .string("https://example.test/two")]))

    let exclusionResponse = await host.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "jsp-exclusion",
        capability: "jsp",
        operation: "query",
        options: [
            "mode": .string("pdfa"),
            "html": .string(html),
            "rule": .string("article.card--.title"),
        ]
    ))
    guard case .object(let exclusionEnvelope) = exclusionResponse.result,
          case .array(let excludedCards) = exclusionEnvelope["value"],
          case .string(let excludedFirstCard) = excludedCards.first else {
        Issue.record("Expected jsp.pdfa exclusion result")
        return
    }
    #expect(!excludedFirstCard.contains("class=\"title\""))

    let styleResponse = await host.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "jsp-style",
        capability: "jsp",
        operation: "query",
        options: [
            "mode": .string("pd"),
            "html": .string(html),
            "rule": .string("div.poster&&style"),
            "base_url": .string("https://example.test/catalog/"),
        ]
    ))
    #expect(styleResponse.result == .object(["value": .string("https://example.test/poster.jpg")]))

    let listResponse = await host.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "jsp-list",
        capability: "jsp",
        operation: "query",
        options: [
            "mode": .string("pdfl"),
            "html": .string(html),
            "texts": .string(".title&&Text"),
            "urls": .string("a&&href"),
            "url_key": .string("https://example.test/catalog/"),
        ]
    ))
    #expect(listResponse.result == .object(["value": .array([
        .string("One$https://example.test/one"),
        .string("Two$https://example.test/two"),
    ])]))

    let bodyResponse = await host.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "jsp-body",
        capability: "jsp",
        operation: "query",
        options: [
            "mode": .string("pdfh"),
            "html": .string("<p>Hello</p>"),
            "rule": .string("body&&Text"),
        ]
    ))
    #expect(bodyResponse.result == .object(["value": .string("Hello")]))

    let unsupportedResponse = await host.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "jsp-unsupported",
        capability: "jsp",
        operation: "query",
        options: ["mode": .string("crypto")]
    ))
    #expect(unsupportedResponse.ok == false)
    #expect(unsupportedResponse.error?.code == "jsp_parse_failed")
}

@Test func quickJSTextHostUsesSystemSimplifiedTraditionalTransforms() async throws {
    let host = QuickJSTextHost()
    let simplifiedResponse = await host.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "text-s2t",
        capability: "text",
        operation: "s2t",
        options: ["value": .string("简体中文🙂")]
    ))
    #expect(simplifiedResponse.ok)
    #expect(simplifiedResponse.result == .object(["value": .string("簡體中文🙂")]))

    let traditionalResponse = await host.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "text-t2s",
        capability: "text",
        operation: "t2s",
        options: ["value": .string("繁體中文🙂")]
    ))
    #expect(traditionalResponse.ok)
    #expect(traditionalResponse.result == .object(["value": .string("繁体中文🙂")]))

    let unsupportedResponse = await host.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "text-unsupported",
        capability: "text",
        operation: "pinyin",
        options: ["value": .string("中文")]
    ))
    #expect(!unsupportedResponse.ok)
    #expect(unsupportedResponse.error?.code == "unsupported_operation")
}

@Test func quickJSJSPHostSupportsCommonComplexSelectors() async throws {
    let html = """
    <section class="catalog">
      <article class="card" data-id="one"><span class="title">One</span><span class="tag">Hot</span></article>
      <article class="card" data-id="two"><span class="title">Two</span></article>
      <article class="card empty" data-id="three"></article>
    </section>
    """
    let host = QuickJSJSPHost()

    let hasTag = await host.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "jsp-has",
        capability: "jsp",
        operation: "query",
        options: [
            "mode": .string("pdfa"),
            "html": .string(html),
            "rule": .string("article.card:has(.tag)"),
        ]
    ))
    guard case .object(let hasEnvelope) = hasTag.result,
          case .array(let hasCards) = hasEnvelope["value"] else {
        Issue.record("Expected jsp :has result")
        return
    }
    #expect(hasCards.count == 1)

    let contains = await host.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "jsp-contains",
        capability: "jsp",
        operation: "query",
        options: [
            "mode": .string("pdfh"),
            "html": .string(html),
            "rule": .string("article.card:contains(Two)&&.title&&Text"),
        ]
    ))
    #expect(contains.result == .object(["value": .string("Two")]))

    let matchesOwn = await host.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "jsp-matches-own",
        capability: "jsp",
        operation: "query",
        options: [
            "mode": .string("pdfh"),
            "html": .string(html),
            "rule": .string("span.title:matchesOwn(^Two$)&&Text"),
        ]
    ))
    #expect(matchesOwn.result == .object(["value": .string("Two")]))

    let matches = await host.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "jsp-matches",
        capability: "jsp",
        operation: "query",
        options: [
            "mode": .string("pdfh"),
            "html": .string(html),
            "rule": .string("article.card:matches(^Two$)&&.title&&Text"),
        ]
    ))
    #expect(matches.result == .object(["value": .string("Two")]))

    let notHasTitle = await host.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "jsp-not-has-title",
        capability: "jsp",
        operation: "query",
        options: [
            "mode": .string("pdfa"),
            "html": .string(html),
            "rule": .string("article.card:not(:has(.title))"),
        ]
    ))
    guard case .object(let notEnvelope) = notHasTitle.result,
          case .array(let noTitleCards) = notEnvelope["value"] else {
        Issue.record("Expected jsp :not result")
        return
    }
    #expect(noTitleCards.count == 1)

    let attribute = await host.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "jsp-attribute",
        capability: "jsp",
        operation: "query",
        options: [
            "mode": .string("pdfh"),
            "html": .string(html),
            "rule": .string("article[data-id='two']&&.title&&Text"),
        ]
    ))
    #expect(attribute.result == .object(["value": .string("Two")]))

    let nthChild = await host.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "jsp-nth-child",
        capability: "jsp",
        operation: "query",
        options: [
            "mode": .string("pdfh"),
            "html": .string(html),
            "rule": .string("article.card:nth-child(2)&&.title&&Text"),
        ]
    ))
    #expect(nthChild.result == .object(["value": .string("Two")]))

    let first = await host.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "jsp-first",
        capability: "jsp",
        operation: "query",
        options: [
            "mode": .string("pdfh"),
            "html": .string(html),
            "rule": .string("article.card:first&&.title&&Text"),
        ]
    ))
    #expect(first.result == .object(["value": .string("One")]))

    let last = await host.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "jsp-last",
        capability: "jsp",
        operation: "query",
        options: [
            "mode": .string("pdfh"),
            "html": .string(html),
            "rule": .string("article.card:last&&.title&&Text"),
        ]
    ))
    #expect(last.result == .object(["value": .string("")]))

    let empty = await host.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "jsp-empty",
        capability: "jsp",
        operation: "query",
        options: [
            "mode": .string("pdfa"),
            "html": .string(html),
            "rule": .string("article.card:empty"),
        ]
    ))
    guard case .object(let emptyEnvelope) = empty.result,
          case .array(let emptyCards) = emptyEnvelope["value"] else {
        Issue.record("Expected jsp :empty result")
        return
    }
    #expect(emptyCards.count == 1)

    let odd = await host.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "jsp-odd",
        capability: "jsp",
        operation: "query",
        options: ["mode": .string("pdfa"), "html": .string(html), "rule": .string("article.card:odd")]
    ))
    guard case .object(let oddEnvelope) = odd.result,
          case .array(let oddCards) = oddEnvelope["value"] else {
        Issue.record("Expected jsp :odd result")
        return
    }
    #expect(oddCards.count == 1)

    let even = await host.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "jsp-even",
        capability: "jsp",
        operation: "query",
        options: ["mode": .string("pdfa"), "html": .string(html), "rule": .string("article.card:even")]
    ))
    guard case .object(let evenEnvelope) = even.result,
          case .array(let evenCards) = evenEnvelope["value"] else {
        Issue.record("Expected jsp :even result")
        return
    }
    #expect(evenCards.count == 2)

    let lessThan = await host.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "jsp-lt",
        capability: "jsp",
        operation: "query",
        options: ["mode": .string("pdfa"), "html": .string(html), "rule": .string("article.card:lt(2)")]
    ))
    guard case .object(let lessEnvelope) = lessThan.result,
          case .array(let lessCards) = lessEnvelope["value"] else {
        Issue.record("Expected jsp :lt result")
        return
    }
    #expect(lessCards.count == 2)

    let greaterThan = await host.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "jsp-gt",
        capability: "jsp",
        operation: "query",
        options: ["mode": .string("pdfa"), "html": .string(html), "rule": .string("article.card:gt(0)")]
    ))
    guard case .object(let greaterEnvelope) = greaterThan.result,
          case .array(let greaterCards) = greaterEnvelope["value"] else {
        Issue.record("Expected jsp :gt result")
        return
    }
    #expect(greaterCards.count == 2)
}

@Test func quickJSCryptoHostMatchesFongMiAESAndRSAContracts() async throws {
    let host = QuickJSCryptoHost()
    let aesEncrypt = await host.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "crypto-aes-encrypt",
        capability: "crypto",
        operation: "aes",
        options: [
            "mode": .string("AES/CBC/PKCS5"),
            "encrypt": .bool(true),
            "input": .string("hello"),
            "in_base64": .bool(false),
            "key": .string("0123456789abcdef"),
            "iv": .string("abcdef9876543210"),
            "out_base64": .bool(true),
        ]
    ))
    #expect(aesEncrypt.result == .object(["value": .string("rkbumbtCClkN+Jkds7bQJw==")]))

    let aesDecrypt = await host.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "crypto-aes-decrypt",
        capability: "crypto",
        operation: "aes",
        options: [
            "mode": .string("AES/CBC/PKCS5"),
            "encrypt": .bool(false),
            "input": .string("rkbumbtCClkN+Jkds7bQJw=="),
            "in_base64": .bool(true),
            "key": .string("0123456789abcdef"),
            "iv": .string("abcdef9876543210"),
            "out_base64": .bool(false),
        ]
    ))
    #expect(aesDecrypt.result == .object(["value": .string("hello")]))

    let keyAttributes: [String: Any] = [
        kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
        kSecAttrKeySizeInBits as String: 1024,
    ]
    var keyError: Unmanaged<CFError>?
    let privateKey = try #require(SecKeyCreateRandomKey(keyAttributes as CFDictionary, &keyError))
    let publicKey = try #require(SecKeyCopyPublicKey(privateKey))
    let publicData = try #require(SecKeyCopyExternalRepresentation(publicKey, nil) as Data?)
    let privateData = try #require(SecKeyCopyExternalRepresentation(privateKey, nil) as Data?)
    func derLength(_ length: Int) -> Data {
        if length < 0x80 { return Data([UInt8(length)]) }
        var bytes: [UInt8] = []
        var value = length
        while value > 0 {
            bytes.insert(UInt8(value & 0xff), at: 0)
            value >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)]) + Data(bytes)
    }
    func der(_ tag: UInt8, _ body: Data) -> Data {
        Data([tag]) + derLength(body.count) + body
    }
    let rsaAlgorithm = Data([0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01])
        + Data([0x05, 0x00])
    let x509PublicData = der(
        0x30,
        der(0x30, rsaAlgorithm) + der(0x03, Data([0]) + publicData)
    )
    let pkcs8PrivateData = der(
        0x30,
        der(0x02, Data([0])) + der(0x30, rsaAlgorithm) + der(0x04, privateData)
    )
    func pem(_ label: String, _ data: Data) -> String {
        let encoded = data.base64EncodedString()
        let lines = stride(from: 0, to: encoded.count, by: 64).map { offset in
            let start = encoded.index(encoded.startIndex, offsetBy: offset)
            let end = encoded.index(start, offsetBy: min(64, encoded.distance(from: start, to: encoded.endIndex)))
            return String(encoded[start..<end])
        }
        return "-----BEGIN \(label)-----\n\(lines.joined(separator: "\n"))\n-----END \(label)-----"
    }
    let publicPEM = pem("PUBLIC KEY", x509PublicData)
    let privatePEM = pem("PRIVATE KEY", pkcs8PrivateData)
    let rsaEncrypt = await host.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "crypto-rsa-encrypt",
        capability: "crypto",
        operation: "rsa",
        options: [
            "mode": .string("RSA/PKCS1"),
            "pub": .bool(true),
            "encrypt": .bool(true),
            "input": .string("hello"),
            "in_base64": .bool(false),
            "key": .string(x509PublicData.base64EncodedString()),
            "out_base64": .bool(true),
        ]
    ))
    guard case .object(let rsaEnvelope) = rsaEncrypt.result,
          case .string(let ciphertext) = rsaEnvelope["value"] else {
        Issue.record("Expected RSA ciphertext")
        return
    }
    let rsaDecrypt = await host.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "crypto-rsa-decrypt",
        capability: "crypto",
        operation: "rsa",
        options: [
            "mode": .string("RSA/PKCS1"),
            "pub": .bool(false),
            "encrypt": .bool(false),
            "input": .string(ciphertext),
            "in_base64": .bool(true),
            "key": .string(privateData.base64EncodedString()),
            "out_base64": .bool(false),
        ]
    ))
    #expect(rsaDecrypt.result == .object(["value": .string("hello")]))

    let pemEncrypt = await host.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "crypto-rsa-pem-encrypt",
        capability: "crypto",
        operation: "rsa",
        options: [
            "mode": .string("RSA/PKCS1"),
            "pub": .bool(true),
            "encrypt": .bool(true),
            "input": .string("hello"),
            "in_base64": .bool(false),
            "key": .string(publicPEM),
            "out_base64": .bool(true),
        ]
    ))
    guard case .object(let pemEnvelope) = pemEncrypt.result,
          case .string(let pemCiphertext) = pemEnvelope["value"] else {
        Issue.record("Expected PEM RSA ciphertext")
        return
    }
    let pemDecrypt = await host.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "crypto-rsa-pem-decrypt",
        capability: "crypto",
        operation: "rsa",
        options: [
            "mode": .string("RSA/PKCS1"),
            "pub": .bool(false),
            "encrypt": .bool(false),
            "input": .string(pemCiphertext),
            "in_base64": .bool(true),
            "key": .string(privatePEM),
            "out_base64": .bool(false),
        ]
    ))
    #expect(pemDecrypt.result == .object(["value": .string("hello")]))

    let unknownModeEncrypt = await host.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "crypto-rsa-unknown-mode",
        capability: "crypto",
        operation: "rsa",
        options: [
            "mode": .string("RSA/OAEP"),
            "pub": .bool(true),
            "encrypt": .bool(true),
            "input": .string("hello"),
            "in_base64": .bool(false),
            "key": .string(x509PublicData.base64EncodedString()),
            "out_base64": .bool(true),
        ]
    ))
    guard case .object(let unknownModeEnvelope) = unknownModeEncrypt.result,
          case .string(let unknownModeCiphertext) = unknownModeEnvelope["value"] else {
        Issue.record("Expected RSA fallback ciphertext")
        return
    }
    let unknownModeDecrypt = await host.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "crypto-rsa-unknown-mode-decrypt",
        capability: "crypto",
        operation: "rsa",
        options: [
            "mode": .string("RSA/PKCS1"),
            "pub": .bool(false),
            "encrypt": .bool(false),
            "input": .string(unknownModeCiphertext),
            "in_base64": .bool(true),
            "key": .string(privateData.base64EncodedString()),
            "out_base64": .bool(false),
        ]
    ))
    #expect(unknownModeDecrypt.result == .object(["value": .string("hello")]))

    let privateEncrypt = await host.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "crypto-rsa-private-encrypt",
        capability: "crypto",
        operation: "rsa",
        options: [
            "mode": .string("RSA/PKCS1"),
            "pub": .bool(false),
            "encrypt": .bool(true),
            "input": .string("hello"),
            "in_base64": .bool(false),
            "key": .string(privateData.base64EncodedString()),
            "out_base64": .bool(true),
        ]
    ))
    guard case .object(let privateEnvelope) = privateEncrypt.result,
          case .string(let privateCiphertext) = privateEnvelope["value"] else {
        Issue.record("Expected RSA private-key ciphertext")
        return
    }
    let publicDecrypt = await host.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "crypto-rsa-public-decrypt",
        capability: "crypto",
        operation: "rsa",
        options: [
            "mode": .string("RSA/PKCS1"),
            "pub": .bool(true),
            "encrypt": .bool(false),
            "input": .string(privateCiphertext),
            "in_base64": .bool(true),
            "key": .string(x509PublicData.base64EncodedString()),
            "out_base64": .bool(false),
        ]
    ))
    #expect(publicDecrypt.result == .object(["value": .string("hello")]))

    let invalidAES = await host.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "crypto-aes-invalid",
        capability: "crypto",
        operation: "aes",
        options: [
            "mode": .string("AES/GCM/NoPadding"),
            "encrypt": .bool(true),
            "input": .string("hello"),
            "in_base64": .bool(false),
            "key": .string("0123456789abcdef"),
            "iv": .null,
            "out_base64": .bool(true),
        ]
    ))
    #expect(invalidAES.ok)
    #expect(invalidAES.result == .object(["value": .string("")]))

    let invalidRSA = await host.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "crypto-rsa-invalid",
        capability: "crypto",
        operation: "rsa",
        options: [
            "mode": .string("RSA/PKCS1"),
            "pub": .bool(true),
            "encrypt": .bool(true),
            "input": .string("hello"),
            "in_base64": .bool(false),
            "key": .string("not-a-key"),
            "out_base64": .bool(true),
        ]
    ))
    #expect(invalidRSA.ok)
    #expect(invalidRSA.result == .object(["value": .string("")]))

    let invalidPEM = await host.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "crypto-rsa-invalid-pem",
        capability: "crypto",
        operation: "rsa",
        options: [
            "mode": .string("RSA/PKCS1"),
            "pub": .bool(true),
            "encrypt": .bool(true),
            "input": .string("hello"),
            "in_base64": .bool(false),
            "key": .string("-----BEGIN RSA PRIVATE KEY-----\nAQ==\n-----END RSA PRIVATE KEY-----"),
            "out_base64": .bool(true),
        ]
    ))
    #expect(invalidPEM.ok)
    #expect(invalidPEM.result == .object(["value": .string("")]))

    let encryptedPrivatePEM = await host.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "crypto-rsa-encrypted-private-pem",
        capability: "crypto",
        operation: "rsa",
        options: [
            "mode": .string("RSA/PKCS1"),
            "pub": .bool(false),
            "encrypt": .bool(false),
            "input": .string(ciphertext),
            "in_base64": .bool(true),
            "key": .string("-----BEGIN ENCRYPTED PRIVATE KEY-----\n\(privateData.base64EncodedString())\n-----END ENCRYPTED PRIVATE KEY-----"),
            "out_base64": .bool(false),
        ]
    ))
    #expect(encryptedPrivatePEM.ok)
    #expect(encryptedPrivatePEM.result == .object(["value": .string("")]))

    let truncatedPEM = await host.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "crypto-rsa-truncated-pem",
        capability: "crypto",
        operation: "rsa",
        options: [
            "mode": .string("RSA/PKCS1"),
            "pub": .bool(true),
            "encrypt": .bool(true),
            "input": .string("hello"),
            "in_base64": .bool(false),
            "key": .string("-----BEGIN PUBLIC KEY-----\nAQ==\n-----END PUBLIC KEY-----"),
            "out_base64": .bool(true),
        ]
    ))
    #expect(truncatedPEM.ok)
    #expect(truncatedPEM.result == .object(["value": .string("")]))

    let unsupported = await host.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "crypto-unsupported",
        capability: "crypto",
        operation: "md5",
        options: [:]
    ))
    #expect(unsupported.ok == false)
    #expect(unsupported.error?.code == "unsupported_operation")
}

@Test func quickJSPersistenceHostPersistsFongMiLocalValues() async throws {
    let state = FileManager.default.temporaryDirectory
        .appendingPathComponent("provider-quickjs-local-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: state) }

    let set = await QuickJSPersistenceHost(stateDirectoryURL: state).handle(QuickJSHostControl(
        type: "host_request",
        requestID: "local-set",
        capability: "persistence",
        operation: "set",
        options: ["rule": .string("fixture"), "key": .string("token"), "value": .string("")]
    ))
    #expect(set.ok)
    let firstGet = await QuickJSPersistenceHost(stateDirectoryURL: state).handle(QuickJSHostControl(
        type: "host_request",
        requestID: "local-get",
        capability: "persistence",
        operation: "get",
        options: ["rule": .string("fixture"), "key": .string("token")]
    ))
    #expect(firstGet.result == .object(["value": .string("")]))

    let update = await QuickJSPersistenceHost(stateDirectoryURL: state).handle(QuickJSHostControl(
        type: "host_request",
        requestID: "local-update",
        capability: "persistence",
        operation: "set",
        options: ["rule": .string("fixture"), "key": .string("token"), "value": .string("persisted")]
    ))
    #expect(update.ok)
    let secondGet = await QuickJSPersistenceHost(stateDirectoryURL: state).handle(QuickJSHostControl(
        type: "host_request",
        requestID: "local-get-2",
        capability: "persistence",
        operation: "get",
        options: ["rule": .string("fixture"), "key": .string("token")]
    ))
    #expect(secondGet.result == .object(["value": .string("persisted")]))

    let delete = await QuickJSPersistenceHost(stateDirectoryURL: state).handle(QuickJSHostControl(
        type: "host_request",
        requestID: "local-delete",
        capability: "persistence",
        operation: "delete",
        options: ["rule": .string("fixture"), "key": .string("token")]
    ))
    #expect(delete.result == .object(["value": .null]))
    let afterDelete = await QuickJSPersistenceHost(stateDirectoryURL: state).handle(QuickJSHostControl(
        type: "host_request",
        requestID: "local-get-after-delete",
        capability: "persistence",
        operation: "get",
        options: ["rule": .string("fixture"), "key": .string("token")]
    ))
    #expect(afterDelete.result == .object(["value": .string("")]))

    let localFile = state.appendingPathComponent("quickjs-local.json")
    let permissions = try #require(
        FileManager.default.attributesOfItem(atPath: localFile.path)[.posixPermissions] as? NSNumber
    )
    #expect(permissions.intValue & 0o777 == 0o600)
    let lockPermissions = try #require(
        FileManager.default.attributesOfItem(atPath: localFile.appendingPathExtension("lock").path)[.posixPermissions] as? NSNumber
    )
    #expect(lockPermissions.intValue & 0o777 == 0o600)
}

@Test func quickJSPersistenceHostPreservesLargeAndEmptyRuleValues() async throws {
    let state = FileManager.default.temporaryDirectory
        .appendingPathComponent("provider-quickjs-local-boundaries-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: state) }

    let largeValue = String(repeating: "x", count: 1_048_577)
    let host = QuickJSPersistenceHost(stateDirectoryURL: state)
    let largeSet = await host.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "large-set",
        capability: "persistence",
        operation: "set",
        options: ["rule": .string(""), "key": .string("large"), "value": .string(largeValue)]
    ))
    #expect(largeSet.ok)

    let persisted = await QuickJSPersistenceHost(stateDirectoryURL: state).handle(QuickJSHostControl(
        type: "host_request",
        requestID: "large-get",
        capability: "persistence",
        operation: "get",
        options: ["rule": .string(""), "key": .string("large")]
    ))
    #expect(persisted.result == .object(["value": .string(largeValue)]))

    let file = try String(contentsOf: state.appendingPathComponent("quickjs-local.json"), encoding: .utf8)
    #expect(file.contains("\"cache_large\""))
}

@Test func quickJSPersistenceHostMigratesAndroidSharedPreferencesCacheValues() async throws {
    let state = FileManager.default.temporaryDirectory
        .appendingPathComponent("provider-quickjs-local-migration-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: state) }
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    try Data("{\"cache_fixture_existing\":\"current\"}".utf8)
        .write(to: state.appendingPathComponent("quickjs-local.json"))
    try Data(
        """
        <?xml version="1.0" encoding="utf-8" standalone="yes"?>
        <map>
            <string name="cache_fixture_existing">legacy</string>
            <string name="cache_fixture_token">from-android</string>
            <boolean name="cache_fixture_flag" value="true" />
            <int name="cache_fixture_count" value="7" />
            <string name="unrelated">ignore</string>
        </map>
        """.utf8
    ).write(to: state.appendingPathComponent("shared_prefs.xml"))

    let host = QuickJSPersistenceHost(stateDirectoryURL: state)
    func get(_ key: String) async -> ProviderJSONValue? {
        let response = await host.handle(QuickJSHostControl(
            type: "host_request",
            requestID: "migration-\(key)",
            capability: "persistence",
            operation: "get",
            options: ["rule": .string("fixture"), "key": .string(key)]
        ))
        guard case .object(let result) = response.result else { return nil }
        return result["value"]
    }
    #expect(await get("existing") == .string("current"))
    #expect(await get("token") == .string("from-android"))
    #expect(await get("flag") == .string("true"))
    #expect(await get("count") == .string("7"))
    #expect(await get("unrelated") == .string(""))

    let marker = state.appendingPathComponent("shared_prefs.xml.migrated")
    #expect(FileManager.default.fileExists(atPath: marker.path))
    let markerPermissions = try #require(
        FileManager.default.attributesOfItem(atPath: marker.path)[.posixPermissions] as? NSNumber
    )
    #expect(markerPermissions.intValue & 0o777 == 0o600)
}

@Test func quickJSPersistenceHostsShareInProcessState() async throws {
    let state = FileManager.default.temporaryDirectory
        .appendingPathComponent("provider-quickjs-local-shared-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: state) }

    let writer = QuickJSPersistenceHost(stateDirectoryURL: state)
    let reader = QuickJSPersistenceHost(stateDirectoryURL: state)
    let set = await writer.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "shared-set",
        capability: "persistence",
        operation: "set",
        options: ["rule": .string("shared"), "key": .string("token"), "value": .string("one")]
    ))
    #expect(set.ok)

    let firstRead = await reader.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "shared-get-1",
        capability: "persistence",
        operation: "get",
        options: ["rule": .string("shared"), "key": .string("token")]
    ))
    #expect(firstRead.result == .object(["value": .string("one")]))

    let update = await reader.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "shared-update",
        capability: "persistence",
        operation: "set",
        options: ["rule": .string("shared"), "key": .string("token"), "value": .string("two")]
    ))
    #expect(update.ok)

    let secondRead = await writer.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "shared-get-2",
        capability: "persistence",
        operation: "get",
        options: ["rule": .string("shared"), "key": .string("token")]
    ))
    #expect(secondRead.result == .object(["value": .string("two")]))

    let localFile = state.appendingPathComponent("quickjs-local.json")
    try Data("{\"cache_shared_token\":\"external\"}".utf8).write(to: localFile, options: .atomic)
    let externalRead = await writer.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "shared-get-external",
        capability: "persistence",
        operation: "get",
        options: ["rule": .string("shared"), "key": .string("token")]
    ))
    #expect(externalRead.result == .object(["value": .string("external")]))

    let merged = await writer.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "shared-set-merge",
        capability: "persistence",
        operation: "set",
        options: ["rule": .string("shared"), "key": .string("other"), "value": .string("kept")]
    ))
    #expect(merged.ok)
    let preserved = await reader.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "shared-get-preserved",
        capability: "persistence",
        operation: "get",
        options: ["rule": .string("shared"), "key": .string("token")]
    ))
    #expect(preserved.result == .object(["value": .string("external")]))
}

@Test func quickJSLocalProxyHostMatchesFongMiURLContract() throws {
    let host = QuickJSLocalProxyHost()
    let port = host.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "proxy-port",
        capability: "local_proxy",
        operation: "get_port",
        options: [:]
    ))
    #expect(port.result == .object(["port": .number(Double(ProxyServer.shared.port))]))

    let proxy = host.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "proxy-url",
        capability: "local_proxy",
        operation: "get_proxy",
        options: ["local": .bool(true)]
    ))
    #expect(proxy.result == .object(["url": .string("http://127.0.0.1:\(ProxyServer.shared.port)/proxy?do=js")]))

    let externalProxy = host.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "proxy-external-url",
        capability: "local_proxy",
        operation: "get_proxy",
        options: ["local": .bool(false)]
    ))
    #expect(externalProxy.result == proxy.result)

    let jsProxy = host.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "proxy-js",
        capability: "local_proxy",
        operation: "js2_proxy",
        options: [
            "dynamic": .bool(false),
            "site_type": .number(1),
            "site_key": .string("golden"),
            "headers": .object(["X-Test": .string("a b")]),
            "url": .string("https://golden.example.test/video?token=a&b=c"),
        ]
    ))
    #expect(jsProxy.result == .object(["url": .string("http://127.0.0.1:\(ProxyServer.shared.port)/proxy?do=js&from=catvod&siteType=1&siteKey=golden&header=%7B%22X-Test%22%3A%22a+b%22%7D&url=https%3A%2F%2Fgolden.example.test%2Fvideo%3Ftoken%3Da%26b%3Dc")]))

    let dynamicJSProxy = host.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "proxy-dynamic-js",
        capability: "local_proxy",
        operation: "js2_proxy",
        options: [
            "dynamic": .bool(true),
            "site_type": .number(1),
            "site_key": .string("golden"),
            "headers": .object(["X-Test": .string("a b")]),
            "url": .string("https://golden.example.test/video?token=a&b=c"),
        ]
    ))
    #expect(dynamicJSProxy.result == jsProxy.result)
}

@Test func providerProxyResponseAdapterValidatesBytesStatusAndHeaders() throws {
    let compressedPrefix = Data([0x1f, 0x8b, 0x08, 0x00])
    let response = try ProviderProxyResponseAdapter.response(from: ProviderProxyPayload(
        statusCode: 206,
        bodyBase64: compressedPrefix.base64EncodedString(),
        headers: [
            "Content-Type": "application/gzip",
            "Content-Length": "999",
            "Transfer-Encoding": "chunked",
            "Content-Encoding": "gzip",
            "X-Fixture": "proxy",
        ]
    ))
    #expect(response.statusCode == 206)
    #expect(response.contentType == "application/gzip")
    #expect(response.data == compressedPrefix)
    #expect(response.headers == ["Content-Encoding": "gzip", "X-Fixture": "proxy"])

    #expect(throws: ProviderProxyResponseError.invalidStatusCode(99)) {
        try ProviderProxyResponseAdapter.response(from: ProviderProxyPayload(statusCode: 99))
    }
    #expect(throws: ProviderProxyResponseError.invalidBase64Body) {
        try ProviderProxyResponseAdapter.response(from: ProviderProxyPayload(
            statusCode: 200,
            bodyBase64: "not-base64"
        ))
    }
    #expect(throws: ProviderProxyResponseError.bodyTooLarge(limit: 3)) {
        try ProviderProxyResponseAdapter.response(
            from: ProviderProxyPayload(statusCode: 200, body: "four"),
            maximumBodyBytes: 3
        )
    }
    #expect(throws: ProviderProxyResponseError.invalidHeader("X-Bad")) {
        try ProviderProxyResponseAdapter.response(from: ProviderProxyPayload(
            statusCode: 200,
            headers: ["X-Bad": "one\r\ntwo"]
        ))
    }
    #expect(throws: ProviderProxyResponseError.invalidHeader("Bad Header")) {
        try ProviderProxyResponseAdapter.response(from: ProviderProxyPayload(
            statusCode: 200,
            headers: ["Bad Header": "value"]
        ))
    }
    #expect(throws: ProviderProxyResponseError.invalidHeader("Content-Type")) {
        try ProviderProxyResponseAdapter.response(from: ProviderProxyPayload(
            statusCode: 200,
            contentType: "text/plain\r\nX-Injected: value"
        ))
    }
}

@Test func quickJSHTTPHostBridgeEnforcesHeadersStatusLimitsTimeoutAndCancellation() async throws {
    let responseHeaders = quickJSResponseHeaders([
        AnyHashable("Set-Cookie"): ["sid=one", "sid=two"],
        AnyHashable("X-One"): "value",
    ])
    #expect(responseHeaders == [
        "Set-Cookie": .array([.string("sid=one"), .string("sid=two")]),
        "X-One": .string("value"),
    ])

    let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent("provider-quickjs-http-\(UUID().uuidString)", isDirectory: true)
    let package = temporary.appendingPathComponent("package", isDirectory: true)
    let state = temporary.appendingPathComponent("state", isDirectory: true)
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let okURL = URL(string: "https://quickjs-host.test/ok")!
    let statusURL = URL(string: "https://quickjs-host.test/status")!
    let largeURL = URL(string: "https://quickjs-host.test/large")!
    let timeoutURL = URL(string: "https://quickjs-host.test/timeout")!
    let slowURL = URL(string: "https://quickjs-host.test/slow")!
    let headerURL = URL(string: "https://quickjs-host.test/header")!
    let multipartURL = URL(string: "https://quickjs-host.test/multipart")!
    let formURL = URL(string: "https://quickjs-host.test/form")!
    let bodyURL = URL(string: "https://quickjs-host.test/body")!
    let cookieProbeURL = URL(string: "https://quickjs-host.test/cookie-probe")!
    let redirectURL = URL(string: "https://quickjs-host.test/redirect")!
    let redirectedURL = URL(string: "https://quickjs-host.test/redirected")!
    let latin1URL = URL(string: "https://quickjs-host.test/latin1")!
    let gbkURL = URL(string: "https://quickjs-host.test/gbk")!
    let unknownCharsetURL = URL(string: "https://quickjs-host.test/unknown-charset")!
    QuickJSHostURLProtocol.install([
        okURL: .init(
            statusCode: 200,
            headers: ["Content-Type": "application/json", "Set-Cookie": "sid=fixture"],
            data: Data("{\"ok\":true}".utf8)
        ),
        statusURL: .init(statusCode: 404, data: Data("missing".utf8)),
        largeURL: .init(statusCode: 200, data: Data(repeating: 0x41, count: 32)),
        timeoutURL: .init(statusCode: 200, data: Data("late".utf8), delay: 0.2),
        slowURL: .init(statusCode: 200, data: Data("slow".utf8), delay: 0.3),
        headerURL: .init(statusCode: 200, data: Data()),
        multipartURL: .init(statusCode: 201, data: Data("created".utf8)),
        formURL: .init(statusCode: 200, data: Data("form".utf8)),
        bodyURL: .init(statusCode: 200, data: Data("body".utf8)),
        cookieProbeURL: .init(statusCode: 200, data: Data("probe".utf8)),
        redirectURL: .init(
            statusCode: 302,
            headers: ["Location": redirectedURL.absoluteString],
            data: Data(),
            redirectURL: redirectedURL
        ),
        redirectedURL: .init(statusCode: 200, data: Data("redirected".utf8)),
        latin1URL: .init(statusCode: 200, data: Data([0xE9])),
        gbkURL: .init(statusCode: 200, data: Data([0xD6, 0xD0])),
        unknownCharsetURL: .init(statusCode: 200, data: Data("plain".utf8)),
    ])
    defer { QuickJSHostURLProtocol.reset() }

    let runtimeDirectory = package.appendingPathComponent("runtimes/quickjs/bin", isDirectory: true)
    try FileManager.default.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)
    let runtime = runtimeDirectory.appendingPathComponent("qjs")
    let runtimeScript = """
    #!/bin/sh
    set -eu
    while IFS= read -r line; do
        request_id=$(printf '%s' "$line" | sed -E 's/.*"request_id":"([^"]*)".*/\\1/')
        case "$line" in
            *handshake*) printf '{"request_id":"%s","ok":true,"result":{"protocol":1,"provider_id":"%s","capabilities":["core-lifecycle","http","jsp","crypto","persistence"]},"error":null}\\n' "$request_id" "$NETVPLAYER_PROVIDER_ID" ;;
            *'"path":"fast"'*) printf '{"request_id":"%s","ok":true,"result":{"fast":true},"error":null}\\n' "$request_id" ;;
            *home*)
                target='https://quickjs-host.test/ok'
                timeout=10000
                case "$line" in
                    *jsp*)
                        host_id="host-$request_id"
                        printf '{"type":"host_request","request_id":"%s","capability":"jsp","operation":"query","options":{"mode":"pdfh","html":"<div class=title>JSP fixture</div>","rule":".title&&Text"}}\\n' "$host_id"
                        IFS= read -r host_response
                        printf '{"request_id":"%s","ok":true,"result":%s,"error":null}\\n' "$request_id" "$host_response"
                        continue
                        ;;
                    *crypto*)
                        host_id="host-$request_id"
                        printf '{"type":"host_request","request_id":"%s","capability":"crypto","operation":"aes","options":{"mode":"AES/CBC/PKCS5Padding","encrypt":true,"input":"hello","in_base64":false,"key":"0123456789abcdef","iv":"abcdef9876543210","out_base64":true}}\n' "$host_id"
                        IFS= read -r host_response
                        printf '{"request_id":"%s","ok":true,"result":%s,"error":null}\n' "$request_id" "$host_response"
                        continue
                        ;;
                    *local*)
                        host_id="host-$request_id"
                        printf '{"type":"host_request","request_id":"%s","capability":"persistence","operation":"get","options":{"rule":"fixture","key":"token"}}\n' "$host_id"
                        IFS= read -r host_response
                        printf '{"request_id":"%s","ok":true,"result":%s,"error":null}\n' "$request_id" "$host_response"
                        continue
                        ;;
                    *denied*)
                        host_id="host-$request_id"
                        printf '{"type":"host_request","request_id":"%s","capability":"local_proxy","operation":"request","options":{}}\n' "$host_id"
                        IFS= read -r host_response
                        printf '{"request_id":"%s","ok":true,"result":%s,"error":null}\n' "$request_id" "$host_response"
                        continue
                        ;;
                    *large*) target='https://quickjs-host.test/large' ;;
                    *status*) target='https://quickjs-host.test/status' ;;
                    *timeout*) target='https://quickjs-host.test/timeout' ; timeout=20 ;;
                    *slow*) target='https://quickjs-host.test/slow' ;;
                esac
                case "$line" in
                    *crash*) exit 7 ;;
                esac
                host_id="host-$request_id"
                printf '{"type":"host_request","request_id":"%s","capability":"http","operation":"request","url":"%s","options":{"method":"GET","timeout":%s,"headers":{"X-Fixture":"yes","Cookie":"session=abc"}}}\\n' "$host_id" "$target" "$timeout"
                IFS= read -r host_response
                case "$host_response" in
                    *'"operation":"cancel"'*) printf '{"type":"host_cancel","request_id":"%s"}\\n' "$host_id" ; continue ;;
                esac
                printf '{"request_id":"%s","ok":true,"result":%s,"error":null}\\n' "$request_id" "$host_response"
                ;;
            *health*) printf '{"request_id":"%s","ok":true,"result":{"status":"ok"},"error":null}\\n' "$request_id" ;;
            *shutdown*) printf '{"request_id":"%s","ok":true,"result":{"shutdown":true},"error":null}\\n' "$request_id" ; break ;;
            *) printf '{"request_id":"%s","ok":true,"result":{},"error":null}\\n' "$request_id" ;;
        esac
    done
    """
    try Data(runtimeScript.utf8).write(to: runtime)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runtime.path)
    let runner = package.appendingPathComponent("runner.mjs")
    let entrypoint = package.appendingPathComponent("provider.mjs")
    try Data("export default {};\n".utf8).write(to: runner)
    try Data("export default {};\n".utf8).write(to: entrypoint)

    let manifest = ProviderManifest(
        providerID: "fixture.quickjs.http",
        version: "1.0.0",
        shellMinimumVersion: "1.0.0",
        macOSMinimumVersion: "1.0",
        architectures: [ProviderManifestVerifier.currentArchitecture],
        runtime: .quickJS,
        entrypoint: "provider.mjs",
        runner: "runner.mjs",
        runtimeExecutable: "runtimes/quickjs/bin/qjs",
        capabilities: [.home],
        assets: [],
        hostCapabilities: [.http, .jsp, .crypto, .persistence],
        license: "MIT"
    )
    let command = try ProviderCommandBuilder.command(
        manifest: manifest,
        packageRoot: package,
        stateDirectoryURL: state
    )
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [QuickJSHostURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let directHost = QuickJSHTTPHost(session: session, maximumResponseBytes: 16)

    let headerResponse = await directHost.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "http-header-method",
        capability: "http",
        operation: "request",
        url: headerURL.absoluteString,
        options: ["method": .string("header")]
    ))
    #expect(headerResponse.ok)
    #expect(QuickJSHostURLProtocol.method(for: headerURL) == "HEAD")

    let fallbackMethodResponse = await directHost.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "http-unsupported-method-fallback",
        capability: "http",
        operation: "request",
        url: headerURL.absoluteString,
        options: ["method": .string("PUT")]
    ))
    #expect(fallbackMethodResponse.ok)
    #expect(QuickJSHostURLProtocol.method(for: headerURL) == "GET")

    let noTimeoutResponse = await directHost.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "http-timeout-disabled",
        capability: "http",
        operation: "request",
        url: timeoutURL.absoluteString,
        options: ["timeout": .number(0)]
    ))
    #expect(noTimeoutResponse.ok)
    #expect(noTimeoutResponse.result == .object([
        "code": .number(200),
        "status": .number(200),
        "headers": .object(["Content-Length": .string("4")]),
        "content": .string("late"),
        "content_base64": .string("bGF0ZQ=="),
        "url": .string(timeoutURL.absoluteString),
    ]))

    let invalidTimeoutResponse = await directHost.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "http-timeout-negative",
        capability: "http",
        operation: "request",
        url: timeoutURL.absoluteString,
        options: ["timeout": .number(-1)]
    ))
    #expect(!invalidTimeoutResponse.ok)
    #expect(invalidTimeoutResponse.error?.code == "invalid_timeout")

    let multipartResponse = await directHost.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "http-form-data",
        capability: "http",
        operation: "request",
        url: multipartURL.absoluteString,
        options: [
            "method": .string("POST"),
            "postType": .string("form-data"),
            "data": .object(["alpha": .string("one"), "beta": .string("two")]),
        ]
    ))
    #expect(multipartResponse.ok)
    let multipartHeaders = QuickJSHostURLProtocol.headers(for: multipartURL) ?? [:]
    let multipartContentType = multipartHeaders.first(where: { $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame })?.value ?? ""
    #expect(multipartContentType.hasPrefix("multipart/form-data; boundary=dio-boundary-"))
    let multipartBody = String(decoding: QuickJSHostURLProtocol.body(for: multipartURL) ?? Data(), as: UTF8.self)
    #expect(multipartBody.contains("name=\"alpha\"\r\n\r\none"))
    #expect(multipartBody.contains("name=\"beta\"\r\n\r\ntwo"))
    #expect(multipartBody.contains("--\(multipartContentType.split(separator: "=").last ?? "")--\r\n"))

    let trimmedPrimitiveResponse = await directHost.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "http-form-android-string-coercion",
        capability: "http",
        operation: "request",
        url: formURL.absoluteString,
        options: [
            "method": .string("POST"),
            "postType": .string("form"),
            "headers": .object([
                "X-Trim": .string("  padded  "),
                "X-Count": .number(7),
                "X-Flag": .bool(true),
            ]),
            "data": .object([
                "text": .string("  two  "),
                "count": .number(7),
                "flag": .bool(true),
            ]),
        ]
    ))
    #expect(trimmedPrimitiveResponse.ok)
    #expect(QuickJSHostURLProtocol.headers(for: formURL)?["X-Trim"] == "padded")
    #expect(QuickJSHostURLProtocol.headers(for: formURL)?["X-Count"] == "7")
    #expect(QuickJSHostURLProtocol.headers(for: formURL)?["X-Flag"] == "true")
    #expect(String(decoding: QuickJSHostURLProtocol.body(for: formURL) ?? Data(), as: UTF8.self) == "count=7&flag=true&text=two")

    let nonObjectFormResponse = await directHost.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "http-form-non-object",
        capability: "http",
        operation: "request",
        url: formURL.absoluteString,
        options: [
            "method": .string("POST"),
            "postType": .string("form"),
            "data": .string("ignored"),
        ]
    ))
    #expect(nonObjectFormResponse.ok)
    #expect(QuickJSHostURLProtocol.body(for: formURL) == Data())

    let rawBodyWithoutContentType = await directHost.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "http-body-without-content-type",
        capability: "http",
        operation: "request",
        url: bodyURL.absoluteString,
        options: ["method": .string("POST"), "body": .string("ignored")]
    ))
    #expect(rawBodyWithoutContentType.ok)
    #expect(QuickJSHostURLProtocol.body(for: bodyURL) == Data())

    let rawBodyWithContentType = await directHost.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "http-body-with-content-type",
        capability: "http",
        operation: "request",
        url: bodyURL.absoluteString,
        options: [
            "method": .string("POST"),
            "headers": .object(["Content-Type": .string("text/plain")]),
            "body": .string("kept"),
        ]
    ))
    #expect(rawBodyWithContentType.ok)
    #expect(QuickJSHostURLProtocol.body(for: bodyURL) == Data("kept".utf8))

    let mixedCasePostTypeResponse = await directHost.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "http-mixed-case-post-type",
        capability: "http",
        operation: "request",
        url: bodyURL.absoluteString,
        options: [
            "method": .string("POST"),
            "postType": .string("JSON"),
            "headers": .object(["Content-Type": .string("text/plain")]),
            "data": .object(["ignored": .string("value")]),
            "body": .string("fallback"),
        ]
    ))
    #expect(mixedCasePostTypeResponse.ok)
    #expect(QuickJSHostURLProtocol.body(for: bodyURL) == Data("fallback".utf8))

    let encodedBodyResponse = await directHost.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "http-body-charset",
        capability: "http",
        operation: "request",
        url: bodyURL.absoluteString,
        options: [
            "method": .string("POST"),
            "headers": .object(["Content-Type": .string("text/plain; charset=iso-8859-1")]),
            "body": .string("é"),
        ]
    ))
    #expect(encodedBodyResponse.ok)
    #expect(QuickJSHostURLProtocol.body(for: bodyURL) == Data([0xE9]))

    let cookieSeedResponse = await directHost.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "http-cookie-seed",
        capability: "http",
        operation: "request",
        url: okURL.absoluteString,
        options: [:]
    ))
    #expect(cookieSeedResponse.ok)
    let cookieProbeResponse = await directHost.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "http-cookie-probe",
        capability: "http",
        operation: "request",
        url: cookieProbeURL.absoluteString,
        options: [:]
    ))
    #expect(cookieProbeResponse.ok)
    #expect(QuickJSHostURLProtocol.headers(for: cookieProbeURL)?["Cookie"] == nil)

    let redirectDelegate = QuickJSHTTPRedirectDelegate(followsRedirects: false)
    var rejectedRedirect: URLRequest?
    redirectDelegate.urlSession(
        URLSession.shared,
        task: URLSession.shared.dataTask(with: redirectURL),
        willPerformHTTPRedirection: HTTPURLResponse(
            url: redirectURL,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": redirectedURL.absoluteString]
        )!,
        newRequest: URLRequest(url: redirectedURL)
    ) { rejectedRedirect = $0 }
    #expect(rejectedRedirect == nil)

    let acceptingDelegate = QuickJSHTTPRedirectDelegate(followsRedirects: true)
    var acceptedRedirect: URLRequest?
    acceptingDelegate.urlSession(
        URLSession.shared,
        task: URLSession.shared.dataTask(with: redirectURL),
        willPerformHTTPRedirection: HTTPURLResponse(
            url: redirectURL,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": redirectedURL.absoluteString]
        )!,
        newRequest: URLRequest(url: redirectedURL)
    ) { acceptedRedirect = $0 }
    #expect(acceptedRedirect?.url == redirectedURL)

    let rejectedResponse = await directHost.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "http-redirect-disabled",
        capability: "http",
        operation: "request",
        url: redirectURL.absoluteString,
        options: ["redirect": .number(0)]
    ))
    #expect(rejectedResponse.ok)
    #expect(rejectedResponse.result == .object([
        "code": .number(302),
        "status": .number(302),
        "headers": .object([
            "Content-Length": .string("0"),
            "Location": .string(redirectedURL.absoluteString),
        ]),
        "content": .string(""),
        "content_base64": .string(""),
        "url": .string(redirectURL.absoluteString),
    ]))

    let followedResponse = await directHost.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "http-redirect-enabled",
        capability: "http",
        operation: "request",
        url: redirectURL.absoluteString,
        options: ["redirect": .number(1)]
    ))
    #expect(followedResponse.ok)
    #expect(followedResponse.result == .object([
        "code": .number(200),
        "status": .number(200),
        "headers": .object(["Content-Length": .string("10")]),
        "content": .string("redirected"),
        "content_base64": .string("cmVkaXJlY3RlZA=="),
        "url": .string(redirectedURL.absoluteString),
    ]))

    let latin1Response = await directHost.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "http-latin1",
        capability: "http",
        operation: "request",
        url: latin1URL.absoluteString,
        options: ["headers": .object(["Content-Type": .string("text/plain; charset=iso-8859-1")])]
    ))
    #expect(latin1Response.result == .object([
        "code": .number(200),
        "status": .number(200),
        "headers": .object(["Content-Length": .string("1")]),
        "content": .string("é"),
        "content_base64": .string("6Q=="),
        "url": .string(latin1URL.absoluteString),
    ]))

    let gbkResponse = await directHost.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "http-gbk",
        capability: "http",
        operation: "request",
        url: gbkURL.absoluteString,
        options: ["headers": .object(["Content-Type": .string("text/plain; charset=gbk")])]
    ))
    #expect(gbkResponse.result == .object([
        "code": .number(200),
        "status": .number(200),
        "headers": .object(["Content-Length": .string("2")]),
        "content": .string("中"),
        "content_base64": .string("1tA="),
        "url": .string(gbkURL.absoluteString),
    ]))

    let unknownCharsetResponse = await directHost.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "http-unknown-charset",
        capability: "http",
        operation: "request",
        url: unknownCharsetURL.absoluteString,
        options: ["headers": .object(["Content-Type": .string("text/plain; charset=x-netvplayer-unknown")])]
    ))
    #expect(!unknownCharsetResponse.ok)
    #expect(unknownCharsetResponse.error?.code == "unsupported_charset")

    let directConcurrentResponses = await withTaskGroup(of: QuickJSHostResponse.self) { group in
        for index in 0..<4 {
            group.addTask {
                await directHost.handle(QuickJSHostControl(
                    type: "host_request",
                    requestID: "direct-concurrent-\(index)",
                    capability: "http",
                    operation: "request",
                    url: okURL.absoluteString,
                    options: [:]
                ))
            }
        }
        var responses: [QuickJSHostResponse] = []
        for await response in group { responses.append(response) }
        return responses
    }
    #expect(directConcurrentResponses.count == 4)
    #expect(directConcurrentResponses.filter(\.ok).count == 4)

    let client = ProviderProcessClient(
        command: command,
        httpSession: session,
        maximumHTTPResponseBytes: 16
    )

    _ = try await client.request(
        ProviderRequest(providerID: manifest.providerID, operation: .handshake),
        timeout: .seconds(2)
    )
    let ok = try await client.request(
        ProviderRequest(
            providerID: manifest.providerID,
            operation: .home,
            arguments: ["path": .string("ok")]
        ),
        timeout: .seconds(2)
    )
    guard case .object(let okEnvelope) = ok.result,
          case .object(let okResult) = okEnvelope["result"] else {
        Issue.record("Expected a successful QuickJS host response")
        return
    }
    #expect(okEnvelope["ok"] == .bool(true))
    #expect(okResult["code"] == .number(200))
    #expect(okResult["content"] == .string("{\"ok\":true}"))
    #expect(QuickJSHostURLProtocol.headers(for: okURL)?["X-Fixture"] == "yes")
    #expect(QuickJSHostURLProtocol.headers(for: okURL)?["Cookie"] == "session=abc")

    let jsp = try await client.request(
        ProviderRequest(
            providerID: manifest.providerID,
            operation: .home,
            arguments: ["path": .string("jsp")]
        ),
        timeout: .seconds(2)
    )
    guard case .object(let jspEnvelope) = jsp.result,
          case .object(let jspResult) = jspEnvelope["result"] else {
        Issue.record("Expected a QuickJS JSP host response")
        return
    }
    #expect(jspEnvelope["ok"] == .bool(true))
    #expect(jspResult["value"] == .string("JSP fixture"))

    let crypto = try await client.request(
        ProviderRequest(
            providerID: manifest.providerID,
            operation: .home,
            arguments: ["path": .string("crypto")]
        ),
        timeout: .seconds(2)
    )
    guard case .object(let cryptoEnvelope) = crypto.result,
          case .object(let cryptoResult) = cryptoEnvelope["result"] else {
        Issue.record("Expected a QuickJS crypto host response")
        return
    }
    #expect(cryptoEnvelope["ok"] == .bool(true))
    #expect(cryptoResult["value"] == .string("rkbumbtCClkN+Jkds7bQJw=="))

    let local = try await client.request(
        ProviderRequest(
            providerID: manifest.providerID,
            operation: .home,
            arguments: ["path": .string("local")]
        ),
        timeout: .seconds(2)
    )
    guard case .object(let localEnvelope) = local.result,
          case .object(let localResult) = localEnvelope["result"] else {
        Issue.record("Expected a QuickJS persistence host response")
        return
    }
    #expect(localEnvelope["ok"] == .bool(true))
    #expect(localResult["value"] == .string(""))

    let notFound = try await client.request(
        ProviderRequest(
            providerID: manifest.providerID,
            operation: .home,
            arguments: ["path": .string("status")]
        ),
        timeout: .seconds(2)
    )
    guard case .object(let statusEnvelope) = notFound.result,
          case .object(let statusResult) = statusEnvelope["result"] else {
        Issue.record("Expected an HTTP status response")
        return
    }
    #expect(statusEnvelope["ok"] == .bool(true))
    #expect(statusResult["code"] == .number(404))

    let tooLarge = try await client.request(
        ProviderRequest(
            providerID: manifest.providerID,
            operation: .home,
            arguments: ["path": .string("large")]
        ),
        timeout: .seconds(2)
    )
    guard case .object(let largeEnvelope) = tooLarge.result,
          case .object(let largeError) = largeEnvelope["error"] else {
        Issue.record("Expected a response-size error")
        return
    }
    #expect(largeEnvelope["ok"] == .bool(false))
    #expect(largeError["code"] == .string("response_too_large"))

    let timedOut = try await client.request(
        ProviderRequest(
            providerID: manifest.providerID,
            operation: .home,
            arguments: ["path": .string("timeout")]
        ),
        timeout: .seconds(2)
    )
    guard case .object(let timeoutEnvelope) = timedOut.result,
          case .object(let timeoutError) = timeoutEnvelope["error"] else {
        Issue.record("Expected a host timeout error")
        return
    }
    #expect(timeoutEnvelope["ok"] == .bool(false))
    #expect(timeoutError["code"] == .string("request_failed"))

    let denied = try await client.request(
        ProviderRequest(
            providerID: manifest.providerID,
            operation: .home,
            arguments: ["path": .string("denied")]
        ),
        timeout: .seconds(2)
    )
    guard case .object(let deniedEnvelope) = denied.result,
          case .object(let deniedError) = deniedEnvelope["error"] else {
        Issue.record("Expected a denied host capability response")
        return
    }
    #expect(deniedEnvelope["ok"] == .bool(false))
    #expect(deniedError["code"] == .string("capability_denied"))

    let requestID = "quickjs-cancel"
    let pending = Task {
        try await client.request(
            ProviderRequest(
                requestID: requestID,
                providerID: manifest.providerID,
                operation: .home,
                arguments: ["path": .string("slow")]
            ),
            timeout: .seconds(2)
        )
    }
    try await Task.sleep(for: .milliseconds(30))
    pending.cancel()
    do {
        _ = try await pending.value
        Issue.record("Expected QuickJS host request cancellation")
    } catch {
        #expect(error as? ProviderProcessError == .canceled(requestID))
    }
    let duplicateID = "quickjs-duplicate"
    let firstRequest = ProviderRequest(
        requestID: duplicateID,
        providerID: manifest.providerID,
        operation: .home,
        arguments: ["path": .string("slow")]
    )
    let first = Task {
        try await client.request(firstRequest, timeout: .seconds(2))
    }
    try await Task.sleep(for: .milliseconds(30))
    do {
        _ = try await client.request(
            ProviderRequest(
                requestID: duplicateID,
                providerID: manifest.providerID,
                operation: .home,
                arguments: ["path": .string("ok")]
            ),
            timeout: .seconds(2)
        )
        Issue.record("Expected duplicate QuickJS request ID to be rejected")
    } catch {
        #expect(error as? ProviderProcessError == .duplicateRequest(duplicateID))
    }
    do {
        let firstResponse = try await first.value
        #expect(firstResponse.ok)
    } catch {
        Issue.record("The original QuickJS request was disrupted by a duplicate ID: \(error)")
    }

    do {
        _ = try await client.request(
            ProviderRequest(
                providerID: manifest.providerID,
                operation: .home,
                arguments: ["path": .string("crash")]
            ),
            timeout: .seconds(2)
        )
        Issue.record("Expected the QuickJS provider process to terminate")
    } catch {
        #expect(error as? ProviderProcessError == .terminated(7))
    }
    try await Task.sleep(for: .milliseconds(30))

    let health = try await client.request(
        ProviderRequest(providerID: manifest.providerID, operation: .health),
        timeout: .seconds(2)
    )
    #expect(health.ok)

    let concurrentOutcomes = await withTaskGroup(of: String.self) { group in
        for (index, path) in ["fast", "fast", "fast", "fast"].enumerated() {
            group.addTask {
                do {
                    let response = try await client.request(
                        ProviderRequest(
                            requestID: "quickjs-concurrent-\(index)",
                            providerID: manifest.providerID,
                            operation: .home,
                            arguments: ["path": .string(path)]
                        ),
                        timeout: .seconds(2)
                    )
                    return "success-\(index)-\(response.ok)"
                } catch {
                    return "error-\(index)-\(error)"
                }
            }
        }
        var outcomes: [String] = []
        for await outcome in group { outcomes.append(outcome) }
        return outcomes
    }
    #expect(concurrentOutcomes.count == 4)
    if concurrentOutcomes.contains(where: { !$0.hasPrefix("success-") }) {
        Issue.record("QuickJS concurrent request outcomes: \(concurrentOutcomes)")
    }
    await client.stop()
}

@Test func quickJSHTTPHostUsesRealLoopbackSocketForRedirectAndCharset() async throws {
    let fixture = try QuickJSRealHTTPFixture()
    let host = QuickJSHTTPHost()
    let base = "http://127.0.0.1:\(fixture.port)"

    let echoed = await host.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "real-echo",
        capability: "http",
        operation: "request",
        url: "\(base)/echo",
        options: ["headers": .object(["X-Real": .string("socket")])]
    ))
    guard case .object(let echoedResult) = echoed.result else {
        Issue.record("Expected a real socket response")
        return
    }
    #expect(echoed.ok)
    #expect(echoedResult["code"] == .number(200))
    #expect(echoedResult["content"] == .string("socket"))
    #expect(echoedResult["content_base64"] == .string("c29ja2V0"))

    let followed = await host.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "real-redirect-follow",
        capability: "http",
        operation: "request",
        url: "\(base)/redirect",
        options: ["redirect": .number(1)]
    ))
    guard case .object(let followedResult) = followed.result else {
        Issue.record("Expected a followed real redirect response")
        return
    }
    #expect(followed.ok)
    #expect(followedResult["code"] == .number(200))
    #expect(followedResult["content"] == .string("final"))

    let rejected = await host.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "real-redirect-reject",
        capability: "http",
        operation: "request",
        url: "\(base)/redirect",
        options: ["redirect": .number(0)]
    ))
    guard case .object(let rejectedResult) = rejected.result else {
        Issue.record("Expected a rejected real redirect response")
        return
    }
    #expect(rejected.ok)
    #expect(rejectedResult["code"] == .number(302))
    #expect(rejectedResult["content"] == .string("redirect-body"))
    #expect(rejectedResult["content_base64"] == .string("cmVkaXJlY3QtYm9keQ=="))

    let latin1 = await host.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "real-latin1",
        capability: "http",
        operation: "request",
        url: "\(base)/latin1",
        options: ["headers": .object(["Content-Type": .string("text/plain; charset=iso-8859-1")])]
    ))
    guard case .object(let latin1Result) = latin1.result else {
        Issue.record("Expected a real charset response")
        return
    }
    #expect(latin1.ok)
    #expect(latin1Result["content"] == .string("é"))
    #expect(latin1Result["content_base64"] == .string("6Q=="))

    let gb18030 = await host.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "real-gb18030",
        capability: "http",
        operation: "request",
        url: "\(base)/gb18030",
        options: ["headers": .object(["Content-Type": .string("text/plain; charset=gb18030")])]
    ))
    guard case .object(let gb18030Result) = gb18030.result else {
        Issue.record("Expected a real GB18030 response: \(String(describing: gb18030.error))")
        return
    }
    #expect(gb18030.ok)
    #expect(gb18030Result["content"] == .string("𠀀"))
    #expect(gb18030Result["content_base64"] == .string("lTKCNg=="))

    let multiCookie = await host.handle(QuickJSHostControl(
        type: "host_request",
        requestID: "real-multi-cookie",
        capability: "http",
        operation: "request",
        url: "\(base)/multi-cookie",
        options: ["headers": .object(["Cookie": .string("explicit=1")])]
    ))
    guard case .object(let multiCookieResult) = multiCookie.result else {
        Issue.record("Expected a real multi-cookie response: \(String(describing: multiCookie.error))")
        return
    }
    #expect(multiCookie.ok)
    #expect(multiCookieResult["content"] == .string("cookies"))
    guard case .object(let multiCookieHeaders) = multiCookieResult["headers"] else {
        Issue.record("Expected response headers in the multi-cookie result")
        return
    }
    #expect(multiCookieHeaders["Content-Length"] == .string("7"))
    #expect(multiCookieHeaders["Set-Cookie"] == .array([
        .string("a=1; Path=/"),
        .string("b=2; Path=/"),
    ]))
    #expect(multiCookieHeaders["X-Request-Cookie"] == .string("explicit=1"))
}

@Test func trustConfigurationRejectsMissingKeysAndLoadsRawKeys() throws {
    #expect(throws: ProviderTrustConfigurationError.missingKey(
        ProviderTrustConfiguration.manifestKeyName
    )) {
        try ProviderTrustConfiguration.load(infoDictionary: [:])
    }

    let manifestKey = Data(repeating: 1, count: 32)
    let distributionKey = Data(repeating: 2, count: 32)
    let configuration = try ProviderTrustConfiguration.load(infoDictionary: [
        ProviderTrustConfiguration.manifestKeyName: manifestKey.base64EncodedString(),
        ProviderTrustConfiguration.distributionKeyName: distributionKey.base64EncodedString()
    ])
    #expect(configuration.manifestPublicKey == manifestKey)
    #expect(configuration.distributionPublicKey == distributionKey)
}

@Test func androidDexCannotClaimDirectCompatibility() throws {
    let privateKey = Curve25519.Signing.PrivateKey()
    let verifier = try ProviderManifestVerifier(
        publicKeyData: privateKey.publicKey.rawRepresentation,
        shellVersion: "1.0.0"
    )
    let manifest = ProviderManifest(
        providerID: "example.dex",
        version: "1.0.0",
        shellMinimumVersion: "1.0.0",
        macOSMinimumVersion: "1.0",
        architectures: [ProviderManifestVerifier.currentArchitecture],
        runtime: .androidDex,
        entrypoint: "provider.dex",
        runner: "provider.dex",
        capabilities: [.home],
        assets: [],
        license: "MIT"
    )

    #expect(throws: ProviderVerificationError.androidDexNeedsPort) {
        try verifier.verifyCompatibility(manifest)
    }
}

@Test func processClientHandshakesExecutesAndStops() async throws {
    let runner = try #require(Bundle.module.url(
        forResource: "mock_runner",
        withExtension: "py",
        subdirectory: "Fixtures"
    ))
    let state = FileManager.default.temporaryDirectory
        .appendingPathComponent("provider-process-state-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: state) }
    let command = ProviderCommand(
        executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
        arguments: [runner.path],
        currentDirectoryURL: runner.deletingLastPathComponent(),
        stateDirectoryURL: state,
        environment: [
            "NETVPLAYER_PROVIDER_ID": "fixture.provider",
            "NETVPLAYER_PROVIDER_STATE": state.path,
        ]
    )
    let client = ProviderProcessClient(command: command)

    let handshake = try await client.request(ProviderRequest(
        providerID: "fixture.provider",
        operation: .handshake
    ))
    #expect(handshake.ok)
    #expect(handshake.result == .object([
        "protocol": .number(1),
        "provider_id": .string("fixture.provider"),
        "runtime": .string("fixture")
    ]))

    let response = try await client.request(ProviderRequest(
        providerID: "fixture.provider",
        operation: .search,
        arguments: ["keyword": .string("swift")]
    ))
    #expect(response.result == .object(["keyword": .string("swift")]))

    await client.stop()
    #expect(await client.isRunning == false)

    let diagnosticsURL = state
        .appendingPathComponent("diagnostics", isDirectory: true)
        .appendingPathComponent("provider-events.jsonl")
    let diagnosticsDecoder = JSONDecoder()
    diagnosticsDecoder.dateDecodingStrategy = .iso8601
    let diagnostics = try String(contentsOf: diagnosticsURL, encoding: .utf8)
        .split(separator: "\n")
        .map { try diagnosticsDecoder.decode(ProviderDiagnosticEvent.self, from: Data($0.utf8)) }
    #expect(diagnostics.contains { $0.code == .processStarted && $0.processID != nil })
    #expect(diagnostics.contains { $0.code == .requestCompleted && $0.requestID == handshake.requestID })
    #expect(diagnostics.contains { $0.code == .processStopped })
}

@Test func processClientPreservesChunkOrderForConcurrentLargeResponses() async throws {
    let runner = try #require(Bundle.module.url(
        forResource: "mock_runner",
        withExtension: "py",
        subdirectory: "Fixtures"
    ))
    let state = FileManager.default.temporaryDirectory
        .appendingPathComponent("provider-process-large-response-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: state) }
    let command = ProviderCommand(
        executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
        arguments: [runner.path],
        currentDirectoryURL: runner.deletingLastPathComponent(),
        stateDirectoryURL: state,
        environment: [
            "NETVPLAYER_PROVIDER_ID": "fixture.provider",
            "NETVPLAYER_PROVIDER_STATE": state.path,
        ]
    )
    let client = ProviderProcessClient(command: command)
    let payloadBytes = 1024 * 1024

    let results = try await withThrowingTaskGroup(of: (String, ProviderResponse).self) { group in
        for index in 0..<4 {
            let marker = "response-\(index)"
            group.addTask {
                let response = try await client.request(ProviderRequest(
                    providerID: "fixture.provider",
                    operation: .search,
                    arguments: [
                        "large_result_bytes": .number(Double(payloadBytes)),
                        "marker": .string(marker),
                    ]
                ))
                return (marker, response)
            }
        }
        var responses: [String: ProviderResponse] = [:]
        for try await (marker, response) in group {
            responses[marker] = response
        }
        return responses
    }

    #expect(results.count == 4)
    for index in 0..<4 {
        let marker = "response-\(index)"
        guard case .object(let result)? = results[marker]?.result,
              case .string(let receivedMarker)? = result["marker"],
              case .string(let payload)? = result["payload"] else {
            Issue.record("Missing decoded large response for \(marker)")
            continue
        }
        #expect(receivedMarker == marker)
        #expect(payload.utf8.count == payloadBytes)
    }

    await client.stop()
    let diagnosticsURL = state
        .appendingPathComponent("diagnostics", isDirectory: true)
        .appendingPathComponent("provider-events.jsonl")
    let diagnostics = try String(contentsOf: diagnosticsURL, encoding: .utf8)
    #expect(!diagnostics.contains("\"code\":\"protocol.invalid_response\""))
}

@Test func providerDiagnosticWriterRotatesJSONLAndKeepsSensitiveValuesRedacted() throws {
    let state = FileManager.default.temporaryDirectory
        .appendingPathComponent("provider-diagnostics-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: state) }
    let writer = ProviderDiagnosticJSONLWriter(
        stateDirectoryURL: state,
        maximumBytes: 256,
        archiveCount: 2
    )

    for index in 0..<4 {
        try writer.record(ProviderDiagnosticEvent(
            level: .warning,
            category: .standardError,
            code: .standardErrorOutput,
            providerID: "fixture.provider",
            message: "event=\(index) https://example.invalid/video?token=secret Cookie: session=secret "
                + String(repeating: "x", count: 180)
        ))
    }

    #expect(FileManager.default.fileExists(atPath: writer.fileURL.path))
    #expect(FileManager.default.fileExists(atPath: writer.fileURL.path + ".1"))
    #expect(FileManager.default.fileExists(atPath: writer.fileURL.path + ".2"))
    let current = try String(contentsOf: writer.fileURL, encoding: .utf8)
    #expect(!current.contains("example.invalid"))
    #expect(!current.contains("session=secret"))
    #expect(current.contains("process.stderr"))
}

@Test func processEnvironmentIsProviderScopedAndRejectsOverrides() throws {
    let state = FileManager.default.temporaryDirectory
        .appendingPathComponent("provider-environment-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: state) }
    let executable = URL(fileURLWithPath: "/usr/bin/true")
    let command = ProviderCommand(
        executableURL: executable,
        arguments: [],
        currentDirectoryURL: state,
        stateDirectoryURL: state,
        environment: [
            "NETVPLAYER_PROVIDER_ID": "fixture.environment",
            "NETVPLAYER_PROVIDER_STATE": state.path,
        ]
    )

    let environment = try ProviderProcessClient.launchEnvironment(for: command)
    #expect(environment["PATH"] == "/usr/bin:/bin")
    #expect(environment["HOME"] == state.appendingPathComponent("home").path)
    #expect(environment["TMPDIR"] == state.appendingPathComponent("tmp").path + "/")
    #expect(environment["SSH_AUTH_SOCK"] == nil)
    #expect(environment["HOME"] != ProcessInfo.processInfo.environment["HOME"])
    let permissions = try #require(
        FileManager.default.attributesOfItem(atPath: state.path)[.posixPermissions] as? NSNumber
    )
    #expect(permissions.intValue & 0o777 == 0o700)

    var unsafe = command
    unsafe.environment["HOME"] = "/tmp/escape"
    #expect(throws: ProviderProcessError.invalidEnvironment("HOME")) {
        try ProviderProcessClient.launchEnvironment(for: unsafe)
    }

    var sandboxed = command
    sandboxed.environment["NETVPLAYER_PROVIDER_SANDBOX"] = "app-sandbox-v2"
    #expect(
        try ProviderProcessClient.launchEnvironment(for: sandboxed)["NETVPLAYER_PROVIDER_SANDBOX"]
            == "app-sandbox-v2"
    )
}

@Test func sandboxManifestRoundTripsWithProviderScopedBindings() throws {
    let configuration = ProviderSandboxConfiguration(
        launcher: "Sandbox/ProviderSandboxLauncher.app/Contents/MacOS/ProviderSandboxLauncher",
        bundleIdentifier: "com.netvplayer.provider.fixture.sandbox",
        releaseProfile: .communityAdhoc
    )
    let manifest = ProviderManifest(
        providerID: "fixture.sandbox",
        version: "1.0.0",
        shellMinimumVersion: "1.0.0",
        architectures: [ProviderManifestVerifier.currentArchitecture],
        runtime: .python,
        entrypoint: "provider.py",
        runner: "runner.py",
        runtimeExecutable: "runtimes/cpython/bin/python3",
        sandbox: configuration,
        capabilities: [.home, .search, .proxy],
        assets: [],
        sourcePolicy: .userConfiguredOnly,
        license: "fixture-only"
    )

    let decoded = try JSONDecoder().decode(
        ProviderManifest.self,
        from: JSONEncoder.providerCanonical.encode(manifest)
    )
    #expect(decoded.sandbox == configuration)
    #expect(decoded.sourcePolicy == .userConfiguredOnly)
    #expect(
        ProviderSandboxVerifier.expectedBundleIdentifier(providerID: manifest.providerID)
            == "com.netvplayer.provider.fixture.sandbox"
    )
    #expect(
        ProviderSandboxVerifier.expectedPackageReadPath(providerID: manifest.providerID)
            == "/Library/Application Support/NetVplayer/Providers/fixture.sandbox/"
    )
    #expect(
        ProviderSandboxVerifier.expectedStateWritePath(providerID: manifest.providerID)
            == "/Library/Application Support/NetVplayer/Providers/.state/fixture.sandbox/"
    )
}

@Test func commandBuilderRejectsSandboxPackageOutsideCanonicalInstallRoot() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("provider-sandbox-command-\(UUID().uuidString)", isDirectory: true)
    let state = root.appendingPathComponent("state", isDirectory: true)
    let launcher = root.appendingPathComponent(
        "Sandbox/ProviderSandboxLauncher.app/Contents/MacOS/ProviderSandboxLauncher"
    )
    try FileManager.default.createDirectory(at: launcher.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    try Data().write(to: launcher)
    try Data().write(to: root.appendingPathComponent("runner.py"))
    try Data().write(to: root.appendingPathComponent("provider.py"))
    try Data().write(to: root.appendingPathComponent("python3"))
    defer { try? FileManager.default.removeItem(at: root) }
    let manifest = ProviderManifest(
        providerID: "fixture.sandbox-location",
        version: "1.0.0",
        shellMinimumVersion: "1.0.0",
        architectures: [ProviderManifestVerifier.currentArchitecture],
        runtime: .python,
        entrypoint: "provider.py",
        runner: "runner.py",
        runtimeExecutable: "python3",
        sandbox: ProviderSandboxConfiguration(
            launcher: "Sandbox/ProviderSandboxLauncher.app/Contents/MacOS/ProviderSandboxLauncher",
            bundleIdentifier: "com.netvplayer.provider.fixture.sandbox-location",
            releaseProfile: .communityAdhoc
        ),
        capabilities: [.home],
        assets: [],
        license: "fixture-only"
    )

    #expect(throws: ProviderSandboxVerificationError.invalidInstallLocation(root.path)) {
        try ProviderCommandBuilder.command(
            manifest: manifest,
            packageRoot: root,
            stateDirectoryURL: state
        )
    }
}

@Test func commandBuilderBindsSignedPackageAndStateRoots() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("provider-command-\(UUID().uuidString)", isDirectory: true)
    let state = root.appendingPathComponent("state", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data().write(to: root.appendingPathComponent("runner"))
    try Data().write(to: root.appendingPathComponent("provider.mjs"))
    let manifest = ProviderManifest(
        providerID: "fixture.command",
        version: "1.0.0",
        shellMinimumVersion: "1.0.0",
        macOSMinimumVersion: "1.0",
        architectures: [ProviderManifestVerifier.currentArchitecture],
        runtime: .javaScript,
        entrypoint: "provider.mjs",
        runner: "runner",
        capabilities: [.home],
        assets: [],
        license: "MIT"
    )

    let command = try ProviderCommandBuilder.command(
        manifest: manifest,
        packageRoot: root,
        stateDirectoryURL: state
    )
    #expect(command.currentDirectoryURL == root)
    #expect(command.stateDirectoryURL == state)
    #expect(command.environment["NETVPLAYER_PROVIDER_ROOT"] == root.path)
    #expect(command.environment["NETVPLAYER_PROVIDER_STATE"] == state.path)
}

@Test func commandBuilderWrapsQuickJSCosmopolitanRuntimeWithShell() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("provider-quickjs-command-\(UUID().uuidString)", isDirectory: true)
    let state = root.appendingPathComponent("state", isDirectory: true)
    let runner = root.appendingPathComponent("provider-runners/quickjs/provider_runner.mjs")
    let entrypoint = root.appendingPathComponent("provider/fixture.mjs")
    let runtime = root.appendingPathComponent("runtimes/quickjs/bin/qjs")
    try FileManager.default.createDirectory(at: runner.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: entrypoint.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: runtime.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    try Data().write(to: runner)
    try Data().write(to: entrypoint)
    try Data("MZqFpD='\n".utf8).write(to: runtime)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runtime.path)
    defer { try? FileManager.default.removeItem(at: root) }

    let manifest = ProviderManifest(
        providerID: "fixture.quickjs",
        version: "1.0.0",
        shellMinimumVersion: "1.0.0",
        architectures: [ProviderManifestVerifier.currentArchitecture],
        runtime: .quickJS,
        entrypoint: "provider/fixture.mjs",
        runner: "provider-runners/quickjs/provider_runner.mjs",
        runtimeExecutable: "runtimes/quickjs/bin/qjs",
        capabilities: [.home],
        assets: [],
        hostCapabilities: [.console, .base64, .md5, .url],
        license: "MIT"
    )

    let command = try ProviderCommandBuilder.command(
        manifest: manifest,
        packageRoot: root,
        stateDirectoryURL: state
    )
    #expect(command.executableURL.path == "/bin/sh")
    #expect(command.arguments == [runtime.path, runner.path, "--provider", entrypoint.path])
    #expect(command.environment["NETVPLAYER_PROVIDER_HOST_CAPABILITIES"] == "console,base64,md5,url")
}

@Test func packageStoreCreatesPrivateProviderStateDirectories() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("provider-store-state-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let key = Curve25519.Signing.PrivateKey()
    let verifier = try ProviderManifestVerifier(
        publicKeyData: key.publicKey.rawRepresentation,
        shellVersion: "1.0.0"
    )
    let store = ProviderPackageStore(rootURL: root, verifier: verifier)

    let first = try await store.stateDirectory(providerID: "fixture.first")
    let second = try await store.stateDirectory(providerID: "fixture.second")
    #expect(first != second)
    #expect(first.path.hasSuffix("/.state/fixture.first"))
    let permissions = try #require(
        FileManager.default.attributesOfItem(atPath: first.path)[.posixPermissions] as? NSNumber
    )
    #expect(permissions.intValue & 0o777 == 0o700)
    await #expect(throws: ProviderPackageStoreError.self) {
        try await store.stateDirectory(providerID: "../escape")
    }
}

@Test func packageStoreRejectsSymlinkedProviderStateRoot() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("provider-store-symlink-\(UUID().uuidString)", isDirectory: true)
    let outside = FileManager.default.temporaryDirectory
        .appendingPathComponent("provider-store-outside-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: outside)
    }
    try FileManager.default.createSymbolicLink(
        at: root.appendingPathComponent(".state"),
        withDestinationURL: outside
    )
    let key = Curve25519.Signing.PrivateKey()
    let verifier = try ProviderManifestVerifier(
        publicKeyData: key.publicKey.rawRepresentation,
        shellVersion: "1.0.0"
    )
    let store = ProviderPackageStore(rootURL: root, verifier: verifier)

    await #expect(throws: ProviderPackageStoreError.unsafeStateDirectory(root.appendingPathComponent(".state").path)) {
        try await store.stateDirectory(providerID: "fixture.symlink")
    }
    #expect((try FileManager.default.contentsOfDirectory(atPath: outside.path)).isEmpty)
}

@Test func signedDistributionIndexRejectsArbitraryURLsAndRevokedReleases() throws {
    let privateKey = Curve25519.Signing.PrivateKey()
    let verifier = try ProviderDistributionIndexVerifier(
        publicKeyData: privateKey.publicKey.rawRepresentation,
        architecture: "arm64"
    )
    let release = ProviderRelease(
        providerID: "fixture.provider",
        version: "1.0.0",
        architectures: ["arm64"],
        archiveURL: try #require(URL(string: "https://providers.example.invalid/fixture.zip")),
        archiveSHA256: String(repeating: "a", count: 64)
    )
    let x86Release = ProviderRelease(
        providerID: "fixture.provider",
        version: "1.0.0",
        architectures: ["x86_64"],
        archiveURL: try #require(URL(string: "https://providers.example.invalid/fixture-x86_64.zip")),
        archiveSHA256: String(repeating: "c", count: 64)
    )
    let index = ProviderDistributionIndex(
        generatedAt: Date(timeIntervalSince1970: 0),
        releases: [release, x86Release]
    )
    let signature = try privateKey.signature(for: JSONEncoder.providerCanonical.encode(index))
    let verified = try verifier.verify(SignedProviderDistributionIndex(
        index: index,
        signature: signature.base64EncodedString()
    ))
    #expect(verified.count == 1)
    #expect(verified[0].providerID == "fixture.provider")
    #expect(verified[0].architectures == ["arm64"])

    let overlappingIndex = ProviderDistributionIndex(
        generatedAt: Date(timeIntervalSince1970: 0),
        releases: [release, release]
    )
    let overlappingSignature = try privateKey.signature(
        for: JSONEncoder.providerCanonical.encode(overlappingIndex)
    )
    #expect(throws: ProviderDistributionError.manifestMismatch) {
        try verifier.verify(SignedProviderDistributionIndex(
            index: overlappingIndex,
            signature: overlappingSignature.base64EncodedString()
        ))
    }

    let duplicateDeclaration = ProviderRelease(
        providerID: "fixture.provider",
        version: "1.0.1",
        architectures: ["arm64", "arm64"],
        archiveURL: try #require(URL(string: "https://providers.example.invalid/fixture-duplicate.zip")),
        archiveSHA256: String(repeating: "d", count: 64)
    )
    let duplicateIndex = ProviderDistributionIndex(
        generatedAt: Date(timeIntervalSince1970: 0),
        releases: [duplicateDeclaration]
    )
    let duplicateSignature = try privateKey.signature(
        for: JSONEncoder.providerCanonical.encode(duplicateIndex)
    )
    #expect(throws: ProviderDistributionError.manifestMismatch) {
        try verifier.verify(SignedProviderDistributionIndex(
            index: duplicateIndex,
            signature: duplicateSignature.base64EncodedString()
        ))
    }

    let insecureRelease = ProviderRelease(
        providerID: "fixture.provider",
        version: "1.0.1",
        architectures: ["arm64"],
        archiveURL: try #require(URL(string: "http://providers.example.invalid/fixture.zip")),
        archiveSHA256: String(repeating: "b", count: 64)
    )
    let insecureIndex = ProviderDistributionIndex(
        generatedAt: Date(timeIntervalSince1970: 0),
        releases: [insecureRelease]
    )
    let insecureSignature = try privateKey.signature(for: JSONEncoder.providerCanonical.encode(insecureIndex))
    #expect(throws: ProviderDistributionError.insecureURL) {
        try verifier.verify(SignedProviderDistributionIndex(
            index: insecureIndex,
            signature: insecureSignature.base64EncodedString()
        ))
    }

    let revokedIndex = ProviderDistributionIndex(
        generatedAt: Date(timeIntervalSince1970: 0),
        releases: [release],
        revoked: [ProviderVersionReference(providerID: release.providerID, version: release.version)]
    )
    let revokedSignature = try privateKey.signature(for: JSONEncoder.providerCanonical.encode(revokedIndex))
    #expect(throws: ProviderDistributionError.revoked) {
        try verifier.verify(SignedProviderDistributionIndex(
            index: revokedIndex,
            signature: revokedSignature.base64EncodedString()
        ))
    }
}

@Test func distributionClientRejectsInsecureIndexURL() async throws {
    let key = Curve25519.Signing.PrivateKey()
    let verifier = try ProviderDistributionIndexVerifier(
        publicKeyData: key.publicKey.rawRepresentation
    )
    let client = ProviderDistributionClient()

    await #expect(throws: ProviderDistributionError.insecureURL) {
        try await client.fetchIndex(
            from: URL(string: "http://invalid.example.test/index.json")!,
            verifier: verifier
        )
    }
}

@Test func bootstrapAutomaticallyInstallsLatestProviderAndSkipsCurrentVersion() async throws {
    let fixture = try #require(Bundle.module.url(
        forResource: "mock_runner",
        withExtension: "py",
        subdirectory: "Fixtures"
    ))
    let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent("provider-auto-sync-\(UUID().uuidString)", isDirectory: true)
    let installed = temporary.appendingPathComponent("installed", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer {
        ProviderFixtureURLProtocol.reset()
        try? FileManager.default.removeItem(at: temporary)
    }

    let manifestKey = Curve25519.Signing.PrivateKey()
    let distributionKey = Curve25519.Signing.PrivateKey()
    let v1Archive = try makeSignedProviderArchive(
        root: temporary,
        fixtureRunner: fixture,
        privateKey: manifestKey,
        version: "1.0.0",
        sourcePolicy: nil
    )
    let v2Archive = try makeSignedProviderArchive(
        root: temporary,
        fixtureRunner: fixture,
        privateKey: manifestKey,
        version: "2.0.0"
    )
    let v1URL = URL(string: "https://providers.example.test/auto-1.0.0.zip")!
    let v2URL = URL(string: "https://providers.example.test/auto-2.0.0.zip")!
    let indexURL = URL(string: "https://providers.example.test/auto-index.json")!
    let releases = [
        ProviderRelease(
            providerID: "fixture.distribution",
            version: "1.0.0",
            architectures: [ProviderManifestVerifier.currentArchitecture],
            archiveURL: v1URL,
            archiveSHA256: try ProviderManifestVerifier.sha256(of: v1Archive)
        ),
        ProviderRelease(
            providerID: "fixture.distribution",
            version: "2.0.0",
            architectures: [ProviderManifestVerifier.currentArchitecture],
            archiveURL: v2URL,
            archiveSHA256: try ProviderManifestVerifier.sha256(of: v2Archive)
        ),
    ]
    let indexData = try signedDistributionDocument(releases: releases, privateKey: distributionKey)
    ProviderFixtureURLProtocol.install([
        indexURL: .init(statusCode: 200, data: indexData),
        v1URL: .init(statusCode: 200, data: try Data(contentsOf: v1Archive)),
        v2URL: .init(statusCode: 200, data: try Data(contentsOf: v2Archive)),
    ])

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ProviderFixtureURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let distribution = ProviderDistributionClient(session: session)
    let manifestVerifier = try ProviderManifestVerifier(
        publicKeyData: manifestKey.publicKey.rawRepresentation,
        shellVersion: "1.0.0"
    )
    let distributionVerifier = try ProviderDistributionIndexVerifier(
        publicKeyData: distributionKey.publicKey.rawRepresentation,
        architecture: ProviderManifestVerifier.currentArchitecture
    )
    let manager = ProviderManager(store: ProviderPackageStore(
        rootURL: installed,
        verifier: manifestVerifier
    ))
    let bootstrap = ProviderRuntimeBootstrap(
        manager: manager,
        distribution: distribution,
        distributionVerifier: distributionVerifier,
        distributionIndexURL: indexURL
    )

    let first = try await bootstrap.synchronizeAvailableProviders()
    #expect(first.catalog.count == 2)
    let indexRequest = try #require(ProviderFixtureURLProtocol.recordedRequest(for: indexURL))
    #expect(indexRequest.cachePolicy == .reloadIgnoringLocalCacheData)
    #expect(indexRequest.value(forHTTPHeaderField: "Cache-Control") == "no-cache")
    #expect(indexRequest.value(forHTTPHeaderField: "Pragma") == "no-cache")
    #expect(first.installedOrUpdated == [ProviderVersionReference(
        providerID: "fixture.distribution",
        version: "2.0.0"
    )])
    #expect(first.failures.isEmpty)
    #expect(first.installed.first?.manifest.version == "2.0.0")

    ProviderFixtureURLProtocol.install([
        indexURL: .init(statusCode: 200, data: indexData),
    ])
    let second = try await bootstrap.synchronizeAvailableProviders()
    #expect(second.installedOrUpdated.isEmpty)
    #expect(second.failures.isEmpty)
    #expect(second.installed.first?.manifest.version == "2.0.0")
    await bootstrap.shutdown()

    let restrictedIndexData = try signedDistributionDocument(
        releases: [releases[0]],
        privateKey: distributionKey
    )
    ProviderFixtureURLProtocol.install([
        indexURL: .init(statusCode: 200, data: restrictedIndexData),
        v1URL: .init(statusCode: 200, data: try Data(contentsOf: v1Archive)),
    ])
    let restrictedManager = ProviderManager(store: ProviderPackageStore(
        rootURL: temporary.appendingPathComponent("restricted-installed", isDirectory: true),
        verifier: manifestVerifier
    ))
    let restricted = ProviderRuntimeBootstrap(
        manager: restrictedManager,
        distribution: distribution,
        distributionVerifier: distributionVerifier,
        distributionIndexURL: indexURL
    )
    let rejected = try await restricted.synchronizeAvailableProviders()
    #expect(rejected.installed.isEmpty)
    #expect(rejected.installedOrUpdated.isEmpty)
    #expect(rejected.failures.count == 1)
    #expect(rejected.failures[0].message == ProviderManagerError.sourcePolicyMismatch.localizedDescription)
    await restricted.shutdown()
}

@Test func distributionIndexUsesSwiftIntegerSecondDateEncoding() throws {
    let encoded = Data(#"{"generated_at":0,"protocol":2,"releases":[],"revoked":[]}"#.utf8)
    let index = try JSONDecoder().decode(ProviderDistributionIndex.self, from: encoded)
    #expect(index.generatedAt == Date(timeIntervalSinceReferenceDate: 0))
    #expect(try JSONEncoder.providerCanonical.encode(index) == encoded)
}

@Test func signedDistributionInstallsUpdatesRollsBackAndRestoresOffline() async throws {
    let fixture = try #require(Bundle.module.url(
        forResource: "mock_runner",
        withExtension: "py",
        subdirectory: "Fixtures"
    ))
    let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent("provider-distribution-e2e-\(UUID().uuidString)", isDirectory: true)
    let installed = temporary.appendingPathComponent("installed", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer {
        ProviderFixtureURLProtocol.reset()
        try? FileManager.default.removeItem(at: temporary)
    }

    let manifestKey = Curve25519.Signing.PrivateKey()
    let distributionKey = Curve25519.Signing.PrivateKey()
    let v1Archive = try makeSignedProviderArchive(
        root: temporary,
        fixtureRunner: fixture,
        privateKey: manifestKey,
        version: "1.0.0"
    )
    let v2Archive = try makeSignedProviderArchive(
        root: temporary,
        fixtureRunner: fixture,
        privateKey: manifestKey,
        version: "2.0.0"
    )
    let v3Archive = try makeSignedProviderArchive(
        root: temporary,
        fixtureRunner: fixture,
        privateKey: manifestKey,
        version: "3.0.0",
        runnerStarts: false
    )
    let v4Archive = try makeSignedProviderArchive(
        root: temporary,
        fixtureRunner: fixture,
        privateKey: manifestKey,
        version: "4.0.0",
        protocolVersion: 2
    )
    let archiveURLs = Dictionary(uniqueKeysWithValues: ["1.0.0", "2.0.0", "3.0.0", "4.0.0", "5.0.0"].map {
        ($0, URL(string: "https://providers.example.test/fixture-\($0).zip")!)
    })
    func release(version: String, archive: URL, hash: String? = nil) throws -> ProviderRelease {
        ProviderRelease(
            providerID: "fixture.distribution",
            version: version,
            architectures: [ProviderManifestVerifier.currentArchitecture],
            archiveURL: archiveURLs[version]!,
            archiveSHA256: try hash ?? ProviderManifestVerifier.sha256(of: archive)
        )
    }
    let releases = [
        try release(version: "1.0.0", archive: v1Archive),
        try release(version: "2.0.0", archive: v2Archive),
        try release(version: "3.0.0", archive: v3Archive),
        try release(version: "4.0.0", archive: v4Archive),
        try release(version: "5.0.0", archive: v2Archive, hash: String(repeating: "f", count: 64)),
    ]
    let indexURL = URL(string: "https://providers.example.test/index.json")!
    ProviderFixtureURLProtocol.install([
        indexURL: .init(
            statusCode: 200,
            data: try signedDistributionDocument(releases: releases, privateKey: distributionKey)
        ),
        archiveURLs["1.0.0"]!: .init(statusCode: 200, data: try Data(contentsOf: v1Archive)),
        archiveURLs["2.0.0"]!: .init(statusCode: 200, data: try Data(contentsOf: v2Archive)),
        archiveURLs["3.0.0"]!: .init(statusCode: 200, data: try Data(contentsOf: v3Archive)),
        archiveURLs["4.0.0"]!: .init(statusCode: 200, data: try Data(contentsOf: v4Archive)),
        archiveURLs["5.0.0"]!: .init(statusCode: 200, data: try Data(contentsOf: v2Archive)),
    ])

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ProviderFixtureURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let distribution = ProviderDistributionClient(session: session)
    let manifestVerifier = try ProviderManifestVerifier(
        publicKeyData: manifestKey.publicKey.rawRepresentation,
        shellVersion: "1.0.0"
    )
    let distributionVerifier = try ProviderDistributionIndexVerifier(
        publicKeyData: distributionKey.publicKey.rawRepresentation,
        architecture: ProviderManifestVerifier.currentArchitecture
    )
    let limitedDistribution = ProviderDistributionClient(
        session: session,
        maximumArchiveBytes: 1
    )
    let limitedRelease = try #require(
        await limitedDistribution.fetchIndex(from: indexURL, verifier: distributionVerifier)
            .first { $0.version == "1.0.0" }
    )
    await #expect(throws: ProviderDistributionError.responseTooLarge) {
        try await limitedDistribution.downloadAndExtract(limitedRelease)
    }
    let store = ProviderPackageStore(rootURL: installed, verifier: manifestVerifier)
    let manager = ProviderManager(store: store)
    let bootstrap = ProviderRuntimeBootstrap(
        manager: manager,
        distribution: distribution,
        distributionVerifier: distributionVerifier,
        distributionIndexURL: indexURL
    )
    let progress = ProviderProgressRecorder()

    try await bootstrap.install(providerID: "fixture.distribution", version: "1.0.0") {
        await progress.append($0)
    }
    #expect((await bootstrap.installedManifests()).first?.manifest.version == "1.0.0")
    let phases = await progress.phases()
    for phase in ProviderInstallPhase.allCasesForTesting {
        #expect(phases.contains(phase))
    }
    #expect((await progress.downloadFractions()).last == 1)

    try await bootstrap.install(providerID: "fixture.distribution", version: "2.0.0")
    #expect((await bootstrap.installedManifests()).first?.manifest.version == "2.0.0")

    do {
        try await bootstrap.install(providerID: "fixture.distribution", version: "3.0.0")
        Issue.record("Expected the failing Runner update to be rejected")
    } catch {
        #expect(error is ProviderProcessError)
    }
    #expect((await bootstrap.installedManifests()).first?.manifest.version == "2.0.0")

    await #expect(throws: ProviderVerificationError.incompatibleProtocol(2)) {
        try await bootstrap.install(providerID: "fixture.distribution", version: "4.0.0")
    }
    await #expect(throws: ProviderDistributionError.invalidArchiveHash) {
        try await bootstrap.install(providerID: "fixture.distribution", version: "5.0.0")
    }
    #expect((await bootstrap.installedManifests()).first?.manifest.version == "2.0.0")

    await manager.shutdownAll()
    ProviderFixtureURLProtocol.reset()
    let offlineManager = ProviderManager(store: store)
    let offlineManifests = await offlineManager.activeManifests()
    #expect(offlineManifests.first?.manifest.version == "2.0.0")
    let health = try await offlineManager.health(providerID: "fixture.distribution")
    #expect(health.ok)
    await offlineManager.shutdownAll()
}

private extension ProviderInstallPhase {
    static var allCasesForTesting: [ProviderInstallPhase] {
        [.fetchingCatalog, .downloading, .verifyingArchive, .extracting, .verifyingPackage, .launching, .completed]
    }
}

@Test func JavaProviderColdStartGetsALongerHandshakeBudget() {
    #expect(ProviderManager.handshakeTimeout(for: .java) == .seconds(15))
    #expect(ProviderManager.handshakeTimeout(for: .python) == .seconds(5))
    #expect(ProviderManager.handshakeTimeout(for: .javaScript) == .seconds(5))
    #expect(ProviderManager.handshakeTimeout(for: .quickJS) == .seconds(5))
}

@Test func managerInstallsSignedPackageThenHandshakesAndChecksHealth() async throws {
    let fixture = try #require(Bundle.module.url(
        forResource: "mock_runner",
        withExtension: "py",
        subdirectory: "Fixtures"
    ))
    let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent("provider-manager-\(UUID().uuidString)", isDirectory: true)
    let package = temporary.appendingPathComponent("package", isDirectory: true)
    let installed = temporary.appendingPathComponent("installed", isDirectory: true)
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let runner = package.appendingPathComponent("js-runner")
    let entrypoint = package.appendingPathComponent("provider.mjs")
    try FileManager.default.copyItem(at: fixture, to: runner)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runner.path)
    try Data("export default {};".utf8).write(to: entrypoint)
    let licenseAsset = try makeProviderLicense(in: package)

    let manifest = ProviderManifest(
        providerID: "fixture.manager",
        version: "1.0.0",
        shellMinimumVersion: "1.0.0",
        macOSMinimumVersion: "1.0",
        architectures: [ProviderManifestVerifier.currentArchitecture],
        runtime: .javaScript,
        entrypoint: "provider.mjs",
        runner: "js-runner",
        capabilities: [.home, .search, .detail, .player, .proxy],
        assets: [
            ProviderAsset(path: "js-runner", sha256: try ProviderManifestVerifier.sha256(of: runner), executable: true),
            ProviderAsset(path: "provider.mjs", sha256: try ProviderManifestVerifier.sha256(of: entrypoint)),
            licenseAsset
        ],
        hostCapabilities: [.console],
        sourceBindings: [ProviderSourceBinding(
            originalKeys: ["fixture-manager-site"],
            originalAPIs: ["https://signed.example.test/provider.js"]
        )],
        license: "MIT"
    )
    let privateKey = Curve25519.Signing.PrivateKey()
    let signature = try privateKey.signature(for: JSONEncoder.providerCanonical.encode(manifest))
    let document = SignedProviderManifest(manifest: manifest, signature: signature.base64EncodedString())
    let manifestVerifier = try ProviderManifestVerifier(
        publicKeyData: privateKey.publicKey.rawRepresentation,
        shellVersion: "1.0.0"
    )
    let store = ProviderPackageStore(rootURL: installed, verifier: manifestVerifier)
    let manager = ProviderManager(store: store)

    _ = try await manager.install(packageDirectory: package, document: document)
    let activeManifests = await manager.activeManifests()
    #expect(activeManifests.count == 1)
    #expect(activeManifests.first?.manifest.sourceBindings == manifest.sourceBindings)

    await SpiderReplacementRegistry.shared.clear()
    let bootstrap = ProviderRuntimeBootstrap(manager: manager, allowedSourcePolicies: nil)
    await bootstrap.registerInstalledProviders()
    let signedSite = Site(
        key: "fixture-manager-site",
        name: "Signed fixture",
        type: 3,
        api: "https://signed.example.test/provider.js"
    )
    let home = try await SiteApi().homeContent(site: signedSite)
    #expect(home.list.isEmpty)
    #expect(home.types.isEmpty)

    let proxyServer = ProxyServer()
    RemoteProviderProxyBridge.install(on: proxyServer)
    try proxyServer.start()
    defer { proxyServer.stop() }
    var proxyComponents = URLComponents(string: proxyServer.getAddress("/proxy"))!
    proxyComponents.queryItems = [
        URLQueryItem(name: "do", value: "js"),
        URLQueryItem(name: "from", value: "catvod"),
        URLQueryItem(name: "siteKey", value: signedSite.key),
    ]
    var proxyRequest = URLRequest(url: try #require(proxyComponents.url))
    proxyRequest.setValue("bytes=4-7", forHTTPHeaderField: "Range")
    proxyRequest.setValue("downstream", forHTTPHeaderField: "X-Proxy-Test")
    let (proxyData, proxyURLResponse) = try await URLSession.shared.data(for: proxyRequest)
    let proxyHTTPResponse = try #require(proxyURLResponse as? HTTPURLResponse)
    #expect(proxyHTTPResponse.statusCode == 202)
    #expect(proxyHTTPResponse.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
    #expect(proxyHTTPResponse.value(forHTTPHeaderField: "Content-Length") == String(proxyData.count))
    #expect(proxyHTTPResponse.value(forHTTPHeaderField: "X-Provider-Proxy") == "fixture")
    #expect(proxyHTTPResponse.value(forHTTPHeaderField: "X-Proxy-Range") == "bytes=4-7")
    #expect(String(decoding: proxyData, as: UTF8.self) == "provider-proxy|bytes=4-7|downstream")

    var updatedManifest = manifest
    updatedManifest.sourceBindings = [ProviderSourceBinding(originalKeys: ["new-provider-site"])]
    await SpiderReplacementRegistry.shared.registerRemote(manifest: updatedManifest, manager: manager)
    #expect(await SpiderReplacementRegistry.shared.nativeProvider(for: signedSite) == nil)
    #expect(await SpiderReplacementRegistry.shared.nativeProvider(for: Site(
        key: "new-provider-site",
        name: "Updated signed fixture",
        type: 3,
        api: "https://unrelated.example.test/provider.js"
    )) != nil)
    await SpiderReplacementRegistry.shared.clear()
    await bootstrap.shutdown()

    let health = try await manager.health(providerID: manifest.providerID)
    #expect(health.ok)
    #expect(health.result == .object(["status": .string("ok")]))

    let timeoutID = "timeout-request"
    let timeoutClock = ContinuousClock()
    let timeoutStarted = timeoutClock.now
    do {
        _ = try await manager.request(
            ProviderRequest(
                requestID: timeoutID,
                providerID: manifest.providerID,
                operation: .search,
                arguments: ["delay": .number(2.0)]
            ),
            timeout: .milliseconds(20)
        )
        Issue.record("Expected Provider request to time out")
    } catch {
        #expect(error as? ProviderProcessError == .timedOut(timeoutID))
    }
    #expect(timeoutStarted.duration(to: timeoutClock.now) < .milliseconds(500))
    let restarted = try await manager.health(providerID: manifest.providerID)
    #expect(restarted.ok)

    let cancelID = "cancel-request"
    let canceled = Task {
        try await manager.request(
            ProviderRequest(
                requestID: cancelID,
                providerID: manifest.providerID,
                operation: .search,
                arguments: ["delay": .number(0.1)]
            ),
            timeout: .seconds(2)
        )
    }
    try await Task.sleep(for: .milliseconds(20))
    canceled.cancel()
    do {
        _ = try await canceled.value
        Issue.record("Expected Provider request to be canceled")
    } catch {
        #expect(error as? ProviderProcessError == .canceled(cancelID))
    }
    await manager.shutdownAll()
}
