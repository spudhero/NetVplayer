import Foundation
import Models
import Networking
import PlayerEngine
import Testing
@testable import DriveEngine
@testable import NetVplayerApp

private final class RecoveryFixture: @unchecked Sendable {
    struct Reply: Sendable {
        var status = 200
        var body = #"{"code":0,"data":{"list":[]}}"#
        var headers: [String: String] = [:]
        var error: URLError.Code?
        var delay: Double = 0
    }
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    let reply: @Sendable (URLRequest, Int) -> Reply
    init(_ reply: @escaping @Sendable (URLRequest, Int) -> Reply) { self.reply = reply }
    func next(_ request: URLRequest) -> Reply {
        let count = lock.withLock { requests.append(request); return requests.count }
        return reply(request, count)
    }
    var count: Int { lock.withLock { requests.count } }
    var paths: [String] { lock.withLock { requests.compactMap { $0.url?.path } } }
}

private final class RecoveryProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var fixture: RecoveryFixture?
    private let lock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let fixture = Self.fixture else { fatalError("Missing isolated protocol fixture") }
        let reply = fixture.next(request)
        let deliver: @Sendable () -> Void = { [self] in
            lock.withLock {
                guard !stopped else { return }
                if let error = reply.error { client?.urlProtocol(self, didFailWithError: URLError(error)); return }
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: reply.status,
                    httpVersion: nil, headerFields: reply.headers)!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
                client?.urlProtocolDidFinishLoading(self)
            }
        }
        if reply.delay > 0 { DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay, execute: deliver) }
        else { deliver() }
    }
    override func stopLoading() { lock.withLock { stopped = true } }
}

private final class RecoveryRevision: @unchecked Sendable {
    let lock = NSLock()
    private var active = true
    func invalidate() { lock.withLock { active = false } }
    var isCurrent: Bool { lock.withLock { active } }
}

private final class RecoveryCurlFixture {
    let process = Process()
    let port: Int
    init() throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", #"""
import http.server, json, time
counts = {}
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        counts[self.path] = counts.get(self.path, 0) + 1
        status = 200
        retry = None
        if self.path == '/retry' and counts[self.path] == 1: status, retry = 429, '1'
        if self.path == '/overlimit': status, retry = 429, '120'
        if self.path in ['/deadline', '/cancel']: time.sleep(5)
        payload = (json.dumps(counts) if self.path == '/counts' else str(counts[self.path])).encode()
        try:
            self.send_response(status)
            if retry: self.send_header('Retry-After', retry)
            self.send_header('Content-Length', str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError): pass
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
"""#]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        var line = Data()
        while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
            if byte == Data([10]) { break }
            line.append(byte)
        }
        guard let port = Int(String(decoding: line, as: UTF8.self)) else {
            if process.isRunning { process.terminate() }
            throw URLError(.cannotConnectToHost)
        }
        self.port = port
    }
    deinit {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }
}

@Suite(.serialized)
struct DriveRequestRecoveryTests {
    private func http(_ fixture: RecoveryFixture) -> HTTPClient {
        RecoveryProtocol.fixture = fixture
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecoveryProtocol.self]
        config.httpCookieStorage = nil
        return HTTPClient(session: URLSession(configuration: config)).withExplicitProxy(nil)
    }
    private func failure(_ action: () async throws -> Void) async throws -> DriveServiceFailure {
        do { try await action(); Issue.record("Expected classified failure") }
        catch let error as DriveServiceFailure { return error }
        throw URLError(.unknown)
    }

    @Test func permissionNeverInvalidatesMappingFromStatusOrMessage() async throws {
        let fixture = RecoveryFixture { _, _ in .init(status: 403, body: #"{"code":32003,"message":"file not found 无权限 token=private"}"#) }
        let client = DriveHTTPClient(http(fixture), provider: .quark)
        let error = try await failure {
            _ = try await client.post(url: "https://drive-pc.quark.cn/1/clouddrive/file/v2/play",
                headers: ["Cookie": "__uid=account"], body: Data("{}".utf8))
        }
        #expect(error.reason == .permissionDenied)
        #expect(!DriveEngineError.invalidatesSavedRecord(error))
        #expect(fixture.count == 1)
        #expect(!DriveEngineError.invalidatesSavedRecord(DriveEngineError.api(provider: .uc, statusCode: 200, code: 999, message: "文件已删除 无权限")))
        #expect(!DriveEngineError.invalidatesSavedRecord(DriveEngineError.api(provider: .quark, statusCode: 404, code: nil, message: "missing endpoint")))
    }

    @Test func businessCodeDistinguishesMissingFileExpiredURLAndQuota() throws {
        let samples: [(String, Int, DriveRequestOperation, AppFailureReason)] = [
            (#"{"code":"NotFound.File"}"#, 404, .fileMetadata, .fileMissing),
            (#"{"code":"ForbiddenNoPermission","message":"not found"}"#, 403, .fileMetadata, .permissionDenied),
            (#"{"message":"file not found"}"#, 410, .playback, .signedURLExpired),
            (#"{"Code":"QuotaExhausted","Message":"private"}"#, 200, .mutation, .quotaExceeded),
            (#"{"code":"Throttling"}"#, 400, .listing, .rateLimited)
        ]
        for (body, status, operation, reason) in samples {
            let result = try #require(DriveFailureClassifier.response(.init(data: Data(body.utf8), statusCode: status),
                provider: .ali, operation: operation, path: "/v2/file/get"))
            #expect(result.reason == reason)
            #expect(DriveEngineError.invalidatesSavedRecord(result) == (reason == .fileMissing))
        }
        let shareError = DriveFailureClassifier.response(.init(data: Data(#"{"errno":-9}"#.utf8), statusCode: 200),
            provider: .baidu, operation: .authentication, path: "/share/verify")
        #expect(shareError == nil)
    }

    @Test func baiduVerificationPausesAccountWithoutRetryingOrInvalidatingFiles() async throws {
        let fixture = RecoveryFixture { _, _ in
            .init(body: #"{"errno":9019,"errmsg":"need verify token=private"}"#)
        }
        let client = DriveHTTPClient(http(fixture), provider: .baidu)
        let error = try await failure {
            _ = try await client.get(url: "https://pan.baidu.com/share/list",
                                     headers: ["Cookie": "BDUSS=fixture; BDCLND=share"])
        }
        #expect(error.reason == .credentialExpired)
        #expect(error.pausesAccountOperation)
        #expect(error.serviceCode == "9019")
        #expect(fixture.count == 1)
        #expect(!DriveEngineError.invalidatesSavedRecord(error))
        let message = UserFacingErrorPresenter.message(for: error, context: .playback)
        #expect(message.contains("官方") && message.contains("重新扫码"))
        #expect(!message.contains("提取码") && !message.contains("private"))
        let unrelated = DriveFailureClassifier.response(.init(data: Data(#"{"errno":9019}"#.utf8), statusCode: 200),
            provider: .quark, operation: .listing, path: "/share/list")
        #expect(unrelated == nil)
    }

    @Test func retryAfterIsWaitedAndSuccessUsesSameRealTransport() async throws {
        let fixture = RecoveryFixture { _, count in count == 1 ? .init(status: 429, headers: ["Retry-After": "1"]) : .init() }
        let client = DriveHTTPClient(http(fixture), provider: .quark)
        let start = ContinuousClock.now
        try await DriveRequestRecovery.withBudget {
            _ = try await client.get(url: "https://drive-pc.quark.cn/1/clouddrive/file/sort")
        }
        #expect(start.duration(to: .now) >= .milliseconds(950))
        #expect(fixture.count == 2)
    }

    @Test func retryAfterBeyondBudgetStopsWithoutSendingAgain() async throws {
        let fixture = RecoveryFixture { _, _ in .init(status: 429, headers: ["rEtRy-AfTeR": "120"]) }
        let client = DriveHTTPClient(http(fixture), provider: .quark)
        let start = ContinuousClock.now
        let error = try await failure {
            try await DriveRequestRecovery.withBudget {
                _ = try await client.get(url: "https://drive-pc.quark.cn/1/clouddrive/file/sort", timeout: 1)
            }
        }
        #expect(error.reason == .rateLimited && error.retryAfter == 120)
        #expect(fixture.count == 1)
        #expect(start.duration(to: .now) < .seconds(1))
    }

    @Test func retryAfterHTTPDateAndMalformedValues() throws {
        let date = Date(timeIntervalSince1970: 1_445_412_480)
        #expect(DriveFailureClassifier.retryAfter(["Retry-After": "Wed, 21 Oct 2015 07:28:03 GMT"], now: date) == 3)
        #expect(DriveFailureClassifier.retryAfter(["Retry-After": "nan"]) == nil)
        #expect(DriveFailureClassifier.retryAfter(["Retry-After": "-1"]) == nil)
    }

    @Test func baiduCurlActuallyHonorsRetryAfterDeadlineAndCancellation() async throws {
        let fixture = try RecoveryCurlFixture()
        let url = "http://127.0.0.1:\(fixture.port)"
        let start = ContinuousClock.now
        let response = try await BaiduShareListCurlTransport.get(url: url + "/retry", userAgent: "fixture", cookie: "BDCLND=fixture", timeout: 3)
        #expect(response.text == "2")
        #expect(start.duration(to: .now) >= .milliseconds(950))
        let tooLong = try await failure {
            _ = try await BaiduShareListCurlTransport.get(url: url + "/overlimit", userAgent: "fixture", cookie: "", timeout: 1)
        }
        #expect(tooLong.reason == .rateLimited && tooLong.retryAfter == 120)

        let deadlineStart = ContinuousClock.now
        _ = try await failure {
            _ = try await BaiduShareListCurlTransport.get(url: url + "/deadline", userAgent: "fixture", cookie: "", timeout: 0.06)
        }
        #expect(deadlineStart.duration(to: .now) < .milliseconds(400))

        let cancelStart = ContinuousClock.now
        let pending = Task { try await BaiduShareListCurlTransport.get(url: url + "/cancel", userAgent: "fixture", cookie: "", timeout: 5) }
        try await Task.sleep(for: .milliseconds(100))
        pending.cancel()
        do { _ = try await pending.value; Issue.record("Cancelled curl request returned success") }
        catch { #expect(error is CancellationError) }
        #expect(cancelStart.duration(to: .now) < .seconds(2))
        let counts = try await BaiduShareListCurlTransport.get(url: url + "/counts", userAgent: "fixture", cookie: "", timeout: 2)
        let values = try #require(JSONSerialization.jsonObject(with: counts.data) as? [String: Int])
        #expect(values["/retry"] == 2)
        #expect(values["/overlimit"] == 1)
        #expect(values["/deadline"] == 1)
        #expect(values["/cancel"] == 1)
    }

    @Test func networkRetriesAreSharedAcrossRequestsAndNeverLayered() async throws {
        let fixture = RecoveryFixture { _, _ in .init(error: .networkConnectionLost) }
        let client = DriveHTTPClient(http(fixture), provider: .uc)
        let error = try await failure {
            try await DriveRequestRecovery.withBudget {
                _ = try await client.get(url: "https://pc-api.uc.cn/1/clouddrive/file/sort", headers: ["Cookie": "__uid=A"])
            }
        }
        #expect(error.reason == .temporaryNetwork)
        #expect(fixture.count == 3)
        await MainActor.run { #expect(AppState.transientPreparationRetryDelayNanoseconds(for: error, attempt: 0) == nil) }
    }

    @Test func readDeadlineIncludesTransportAndConfirmationBudget() async throws {
        let fixture = RecoveryFixture { _, _ in .init(delay: 0.5) }
        let client = DriveHTTPClient(http(fixture), provider: .quark)
        let start = ContinuousClock.now
        _ = try await failure {
            try await DriveTransferContext.$confirmationDeadline.withValue(.now.advanced(by: .milliseconds(60))) {
                try await DriveRequestRecovery.withBudget {
                    _ = try await client.get(url: "https://drive-pc.quark.cn/1/clouddrive/file/sort", timeout: 10)
                }
            }
        }
        #expect(fixture.count == 1)
        #expect(start.duration(to: .now) < .milliseconds(400))
    }

    @Test func cancellationAndTLSFailuresDoNotRetry() async throws {
        for code in [URLError.Code.cancelled, .serverCertificateUntrusted] {
            let fixture = RecoveryFixture { _, _ in .init(error: code) }
            let client = DriveHTTPClient(http(fixture), provider: .uc)
            do { _ = try await client.get(url: "https://pc-api.uc.cn/1/clouddrive/file/sort"); Issue.record("Expected failure") }
            catch { #expect(error is CancellationError || (error as? URLError)?.code == .serverCertificateUntrusted) }
            #expect(fixture.count == 1)
        }
    }

    @Test func lostWriteRemainsUnknownAndRetryOnlyConfirms() async throws {
        let fixture = RecoveryFixture { _, _ in .init(error: .networkConnectionLost) }
        let client = DriveHTTPClient(http(fixture), provider: .uc)
        let attempt = DriveTransferAttempt()
        for _ in 0..<2 {
            _ = try await attempt.submit(previousIDs: []) {
                _ = try await client.post(url: "https://pc-api.uc.cn/1/clouddrive/share/sharepage/save", body: Data())
                return .init(fileID: "impossible")
            }
        }
        #expect(await attempt.phase == .outcomeUnknown)
        #expect(fixture.count == 1)
    }

    @Test func quotaRejectionStopsWriteAndSameAccountBackgroundWork() async throws {
        let fixture = RecoveryFixture { request, _ in
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer B" { return .init() }
            return .init(body: #"{"responses":[{"status":400,"body":{"code":"QuotaExhausted"}}]}"#)
        }
        let client = DriveHTTPClient(http(fixture), provider: .ali)
        try await DriveRequestRecovery.$accountGate.withValue(DriveAccountRequestGate()) {
            for _ in 0..<2 {
                let error = try await failure {
                    try await DriveRequestRecovery.withBudget(background: true) {
                        _ = try await client.post(url: "https://api.aliyundrive.com/adrive/v4/batch", headers: ["Authorization": "Bearer A"])
                    }
                }
                #expect(error.reason == .quotaExceeded && error.definiteRejection)
            }
            #expect(fixture.count == 1)
            try await DriveRequestRecovery.withBudget(background: true) {
                _ = try await client.post(url: "https://api.aliyundrive.com/adrive/v4/batch", headers: ["Authorization": "Bearer B"])
            }
            #expect(fixture.count == 2)
        }
    }

    @Test func accountPauseIsScopedAndExplicitRetryCanResume() async throws {
        let fixture = RecoveryFixture { _, count in count == 1 ? .init(status: 403) : .init() }
        let http = http(fixture)
        let client = DriveHTTPClient(http, provider: .quark)
        try await DriveRequestRecovery.$accountGate.withValue(DriveAccountRequestGate()) {
            for _ in 0..<2 {
                _ = try await failure {
                    try await DriveRequestRecovery.withBudget(background: true) {
                        _ = try await client.get(url: "https://drive-pc.quark.cn/1/clouddrive/file/sort", headers: ["Cookie": "__uid=A"])
                    }
                }
            }
            #expect(fixture.count == 1)
            try await DriveRequestRecovery.withBudget(background: true) {
                _ = try await client.get(url: "https://drive-pc.quark.cn/1/clouddrive/file/sort", headers: ["Cookie": "__uid=B"])
                _ = try await DriveHTTPClient(http, provider: .uc).get(url: "https://pc-api.uc.cn/1/clouddrive/file/sort", headers: ["Cookie": "__uid=A"])
            }
            #expect(fixture.count == 3)
            try await DriveRequestRecovery.withBudget {
                _ = try await client.get(url: "https://drive-pc.quark.cn/1/clouddrive/file/sort", headers: ["Cookie": "__uid=A"])
            }
            try await DriveRequestRecovery.withBudget(background: true) {
                _ = try await client.get(url: "https://drive-pc.quark.cn/1/clouddrive/file/sort", headers: ["Cookie": "__uid=A"])
            }
            #expect(fixture.count == 5)
        }
    }

    @Test func accountSwitchRejectsLateResponseAndDoesNotPauseNewScope() async throws {
        let revision = RecoveryRevision()
        let fixture = RecoveryFixture { _, count in
            if count == 1 { revision.invalidate(); return .init(status: 403) }
            return .init()
        }
        let client = DriveHTTPClient(http(fixture), provider: .quark)
        let context = DriveTransferContext(revision: "old") { revision.isCurrent }
        await #expect(throws: CancellationError.self) {
            try await DriveTransferContext.$current.withValue(context) {
                _ = try await client.get(url: "https://drive-pc.quark.cn/1/clouddrive/file/sort", headers: ["Cookie": "__uid=A"])
            }
        }
        try await DriveTransferContext.$current.withValue(.init(revision: "new")) {
            try await DriveRequestRecovery.withBudget(background: true) {
                _ = try await client.get(url: "https://drive-pc.quark.cn/1/clouddrive/file/sort", headers: ["Cookie": "__uid=A"])
            }
        }
        #expect(fixture.count == 2)
    }

    @Test func cookieServices401DoNotRefreshOrRetry403() async throws {
        for provider in [DriveProvider.quark, .uc, .baidu, .p115] {
            for status in [401, 403] {
                let fixture = RecoveryFixture { _, _ in .init(status: status) }
                let client = DriveHTTPClient(http(fixture), provider: provider)
                let error = try await failure { _ = try await client.get(url: "https://fixture.invalid/files", headers: ["Cookie": "UID=fixture"]) }
                #expect(error.reason == (status == 401 ? .credentialExpired : .permissionDenied))
                #expect(fixture.count == 1)
            }
        }
    }

    @Test func aliRefreshIsSharedByAuthenticationAndPlaybackAndExhaustsOnce() async throws {
        let fixture = RecoveryFixture { request, _ in
            if request.url?.path == "/v2/account/token" { return .init(body: #"{"access_token":"fresh","refresh_token":"rotated"}"#) }
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer stale" { return .init(status: 401) }
            if request.url?.path == "/users/v1/users/device/create_session" { return .init(body: "{}") }
            return .init(status: 401)
        }
        let extractor = AliShareExtractor(httpClient: http(fixture), credentialProvider: {
            .init(provider: .ali, kind: .refreshToken, secret: "stale", refreshToken: "refresh", accessToken: "stale",
                metadata: ["user_id": "fixture", "default_drive_id": "drive", "ali_auth_domain": "auth.alipan.com"])
        }, credentialUpdateHandler: { _ in Issue.record("Rejected credential was published") })
        let reference = DriveFileReference(provider: .ali, shareURL: "ali://share/fixture", pwdID: "fixture", fid: "source", fidToken: "",
            fileName: "sample.mp4", personalDriveID: "drive", personalFileID: "personal", size: 100)
        let error = try await failure { _ = try await extractor.fetchResult(url: reference.encodedURL) }
        #expect(error.reason == .credentialExpired)
        #expect(fixture.paths.filter { $0 == "/v2/account/token" }.count == 1)
        #expect(fixture.count <= 5)
    }

    @Test func aliProductCopyQuotaDoesNotFallThroughToSharePlayback() async throws {
        let fixture = RecoveryFixture { request, _ in
            switch request.url?.path {
            case "/users/v1/users/device/create_session": return .init(body: "{}")
            case "/adrive/v3/file/list": return .init(body: #"{"items":[{"file_id":"folder","name":"NetVplayer","type":"folder","drive_id":"drive","parent_file_id":"root"}]}"#)
            case "/adrive/v4/batch": return .init(body: #"{"responses":[{"status":400,"body":{"code":"QuotaExhausted"}}]}"#)
            default: Issue.record("Unexpected request after quota rejection"); return .init(status: 500)
            }
        }
        let client = AliDriveClient(httpClient: http(fixture))
        let file = AliShareFile(fileID: "source", name: "sample.mp4", parentFileID: "root", driveID: "share-drive",
            type: "file", category: "video", size: 100, contentType: "video/mp4", downloadURL: "", playURL: "", isDirectory: false)
        let error = try await failure {
            try await DriveTransferCoordinator.$current.withValue(DriveTransferCoordinator()) {
                try await DriveRequestRecovery.withBudget {
                    _ = try await client.link(file: file, share: .init(originalURL: "https://www.alipan.com/s/fixture", shareID: UUID().uuidString),
                        shareToken: "fixture", credential: .init(provider: .ali, kind: .accessToken, secret: "fixture", accessToken: "fixture",
                            metadata: ["default_drive_id": "drive", "user_id": "fixture"]))
                }
            }
        }
        #expect(error.reason == .quotaExceeded && error.definiteRejection)
        #expect(fixture.paths.filter { $0 == "/adrive/v4/batch" }.count == 1)
        #expect(!fixture.paths.contains { $0.contains("get_download_url") })
    }

    @Test func pikpakRefreshOnlyCredentialIsReusedThroughSelectionAndPlayback() async throws {
        let fixture = RecoveryFixture { request, _ in
            if request.url?.path == "/v1/auth/token" { return .init(body: #"{"access_token":"fresh","refresh_token":"rotated"}"#) }
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh")
            return .init(body: #"{"id":"file","name":"sample.mp4","kind":"drive#file","size":"100","web_content_link":"https://media.example.test/sample.mp4"}"#)
        }
        let extractor = PikPakShareExtractor(httpClient: http(fixture), credentialProvider: {
            .init(provider: .pikpak, kind: .refreshToken, secret: "", refreshToken: "refresh")
        }, credentialUpdateHandler: { #expect($0.accessToken == "fresh" && $0.refreshToken == "rotated") })
        let result = try await extractor.fetchResult(url: "pikpak://file/file")
        #expect(result.url == "https://media.example.test/sample.mp4")
        #expect(fixture.paths.filter { $0 == "/v1/auth/token" }.count == 1)
        #expect(fixture.count == 2)
    }

    @Test func tvCredentialRefreshOnlyRunsForAuthenticationAndIsBounded() async throws {
        for status in [401, 403, 429] {
            let fixture = RecoveryFixture { request, _ in
                if request.url?.path.hasSuffix("/token") == true {
                    return .init(body: #"{"code":200,"data":{"access_token":"fresh","refresh_token":"rotated"}}"#)
                }
                return .init(status: status, headers: ["Retry-After": "120"])
            }
            let driver = QuarkTVDriver(provider: .uc, httpClient: http(fixture))
            let error = try await failure {
                _ = try await driver.validate(.token(provider: .uc, refreshToken: "refresh", accessToken: "old", deviceID: "device"), reference: nil)
            }
            #expect(error.reason == (status == 401 ? .credentialExpired : status == 403 ? .permissionDenied : .rateLimited))
            #expect(fixture.paths.filter { $0.hasSuffix("/token") }.count == (status == 401 ? 1 : 0))
            #expect(fixture.count == (status == 401 ? 3 : 1))
        }
    }

    @Test @MainActor func allReasonsHaveSpecificSafeNextStepsAndNoOuterRetry() {
        let reasons: [AppFailureReason] = [.credentialExpired, .permissionDenied, .quotaExceeded, .rateLimited,
            .temporaryNetwork, .fileMissing, .signedURLExpired, .outcomeUnknown]
        for reason in reasons {
            let error = DriveServiceFailure(provider: .ali, reason: reason, operation: .playback)
            let result = UserFacingErrorPresenter.presentation(for: error, context: .playback)
            #expect(result.message == reason.presentationHint.title)
            #expect(result.recoverySuggestion == reason.presentationHint.suggestedAction)
            #expect(!result.recoverySuggestion.isEmpty)
            #expect(!result.combinedMessage.contains("private"))
            #expect(AppState.transientPreparationRetryDelayNanoseconds(for: error, attempt: 0) == nil)
        }
    }
}
