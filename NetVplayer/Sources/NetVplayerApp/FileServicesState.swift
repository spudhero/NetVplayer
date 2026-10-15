import Foundation
import Combine
import Models
import Storage
import FileServiceEngine
import MediaLibraryEngine

extension Notification.Name { static let fileServicesDidChange = Notification.Name("netvplayer.fileServicesDidChange") }

@MainActor
final class FileServicesState: ObservableObject {
    static let shared = FileServicesState()
    @Published var catalog: FileServiceCatalog
    @Published var entries: [FileEntry] = []
    @Published var path = "/"
    @Published var busy = false
    @Published var error: String?
    @Published var directoryError: String?
    @Published var search = ""
    @Published var sort: FileSort = .name
    @Published var mode: FileViewMode = .files
    @Published var selectedLibraryID: UUID?
    @Published var mediaRecords: [MediaRecord] = []
    @Published var mediaHasMore = false
    @Published var mediaLoading = false
    @Published private(set) var mediaError: String?
    @Published var mediaFilter = MediaLibraryFilter()
    @Published private(set) var mediaFacets = MediaLibraryFacets()
    @Published var scanProgress: [UUID: MediaScanProgress] = [:]
    @Published var matchProgress: [UUID: MetadataMatchProgress] = [:]
    @Published var verificationURL: URL?
    private var indexTask: Task<Void, Never>?
    private var observers = Set<AnyCancellable>()
    private let index: MediaIndex
    private let store: FileServiceStore
    private let runtime: FileServiceRuntime
    private let startLibraryScan: @Sendable (MediaLibraryConfiguration) async -> Void
    private var mediaGeneration = 0
    private var loadedLibraryID: UUID?
    private var loadedFilter = MediaLibraryFilter()
    private var failedMediaAppend = false
    private var savingCorrections = false
    private(set) var serviceID: UUID?
    private var directoryTask: Task<Void, Never>?
    private var generation = 0
    enum FileSort: String, CaseIterable { case name = "名称", modified = "修改时间", size = "大小" }
    enum FileViewMode: String, CaseIterable { case library = "媒体库", files = "文件" }
    init(catalog: FileServiceCatalog? = nil, index: MediaIndex = .shared, serviceID: UUID? = nil,
         store: FileServiceStore = .shared, runtime: FileServiceRuntime? = nil,
         startLibraryScan: @escaping @Sendable (MediaLibraryConfiguration) async -> Void = { await MediaLibraryScanner.shared.start($0) }) {
        self.index = index; self.serviceID = serviceID; self.store = store
        self.runtime = runtime ?? (store === FileServiceStore.shared ? .shared : FileServiceRuntime(store: store))
        self.startLibraryScan = startLibraryScan
        self.catalog = catalog ?? store.load()
        NotificationCenter.default.publisher(for: .mediaLibraryIndexDidChange).receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self, notification.object as? UUID == self.selectedLibraryID else { return }
                self.loadMedia()
            }.store(in: &observers)
        NotificationCenter.default.publisher(for: .mediaLibraryScanDidChange).receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                if let progress = notification.object as? MediaScanProgress { self?.scanProgress[progress.libraryID] = progress }
            }.store(in: &observers)
        NotificationCenter.default.publisher(for: .metadataVerificationRequired).receive(on: DispatchQueue.main)
            .sink { [weak self] notification in self?.verificationURL = notification.object as? URL }.store(in: &observers)
        NotificationCenter.default.publisher(for: .metadataMatchingDidChange).receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                if let progress = notification.object as? MetadataMatchProgress { self?.matchProgress[progress.libraryID] = progress }
            }.store(in: &observers)
    }
    var selectedLibrary: MediaLibraryConfiguration? { libraries.first { $0.id == selectedLibraryID } }
    var isRefreshing: Bool {
        if mode == .files { return busy }
        guard let id = selectedLibraryID else { return false }
        return scanProgress[id]?.isRunning == true || matchProgress[id]?.isRunning == true
    }
    var visibleEntries: [FileEntry] {
        entries.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            switch sort {
            case .name: return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .modified: return (lhs.modifiedAt ?? .distantPast) > (rhs.modifiedAt ?? .distantPast)
            case .size: return lhs.size > rhs.size
            }
        }
    }
    var libraries: [MediaLibraryConfiguration] { catalog.libraries.filter { $0.serviceID == serviceID } }
    func reload() {
        catalog = store.load()
        if let id = selectedLibraryID, !catalog.libraries.contains(where: { $0.id == id }) {
            selectedLibraryID = libraries.first?.id
        }
        NotificationCenter.default.post(name: .fileServicesDidChange, object: nil)
    }
    func selectService(_ id: UUID) {
        guard serviceID != id else { return }
        cancelMediaLoad(clear: true)
        cancel(); serviceID = id; path = "/"; entries = []; search = ""; error = nil; directoryError = nil
        selectedLibraryID = libraries.first?.id
        mode = libraries.isEmpty ? .files : .library
        if mode == .library { loadMedia() }
        else { load(path: "/") }
    }
    func load(path: String) {
        guard let id = serviceID else { return }
        cancel(); generation += 1; let requestGeneration = generation
        self.path = path; search = ""; error = nil; directoryError = nil; busy = true
        directoryTask = Task {
            do {
                let client = try await FileServiceRuntime.shared.client(for: id)
                let entries = try await client.allEntries(path: path)
                try Task.checkCancellation()
                guard requestGeneration == self.generation else { return }
                self.entries = entries.filter { !$0.name.hasPrefix(".") }; self.busy = false
            } catch {
                guard requestGeneration == self.generation else { return }
                self.busy = false
                if !(error is CancellationError) { self.directoryError = error.localizedDescription }
            }
        }
    }
    func cancel() { generation += 1; directoryTask?.cancel(); directoryTask = nil; busy = false }
    func directoryEntries(serviceID: UUID, path: String) async throws -> [FileEntry] {
        let client = try await runtime.client(for: serviceID)
        return try await client.allEntries(path: path)
    }
    func cancelMediaLoad(clear: Bool = false) {
        mediaGeneration += 1; indexTask?.cancel(); indexTask = nil; mediaLoading = false
        if clear { mediaRecords = []; mediaHasMore = false; mediaError = nil; loadedLibraryID = nil; mediaFacets = .init() }
    }
    func setMediaFilter(_ filter: MediaLibraryFilter) {
        guard mediaFilter != filter || loadedLibraryID != selectedLibraryID else { return }
        mediaFilter = filter; loadMedia(resetFilterOnLibraryChange: false)
    }
    func loadNextMediaPage() {
        guard mediaHasMore, !mediaLoading, mediaError == nil else { return }
        loadMedia(append: true)
    }
    func retryMediaPage() { loadMedia(append: failedMediaAppend) }
    func waitForMediaLoad() async { await indexTask?.value }

    func loadMedia(append: Bool = false, resetFilterOnLibraryChange: Bool = true) {
        guard let id = selectedLibraryID, libraries.contains(where: { $0.id == id }) else {
            cancelMediaLoad(clear: true); return
        }
        if append { guard loadedLibraryID == id, mediaHasMore, !mediaLoading else { return } }
        if loadedLibraryID != id || loadedFilter != mediaFilter {
            if loadedLibraryID != id && resetFilterOnLibraryChange { mediaFilter = .init() }
            cancelMediaLoad(clear: true)
        }
        cancelMediaLoad()
        let requestGeneration = mediaGeneration
        let filter = mediaFilter
        loadedLibraryID = id; loadedFilter = filter; mediaLoading = true; mediaError = nil
        let offset = append ? mediaRecords.count : 0
        let targetCount = append ? 100 : max(100, mediaRecords.count)
        indexTask = Task {
            do {
                let resolvedFilter = try await index.canonicalFilter(libraryID: id, filter: filter)
                let facets = try await index.facets(libraryID: id)
                var records: [MediaRecord] = []
                // One look-ahead row tells us whether a full page is also the last page.
                while records.count < targetCount + 1 {
                    let limit = min(100, targetCount + 1 - records.count)
                    let page = try await index.representatives(libraryID: id, limit: limit, offset: offset + records.count, filter: resolvedFilter)
                    try Task.checkCancellation()
                    records += page
                    if page.count < limit { break }
                }
                try Task.checkCancellation()
                guard mediaGeneration == requestGeneration, selectedLibraryID == id, mediaFilter == filter else { return }
                mediaFilter = resolvedFilter; loadedFilter = resolvedFilter
                mediaFacets = facets
                let page = Array(records.prefix(targetCount))
                var seen = Set<String>()
                mediaRecords = (append ? mediaRecords + page : page).filter { seen.insert($0.id).inserted }
                mediaHasMore = records.count > targetCount
                mediaLoading = false
            } catch {
                guard !Task.isCancelled, mediaGeneration == requestGeneration else { return }
                mediaError = error.localizedDescription; failedMediaAppend = append; mediaLoading = false
            }
        }
    }

    /// Validate every directory before publishing one atomic catalog change.
    func addLibraries(_ drafts: [MediaLibraryConfiguration], to serviceID: UUID) async throws {
        guard let service = store.load().services.first(where: { $0.id == serviceID }) else { throw FileServiceError.unavailable }
        let libraries = try MediaLibraryBatch.validated(drafts, serviceID: serviceID, existing: store.load().libraries)
        let client = try await runtime.client(for: serviceID)
        for library in libraries {
            _ = try await client.allEntries(path: library.path)
            try Task.checkCancellation()
        }
        // Directory I/O can suspend while settings are edited in another window.
        var updated = store.load()
        guard updated.services.contains(service) else { throw FileServiceError.unavailable }
        let verified = try MediaLibraryBatch.validated(libraries, serviceID: serviceID, existing: updated.libraries)
        updated.libraries += verified
        try store.save(updated)
        reload()
        if self.serviceID == serviceID, selectedLibraryID == nil {
            selectedLibraryID = verified.first?.id; mode = .library; loadMedia()
        }
        for library in verified { await startLibraryScan(library) }
    }
    func refreshCurrentView() {
        if mode == .files { load(path: path) }
        else if let library = selectedLibrary { Task { await MediaLibraryScanner.shared.start(library) } }
    }
    func cancelCurrentRefresh() {
        if mode == .files { cancel() }
        else if let id = selectedLibraryID { Task { await MediaLibraryScanner.shared.cancel(libraryID: id); await MetadataMatcher.shared.cancel(libraryID: id) } }
    }
    func saveLibrary(_ library: MediaLibraryConfiguration) async throws {
        var library = library; library.path = try FileServicePath.normalize(library.path)
        guard !library.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw FileServiceError.invalidConfiguration("请填写媒体库名称") }
        let client = try await FileServiceRuntime.shared.client(for: library.serviceID)
        _ = try await client.allEntries(path: library.path)
        await MediaLibraryScanner.shared.cancel(libraryID: library.id)
        await MetadataMatcher.shared.cancel(libraryID: library.id)
        await MediaLibraryScanner.shared.waitForScan(libraryID: library.id)
        await MetadataMatcher.shared.waitForMatching(libraryID: library.id)
        var updated = catalog; updated.libraries.removeAll { $0.id == library.id }; updated.libraries.append(library)
        try FileServiceStore.shared.save(updated); reload()
        selectedLibraryID = library.id; loadMedia()
        await MediaLibraryScanner.shared.start(library)
    }
    func removeLibrary(_ library: MediaLibraryConfiguration) async throws {
        await MediaLibraryScanner.shared.cancel(libraryID: library.id); await MetadataMatcher.shared.cancel(libraryID: library.id)
        await MediaLibraryScanner.shared.waitForScan(libraryID: library.id)
        await MetadataMatcher.shared.waitForMatching(libraryID: library.id)
        var updated = catalog; updated.libraries.removeAll { $0.id == library.id }; try FileServiceStore.shared.save(updated)
        try await index.removeLibrary(library.id); reload()
        if selectedLibraryID == library.id { selectedLibraryID = libraries.first?.id; loadMedia() }
    }
    func setSource(_ source: MetadataSource, libraryID: UUID) throws {
        var updated = catalog
        guard let position = updated.libraries.firstIndex(where: { $0.id == libraryID }) else { return }
        updated.libraries[position].metadataSource = source; try FileServiceStore.shared.save(updated); reload()
        Task { await MetadataMatcher.shared.cancel(libraryID: libraryID) }
    }
    func saveCorrection(_ correction: MediaManualCorrection) async throws {
        try await saveCorrections([correction])
    }
    private func saveCorrections(_ changes: [MediaManualCorrection]) async throws {
        guard !savingCorrections else { throw FileServiceError.invalidConfiguration("正在保存影视资料，请稍后再试") }
        savingCorrections = true; defer { savingCorrections = false }
        let previous = store.loadCorrections()
        let changed = Set(changes.map(\.reference))
        let corrections = previous.filter { !changed.contains($0.reference) } + changes
        try store.saveCorrections(corrections)
        do { try await index.applyCorrections(changes) }
        catch { try? store.saveCorrections(previous); throw error }
        loadMedia()
    }
    func televisionRepresentatives(libraryID: UUID) async throws -> [MediaRecord] {
        var records: [MediaRecord] = []
        while true {
            let page = try await index.representatives(libraryID: libraryID, limit: 500, offset: records.count)
            records += page
            if page.count < 500 { break }
        }
        return records.filter { $0.metadata.kind == .television }
    }
    func mergeTelevision(groups: [MediaRecord], target: MediaRecord) async throws {
        guard let libraryID = target.reference.libraryID, catalog.libraries.contains(where: { $0.id == libraryID }), groups.count >= 2 else {
            throw FileServiceError.invalidConfiguration("请选择至少两个剧集条目")
        }
        await MediaLibraryScanner.shared.cancel(libraryID: libraryID)
        await MetadataMatcher.shared.cancel(libraryID: libraryID)
        await MediaLibraryScanner.shared.waitForScan(libraryID: libraryID)
        await MetadataMatcher.shared.waitForMatching(libraryID: libraryID)
        var records: [MediaRecord] = []
        for group in groups {
            guard let current = try await index.record(reference: group.reference), current.groupKey == group.groupKey else {
                throw FileServiceError.invalidConfiguration("剧集资料已变化，请重新选择要合并的条目")
            }
            records += try await index.group(for: current)
        }
        let current = try await index.record(reference: target.reference) ?? target
        let corrections = try MediaTelevisionMerge.corrections(records: records, target: current)
        try await saveCorrections(corrections)
    }
    func save(configuration: FileServiceConfiguration, credentials: FileServiceCredentials, bookmark: Data?) async throws {
        let configuration = try configuration.validated()
        // Saving always verifies the exact draft, including any changed endpoint or password.
        try await FileServiceRuntime.shared.test(configuration: configuration, credentials: credentials, bookmark: bookmark)
        try await Task.detached {
            try FileServiceStore.shared.saveCredentials(credentials, for: configuration)
            if let bookmark { try FileServiceStore.shared.saveBookmark(bookmark, for: configuration.id) }
        }.value
        var updated = catalog
        updated.services.removeAll { $0.id == configuration.id }; updated.services.append(configuration)
        try FileServiceStore.shared.save(updated)
        await MediaLibraryScanner.shared.cancel(serviceID: configuration.id)
        await MetadataMatcher.shared.cancel(serviceID: configuration.id)
        for library in catalog.libraries where library.serviceID == configuration.id {
            await MediaLibraryScanner.shared.waitForScan(libraryID: library.id)
            await MetadataMatcher.shared.waitForMatching(libraryID: library.id)
        }
        await FileServiceRuntime.shared.invalidate(serviceID: configuration.id)
        reload()
        if serviceID == configuration.id { load(path: "/") }
    }
    func remove(_ configuration: FileServiceConfiguration) async throws {
        if serviceID == configuration.id { cancel(); cancelMediaLoad(clear: true); selectedLibraryID = nil; serviceID = nil; entries = [] }
        await MediaLibraryScanner.shared.cancel(serviceID: configuration.id)
        await MetadataMatcher.shared.cancel(serviceID: configuration.id)
        for library in catalog.libraries where library.serviceID == configuration.id {
            await MediaLibraryScanner.shared.waitForScan(libraryID: library.id)
            await MetadataMatcher.shared.waitForMatching(libraryID: library.id)
            try await index.removeLibrary(library.id)
        }
        await FileServiceRuntime.shared.invalidate(serviceID: configuration.id)
        var updated = catalog
        updated.services.removeAll { $0.id == configuration.id }
        updated.libraries.removeAll { $0.serviceID == configuration.id }
        try FileServiceStore.shared.save(updated)
        try await Task.detached { try FileServiceStore.shared.removeSecrets(for: configuration.id) }.value
        reload()
    }
}
