import Foundation
import Testing
@testable import DriveEngine
import Models
import Networking

@Suite(.serialized)
struct BaiduFileIdentityTests {
    @Test(arguments: [false, true])
    func mediaInfoPreservesPlusAndOtherReservedFilenameCharacters(legacy: Bool) async throws {
        let filename = "样片 SDR+ 空格 & %2B #?.mp4"
        let fixture = try BaiduIdentityFixture(name: filename, correctFileName: filename)
        defer { fixture.close() }
        fixture.after = [fixture.correctFile]
        fixture.legacyMediaInfo = legacy

        let link = try await fixture.play()

        #expect(fixture.mediaPaths == Array(repeating: fixture.correctPath, count: legacy ? 2 : 1))
        #expect(link.url == "https://d.pcs.baidu.com/file/correct")
        #expect(link.metadata[DrivePlaybackMetadataKey.size] == String(fixture.size))
        #expect(fixture.transferCount == 1)
    }

    @Test(arguments: [false, true])
    func renamedTransferUsesMatchingDestination(omitSourceInfo: Bool) async throws {
        let fixture = try BaiduIdentityFixture()
        defer { fixture.close() }
        fixture.before = [fixture.oldFile]
        fixture.after = [fixture.oldFile, fixture.correctFile]
        fixture.transferResponse = ["errno": 0, "extra": ["list": [
            ["from_fs_id": "unrelated", "to_fs_id": "old", "to": "/NetVplayer/\(fixture.name)"],
            fixture.mapping
        ]]]
        if !omitSourceInfo {
            // Captured Baidu response: info is the original share, not the copy.
            fixture.transferResponse["info"] = [["errno": 0, "fsid": "source", "path": "/\(fixture.name)"]]
        }
        let link = try await fixture.play()
        let record = try #require(await fixture.store.record(for: fixture.identity))
        #expect(record.savedFID == "correct")
        #expect(record.parentFID == fixture.correctPath)
        #expect(record.size == fixture.size)
        #expect(fixture.mediaPaths == [fixture.correctPath])
        #expect(link.metadata[DrivePlaybackMetadataKey.fid] == "correct")
        #expect(link.metadata[DrivePlaybackMetadataKey.size] == String(fixture.size))
        #expect(link.headers["Cookie"] == nil)
    }

    @Test(arguments: [false, true])
    func fallbackExcludesPreexistingNamesake(returnSourceID: Bool) async throws {
        let fixture = try BaiduIdentityFixture()
        defer { fixture.close() }
        // The old film can even have the same byte count. It is not this transfer.
        var old = fixture.oldFile
        old["size"] = fixture.size
        fixture.before = [old]
        fixture.after = [old, fixture.correctFile]
        var item: [String: Any] = ["path": "/\(fixture.name)", "server_filename": fixture.name]
        if returnSourceID { item["fsid"] = "source" }
        fixture.transferResponse = ["errno": 0, "info": [item]]
        _ = try await fixture.play()
        #expect(fixture.mediaPaths == [fixture.correctPath])
        #expect(await fixture.store.record(for: fixture.identity)?.savedFID == "correct")
    }

    @Test(arguments: [false, true])
    func legacySourceIDAndWrongIDRequireManualRecovery(poisonedPersonalID: Bool) async throws {
        let fixture = try BaiduIdentityFixture()
        defer { fixture.close() }
        fixture.before = [fixture.oldFile, fixture.correctFile]
        fixture.after = fixture.before
        try await fixture.cache(id: poisonedPersonalID ? "old" : "source",
            size: poisonedPersonalID ? fixture.oldSize : fixture.size)
        do { _ = try await fixture.play(); Issue.record("invalid mapping must stop before another transfer") }
        catch let failure as DriveServiceFailure { #expect(failure.reason == .mappingChanged) }
        #expect(fixture.transferCount == 0)
        #expect(fixture.mediaPaths.isEmpty || fixture.mediaPaths == ["/NetVplayer/" + fixture.name])
        #expect(await fixture.store.record(for: fixture.identity) == nil)
    }

    @Test(arguments: [false, true])
    func duplicateCopiesRequireIdenticalFingerprints(identical: Bool) async throws {
        let fixture = try BaiduIdentityFixture()
        defer { fixture.close() }
        var second = fixture.correctFile
        second["fs_id"] = "second"
        second["server_filename"] = "S01E01 4KHQHDR60FPS(4).mp4"
        second["path"] = "/NetVplayer/S01E01 4KHQHDR60FPS(4).mp4"
        second["md5"] = identical ? "correct-content" : "different-content"
        fixture.before = [fixture.correctFile, second]
        fixture.transferResponse = ["errno": -9]
        try await fixture.cache(id: "source", size: fixture.size)
        // Even equal fingerprints cannot replace an already known missing ID.
        do { _ = try await fixture.play(); Issue.record("known ID fell back to another file") }
        catch let failure as DriveServiceFailure { #expect(failure.reason == .mappingChanged) }
        #expect(fixture.mediaPaths.isEmpty)
        #expect(fixture.transferCount == 0)
        #expect(await fixture.store.record(for: fixture.identity) == nil)
    }

    @Test(arguments: [false, true])
    func unknownDestinationAcceptsOnlyEquivalentNewCopies(identical: Bool) async throws {
        let fixture = try BaiduIdentityFixture()
        defer { fixture.close() }
        var second = fixture.correctFile
        second["fs_id"] = "second"
        second["server_filename"] = "S01E01 4KHQHDR60FPS(4).mp4"
        second["path"] = "/NetVplayer/S01E01 4KHQHDR60FPS(4).mp4"
        second["md5"] = identical ? "correct-content" : "different-content"
        fixture.before = []
        fixture.after = [fixture.correctFile, second]
        fixture.transferResponse = ["errno": 0, "info": [["fsid": "source", "path": "/" + fixture.name]]]
        if identical {
            _ = try await fixture.play()
            #expect(fixture.mediaPaths == [fixture.correctPath])
        } else {
            await #expect(throws: DriveEngineError.self) { _ = try await fixture.play() }
            #expect(fixture.mediaPaths.isEmpty)
        }
        #expect(fixture.transferCount == 1)
    }

    @Test(arguments: ["wrong-source", "missing-id", "outside-directory"])
    func rejectsUnrelatedDestinationMapping(reason: String) async throws {
        let fixture = try BaiduIdentityFixture()
        defer { fixture.close() }
        fixture.after = [fixture.correctFile]
        var mapping = fixture.mapping
        if reason == "wrong-source" { mapping["from_fs_id"] = "other-source" }
        if reason == "missing-id" { mapping["to_fs_id"] = "" }
        if reason == "outside-directory" { mapping["to"] = "/Other/\(fixture.name)" }
        fixture.transferResponse = ["errno": 0, "extra": ["list": [mapping]]]
        await #expect(throws: (any Error).self) { _ = try await fixture.play() }
        #expect(fixture.mediaPaths.isEmpty)
        #expect(await fixture.store.record(for: fixture.identity) == nil)
    }

    @Test(arguments: [false, true])
    func knownDestinationIDNeverFallsBackToSameName(wrongSize: Bool) async throws {
        let fixture = try BaiduIdentityFixture()
        defer { fixture.close() }
        var candidate = fixture.correctFile
        if wrongSize { candidate["size"] = fixture.oldSize }
        fixture.after = [candidate]
        var mapping = fixture.mapping
        mapping["to_fs_id"] = wrongSize ? "correct" : "not-visible"
        fixture.transferResponse = ["errno": 0, "extra": ["list": [mapping]]]
        await #expect(throws: (any Error).self) { _ = try await fixture.play() }
        #expect(fixture.mediaPaths.isEmpty)
        #expect(await fixture.store.record(for: fixture.identity) == nil)
    }

    @Test func missingDestinationDoesNotReuseAnExistingFile() async throws {
        let fixture = try BaiduIdentityFixture()
        defer { fixture.close() }
        fixture.before = [fixture.correctFile]
        fixture.after = fixture.before
        fixture.transferResponse = ["errno": 0, "info": [["fsid": "source", "path": "/\(fixture.name)"]]]
        await #expect(throws: (any Error).self) { _ = try await fixture.play() }
        #expect(fixture.mediaPaths.isEmpty)
    }

    @Test(arguments: [false, true])
    func mediaSizeMismatchInvalidatesCacheBeforeReturningLink(legacyMediaInfo: Bool) async throws {
        let fixture = try BaiduIdentityFixture()
        defer { fixture.close() }
        fixture.before = [fixture.oldFile]
        fixture.after = [fixture.oldFile, fixture.correctFile]
        fixture.legacyMediaInfo = legacyMediaInfo
        try await fixture.cache(id: "old", size: fixture.size)
        do { _ = try await fixture.play(); Issue.record("mismatched mapping must stop before retransferring") }
        catch let failure as DriveServiceFailure { #expect(failure.reason == .mappingChanged) }
        #expect(fixture.transferCount == 0)
        #expect(fixture.mediaPaths.isEmpty)
        #expect(await fixture.store.record(for: fixture.identity) == nil)
        // A later, explicit user retry may submit the original source again.
        let link = try await fixture.play()
        #expect(link.url.contains("correct"))
        #expect(fixture.transferCount == 1)
        #expect(await fixture.store.record(for: fixture.identity)?.savedFID == "correct")
    }

    @Test func unknownSizeDoesNotRepairLegacyCacheByNameAlone() async throws {
        let fixture = try BaiduIdentityFixture(size: 0)
        defer { fixture.close() }
        fixture.before = [fixture.oldFile]
        fixture.transferResponse = ["errno": -9]
        try await fixture.cache(id: "source", size: 0)
        await #expect(throws: (any Error).self) { _ = try await fixture.play() }
        #expect(fixture.mediaPaths.isEmpty)
    }

    @Test(arguments: [false, true])
    func verifiedUnscopedCopyMigratesWithoutShareOrTransfer(nameKey: Bool) async throws {
        let fixture = try BaiduIdentityFixture()
        defer { fixture.close() }
        fixture.before = [fixture.oldFile, fixture.correctFile]
        let legacy = fixture.legacyRecord(nameKey: nameKey)
        try await fixture.store.save(legacy)

        let link = try await fixture.play()

        #expect(link.metadata[DrivePlaybackMetadataKey.fid] == "correct")
        #expect(link.metadata[DrivePlaybackMetadataKey.cacheKey] == fixture.identity.cacheKey)
        #expect(await fixture.store.record(for: legacy.cacheKey) == nil)
        let migrated = try #require(await fixture.store.record(for: fixture.identity.cacheKey))
        #expect(migrated.savedFID == legacy.savedFID)
        #expect(migrated.contentFingerprint == "correct-content")
        #expect(migrated.isTemporary == false)
        #expect(fixture.mediaPaths == [fixture.correctPath])
        #expect(fixture.transferCount == 0)
        #expect(fixture.shareRequestCount == 0)
        // Reopening uses the proven account binding, including with an expired share.
        _ = try await fixture.play()
        #expect(fixture.transferCount == 0)
        #expect(fixture.shareRequestCount == 0)
    }

    @Test(arguments: [false, true])
    func malformedUnscopedSourceIDAllowsOnlyExplicitRetry(nameKey: Bool) async throws {
        let fixture = try BaiduIdentityFixture()
        defer { fixture.close() }
        fixture.before = [fixture.oldFile]
        fixture.after = [fixture.oldFile, fixture.correctFile]
        let legacy = fixture.legacyRecord(id: "source", nameKey: nameKey)
        try await fixture.store.save(legacy)

        do { _ = try await fixture.play(); Issue.record("invalid legacy mapping must stop before transfer") }
        catch let failure as DriveServiceFailure { #expect(failure.reason == .mappingChanged) }
        #expect(await fixture.store.record(for: legacy.cacheKey) == nil)
        #expect(fixture.folderListCount == 0)
        #expect(fixture.shareRequestCount == 0)
        #expect(fixture.transferCount == 0)
        #expect(fixture.mediaPaths.isEmpty)

        // A separate user retry may copy the exact source; an old namesake
        // must not become the replacement merely because its path agrees.
        let link = try await fixture.play()
        #expect(link.metadata[DrivePlaybackMetadataKey.fid] == "correct")
        #expect(fixture.mediaPaths == [fixture.correctPath])
        #expect(fixture.transferCount == 1)
        let repaired = try #require(await fixture.store.record(for: fixture.identity.cacheKey))
        #expect(repaired.savedFID == "correct")
        #expect(repaired.contentFingerprint == "correct-content")
        #expect(await fixture.store.record(for: legacy.cacheKey) == nil)

        _ = try await fixture.play()
        #expect(fixture.transferCount == 1)
        #expect(fixture.mediaPaths == [fixture.correctPath, fixture.correctPath])
    }

    @Test(arguments: ["missing", "other-account", "size", "path", "directory", "missing-hash", "changed-hash", "unknown-size"])
    func unprovenLegacyCopyIsPreservedWithoutTransfer(scenario: String) async throws {
        let fixture = try BaiduIdentityFixture(size: scenario == "unknown-size" ? 0 : 5_566_387_403)
        defer { fixture.close() }
        var file = fixture.correctFile
        if scenario == "other-account" { file["fs_id"] = "other" }
        if scenario == "size" { file["size"] = fixture.oldSize }
        if scenario == "path" { file["path"] = "/NetVplayer/other.mp4" }
        if scenario == "directory" { file["isdir"] = 1 }
        if scenario == "missing-hash" { file["md5"] = "" }
        fixture.before = scenario == "missing" ? [] : [file]
        let legacy = fixture.legacyRecord(
            fingerprint: scenario == "changed-hash" ? "different-content" : nil)
        try await fixture.store.save(legacy)

        do { _ = try await fixture.play(); Issue.record("unproven legacy copy was adopted") }
        catch let failure as DriveServiceFailure { #expect(failure.reason == .mappingUnconfirmed) }

        #expect(await fixture.store.record(for: legacy.cacheKey) == legacy)
        #expect(await fixture.store.record(for: fixture.identity.cacheKey) == nil)
        #expect(fixture.transferCount == 0)
        #expect(fixture.shareRequestCount == 0)
        #expect(fixture.mediaPaths.isEmpty)
        if scenario == "unknown-size" {
            #expect(fixture.folderListCount == 0)
        }
    }

    @Test(arguments: ["share", "source", "size", "unknown-size", "path"])
    func inconsistentLegacySourceIDIsPreserved(field: String) async throws {
        let fixture = try BaiduIdentityFixture()
        defer { fixture.close() }
        let base = fixture.legacyRecord(id: "source")
        let legacy = DriveSavedFileRecord(provider: .baidu, cacheKey: base.cacheKey,
            pwdID: field == "share" ? "other-share" : base.pwdID,
            shareFID: field == "source" ? "other-source" : base.shareFID,
            fidToken: base.fidToken,
            size: field == "unknown-size" ? 0 : (field == "size" ? fixture.oldSize : base.size),
            originalName: base.originalName, savedFID: base.savedFID, savedFileName: base.savedFileName,
            parentFID: field == "path" ? "/Other/file.mp4" : base.parentFID)
        try await fixture.store.save(legacy)

        do { _ = try await fixture.play(); Issue.record("inconsistent legacy row was discarded") }
        catch let failure as DriveServiceFailure { #expect(failure.reason == .mappingUnconfirmed) }
        #expect(await fixture.store.record(for: legacy.cacheKey) == legacy)
        #expect(fixture.folderListCount == 0)
        #expect(fixture.shareRequestCount == 0)
        #expect(fixture.transferCount == 0)
        #expect(fixture.mediaPaths.isEmpty)
    }

    @Test(arguments: [false, true])
    func backgroundCannotInvalidateUnscopedSourceID(nameKey: Bool) async throws {
        let fixture = try BaiduIdentityFixture()
        defer { fixture.close() }
        let legacy = fixture.legacyRecord(id: "source", nameKey: nameKey)
        try await fixture.store.save(legacy)
        do {
            _ = try await DriveRequestRecovery.withBudget(background: true) { try await fixture.play() }
            Issue.record("background playback discarded a legacy row")
        } catch let failure as DriveServiceFailure { #expect(failure.reason == .mappingUnconfirmed) }
        #expect(await fixture.store.record(for: legacy.cacheKey) == legacy)
        #expect(fixture.folderListCount == 0)
        #expect(fixture.shareRequestCount == 0)
        #expect(fixture.transferCount == 0)
        #expect(fixture.mediaPaths.isEmpty)
    }

    @Test func conflictingLegacyRowsCannotSelectAnArbitraryCopy() async throws {
        let fixture = try BaiduIdentityFixture()
        defer { fixture.close() }
        fixture.before = [fixture.correctFile]
        let sizeKey = fixture.legacyRecord()
        let nameKey = fixture.legacyRecord(nameKey: true)
        try await fixture.store.save(sizeKey)
        try await fixture.store.save(nameKey)
        do { _ = try await fixture.play(); Issue.record("conflicting legacy rows were accepted") }
        catch let failure as DriveServiceFailure { #expect(failure.reason == .mappingUnconfirmed) }
        #expect(await fixture.store.record(for: sizeKey.cacheKey) == sizeKey)
        #expect(await fixture.store.record(for: nameKey.cacheKey) == nameKey)
        #expect(fixture.transferCount == 0)
        #expect(fixture.mediaPaths.isEmpty)
    }

    @Test(arguments: [false, true])
    func failedLegacyLookupCannotInvalidateAnUnboundRow(partial: Bool) async throws {
        let fixture = try BaiduIdentityFixture()
        defer { fixture.close() }
        let legacy = fixture.legacyRecord()
        try await fixture.store.save(legacy)
        fixture.folderResponseOverride = partial
            ? ["errno": 0, "list": [fixture.correctFile], "has_more": 1]
            : ["errno": -9]
        await #expect(throws: (any Error).self) { _ = try await fixture.play() }
        #expect(await fixture.store.record(for: legacy.cacheKey) == legacy)
        #expect(fixture.transferCount == 0)
        #expect(fixture.mediaPaths.isEmpty)
    }

    @Test func backgroundCannotMigrateAnUnboundRow() async throws {
        let fixture = try BaiduIdentityFixture()
        defer { fixture.close() }
        fixture.before = [fixture.correctFile]
        let legacy = fixture.legacyRecord()
        try await fixture.store.save(legacy)
        do {
            _ = try await DriveRequestRecovery.withBudget(background: true) { try await fixture.play() }
            Issue.record("background playback migrated an unbound row")
        } catch let failure as DriveServiceFailure { #expect(failure.reason == .mappingUnconfirmed) }
        #expect(await fixture.store.record(for: legacy.cacheKey) == legacy)
        #expect(fixture.folderListCount == 0)
        #expect(fixture.transferCount == 0)
        #expect(fixture.mediaPaths.isEmpty)
    }
}

private final class BaiduIdentityFixture: @unchecked Sendable {
    let name: String
    let correctPath: String
    let oldSize: Int64 = 5_144_043_507
    let size: Int64
    let directory: URL
    let store: DriveSavedFileStore
    let reference: DriveFileReference
    let identity: DriveSavedFileIdentity
    let coordinator = DriveTransferCoordinator()
    var before: [[String: Any]] = []
    var after: [[String: Any]] = []
    var transferResponse: [String: Any] = [:]
    var folderResponseOverride: [String: Any]?
    var legacyMediaInfo = false
    private(set) var transferCount = 0
    private(set) var shareRequestCount = 0
    private(set) var folderListCount = 0
    private(set) var mediaPaths: [String] = []
    private let lock = NSLock()

    var oldFile: [String: Any] {
        ["fs_id": "old", "server_filename": name, "path": "/NetVplayer/\(name)",
         "size": oldSize, "isdir": 0, "md5": "old-content"]
    }
    var correctFile: [String: Any] {
        ["fs_id": "correct", "server_filename": (correctPath as NSString).lastPathComponent,
         "path": correctPath, "size": size, "isdir": 0, "md5": "correct-content"]
    }
    var mapping: [String: String] {
        ["from_fs_id": "source", "to_fs_id": "correct", "from": "/\(name)", "to": correctPath]
    }

    init(size: Int64 = 5_566_387_403, name: String = "S01E01 4KHQHDR60FPS.mp4",
         correctFileName: String = "S01E01 4KHQHDR60FPS(3).mp4") throws {
        self.size = size
        self.name = name
        correctPath = "/NetVplayer/" + correctFileName
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = DriveSavedFileStore(fileURL: directory.appendingPathComponent("saved.json"))
        reference = DriveFileReference(provider: .baidu,
            shareURL: "https://pan.baidu.com/s/1identity-\(UUID().uuidString)?pwd=test", pwdID: UUID().uuidString,
            passcode: "test", fid: "source", fidToken: "owner", fileName: name, size: size)
        identity = DriveSavedFileNaming.identity(provider: .baidu, pwdID: reference.pwdID,
            fid: reference.fid, name: name, size: size)
            .scoped(account: DriveTransferContext.account(provider: .baidu, cookie: "BDUSS=fixture-account"), target: "/NetVplayer")
        transferResponse = ["errno": 0, "extra": ["list": [mapping]]]
        BaiduIdentityURLProtocol.fixture = self
    }

    func close() {
        BaiduIdentityURLProtocol.fixture = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func cache(id: String, size: Int64) async throws {
        try await store.save(DriveSavedFileRecord(provider: .baidu, cacheKey: identity.cacheKey,
            pwdID: reference.pwdID, shareFID: reference.fid, fidToken: reference.fidToken,
            size: size, originalName: name, savedFID: id, savedFileName: name, parentFID: "/NetVplayer/\(name)"))
    }

    func legacyRecord(id: String = "correct", nameKey: Bool = false, fingerprint: String? = nil) -> DriveSavedFileRecord {
        let base = DriveSavedFileNaming.identity(provider: .baidu, pwdID: reference.pwdID,
            fid: reference.fid, name: name, size: size)
        return DriveSavedFileRecord(provider: .baidu, cacheKey: nameKey ? base.legacyCacheKey! : base.cacheKey,
            pwdID: reference.pwdID, shareFID: reference.fid, fidToken: reference.fidToken,
            size: size, originalName: name, savedFID: id, savedFileName: "S01E01 4KHQHDR60FPS(3).mp4",
            parentFID: correctPath, isTemporary: false, contentFingerprint: fingerprint)
    }

    func play() async throws -> CloudDriveLink {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BaiduIdentityURLProtocol.self]
        let http = HTTPClient(session: URLSession(configuration: configuration)).withExplicitProxy(nil)
        return try await DriveTransferCoordinator.$current.withValue(coordinator) {
            try await BaiduDriveClient(httpClient: http, savedFileStore: store).link(
                reference: reference, credential: .cookie(provider: .baidu, value: "BDUSS=fixture-account"))
        }
    }

    func respond(to url: URL) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        // Baidu decodes query parameters as form data: a bare '+' means a space.
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let formQuery = components?.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%20")
        components?.percentEncodedQuery = formQuery
        let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") })
        let object: [String: Any]
        switch url.path {
        case "/api/list":
            if query["dir"] == "/NetVplayer" {
                folderListCount += 1
                object = folderResponseOverride ?? ["errno": 0, "list": transferCount == 0 ? before : after]
            } else {
                object = ["errno": 0, "list": []]
            }
        case "/api/create": object = ["errno": -8]
        case "/share/verify":
            shareRequestCount += 1
            object = ["errno": 0, "randsk": "fixture-share-key"]
        case "/share/transfer":
            transferCount += 1
            object = transferResponse
        case "/api/mediainfo":
            let path = query["path"] ?? ""
            mediaPaths.append(path)
            if legacyMediaInfo && query["type"] != "VideoURL" {
                object = ["errno": 0]
            } else {
                let correct = path == correctPath
                object = ["errno": 133, "info": ["size": correct ? size : oldSize,
                    "dlink": "https://d.pcs.baidu.com/file/\(correct ? "correct" : "wrong")"]]
            }
        default:
            if url.path.hasPrefix("/s/") {
                shareRequestCount += 1
                return Data("<html>verify</html>".utf8)
            }
            throw URLError(.unsupportedURL)
        }
        return try JSONSerialization.data(withJSONObject: object)
    }
}

private final class BaiduIdentityURLProtocol: URLProtocol, @unchecked Sendable {
    // The suite is serialized; each session is completed before its fixture closes.
    nonisolated(unsafe) static var fixture: BaiduIdentityFixture?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let url = request.url, let fixture = Self.fixture else { throw URLError(.badURL) }
            let data = try fixture.respond(to: url)
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
