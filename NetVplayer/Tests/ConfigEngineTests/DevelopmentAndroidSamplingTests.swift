#if DEBUG
import Foundation
import Testing
@testable import NetVplayerApp

@Test func auditSamplingIsReproducibleUniqueAndPreservesOpaqueIDs() {
    let ids = (0..<30).map { "{\"folder\":\($0),\"text\":\"a+b/%20\"}" }
    let first = DevelopmentAndroidSampling.indices(ids: ids, seed: "campaign-fixture", scope: "source:category", offset: 0, count: 3)
    #expect(first.count == 3)
    #expect(Set(first).count == 3)
    #expect(first.allSatisfy(ids.indices.contains))
    #expect(first == DevelopmentAndroidSampling.indices(ids: ids, seed: "campaign-fixture", scope: "source:category", offset: 0, count: 3))
    let reversed = Array(ids.reversed())
    let reordered = DevelopmentAndroidSampling.indices(ids: reversed, seed: "campaign-fixture", scope: "source:category", offset: 0, count: 3)
    #expect(first.map { ids[$0] } == reordered.map { reversed[$0] })
}

@Test func auditSamplingUsesDifferentScopesAndCanResumeWithoutOverlap() {
    let ids = (0..<50).map(String.init)
    let first = DevelopmentAndroidSampling.indices(ids: ids, seed: "fixture", scope: "one", offset: 0, count: 3)
    let next = DevelopmentAndroidSampling.indices(ids: ids, seed: "fixture", scope: "one", offset: 3, count: 3)
    let other = DevelopmentAndroidSampling.indices(ids: ids, seed: "fixture", scope: "two", offset: 0, count: 3)
    #expect(Set(first).isDisjoint(with: next))
    #expect(first != other)
}

@Test func auditSamplingDoesNotRepeatTheSameCatalogueIdentity() {
    let ids = ["one", "one", "two", "three", "two"]
    let selected = DevelopmentAndroidSampling.indices(ids: ids, seed: "fixture", scope: "category", offset: 0, count: 3)
    #expect(Set(selected.map { ids[$0] }) == Set(["one", "two", "three"]))
    #expect(selected.count == 3)
    #expect(DevelopmentAndroidSampling.indices(ids: [], seed: "fixture", scope: "category", offset: 0, count: 3).isEmpty)
    #expect(DevelopmentAndroidSampling.indices(ids: ["one"], seed: "fixture", scope: "category", offset: 0, count: 3) == [0])
}

@Test func auditSamplingRetainsLegacyOrderWithoutASeedAndBoundsSelection() {
    let ids = (0..<10).map(String.init)
    #expect(DevelopmentAndroidSampling.indices(ids: ids, seed: nil, scope: "", offset: 2, count: 3) == [2, 3, 4])
    #expect(DevelopmentAndroidSampling.indices(ids: ids, seed: nil, scope: "", offset: -10, count: 0) == [0])
    #expect(DevelopmentAndroidSampling.indices(ids: ids, seed: "x", scope: "", offset: 99, count: 999).isEmpty)
    #expect(DevelopmentAndroidSampling.indices(ids: ids, seed: "x", scope: "", offset: 0, count: 999).count == 3)
}

@Test func auditInventoryDistinguishesActionsFromMediaCategories() {
    #expect(DevelopmentAndroidSampling.categoryExclusion(id: "search", name: "搜索") == "search_action")
    #expect(DevelopmentAndroidSampling.categoryExclusion(id: "1", name: "本源是网盘搜索源，仅支持搜索") == "search_action")
    #expect(DevelopmentAndroidSampling.categoryExclusion(id: "peizhi", name: "设置") == "settings_action")
    #expect(DevelopmentAndroidSampling.categoryExclusion(id: "account", name: "网盘登录") == "authentication_action")
    #expect(DevelopmentAndroidSampling.categoryExclusion(id: "1", name: "电影") == nil)
    #expect(DevelopmentAndroidSampling.categoryExclusion(id: "2", name: "电视剧") == nil)
    #expect(DevelopmentAndroidSampling.categoryExclusion(id: "3", name: "搜索技巧课程") == nil)
}

@Test func auditPlaybackRequiresContinuousProgressWithoutBufferingOrSeekJumps() {
    var progress = DevelopmentAndroidSampling.PlaybackProgress()
    func observe(_ position: Double, playing: Bool = true, loading: Bool = false,
                 buffering: Bool = false, expected: Bool = false) {
        let actual = progress.observe(position: position, playing: playing, loading: loading, buffering: buffering)
        #expect(actual == expected)
    }
    for position in 0..<5 {
        observe(Double(position))
    }
    observe(5, buffering: true)
    for position in 10..<15 {
        observe(Double(position))
    }
    observe(40)
    observe(.infinity)
    for position in 0..<5 {
        observe(Double(position))
    }
    observe(5, expected: true)
    observe(6, playing: false)
    observe(7, loading: true)
}

@Test func fullPlaybackWindowDoesNotCountLoadingOrAnEarlierShortStreak() {
    var window = DevelopmentAndroidSampling.ContinuousPlaybackWindow(requiredSeconds: 45)
    for second in 0...6 {
        let observed1 = window.observe(time: Double(second), position: 0, playing: true, loading: true, buffering: false)
        #expect(!observed1)
    }
    for second in 7...45 {
        let observed2 = window.observe(time: Double(second), position: Double(second - 7), playing: true, loading: false, buffering: false)
        #expect(!observed2)
    }
    #expect(window.elapsedSeconds == 38)
    #expect(!window.complete)
    for second in 46...52 {
        let result = window.observe(time: Double(second), position: Double(second - 7), playing: true, loading: false, buffering: false)
        #expect(result == (second == 52))
    }
    #expect(window.elapsedSeconds == 45)
    #expect(window.advancedSeconds == 45)
}

@Test func fullPlaybackWindowResetsAfterBufferingAndPause() {
    var window = DevelopmentAndroidSampling.ContinuousPlaybackWindow(requiredSeconds: 45)
    for second in 0...30 { _ = window.observe(time: Double(second), position: Double(second), playing: true, loading: false, buffering: false) }
    let observed3 = window.observe(time: 31, position: 30, playing: true, loading: false, buffering: true)
    #expect(!observed3)
    for second in 32...76 {
        let observed4 = window.observe(time: Double(second), position: Double(second - 2), playing: true, loading: false, buffering: false)
        #expect(!observed4)
    }
    let observed5 = window.observe(time: 77, position: 75, playing: true, loading: false, buffering: false)
    #expect(observed5)
    let observed6 = window.observe(time: 78, position: 75, playing: false, loading: false, buffering: false)
    #expect(!observed6)
    #expect(!window.complete)
}

@Test func fullPlaybackWindowRejectsSeekSpeedStallGapAndMissingDecode() {
    for invalid in ["seek", "speed", "stall", "jump", "gap", "decoder", "identity", "nonfinite", "clock"] {
        var window = DevelopmentAndroidSampling.ContinuousPlaybackWindow(requiredSeconds: 45)
        for second in 0...44 { _ = window.observe(time: Double(second), position: Double(second), playing: true, loading: false, buffering: false) }
        let now: Double = invalid == "gap" ? 60 : (invalid == "clock" ? 44 : 45)
        let position: Double = invalid == "stall" ? 44 : (invalid == "jump" ? 100 : (invalid == "nonfinite" ? .infinity : 45))
        let observed7 = window.observe(time: now, position: position, playing: true, loading: false, buffering: false,
            seeking: invalid == "seek", speed: invalid == "speed" ? 2 : 1,
            decoded: invalid != "decoder", identityMatches: invalid != "identity")
        #expect(!observed7)
        #expect(!window.complete)
    }
}

@Test func fullPlaybackWindowRequiresBothWallAndMediaTime() {
    var window = DevelopmentAndroidSampling.ContinuousPlaybackWindow(requiredSeconds: 45)
    for second in 0...45 {
        let observed8 = window.observe(time: Double(second), position: Double(second) * 0.99, playing: true, loading: false, buffering: false)
        #expect(!observed8)
    }
    let observed9 = window.observe(time: 46, position: 45.54, playing: true, loading: false, buffering: false)
    #expect(observed9)
}
#endif
