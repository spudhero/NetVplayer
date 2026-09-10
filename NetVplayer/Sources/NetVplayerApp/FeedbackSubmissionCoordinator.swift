import AppKit
import Foundation
import Models

enum FeedbackDestination {
    static let repositoryInfoKey = "NetVplayerFeedbackRepositoryURL"

    static func repositoryURL(bundle: Bundle = .main) -> URL? {
        repositoryURL(infoDictionary: bundle.infoDictionary)
    }

    static func repositoryURL(infoDictionary: [String: Any]?) -> URL? {
        guard let rawValue = infoDictionary?[repositoryInfoKey] as? String,
              let url = URL(string: rawValue),
              (try? GitHubIssueDraftURLBuilder.issueCreationURL(repositoryURL: url)) != nil else {
            return nil
        }
        return url
    }
}

struct FeedbackHandoffResult: Equatable {
    var attachmentURL: URL?
    var copiedToClipboard: Bool
}

@MainActor
protocol FeedbackWorkspaceOpening {
    @discardableResult
    func selectFile(_ fullPath: String?, inFileViewerRootedAtPath rootFullPath: String) -> Bool
    @discardableResult
    func open(_ url: URL) -> Bool
}

extension NSWorkspace: FeedbackWorkspaceOpening {}

enum FeedbackReportFileStore {
    static let retentionInterval: TimeInterval = 7 * 24 * 60 * 60

    static func cleanupExpiredReports(
        now: Date = Date(),
        fileManager: FileManager = .default
    ) {
        guard let directory = try? directoryURL(fileManager: fileManager),
              let files = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ) else { return }
        for file in files where file.pathExtension.lowercased() == "log" {
            let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if let modified, now.timeIntervalSince(modified) > retentionInterval {
                try? fileManager.removeItem(at: file)
            }
        }
    }

    static func write(
        report: FeedbackReport,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> URL {
        let directory = try directoryURL(fileManager: fileManager)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = directory.appendingPathComponent(
            "NetVplayer-feedback-\(formatter.string(from: now)).log"
        )
        try Data(report.attachmentText.utf8).write(to: url, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    private static func directoryURL(fileManager: FileManager) throws -> URL {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Caches", isDirectory: true)
        let directory = caches
            .appendingPathComponent("NetVplayer", isDirectory: true)
            .appendingPathComponent("Feedback", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

@MainActor
enum FeedbackSubmissionCoordinator {
    static func handoff(
        draft: FeedbackDraft,
        report: FeedbackReport,
        repositoryURL: URL,
        workspace: any FeedbackWorkspaceOpening = NSWorkspace.shared,
        reportWriter: (FeedbackReport) throws -> URL = { try FeedbackReportFileStore.write(report: $0) },
        clipboardWriter: (String) -> Void = { text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    ) throws -> FeedbackHandoffResult {
        FeedbackReportFileStore.cleanupExpiredReports()
        let attachmentURL = draft.includeLogs ? try reportWriter(report) : nil
        let handoff = try GitHubIssueDraftURLBuilder.makeHandoff(
            repositoryURL: repositoryURL,
            draft: draft,
            report: report
        )
        if handoff.requiresClipboardPaste {
            clipboardWriter(handoff.clipboardText)
        }
        if let attachmentURL {
            workspace.selectFile(attachmentURL.path, inFileViewerRootedAtPath: attachmentURL.deletingLastPathComponent().path)
        }
        guard workspace.open(handoff.url) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [
                NSLocalizedDescriptionKey: "无法打开 GitHub 反馈页面",
            ])
        }
        return FeedbackHandoffResult(
            attachmentURL: attachmentURL,
            copiedToClipboard: handoff.requiresClipboardPaste
        )
    }
}
