import Foundation
import Combine
import Models
import MediaLibraryEngine

struct OnlineVodDetailIdentity: Hashable {
    let sourceFingerprint: String
    let siteKey: String
    let vodID: String
}

struct OnlineVodDetailInput: Hashable {
    let identity: OnlineVodDetailIdentity
    var title: String
    let year: Int?
    let kind: MediaLibraryKind?

    init?(vod: Vod, sourceFingerprint: String, siteKey: String) {
        guard !sourceFingerprint.isEmpty, !siteKey.isEmpty, !vod.vodId.isEmpty,
              vod.siteKey.isEmpty || vod.siteKey == siteKey,
              FileResourceReference(locator: vod.vodId) == nil,
              MediaServerReference(locator: vod.vodId) == nil else { return nil }
        identity = .init(sourceFingerprint: sourceFingerprint, siteKey: siteKey, vodID: vod.vodId)
        title = vod.vodName.trimmingCharacters(in: .whitespacesAndNewlines)
        year = Int(vod.vodYear.trimmingCharacters(in: .whitespacesAndNewlines))
        // Genres (animation, documentary, etc.) do not establish a movie/TV namespace.
        switch vod.typeName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "电影", "movie", "movies": kind = .movies
        case "电视剧", "剧集", "tv", "television": kind = .television
        default: kind = nil
        }
    }
}

/// Owns only display metadata. It cannot mutate source episodes, playback or history.
@MainActor final class OnlineVodDetailModel: ObservableObject {
    @Published private(set) var input: OnlineVodDetailInput?
    @Published private(set) var binding: MetadataCandidate?
    @Published private(set) var metadata: MediaMetadata?
    @Published private(set) var candidates: [MetadataCandidate] = []
    @Published private(set) var isLoading = false
    @Published private(set) var issue: String?
    @Published private(set) var wantsEnhanced = false
    @Published private(set) var hasSearched = false
    private let matcher: MetadataMatcher
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var active = false
    private var visibilityOwner: UUID?
    private var searchTitleOverride: String?

    init(matcher: MetadataMatcher = .shared) { self.matcher = matcher }
    var displayedMetadata: MediaMetadata? { wantsEnhanced ? metadata : nil }

    func receive(_ newInput: OnlineVodDetailInput?) {
        guard input != newInput else { return }
        let sameIdentity = input?.identity == newInput?.identity && newInput != nil
        input = newInput
        // Source completion can rename the title or add year/category/episodes.
        // A confirmed/unique work remains bound until its source identity changes or the user rematches.
        if sameIdentity, binding != nil || searchTitleOverride != nil { return }
        cancelRequest()
        binding = nil; metadata = nil; candidates = []; issue = nil; hasSearched = false
        if !sameIdentity { wantsEnhanced = false; searchTitleOverride = nil }
        if active, wantsEnhanced { startSearch(refresh: false) }
    }

    func resume(owner: UUID? = nil) {
        if let owner { visibilityOwner = owner }
        active = true
        guard wantsEnhanced, task == nil else { return }
        if let binding, metadata?.detailVersion == nil { loadDetails(binding, refresh: false) }
        else if !hasSearched { startSearch(refresh: false) }
    }
    func suspend(owner: UUID? = nil) {
        guard owner == nil || visibilityOwner == owner else { return }
        visibilityOwner = nil; active = false; cancelRequest()
    }
    func showOriginal() { wantsEnhanced = false; cancelRequest() }
    func showEnhanced() { wantsEnhanced = true; resume() }
    func retry() {
        guard wantsEnhanced else { return }
        if let binding { loadDetails(binding, refresh: true) }
        else { startSearch(refresh: true) }
    }
    func search(title: String) {
        guard input != nil else { return }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.utf8.count <= 512 else { return }
        searchTitleOverride = title
        cancelRequest()
        binding = nil; metadata = nil; candidates = []; hasSearched = false
        wantsEnhanced = true
        startSearch(refresh: true)
    }
    func confirm(_ candidate: MetadataCandidate) {
        guard candidates.contains(candidate), MetadataMatcher.onlineCandidateKey(candidate) != nil else { return }
        loadDetails(candidate, refresh: false)
    }

    private func cancelRequest() {
        generation = UUID(); task?.cancel(); task = nil; isLoading = false
    }
    private func startSearch(refresh: Bool) {
        guard active, wantsEnhanced, var input else { return }
        input.title = searchTitleOverride ?? input.title
        guard !input.title.isEmpty, input.title.utf8.count <= 512 else { return }
        cancelRequest()
        let request = generation
        isLoading = true; issue = nil
        task = Task { [weak self, matcher] in
            do {
                let result = try await matcher.searchOnline(title: input.title, year: input.year, kind: input.kind, refresh: refresh)
                guard let self, self.generation == request, !Task.isCancelled else { return }
                self.candidates = result.candidates
                self.hasSearched = true; self.isLoading = false; self.task = nil
                self.issue = result.issue?.localizedDescription
                // Use the established exact-title/year policy, then require uniqueness across kinds too.
                let matches = result.candidates.filter { candidate in
                    guard let kind = candidate.metadata.kind else { return false }
                    return MetadataMatcher.uniqueMatch(candidates: [candidate], title: input.title, year: input.year, kind: kind) != nil
                }
                if result.issue == nil, matches.count == 1 {
                    self.loadDetails(matches[0], refresh: false)
                }
            } catch {
                guard let self, self.generation == request, !Task.isCancelled else { return }
                self.issue = error.localizedDescription; self.hasSearched = true
                self.isLoading = false; self.task = nil
            }
        }
    }
    private func loadDetails(_ candidate: MetadataCandidate, refresh: Bool) {
        guard active, wantsEnhanced, input != nil else { return }
        cancelRequest()
        let request = generation
        if binding != candidate { metadata = candidate.metadata }
        binding = candidate; isLoading = true; issue = nil
        task = Task { [weak self, matcher] in
            do {
                let value = try await matcher.onlineDetails(candidate: candidate, refresh: refresh)
                guard let self, self.generation == request, !Task.isCancelled else { return }
                self.metadata = value; self.isLoading = false; self.task = nil
            } catch {
                guard let self, self.generation == request, !Task.isCancelled else { return }
                self.issue = error.localizedDescription; self.isLoading = false; self.task = nil
            }
        }
    }
}
