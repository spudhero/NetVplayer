import Foundation
import Testing
import Models
@testable import FileServiceEngine

@Suite("SMB connection recovery")
struct SMBRecoveryTests {
    private func client(_ manager: RecoverySMBSession) throws -> SMBClient {
        try SMBClient(configuration: .init(name: "NAS", kind: .smb, address: "smb://nas.local", rootPath: "/Movies", share: "Shared"), session: manager)
    }

    @Test func browsingChecksSessionAfterIdleDisconnect() async throws {
        let manager = RecoverySMBSession()
        let client = try client(manager)
        try await client.connect()
        await manager.expire()
        let page = try await client.list(path: "/", cursor: nil)
        #expect(page.entries.first?.name == "Movie.mkv")
        #expect(await manager.connectCalls == 2)
        await manager.expire()
        #expect(try await client.stat(path: "/Movie.mkv").size == 4)
        #expect(await manager.connectCalls == 3)
    }

    @Test func disconnectedReadRetriesSameRangeOnceWithoutProbingHealthyChunks() async throws {
        let manager = RecoverySMBSession()
        let client = try client(manager)
        try await client.connect()
        await manager.expire()
        #expect(try await client.read(path: "/Movie.mkv", range: 10..<14) == Data(repeating: 1, count: 4))
        #expect(await manager.connectCalls == 2)
        #expect(await manager.readRanges == [10..<14, 10..<14])
        _ = try await client.read(path: "/Movie.mkv", range: 14..<18)
        #expect(await manager.connectCalls == 2)
        await manager.failReads(with: .ENOTCONN)
        await #expect(throws: FileServiceError.self) { _ = try await client.read(path: "/Movie.mkv", range: 18..<22) }
        #expect(await manager.connectCalls == 3)
        #expect(await manager.readRanges.suffix(2) == [18..<22, 18..<22])
    }

    @Test func genuineAccessDenialIsPreservedAndNotRetried() async throws {
        let manager = RecoverySMBSession()
        let client = try client(manager)
        try await client.connect()
        await manager.failReads(with: .EACCES)
        await #expect(throws: FileServiceError.permission("/Movies/Movie.mkv")) {
            _ = try await client.read(path: "/Movie.mkv", range: 0..<4)
        }
        #expect(await manager.connectCalls == 1)
        #expect(await manager.readRanges.count == 1)
    }
}

private actor RecoverySMBSession: SMBSession {
    private var connected = false
    var connectCalls = 0
    var readRanges: [Range<Int64>] = []
    private var readFailure: POSIXErrorCode?
    func expire() { connected = false }
    func failReads(with code: POSIXErrorCode) { readFailure = code }
    func connect(share: String) async throws { connected = true; connectCalls += 1 }
    func disconnect() async { connected = false }
    func list(remotePath: String, relativePath: String) async throws -> [FileEntry] {
        guard connected else { throw POSIXError(.EACCES) }
        return [.init(path: try FileServicePath.join(relativePath, "Movie.mkv"), name: "Movie.mkv", isDirectory: false, size: 4)]
    }
    func stat(remotePath: String, relativePath: String) async throws -> FileEntry {
        guard connected else { throw POSIXError(.ENOTCONN) }
        return .init(path: relativePath, name: "Movie.mkv", isDirectory: false, size: 4)
    }
    func read(path: String, range: Range<Int64>) async throws -> Data {
        readRanges.append(range)
        if let readFailure { throw POSIXError(readFailure) }
        guard connected else { throw POSIXError(.ENOTCONN) }
        return Data(repeating: 1, count: 4)
    }
}
