import Foundation
import Models
import CSQLite

public struct MediaIndexError: Error, LocalizedError, Sendable {
    public var message: String
    public var errorDescription: String? { "媒体索引：" + message }
}

private final class SQLiteConnection: @unchecked Sendable {
    var handle: OpaquePointer?
    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw MediaIndexError(message: "无法打开数据库")
        }
        sqlite3_busy_timeout(handle, 5000)
    }
    deinit { sqlite3_close(handle) }
}

/// All statements and scan completion transitions are serialized by this actor.
public actor MediaIndex {
    public static let shared = MediaIndex()
    private let connection: SQLiteConnection?
    private let openError: String?
    private var browseIndexReady = false
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NetVplayer/media-index.sqlite")
    }
    public init(url: URL = MediaIndex.defaultURL) {
        do {
            let connection = try SQLiteConnection(url: url)
            let schema = """
            PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;
            CREATE TABLE IF NOT EXISTS media(id TEXT PRIMARY KEY, library TEXT NOT NULL, service TEXT NOT NULL,
              path TEXT NOT NULL, group_id TEXT NOT NULL, payload BLOB NOT NULL, seen TEXT NOT NULL, available INTEGER NOT NULL DEFAULT 1);
            CREATE INDEX IF NOT EXISTS media_library ON media(library,available,group_id);
            CREATE TABLE IF NOT EXISTS scan_state(library TEXT PRIMARY KEY,last_success REAL,error TEXT);
            CREATE TABLE IF NOT EXISTS media_browse(id TEXT PRIMARY KEY,sort_title TEXT NOT NULL,release_date TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS media_facets(media_id TEXT NOT NULL,kind TEXT NOT NULL,facet_key TEXT NOT NULL,label TEXT NOT NULL,
              PRIMARY KEY(media_id,kind,facet_key));
            CREATE INDEX IF NOT EXISTS media_facet_lookup ON media_facets(kind,facet_key,media_id);
            CREATE TABLE IF NOT EXISTS media_actor_names(media_id TEXT NOT NULL,facet_key TEXT NOT NULL,name_key TEXT NOT NULL,label TEXT NOT NULL,
              PRIMARY KEY(media_id,facet_key));
            CREATE INDEX IF NOT EXISTS media_actor_name_lookup ON media_actor_names(name_key,facet_key,media_id);
            CREATE TABLE IF NOT EXISTS media_index_meta(key TEXT PRIMARY KEY,value TEXT NOT NULL);
            """
            guard sqlite3_exec(connection.handle, schema, nil, nil, nil) == SQLITE_OK else {
                throw MediaIndexError(message: String(cString: sqlite3_errmsg(connection.handle)))
            }
            self.connection = connection; self.openError = nil
        } catch { self.connection = nil; self.openError = error.localizedDescription }
    }
    private enum Value { case text(String), blob(Data), number(Double) }
    private func prepare(_ sql: String, _ values: [Value] = []) throws -> OpaquePointer {
        guard let db = connection?.handle else { throw MediaIndexError(message: openError ?? "数据库不可用") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let position = Int32(offset + 1)
            switch value {
            case .text(let text): sqlite3_bind_text(statement, position, text, -1, transient)
            case .blob(let data): _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, position, $0.baseAddress, Int32(data.count), transient) }
            case .number(let number): sqlite3_bind_double(statement, position, number)
            }
        }
        return statement
    }
    private func failure() -> MediaIndexError {
        MediaIndexError(message: connection?.handle.map { String(cString: sqlite3_errmsg($0)) } ?? "数据库不可用")
    }
    private func execute(_ sql: String, _ values: [Value] = []) throws {
        let statement = try prepare(sql, values); defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }
    private func query(_ sql: String, _ values: [Value] = []) throws -> [MediaRecord] {
        let statement = try prepare(sql, values); defer { sqlite3_finalize(statement) }
        var records: [MediaRecord] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw failure() }
            let size = Int(sqlite3_column_bytes(statement, 0))
            guard let bytes = sqlite3_column_blob(statement, 0), size <= 4 * 1024 * 1024 else { throw MediaIndexError(message: "索引条目无效") }
            records.append(try JSONDecoder().decode(MediaRecord.self, from: Data(bytes: bytes, count: size)))
        }
        return records
    }
    public func record(reference: FileResourceReference) throws -> MediaRecord? {
        try ensureBrowseIndex()
        return try query("SELECT payload FROM media WHERE id=?", [.text(reference.locator)]).first
    }
    public func records(libraryID: UUID, limit: Int = 50000, offset: Int = 0) throws -> [MediaRecord] {
        try ensureBrowseIndex()
        return try query("SELECT payload FROM media WHERE library=? AND available=1 ORDER BY group_id,path LIMIT ? OFFSET ?",
                  [.text(libraryID.uuidString), .number(Double(max(1, min(limit, 50000)))), .number(Double(max(0, offset)))])
    }
    public func group(for record: MediaRecord) throws -> [MediaRecord] {
        let current = try self.record(reference: record.reference) ?? record
        return try query("SELECT payload FROM media WHERE library=? AND group_id=? AND available=1 ORDER BY path",
                  [.text(current.reference.libraryID?.uuidString ?? ""), .text(current.groupKey)])
    }
    public func representatives(libraryID: UUID, limit: Int = 100, offset: Int = 0, filter: MediaLibraryFilter = .init()) throws -> [MediaRecord] {
        try ensureBrowseIndex()
        var condition = ""; var values: [Value] = [.text(libraryID.uuidString)]
        for (kind, key) in [("collection", filter.collection), ("actor", filter.actor), ("director", filter.director)] {
            if let key {
                let keys = kind == "actor" ? try actorKeys(libraryID: libraryID, key: key) : [key]
                condition += " AND EXISTS(SELECT 1 FROM media_facets f WHERE f.media_id=media.id AND f.kind=? AND f.facet_key IN (\(keys.map { _ in "?" }.joined(separator: ","))))"
                values += [.text(kind)] + keys.map(Value.text)
            }
        }
        values += [.number(Double(max(1, min(limit, 500)))), .number(Double(max(0, offset)))]
        let order = filter.collection == nil ? "b.sort_title,m.group_id" : "CASE WHEN b.release_date='' THEN '9999' ELSE b.release_date END,b.sort_title,m.group_id"
        return try query("SELECT m.payload FROM media m JOIN media_browse b ON b.id=m.id WHERE m.id IN (SELECT MIN(id) FROM media WHERE library=? AND available=1\(condition) GROUP BY group_id) ORDER BY \(order) LIMIT ? OFFSET ?", values)
    }
    public func facets(libraryID: UUID) throws -> MediaLibraryFacets {
        try ensureBrowseIndex()
        let statement = try prepare("SELECT f.kind,f.facet_key,MIN(f.label),COUNT(DISTINCT m.group_id) FROM media_facets f JOIN media m ON m.id=f.media_id WHERE m.library=? AND m.available=1 AND f.kind IN ('collection','director') GROUP BY f.kind,f.facet_key ORDER BY COUNT(DISTINCT m.group_id) DESC,MIN(f.label)", [.text(libraryID.uuidString)])
        defer { sqlite3_finalize(statement) }
        var result = MediaLibraryFacets()
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW, let kind = sqlite3_column_text(statement, 0),
                  let key = sqlite3_column_text(statement, 1), let label = sqlite3_column_text(statement, 2) else { throw failure() }
            let item = MediaLibraryFacet(id: String(cString: key), name: String(cString: label), count: Int(sqlite3_column_int(statement, 3)))
            if String(cString: kind) == "collection" { result.collections.append(item) }
            else { result.directors.append(item) }
        }
        let actors = try prepare("""
        WITH known AS (
          SELECT n.name_key,MIN(n.facet_key) AS target FROM media_actor_names n JOIN media m ON m.id=n.media_id
          WHERE m.library=? AND m.available=1 AND n.facet_key LIKE 'tmdb:%'
          GROUP BY n.name_key HAVING COUNT(DISTINCT n.facet_key)=1
        )
        SELECT COALESCE(k.target,n.facet_key),MIN(n.label),COUNT(DISTINCT m.group_id)
        FROM media_actor_names n JOIN media m ON m.id=n.media_id
        LEFT JOIN known k ON k.name_key=n.name_key AND n.facet_key LIKE 'name:%'
        WHERE m.library=? AND m.available=1 GROUP BY COALESCE(k.target,n.facet_key)
        ORDER BY COUNT(DISTINCT m.group_id) DESC,MIN(n.label)
        """, [.text(libraryID.uuidString), .text(libraryID.uuidString)])
        defer { sqlite3_finalize(actors) }
        while true {
            let code = sqlite3_step(actors)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW, let key = sqlite3_column_text(actors, 0), let name = sqlite3_column_text(actors, 1) else { throw failure() }
            result.actors.append(.init(id: String(cString: key), name: String(cString: name), count: Int(sqlite3_column_int(actors, 2))))
        }
        return result
    }
    public func canonicalFilter(libraryID: UUID, filter: MediaLibraryFilter) throws -> MediaLibraryFilter {
        try ensureBrowseIndex()
        guard let key = filter.actor, key.hasPrefix("name:") else { return filter }
        let statement = try prepare("""
        SELECT MIN(n.facet_key) FROM media_actor_names n JOIN media m ON m.id=n.media_id
        WHERE m.library=? AND m.available=1 AND n.name_key=? AND n.facet_key LIKE 'tmdb:%'
        HAVING COUNT(DISTINCT n.facet_key)=1
        """, [.text(libraryID.uuidString), .text(String(key.dropFirst(5)))])
        defer { sqlite3_finalize(statement) }
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { return filter }
        guard code == SQLITE_ROW else { throw failure() }
        guard let target = sqlite3_column_text(statement, 0) else { return filter }
        var resolved = filter; resolved.actor = String(cString: target)
        return resolved
    }
    private func actorKeys(libraryID: UUID, key: String) throws -> [String] {
        let key = try canonicalFilter(libraryID: libraryID, filter: .init(actor: key)).actor ?? key
        guard key.hasPrefix("tmdb:") else { return [key] }
        let statement = try prepare("""
        SELECT DISTINCT n.name_key FROM media_actor_names n JOIN media m ON m.id=n.media_id
        WHERE m.library=? AND m.available=1 AND n.facet_key=? AND
          (SELECT COUNT(DISTINCT other.facet_key) FROM media_actor_names other JOIN media om ON om.id=other.media_id
           WHERE om.library=m.library AND om.available=1 AND other.name_key=n.name_key AND other.facet_key LIKE 'tmdb:%')=1
        """, [.text(libraryID.uuidString), .text(key)])
        defer { sqlite3_finalize(statement) }
        var keys = [key]
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW, let name = sqlite3_column_text(statement, 0) else { throw failure() }
            keys.append("name:" + String(cString: name))
        }
        return keys
    }
    /// Upgrade cached grouping and facet data once, without touching file identities or scan availability.
    private func ensureBrowseIndex() throws {
        guard !browseIndexReady else { return }
        let statement = try prepare("SELECT value FROM media_index_meta WHERE key='browse_version'")
        let step = sqlite3_step(statement)
        let version = step == SQLITE_ROW ? sqlite3_column_text(statement, 0).map { String(cString: $0) } : nil
        sqlite3_finalize(statement)
        guard step == SQLITE_ROW || step == SQLITE_DONE else { throw failure() }
        if version == "3" { browseIndexReady = true; return }
        try execute("BEGIN IMMEDIATE")
        do {
            for var record in try query("SELECT payload FROM media") {
                record.updateGrouping()
                try execute("UPDATE media SET payload=?,group_id=? WHERE id=?", [.blob(try JSONEncoder().encode(record)), .text(record.groupKey), .text(record.id)])
                try updateBrowseFields(record)
            }
            try execute("INSERT INTO media_index_meta(key,value) VALUES('browse_version','3') ON CONFLICT(key) DO UPDATE SET value='3'")
            try execute("COMMIT"); browseIndexReady = true
        } catch { try? execute("ROLLBACK"); throw error }
    }
    private func updateBrowseFields(_ record: MediaRecord) throws {
        let metadata = record.metadata
        let title = metadata.kind == .television ? metadata.showTitle ?? metadata.title ?? record.entry.name : metadata.title ?? record.entry.name
        let date = metadata.releaseDate ?? metadata.year.map { String(format: "%04d-01-01", $0) } ?? ""
        try execute("INSERT INTO media_browse(id,sort_title,release_date) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET sort_title=excluded.sort_title,release_date=excluded.release_date",
                    [.text(record.id), .text(MediaLibraryIdentity.normalized(title)), .text(date)])
        try execute("DELETE FROM media_facets WHERE media_id=?", [.text(record.id)])
        try execute("DELETE FROM media_actor_names WHERE media_id=?", [.text(record.id)])
        var facets: [(String, String, String)] = []
        if metadata.kind != .television, let collection = metadata.collection, !collection.name.isEmpty {
            facets.append(("collection", MediaLibraryIdentity.collectionKey(collection), collection.name))
        }
        for director in metadata.directors ?? [] {
            let name = MediaLibraryIdentity.personName(director)
            guard !MediaLibraryIdentity.normalized(name).isEmpty else { continue }
            facets.append(("director", MediaLibraryIdentity.directorKey(name), name))
        }
        for actor in metadata.cast ?? [] where !actor.name.isEmpty {
            let name = MediaLibraryIdentity.actorName(actor.name)
            let key = MediaLibraryIdentity.actorKey(actor)
            facets.append(("actor", key, name))
            try execute("INSERT OR IGNORE INTO media_actor_names(media_id,facet_key,name_key,label) VALUES(?,?,?,?)",
                        [.text(record.id), .text(key), .text(MediaLibraryIdentity.normalized(name)), .text(name)])
        }
        for (kind, key, label) in facets {
            try execute("INSERT OR IGNORE INTO media_facets(media_id,kind,facet_key,label) VALUES(?,?,?,?)",
                        [.text(record.id), .text(kind), .text(key), .text(label)])
        }
    }
    public func upsert(_ record: MediaRecord, scanID: UUID? = nil) throws {
        var record = record; record.updateGrouping()
        let data = try JSONEncoder().encode(record)
        let library = record.reference.libraryID?.uuidString ?? ""
        if let scanID {
            try execute("INSERT INTO media(id,library,service,path,group_id,payload,seen,available) VALUES(?,?,?,?,?,?,?,1) ON CONFLICT(id) DO UPDATE SET group_id=excluded.group_id,payload=excluded.payload,seen=excluded.seen,available=1",
                [.text(record.id), .text(library), .text(record.reference.serviceID.uuidString), .text(record.reference.path), .text(record.groupKey), .blob(data), .text(scanID.uuidString)])
        } else {
            try execute("UPDATE media SET payload=?,group_id=? WHERE id=?", [.blob(data), .text(record.groupKey), .text(record.id)])
        }
        try updateBrowseFields(record)
    }
    public func markSeen(reference: FileResourceReference, scanID: UUID) throws {
        try execute("UPDATE media SET seen=?,available=1 WHERE id=?", [.text(scanID.uuidString), .text(reference.locator)])
    }
    /// Commit a slow detail request only while its matched identity and source are unchanged.
    /// This check and write share one actor turn, preserving concurrent corrections/scans.
    public func enrichDetails(_ metadata: MediaMetadata, snapshot: MediaRecord) throws -> MediaRecord? {
        guard var current = try query("SELECT payload FROM media WHERE id=? AND available=1", [.text(snapshot.id)]).first else { return nil }
        guard current.metadataSource == snapshot.metadataSource,
              current.correction == snapshot.correction,
              current.localMetadata == snapshot.localMetadata,
              current.onlineMetadata == snapshot.onlineMetadata else { return current }
        current.onlineMetadata = metadata.fillingMissing(from: current.onlineMetadata)
        try upsert(current)
        return current
    }
    public func finishScan(libraryID: UUID, scanID: UUID, succeeded: Bool, error: String? = nil) throws {
        if succeeded {
            try execute("BEGIN IMMEDIATE")
            do {
                try execute("UPDATE media SET available=0 WHERE library=? AND seen<>?", [.text(libraryID.uuidString), .text(scanID.uuidString)])
                try execute("INSERT INTO scan_state(library,last_success,error) VALUES(?,?,NULL) ON CONFLICT(library) DO UPDATE SET last_success=excluded.last_success,error=NULL",
                            [.text(libraryID.uuidString), .number(Date().timeIntervalSince1970)])
                try execute("COMMIT")
            } catch { try? execute("ROLLBACK"); throw error }
        } else {
            try execute("INSERT INTO scan_state(library,error) VALUES(?,?) ON CONFLICT(library) DO UPDATE SET error=excluded.error",
                        [.text(libraryID.uuidString), .text(error ?? "扫描未完成")])
        }
    }
    public func lastSuccessfulScan(libraryID: UUID) throws -> Date? {
        let statement = try prepare("SELECT last_success FROM scan_state WHERE library=?", [.text(libraryID.uuidString)])
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
    }
    public func applyCorrection(_ correction: MediaManualCorrection) throws {
        try applyCorrections([correction])
    }
    public func applyCorrections(_ corrections: [MediaManualCorrection]) throws {
        try ensureBrowseIndex()
        try execute("BEGIN IMMEDIATE")
        do {
            for correction in corrections {
                guard var record = try query("SELECT payload FROM media WHERE id=? AND available=1", [.text(correction.id)]).first else { throw MediaIndexError(message: "文件尚未索引") }
                record.correction = correction
                if let candidate = correction.selectedCandidate {
                    record.onlineMetadata = candidate.metadata; record.candidates = []
                }
                try upsert(record)
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    public func corrections() throws -> [MediaManualCorrection] {
        try query("SELECT payload FROM media").compactMap(\.correction)
    }
    /// Reconcile the rebuildable index with restored configuration, including removed locks.
    public func restoreCatalogState(libraries: [MediaLibraryConfiguration], corrections: [MediaManualCorrection], resetScanState: Bool = true) throws {
        let libraryByID = Dictionary(libraries.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let correctionByReference = Dictionary(corrections.map { ($0.reference, $0) }, uniquingKeysWith: { _, last in last })
        try execute("BEGIN IMMEDIATE")
        do {
            for var record in try query("SELECT payload FROM media") {
                guard let libraryID = record.reference.libraryID, let library = libraryByID[libraryID] else {
                    try execute("UPDATE media SET available=0 WHERE id=?", [.text(record.id)])
                    continue
                }
                record.metadataSource = library.metadataSource
                record.correction = correctionByReference[record.reference]
                if let candidate = record.correction?.selectedCandidate {
                    record.onlineMetadata = candidate.metadata.fillingMissing(from: record.onlineMetadata)
                    record.candidates = []
                }
                try upsert(record)
            }
            if resetScanState {
                for library in libraries {
                    try execute("UPDATE scan_state SET last_success=NULL WHERE library=?", [.text(library.id.uuidString)])
                }
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    public func removeLibrary(_ id: UUID) throws {
        try execute("UPDATE media SET available=0 WHERE library=?", [.text(id.uuidString)])
    }
}
