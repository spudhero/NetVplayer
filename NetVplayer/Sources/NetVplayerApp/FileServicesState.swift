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
    @Published var catalog = FileServiceStore.shared.load()
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
    @Published var scanProgress: [UUID: MediaScanProgress] = [:]
    @Published var matchProgress: [UUID: MetadataMatchProgress] = [:]
    @Published var verificationURL: URL?
    private var indexTask: Task<Void, Never>?
    private var observers = Set<AnyCancellable>()
    private let index: MediaIndex
    private(set) var serviceID: UUID?
    private var directoryTask: Task<Void, Never>?
    private var generation = 0
    enum FileSort: String, CaseIterable { case name = "名称", modified = "修改时间", size = "大小" }
    enum FileViewMode: String, CaseIterable { case library = "媒体库", files = "文件" }
    init(catalog: FileServiceCatalog? = nil, index: MediaIndex = .shared, serviceID: UUID? = nil) {
        self.index = index; self.serviceID = serviceID
        if let catalog { self.catalog = catalog }
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
        catalog = FileServiceStore.shared.load()
        if let id = selectedLibraryID, !catalog.libraries.contains(where: { $0.id == id }) {
            selectedLibraryID = libraries.first?.id
        }
        NotificationCenter.default.post(name: .fileServicesDidChange, object: nil)
    }
    func selectService(_ id: UUID) {
        guard serviceID != id else { return }
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
    func loadMedia(append: Bool = false) {
        guard let id = selectedLibraryID else { mediaRecords = []; return }
        indexTask?.cancel(); mediaLoading = true
        let offset = append ? mediaRecords.count : 0
        let targetCount = append ? 100 : max(100, mediaRecords.count)
        indexTask = Task {
            do {
                var records: [MediaRecord] = []
                while records.count < targetCount {
                    let page = try await index.representatives(libraryID: id, limit: min(100, targetCount - records.count), offset: offset + records.count)
                    try Task.checkCancellation()
                    records += page
                    if page.count < 100 { break }
                }
                try Task.checkCancellation()
                guard selectedLibraryID == id else { return }
                mediaRecords = append ? mediaRecords + records : records
                mediaHasMore = records.count == targetCount
                mediaLoading = false
            } catch { if !Task.isCancelled { self.error = error.localizedDescription; mediaLoading = false } }
        }
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
        let previous = FileServiceStore.shared.loadCorrections()
        var corrections = previous; corrections.removeAll { $0.reference == correction.reference }; corrections.append(correction)
        try FileServiceStore.shared.saveCorrections(corrections)
        do { try await index.applyCorrection(correction) }
        catch { try? FileServiceStore.shared.saveCorrections(previous); throw error }
        loadMedia()
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
        if serviceID == configuration.id { cancel(); serviceID = nil; entries = [] }
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
