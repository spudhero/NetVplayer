import Foundation
import Models
@preconcurrency import Sentry

public final class SentryDiagnostics: @unchecked Sendable {
    public static let shared = SentryDiagnostics()
    private let lock = NSRecursiveLock()
    private let defaults: UserDefaults
    private let budget: DiagnosticEventBudget
    private let environment: String
    private var started = false
    private var playbackSpan: (id: UUID, span: any Span)?

    public init(defaults: UserDefaults = .standard, environment: String = "production") {
        self.defaults = defaults
        self.budget = DiagnosticEventBudget(defaults: defaults)
        self.environment = environment
    }

    public var isConfigured: Bool {
        DiagnosticReportingConfiguration.dsn(
            environment: ProcessInfo.processInfo.environment,
            info: Bundle.main.infoDictionary ?? [:]
        ) != nil
    }

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !started, defaults.object(forKey: DiagnosticReportingConfiguration.preferenceKey) as? Bool != false,
              let dsn = DiagnosticReportingConfiguration.dsn(
                environment: ProcessInfo.processInfo.environment, info: Bundle.main.infoDictionary ?? [:]
              ) else { return }
        SentrySDK.start { options in
            Self.configure(options, dsn: dsn, bundle: Bundle.main)
            options.environment = self.environment
        }
        started = SentrySDK.isEnabled
        guard started else { return }
        DiagnosticLog.setRemoteSink { [weak self] record in self?.receive(record) }
    }

    public func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: DiagnosticReportingConfiguration.preferenceKey)
        if enabled { start() } else { stop() }
    }

    /// Synthetic verification only. An event ID and a completed flush do not prove server receipt.
    public func captureVerificationEvent() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard started else { return nil }
        let event = Event(level: .info)
        event.message = SentryMessage(formatted: "SENTRY_VERIFICATION")
        event.environment = "verification"
        event.fingerprint = ["netvplayer", "SENTRY_VERIFICATION"]
        event.tags = ["diagnostic.code": "SENTRY_VERIFICATION"]
        let id = SentrySDK.capture(event: event)
        guard id.sentryIdString != String(repeating: "0", count: 32) else { return nil }
        SentrySDK.flush(timeout: 10)
        return id.sentryIdString
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        DiagnosticLog.setRemoteSink(nil)
        guard started else { return }
        started = false
        playbackSpan?.span.finish(status: .cancelled)
        playbackSpan = nil
        SentrySDK.close()
    }

    static func configure(_ options: Options, dsn: String, bundle: Bundle) {
        options.dsn = dsn
        options.debug = false
        options.sendDefaultPii = false
        options.enableAutoSessionTracking = false
        options.sendClientReports = false
        options.enableUncaughtNSExceptionReporting = true
        options.enableAutoBreadcrumbTracking = false
        options.enableNetworkTracking = false
        options.enableNetworkBreadcrumbs = false
        options.enableCaptureFailedRequests = false
        options.enableFileIOTracing = false
        options.enableCoreDataTracing = false
        options.enableAutoPerformanceTracing = false
        options.enableAppHangTracking = false
        options.enableLogs = false
        options.maxBreadcrumbs = 40
        options.maxCacheItems = 30
        options.tracesSampleRate = NSNumber(value: DiagnosticReportingConfiguration.tracesSampleRate)
        options.environment = "production"
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        options.releaseName = "com.netvplayer.app@\(version)+\(build)"
        options.dist = build
        options.beforeSend = { event in sanitize(event) }
        options.tracePropagationTargets = []
        options.beforeSendSpan = { span in
            guard span.operation == "media.playback.start" else { return nil }
            for key in span.data.keys { span.setData(value: nil, key: key) }
            for key in span.tags.keys { span.removeTag(key: key) }
            span.spanDescription = "playback.start"
            return span
        }
    }

    static func sanitize<T: Event>(_ event: T) -> T {
        event.user = nil
        event.request = nil
        event.extra = nil
        event.serverName = nil
        if let message = event.message {
            let record = RemoteDiagnosticRecord(localMessage: "[\(message.formatted)]")
            event.message = SentryMessage(formatted: record?.code ?? "Application error")
        }
        event.tags = event.tags?.filter { $0.key == "diagnostic.code" }
        let allowedContexts: [String: Set<String>] = [
            "app": ["app_identifier", "app_version", "app_build", "app_start_time", "in_foreground"],
            "os": ["name", "version", "build", "kernel_version"],
            "device": ["family", "model", "model_id", "arch", "memory_size", "free_memory"],
            "runtime": ["name", "version"],
            "trace": ["trace_id", "span_id", "parent_span_id", "op", "status", "origin"],
            "diagnostic": ["status", "code", "errorCode", "attempt", "elapsedMs", "durationMs"],
        ]
        event.context = event.context?.reduce(into: [:]) { result, pair in
            if let allowed = allowedContexts[pair.key] {
                result[pair.key] = pair.value.filter { allowed.contains($0.key) }
            }
        }
        event.breadcrumbs = event.breadcrumbs?.compactMap { breadcrumb in
            guard breadcrumb.category == "diagnostic", let message = breadcrumb.message,
                  let record = RemoteDiagnosticRecord(localMessage: "[\(message)]") else { return nil }
            let safe = Breadcrumb(level: breadcrumb.level, category: "diagnostic")
            safe.message = record.code
            safe.timestamp = breadcrumb.timestamp
            for (key, value) in breadcrumb.data ?? [:] where allowedContexts["diagnostic"]!.contains(key) && value is Int {
                safe.setData(value: value, key: key)
            }
            return safe
        }
        for exception in event.exceptions ?? [] {
            // Exception reason strings may contain paths, URLs or user-controlled media names.
            exception.value = "Exception details omitted; inspect the symbolicated stack trace."
            sanitize(exception.stacktrace)
            exception.mechanism?.data = nil
        }
        for thread in event.threads ?? [] {
            thread.name = nil
            sanitize(thread.stacktrace)
        }
        sanitize(event.stacktrace)
        for image in event.debugMeta ?? [] {
            image.codeFile = image.codeFile.map { ($0 as NSString).lastPathComponent }
        }
        return event
    }

    private static func sanitize(_ stack: SentryStacktrace?) {
        for frame in stack?.frames ?? [] {
            frame.fileName = frame.fileName.map { ($0 as NSString).lastPathComponent }
            frame.package = frame.package.map { ($0 as NSString).lastPathComponent }
            frame.vars = nil
            frame.contextLine = nil
            frame.preContext = nil
            frame.postContext = nil
        }
    }

    private func receive(_ record: RemoteDiagnosticRecord) {
        lock.lock()
        defer { lock.unlock() }
        guard started else { return }
        trackPlayback(record.code)
        let breadcrumb = Breadcrumb(level: record.isError ? .error : .info, category: "diagnostic")
        breadcrumb.message = record.code
        for (key, value) in record.measurements { breadcrumb.setData(value: value, key: key) }
        SentrySDK.addBreadcrumb(breadcrumb)
        guard record.isError, budget.admit(code: record.code) else { return }
        let event = Event(level: .error)
        event.message = SentryMessage(formatted: record.code)
        event.fingerprint = ["netvplayer", record.code]
        event.tags = ["diagnostic.code": record.code]
        event.context = ["diagnostic": record.measurements]
        SentrySDK.capture(event: event)
    }

    private func trackPlayback(_ code: String) {
        if code == "MPV_PLAY" {
            playbackSpan?.span.finish(status: .cancelled)
            let id = UUID()
            playbackSpan = (id, SentrySDK.startTransaction(name: "playback.start", operation: "media.playback.start"))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 120) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                defer { self.lock.unlock() }
                guard self.playbackSpan?.id == id else { return }
                self.playbackSpan?.span.finish(status: .deadlineExceeded)
                self.playbackSpan = nil
            }
        } else if ["MPV_STARTED", "MPV_ERROR", "MPV_DESTROY", "VOD_PLAYER_EXIT"].contains(code) {
            let status: SentrySpanStatus = code == "MPV_STARTED" ? .ok : (code == "MPV_ERROR" ? .internalError : .cancelled)
            playbackSpan?.span.finish(status: status)
            playbackSpan = nil
        }
    }
}
