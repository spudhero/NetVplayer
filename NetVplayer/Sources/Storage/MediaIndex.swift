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
        try query("SELECT payload FROM media WHERE id=?", [.text(reference.locator)]).first
    }
    public func records(libraryID: UUID, limit: Int = 50000, offset: Int = 0) throws -> [MediaRecord] {
        try query("SELECT payload FROM media WHERE library=? AND available=1 ORDER BY group_id,path LIMIT ? OFFSET ?",
                  [.text(libraryID.uuidString), .number(Double(max(1, min(limit, 50000)))), .number(Double(max(0, offset)))])
    }
    public func group(for record: MediaRecord) throws -> [MediaRecord] {
        try query("SELECT payload FROM media WHERE library=? AND group_id=? AND available=1 ORDER BY path",
                  [.text(record.reference.libraryID?.uuidString ?? ""), .text(record.groupKey)])
    }
    public func representatives(libraryID: UUID, limit: Int = 100, offset: Int = 0) throws -> [MediaRecord] {
        try query("SELECT payload FROM media WHERE id IN (SELECT MIN(id) FROM media WHERE library=? AND available=1 GROUP BY group_id) ORDER BY group_id LIMIT ? OFFSET ?",
                  [.text(libraryID.uuidString), .number(Double(max(1, min(limit, 500)))), .number(Double(max(0, offset)))])
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
    }
    public func markSeen(reference: FileResourceReference, scanID: UUID) throws {
        try execute("UPDATE media SET seen=?,available=1 WHERE id=?", [.text(scanID.uuidString), .text(reference.locator)])
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
        guard var record = try record(reference: correction.reference) else { throw MediaIndexError(message: "文件尚未索引") }
        record.correction = correction
        if let candidate = correction.selectedCandidate { record.onlineMetadata = candidate.metadata.fillingMissing(from: record.onlineMetadata); record.candidates = [] }
        try upsert(record)
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
