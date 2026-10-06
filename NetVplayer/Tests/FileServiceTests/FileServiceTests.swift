import Foundation
import Testing
import Models
import Storage
import FileServiceEngine
import ProxyServer
import SpiderEngine
import MediaLibraryEngine

@Suite("File services", .serialized)
struct FileServiceTests {
    @Test func validationAndCredentialBinding() throws {
        var service = FileServiceConfiguration(name: "NAS", kind: .smb, address: "nas.local", share: "Movies", guest: true)
        service = try service.validated()
        #expect(service.address == "smb://nas.local:445")
        service.port = 65536
        #expect(throws: FileServiceError.self) { try service.validated() }
        #expect(throws: FileServiceError.self) { try FileServicePath.normalize("/movies/../../etc") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferences = UserPreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!, credentialStore: MemoryCredentialStore())
        let store = FileServiceStore(storage: StorageManager(storageDirectory: directory), preferences: preferences)
        service.port = 445
        try store.saveCredentials(.init(username: "tester", password: "secret"), for: service)
        #expect(try store.credentials(for: service).username == "tester")
        service.address = "smb://other.local:445"
        #expect(try store.credentials(for: service).username.isEmpty)
    }
    @Test func opaqueReferencesAndPortableBackup() throws {
        let service = FileServiceConfiguration(name: "本地", kind: .local)
        let reference = try FileResourceReference(serviceID: service.id, path: "/中文/影片$#1.mkv")
        #expect(FileResourceReference(locator: reference.locator) == reference)
        #expect(HistoryPersistencePolicy.sanitizedEpisodeLocator(reference.locator) == reference.locator)
        let backup = StorageBackup(fileServices: .init(services: [service]))
        let archive = try StorageBackupCodec.encode(backup)
        #expect(try StorageBackupCodec.decode(archive).backup.fileServices?.services == [service])
        let old = try StorageBackupCodec.decode(Data("{\"schemaVersion\":1,\"configs\":[],\"history\":[]}".utf8)).backup
        #expect(old.fileServices == nil)
        #expect(!String(decoding: archive, as: UTF8.self).contains("bookmark"))
        let passwords = FileServiceCredentials(directoryPasswords: ["/": "root", "/A": "a"])
        #expect(passwords.directoryPassword(for: "/AB") == "root")
        #expect(passwords.directoryPassword(for: "/A/film.mkv") == "a")
    }
    @Test func localDirectoryRangesAndSymlinkEscape() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data((0..<256).map(UInt8.init)).write(to: folder.appendingPathComponent("中文.mkv"))
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("escape").path, withDestinationPath: "/etc")
        let client = try LocalDirectoryClient(folder: folder)
        try await client.connect()
        #expect(try await client.allEntries(path: "/").contains { $0.name == "中文.mkv" })
        #expect(try await client.read(path: "/中文.mkv", range: 120..<130) == Data((120..<130).map(UInt8.init)))
        await #expect(throws: FileServiceError.self) { try await client.resolve(path: "/escape/passwd") }
        await client.disconnect()
        await #expect(throws: FileServiceError.self) { try await client.list(path: "/", cursor: nil) }
    }
    @Test func localBookmarkAndRuntimeConfigurationChange() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["A", "B"] {
            let path = folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: path.appendingPathComponent(name + ".mp4"))
        }
        let store = FileServiceStore(storage: StorageManager(storageDirectory: folder.appendingPathComponent("state")), preferences:
            UserPreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!, credentialStore: MemoryCredentialStore()))
        var service = FileServiceConfiguration(name: "本地", kind: .local, rootPath: "/A")
        try store.save(.init(services: [service]))
        try store.saveBookmark(folder.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil), for: service.id)
        let runtime = FileServiceRuntime(store: store)
        let first = try await runtime.client(for: service.id)
        #expect(try await first.allEntries(path: "/").first?.name == "A.mp4")
        service.rootPath = "/B"; try store.save(.init(services: [service]))
        let second = try await runtime.client(for: service.id)
        #expect(try await second.allEntries(path: "/").first?.name == "B.mp4")
        let ref = try FileResourceReference(serviceID: service.id, path: "/B.mp4")
        let lease = UUID(); let resource = try await runtime.resolvePlayback(ref, leaseID: lease)
        #expect(resource.url.isFileURL); #expect(try Data(contentsOf: resource.url) == Data("fixture".utf8))
        await runtime.releasePlayback(leaseID: lease); await runtime.invalidate(serviceID: service.id)
        #expect(throws: (any Error).self) { try LocalDirectoryClient(bookmark: Data("invalid bookmark".utf8)) }
    }
    @Test func byteRangesAndStreamingProxy() async throws {
        #expect(SeekableRange.parse("bytes=-20", size: 100) == 80..<100)
        #expect(SeekableRange.parse("bytes=90-999999999999999999", size: 100) == 90..<100)
        #expect(SeekableRange.parse("bytes=100-", size: 100) == nil)
        #expect(SeekableRange.parse("bytes=0-1,4-5", size: 100) == nil)
        let proxy = ProxyServer(); try proxy.start(); defer { proxy.stop() }
        let reads = RangeRecorder()
        let url = try proxy.registerSeekableResource(.init(size: 5_000_000_000) { range in
            await reads.record(range); return Data(repeating: 42, count: range.count)
        })
        var request = URLRequest(url: URL(string: url)!); request.setValue("bytes=4000000000-4001100000", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 206)
        #expect(data.count == 1_100_001)
        #expect(await reads.maximumCount <= 512 * 1024)
        #expect(await reads.firstOffset == 4_000_000_000)
        request.httpMethod = "HEAD"
        let (headData, headResponse) = try await URLSession.shared.data(for: request)
        #expect(headData.isEmpty)
        #expect((headResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length") == "1100001")
        proxy.unregisterSeekableResource(url: url)
        #expect((try await URLSession.shared.data(for: request).1 as? HTTPURLResponse)?.statusCode == 404)
    }
    @Test func aListPaginationDirectoryPasswordAndExpiredLogin() async throws {
        let fixture = AListFixture()
        let client = try AListClient(configuration: .init(name: "测试", kind: .openList, address: "http://localhost:5244", rootPath: "/库"),
                                    credentials: .init(username: "tester", password: "secret", directoryPasswords: ["/库": "dir-secret"]),
                                    requestHandler: { url, method, headers, body in try await fixture.request(url, headers: headers, body: body) })
        try await client.connect()
        let entries = try await client.allEntries(path: "/")
        #expect(entries.count == 451)
        #expect(entries.last?.path == "/影片450.mkv")
        #expect(await fixture.loginCount == 2)
        #expect(await fixture.directoryPasswordCorrect)
    }
    @Test func realConfiguredProtocols() async throws {
        guard let path = ProcessInfo.processInfo.environment["NETVPLAYER_FILE_SERVICE_TEST_CONFIG"] else { return }
        let tests = try JSONDecoder().decode([ProtocolFixture].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        for fixture in tests {
            let client = try await FileServiceRuntime.shared.makeClient(configuration: fixture.service, credentials: fixture.credentials)
            try await client.connect()
            let entries = try await client.allEntries(path: "/")
            #expect(entries.count >= 453)
            #expect(entries.contains { $0.name == "中文大文件.mkv" })
            let entry = try #require(entries.first { $0.name == "中文大文件.mkv" })
            #expect(try await client.read(path: entry.path, range: 4_000_000_000..<4_000_000_032) == Data(repeating: 0, count: 32))
            await client.disconnect()
            var invalid = fixture.credentials; invalid.password = "invalid-fixture-password"
            await #expect(throws: FileServiceError.self) { try await FileServiceRuntime.shared.test(configuration: fixture.service, credentials: invalid) }
            var missing = fixture.service; missing.rootPath += "/missing-fixture-folder"
            await #expect(throws: FileServiceError.self) { try await FileServiceRuntime.shared.test(configuration: missing, credentials: fixture.credentials) }
            print("[REAL_PROTOCOL] \(fixture.service.kind.rawValue): \(entries.count) entries, Chinese 5 GB range, bad credentials and missing root verified")
            if fixture.service.kind == .smb {
                var guest = fixture.service; guest.share = "Public"; guest.guest = true
                let guestClient = try await FileServiceRuntime.shared.makeClient(configuration: guest, credentials: .init())
                try await guestClient.connect()
                #expect(try await guestClient.allEntries(path: "/").contains { $0.name == "中文大文件.mkv" })
                #expect(try await guestClient.read(path: "/中文大文件.mkv", range: 4_000_000_000..<4_000_000_032) == Data(repeating: 0, count: 32))
                await guestClient.disconnect(); print("[REAL_PROTOCOL] smb: guest connection verified")
            }
        }
    }
    @Test(.disabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_FILE_SERVICE_PLAYBACK_ACCEPTANCE"] != "1"))
    func realPlaybackSeekingSubtitlesAndLeaseRelease() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["NETVPLAYER_FILE_SERVICE_TEST_CONFIG"])
        var fixtures = try JSONDecoder().decode([ProtocolFixture].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        if var guest = fixtures.first(where: { $0.service.kind == .smb }) {
            guest.service.share = "Public"; guest.service.guest = true; guest.credentials = .init(); fixtures.append(guest)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileServiceStore(storage: StorageManager(storageDirectory: directory), preferences:
            UserPreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!, credentialStore: MemoryCredentialStore()))
        let runtime = FileServiceRuntime(store: store)
        let index = MediaIndex(url: directory.appendingPathComponent("index.sqlite"))
        let proxy = ProxyServer.shared; try proxy.start(); defer { proxy.stop() }
        for fixture in fixtures {
            let service = try fixture.service.validated()
            try store.save(.init(services: [service])); try store.saveCredentials(fixture.credentials, for: service)
            let provider = FileServiceNativeProvider(serviceID: service.id, runtime: runtime, index: index)
            let ref = try FileResourceReference(serviceID: service.id, path: "/播放测试.mp4")
            let result = try await provider.playerContent(site: service.site(), flag: "文件", id: ref.locator)
            #expect(result.subs.contains { $0.name == "播放测试.srt" })
            #expect(!result.url.contains("fixture-password"))
            let task = Process(); task.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/mpv")
            task.arguments = ["--no-config", "--vo=null", "--ao=null", "--really-quiet", "--start=3", "--length=1", "--sub-auto=no", "--sub-file=" + (result.subs.first?.url ?? ""), result.url]
            task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
            try task.run()
            let deadline = Date().addingTimeInterval(20)
            while task.isRunning && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
            if task.isRunning { task.terminate(); throw FileServiceError.network("mpv playback timeout") }
            #expect(task.terminationStatus == 0)
            let lease = try #require(result.fileResourceLeaseID.flatMap(UUID.init(uuidString:)))
            await runtime.releasePlayback(leaseID: lease)
            let request = URLRequest(url: try #require(URL(string: result.url)))
            #expect((try await URLSession.shared.data(for: request).1 as? HTTPURLResponse)?.statusCode == 404)
            await runtime.invalidate(serviceID: service.id)
            print("[REAL_PLAYBACK] \(service.kind.rawValue): decoded Chinese-path MP4 from 3s, external subtitle, lease released")
        }
    }
}

private actor RangeRecorder {
    var maximumCount = 0; var firstOffset: Int64?
    func record(_ range: Range<Int64>) { maximumCount = max(maximumCount, range.count); if firstOffset == nil { firstOffset = range.lowerBound } }
}
private struct ProtocolFixture: Decodable { var service: FileServiceConfiguration; var credentials: FileServiceCredentials }
private actor AListFixture {
    var loginCount = 0; var directoryPasswordCorrect = true; private var expired = false
    func request(_ url: URL, headers: [String: String], body: Data?) throws -> (Data, HTTPURLResponse) {
        let request = try JSONSerialization.jsonObject(with: body ?? Data()) as? [String: Any] ?? [:]
        var object: [String: Any]
        if url.path == "/api/auth/login" { loginCount += 1; object = ["code": 200, "data": ["token": "token\(loginCount)"]] }
        else if !expired && request["page"] as? Int == 2 { expired = true; object = ["code": 401, "message": "token expired"] }
        else {
            #expect(headers["Authorization"] == "token\(loginCount)")
            directoryPasswordCorrect = directoryPasswordCorrect && request["password"] as? String == "dir-secret" && request["path"] as? String == "/库"
            let page = request["page"] as? Int ?? 1
            let content = ((page - 1) * 200..<min(page * 200, 451)).map { ["name": "影片\($0).mkv", "is_dir": false, "size": 100] as [String: Any] }
            object = ["code": 200, "data": ["content": content, "total": 451]]
        }
        return (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@Test(.disabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_LARGE_SMB_MEMORY_ACCEPTANCE"] != "1"))
func realLargeSMBBoundedMemory() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["NETVPLAYER_FILE_SERVICE_TEST_CONFIG"])
    let fixture = try #require(JSONDecoder().decode([ProtocolFixture].self, from: Data(contentsOf: URL(fileURLWithPath: path))).first { $0.service.kind == .smb })
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FileServiceStore(storage: StorageManager(storageDirectory: directory), preferences:
        UserPreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!, credentialStore: MemoryCredentialStore()))
    let service = try fixture.service.validated(); try store.save(.init(services: [service])); try store.saveCredentials(fixture.credentials, for: service)
    let runtime = FileServiceRuntime(store: store)
    let proxy = ProxyServer.shared; try proxy.start(); defer { proxy.stop() }
    let lease = UUID()
    let resource = try await runtime.resolvePlayback(FileResourceReference(serviceID: service.id, path: "/大文件播放.mp4"), leaseID: lease)
    let baseline = try residentKilobytes(); var peak = baseline
    let decoder = Process(); decoder.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/mpv")
    decoder.arguments = ["--no-config", "--vo=null", "--ao=null", "--really-quiet", "--start=3", "--length=1", resource.url.absoluteString]
    decoder.standardOutput = FileHandle.nullDevice; decoder.standardError = FileHandle.nullDevice; try decoder.run()
    let decodeDeadline = Date().addingTimeInterval(20)
    while decoder.isRunning && Date() < decodeDeadline { peak = max(peak, try residentKilobytes()); try await Task.sleep(for: .milliseconds(100)) }
    if decoder.isRunning { decoder.terminate(); throw FileServiceError.network("large MP4 decode timeout") }
    #expect(decoder.terminationStatus == 0)
    let reader = Process(); reader.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    reader.arguments = ["--fail", "--silent", "--max-time", "40", "--range", "4000000000-4033554431", "--output", "/dev/null", resource.url.absoluteString]
    reader.standardOutput = FileHandle.nullDevice; reader.standardError = FileHandle.nullDevice; try reader.run()
    while reader.isRunning { peak = max(peak, try residentKilobytes()); try await Task.sleep(for: .milliseconds(100)) }
    #expect(reader.terminationStatus == 0)
    #expect(peak - baseline < 128 * 1024)
    await runtime.releasePlayback(leaseID: lease); await runtime.invalidate(serviceID: service.id)
    print("[LARGE_SMB_MEMORY] 5 GB sparse valid MP4 decoded, 32 MiB streamed at 4 GB offset; server RSS growth \(peak - baseline) KiB")
}

private func residentKilobytes() throws -> Int {
    let process = Process(); let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-o", "rss=", "-p", String(ProcessInfo.processInfo.processIdentifier)]
    process.standardOutput = pipe; try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
    return Int(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
}
