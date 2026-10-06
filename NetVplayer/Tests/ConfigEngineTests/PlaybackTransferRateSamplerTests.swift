import Testing
@testable import PlayerEngine

@Test func playbackTransferSpeedUsesRecentDownloadsAndExpiresWhenIdle() {
    let mib: Int64 = 1_048_576
    var sampler = PlaybackTransferRateSampler(receivedBytes: 100 * mib, at: 0)
    let first = sampler.sample(receivedBytes: 102 * mib, at: 0.5)
    #expect(first.receivedBytes == 2 * mib)
    #expect(first.bytesPerSecond == 4 * mib)
    _ = sampler.sample(receivedBytes: 104 * mib, at: 1)
    _ = sampler.sample(receivedBytes: 104 * mib, at: 2)
    let idle = sampler.sample(receivedBytes: 104 * mib, at: 3)
    #expect(idle.receivedBytes == 4 * mib)
    #expect(idle.bytesPerSecond == 0)
    let resumed = sampler.sample(receivedBytes: 108 * mib, at: 3.5)
    #expect(resumed.bytesPerSecond > 0)
}

@Test func playbackTransferSpeedDoesNotReusePreviousSeekOrDivideByZero() {
    var sampler = PlaybackTransferRateSampler(receivedBytes: 500, at: 10)
    #expect(sampler.sample(receivedBytes: 500, at: 10).bytesPerSecond == 0)
    #expect(sampler.sample(receivedBytes: 500, at: 11).receivedBytes == 0)
    #expect(sampler.sample(receivedBytes: 400, at: 12).bytesPerSecond == 0)
}
