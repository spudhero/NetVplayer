import Foundation
import Testing
import Models
@testable import Diagnostics
import Sentry

@Suite struct DiagnosticReportingTests {
    @Test func remoteProjectionDoesNotCopyCredentialsOrMediaDetails() throws {
        let record = try #require(RemoteDiagnosticRecord(localMessage:
            "[PROXY_UPSTREAM_ERROR] status=403 url=https://example.com/movie?token=secret Cookie: session=private bodyPrefix={\"password\":\"hunter2\"} title=Private Movie"))
        #expect(record.code == "PROXY_UPSTREAM_ERROR")
        #expect(!record.isError)
        #expect(record.measurements == ["status": 403])
        #expect(RemoteDiagnosticRecord(localMessage: "[MPV_LOG] arbitrary private text") == nil)
        #expect(RemoteDiagnosticRecord(localMessage: "[MPV_PLAY_ERROR_IGNORED] code=1") == nil)
    }

    @Test func recoverablePlaybackFailuresStayBreadcrumbsUntilRecoveryIsExhausted() throws {
        let remoteStream = try #require(RemoteDiagnosticRecord(
            localMessage: "[REMOTE_STREAM_ERROR] errorKind=1 status=503 url=https://private.example/token"
        ))
        let mpv = try #require(RemoteDiagnosticRecord(
            localMessage: "[MPV_ERROR] errorKind=3 private media title"
        ))
        let terminal = try #require(RemoteDiagnosticRecord(
            localMessage: "[PLAYBACK_RECOVERY_FAILED] errorKind=5 provider=1 route=6"
        ))

        #expect(!remoteStream.isError)
        #expect(remoteStream.measurements == ["errorKind": 1, "status": 503])
        #expect(!mpv.isError)
        #expect(mpv.measurements == ["errorKind": 3])
        #expect(terminal.isError)
        #expect(terminal.measurements == ["errorKind": 5, "provider": 1, "route": 6])
        #expect(terminal.fingerprint == [
            "netvplayer", "PLAYBACK_RECOVERY_FAILED", "provider:1", "route:6", "errorKind:5",
        ])
    }

    @Test func upstreamFailuresKeepTheirStatusWithoutConsumingTheTerminalErrorBudget() throws {
        for code in ["PROXY_UPSTREAM_ERROR", "PROXY_UPSTREAM_STREAM_ERROR", "REMOTE_STREAM_UPSTREAM_ERROR"] {
            let record = try #require(RemoteDiagnosticRecord(localMessage: "[\(code)] status=403"))
            #expect(!record.isError)
            #expect(record.measurements == ["status": 403])
        }
        for code in ["PROXY_SERVER_ERROR", "PLAYBACK_RECOVERY_FAILED", "LIVE_CONTENT_RECOVERY_FAILED"] {
            let record = try #require(RemoteDiagnosticRecord(localMessage: "[\(code)] errorKind=4 code=-1005"))
            #expect(record.isError)
            #expect(record.measurements == ["errorKind": 4, "code": -1005])
        }
    }

    @Test func playbackFailuresKeepNumericCauseAndSeparateHTTPStatuses() throws {
        let terminal = try #require(RemoteDiagnosticRecord(localMessage:
            "[PLAYBACK_RECOVERY_FAILED] errorKind=5 provider=2 route=5 failureKind=3 status=403 url=https://private.example/?token=secret"))
        #expect(terminal.measurements == ["errorKind": 5, "provider": 2, "route": 5, "failureKind": 3, "status": 403])
        #expect(terminal.fingerprint == ["netvplayer", "PLAYBACK_RECOVERY_FAILED", "provider:2", "route:5", "errorKind:5", "failureKind:3", "status:403"])
        let other = try #require(RemoteDiagnosticRecord(localMessage:
            "[PLAYBACK_RECOVERY_FAILED] errorKind=5 provider=2 route=5 failureKind=3 status=404"))
        #expect(terminal.fingerprint != other.fingerprint)
        let http = try #require(RemoteDiagnosticRecord(localMessage: "[MPV_HTTP_ERROR] status=403 token=secret"))
        let ended = try #require(RemoteDiagnosticRecord(localMessage: "[MPV_END_FILE] code=4 errorCode=-13"))
        #expect(!http.isError && !ended.isError)
        #expect(http.measurements == ["status": 403])
        #expect(ended.measurements == ["code": 4, "errorCode": -13])
    }

    @Test func developmentBinariesDoNotShareProductionReleaseIdentity() {
        let info: [String: Any] = ["CFBundleShortVersionString": "1.0.12", "CFBundleVersion": "13"]
        var production = info
        production["NetVplayerSentryEnvironment"] = "production"
        let published = DiagnosticReportingConfiguration.identity(info: production)
        #expect(published.environment == "production")
        #expect(published.release == "com.netvplayer.app@1.0.12+13")
        #expect(published.dist == "13")

        var development = info
        development["NetVplayerSentryEnvironment"] = "development"
        development["NetVplayerSentryBuildID"] = "273A3B02-7D82-3AB9-8A6D-BB717027F57D"
        let first = DiagnosticReportingConfiguration.identity(info: development)
        #expect(first.environment == "development")
        #expect(first.release == "com.netvplayer.app@1.0.12-dev+13.273a3b02-7d82-3ab9-8a6d-bb717027f57d")
        #expect(first.dist == "13.273a3b02-7d82-3ab9-8a6d-bb717027f57d")
        development["NetVplayerSentryBuildID"] = "EFDFC73F-E855-302F-8F67-C9B49E3EDAA4"
        #expect(DiagnosticReportingConfiguration.identity(info: development).release != first.release)
        development["NetVplayerSentryBuildID"] = "/Users/private-sentinel"
        #expect(DiagnosticReportingConfiguration.identity(info: development).dist == "13.unpackaged")
    }

    @Test func expectedSourceErrorsDoNotCreateIssuesAndDriveAPIErrorsKeepSafeDimensions() throws {
        let expected = try #require(RemoteDiagnosticRecord(
            localMessage: "[CATALOG_LOAD_FAILED] errorCode=1 errorKind=1 expected=1"
        ))
        let driveAPI = try #require(RemoteDiagnosticRecord(
            localMessage: "[PLAYBACK_PREPARE_FAILED] attempt=1 errorCode=6 errorKind=2 expected=0 provider=1 status=503 code=429"
        ))

        #expect(!expected.isError)
        #expect(expected.measurements == ["errorCode": 1, "errorKind": 1, "expected": 1])
        #expect(driveAPI.isError)
        #expect(driveAPI.measurements == [
            "errorCode": 6,
            "errorKind": 2,
            "expected": 0,
            "provider": 1,
            "status": 503,
            "code": 429,
            "attempt": 1,
        ])
        #expect(driveAPI.fingerprint == [
            "netvplayer", "PLAYBACK_PREPARE_FAILED", "errorKind:2", "provider:1",
            "status:503", "code:429", "errorCode:6",
        ])
    }

    @Test func unavailableLiveCatalogStaysABreadcrumbWithEnoughSafeContext() throws {
        let record = try #require(RemoteDiagnosticRecord(
            localMessage: "[LIVE_CONTENT_REFRESH_FAILED] errorKind=3 attempt=1 bytes=561 status=200 source=Private Source"
        ))

        #expect(!record.isError)
        #expect(record.measurements == [
            "attempt": 1,
            "bytes": 561,
            "errorKind": 3,
            "status": 200,
        ])
    }

    @Test func quotaSurvivesRestartAndResetsOnNextDay() throws {
        let name = "DiagnosticReportingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let budget = DiagnosticEventBudget(defaults: defaults, dailyLimit: 2)
        #expect(budget.admit(code: "MPV_ERROR", now: now))
        #expect(!budget.admit(code: "MPV_ERROR", now: now.addingTimeInterval(60)))
        #expect(budget.admit(code: "CONFIG_LOAD_FAILED", now: now))
        let restarted = DiagnosticEventBudget(defaults: defaults, dailyLimit: 2)
        #expect(!restarted.admit(code: "MPV_ERROR", now: now.addingTimeInterval(600)))
        #expect(restarted.admit(code: "MPV_ERROR", now: now.addingTimeInterval(86_400)))
    }

    @Test func missingOrUnsafeConfigurationStaysDisabled() {
        #expect(DiagnosticReportingConfiguration.dsn(environment: [:], info: [:]) == nil)
        #expect(DiagnosticReportingConfiguration.dsn(environment: ["NETVPLAYER_SENTRY_DSN": "https://abc@o1.ingest.us.sentry.io/123"], info: [:]) != nil)
        for value in ["http://abc@o1.ingest.us.sentry.io/123", "https://abc:secret@o1.ingest.us.sentry.io/123", "https://abc@example.com/123", "https://abc@o1.ingest.us.sentry.io/not-a-project"] {
            #expect(DiagnosticReportingConfiguration.dsn(environment: ["NETVPLAYER_SENTRY_DSN": value], info: [:]) == nil)
        }
    }

    @Test func sdkOptionsDisableAutomaticSensitiveCapture() {
        let options = Options()
        SentryDiagnostics.configure(options, dsn: "https://abc@o1.ingest.us.sentry.io/123", bundle: .main)
        #expect(!options.sendDefaultPii)
        #expect(!options.enableAutoBreadcrumbTracking)
        #expect(!options.enableNetworkTracking)
        #expect(!options.enableNetworkBreadcrumbs)
        #expect(!options.enableLogs)
        #expect(options.enableUncaughtNSExceptionReporting)
        #expect(options.tracesSampleRate?.doubleValue == 0.05)
    }

    @Test func crashPayloadRetainsStackAddressesButDropsPrivateData() throws {
        let event = Event(level: .fatal)
        let user = User()
        user.email = "private-sentinel@example.com"
        event.user = user
        event.extra = ["token": "private-sentinel"]
        event.context = ["device": ["name": "private-sentinel", "arch": "arm64"], "private": ["token": "private-sentinel"]]
        let exception = Exception(value: "private-sentinel", type: "NSException")
        let frame = Frame()
        frame.package = "/Users/private-sentinel/NetVplayerApp"
        frame.instructionAddress = "0x1234"
        frame.vars = ["token": "private-sentinel"]
        exception.stacktrace = SentryStacktrace(frames: [frame], registers: [:])
        event.exceptions = [exception]
        let unsafeBreadcrumb = Breadcrumb(level: .info, category: "http")
        unsafeBreadcrumb.message = "private-sentinel"
        event.breadcrumbs = [unsafeBreadcrumb]
        let result = SentryDiagnostics.sanitize(event)
        let data = try JSONSerialization.data(withJSONObject: result.serialize())
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("private-sentinel"))
        #expect(json.contains("0x1234"))
        #expect(json.contains("arm64"))
        #expect(result.user == nil)
    }

    @Test func sanitizerKeepsOnlyApprovedNumericDiagnosticDimensions() throws {
        let event = Event(level: .error)
        event.message = SentryMessage(formatted: "PLAYBACK_RECOVERY_FAILED")
        event.context = [
            "diagnostic": [
                "errorKind": 5,
                "provider": 2,
                "route": 6,
                "bytes": 1024,
                "private": "private-sentinel",
            ],
        ]
        let breadcrumb = Breadcrumb(level: .error, category: "diagnostic")
        breadcrumb.message = "PLAYBACK_RECOVERY_FAILED"
        for (key, value) in ["errorKind": 5, "provider": 2, "route": 6, "bytes": 1024] {
            breadcrumb.setData(value: value, key: key)
        }
        breadcrumb.setData(value: "private-sentinel", key: "private")
        event.breadcrumbs = [breadcrumb]

        let result = SentryDiagnostics.sanitize(event)
        let data = try JSONSerialization.data(withJSONObject: result.serialize())
        let json = String(decoding: data, as: UTF8.self)

        for key in ["errorKind", "provider", "route", "bytes"] {
            #expect(json.contains(key))
        }
        #expect(!json.contains("private-sentinel"))
        #expect(!json.contains("\"private\""))
    }
}
