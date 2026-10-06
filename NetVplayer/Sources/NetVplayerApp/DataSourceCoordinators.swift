import Foundation
import Models
import Networking
import SpiderEngine
import FileServiceEngine
import ConfigEngine
import LiveEngine

/// A scope is captured before suspension, including before a cache invokes its loader.
struct DataSourceRequestScope: Sendable, Equatable {
    let source: String
    let revision: UInt64
    fileprivate let generation: UInt64
}

@MainActor
final class OwnedDataSourceRequests {
    private var generation: UInt64 = 0
    private var cancellations: [UUID: @Sendable () -> Void] = [:]

    func scope(source: String, revision: UInt64 = 0) -> DataSourceRequestScope {
        DataSourceRequestScope(source: source, revision: revision, generation: generation)
    }

    func cancelAll() {
        generation &+= 1
        cancellations.values.forEach { $0() }
        cancellations.removeAll()
    }

    deinit { cancellations.values.forEach { $0() } }

    func run<Value: Sendable>(
        scope: DataSourceRequestScope,
        operation: @escaping @Sendable () async throws -> Value,
        discard: @escaping @Sendable (Value) async -> Void = { _ in }
    ) async throws -> Value {
        try Task.checkCancellation()
        guard scope.generation == generation else { throw CancellationError() }
        let id = UUID()
        let task = Task { try await operation() }
        cancellations[id] = { task.cancel() }
        defer { cancellations[id] = nil }
        let value = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
        guard !Task.isCancelled, !task.isCancelled, scope.generation == generation else {
            await discard(value)
            throw CancellationError()
        }
        return value
    }
}

/// Owns the actual provider tasks; the existing repositories still own cache/coalescing budgets.
@MainActor
final class VodDataSourceCoordinator {
    let requests = OwnedDataSourceRequests()
    private let api: SiteApi
    private var retirement: Task<Void, Never>?

    init(api: SiteApi = .shared) { self.api = api }

    func retire(catalog: CatalogRepository, details: VodDetailRepository = .shared) {
        requests.cancelAll()
        let previous = retirement
        retirement = Task {
            await previous?.value
            await catalog.cancelPending()
            await details.cancelPending()
        }
    }

    func waitForRetirement() async { await retirement?.value }

    func home(site: Site, scope: DataSourceRequestScope) async throws -> Models.Result {
        let api = api
        return try await requests.run(scope: scope) { try await api.homeContent(site: site) }
    }

    func category(site: Site, id: String, page: Int, selection: [String: String], sites: [Site], scope: DataSourceRequestScope) async throws -> Models.Result {
        let api = api
        return try await requests.run(scope: scope) {
            try await api.categoryContent(key: site.key, tid: id, page: String(page), filter: true, extend: selection, sites: sites)
        }
    }

    func detail(site: Site, id: String, sites: [Site], scope: DataSourceRequestScope) async throws -> Models.Result {
        let api = api
        return try await requests.run(scope: scope) { try await api.detailContent(key: site.key, id: id, sites: sites) }
    }

    func playback(site: Site, flag: String, id: String, sites: [Site], scope: DataSourceRequestScope) async throws -> Models.Result {
        let api = api
        return try await requests.run(scope: scope, operation: {
            try await api.playerContent(key: site.key, flag: flag, id: id, sites: sites)
        }, discard: { value in
            if let raw = value.fileResourceLeaseID, let id = UUID(uuidString: raw) {
                await FileServiceRuntime.shared.releasePlayback(leaseID: id)
            }
        })
    }
}

@MainActor
final class LiveDataSourceCoordinator {
    let contentRequests = OwnedDataSourceRequests()
    private let configurationRequests = OwnedDataSourceRequests()

    struct Content: Sendable {
        let groups: [ChannelGroup]
        let attempt: Int
        let status: Int
        let bytes: Int
    }
    enum ContentError: Error { case empty }
    struct TransportError: Error {
        let underlying: Error
        let attempt: Int
    }

    func configuration(url: String, resolver: ConfigResolver) async throws -> LiveConfigurationInput {
        configurationRequests.cancelAll()
        let scope = configurationRequests.scope(source: url)
        return try await configurationRequests.run(scope: scope) {
            let text: String
            if url.hasPrefix("/"), FileManager.default.fileExists(atPath: url) {
                text = try SourceDecoder.decode(String(contentsOfFile: url, encoding: .utf8), url: url)
            } else if let fileURL = URL(string: url), fileURL.isFileURL {
                text = try SourceDecoder.decode(String(contentsOf: fileURL, encoding: .utf8), url: url)
            } else {
                text = try await resolver.load(url: url)
            }
            try Task.checkCancellation()
            return try LiveConfigurationInput.parse(text: text, url: url)
        }
    }

    func content(live: Live, client: HTTPClient, scope: DataSourceRequestScope,
                 nativeGroups: (@Sendable () async throws -> [ChannelGroup])? = nil) async throws -> Content {
        try await contentRequests.run(scope: scope) {
            if live.groups.contains(where: { !$0.channels.isEmpty }) {
                return Content(groups: live.groups, attempt: 0, status: 0, bytes: 0)
            }
            if let nativeGroups {
                let groups = try await nativeGroups()
                guard groups.contains(where: { !$0.channels.isEmpty }) else { throw ContentError.empty }
                return Content(groups: groups, attempt: 0, status: 0, bytes: 0)
            }
            guard !live.url.isEmpty else { throw ContentError.empty }
            let headers = Channel().applying(live: live).requestHeaders
            if live.url.hasPrefix("http") {
                for attempt in 0...1 {
                    try Task.checkCancellation()
                    let requestHeaders = attempt == 0 ? headers : headers.merging([
                        "Cache-Control": "no-cache", "Pragma": "no-cache"
                    ]) { _, new in new }
                    let response: HTTPResponse
                    do {
                        response = try await client.get(url: live.url, headers: requestHeaders, timeout: TimeInterval(max(live.timeout, 1)))
                    } catch {
                        if error is CancellationError { throw error }
                        throw TransportError(underlying: error, attempt: attempt)
                    }
                    try Task.checkCancellation()
                    guard (200..<300).contains(response.statusCode) else { throw ContentError.empty }
                    let groups = LiveParser.parse(text: response.text)
                    if groups.contains(where: { !$0.channels.isEmpty }) {
                        return Content(groups: groups, attempt: attempt, status: response.statusCode, bytes: response.data.count)
                    }
                    guard attempt == 0 else { throw ContentError.empty }
                    DiagnosticLog.write("[LIVE_CONTENT_REFRESH_RETRY] status=\(response.statusCode) bytes=\(response.data.count) reason=empty channel list")
                }
            } else {
                let path = URL(string: live.url).flatMap { $0.isFileURL ? $0.path : nil } ?? live.url
                guard FileManager.default.fileExists(atPath: path) else { throw ContentError.empty }
                let text = try String(contentsOfFile: path, encoding: .utf8)
                let groups = LiveParser.parse(text: text)
                guard groups.contains(where: { !$0.channels.isEmpty }) else { throw ContentError.empty }
                return Content(groups: groups, attempt: 0, status: 0, bytes: text.utf8.count)
            }
            throw ContentError.empty
        }
    }
}
