import Foundation
import Combine
import Models
import SubtitleEngine

struct SubtitlePlaybackOwner: Equatable, Sendable {
    let media: String
    let generation: String
    init(_ spec: PlaySpec) {
        media = SubtitleMediaIdentity.key(for: spec) ?? spec.url
        generation = spec.metadata["playback.sessionGeneration"] ?? spec.metadata["live.sessionID"] ?? ""
    }
}

@MainActor
final class OnlineSubtitleSearchModel: ObservableObject {
    @Published var results: [OnlineSubtitleResult] = []
    @Published var files: [OnlineSubtitleFile] = []
    @Published var downloads: [DownloadedSubtitle] = []
    @Published var isLoading = false
    @Published var hasMore = false
    @Published var errorMessage: String?
    private(set) var language = ""
    private var owner: SubtitlePlaybackOwner?
    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?
    private var query = ""
    private var offset = 0
    private let service: any OnlineSubtitleService

    init(service: any OnlineSubtitleService = ASSRTSubtitleService()) { self.service = service }

    func bind(to owner: SubtitlePlaybackOwner?) {
        guard self.owner != owner else { return }
        cancel()
        self.owner = owner
        results = []; files = []; downloads = []; hasMore = false
    }

    func cancel() {
        generation &+= 1
        task?.cancel(); task = nil; isLoading = false; errorMessage = nil
    }

    func search(query: String, token: String, more: Bool = false) {
        guard owner != nil, !more || hasMore, !isLoading else { return }
        if !more { self.query = query; offset = 0; results = []; files = []; downloads = [] }
        let query = self.query, offset = self.offset, service = service
        begin { try await service.search(query: query, offset: offset, token: token) } apply: { page in
            let existing = Set(self.results.map(\.id))
            self.results.append(contentsOf: page.results.filter { !existing.contains($0.id) })
            self.offset = offset + ASSRTSubtitleService.pageSize
            self.hasMore = page.hasMore
        }
    }

    func details(_ result: OnlineSubtitleResult, token: String) {
        files = []; downloads = []
        let service = service
        begin { try await service.files(id: result.id, token: token) } apply: { self.files = $0 }
    }

    func download(_ file: OnlineSubtitleFile) {
        downloads = []; language = file.language
        let service = service
        begin { try await service.download(file) } apply: { self.downloads = $0 }
    }

    func owns(_ spec: PlaySpec?) -> Bool { spec.map(SubtitlePlaybackOwner.init) == owner && owner != nil }

    private func begin<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T,
                                     apply: @escaping @MainActor (T) -> Void) {
        cancel()
        guard let owner else { return }
        let generation = generation
        isLoading = true
        task = Task { [weak self] in
            do {
                let value = try await operation()
                try Task.checkCancellation()
                guard let self, self.owner == owner, self.generation == generation else { return }
                apply(value)
                self.isLoading = false; self.task = nil
            } catch {
                guard let self, self.owner == owner, self.generation == generation, !Task.isCancelled else { return }
                self.errorMessage = (error as? OnlineSubtitleError)?.errorDescription ?? L10n.text("字幕请求失败，请重试。")
                self.isLoading = false; self.task = nil
            }
        }
    }
}
