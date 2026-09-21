import Foundation
import Testing
import DriveEngine
import Models
import Networking
import SpiderEngine
@testable import NetVplayerApp

@Test func userFacingErrorPresenterExplainsProblemAndNextStep() {
    let configMessage = UserFacingErrorPresenter.message(
        for: HTTPError.httpError(503, "upstream unavailable"),
        context: .configuration
    )
    #expect(configMessage.contains("服务暂时异常"))
    #expect(configMessage.contains("检查配置地址和网络"))

    let invalidRequestMessage = UserFacingErrorPresenter.message(
        for: HTTPError.invalidURL("invalid"),
        context: .webContent
    )
    #expect(invalidRequestMessage == "请求地址格式不正确。请检查地址和网络后重试。")

    let authorizationMessage = UserFacingErrorPresenter.message(
        for: URLError(.notConnectedToInternet),
        context: .authorization(providerName: DriveProvider.quark.displayName)
    )
    #expect(authorizationMessage.contains("没有可用的网络连接"))
    #expect(authorizationMessage.contains("刷新登录页面"))

    let unsupportedMessage = UserFacingErrorPresenter.message(
        for: SpiderEngineError.unsupportedAndroidCrawler(api: "csp_Example"),
        context: .content(sourceName: "示例源")
    )
    #expect(unsupportedMessage == "该视频源使用的格式当前无法加载。请稍后重试或切换其他视频源。")

    let cancelledMessage = UserFacingErrorPresenter.message(
        for: CancellationError(),
        context: .update
    )
    #expect(cancelledMessage == "操作已取消。")
}

@Test func userFacingErrorPresenterDoesNotExposeImplementationTerms() {
    let messages = [
        UserFacingErrorPresenter.message(
            for: SpiderEngineError.unsupportedAndroidCrawler(api: "csp_Example"),
            context: .content(sourceName: "示例源")
        ),
        UserFacingErrorPresenter.message(
            for: DriveEngineError.api(provider: .uc, statusCode: 403, code: 1, message: "token invalid"),
            context: .playback
        ),
        UserFacingErrorPresenter.playbackMessage(from: "mpv playback failed: unrecognized file format"),
    ]
    let implementationTerms = ["Android", "csp_", "Dex", "Jar", "Fongmi", "Provider", "mpv", "WebView", "Live:"]

    for message in messages {
        #expect(!implementationTerms.contains { message.localizedCaseInsensitiveContains($0) })
    }
}

@Test func compatibilityStatusPresentationUsesProductLanguage() {
    #expect(ExternalSourceSupportStatus.unsupportedAndroidCsp.userFacingTitle == "暂不支持")
    #expect(ExternalSourceSupportStatus.pendingGuardCapture.userFacingTitle == "正在适配")
    #expect(ExternalResourceDiagnosticStatus.androidRuntimeOnly.userFacingTitle == "格式不兼容")

    let copy = [
        ExternalSourceSupportStatus.unsupportedAndroidCsp.userFacingDetail,
        ExternalSourceSupportStatus.pendingGuardCapture.userFacingDetail,
    ].joined(separator: " ")
    #expect(!copy.contains("Android"))
    #expect(!copy.contains("抓包"))
}

@Test func playbackDiagnosticsExplainTheFailureWithoutCopyingPrivateDetails() {
    let cases: [(diagnostic: String, expected: String)] = [
        ("HTTP 401 Unauthorized", "播放地址已失效或需要重新授权。请重新打开内容，必要时完成授权后重试。"),
        ("HTTP 403 Forbidden", "播放地址已失效或需要重新授权。请重新打开内容，必要时完成授权后重试。"),
        ("Signature expired", "播放地址已失效或需要重新授权。请重新打开内容，必要时完成授权后重试。"),
        ("HTTP 404 Not Found", "播放地址已失效或内容已下线。请切换线路或视频源。"),
        ("Connection timed out", "连接播放线路失败。请检查网络后重试，或切换其他线路。"),
        ("TLS handshake failed", "连接播放线路失败。请检查网络后重试，或切换其他线路。"),
        ("Connection reset by peer", "连接播放线路失败。请检查网络后重试，或切换其他线路。"),
        ("Unrecognized file format", "当前内容的格式暂不受支持。请切换线路或视频源。"),
        ("Decoder unavailable", "当前内容的格式暂不受支持。请切换线路或视频源。"),
        ("HTTP 500 Internal Server Error", "视频服务暂时异常。请稍后重试或切换其他线路。"),
        ("HTTP 502 Bad Gateway", "视频服务暂时异常。请稍后重试或切换其他线路。"),
        ("HTTP 503 Service Unavailable", "视频服务暂时异常。请稍后重试或切换其他线路。"),
        ("HTTP 504 Gateway Timeout", "连接播放线路失败。请检查网络后重试，或切换其他线路。"),
        ("Cannot open input", "当前内容暂时无法播放。请重试或切换线路、视频源。"),
    ]
    for item in cases {
        let rawMessage = "mpv: \(item.diagnostic); url=https://media.example.test/movie?token=private-sentinel"
        let message = UserFacingErrorPresenter.playbackMessage(from: rawMessage)
        #expect(message == item.expected)
        #expect(!message.contains("private-sentinel"))
        #expect(!message.contains("media.example.test"))
    }
}

@Test func httpFailuresDistinguishAuthorizationMissingContentLimitsAndServerErrors() {
    let cases: [(status: Int, expected: String)] = [
        (401, "服务拒绝访问，登录状态可能已失效。"),
        (403, "服务拒绝访问，登录状态可能已失效。"),
        (404, "请求的内容已不存在。"),
        (410, "请求的内容已不存在。"),
        (408, "连接服务超时。"),
        (429, "请求过于频繁，服务暂时限制访问。"),
        (500, "服务暂时异常（错误码 500）。"),
        (503, "服务暂时异常（错误码 503）。"),
        (599, "服务暂时异常（错误码 599）。"),
        (418, "服务返回异常（错误码 418）。"),
    ]
    for item in cases {
        let presentation = UserFacingErrorPresenter.presentation(
            for: HTTPError.httpError(item.status, "private-sentinel: Cookie=session-secret"),
            context: .content(sourceName: "示例源")
        )
        #expect(presentation.message == item.expected)
        #expect(presentation.combinedMessage == item.expected + "请稍后重试或切换其他视频源。")
        #expect(!presentation.combinedMessage.contains("private-sentinel"))
    }
}

@Test func networkFailuresDistinguishOfflineTimeoutHostAndCertificateProblems() {
    let cases: [(code: URLError.Code, expected: String)] = [
        (.notConnectedToInternet, "当前没有可用的网络连接。"),
        (.networkConnectionLost, "当前没有可用的网络连接。"),
        (.timedOut, "连接超时。"),
        (.cannotFindHost, "无法连接到服务地址。"),
        (.dnsLookupFailed, "无法连接到服务地址。"),
        (.cannotConnectToHost, "无法连接到服务地址。"),
        (.secureConnectionFailed, "无法与服务建立安全连接。"),
        (.serverCertificateUntrusted, "无法与服务建立安全连接。"),
        (.serverCertificateHasBadDate, "无法与服务建立安全连接。"),
        (.clientCertificateRequired, "无法与服务建立安全连接。"),
        (.badServerResponse, "网络请求未能完成。"),
    ]
    for item in cases {
        let presentation = UserFacingErrorPresenter.presentation(
            for: URLError(item.code),
            context: .webContent
        )
        #expect(presentation.message == item.expected)
        #expect(presentation.combinedMessage == item.expected + "请检查地址和网络后重试。")
    }
}

@Test func unknownErrorsUseContextWithoutDisplayingSensitiveLocalizedDescriptions() {
    let error = NSError(
        domain: "PrivateImplementationError",
        code: 123,
        userInfo: [NSLocalizedDescriptionKey: "Android Provider token=private-sentinel /Users/private-user/config.json"]
    )
    let cases: [(context: UserFacingErrorContext, expected: String)] = [
        (.configuration, "点播源未能加载。请检查配置地址和网络后重试。"),
        (.content(sourceName: " 示例源 "), "视频源“示例源”暂时无法加载。请稍后重试或切换其他视频源。"),
        (.content(sourceName: "  "), "当前视频源暂时无法加载。请稍后重试或切换其他视频源。"),
        (.playback, "当前内容暂时无法播放。请重试或切换线路、视频源。"),
        (.live(channelName: "测试频道", lineNumber: 2), "频道“测试频道”的线路 2 暂时无法播放。请重试或切换其他线路、频道。"),
        (.authorization(providerName: "夸克"), "夸克授权未完成。请检查网络后刷新登录页面并重试。"),
        (.storage(operation: "导入备份"), "导入备份未完成。请检查文件权限和可用存储空间后重试。"),
        (.extensionOperation(operation: "安装播放扩展"), "安装播放扩展未完成。请检查网络后重试；已安装的扩展仍可继续使用。"),
        (.feedback(operation: "导出反馈"), "导出反馈未完成。请检查填写内容后重试。"),
        (.update, "应用更新未完成。请检查网络后重新检查更新。"),
        (.webContent, "页面未能加载。请检查地址和网络后重试。"),
    ]
    for item in cases {
        let message = UserFacingErrorPresenter.message(for: error, context: item.context)
        #expect(message == item.expected)
        #expect(!message.contains("private-sentinel"))
        #expect(!message.contains("/Users/"))
        #expect(!message.contains("Android"))
        #expect(!message.contains("Provider"))
    }
}

@Test func bridgedURLCancellationDoesNotSuggestRetryingButOtherDomainsRemainFailures() {
    let userInfo = [NSLocalizedDescriptionKey: "private-sentinel"]
    let cancelled = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled, userInfo: userInfo)
    let presentation = UserFacingErrorPresenter.presentation(for: cancelled, context: .update)
    #expect(presentation.message == "操作已取消。")
    #expect(presentation.recoverySuggestion.isEmpty)
    #expect(presentation.combinedMessage == "操作已取消。")

    let unrelatedError = NSError(domain: "OtherErrorDomain", code: NSURLErrorCancelled, userInfo: userInfo)
    #expect(UserFacingErrorPresenter.message(for: unrelatedError, context: .update)
        == "应用更新未完成。请检查网络后重新检查更新。")
}

@Test func recoverySuggestionsAvoidDuplicateActionsWithoutMistakingRequestForAnInstruction() {
    for message in [
        "请先选择一个子配置。",
        "授权已过期。请重新授权。",
        "授权已过期；请重新授权。",
        "授权已过期，请重新授权。",
    ] {
        let presentation = UserFacingErrorPresentation(message: message, recoverySuggestion: "请稍后重试。")
        #expect(presentation.combinedMessage == message)
    }

    let alreadyIncluded = UserFacingErrorPresentation(
        message: "连接失败。请稍后重试。",
        recoverySuggestion: "请稍后重试。"
    )
    #expect(alreadyIncluded.combinedMessage == "连接失败。请稍后重试。")

    let requestFailure = UserFacingErrorPresentation(
        message: "  请求地址格式不正确。\n",
        recoverySuggestion: " 请检查地址和网络后重试。 "
    )
    #expect(requestFailure.combinedMessage == "请求地址格式不正确。请检查地址和网络后重试。")
    #expect(UserFacingErrorPresentation(message: " 操作已取消。 ", recoverySuggestion: " \n ").combinedMessage
        == "操作已取消。")
}

@Test func legacyCompatibilityReportIgnoresRemovedRuntimeDiagnosticAndPreservesSupportedFields() throws {
    let legacyJSON = Data("""
        {
          "configLocation": "fixture://legacy-config",
          "siteKey": "legacy-source",
          "siteName": "旧视频源",
          "api": "csp_Example",
          "status": "unsupported-android-csp",
          "reason": "该来源使用的格式当前无法加载",
          "suggestion": "请切换其他视频源",
          "androidRuntimeDiagnostic": "obsolete-runtime-diagnostic"
        }
        """.utf8)
    let report = try JSONDecoder().decode(ExternalSourceReport.self, from: legacyJSON)
    #expect(report.configLocation == "fixture://legacy-config")
    #expect(report.siteKey == "legacy-source")
    #expect(report.siteName == "旧视频源")
    #expect(report.api == "csp_Example")
    #expect(report.status == .unsupportedAndroidCsp)
    #expect(report.status.userFacingTitle == "暂不支持")
    #expect(report.reason == "该来源使用的格式当前无法加载")
    #expect(report.suggestion == "请切换其他视频源")
    #expect(report.normalizationEvents.isEmpty)
    #expect(report.resourceDiagnostics.isEmpty)

    let encoded = try JSONEncoder().encode(report)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(object["androidRuntimeDiagnostic"] == nil)
    #expect(object["status"] as? String == "unsupported-android-csp")
    #expect(try JSONDecoder().decode(ExternalSourceReport.self, from: encoded) == report)
}
