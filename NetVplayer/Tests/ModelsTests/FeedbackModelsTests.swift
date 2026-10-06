import Foundation
import Testing
@testable import Models

@Test func diagnosticSanitizerRemovesCredentialsURLsAndPrivateValues() {
    let input = """
    url=https://user:pass@example.com/private/video.m3u8?token=secret
    Cookie: first=abc; session=secret-cookie
    Authorization: Bearer secret-token
    Proxy-Authorization=Bearer-123
    keyword=我的搜索 title=隐私片名 file=/Users/alice/Movies/private.mp4 names=封面.jpg, 字幕.srt
    [PLAY_EPISODE] 开始播放剧集 title=私密剧集, url=https://media.example/private.m3u8
    private=http://192.168.1.8:8080/api?id=123 ipv6=https://[fd00::1]/api email=alice@example.com
    """

    let sanitized = DiagnosticLogSanitizer.sanitize(input)

    #expect(!sanitized.contains("user:pass"))
    #expect(!sanitized.contains("secret"))
    #expect(!sanitized.contains("Bearer-123"))
    #expect(!sanitized.contains("secret-token"))
    #expect(!sanitized.contains("secret-cookie"))
    #expect(!sanitized.contains("我的搜索"))
    #expect(!sanitized.contains("隐私片名"))
    #expect(!sanitized.contains("私密剧集"))
    #expect(!sanitized.contains("封面.jpg"))
    #expect(!sanitized.contains("字幕.srt"))
    #expect(!sanitized.contains("/Users/alice"))
    #expect(!sanitized.contains("alice@example.com"))
    #expect(sanitized.contains("https://example.com/<redacted>"))
    #expect(sanitized.contains("http://<private-host>:8080/<redacted>"))
    #expect(sanitized.contains("https://<private-host>/<redacted>"))
}

@Test func diagnosticLogStoreRotatesBoundsAndReadsTwoSessions() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("netvplayer-feedback-log-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DiagnosticLogStore(
        directoryURL: directory,
        maximumSessionBytes: 1_024,
        maximumLineBytes: 256
    )

    store.beginSession()
    store.write("previous-session marker token=private-token")
    store.beginSession()
    await withTaskGroup(of: Void.self) { group in
        for index in 0..<80 {
            group.addTask {
                store.write("current-session-\(index) title=private-title payload=\(String(repeating: "x", count: 40))")
            }
        }
    }

    let currentSize = try #require(
        store.currentLogURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
    )
    let report = store.reportText(maximumCombinedBytes: 2_048)

    #expect(currentSize <= 1_024)
    #expect(report.contains("Previous session"))
    #expect(report.contains("Current session"))
    #expect(!report.contains("private-token"))
    #expect(!report.contains("private-title"))
}

@Test func diagnosticLogStoreKeepsStrictUTF8AndCombinedReportBudgets() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("netvplayer-feedback-unicode-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DiagnosticLogStore(
        directoryURL: directory,
        maximumSessionBytes: 1_024,
        maximumLineBytes: 256
    )

    store.beginSession()
    store.write(String(repeating: "剧集标题", count: 200))
    let currentData = try Data(contentsOf: store.currentLogURL)
    let report = store.reportText(maximumCombinedBytes: 1_024)

    #expect(currentData.count <= 1_024)
    #expect(String(data: currentData, encoding: .utf8) != nil)
    #expect(currentData.split(separator: 0x0A).allSatisfy { $0.count + 1 <= 256 })
    #expect(report.utf8.count <= 1_024)
    #expect(report.contains("Previous session"))
    #expect(report.contains("previous session log not found"))
    #expect(report.contains("Current session"))
}

@Test func diagnosticLogStoreReportsUnreadableSessionReason() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("netvplayer-feedback-unreadable-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DiagnosticLogStore(directoryURL: directory)
    try FileManager.default.createDirectory(at: store.currentLogURL, withIntermediateDirectories: true)

    let report = store.reportText()

    #expect(report.contains("current session log is not a readable file"))
}

@Test func stableFingerprintIsDeterministicAndTruncated() {
    let first = StableFingerprint.sha256Prefix("same configuration")
    let second = StableFingerprint.sha256Prefix("same configuration")
    let other = StableFingerprint.sha256Prefix("different configuration")

    #expect(first == second)
    #expect(first.count == 12)
    #expect(first != other)
    #expect(!first.contains("configuration"))
}

@Test func publicSourceValidatorRequiresExplicitSafePublicHTTPS() throws {
    let accepted = try PublicReproductionSourceValidator.validate(
        "https://example.com/config.json?lang=zh",
        confirmed: true
    )
    #expect(accepted?.absoluteString == "https://example.com/config.json?lang=zh")
    let harmlessKeyName = try PublicReproductionSourceValidator.validate(
        "https://example.com/config.json?monkey=ok",
        confirmed: true
    )
    #expect(harmlessKeyName != nil)

    #expect(throws: PublicSourceValidationError.confirmationRequired) {
        try PublicReproductionSourceValidator.validate("https://example.com/config.json", confirmed: false)
    }
    #expect(throws: PublicSourceValidationError.requiresHTTPS) {
        try PublicReproductionSourceValidator.validate("http://example.com/config.json", confirmed: true)
    }
    #expect(throws: PublicSourceValidationError.containsCredentials) {
        try PublicReproductionSourceValidator.validate("https://user:pass@example.com/config.json", confirmed: true)
    }
    #expect(throws: PublicSourceValidationError.privateHost) {
        try PublicReproductionSourceValidator.validate("https://192.168.1.2/config.json", confirmed: true)
    }
    #expect(throws: PublicSourceValidationError.privateHost) {
        try PublicReproductionSourceValidator.validate("https://[fd00::1]/config.json", confirmed: true)
    }
    #expect(throws: PublicSourceValidationError.privateHost) {
        try PublicReproductionSourceValidator.validate("https://localhost/config.json", confirmed: true)
    }
    #expect(throws: PublicSourceValidationError.privateHost) {
        try PublicReproductionSourceValidator.validate("https://[fe80::1]/config.json", confirmed: true)
    }
    #expect(throws: PublicSourceValidationError.containsFragment) {
        try PublicReproductionSourceValidator.validate("https://example.com/config.json#private", confirmed: true)
    }
    #expect(throws: PublicSourceValidationError.invalidURL) {
        try PublicReproductionSourceValidator.validate("not a url", confirmed: true)
    }
    #expect(throws: PublicSourceValidationError.containsSensitiveQuery("access_token")) {
        try PublicReproductionSourceValidator.validate(
            "https://example.com/config.json?access_token=secret",
            confirmed: true
        )
    }
}

@Test func feedbackReportSeparatesDiagnosticAndPublicSourceVerification() throws {
    let environment = FeedbackEnvironment(
        appVersion: "1.2.3",
        buildNumber: "45",
        operatingSystem: "macOS test",
        architecture: "arm64",
        generatedAt: Date(timeIntervalSince1970: 0),
        sessionID: "session-test"
    )
    let context = SourceReproductionContext(
        configFingerprint: "abc123def456",
        inputKind: "configuration",
        adapterID: "spider",
        providerID: "provider.sample",
        providerVersion: "2.0.0",
        siteKeyFingerprint: "site12345678",
        failureStage: "Spider",
        errorCategory: .spider
    )
    var draft = FeedbackDraft(
        category: .provider,
        title: "加载失败",
        problemDescription: "打开后无法加载",
        reproductionSteps: "打开首页",
        expectedResult: "显示内容",
        actualResult: "显示错误",
        isSourceRelated: true,
        includeLogs: true
    )

    let diagnosticOnly = try FeedbackReportBuilder.build(
        draft: draft,
        sourceContext: context,
        environment: environment,
        diagnosticLogs: "Authorization=secret\nlog-marker"
    )
    #expect(diagnosticOnly.reproductionLevel == .diagnosticOnly)
    #expect(diagnosticOnly.issueBody.contains("真实源未验证"))
    #expect(diagnosticOnly.issueBody.contains("abc123def456"))
    #expect(diagnosticOnly.automaticContext.contains("provider.sample @ 2.0.0"))
    #expect(!diagnosticOnly.issueBody.contains("log-marker"))
    #expect(diagnosticOnly.attachmentText.contains("log-marker"))
    #expect(!diagnosticOnly.attachmentText.contains("Authorization=secret"))
    let repository = try #require(URL(string: "https://github.com/spudhero/NetVplayer"))
    let diagnosticHandoff = try GitHubIssueDraftURLBuilder.makeHandoff(
        repositoryURL: repository,
        draft: draft,
        report: diagnosticOnly
    )
    let diagnosticItems = URLComponents(
        url: diagnosticHandoff.url,
        resolvingAgainstBaseURL: false
    )?.queryItems ?? []
    #expect(diagnosticItems.first { $0.name == "diagnostics" }?.value?.contains("abc123def456") == true)
    #expect(diagnosticItems.first { $0.name == "diagnostics" }?.value?.contains("provider.sample") == true)
    #expect(diagnosticItems.allSatisfy { $0.value?.contains("log-marker") != true })

    draft.publicSourceURL = "https://example.com/public-config.json"
    draft.confirmsPublicSource = true
    let publicSource = try FeedbackReportBuilder.build(
        draft: draft,
        sourceContext: context,
        environment: environment,
        diagnosticLogs: "log-marker"
    )
    #expect(publicSource.reproductionLevel == .publicSource)
    #expect(publicSource.issueBody.contains("https://example.com/public-config.json"))

    draft.isSourceRelated = false
    let generic = try FeedbackReportBuilder.build(
        draft: draft,
        sourceContext: context,
        environment: environment,
        diagnosticLogs: ""
    )
    #expect(generic.reproductionLevel == .generic)
    #expect(generic.publicSourceURL == nil)
    #expect(!generic.issueBody.contains("abc123def456"))
    #expect(!generic.issueBody.contains("provider.sample"))
    #expect(!generic.issueBody.contains("public-config.json"))
}

@Test func feedbackReportRequiresTitleAndProblemAndCanExcludeLogs() throws {
    let environment = FeedbackEnvironment(
        appVersion: "1",
        buildNumber: "1",
        operatingSystem: "macOS",
        architecture: "arm64"
    )
    var draft = FeedbackDraft(title: "", problemDescription: "Problem")
    #expect(throws: FeedbackValidationError.missingTitle) {
        try FeedbackReportBuilder.build(
            draft: draft,
            sourceContext: SourceReproductionContext(),
            environment: environment,
            diagnosticLogs: "secret-log-marker"
        )
    }

    draft.title = "Title"
    draft.problemDescription = ""
    #expect(throws: FeedbackValidationError.missingProblemDescription) {
        try FeedbackReportBuilder.build(
            draft: draft,
            sourceContext: SourceReproductionContext(),
            environment: environment,
            diagnosticLogs: "secret-log-marker"
        )
    }

    draft.problemDescription = "Problem"
    draft.includeLogs = false
    let report = try FeedbackReportBuilder.build(
        draft: draft,
        sourceContext: SourceReproductionContext(),
        environment: environment,
        diagnosticLogs: "secret-log-marker"
    )
    #expect(report.attachmentText.contains("日志未附带（用户选择）"))
    #expect(!report.attachmentText.contains("secret-log-marker"))
}

@Test func feedbackReportKeepsReproductionContextWhenLargeLogsAreTruncated() throws {
    let draft = FeedbackDraft(
        category: .source,
        title: String(repeating: "标题 ", count: 200),
        problemDescription: "必须保留的问题现象",
        isSourceRelated: true,
        includeLogs: true
    )
    let context = SourceReproductionContext(configFingerprint: "keep12345678")
    let environment = FeedbackEnvironment(
        appVersion: "1",
        buildNumber: "1",
        operatingSystem: "macOS",
        architecture: "arm64",
        sessionID: "large-log"
    )
    let report = try FeedbackReportBuilder.build(
        draft: draft,
        sourceContext: context,
        environment: environment,
        diagnosticLogs: String(repeating: "日志内容\n", count: 400_000)
    )

    #expect(report.issueTitle.count <= 220)
    #expect(report.attachmentText.utf8.count <= FeedbackReport.maximumAttachmentBytes)
    #expect(report.attachmentText.contains("必须保留的问题现象"))
    #expect(report.attachmentText.contains("keep12345678"))
    #expect(report.attachmentText.contains("[REPORT_TRUNCATED]"))
}

@Test func githubIssueURLNeverContainsLogsAndFallsBackToClipboard() throws {
    let draft = FeedbackDraft(
        category: .playback,
        title: "播放失败",
        problemDescription: "无法播放",
        reproductionSteps: "点击播放",
        expectedResult: "开始播放",
        actualResult: "显示错误",
        isSourceRelated: true,
        includeLogs: true
    )
    let report = FeedbackReport(
        issueTitle: "[用户反馈][播放] 播放失败",
        issueBody: "body-marker",
        attachmentText: "sensitive-log-marker",
        reproductionLevel: .diagnosticOnly,
        publicSourceURL: nil
    )
    let repository = try #require(URL(string: "https://github.com/spudhero/NetVplayer"))

    let normal = try GitHubIssueDraftURLBuilder.makeHandoff(
        repositoryURL: repository,
        draft: draft,
        report: report
    )
    #expect(normal.url.absoluteString.contains("user-feedback.yml"))
    #expect(!normal.url.absoluteString.contains("sensitive-log-marker"))
    #expect(normal.requiresClipboardPaste == false)
    let normalBytes = normal.url.absoluteString.utf8.count
    let exactBoundary = try GitHubIssueDraftURLBuilder.makeHandoff(
        repositoryURL: repository,
        draft: draft,
        report: report,
        maximumURLBytes: normalBytes
    )
    let belowBoundary = try GitHubIssueDraftURLBuilder.makeHandoff(
        repositoryURL: repository,
        draft: draft,
        report: report,
        maximumURLBytes: normalBytes - 1
    )
    #expect(!exactBoundary.requiresClipboardPaste)
    #expect(belowBoundary.requiresClipboardPaste)

    let fallback = try GitHubIssueDraftURLBuilder.makeHandoff(
        repositoryURL: repository,
        draft: draft,
        report: report,
        maximumURLBytes: 100
    )
    #expect(fallback.requiresClipboardPaste)
    #expect(fallback.clipboardText == "body-marker")
    #expect(!fallback.url.absoluteString.contains("sensitive-log-marker"))
    #expect(!fallback.url.absoluteString.contains("template="))
    #expect(URLComponents(url: fallback.url, resolvingAgainstBaseURL: false)?.queryItems?.contains {
        $0.name == "body" && $0.value == ""
    } == true)

    #expect(throws: GitHubIssueDraftError.invalidRepositoryURL) {
        try GitHubIssueDraftURLBuilder.issueCreationURL(
            repositoryURL: URL(string: "https://example.com/spudhero/NetVplayer")!
        )
    }
    let gitSuffix = try GitHubIssueDraftURLBuilder.issueCreationURL(
        repositoryURL: URL(string: "https://github.com/spudhero/NetVplayer.git")!
    )
    #expect(gitSuffix.path == "/spudhero/NetVplayer/issues/new")
}
