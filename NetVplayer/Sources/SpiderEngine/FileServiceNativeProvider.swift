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
        return Result(list: try entries.filter { FileServiceRuntime.isVideo($0) || DiscMediaPolicy.isBDMV($0) }
            .map { try Self.vod(entry: $0, serviceID: serviceID, site: site) })
    }
    public static func vod(entry: FileEntry, serviceID: UUID, libraryID: UUID? = nil, site: Site) throws -> Vod {
        let path = DiscMediaPolicy.isBDMV(entry) ? FileServicePath.parent(entry.path) : entry.path
        let name = DiscMediaPolicy.isBDMV(entry) ? (path as NSString).lastPathComponent : entry.name
        let reference = try FileResourceReference(serviceID: serviceID, libraryID: libraryID, path: path)
        return Vod(vodId: reference.locator, vodName: (name as NSString).deletingPathExtension,
                   vodRemarks: ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file),
                   vodPlayFrom: "文件", vodPlayUrl: "播放$" + reference.locator, siteKey: site.key)
    }
    public func detailContent(site: Site, id: String) async throws -> Result {
        guard let reference = FileResourceReference(locator: id), reference.serviceID == serviceID else { throw FileServiceError.path(id) }
        let client = try await runtime.client(for: serviceID)
        let entry = try await client.stat(path: reference.path)
        if entry.isDirectory || DiscMediaPolicy.isISO(entry.name) {
            let catalog = try await runtime.scanDisc(reference)
            var vod = try Self.vod(entry: entry, serviceID: serviceID, libraryID: reference.libraryID, site: site)
            if let record = try await index.record(reference: reference) { vod = MediaLibraryPresentation.vod(record: record, group: [record], site: site) }
            let titles = catalog.titles.sorted {
                if ($0.playlist == catalog.suggestedPlaylist) != ($1.playlist == catalog.suggestedPlaylist) { return $0.playlist == catalog.suggestedPlaylist }
                return $0.playlist < $1.playlist
            }
            let episodes = titles.flatMap { title in
                (0..<title.angles).map { angle in
                    let selection = DiscSelection(reference: reference, playlist: title.playlist, angle: angle)
                    let name = title.displayName + (title.angles > 1 ? " · \(angle + 1)" : "")
                    return Episode(name: name, url: selection.locator, series: EpisodeSeries(id: selection.locator, name: name))
                }
            }
            vod.vodPlayFrom = L10n.text("蓝光标题")
            vod.vodPlayUrl = episodes.map { $0.name + "$" + $0.url }.joined(separator: "#")
            vod.episodeDetails = episodes
            return Result(list: [vod])
        }
        if reference.libraryID != nil, let record = try await index.record(reference: reference) {
            let group = try await index.group(for: record)
            if !group.isEmpty { return Result(list: [MediaLibraryPresentation.vod(record: record, group: group, site: site)]) }
        }
        return Result(list: [try Self.vod(entry: entry, serviceID: serviceID, libraryID: reference.libraryID, site: site)])
    }
    public func playerContent(site: Site, flag: String, id: String) async throws -> Result {
        if let selection = DiscSelection(locator: id), selection.reference.serviceID == serviceID {
            let leaseID = UUID()
            do {
                let disc = try await runtime.resolveDisc(selection, leaseID: leaseID)
                var result = Result(url: disc.edl(), flag: flag, fileResourceLeaseID: leaseID.uuidString)
                result.disc = disc
                return result
            } catch { await runtime.releasePlayback(leaseID: leaseID); throw error }
        }
        guard let reference = FileResourceReference(locator: id), reference.serviceID == serviceID else { throw FileServiceError.unavailable }
        // A disc must first resolve a concrete title. Never pass its ISO bytes to mpv as an ordinary file.
        guard !DiscMediaPolicy.isISO(reference.path) else { throw DiscReadError.invalidTitle }
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
