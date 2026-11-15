import Foundation
import Testing
import Models
import Storage
@testable import FileServiceEngine

@Suite("FTP and SFTP contracts")
struct RemoteTransferTests {
    @Test func endpointsAndLegacyConfiguration() throws {
        let ftp = try FileServiceConfiguration(name: "FTP", kind: .ftp, address: "ftp://nas.local:2121/视频", rootPath: "/电影").validated()
        #expect(ftp.address == "ftp://nas.local:2121")
        #expect(ftp.rootPath == "/视频/电影")
        #expect(try ftp.validated() == ftp)
        let old = try JSONDecoder().decode(FileServiceConfiguration.self, from: Data(#"{"id":"A3C67EAE-AF0F-457E-A7E7-AE9CC51E8764","name":"NAS","kind":"smb","address":"smb://nas.local","rootPath":"/","share":"Movies","domain":"","guest":false}"#.utf8))
        #expect(old.sshHostKeySHA256 == nil)
        for address in ["http://nas.local", "sftp://user:password@nas.local", "sftp://nas.local?password=x", "sftp://nas.local:99999"] {
            #expect(throws: FileServiceError.self) { try FileServiceConfiguration(name: "SFTP", kind: .sftp, address: address).validated() }
        }
        var ssh = FileServiceConfiguration(name: "SSH", kind: .sftp, address: "nas.local")
        #expect(try ssh.validated().address == "sftp://nas.local")
        ssh.sshHostKeySHA256 = "   "
        #expect(try ssh.validated().sshHostKeySHA256 == nil)
        ssh.sshHostKeySHA256 = "SHA256:" + Data(repeating: 1, count: 32).base64EncodedString()
        let normalized = try ssh.validated()
        #expect(normalized.sshHostKeySHA256?.hasSuffix("=") == false)
        var changed = normalized; changed.sshHostKeySHA256 = nil
        #expect(changed.endpointIdentity != normalized.endpointIdentity)
    }
    @Test func machineAndLegacyListingsPreserveChineseNamesAndLargeSizes() throws {
        let mlsd = "type=cdir;modify=20261021000000; .\r\ntype=dir; 中文目录\r\ntype=file;size=5000000000;modify=20261021100000; 中文 影片 #%?.mkv\r\n"
        let entries = try FTPDirectoryListing.parse(Data(mlsd.utf8), path: "/库", mlsd: true)
        try #require(entries.count == 2)
        #expect(entries[0].isDirectory)
        #expect(entries[1].path == "/库/中文 影片 #%?.mkv")
        #expect(entries[1].size == 5_000_000_000 && entries[1].modifiedAt != nil)
        let unix = "total 2\n-rw-r--r-- 1 tester staff 5000000000 Oct 21 10:00 中文 电影.mkv\nlrwxrwxrwx 1 tester staff 10 Oct 21 10:00 link -> /outside\n"
        let parsed = try FTPDirectoryListing.parse(Data(unix.utf8), path: "/", mlsd: false)
        #expect(parsed[0].size == 5_000_000_000 && parsed[1].isSymbolicLink)
        let dos = "10-21-26  10:00AM       <DIR>          电影\n10-21-26  10:01AM       5000000000     film.mkv\n"
        #expect(try FTPDirectoryListing.parse(Data(dos.utf8), path: "/", mlsd: false).last?.size == 5_000_000_000)
        for line in ["type=file;size=1; ../escape", "type=file;size=-1; film", "garbage"] {
            #expect(throws: FileServiceError.self) { try FTPDirectoryListing.parse(Data(line.utf8), path: "/", mlsd: true) }
        }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_FILE_SERVICE_TEST_CONFIG"] != nil))
    func realSSHRejectsUnknownAndChangedHostBeforeLogin() async throws {
        struct Fixture: Decodable { let service: FileServiceConfiguration; let credentials: FileServiceCredentials }
        let path = try #require(ProcessInfo.processInfo.environment["NETVPLAYER_FILE_SERVICE_TEST_CONFIG"])
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        for fixture in fixtures where fixture.service.kind == .sftp {
            for fingerprint in [Optional<String>.none, "SHA256:" + Data(repeating: 0, count: 32).base64EncodedString()] {
                var service = fixture.service; service.sshHostKeySHA256 = fingerprint
                let client = try RemoteTransferClient(configuration: service, credentials: fixture.credentials)
                do { try await client.connect(); Issue.record("Untrusted SSH host was accepted") }
                catch { #expect(error.localizedDescription.contains("SSH 主机指纹")) }
                await client.disconnect()
            }
            let client = try RemoteTransferClient(configuration: fixture.service, credentials: fixture.credentials)
            try await client.connect()
            await #expect(throws: FileServiceError.self) { try await client.read(path: "/中文大文件.mkv", range: 0..<5_000_000) }
            await #expect(throws: FileServiceError.self) { try await client.read(path: "/../escape", range: 0..<1) }
            await client.disconnect()
            await #expect(throws: FileServiceError.self) { try await client.list(path: "/", cursor: nil) }
            print("[REAL_SFTP] unknown/changed host key rejected; trusted host, bounded reads, traversal and closed-session checks passed")
        }
    }
}
