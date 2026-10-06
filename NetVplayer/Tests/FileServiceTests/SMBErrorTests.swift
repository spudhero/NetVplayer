import Foundation
import Testing
import Models
@testable import FileServiceEngine

@Suite("SMB error presentation")
struct SMBErrorTests {
    @Test(arguments: [EACCES, EPERM])
    func accessDeniedDependsOnConnectionStage(_ code: Int32) {
        let error = NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        let connecting = SMBClient.translate(error, path: "Shared", connecting: true) as? FileServiceError
        #expect(connecting == .protocolFailure(L10n.text("无法访问共享文件夹，请检查完整地址、账号密码，以及该账号是否有访问权限。")))
        #expect(SMBClient.translate(error, path: "/Movies") as? FileServiceError == .permission("/Movies"))
    }

    @Test func missingPathsAndOtherErrorDomains() {
        #expect(SMBClient.translate(POSIXError(.ENOENT), path: "/Movies") as? FileServiceError == .path("/Movies"))
        let other = NSError(domain: "TestError", code: Int(EACCES), userInfo: [NSLocalizedDescriptionKey: "fixture"])
        #expect(SMBClient.translate(other, path: "/Movies") as? FileServiceError == .network("fixture"))
        #expect(SMBClient.translate(FileServiceError.path("invalid"), path: "/") as? FileServiceError == .path("invalid"))
        #expect(SMBClient.translate(CancellationError(), path: "/") is CancellationError)
    }
}
