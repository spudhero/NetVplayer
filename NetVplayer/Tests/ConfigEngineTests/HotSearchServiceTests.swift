import Foundation
import Networking
import Testing
@testable import NetVplayerApp

@Test func hotSearchServiceDecodesTitleAndNameWithoutInventingMetadata() throws {
    let data = Data(
        #"{"data":[{"title":" 沙丘2 "},{"name":"庆余年 第二季"},{"title":"沙丘2"},{"title":"  "}]}"#.utf8
    )

    let items = try HotSearchService.decodeItems(from: data)

    #expect(items.map(\.title) == ["沙丘2", "庆余年 第二季"])
}

@Test func hotSearchServiceReadsCachedRawRankingBeforeNetworkRefresh() {
    let suiteName = "HotSearchServiceTests.cache.\(UUID().uuidString)"
    let storageKey = "hot"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    defaults.set(
        Data(#"{"data":[{"title":"缓存热词"}]}"#.utf8),
        forKey: storageKey
    )
    let service = HotSearchService(
        defaults: defaults,
        storageKey: storageKey,
        responseLoader: { HTTPResponse(data: Data(), statusCode: 200) }
    )

    #expect(service.cachedItems().map(\.title) == ["缓存热词"])
}

@Test func hotSearchServiceRefreshesAndCachesRawRanking() async throws {
    let suiteName = "HotSearchServiceTests.refresh.\(UUID().uuidString)"
    let storageKey = "hot"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let responseData = Data(
        #"{"data":[{"title":"实时热词一"},{"name":"实时热词二"}]}"#.utf8
    )
    let service = HotSearchService(
        defaults: defaults,
        storageKey: storageKey,
        responseLoader: { HTTPResponse(data: responseData, statusCode: 200) }
    )

    let refreshedItems = try await service.refresh()

    #expect(refreshedItems.map(\.title) == ["实时热词一", "实时热词二"])
    #expect(defaults.data(forKey: storageKey) == responseData)
    #expect(service.cachedItems() == refreshedItems)
}
