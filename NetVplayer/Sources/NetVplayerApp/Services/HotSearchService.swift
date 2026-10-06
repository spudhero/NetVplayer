import Foundation
import Networking

struct HotSearchItem: Hashable, Identifiable, Sendable {
    let title: String

    var id: String { title.lowercased() }
}

enum HotSearchServiceError: Error, Equatable {
    case invalidStatusCode(Int)
    case emptyRanking
}

final class HotSearchService: @unchecked Sendable {
    static let shared = HotSearchService()

    private static let endpoint = "https://api.web.360kan.com/v1/rank?cat=1"
    private static let referer = "https://www.360kan.com/rank/general"

    private let defaults: UserDefaults
    private let storageKey: String
    private let responseLoader: @Sendable () async throws -> HTTPResponse
    private let lock = NSLock()

    init(
        client: HTTPClient = .shared,
        defaults: UserDefaults = .standard,
        storageKey: String = "netvplayer.hotSearch.v1"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.responseLoader = {
            try await client.get(
                url: Self.endpoint,
                headers: ["Referer": Self.referer],
                timeout: 10
            )
        }
    }

    init(
        defaults: UserDefaults,
        storageKey: String,
        responseLoader: @escaping @Sendable () async throws -> HTTPResponse
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.responseLoader = responseLoader
    }

    func cachedItems() -> [HotSearchItem] {
        lock.lock()
        let data = defaults.data(forKey: storageKey)
        lock.unlock()

        guard let data else { return [] }
        return (try? Self.decodeItems(from: data)) ?? []
    }

    func refresh() async throws -> [HotSearchItem] {
        let response = try await responseLoader()
        guard (200..<300).contains(response.statusCode) else {
            throw HotSearchServiceError.invalidStatusCode(response.statusCode)
        }

        let items = try Self.decodeItems(from: response.data)
        guard !items.isEmpty else {
            throw HotSearchServiceError.emptyRanking
        }

        save(response.data)
        return items
    }

    static func decodeItems(from data: Data) throws -> [HotSearchItem] {
        let response = try JSONDecoder().decode(RankingResponse.self, from: data)
        var seen = Set<String>()

        return response.data.compactMap { payload in
            let title = (payload.title ?? payload.name ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }

            let identity = title.lowercased()
            guard seen.insert(identity).inserted else { return nil }
            return HotSearchItem(title: title)
        }
    }

    private func save(_ data: Data) {
        lock.lock()
        defaults.set(data, forKey: storageKey)
        lock.unlock()
    }
}

private struct RankingResponse: Decodable {
    let data: [RankingItem]
}

private struct RankingItem: Decodable {
    let title: String?
    let name: String?
}
