import Foundation
import Testing
@testable import Models

@Suite("SMB folder addresses")
struct SMBFolderAddressTests {
    @Test func fullChineseAddressAndShareRoot() throws {
        let folder = try SMBFolderAddress("  smb://nas.local/家庭共享/电影/4K 原盘/  \n")
        #expect(folder.serverAddress == "smb://nas.local:445")
        #expect(folder.share == "家庭共享")
        #expect(folder.rootPath == "/电影/4K 原盘")
        #expect(try SMBFolderAddress("nas.local/家庭共享").rootPath == "/")
    }

    @Test func percentEncodedPathsDecodeExactlyOnce() throws {
        let folder = try SMBFolderAddress("smb://nas.local/%E5%AE%B6%E5%BA%AD%E5%85%B1%E4%BA%AB/%E7%94%B5%E5%BD%B1%20%231%3F/100%25/%252F")
        #expect(folder.share == "家庭共享")
        #expect(folder.rootPath == "/电影 #1?/100%/%2F")
        let configuration = folder.applying(to: .init(name: "NAS", kind: .smb))
        let display = SMBFolderAddress.formatted(configuration)
        #expect(display == "smb://nas.local/家庭共享/电影 %231%3F/100%25/%252F")
        #expect(try SMBFolderAddress(display) == folder)
    }

    @Test func customPortAndIPv6() throws {
        let folder = try SMBFolderAddress("smb://[::1]:1445/Shared/Movies")
        #expect(folder.serverAddress == "smb://[::1]:1445")
        #expect(folder.port == 1445)
        #expect(folder.rootPath == "/Movies")
    }

    @Test(arguments: [
        "", "smb://nas.local", "smb://nas.local/", "https://nas.local/Shared",
        "smb://user:secret@nas.local/Shared", "smb://user@nas.local/Shared",
        "smb://nas.local:0/Shared", "smb://nas.local:65536/Shared",
        "smb://nas.local/Shared?token=secret", "smb://nas.local/Shared#fragment",
        "smb://nas.local/Shared/../Movies", "smb://nas.local/Shared/%2e%2e/Movies",
        "smb://nas.local/Share%2FMovies", "smb://nas.local/Shared/%5CMovies",
        "smb://nas.local/Shared/%00", "smb://nas.local/./Movies"
    ])
    func rejectsIncompleteOrAmbiguousAddresses(_ address: String) {
        #expect(throws: FileServiceError.self) { try SMBFolderAddress(address) }
    }

    @Test func editingLegacyConfigurationsPreservesIdentity() throws {
        for explicitPort in [nil, 445, 1445] as [Int?] {
            for addressPort in [nil, 1445] as [Int?] {
                let address = "smb://nas.local" + (addressPort.map { ":\($0)" } ?? "")
                let original = try FileServiceConfiguration(name: "NAS", kind: .smb, address: address,
                    port: explicitPort, rootPath: "/电影/4K 原盘", share: "家庭共享", domain: "WORKGROUP", guest: true).validated()
                let edited = try SMBFolderAddress(SMBFolderAddress.formatted(original)).applying(to: original).validated()
                #expect(edited == original)
                #expect(edited.endpointIdentity == original.endpointIdentity)
            }
        }
        let root = FileServiceConfiguration(name: "NAS", kind: .smb, address: "smb://nas.local:445", share: "家庭共享")
        #expect(SMBFolderAddress.formatted(root) == "smb://nas.local/家庭共享")
    }

    @Test func pastedAddressReplacesOldShareRootAndPort() throws {
        let original = FileServiceConfiguration(name: "NAS", kind: .smb, address: "smb://old.local", port: 1445,
            rootPath: "/old", share: "Old", domain: "WORKGROUP", guest: true)
        let updated = try SMBFolderAddress("smb://new.local:2445/New/Movies").applying(to: original).validated()
        #expect(updated.address == "smb://new.local:2445")
        #expect(updated.port == nil)
        #expect(updated.share == "New")
        #expect(updated.rootPath == "/Movies")
        #expect(updated.id == original.id)
        #expect(updated.domain == original.domain)
        #expect(updated.guest == original.guest)
        #expect(try SMBFolderAddress("smb://new.local/New").applying(to: original).validated().address == "smb://new.local:445")
    }
}
