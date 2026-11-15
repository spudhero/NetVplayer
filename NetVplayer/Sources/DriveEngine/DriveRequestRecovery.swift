import Foundation
import Models
import Networking

/// One operation owns the deadline and the two transport retries. Pagination,
/// confirmation polling, credential refresh and candidate reads inherit it.
public enum DriveRequestRecovery {
    @TaskLocal static var budget: DriveReadBudget?
    @TaskLocal static var transferAttempt: DriveTransferAttempt?
    @TaskLocal static var background = false
    @TaskLocal static var accountGate = DriveAccountRequestGate()

    public static func withBudget<T: Sendable>(background: Bool = false,
        operation: @Sendable () async throws -> T) async throws -> T {
        if budget != nil { return try await operation() }
        return try await $background.withValue(background) {
            try await $budget.withValue(DriveReadBudget()) { try await operation() }
        }
    }

    public static func withAccountOperation<T: Sendable>(credential: CloudCredential,
        operation: @Sendable () async throws -> T) async throws -> T {
        let key = DriveTransferContext.digest([credential.provider.rawValue, credential.secret,
            credential.refreshToken ?? "", credential.accessToken ?? "", DriveTransferContext.current.revision, "resolve"])
        try await DriveTransferContext.current.check()
        if background, let blocked = await accountGate.failure(for: key) { throw blocked }
        do {
            let result = try await operation()
            try await DriveTransferContext.current.check()
            if !background { await accountGate.clear(key) }
            return result
        } catch {
            try await DriveTransferContext.current.check()
            if let failure = error as? DriveServiceFailure { await accountGate.record(failure, key: key) }
            throw error
        }
    }
}

actor DriveReadBudget {
    let deadline: ContinuousClock.Instant
    private var retries = 0
    private let maximumRetries: Int
    private var stopped: [String: DriveServiceFailure] = [:]
    private var refreshed = Set<DriveProvider>()

    init(seconds: Double = 30, maximumRetries: Int = 2) {
        deadline = .now.advanced(by: .seconds(seconds))
        self.maximumRetries = maximumRetries
    }

    var availableRetries: Int { max(0, maximumRetries - retries) }

    func remaining(maximum: TimeInterval) -> TimeInterval {
        let end = min(deadline, DriveTransferContext.confirmationDeadline ?? deadline)
        let value = ContinuousClock.now.duration(to: end).components
        return min(maximum, Double(value.seconds) + Double(value.attoseconds) / 1e18)
    }

    func retryDelay(for failure: DriveServiceFailure) async throws -> TimeInterval? {
        guard retries < maximumRetries else { return nil }
        let delay = max(failure.retryAfter ?? 0, 0.25 * pow(2, Double(retries)))
        guard delay < remaining(maximum: .greatestFiniteMagnitude) else { return nil }
        retries += 1
        try await DriveRequestRecovery.transferAttempt?.consumeRetry()
        return delay
    }
    func failure(for key: String) -> DriveServiceFailure? { stopped[key] }
    func stop(_ failure: DriveServiceFailure, key: String) {
        if failure.pausesAccountOperation || [.rateLimited, .temporaryNetwork].contains(failure.reason) {
            stopped[key] = failure
        }
    }
    func claimCredentialRefresh(_ provider: DriveProvider) -> Bool { refreshed.insert(provider).inserted }
}

actor DriveAccountRequestGate {
    private var blocked: [String: DriveServiceFailure] = [:]
    func failure(for key: String) -> DriveServiceFailure? { blocked[key] }
    func record(_ failure: DriveServiceFailure, key: String) {
        guard failure.pausesAccountOperation else { return }
        // Only opaque scopes are retained, and this is not a persistent queue.
        if blocked.count >= 256, blocked[key] == nil { blocked.removeValue(forKey: blocked.keys.sorted().first!) }
        blocked[key] = failure
    }
    func clear(_ key: String) { blocked[key] = nil }
}

/// The existing HTTP transport still owns cookies and routing. This adapter is
/// the sole automatic retry owner for drive API requests; transparent proxy
/// fallback is disabled so it cannot multiply the attempts or replay writes.
final class DriveHTTPClient: Sendable {
    let base: HTTPClient
    let provider: DriveProvider
    init(_ base: HTTPClient, provider: DriveProvider) { self.base = base; self.provider = provider }

    // Keep HTTPClient-compatible labels; drive requests always disable fallback and redact URLs.
    func get(url: String, headers: [String: String] = [:], timeout: TimeInterval = 15,
             allowsProxyFallback _: Bool = true, redactsURLInLogs _: Bool = false) async throws -> HTTPResponse {
        try await request(url: url, headers: headers, timeout: timeout)
    }
    func post(url: String, headers: [String: String] = [:], body: Data? = nil, timeout: TimeInterval = 15,
              handlesCookies: Bool = true, allowsProxyFallback _: Bool = true,
              redactsURLInLogs _: Bool = false) async throws -> HTTPResponse {
        try await request(url: url, method: .post, headers: headers, body: body,
                          timeout: timeout, handlesCookies: handlesCookies)
    }
    func request(url: String, method: HTTPMethod = .get, headers: [String: String] = [:], body: Data? = nil,
                 timeout: TimeInterval = 15, allowsProxyFallback _: Bool = true, redactsURLInLogs _: Bool = false,
                 handlesCookies: Bool = true) async throws -> HTTPResponse {
        try await perform(url: url, method: method, headers: headers, timeout: timeout) { [base] remaining in
            try await base.request(url: url, method: method, headers: headers, body: body,
                timeout: remaining, allowsProxyFallback: false, redactsURLInLogs: true, handlesCookies: handlesCookies)
        }
    }

    func perform(url: String, method: HTTPMethod = .get, headers: [String: String], timeout: TimeInterval,
                 transport: @escaping @Sendable (TimeInterval) async throws -> HTTPResponse) async throws -> HTTPResponse {
        let operation = DriveFailureClassifier.operation(provider: provider, url: url, method: method)
        let budget = DriveRequestRecovery.budget ?? DriveReadBudget(seconds: min(30, timeout))
        let cookie = headers.first { $0.key.caseInsensitiveCompare("Cookie") == .orderedSame }?.value ?? ""
        let token = headers.first { $0.key.caseInsensitiveCompare("Authorization") == .orderedSame }?.value
            ?? URLComponents(string: url)?.queryItems?.first { $0.name == "access_token" }?.value ?? ""
        let account = cookie.isEmpty ? token : DriveTransferContext.account(provider: provider, cookie: cookie)
        let scope = account.isEmpty ? nil : DriveTransferContext.digest([
            provider.rawValue, account, cookie, token, DriveTransferContext.current.revision, operation.rawValue
        ])
        while true {
            try await DriveTransferContext.current.check()
            if let scope {
                if let stopped = await budget.failure(for: scope) { throw stopped }
                if DriveRequestRecovery.background, let blocked = await DriveRequestRecovery.accountGate.failure(for: scope) { throw blocked }
            }
            let remaining = await budget.remaining(maximum: timeout)
            guard remaining > 0 else {
                throw DriveServiceFailure(provider: provider, reason: .temporaryNetwork, operation: operation)
            }
            do {
                let response = try await withThrowingTaskGroup(of: HTTPResponse.self) { group in
                    group.addTask { try await transport(remaining) }
                    group.addTask {
                        try await Task.sleep(for: .seconds(remaining))
                        throw URLError(.timedOut)
                    }
                    defer { group.cancelAll() }
                    return try await group.next()!
                }
                try await DriveTransferContext.current.check()
                guard await budget.remaining(maximum: timeout) > 0 else { throw URLError(.timedOut) }
                if let failure = DriveFailureClassifier.response(response, provider: provider, operation: operation,
                    path: URL(string: url)?.path ?? "", hasFileIdentity:
                        URLComponents(string: url)?.queryItems?.contains { $0.name == "fs_id" && $0.value?.isEmpty == false } == true) { throw failure }
                if let scope {
                    if let stopped = await budget.failure(for: scope) { throw stopped }
                    // A concurrent background success must not undo an account
                    // pause. Only an explicit foreground retry can clear it.
                    if !DriveRequestRecovery.background { await DriveRequestRecovery.accountGate.clear(scope) }
                }
                return response
            } catch {
                try await DriveTransferContext.current.check()
                if (error as? URLError)?.code == .cancelled { throw CancellationError() }
                let failure: DriveServiceFailure
                if let classified = error as? DriveServiceFailure { failure = classified }
                else if let network = error as? URLError,
                        [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotFindHost,
                         .cannotConnectToHost, .dnsLookupFailed].contains(network.code) {
                    failure = DriveServiceFailure(provider: provider, reason: .temporaryNetwork, operation: operation)
                } else { throw error }
                if operation.isRead, [.rateLimited, .temporaryNetwork].contains(failure.reason),
                   let delay = try await budget.retryDelay(for: failure) {
                    try await Task.sleep(for: .seconds(delay))
                    continue
                }
                if let scope {
                    await budget.stop(failure, key: scope)
                    await DriveRequestRecovery.accountGate.record(failure, key: scope)
                }
                throw failure
            }
        }
    }

    func setCookie(name: String, value: String, for url: String) -> Bool { base.setCookie(name: name, value: value, for: url) }
    func cookieValue(name: String, for url: String) -> String? { base.cookieValue(name: name, for: url) }
    func cookieHeader(for url: String) -> String? { base.cookieHeader(for: url) }
    func removeCookie(name: String, for url: String) { base.removeCookie(name: name, for: url) }
}
