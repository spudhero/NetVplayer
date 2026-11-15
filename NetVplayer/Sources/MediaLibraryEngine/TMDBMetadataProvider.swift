import Foundation
import Models

public struct TMDBMetadataProvider: MetadataProvider {
    public let source = MetadataSource.tmdb
    private let credential: TMDBCredential
    private let transport: MetadataTransport
    private let aliasPolicy: TMDBAliasPolicy
    public init(credential: TMDBCredential, request: MetadataRequest? = nil, aliasPolicy: TMDBAliasPolicy = .init()) {
        self.credential = credential; self.transport = MetadataTransport(request: request); self.aliasPolicy = aliasPolicy
    }
    private func get(_ path: String, params: [String: String] = [:], aliasRequest: Bool = false) async throws -> [String: Any] {
        guard credential.isValid else { throw MetadataProviderError.authentication }
        var url = URLComponents(string: "https://api.themoviedb.org/3/" + path)!
        var query = params; query["language"] = "zh-CN"
        var headers: [String: String] = [:]
        if credential.kind == .apiKey { query["api_key"] = credential.value }
        else { headers["Authorization"] = "Bearer " + credential.value }
        url.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        let (data, response) = try await transport.data(url: url.url!, headers: headers,
            timeout: aliasRequest ? aliasPolicy.requestTimeout : .seconds(20))
        guard response.url?.host == "api.themoviedb.org" else { throw MetadataProviderError.invalidResponse }
        try MetadataTransport.checkStatus(response)
        guard
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MetadataProviderError.invalidResponse }
        return object
    }
    public func search(title: String, year: Int?, kind: MediaLibraryKind) async throws -> [MetadataCandidate] {
        try await searchResult(title: title, year: year, kind: kind).candidates
    }
    public func searchResult(title: String, year: Int?, kind: MediaLibraryKind) async throws -> MetadataSearchResult {
        let type = kind == .television ? "tv" : "movie"
        var params = ["query": title]
        if let year { params[kind == .television ? "first_air_date_year" : "year"] = String(year) }
        let object = try await get("search/" + type, params: params)
        guard let results = object["results"] as? [[String: Any]] else { throw MetadataProviderError.invalidResponse }
        let candidates: [MetadataCandidate] = results.prefix(20).map { .init(source: .tmdb, metadata: map($0, kind: kind)) }
        let normalized = MediaFilenameParser.normalizedTitle(title)
        let eligible = candidates.filter { year == nil || $0.metadata.year == year }
        // Primary-title hits already establish either a unique match or a remake ambiguity.
        if eligible.contains(where: { candidate in
            [candidate.metadata.title, candidate.metadata.originalTitle].compactMap { $0 }
                .contains { MediaFilenameParser.normalizedTitle($0) == normalized }
        }) { return .init(candidates: candidates) }
        // Query each distinct eligible identity once, retaining original candidate order.
        let ids = Array(Set(eligible.compactMap { $0.metadata.tmdbID })).sorted()
        guard eligible.allSatisfy({ candidate in
            guard let id = candidate.metadata.tmdbID else { return false }
            return !id.isEmpty && id.count <= 12 && id.allSatisfy(\.isNumber)
        }) else { return .init(candidates: candidates, issue: MetadataProviderError.invalidResponse) }
        do {
            let aliases = try await withThrowingTaskGroup(of: [String: [String]].self) { group in
                group.addTask { try await aliasCoverage(ids: ids, type: type, kind: kind) }
                group.addTask { try await Task.sleep(for: aliasPolicy.totalTimeout); throw URLError(.timedOut) }
                defer { group.cancelAll() }
                return try await group.next()!
            }
            try Task.checkCancellation()
            var enriched = candidates
            for i in enriched.indices {
                if let id = enriched[i].metadata.tmdbID, let titles = aliases[id] { enriched[i].metadata.alternativeTitles = titles }
            }
            return .init(candidates: enriched)
        } catch {
            try Task.checkCancellation()
            // No partial aliases escape: incomplete coverage cannot prove uniqueness.
            return .init(candidates: candidates, issue: error)
        }
    }
    private func aliasCoverage(ids: [String], type: String, kind: MediaLibraryKind) async throws -> [String: [String]] {
        let retries = TMDBAliasRetries(aliasPolicy.retryBudget)
        return try await withThrowingTaskGroup(of: (String, [String]).self) { group in
            var cursor = 0
            func submit(_ id: String) {
                group.addTask { (id, try await aliasTitles(id: id, type: type, kind: kind, retries: retries)) }
            }
            while cursor < min(aliasPolicy.concurrency, ids.count) { submit(ids[cursor]); cursor += 1 }
            var result: [String: [String]] = [:]
            while let (id, titles) = try await group.next() {
                result[id] = titles
                if cursor < ids.count { submit(ids[cursor]); cursor += 1 }
            }
            return result
        }
    }
    private func aliasTitles(id: String, type: String, kind: MediaLibraryKind, retries: TMDBAliasRetries) async throws -> [String] {
        for attempt in 0...1 {
            try Task.checkCancellation()
            try await TMDBAliasLimiter.shared.acquire()
            do {
                try Task.checkCancellation()
                let aliases = try await get(type + "/" + id + "/alternative_titles", aliasRequest: true)
                guard let titles = aliases[kind == .television ? "results" : "titles"] as? [[String: Any]],
                      titles.allSatisfy({ $0["title"] is String }) else { throw MetadataProviderError.invalidResponse }
                await TMDBAliasLimiter.shared.release()
                return titles.compactMap { $0["title"] as? String }
            } catch {
                await TMDBAliasLimiter.shared.release()
                try Task.checkCancellation()
                let transient = (error as? MetadataProviderError).map {
                    if case .serviceUnavailable = $0 { return true }; return false
                } == true || (error as? URLError).map {
                    [.timedOut, .networkConnectionLost, .cannotConnectToHost].contains($0.code)
                } == true
                guard attempt == 0, transient, await retries.take() else { throw error }
                try await Task.sleep(for: aliasPolicy.retryDelay)
            }
        }
        throw MetadataProviderError.invalidResponse
    }
    public func details(id: String, kind: MediaLibraryKind) async throws -> MediaMetadata {
        guard id.allSatisfy(\.isNumber), !id.isEmpty, id.count <= 12 else { throw MetadataProviderError.invalidResponse }
        let object = try await get((kind == .television ? "tv/" : "movie/") + id, params: ["append_to_response": "credits"])
        var metadata = map(object, kind: kind)
        guard metadata.title?.isEmpty == false, metadata.tmdbID == id else { throw MetadataProviderError.invalidResponse }
        metadata.detailVersion = 2
        return metadata
    }
    private func map(_ object: [String: Any], kind: MediaLibraryKind) -> MediaMetadata {
        let title = object["title"] as? String ?? object["name"] as? String
        let date = object["release_date"] as? String ?? object["first_air_date"] as? String ?? ""
        let originalTitle = object["original_title"] as? String ?? object["original_name"] as? String
        let credits = object["credits"] as? [String: Any] ?? [:]
        let crew = credits["crew"] as? [[String: Any]] ?? []
        let runtime = object["runtime"] as? Int ?? (object["episode_run_time"] as? [Int])?.first
        let cast = (credits["cast"] as? [[String: Any]])?.prefix(40).compactMap { person -> MediaCastMember? in
            guard let name = nonempty(person["name"] as? String) else { return nil }
            return .init(name: name, role: nonempty(person["character"] as? String), portrait: image(person["profile_path"], size: "w185"),
                         tmdbID: (person["id"] as? NSNumber)?.stringValue)
        }
        let collection = (object["belongs_to_collection"] as? [String: Any]).flatMap { item -> MediaCollection? in
            guard kind != .television, let name = nonempty(item["name"] as? String) else { return nil }
            return .init(name: name, tmdbID: (item["id"] as? NSNumber)?.stringValue)
        }
        return .init(title: title, originalTitle: originalTitle, year: Int(date.prefix(4)), kind: kind, showTitle: kind == .television ? title : nil,
                     plot: nonempty(object["overview"] as? String), poster: image(object["poster_path"]), fanart: image(object["backdrop_path"], size: "w1280"),
                     tmdbID: (object["id"] as? NSNumber)?.stringValue, tmdbRating: (object["vote_average"] as? NSNumber)?.doubleValue,
                     genres: names(object["genres"]), runtimeMinutes: runtime.flatMap { $0 > 0 ? $0 : nil }, releaseDate: nonempty(date),
                     countries: names(object["production_countries"]), languages: names(object["spoken_languages"]),
                     studios: names(object["production_companies"]), tagline: nonempty(object["tagline"] as? String),
                     directors: names(crew.filter { $0["job"] as? String == "Director" }),
                     writers: names(crew.filter { ["Writer", "Screenplay", "Story"].contains($0["job"] as? String ?? "") }), cast: cast, collection: collection)
    }
    private func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
    private func names(_ value: Any?) -> [String]? {
        guard let items = value as? [[String: Any]] else { return nil }
        var seen = Set<String>()
        let names = items.prefix(80).compactMap { nonempty($0["name"] as? String) }.filter { seen.insert($0).inserted }
        return names.isEmpty ? nil : names
    }
    private func image(_ value: Any?, size: String = "w500") -> String? {
        guard let path = value as? String, path.hasPrefix("/"), !path.contains("..") else { return nil }
        return "https://image.tmdb.org/t/p/" + size + path
    }
}
