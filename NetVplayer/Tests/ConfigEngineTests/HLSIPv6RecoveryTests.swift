import Foundation
import Models
import PlayerEngine
import Testing
@testable import ProxyServer

@Test func testHLSIPv6RecoveryRejectsUnsafeAndUnrelatedEndpoints() throws {
    #expect(HLSIPv6Recovery.supports(try #require(URL(string: "https://hd.kuktxu.com/movie/index.m3u8"))))
    #expect(HLSIPv6Recovery.supports(try #require(URL(string: "https://hd.kuktxu.com/movie/key.key"))))
    for value in [
        "http://hd.kuktxu.com/a", "https://hd.kuktxu.com.evil.test/a",
        "https://hd.kuktxu.com:8443/a", "https://user:pass@hd.kuktxu.com/a",
        "https://127.0.0.1/a", "https://example.com/a"
    ] {
        #expect(!HLSIPv6Recovery.supports(try #require(URL(string: value))))
    }
    for address in ["::1", "::", "fc00::1", "fe80::1", "ff02::1", "::ffff:127.0.0.1", "2001:db8::1", "192.168.1.1", "2606:4700:4700::1111\n"] {
        #expect(!HLSIPv6Recovery.isPublicIPv6(address))
    }
    #expect(HLSIPv6Recovery.isPublicIPv6("2606:4700:4700::1111"))
}

@Test func testHLSIPv6RecoveryOnlyAcceptsSuccessfulPublicAAAAAnswers() {
    let data = Data(#"{"Status":0,"Answer":[{"type":5,"data":"alias.example"},{"type":1,"data":"1.1.1.1"},{"type":28,"data":"::1"},{"type":28,"data":"fc00::1"},{"type":28,"data":"2606:4700:4700::1111"},{"type":28,"data":"2606:4700:4700::1111"}]}"#.utf8)
    #expect(HLSIPv6Recovery.addresses(from: data) == ["2606:4700:4700::1111"])
    #expect(HLSIPv6Recovery.addresses(from: Data(#"{"Status":2,"Answer":[{"type":28,"data":"2606:4700:4700::1111"}]}"#.utf8)).isEmpty)
    #expect(HLSIPv6Recovery.addresses(from: Data("not DNS JSON".utf8)).isEmpty)
}

@Test func testPlaybackProxyPolicyRelaysKuktxuHLSAndKeepsOtherMediaDirect() {
    #expect(PlaybackProxyPolicy.shouldUseLocalHLSProxy(for: PlaySpec(url: "https://hd.kuktxu.com/movie/index.m3u8")))
    #expect(!PlaybackProxyPolicy.shouldUseLocalHLSProxy(for: PlaySpec(url: "https://hd.kuktxu.com/movie/video.mp4")))
    #expect(!PlaybackProxyPolicy.shouldUseLocalHLSProxy(for: PlaySpec(url: "https://hd.kuktxu.com.evil.test/movie/index.m3u8")))
}
