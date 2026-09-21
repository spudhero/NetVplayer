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
        #expect(record.isError)
        #expect(record.measurements == ["status": 403])
        #expect(RemoteDiagnosticRecord(localMessage: "[MPV_LOG] arbitrary private text") == nil)
        #expect(RemoteDiagnosticRecord(localMessage: "[MPV_PLAY_ERROR_IGNORED] code=1") == nil)
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
}
