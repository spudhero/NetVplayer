import ApplicationCore
import Foundation

extension StorageManager: ApplicationLibraryPersistence {
    public func clearHistoryRecords() throws {
        try delete("history.json")
    }
}
