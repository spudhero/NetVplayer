import Foundation
import Testing
@testable import ConfigEngine
@testable import Models
@testable import NetVplayerApp

@MainActor
final class FeedbackWorkspaceSpy: FeedbackWorkspaceOpening {
    var selectedFile: String?
    var openedURL: URL?
    var opensSuccessfully = true

    func selectFile(_ fullPath: String?, inFileViewerRootedAtPath rootFullPath: String) -> Bool {
        selectedFile = fullPath
        return true
    }

    func open(_ url: URL) -> Bool {
        openedURL = url
        return opensSuccessfully
    }
}

@Test func feedbackDestinationRequiresAValidGitHubRepositorySetting() {
    #expect(FeedbackDestination.repositoryURL(infoDictionary: nil) == nil)
    #expect(FeedbackDestination.repositoryURL(infoDictionary: [
        FeedbackDestination.repositoryInfoKey: "https://example.com/not-github/repo",
    ]) == nil)
    #expect(FeedbackDestination.repositoryURL(infoDictionary: [
        FeedbackDestination.repositoryInfoKey: "https://github.com/spudhero/NetVplayer",
    ])?.absoluteString == "https://github.com/spudhero/NetVplayer")
}

@Test func feedbackPreviewSnapshotRejectsAnyChangedDraft() {
    let draft = FeedbackDraft(
        category: .playback,
        title: "Playback",
        problemDescription: "Does not start"
    )
    let report = FeedbackReport(
        issueTitle: "title",
        issueBody: "body",
        attachmentText: "attachment",
        reproductionLevel: .diagnosticOnly,
        publicSourceURL: nil
    )
    let snapshot = FeedbackPreviewSnapshot(draft: draft, report: report)
    var changed = draft
    changed.includeLogs.toggle()

    #expect(snapshot.report(matching: draft) == report)
    #expect(snapshot.report(matching: changed) == nil)
}

@Test func resolvedVodInputComputesStableConfigurationFingerprint() {
    let first = ResolvedVodInput(
        json: #"{"sites":[]}"#,
        config: Config(type: .vod, url: "https://example.com/config.json"),
        kind: .configuration,
        canonicalURL: "https://example.com/config.json",
        initialResult: nil
    )
    let second = ResolvedVodInput(
        json: #"{"sites":[]}"#,
        config: Config(type: .vod, url: "https://other.example/config.json"),
        kind: .configuration,
        canonicalURL: "https://other.example/config.json",
        initialResult: nil
    )
    let changed = ResolvedVodInput(
        json: #"{"sites":[{"key":"changed"}]}"#,
        config: Config(type: .vod, url: "https://example.com/config.json"),
        kind: .configuration,
        canonicalURL: "https://example.com/config.json",
        initialResult: nil
    )

    #expect(first.fingerprint == second.fingerprint)
    #expect(first.fingerprint != changed.fingerprint)
    #expect(first.fingerprint.count == 12)
    #expect(!first.fingerprint.contains("example.com"))
}

@MainActor
@Test func appStateFeedbackNavigationAndSourceContextUseOnlyFingerprints() async {
    let appState = AppState(loadDefaultConfig: false, startProxyServer: false)
    appState.activeSite = Site(
        key: "private-site-key",
        name: "Private Site",
        type: SiteType.spider.rawValue,
        api: "csp_PrivateProvider"
    )

    appState.openFeedback()
    let context = await appState.feedbackSourceContext(for: .provider)

    #expect(appState.selectedTab == .settings)
    #expect(appState.settingsNavigationDestination == .feedback)
    #expect(context.adapterID == "android-crawler")
    #expect(context.providerID == "PrivateProvider")
    #expect(context.siteKeyFingerprint?.count == 12)
    #expect(context.siteKeyFingerprint != "private-site-key")
    #expect(context.errorCategory == nil)

    appState.handlePlaybackError(
        NSError(domain: "feedback-test", code: 1),
        episode: Episode(name: "Private episode", url: "episode://private")
    )
    let failedContext = await appState.feedbackSourceContext(for: .playback)
    #expect(failedContext.failureStage == "Player.prepare")
    #expect(failedContext.errorCategory == .player)
}

@MainActor
@Test func feedbackHandoffSelectsAttachmentAndOpensIssueWithoutUploadingLog() throws {
    let spy = FeedbackWorkspaceSpy()
    let attachment = FileManager.default.temporaryDirectory
        .appendingPathComponent("feedback-handoff-test.log")
    var clipboardText: String?
    let draft = FeedbackDraft(
        category: .playback,
        title: "Playback fails",
        problemDescription: "Playback does not start",
        isSourceRelated: true,
        includeLogs: true
    )
    let report = FeedbackReport(
        issueTitle: "[用户反馈][播放] Playback fails",
        issueBody: "issue-body",
        attachmentText: "secret-log-body",
        reproductionLevel: .diagnosticOnly,
        publicSourceURL: nil
    )
    let repository = try #require(URL(string: "https://github.com/spudhero/NetVplayer"))

    let result = try FeedbackSubmissionCoordinator.handoff(
        draft: draft,
        report: report,
        repositoryURL: repository,
        workspace: spy,
        reportWriter: { _ in attachment },
        clipboardWriter: { clipboardText = $0 }
    )

    #expect(result.attachmentURL == attachment)
    #expect(spy.selectedFile == attachment.path)
    #expect(spy.openedURL?.host == "github.com")
    #expect(spy.openedURL?.absoluteString.contains("secret-log-body") == false)
    #expect(clipboardText == nil)
}

@MainActor
@Test func feedbackHandoffCopiesLongBodyAndReportsBrowserFailure() throws {
    let spy = FeedbackWorkspaceSpy()
    spy.opensSuccessfully = false
    var clipboardText: String?
    let draft = FeedbackDraft(
        category: .userInterface,
        title: "UI",
        problemDescription: String(repeating: "long description ", count: 800),
        isSourceRelated: false,
        includeLogs: false
    )
    let report = FeedbackReport(
        issueTitle: "[用户反馈][界面] UI",
        issueBody: String(repeating: "body ", count: 2_000),
        attachmentText: "unused",
        reproductionLevel: .generic,
        publicSourceURL: nil
    )
    let repository = try #require(URL(string: "https://github.com/spudhero/NetVplayer"))

    #expect(throws: (any Error).self) {
        try FeedbackSubmissionCoordinator.handoff(
            draft: draft,
            report: report,
            repositoryURL: repository,
            workspace: spy,
            reportWriter: { _ in
                Issue.record("Report writer should not run when logs are excluded")
                return URL(fileURLWithPath: "/tmp/unexpected.log")
            },
            clipboardWriter: { clipboardText = $0 }
        )
    }
    #expect(clipboardText == report.issueBody)
    #expect(spy.selectedFile == nil)
}

@Test func feedbackReportFileStoreWritesPrivateFileAndCleansExpiredReports() throws {
    let fileManager = FileManager.default
    let report = FeedbackReport(
        issueTitle: "title",
        issueBody: "body",
        attachmentText: "attachment",
        reproductionLevel: .generic,
        publicSourceURL: nil
    )
    let url = try FeedbackReportFileStore.write(report: report)
    defer { try? fileManager.removeItem(at: url) }

    let attributes = try fileManager.attributesOfItem(atPath: url.path)
    let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
    #expect(permissions.intValue == 0o600)
    #expect(try String(contentsOf: url, encoding: .utf8) == "attachment")

    let expired = url.deletingLastPathComponent().appendingPathComponent("expired-test.log")
    try Data("expired".utf8).write(to: expired)
    try fileManager.setAttributes(
        [.modificationDate: Date(timeIntervalSinceNow: -(FeedbackReportFileStore.retentionInterval + 10))],
        ofItemAtPath: expired.path
    )
    FeedbackReportFileStore.cleanupExpiredReports()
    #expect(!fileManager.fileExists(atPath: expired.path))
}
