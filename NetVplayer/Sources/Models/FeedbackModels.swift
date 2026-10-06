// Models/FeedbackModels.swift
// Privacy-preserving feedback report and GitHub handoff contracts.

import CryptoKit
import Foundation

public enum FeedbackCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    case playback
    case source
    case live
    case provider
    case userInterface
    case crash
    case other

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .playback: return L10n.text("播放")
        case .source: return L10n.text("配置源")
        case .live: return L10n.text("直播")
        case .provider: return L10n.text("播放扩展")
        case .userInterface: return L10n.text("界面")
        case .crash: return L10n.text("崩溃")
        case .other: return L10n.text("其他")
        }
    }

    public var failureCategory: AppFailureCategory {
        switch self {
        case .playback, .crash: return .player
        case .source: return .config
        case .live: return .live
        case .provider: return .spider
        case .userInterface: return .ui
        case .other: return .unknown
        }
    }

    public var defaultsToSourceRelated: Bool {
        switch self {
        case .playback, .source, .live, .provider: return true
        case .userInterface, .crash, .other: return false
        }
    }
}

public struct FeedbackDraft: Sendable, Equatable {
    public var category: FeedbackCategory
    public var title: String
    public var problemDescription: String
    public var reproductionSteps: String
    public var expectedResult: String
    public var actualResult: String
    public var isSourceRelated: Bool
    public var publicSourceURL: String
    public var confirmsPublicSource: Bool
    public var includeLogs: Bool

    public init(
        category: FeedbackCategory = .playback,
        title: String = "",
        problemDescription: String = "",
        reproductionSteps: String = "",
        expectedResult: String = "",
        actualResult: String = "",
        isSourceRelated: Bool = true,
        publicSourceURL: String = "",
        confirmsPublicSource: Bool = false,
        includeLogs: Bool = true
    ) {
        self.category = category
        self.title = title
        self.problemDescription = problemDescription
        self.reproductionSteps = reproductionSteps
        self.expectedResult = expectedResult
        self.actualResult = actualResult
        self.isSourceRelated = isSourceRelated
        self.publicSourceURL = publicSourceURL
        self.confirmsPublicSource = confirmsPublicSource
        self.includeLogs = includeLogs
    }
}

public enum FeedbackReproductionLevel: String, Codable, Sendable {
    case generic
    case diagnosticOnly
    case publicSource

    public var title: String {
        switch self {
        case .generic: return L10n.text("通用问题")
        case .diagnosticOnly: return L10n.text("仅诊断资料，真实源未验证")
        case .publicSource: return L10n.text("包含可公开复现源")
        }
    }
}

public struct SourceReproductionContext: Codable, Sendable, Equatable {
    public var configFingerprint: String?
    public var inputKind: String?
    public var adapterID: String?
    public var providerID: String?
    public var providerVersion: String?
    public var siteKeyFingerprint: String?
    public var failureStage: String?
    public var errorCategory: AppFailureCategory?

    public init(
        configFingerprint: String? = nil,
        inputKind: String? = nil,
        adapterID: String? = nil,
        providerID: String? = nil,
        providerVersion: String? = nil,
        siteKeyFingerprint: String? = nil,
        failureStage: String? = nil,
        errorCategory: AppFailureCategory? = nil
    ) {
        self.configFingerprint = configFingerprint
        self.inputKind = inputKind
        self.adapterID = adapterID
        self.providerID = providerID
        self.providerVersion = providerVersion
        self.siteKeyFingerprint = siteKeyFingerprint
        self.failureStage = failureStage
        self.errorCategory = errorCategory
    }

    public var hasSourceEvidence: Bool {
        [configFingerprint, inputKind, adapterID, providerID, siteKeyFingerprint]
            .contains { value in
                value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            }
    }
}

public enum StableFingerprint {
    public static func sha256Prefix(_ value: String, length: Int = 12) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(max(1, min(length, hex.count))))
    }
}

public enum PublicSourceValidationError: Error, LocalizedError, Sendable, Equatable {
    case confirmationRequired
    case invalidURL
    case requiresHTTPS
    case containsCredentials
    case containsFragment
    case containsSensitiveQuery(String)
    case privateHost

    public var errorDescription: String? {
        switch self {
        case .confirmationRequired: return L10n.text("请确认该复现源可以公开访问")
        case .invalidURL: return L10n.text("复现源地址无效")
        case .requiresHTTPS: return L10n.text("复现源必须使用 HTTPS")
        case .containsCredentials: return L10n.text("复现源不能包含用户名或密码")
        case .containsFragment: return L10n.text("复现源不能包含“#”后的页面定位内容")
        case .containsSensitiveQuery(let name): return L10n.text("复现源包含敏感参数：{0}", ["\(name)"])
        case .privateHost: return L10n.text("复现源必须是可公开访问的主机")
        }
    }
}

public enum PublicReproductionSourceValidator {
    private static let sensitiveQueryNames = [
        "token", "access_token", "refresh_token", "cookie", "authorization", "auth",
        "password", "passwd", "secret", "signature", "sign", "auth_key", "api_key",
        "apikey", "key", "ossaccesskeyid", "security-token",
    ]

    public static func validate(_ rawValue: String, confirmed: Bool) throws -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard confirmed else { throw PublicSourceValidationError.confirmationRequired }
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let parsedHost = components.host?.lowercased(),
              !parsedHost.isEmpty else {
            throw PublicSourceValidationError.invalidURL
        }
        let host = parsedHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard scheme == "https" else { throw PublicSourceValidationError.requiresHTTPS }
        guard components.user == nil, components.password == nil else {
            throw PublicSourceValidationError.containsCredentials
        }
        guard components.fragment == nil else { throw PublicSourceValidationError.containsFragment }
        guard !NetworkHostPrivacy.isPrivateOrLocal(host) else {
            throw PublicSourceValidationError.privateHost
        }

        for item in components.queryItems ?? [] {
            let name = item.name.lowercased()
            if isSensitiveQueryName(name) {
                throw PublicSourceValidationError.containsSensitiveQuery(item.name)
            }
        }
        components.scheme = "https"
        components.host = host
        guard let url = components.url else { throw PublicSourceValidationError.invalidURL }
        return url
    }

    private static func isSensitiveQueryName(_ name: String) -> Bool {
        if sensitiveQueryNames.contains(name) { return true }
        let compact = name.filter(\.isLetter)
        if sensitiveQueryNames.contains(compact) { return true }
        return ["token", "secret", "signature", "password", "cookie", "credential"]
            .contains { compact.hasSuffix($0) }
    }
}

public struct FeedbackEnvironment: Sendable, Equatable {
    public var appVersion: String
    public var buildNumber: String
    public var operatingSystem: String
    public var architecture: String
    public var generatedAt: Date
    public var sessionID: String

    public init(
        appVersion: String,
        buildNumber: String,
        operatingSystem: String,
        architecture: String,
        generatedAt: Date = Date(),
        sessionID: String = UUID().uuidString
    ) {
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.operatingSystem = operatingSystem
        self.architecture = architecture
        self.generatedAt = generatedAt
        self.sessionID = sessionID
    }

    public static func current(bundle: Bundle = .main, processInfo: ProcessInfo = .processInfo) -> FeedbackEnvironment {
        let info = bundle.infoDictionary
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif
        return FeedbackEnvironment(
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "dev",
            buildNumber: info?["CFBundleVersion"] as? String ?? "dev",
            operatingSystem: processInfo.operatingSystemVersionString,
            architecture: architecture
        )
    }
}

public enum FeedbackValidationError: Error, LocalizedError, Sendable, Equatable {
    case missingTitle
    case missingProblemDescription

    public var errorDescription: String? {
        switch self {
        case .missingTitle: return L10n.text("请填写问题标题")
        case .missingProblemDescription: return L10n.text("请填写问题现象")
        }
    }
}

public struct FeedbackReport: Sendable, Equatable {
    public static let maximumAttachmentBytes = 2 * 1024 * 1024

    public var issueTitle: String
    public var issueBody: String
    public var automaticContext: String
    public var attachmentText: String
    public var reproductionLevel: FeedbackReproductionLevel
    public var publicSourceURL: URL?

    public init(
        issueTitle: String,
        issueBody: String,
        automaticContext: String = "",
        attachmentText: String,
        reproductionLevel: FeedbackReproductionLevel,
        publicSourceURL: URL?
    ) {
        self.issueTitle = issueTitle
        self.issueBody = issueBody
        self.automaticContext = automaticContext
        self.attachmentText = attachmentText
        self.reproductionLevel = reproductionLevel
        self.publicSourceURL = publicSourceURL
    }
}

public enum FeedbackReportBuilder {
    private static let maximumUserFieldBytes = 12 * 1024
    private static let maximumIssueTitleCharacters = 220

    public static func build(
        draft: FeedbackDraft,
        sourceContext: SourceReproductionContext,
        environment: FeedbackEnvironment,
        diagnosticLogs: String
    ) throws -> FeedbackReport {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let problem = draft.problemDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw FeedbackValidationError.missingTitle }
        guard !problem.isEmpty else { throw FeedbackValidationError.missingProblemDescription }

        let publicSource = draft.isSourceRelated
            ? try PublicReproductionSourceValidator.validate(
                draft.publicSourceURL,
                confirmed: draft.confirmsPublicSource
            )
            : nil
        let reproductionLevel: FeedbackReproductionLevel = if !draft.isSourceRelated {
            .generic
        } else if publicSource != nil {
            .publicSource
        } else {
            .diagnosticOnly
        }

        let effectiveSourceContext = draft.isSourceRelated
            ? sourceContext
            : SourceReproductionContext(
                failureStage: draft.category.failureCategory.rawValue,
                errorCategory: draft.category.failureCategory
            )
        let titleText = safeUserText(title)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let issueTitle = String(
            "[用户反馈][\(draft.category.title)] \(titleText)"
                .prefix(maximumIssueTitleCharacters)
        )
        let automaticContext = automaticContextMarkdown(
            draft: draft,
            sourceContext: effectiveSourceContext,
            environment: environment,
            reproductionLevel: reproductionLevel,
            publicSource: publicSource
        )
        let issueBody = markdownBody(
            draft: draft,
            automaticContext: automaticContext
        )
        let logSection = draft.includeLogs
            ? diagnosticLogs.trimmingCharacters(in: .whitespacesAndNewlines)
            : L10n.text("日志未附带（用户选择）")
        let attachmentPrefix = L10n.text("NetVplayer Feedback Report\nGenerated: {0}\nSession: {1}\n\n{2}\n\n## 脱敏诊断日志", ["\(ISO8601DateFormatter().string(from: environment.generatedAt))", "\(environment.sessionID)", "\(issueBody)"])
        let sanitizedLog = logSection.isEmpty
            ? L10n.text("没有可用的诊断日志")
            : DiagnosticLogSanitizer.sanitize(logSection)
        return FeedbackReport(
            issueTitle: issueTitle,
            issueBody: issueBody,
            automaticContext: automaticContext,
            attachmentText: boundedAttachment(prefix: attachmentPrefix, diagnosticLog: sanitizedLog),
            reproductionLevel: reproductionLevel,
            publicSourceURL: publicSource
        )
    }

    private static func markdownBody(
        draft: FeedbackDraft,
        automaticContext: String
    ) -> String {
        L10n.text("<!-- netvplayer-feedback:v1 -->\n## 问题现象\n{0}\n\n## 复现步骤\n{1}\n\n## 预期结果\n{2}\n\n## 实际结果\n{3}\n\n{4}", ["\(safeUserText(draft.problemDescription))", "\(safeUserText(draft.reproductionSteps, fallback: "未提供"))", "\(safeUserText(draft.expectedResult, fallback: "未提供"))", "\(safeUserText(draft.actualResult, fallback: "未提供"))", "\(automaticContext)"])
    }

    private static func automaticContextMarkdown(
        draft: FeedbackDraft,
        sourceContext: SourceReproductionContext,
        environment: FeedbackEnvironment,
        reproductionLevel: FeedbackReproductionLevel,
        publicSource: URL?
    ) -> String {
        let provider = [sourceContext.providerID, sourceContext.providerVersion]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " @ ")
        return L10n.text("## 复现资料\n- 复现等级：{0}\n- 公开复现源：{1}\n- 配置指纹：{2}\n- 输入类型：{3}\n- 适配器：{4}\n- Provider：{5}\n- 站点键指纹：{6}\n- 最近失败阶段：{7}\n- 最近错误分类：{8}\n- 用户选择分类：{9}\n\n## 运行环境\n- NetVplayer：{10} ({11})\n- macOS：{12}\n- 架构：{13}\n- 会话：{14}\n\n## 验证边界\n{15}", ["\(reproductionLevel.title)", "\(publicSource?.absoluteString ?? "未提供")", "\(sourceContext.configFingerprint ?? "无")", "\(sourceContext.inputKind ?? "无")", "\(sourceContext.adapterID ?? "无")", "\(provider.isEmpty ? "无" : provider)", "\(sourceContext.siteKeyFingerprint ?? "无")", "\(sourceContext.failureStage ?? "无")", "\(sourceContext.errorCategory?.rawValue ?? "无")", "\(draft.category.failureCategory.rawValue)", "\(environment.appVersion)", "\(environment.buildNumber)", "\(environment.operatingSystem)", "\(environment.architecture)", "\(environment.sessionID)", "\(reproductionLevel == .diagnosticOnly ? "代码回归可以验证；真实配置源未提供，真实源修复状态必须保持为未验证。" : "请分别记录自动化回归、打包 App 验证与真实源验证结果。")"])
    }

    private static func safeUserText(_ value: String, fallback: String = "") -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        return utf8Prefix(
            DiagnosticLogSanitizer.sanitize(trimmed),
            maximumBytes: maximumUserFieldBytes
        )
    }

    private static func boundedAttachment(prefix: String, diagnosticLog: String) -> String {
        let complete = prefix + diagnosticLog
        guard complete.utf8.count > FeedbackReport.maximumAttachmentBytes else { return complete }
        let marker = L10n.text("\n[REPORT_TRUNCATED] 日志已按 2 MiB 上限截断。\n")
        let availableLogBytes = max(
            0,
            FeedbackReport.maximumAttachmentBytes - prefix.utf8.count - marker.utf8.count
        )
        var suffix = Data(diagnosticLog.utf8).suffix(availableLogBytes)
        while !suffix.isEmpty, String(data: suffix, encoding: .utf8) == nil {
            suffix = suffix.dropFirst()
        }
        return prefix + marker + (String(data: suffix, encoding: .utf8) ?? "")
    }

    private static func utf8Prefix(_ value: String, maximumBytes: Int) -> String {
        let data = Data(value.utf8)
        guard data.count > maximumBytes else { return value }
        let marker = "..."
        var prefix = data.prefix(max(0, maximumBytes - marker.utf8.count))
        while !prefix.isEmpty, String(data: prefix, encoding: .utf8) == nil {
            prefix = prefix.dropLast()
        }
        return (String(data: prefix, encoding: .utf8) ?? "") + marker
    }
}

public enum GitHubIssueDraftError: Error, LocalizedError, Sendable, Equatable {
    case invalidRepositoryURL

    public var errorDescription: String? { L10n.text("反馈仓库地址无效") }
}

public struct GitHubIssueHandoff: Sendable, Equatable {
    public var url: URL
    public var clipboardText: String
    public var requiresClipboardPaste: Bool

    public init(url: URL, clipboardText: String, requiresClipboardPaste: Bool) {
        self.url = url
        self.clipboardText = clipboardText
        self.requiresClipboardPaste = requiresClipboardPaste
    }
}

public enum GitHubIssueDraftURLBuilder {
    public static let defaultMaximumURLBytes = 6_000

    public static func makeHandoff(
        repositoryURL: URL,
        draft: FeedbackDraft,
        report: FeedbackReport,
        maximumURLBytes: Int = defaultMaximumURLBytes
    ) throws -> GitHubIssueHandoff {
        let baseURL = try issueCreationURL(repositoryURL: repositoryURL)
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = formQueryItems(draft: draft, report: report)
        guard let populatedURL = components.url else { throw GitHubIssueDraftError.invalidRepositoryURL }
        if populatedURL.absoluteString.utf8.count <= maximumURLBytes {
            return GitHubIssueHandoff(
                url: populatedURL,
                clipboardText: report.issueBody,
                requiresClipboardPaste: false
            )
        }

        components.queryItems = [
            URLQueryItem(name: "title", value: report.issueTitle),
            URLQueryItem(name: "body", value: ""),
        ]
        guard let fallbackURL = components.url else { throw GitHubIssueDraftError.invalidRepositoryURL }
        return GitHubIssueHandoff(
            url: fallbackURL,
            clipboardText: report.issueBody,
            requiresClipboardPaste: true
        )
    }

    public static func issueCreationURL(repositoryURL: URL) throws -> URL {
        guard var components = URLComponents(url: repositoryURL, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "github.com",
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw GitHubIssueDraftError.invalidRepositoryURL
        }
        var paths = components.path.split(separator: "/").map(String.init)
        guard paths.count == 2 else { throw GitHubIssueDraftError.invalidRepositoryURL }
        if paths[1].hasSuffix(".git") {
            paths[1].removeLast(4)
        }
        guard !paths[0].isEmpty, !paths[1].isEmpty else {
            throw GitHubIssueDraftError.invalidRepositoryURL
        }
        components.path = "/\(paths[0])/\(paths[1])/issues/new"
        return components.url!
    }

    private static func formQueryItems(draft: FeedbackDraft, report: FeedbackReport) -> [URLQueryItem] {
        [
            URLQueryItem(name: "template", value: "user-feedback.yml"),
            URLQueryItem(name: "title", value: report.issueTitle),
            URLQueryItem(name: "category", value: draft.category.title),
            URLQueryItem(name: "problem", value: DiagnosticLogSanitizer.sanitize(draft.problemDescription)),
            URLQueryItem(name: "steps", value: DiagnosticLogSanitizer.sanitize(draft.reproductionSteps)),
            URLQueryItem(name: "expected", value: DiagnosticLogSanitizer.sanitize(draft.expectedResult)),
            URLQueryItem(name: "actual", value: DiagnosticLogSanitizer.sanitize(draft.actualResult)),
            URLQueryItem(name: "reproduction", value: report.reproductionLevel.title),
            URLQueryItem(name: "public_source", value: report.publicSourceURL?.absoluteString ?? ""),
            URLQueryItem(name: "diagnostics", value: report.automaticContext),
        ]
    }
}
