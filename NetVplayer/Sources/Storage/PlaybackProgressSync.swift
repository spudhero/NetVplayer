// Storage/PlaybackProgressSync.swift
// Safe playback progress import/export contract for local sync and future WebHome history bridge.

import Foundation
import Models

public struct PlaybackProgressExport: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var exportedAt: Date
    public var records: [PlaybackProgressRecord]

    public init(schemaVersion: Int = 1, exportedAt: Date = Date(), records: [PlaybackProgressRecord] = []) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.records = records
    }
}

public struct PlaybackProgressRecord: Codable, Identifiable, Sendable, Equatable {
    public var id: String { progressKey }
    public var historyKey: String
    public var progressKey: String
    public var siteKey: String
    public var vodId: String
    public var vodName: String
    public var vodFlag: String
    public var episodeKey: String
    public var position: Int64
    public var duration: Int64
    public var updatedAt: Date
    public var driveProvider: String
    public var driveReferenceURL: String
    public var driveRoute: String

    public init(
        historyKey: String,
        progressKey: String,
        siteKey: String,
        vodId: String,
        vodName: String,
        vodFlag: String,
        episodeKey: String,
        position: Int64,
        duration: Int64,
        updatedAt: Date,
        driveProvider: String = "",
        driveReferenceURL: String = "",
        driveRoute: String = ""
    ) {
        self.historyKey = historyKey
        self.progressKey = progressKey
        self.siteKey = siteKey
        self.vodId = vodId
        self.vodName = vodName
        self.vodFlag = vodFlag
        self.episodeKey = episodeKey
        self.position = max(0, position)
        self.duration = max(0, duration)
        self.updatedAt = updatedAt
        self.driveProvider = driveProvider
        self.driveReferenceURL = Self.safeDriveReference(driveReferenceURL)
        self.driveRoute = driveRoute
    }

    public init(history: History) {
        let driveReferenceURL = Self.safeDriveReference(history.driveReferenceURL)
        let episodeKey = Self.episodeKey(for: history)
        let progressKey = driveReferenceURL.isEmpty
            ? [history.siteKey, history.vodId, history.vodFlag, episodeKey].joined(separator: "|")
            : driveReferenceURL
        self.init(
            historyKey: history.key,
            progressKey: progressKey,
            siteKey: history.siteKey,
            vodId: history.vodId,
            vodName: history.vodName,
            vodFlag: history.vodFlag,
            episodeKey: episodeKey,
            position: history.position,
            duration: history.duration,
            updatedAt: history.createTime,
            driveProvider: history.driveProvider,
            driveReferenceURL: driveReferenceURL,
            driveRoute: history.driveRoute
        )
    }

    public static func episodeKey(for history: History) -> String {
        if !history.episodeKey.isEmpty {
            return history.episodeKey
        }
        return HistoryPersistencePolicy.episodeKey(
            siteKey: history.siteKey,
            vodId: history.vodId,
            vodFlag: history.vodFlag,
            episodeURL: history.episodeUrl
        )
    }

    public static func safeDriveReference(_ value: String) -> String {
        HistoryPersistencePolicy.sanitizedDriveReference(value)
    }
}

public enum PlaybackProgressSyncPolicy {
    public static func merged(existing histories: [History], importing export: PlaybackProgressExport) -> [History] {
        var items = histories
        var indexes: [String: Int] = [:]
        for (index, history) in items.enumerated() {
            indexes[PlaybackProgressRecord(history: history).progressKey] = index
        }

        for record in export.records {
            if let index = indexes[record.progressKey] {
                guard record.updatedAt > items[index].createTime else { continue }
                items[index].position = record.position
                items[index].duration = record.duration
                items[index].createTime = record.updatedAt
                if !record.driveReferenceURL.isEmpty {
                    items[index].driveProvider = record.driveProvider
                    items[index].driveReferenceURL = record.driveReferenceURL
                    items[index].driveRoute = record.driveRoute
                }
            } else if !record.driveReferenceURL.isEmpty {
                let history = History(
                    key: record.historyKey.isEmpty ? record.progressKey : record.historyKey,
                    siteKey: record.siteKey,
                    vodId: record.vodId,
                    vodName: record.vodName,
                    vodFlag: record.vodFlag,
                    episodeUrl: record.driveReferenceURL,
                    position: record.position,
                    duration: record.duration,
                    driveProvider: record.driveProvider,
                    driveReferenceURL: record.driveReferenceURL,
                    driveRoute: record.driveRoute,
                    createTime: record.updatedAt
                )
                indexes[record.progressKey] = items.count
                items.append(history)
            }
        }

        return items.sorted { $0.createTime > $1.createTime }
    }
}
