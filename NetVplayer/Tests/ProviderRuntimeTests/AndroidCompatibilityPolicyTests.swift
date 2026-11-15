import Foundation
import Testing
@testable import SpiderEngine

@Test func androidBundledCompatibilityResourceIsAvailableAndRejectsChangedBytes() {
    #expect(AndroidCompatibilityPolicy.bundled != nil)
    #expect(AndroidCompatibilityPolicy.decodeBundled(Data("changed metadata".utf8)) == nil)
}

@Test func androidCompatibilityPolicyScopesCloudPresentationWithoutChangingInputs() throws {
    let policy = try JSONDecoder().decode(AndroidCompatibilityPolicy.self, from: Data(#"""
    {"cloud":[{"classes":["com.github.catvod.spider.Fixture"],
      "shareHosts":{"share.example.test":"ali"},
      "playerFlags":{"fixture-drive":{"drive":"ali","fileKey":"opaque_file"}}}],"media":[]}
    """#.utf8))
    func drive(_ operation: String, _ id: String, className: String = "com.github.catvod.spider.Fixture") -> String? {
        policy.cloudDrive(api: "csp_Fixture", className: className, operation: operation, id: id)
    }
    #expect(drive("detail", "https://share.example.test/s/opaque") == "ali")
    #expect(drive("detail", "https://other.example.test/s/opaque") == nil)
    #expect(drive("detail", "https://user:password@share.example.test/s/opaque") == nil)
    #expect(drive("detail", "https://share.example.test/s/opaque", className: "com.github.catvod.spider.Other") == nil)
    #expect(drive("player", #"{"flag":"fixture-drive","opaque_file":"original","extra":"preserve"}"#) == "ali")
    #expect(drive("player", #"{"flag":"fixture-drive","opaque_file":""}"#) == nil)
    #expect(drive("proxy", #"{"flag":"fixture-drive","opaque_file":"original"}"#) == nil)
}

@Test func androidNativePlaybackRulesRejectMalformedIDsAndKeepLegacyCompatibility() throws {
    let rule = try JSONDecoder().decode(AndroidCompatibilityPolicy.NativePlaybackRule.self, from: Data(#"""
    {"key":"fixture","api":"csp_Fixture","className":"fixture.Class","flag":"fixture-line",
     "legacyPrefix":"fixture:","idSeparator":"/","idPartCount":2,"idMaxDigits":4,
     "providerID":"fixture.provider","minimumVersion":"1.0.0","accountDrives":["uc"]}
    """#.utf8))
    #expect(rule.accepts(flag: "fixture-line", id: "12/345"))
    #expect(rule.accepts(flag: "fixture-line", id: "fixture:123"))
    for id in ["12/", "/12", "12/3/4", "12345/1", "12/a", "fixture:", "１２/3", "12/3\n"] {
        #expect(!rule.accepts(flag: "fixture-line", id: id))
    }
    #expect(!rule.accepts(flag: "other", id: "12/345"))
}
