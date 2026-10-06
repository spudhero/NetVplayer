import Foundation
import Models
import Storage
import FileServiceEngine
import MediaLibraryEngine

/// Adapts credential-free file references to the application's existing detail and player pipeline.
public struct FileServiceNativeProvider: SiteContentProvider {
    public let serviceID: UUID
    private let runtime: FileServiceRuntime
    private let index: MediaIndex
    public init(serviceID: UUID, runtime: FileServiceRuntime = .shared, index: MediaIndex = .shared) {
        self.serviceID = serviceID; self.runtime = runtime; self.index = index
    }
    public func homeContent(site: Site) async throws -> Result {
        try await categoryContent(site: site, tid: "/", page: "1", filter: false, extend: [:])
    }
    public func categoryContent(site: Site, tid: String, page: String, filter: Bool, extend: [String: String]) async throws -> Result {
        let client = try await runtime.client(for: serviceID)
        let entries = try await client.allEntries(path: tid)
        return Result(list: try entries.filter(FileServiceRuntime.isVideo).map { try Self.vod(entry: $0, serviceID: serviceID, site: site) })
    }
    public static func vod(entry: FileEntry, serviceID: UUID, libraryID: UUID? = nil, site: Site) throws -> Vod {
        let reference = try FileResourceReference(serviceID: serviceID, libraryID: libraryID, path: entry.path)
        return Vod(vodId: reference.locator, vodName: (entry.name as NSString).deletingPathExtension,
                   vodRemarks: ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file),
                   vodPlayFrom: "文件", vodPlayUrl: "播放$" + reference.locator, siteKey: site.key)
    }
    public func detailContent(site: Site, id: String) async throws -> Result {
        guard let reference = FileResourceReference(locator: id), reference.serviceID == serviceID else { throw FileServiceError.path(id) }
        if reference.libraryID != nil, let record = try await index.record(reference: reference) {
            let group = try await index.group(for: record)
            if !group.isEmpty { return Result(list: [MediaLibraryPresentation.vod(record: record, group: group, site: site)]) }
        }
        let client = try await runtime.client(for: serviceID)
        let entry = try await client.stat(path: reference.path)
        return Result(list: [try Self.vod(entry: entry, serviceID: serviceID, libraryID: reference.libraryID, site: site)])
    }
    public func playerContent(site: Site, flag: String, id: String) async throws -> Result {
        guard let reference = FileResourceReference(locator: id), reference.serviceID == serviceID else { throw FileServiceError.unavailable }
        let leaseID = UUID()
        do {
        let resource = try await runtime.resolvePlayback(reference, leaseID: leaseID)
        let client = try await runtime.client(for: serviceID)
        // Optional subtitles must not make an otherwise playable video fail.
        let siblings = (try? await client.allEntries(path: FileServicePath.parent(reference.path))) ?? []
        let stem = ((reference.path as NSString).lastPathComponent as NSString).deletingPathExtension
        var subs: [Sub] = []
        for entry in siblings where FileServiceRuntime.isSubtitle(entry) && entry.name.hasPrefix(stem) {
            let reference = try FileResourceReference(serviceID: serviceID, libraryID: reference.libraryID, path: entry.path)
            if let subtitle = try? await runtime.resolvePlayback(reference, leaseID: leaseID) {
                subs.append(Sub(name: entry.name, url: subtitle.url.absoluteString))
            }
        }
        try Task.checkCancellation()
        return Result(url: resource.url.absoluteString, flag: flag, header: resource.headers, subs: subs, fileResourceLeaseID: leaseID.uuidString)
        } catch {
            await runtime.releasePlayback(leaseID: leaseID)
            throw error
        }
    }
    public func searchContent(site: Site, keyword: String, quick: Bool, page: String) async throws -> Result { .empty }
}
