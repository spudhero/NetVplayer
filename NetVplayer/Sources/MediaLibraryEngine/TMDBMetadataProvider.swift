import Foundation
import Models

public struct TMDBMetadataProvider: MetadataProvider {
    public let source = MetadataSource.tmdb
    private let credential: TMDBCredential
    private let transport: MetadataTransport
    public init(credential: TMDBCredential, request: MetadataRequest? = nil) {
        self.credential = credential; self.transport = MetadataTransport(request: request)
    }
    private func get(_ path: String, params: [String: String] = [:]) async throws -> [String: Any] {
        guard credential.isValid else { throw MetadataProviderError.unavailable("此构建未配置 TMDB 应用凭据") }
        var url = URLComponents(string: "https://api.themoviedb.org/3/" + path)!
        var query = params; query["language"] = "zh-CN"
        var headers: [String: String] = [:]
        if credential.kind == .apiKey { query["api_key"] = credential.value }
        else { headers["Authorization"] = "Bearer " + credential.value }
        url.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        let (data, response) = try await transport.data(url: url.url!, headers: headers)
        guard response.url?.host == "api.themoviedb.org", response.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MetadataProviderError.invalidResponse }
        return object
    }
    public func search(title: String, year: Int?, kind: MediaLibraryKind) async throws -> [MetadataCandidate] {
        let type = kind == .television ? "tv" : "movie"
        var params = ["query": title]
        if let year { params[kind == .television ? "first_air_date_year" : "year"] = String(year) }
        let object = try await get("search/" + type, params: params)
        let candidates: [MetadataCandidate] = (object["results"] as? [[String: Any]] ?? []).prefix(20).map { .init(source: .tmdb, metadata: map($0, kind: kind)) }
        let normalized = MediaFilenameParser.normalizedTitle(title)
        let eligible = candidates.filter { year == nil || $0.metadata.year == year }
        // Primary-title hits already establish either a unique match or a remake ambiguity.
        if eligible.contains(where: { candidate in
            [candidate.metadata.title, candidate.metadata.originalTitle].compactMap { $0 }
                .contains { MediaFilenameParser.normalizedTitle($0) == normalized }
        }) { return candidates }
        var enriched = candidates
        do {
            for i in enriched.indices where year == nil || enriched[i].metadata.year == year {
                guard let id = enriched[i].metadata.tmdbID else { continue }
                let aliases = try await get(type + "/" + id + "/alternative_titles")
                let titles = aliases[kind == .television ? "results" : "titles"] as? [[String: Any]] ?? []
                enriched[i].metadata.alternativeTitles = titles.compactMap { $0["title"] as? String }
            }
            return enriched
        } catch is CancellationError { throw CancellationError() }
        catch {
            // Partial alias coverage cannot establish uniqueness; retain the original suggestions.
            return candidates
        }
    }
    public func details(id: String, kind: MediaLibraryKind) async throws -> MediaMetadata {
        guard id.allSatisfy(\.isNumber), !id.isEmpty, id.count <= 12 else { throw MetadataProviderError.invalidResponse }
        return try map(await get((kind == .television ? "tv/" : "movie/") + id), kind: kind)
    }
    private func map(_ object: [String: Any], kind: MediaLibraryKind) -> MediaMetadata {
        let title = object["title"] as? String ?? object["name"] as? String
        let date = object["release_date"] as? String ?? object["first_air_date"] as? String ?? ""
        let originalTitle = object["original_title"] as? String ?? object["original_name"] as? String
        return .init(title: title, originalTitle: originalTitle, year: Int(date.prefix(4)), kind: kind, showTitle: kind == .television ? title : nil,
                     plot: (object["overview"] as? String).flatMap { $0.isEmpty ? nil : $0 }, poster: image(object["poster_path"]), fanart: image(object["backdrop_path"]),
                     tmdbID: (object["id"] as? NSNumber)?.stringValue, tmdbRating: (object["vote_average"] as? NSNumber)?.doubleValue)
    }
    private func image(_ value: Any?) -> String? {
        guard let path = value as? String, path.hasPrefix("/"), !path.contains("..") else { return nil }
        return "https://image.tmdb.org/t/p/w500" + path
    }
}
