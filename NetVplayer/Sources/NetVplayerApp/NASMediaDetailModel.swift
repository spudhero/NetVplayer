import Foundation
import Combine
import Models
import Storage
import MediaLibraryEngine

/// Owns only NAS detail data. Playback and history remain owned by AppState.
@MainActor
final class NASMediaDetailModel: ObservableObject {
    @Published private(set) var record: MediaRecord?
    @Published private(set) var files: [MediaRecord] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var detailsUnavailable = false
    @Published private(set) var serviceName = ""
    @Published private(set) var libraryName = ""
    private let index: MediaIndex
    private let matcher: MetadataMatcher
    private let store: FileServiceStore
    private var generation = UUID()

    init(index: MediaIndex = .shared, matcher: MetadataMatcher = .shared, store: FileServiceStore = .shared) {
        self.index = index; self.matcher = matcher; self.store = store
    }

    func load(reference: FileResourceReference, enrich: Bool = true) async {
        let request = UUID(); generation = request
        isRefreshing = false
        detailsUnavailable = false
        let catalog = store.load()
        serviceName = catalog.services.first { $0.id == reference.serviceID }?.name ?? ""
        let library = catalog.libraries.first { $0.id == reference.libraryID }
        libraryName = library?.name ?? ""
        do {
            let cached = try await index.record(reference: reference)
            guard generation == request, !Task.isCancelled else { return }
            record = cached
            let group = try await cachedGroup(cached)
            guard generation == request, !Task.isCancelled else { return }
            files = group
            guard generation == request, !Task.isCancelled, enrich, let cached else { return }
            let source = library?.metadataSource ?? cached.metadataSource ?? .local
            let version = cached.metadata.tmdbID == nil ? 1 : 2
            guard source != .local, (cached.onlineMetadata.detailVersion ?? 0) < version else { return }
            isRefreshing = true
            defer { if generation == request { isRefreshing = false } }
            let updated = try await matcher.enrichDetails(reference: reference, source: source)
            guard generation == request, !Task.isCancelled,
                  store.load().libraries.first(where: { $0.id == reference.libraryID })?.metadataSource == library?.metadataSource else { return }
            record = updated
            if let updated {
                files = files.map { $0.id == updated.id ? updated : $0 }
            }
        } catch is CancellationError { }
        catch {
            guard generation == request, !Task.isCancelled else { return }
            detailsUnavailable = true
        }
    }

    private func cachedGroup(_ record: MediaRecord?) async throws -> [MediaRecord] {
        guard let record else { return [] }
        let group = try await index.group(for: record)
        return group.isEmpty ? [record] : group
    }
}

enum NASMediaDetailPresentation {
    static func primaryEpisode(episodes: [Episode], history: History?, selectedURL: String? = nil) -> Episode? {
        if let selectedURL, let selected = episodes.first(where: { $0.url == selectedURL }) { return selected }
        if let history, let episode = episodes.first(where: { $0.url == history.episodeUrl }) { return episode }
        return episodes.first
    }

    static func title(metadata: MediaMetadata, fallback: String) -> String {
        if metadata.kind == .television { return metadata.showTitle ?? metadata.title ?? fallback }
        return metadata.title ?? fallback
    }

    static func fileSummary(_ record: MediaRecord?) -> String {
        guard let record else { return "" }
        var values: [String] = []
        let container = (record.entry.name as NSString).pathExtension.uppercased()
        if !container.isEmpty { values.append(container) }
        if record.entry.size > 0 { values.append(ByteCountFormatter.string(fromByteCount: record.entry.size, countStyle: .file)) }
        return values.joined(separator: " · ")
    }
}
