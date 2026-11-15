import Foundation
import Models
import Networking
import Testing
import Storage
@testable import DriveEngine

/// All requests, including requests to unexpected hosts, terminate in this
/// fixture. No real account, public share or NAS is contacted.
private final class ConfirmationProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var fixture: ConfirmationFixture?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let body = try Self.fixture!.reply(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: Self.fixture!.status(request), httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}

private final class RecoveryCurrentState: @unchecked Sendable {
    private let lock = NSLock()
    private var current = true
    var isCurrent: Bool { lock.withLock { current } }
    func retire() { lock.withLock { current = false } }
}

private final class ConfirmationFixture: @unchecked Sendable {
    let provider: DriveProvider
    let knownID: Bool
    var mappingScenario: String?
    let lock = NSLock()
    var onSubmission: (@Sendable () throws -> Void)?
    var onRead: (@Sendable () throws -> Void)?
    private var requests = 0
    var requestCount: Int { lock.withLock { requests } }
    private var paths = [String]()
    var requestedPaths: [String] { lock.withLock { paths } }
    private var visible = false
    private var submissions = 0
    private var reads = 0
    private var mutations = 0
    private var parents = Set<String>()
    private var ambiguous = false
    init(_ provider: DriveProvider, knownID: Bool) { self.provider = provider; self.knownID = knownID }
    func reveal(ambiguous: Bool = false) { lock.withLock { visible = true; self.ambiguous = ambiguous } }
    var writes: Int { lock.withLock { submissions } }
    var directoryReads: Int { lock.withLock { reads } }
    var remoteMutations: Int { lock.withLock { mutations } }
    var visitedParents: Set<String> { lock.withLock { parents } }

    func status(_ request: URLRequest) -> Int {
        if mappingScenario == "permission" { return 403 }
        if mappingScenario == "expired", request.url!.path.contains("get_download_url")
            || request.url!.path.contains("get_video_preview_play_info") { return 410 }
        return 200
    }

    func reply(_ request: URLRequest) throws -> String {
        try lock.withLock {
            requests += 1
            let url = request.url!, path = url.path
            paths.append(path)
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let bytes: Data
            if let body = request.httpBody { bytes = body }
            else if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
                bytes = data
            } else { bytes = Data() }
            let body = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] ?? [:]
            if ["/1/clouddrive/file", "/1/clouddrive/file/rename", "/v2/file/create", "/v2/file/update",
                "/files/add", "/rb/delete", "/api/create", "/api/filemanager"].contains(path)
                || path.hasSuffix("/sharepage/save") || path == "/adrive/v4/batch"
                || path == "/share/receive" || path == "/share/transfer" { mutations += 1 }
            if mappingScenario == "offline" { throw URLError(.notConnectedToInternet) }
            let parent = query.first { $0.name == "pdir_fid" || $0.name == "cid" || $0.name == "dir" }?.value
                ?? body["parent_file_id"] as? String
            if let parent { parents.insert(parent) }
            let targetRead = path == "/v2/file/get" || ((path.hasSuffix("/file/sort") || path == "/files"
                || path == "/adrive/v3/file/list") && parent != "0" && parent != "root")
                || (path == "/api/list" && parent == "/NetVplayer")
            if mappingScenario == "malformed", targetRead { return "{}" }
            if mappingScenario == "partial", targetRead {
                switch provider {
                case .p115: return #"{"state":true,"count":2,"data":{"list":[]}}"#
                case .baidu: return #"{"errno":0,"total":2,"list":[]}"#
                default: return #"{"code":0,"metadata":{"_total":2},"data":{"list":[]}}"#
                }
            }
            if mappingScenario == "missingFolder", parent == "0" || parent == "root" {
                switch provider {
                case .ali: return #"{"items":[]}"#
                case .p115: return #"{"state":true,"data":{"list":[]}}"#
                default: return #"{"code":0,"data":{"list":[]}}"#
                }
            }
            let mappingID = mappingScenario == "deleted" ? "same-name-other-content" : "destination"
            let mappingSize = mappingScenario == "size" ? 99 : 100
            let mappingParent = mappingScenario == "moved" ? "outside" : "folder"
            let isWrite = path.hasSuffix("/sharepage/save") || path == "/adrive/v4/batch"
                || path == "/share/receive" || path == "/share/transfer"
            if isWrite {
                try onSubmission?()
                submissions += 1
                if !knownID { throw URLError(.networkConnectionLost) }
                switch provider {
                case .ali: return #"{"responses":[{"status":200,"body":{"file_id":"destination"}}]}"#
                case .baidu: return #"{"errno":0,"extra":{"list":[{"from_fs_id":"source","to_fs_id":"destination","to":"/NetVplayer/sample.mp4"}]}}"#
                case .p115: return #"{"state":true,"data":{"file_id":"destination"}}"#
                default: return #"{"code":0,"data":{"saved_fid":"destination"}}"#
                }
            }
            if targetRead { try onRead?() }
            if path.hasSuffix("/file/sort") {
                reads += 1
                let parent = query.first { $0.name == "pdir_fid" }?.value
                if parent == "0" { return #"{"code":0,"data":{"list":[{"fid":"\#(mappingScenario == "policy" ? "new-folder" : "folder")","file_name":"NetVplayer","dir":true,"file":false,"file_type":0}]}}"# }
                let ids = visible ? (ambiguous ? ["destination", "other"] : [mappingID]) : ["old-namesake"]
                let files = ids.map { #"{"fid":"\#($0)","file_name":"sample.mp4","pdir_fid":"\#(mappingParent)","size":\#(mappingSize),"dir":false,"file":true,"file_type":1,"category":1}"# }
                return #"{"code":0,"data":{"list":[\#(files.joined(separator: ","))]}}"#
            }
            if path == "/adrive/v3/file/list" {
                reads += 1
                if body["parent_file_id"] as? String == "root" { return #"{"items":[{"file_id":"\#(mappingScenario == "policy" ? "new-folder" : "folder")","name":"NetVplayer","type":"folder"}]}"# }
                let ids = visible ? (ambiguous ? ["destination", "other"] : [mappingID]) : ["old-namesake"]
                return #"{"items":[\#(ids.map { #"{"file_id":"\#($0)","name":"sample.mp4","parent_file_id":"\#(mappingParent)","drive_id":"drive","type":"file","size":\#(mappingSize)}"# }.joined(separator: ","))]}"#
            }
            if path == "/files" {
                reads += 1
                if query.first(where: { $0.name == "cid" })?.value == "0" { return #"{"state":true,"data":{"list":[{"cid":"\#(mappingScenario == "policy" ? "new-folder" : "folder")","n":"NetVplayer","is_dir":true}]}}"# }
                let ids = visible ? (ambiguous ? ["destination", "other"] : [mappingID]) : ["old-namesake"]
                return #"{"state":true,"data":{"list":[\#(ids.map { #"{"fid":"\#($0)","n":"sample.mp4","cid":"\#(mappingParent)","pc":"pick","ico":"mp4","s":\#(mappingSize)}"# }.joined(separator: ","))]}}"#
            }
            if path == "/api/list" {
                reads += 1
                let ids = visible ? (ambiguous ? ["destination", "other"] : [mappingID]) : ["old-namesake"]
                return #"{"errno":0,"list":[\#(ids.map { #"{"fs_id":"\#($0)","server_filename":"sample.mp4","path":"/\#(mappingScenario == "moved" ? "Other" : "NetVplayer")/sample.mp4","size":\#(mappingSize),"category":1,"isdir":0}"# }.joined(separator: ","))]}"#
            }
            if path == "/open/folder/get_info" {
                return #"{"state":true,"data":{"file_id":"\#(mappingScenario == "unrelated" ? "another-id" : "destination")","pick_code":"pick","size":\#(mappingSize)}}"#
            }
            if path == "/v2/file/get", mappingScenario == "unrelated" { return #"{"file_id":"another-id","name":"sample.mp4","type":"file","size":100}"# }
            if path == "/v2/file/get", mappingScenario == "deleted" { return #"{"code":"NotFound.File"}"# }
            if path == "/v2/file/get" { return #"{"file_id":"\#(mappingID)","name":"sample.mp4","parent_file_id":"\#(mappingParent)","drive_id":"drive","type":"file","size":\#(mappingSize)}"# }
            if path == "/api/create" { return #"{"errno":-8}"# }
            if path == "/share/verify" { return #"{"errno":0,"randsk":"fixture"}"# }
            if path.hasPrefix("/s/") { return "<html>fixture</html>" }
            if path == "/api/mediainfo" { return #"{"errno":133,"info":{"dlink":"https://media.invalid/sample.mp4","size":100}}"# }
            if path.hasSuffix("/get_download_url") { return #"{"url":"https://media.invalid/sample.mp4"}"# }
            if path.contains("/m3u8/") { return "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=4000\nhttps://media.invalid/sample.m3u8\n" }
            if path.hasSuffix("/create_session") || path.hasSuffix("/file/update") { return "{}" }
            if path.hasSuffix("/rename") { return #"{"code":0}"# }
            if path.hasSuffix("/file/v2/play") { return #"{"code":0,"data":{"video_list":[{"resolution":"super","trans_status":"success","video_info":{"url":"https://media.invalid/sample.m3u8"}}]}}"# }
            if path.hasSuffix("/file/download") { return #"{"code":0,"data":[]}"# }
            if path.hasSuffix("/get_video_preview_play_info") { return #"{"video_preview_play_info":{"live_transcoding_task_list":[]}}"# }
            if path.contains("/token") { return #"{"code":0,"data":{"token":"fixture"}}"# }
            throw URLError(.unsupportedURL)
        }
    }
}

@Suite(.serialized)
struct DriveTransferProtocolTests {
    @Test(arguments: [DriveProvider.quark, .uc, .ali, .p115, .baidu], [false, true])
    func persistedRecoveryAcrossLaunch(provider: DriveProvider, knownID: Bool) async throws {
        await sharedSavedFileStoreTestLock.acquire()
        do {
            try await persistedExercise(provider: provider, knownID: knownID)
            await sharedSavedFileStoreTestLock.release()
        } catch { await sharedSavedFileStoreTestLock.release(); throw error }
    }

    private func persistedExercise(provider: DriveProvider, knownID: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("msc04-protocol-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); ConfirmationProtocol.fixture = nil }
        let fixture = ConfirmationFixture(provider, knownID: knownID)
        ConfirmationProtocol.fixture = fixture
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ConfirmationProtocol.self]
        let http = HTTPClient(session: URLSession(configuration: config)).withExplicitProxy(nil)
        let store = DriveTransferTaskStore(storage: StorageManager(storageDirectory: root))
        let coordinator = DriveTransferCoordinator(store: store)
        let cookie = "__uid=fixture; UID=115001_A1_fixture; BDUSS=fixture"
        let resolve = resolver(provider: provider, http: http, shareID: UUID().uuidString, cookie: cookie)
        fixture.onSubmission = {
            let record = try #require(DriveTransferTaskStore(storage: StorageManager(storageDirectory: root)).records().first)
            #expect(record.submitted && record.phase == .outcomeUnknown)
            #expect(!record.previousIDs.isEmpty)
        }
        try await DriveTransferContext.$current.withValue(.init(configurationIdentity: "saved-config")) {
            do {
                try await DriveTransferCoordinator.$current.withValue(coordinator) { try await resolve() }
                Issue.record("file was not visible")
            } catch DriveEngineError.transferConfirmationPending { }
        }
        #expect(fixture.writes == 1)
        let journalBytes = try Data(contentsOf: root.appendingPathComponent(DriveTransferTaskStore.filename))
        let raw = String(decoding: journalBytes, as: UTF8.self)
        for secret in ["__uid=", "UID=", "BDUSS=", "fidToken", "stoken", "https://", "access_token", "refresh_token"] {
            #expect(!raw.contains(secret))
        }
        let beforeRestart = fixture.requestCount
        let reopenedStore = DriveTransferTaskStore(storage: StorageManager(storageDirectory: root))
        let reopened = DriveTransferCoordinator(store: reopenedStore)
        let record = try #require(try await reopened.summaries().first)
        #expect(record.scope.configurationIdentity == "saved-config")
        #expect(fixture.requestCount == beforeRestart)
        let credential = provider == .ali
            ? CloudCredential(provider: .ali, kind: .accessToken, secret: "fixture", accessToken: "fixture", metadata: ["default_drive_id": "drive", "user_id": "fixture"])
            : .cookie(provider: provider, value: cookie)
        for mismatch in ["account", "configuration"] {
            await #expect(throws: DriveTaskRecoveryError.self) {
                _ = try await reopened.continueRecovery(record.id,
                    credential: mismatch == "account" ? .cookie(provider: provider, value: "different-account") : credential,
                    configurationIdentity: mismatch == "configuration" ? "changed" : "saved-config", httpClient: http)
            }
        }
        #expect(fixture.requestCount == beforeRestart)
        let mutations = fixture.remoteMutations
        fixture.reveal()
        let result = try await reopened.continueRecovery(record.id, credential: credential,
            configurationIdentity: "saved-config", httpClient: http)
        #expect(result == .fileConfirmed)
        #expect(fixture.writes == 1 && fixture.remoteMutations == mutations)
        #expect(try reopenedStore.records().first?.completed == true)
        #expect(await DriveSavedFileStore.shared.record(for: record.scope.cacheKey)?.savedFID == "destination")
        try await DriveSavedFileStore.shared.remove(cacheKey: record.scope.cacheKey)
    }

    @Test(arguments: ["beforeSubmit", "confirmed", "cancelled", "targetChanged", "lateCancel", "lateAccount", "exhausted", "oneRetry", "mappingWriteFail"])
    func restoredBoundariesHaveOnlyExplicitReadEffects(boundary: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("msc04-boundary-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); ConfirmationProtocol.fixture = nil }
        let fixture = ConfirmationFixture(.quark, knownID: true)
        fixture.reveal()
        ConfirmationProtocol.fixture = fixture
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ConfirmationProtocol.self]
        let http = HTTPClient(session: URLSession(configuration: config)).withExplicitProxy(nil)
        let store = DriveTransferTaskStore(storage: StorageManager(storageDirectory: root))
        let cookie = "__uid=fixture", account = DriveTransferContext.account(provider: .quark, cookie: cookie)
        let base = DriveSavedFileNaming.identity(provider: .quark, pwdID: "isolated", fid: "source", name: "sample.mp4", size: 100)
        let identity = base.scoped(account: account, target: "folder")
        let scope = DriveTransferTaskScope.make(identity: identity, account: account, target: "folder",
            shareID: "isolated", sourceFileID: "source", name: "sample.mp4", size: 100)
        var record = DriveTransferTask(scope: scope)
        if boundary != "beforeSubmit" { record.submitted = true; record.phase = .fileConfirmed; record.fileID = "destination" }
        if boundary == "cancelled" { record.cancelled = true }
        if boundary == "exhausted" || boundary == "oneRetry" {
            record.remainingReadRetries = boundary == "oneRetry" ? 1 : 0
            fixture.mappingScenario = "offline"
        }
        if boundary == "targetChanged" { fixture.mappingScenario = "policy" }
        try store.insert(record)
        let id = record.id
        let current = RecoveryCurrentState()
        if boundary == "lateCancel" { fixture.onRead = { try store.cancel(id) } }
        if boundary == "lateAccount" { fixture.onRead = { current.retire() } }
        let mappingDirectory = root.appendingPathComponent("mapping")
        try FileManager.default.createDirectory(at: mappingDirectory, withIntermediateDirectories: true)
        if boundary == "mappingWriteFail" { try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: mappingDirectory.path) }
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: mappingDirectory.path) }
        let mapping = DriveSavedFileStore(fileURL: mappingDirectory.appendingPathComponent("mappings.json"))
        let coordinator = DriveTransferCoordinator(store: store)
        do {
            let result = try await DriveTransferContext.$current.withValue(.init(isCurrent: { current.isCurrent })) {
                try await coordinator.continueRecovery(id, credential: .cookie(provider: .quark, value: cookie),
                    configurationIdentity: "", httpClient: http, mappingStore: mapping)
            }
            #expect(result == (boundary == "beforeSubmit" ? .readyToRetry : .fileConfirmed))
            #expect(boundary == "beforeSubmit" || boundary == "confirmed")
        } catch { #expect(!["beforeSubmit", "confirmed"].contains(boundary)) }
        #expect(fixture.remoteMutations == 0)
        if boundary == "cancelled" { #expect(fixture.requestCount == 0) }
        if boundary == "exhausted" { #expect(fixture.requestCount == 1) }
        if boundary == "oneRetry" {
            #expect(fixture.requestCount == 2)
            #expect(try store.records().first?.remainingReadRetries == 0)
            let reopened = DriveTransferCoordinator(store: DriveTransferTaskStore(storage: StorageManager(storageDirectory: root)))
            do {
                _ = try await reopened.continueRecovery(id, credential: .cookie(provider: .quark, value: cookie),
                    configurationIdentity: "", httpClient: http, mappingStore: mapping)
                Issue.record("offline read reported success")
            } catch { }
            #expect(fixture.requestCount == 3)
        }
        if boundary == "mappingWriteFail" {
            #expect(try store.records().first?.phase == .fileConfirmed)
            #expect(try store.records().first?.completed == false)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: mappingDirectory.path)
            let reopened = DriveTransferCoordinator(store: DriveTransferTaskStore(storage: StorageManager(storageDirectory: root)))
            _ = try await reopened.continueRecovery(id, credential: .cookie(provider: .quark, value: cookie),
                configurationIdentity: "", httpClient: http, mappingStore: mapping)
            #expect(try store.records().first?.completed == true)
            #expect(fixture.remoteMutations == 0)
        }
        if boundary == "confirmed" || boundary == "mappingWriteFail" { #expect(await mapping.record(for: scope.cacheKey)?.savedFID == "destination") }
        else { #expect(await mapping.record(for: scope.cacheKey) == nil) }
    }

    @Test(arguments: [DriveProvider.quark, .uc, .ali, .p115, .baidu], [false, true])
    func uncertainWritesReadBeforeRetry(provider: DriveProvider, knownID: Bool) async throws {
        await sharedSavedFileStoreTestLock.acquire()
        do {
            try await DriveTransferCoordinator.$current.withValue(DriveTransferCoordinator()) {
                try await exercise(provider: provider, knownID: knownID)
            }
            await sharedSavedFileStoreTestLock.release()
        } catch {
            await sharedSavedFileStoreTestLock.release()
            throw error
        }
    }

    private func exercise(provider: DriveProvider, knownID: Bool) async throws {
        let fixture = ConfirmationFixture(provider, knownID: knownID)
        ConfirmationProtocol.fixture = fixture
        defer { ConfirmationProtocol.fixture = nil }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ConfirmationProtocol.self]
        let http = HTTPClient(session: URLSession(configuration: config)).withExplicitProxy(nil)
        let shareID = UUID().uuidString
        let cookie = "__uid=fixture; UID=115001_A1_fixture; BDUSS=fixture"
        let identity = DriveSavedFileNaming.identity(provider: provider, pwdID: shareID, fid: "source", name: "sample.mp4", size: 100)
            .scoped(account: provider == .ali ? "drive" : DriveTransferContext.account(provider: provider, cookie: cookie), target: provider == .baidu ? "/NetVplayer" : "folder")
        let resolve = resolver(provider: provider, http: http, shareID: shareID, cookie: cookie)
        for _ in 0..<2 {
            do { try await resolve(); Issue.record("unconfirmed result reported ready") }
            catch DriveEngineError.transferConfirmationPending { }
            #expect(fixture.writes == 1)
        }
        #expect(fixture.directoryReads < 60)
        if !knownID {
            fixture.reveal(ambiguous: true)
            do { try await resolve(); Issue.record("ambiguous namesakes must remain unconfirmed") }
            catch DriveEngineError.transferConfirmationPending { }
            #expect(fixture.writes == 1)
        }
        fixture.reveal()
        try await resolve()
        let saved = try #require(await DriveSavedFileStore.shared.record(for: identity.cacheKey))
        #expect(saved.savedFID == "destination")
        #expect(fixture.writes == 1)
        try await resolve()
        #expect(fixture.writes == 1)
        try await DriveSavedFileStore.shared.remove(cacheKey: identity.cacheKey)
    }
    private func resolver(provider: DriveProvider, http: HTTPClient, shareID: String, cookie: String) -> @Sendable () async throws -> Void {
        return {
            switch provider {
            case .quark:
                let file = QuarkShareFile(fid: "source", name: "sample.mp4", pdirFID: "0", category: 1, fileType: 1, size: 100,
                    formatType: "video/mp4", isDirectory: false, isFile: true, shareFIDToken: "fixture")
                _ = try await QuarkDriveClient(httpClient: http, pendingPlayPolls: 2, pendingPlayIntervalMilliseconds: 0)
                    .fetchSavedDownloadURLResult(for: .init(file: file, stoken: "fixture"), share: .init(originalURL: "https://pan.quark.cn/s/fixture", pwdID: shareID), cookie: cookie)
            case .uc:
                let file = UCShareFile(fid: "source", name: "sample.mp4", pdirFID: "0", category: 1, fileType: 1, size: 100,
                    formatType: "video/mp4", isDirectory: false, isFile: true, shareFIDToken: "fixture")
                _ = try await UCDriveClient(httpClient: http, pendingPlayPolls: 2, pendingPlayIntervalMilliseconds: 0)
                    .fetchSavedDownloadURLResult(for: .init(file: file, stoken: "fixture"), share: .init(originalURL: "https://drive.uc.cn/s/fixture", pwdID: shareID), cookie: cookie)
            case .ali:
                let file = AliShareFile(fileID: "source", name: "sample.mp4", parentFileID: "root", driveID: "share-drive", type: "file",
                    category: "video", size: 100, contentType: "video/mp4", downloadURL: "", playURL: "", isDirectory: false)
                _ = try await AliDriveClient(httpClient: http, originalDownloadPolls: 1, originalDownloadIntervalMilliseconds: 0)
                    .link(file: file, share: .init(originalURL: "https://www.alipan.com/s/fixture", shareID: shareID), shareToken: "fixture",
                        credential: .init(provider: .ali, kind: .accessToken, secret: "fixture", accessToken: "fixture",
                            metadata: ["default_drive_id": "drive", "user_id": "fixture"]))
            case .p115:
                let file = P115ShareFile(fileID: "source", name: "sample.mp4", parentID: "0", pickCode: "source-pick", size: 100, category: "video", downloadURL: "", isDirectory: false)
                _ = try await P115DriveClient(httpClient: http).link(file: file, share: .init(originalURL: "https://115.com/s/fixture", shareCode: shareID), cookie: cookie)
            case .baidu:
                let reference = DriveFileReference(provider: .baidu, shareURL: "https://pan.baidu.com/s/1fixture?pwd=1234", pwdID: shareID,
                    passcode: "1234", fid: "source", fidToken: "owner", fileName: "sample.mp4", size: 100)
                _ = try await BaiduDriveClient(httpClient: http).link(reference: reference, credential: .cookie(provider: .baidu, value: cookie))
            default: Issue.record("unexpected provider")
            }
        }
    }

    @Test(arguments: [DriveProvider.quark, .uc, .ali, .p115, .baidu],
          ["valid", "deleted", "size", "moved", "permission", "offline", "malformed", "policy"])
    func mappingChecksOnlyCurrentFile(provider: DriveProvider, scenario: String) async throws {
        await sharedSavedFileStoreTestLock.acquire()
        do {
            try await mappingExercise(provider: provider, scenario: scenario)
            await sharedSavedFileStoreTestLock.release()
        } catch {
            await sharedSavedFileStoreTestLock.release()
            throw error
        }
    }

    @Test(arguments: [DriveProvider.quark, .uc, .ali, .p115])
    func missingTargetDoesNotCreateDirectory(provider: DriveProvider) async throws {
        await sharedSavedFileStoreTestLock.acquire()
        do {
            try await mappingExercise(provider: provider, scenario: "missingFolder")
            await sharedSavedFileStoreTestLock.release()
        } catch {
            await sharedSavedFileStoreTestLock.release()
            throw error
        }
    }

    @Test func expiredAddressKeepsAliMapping() async throws {
        await sharedSavedFileStoreTestLock.acquire()
        do {
            try await mappingExercise(provider: .ali, scenario: "expired")
            await sharedSavedFileStoreTestLock.release()
        } catch {
            await sharedSavedFileStoreTestLock.release()
            throw error
        }
    }

    @Test(arguments: [DriveProvider.quark, .uc, .p115, .baidu])
    func incompleteDirectoryCannotProveDeletion(provider: DriveProvider) async throws {
        await sharedSavedFileStoreTestLock.acquire()
        do {
            try await mappingExercise(provider: provider, scenario: "partial")
            await sharedSavedFileStoreTestLock.release()
        } catch {
            await sharedSavedFileStoreTestLock.release()
            throw error
        }
    }

    @Test(arguments: [DriveProvider.quark, .uc, .ali, .p115], [false, true])
    func verifiedLegacyMappingRebindsWithoutRemoteWrites(provider: DriveProvider, nameKey: Bool) async throws {
        await sharedSavedFileStoreTestLock.acquire()
        do {
            try await legacyMappingExercise(provider: provider, nameKey: nameKey)
            await sharedSavedFileStoreTestLock.release()
        } catch {
            await sharedSavedFileStoreTestLock.release()
            throw error
        }
    }

    @Test(arguments: [DriveProvider.quark, .uc, .ali, .p115],
          ["deleted", "size", "moved", "permission", "offline", "malformed", "policy",
           "missingFolder", "partial", "source-id", "unknown-size", "wrong-share", "wrong-source",
           "fingerprint", "background"])
    func unprovenLegacyMappingIsPreservedWithoutRemoteWrites(provider: DriveProvider, scenario: String) async throws {
        await sharedSavedFileStoreTestLock.acquire()
        do {
            try await legacyMappingExercise(provider: provider, nameKey: false, scenario: scenario)
            await sharedSavedFileStoreTestLock.release()
        } catch {
            await sharedSavedFileStoreTestLock.release()
            throw error
        }
    }

    private func legacyMappingExercise(provider: DriveProvider, nameKey: Bool, scenario: String = "valid") async throws {
        let fixture = ConfirmationFixture(provider, knownID: true)
        fixture.reveal()
        fixture.mappingScenario = scenario
        ConfirmationProtocol.fixture = fixture
        defer { ConfirmationProtocol.fixture = nil }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ConfirmationProtocol.self]
        let http = HTTPClient(session: URLSession(configuration: config)).withExplicitProxy(nil)
        let shareID = UUID().uuidString
        let cookie = "__uid=fixture; UID=115001_A1_fixture; BDUSS=fixture"
        let account = provider == .ali ? "drive" : DriveTransferContext.account(provider: provider, cookie: cookie)
        let base = DriveSavedFileNaming.identity(provider: provider, pwdID: shareID, fid: "source", name: "sample.mp4", size: 100)
        let identity = base.scoped(account: account, target: "folder")
        let key = nameKey ? try #require(base.legacyCacheKey) : base.cacheKey
        let record = DriveSavedFileRecord(provider: provider, cacheKey: key,
            pwdID: scenario == "wrong-share" ? "other-share" : shareID,
            shareFID: scenario == "wrong-source" ? "other-source" : "source",
            fidToken: "old-token", size: scenario == "unknown-size" ? 0 : 100, originalName: "sample.mp4",
            savedFID: scenario == "source-id" ? "source" : "destination",
            savedFileName: "original-saved-name.mp4", parentFID: "folder",
            driveID: provider == .ali ? "drive" : provider == .p115 ? "115" : nil,
            savedPickCode: provider == .p115 ? "old-pick" : nil, isTemporary: false,
            contentFingerprint: scenario == "fingerprint" ? "original-fingerprint" : nil)
        let store = DriveSavedFileStore.shared
        try await store.save(record)
        do {
            let resolve = resolver(provider: provider, http: http, shareID: shareID, cookie: cookie)
            if scenario == "valid" {
                try await resolve()
                let bound = try #require(await store.record(for: identity.cacheKey))
                #expect(bound.savedFID == record.savedFID)
                #expect(bound.parentFID == record.parentFID)
                #expect(bound.size == record.size && bound.shareFID == record.shareFID)
                #expect(bound.isTemporary == false && bound.driveID == record.driveID)
                #expect(await store.record(for: key) == nil)
                try await resolve()
            } else {
                do {
                    if scenario == "background" {
                        try await DriveRequestRecovery.withBudget(background: true) { try await resolve() }
                    } else { try await resolve() }
                    Issue.record("unproven legacy mapping was adopted")
                } catch {
                    if !["permission", "offline", "malformed"].contains(scenario) {
                        #expect((error as? DriveServiceFailure)?.reason == .mappingUnconfirmed)
                    }
                }
                #expect(await store.record(for: key) == record)
                #expect(await store.record(for: identity.cacheKey) == nil)
                if ["source-id", "unknown-size", "wrong-share", "wrong-source", "background"].contains(scenario) {
                    // Ali authenticates before examining a mapping. None of
                    // these rejections may inspect or modify personal files.
                    #expect(fixture.requestedPaths == (provider == .ali
                        ? ["/users/v1/users/device/create_session"] : []))
                }
            }
            #expect(fixture.writes == 0 && fixture.remoteMutations == 0)
        } catch {
            try? await store.remove(cacheKey: key)
            try? await store.remove(cacheKey: identity.cacheKey)
            throw error
        }
        try await store.remove(cacheKey: key)
        try await store.remove(cacheKey: identity.cacheKey)
    }

    private func mappingExercise(provider: DriveProvider, scenario: String) async throws {
        let fixture = ConfirmationFixture(provider, knownID: true)
        fixture.reveal()
        fixture.mappingScenario = scenario
        ConfirmationProtocol.fixture = fixture
        defer { ConfirmationProtocol.fixture = nil }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ConfirmationProtocol.self]
        let http = HTTPClient(session: URLSession(configuration: config)).withExplicitProxy(nil)
        let shareID = UUID().uuidString
        let cookie = "__uid=fixture; UID=115001_A1_fixture; BDUSS=fixture"
        let account = provider == .ali ? "drive" : DriveTransferContext.account(provider: provider, cookie: cookie)
        let base = DriveSavedFileNaming.identity(provider: provider, pwdID: shareID, fid: "source", name: "sample.mp4", size: 100)
        let target = provider == .baidu ? (scenario == "policy" ? "/OldTarget" : "/NetVplayer") : "folder"
        let identity = base.scoped(account: account, target: target)
        let record = DriveSavedFileRecord(provider: provider, cacheKey: identity.cacheKey, pwdID: shareID,
            shareFID: "source", fidToken: "fixture", size: 100, originalName: "sample.mp4",
            savedFID: "destination", savedFileName: "sample.mp4",
            parentFID: provider == .baidu ? target + "/sample.mp4" : target,
            driveID: provider == .ali ? "drive" : provider == .p115 ? "115" : nil,
            targetRootFID: provider == .baidu ? nil : target, savedPickCode: "pick")
        let other = DriveSavedFileRecord(provider: provider, cacheKey: "unrelated-" + shareID, pwdID: "unrelated",
            shareFID: "other", fidToken: "", size: 100, originalName: "sample.mp4", savedFID: "other",
            savedFileName: "sample.mp4", parentFID: "unrelated-directory")
        try await DriveSavedFileStore.shared.save(record)
        try await DriveSavedFileStore.shared.save(other)
        let resolve = resolver(provider: provider, http: http, shareID: shareID, cookie: cookie)
        let changed = ["deleted", "size", "moved", "policy", "missingFolder"].contains(scenario)
        do {
            try await DriveTransferCoordinator.$current.withValue(DriveTransferCoordinator()) { try await resolve() }
            #expect(scenario == "valid")
        } catch let failure as DriveServiceFailure {
            let expected: AppFailureReason = changed ? .mappingChanged
                : scenario == "permission" ? .permissionDenied : scenario == "offline" ? .temporaryNetwork
                : scenario == "expired" ? .signedURLExpired : .mappingUnconfirmed
            #expect(failure.reason == expected)
        }
        #expect(fixture.writes == 0)
        #expect(fixture.remoteMutations == 0)
        #expect(!fixture.visitedParents.contains("unrelated-directory"))
        if scenario == "valid" {
            #expect(await DriveSavedFileStore.shared.record(for: identity.cacheKey)?.savedFID == record.savedFID)
        } else {
            #expect(await DriveSavedFileStore.shared.record(for: identity.cacheKey) == (changed ? nil : record))
        }
        #expect(await DriveSavedFileStore.shared.record(for: other.cacheKey) == other)
        #expect(fixture.directoryReads < 10)
        try await DriveSavedFileStore.shared.remove(cacheKey: identity.cacheKey)
        try await DriveSavedFileStore.shared.remove(cacheKey: other.cacheKey)
    }

    @Test(arguments: [DriveProvider.ali, .p115], ["unrelated", "size"])
    func stablePersonalReferenceDoesNotFallBackToShare(provider: DriveProvider, scenario: String) async throws {
        await sharedSavedFileStoreTestLock.acquire()
        do {
            let fixture = ConfirmationFixture(provider, knownID: true)
            fixture.mappingScenario = scenario
            ConfirmationProtocol.fixture = fixture
            defer { ConfirmationProtocol.fixture = nil }
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [ConfirmationProtocol.self]
            let http = HTTPClient(session: URLSession(configuration: config)).withExplicitProxy(nil)
            let reference = DriveFileReference(provider: provider,
                shareURL: provider == .ali ? "https://www.alipan.com/s/fixture" : "https://115.com/s/fixture",
                pwdID: "fixture", fid: "source", fidToken: "fixture", fileName: "sample.mp4",
                personalDriveID: provider == .ali ? "drive" : "115", personalFileID: "destination", pickCode: "pick", size: 100)
            do {
                if provider == .ali {
                    _ = try await AliDriveClient(httpClient: http).link(reference: reference,
                        credential: .init(provider: .ali, kind: .accessToken, secret: "fixture", accessToken: "fixture",
                            metadata: ["default_drive_id": "drive", "user_id": "fixture"]))
                } else {
                    _ = try await P115DriveClient(httpClient: http).link(reference: reference, cookie: "UID=115001_fixture", accessToken: "fixture")
                }
                Issue.record("unrelated personal file was accepted")
            } catch let failure as DriveServiceFailure {
                #expect(failure.reason == (scenario == "size" ? .mappingChanged : .mappingUnconfirmed))
            }
            #expect(fixture.remoteMutations == 0)
            #expect(fixture.directoryReads == 0)
            await sharedSavedFileStoreTestLock.release()
        } catch {
            await sharedSavedFileStoreTestLock.release()
            throw error
        }
    }

}
