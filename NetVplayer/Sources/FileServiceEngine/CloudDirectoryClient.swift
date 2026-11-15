import Foundation
import Models
import Storage
import Networking
import DriveEngine

/// Presents a personal cloud account through the same read-only interface as NAS directories.
/// Logical paths contain names; provider file identifiers and expiring URLs stay inside this client.
public actor CloudDirectoryClient: FileServiceClient {
    typealias Listing = @Sendable (String, String, String?, CloudCredential) async throws -> CloudDirectoryPage
    typealias Download = @Sendable (CloudDirectoryEntry, CloudCredential) async throws -> CloudDriveLink
    private let configuration: FileServiceConfiguration
    private let binding: CloudDirectoryBinding
    private let preferences: UserPreferences
    private let listing: Listing
    private let download: Download
    private let transport: FileHTTPTransport
    private var entries: [String: CloudDirectoryEntry] = [:]
    private var links: [String: (resource: ResolvedFileResource, expires: Date)] = [:]
    private struct Cursor: Codable { let id: UUID; let path: String; let upstream: String }
    private struct Enumeration {
        var names: [String: String] = [:]
        var cursors = Set<String>()
        var updated = Date()
    }
    private var enumerations: [UUID: Enumeration] = [:]
    private var closed = false

    public init(configuration: FileServiceConfiguration, preferences: UserPreferences = .shared,
                httpClient: HTTPClient = .shared) throws {
        let backend = PersonalCloudDirectoryClient(httpClient: httpClient)
        try self.init(configuration: configuration, preferences: preferences,
                      listing: { try await backend.list(folderID: $0, driveID: $1, cursor: $2, credential: $3) },
                      download: { try await backend.download(entry: $0, credential: $1) }, transport: .init())
    }

    init(configuration: FileServiceConfiguration, preferences: UserPreferences,
         listing: @escaping Listing, download: @escaping Download, transport: FileHTTPTransport) throws {
        let configuration = try configuration.validated()
        guard configuration.kind == .cloudDrive, let binding = configuration.cloudDirectory else {
            throw FileServiceError.invalidConfiguration("请重新选择已登录的网盘账号")
        }
        self.configuration = configuration; self.binding = binding; self.preferences = preferences
        self.listing = listing; self.download = download; self.transport = transport
    }

    public func connect() async throws { _ = try await list(path: "/", cursor: nil) }

    public func list(path: String, cursor: String?) async throws -> FileEntryPage {
        let path = try FileServicePath.normalize(path)
        let full = try FileServicePath.join(configuration.rootPath, path)
        let parent = try await lookup(full)
        guard parent.isDirectory else { throw FileServiceError.path(path) }
        let id: UUID, upstream: String?
        var enumeration: Enumeration
        if let cursor {
            guard let data = Data(base64Encoded: cursor), let value = try? JSONDecoder().decode(Cursor.self, from: data),
                  value.path == full, let saved = enumerations.removeValue(forKey: value.id),
                  saved.updated.timeIntervalSinceNow > -600 else {
                throw FileServiceError.protocolFailure("无效的网盘分页标识")
            }
            id = value.id; upstream = value.upstream; enumeration = saved
        } else {
            enumerations = enumerations.filter { $0.value.updated.timeIntervalSinceNow > -600 }
            guard enumerations.count < 64 else { throw FileServiceError.protocolFailure("网盘目录读取过多，请稍后重试") }
            id = UUID(); upstream = nil; enumeration = .init()
            // A new enumeration must not compare new file IDs against a previous scan's cache.
            let prefix = full == "/" ? "/" : full + "/"
            entries = entries.filter { $0.key == full || !$0.key.hasPrefix(prefix) }
        }
        let page = try await fetch(parent, cursor: upstream)
        var result: [FileEntry] = [], seen = Set<String>()
        for child in page.entries {
            try validateName(child.name)
            guard seen.insert(child.name).inserted else {
                throw FileServiceError.protocolFailure("网盘目录返回了重复的文件名")
            }
            let childPath = try FileServicePath.join(full, child.name)
            if let existing = enumeration.names[child.name], existing != child.id {
                throw FileServiceError.protocolFailure("网盘分页返回了冲突的文件名")
            }
            enumeration.names[child.name] = child.id
            entries[childPath] = child
            result.append(fileEntry(child, path: try FileServicePath.join(path, child.name)))
        }
        if full == "/", !page.driveID.isEmpty {
            entries["/"] = .init(id: parent.id, name: parent.name, driveID: page.driveID, isDirectory: true)
        }
        var next: String?
        if let upstream = page.nextCursor {
            guard enumeration.cursors.insert(upstream).inserted, !page.entries.isEmpty else {
                throw FileServiceError.protocolFailure("服务分页未向前推进，未完成目录读取")
            }
            enumeration.updated = Date(); enumerations[id] = enumeration
            next = try JSONEncoder().encode(Cursor(id: id, path: full, upstream: upstream)).base64EncodedString()
        }
        return .init(entries: result, nextCursor: next)
    }

    public func stat(path: String) async throws -> FileEntry {
        let path = try FileServicePath.normalize(path)
        let entry = try await lookup(FileServicePath.join(configuration.rootPath, path))
        _ = try account()
        return fileEntry(entry, path: path)
    }

    public func resolve(path: String) async throws -> ResolvedFileResource {
        let path = try FileServicePath.normalize(path)
        _ = try account()
        if let cached = links[path], cached.expires > Date() { return cached.resource }
        let entry = try await lookup(FileServicePath.join(configuration.rootPath, path))
        guard !entry.isDirectory else { throw FileServiceError.path(path) }
        let link = try await CloudDirectoryRequestGate.shared.run(binding.accountID) {
            let snapshot = try await self.account()
            let link = try await self.download(entry, self.credential(snapshot))
            try await self.finish(snapshot, updated: link.updatedCredential)
            return link
        }
        guard let url = URL(string: link.url), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil,
              url.pathExtension.lowercased() != "m3u8" else {
            throw FileServiceError.protocolFailure("网盘未返回可读取的原始文件链接")
        }
        let resource = ResolvedFileResource(url: url, headers: link.headers)
        links[path] = (resource, Date().addingTimeInterval(60))
        return resource
    }

    public func read(path: String, range: Range<Int64>) async throws -> Data {
        guard range.lowerBound >= 0, range.upperBound >= range.lowerBound,
              range.upperBound - range.lowerBound <= 64 * 1024 * 1024 else { throw FileServiceError.path(path) }
        guard !range.isEmpty else { return Data() }
        for attempt in 0...1 {
            let resource = try await resolve(path: path)
            var headers = resource.headers
            headers["Range"] = "bytes=\(range.lowerBound)-\(range.upperBound - 1)"
            headers["Accept-Encoding"] = "identity"
            do {
                let (data, response) = try await transport.request(resource.url, headers: headers, maximumBytes: Int(range.count))
                _ = try account()
                try Task.checkCancellation()
                try FileHTTPTransport.validateRange(data: data, response: response, requested: range)
                return data
            } catch let error as FileServiceError {
                guard attempt == 0 else { throw error }
                switch error {
                case .authentication, .permission:
                    links[try FileServicePath.normalize(path)] = nil
                default: throw error
                }
            }
        }
        throw FileServiceError.authentication
    }

    public func disconnect() async { closed = true; entries.removeAll(); links.removeAll(); enumerations.removeAll() }

    private func account() throws -> CloudDirectoryAccountSnapshot {
        try Task.checkCancellation()
        guard !closed else { throw FileServiceError.unavailable }
        let snapshot = try preferences.cloudDirectoryAccount(binding.provider)
        guard snapshot.binding == binding else { throw FileServiceError.authorizationExpired }
        return snapshot
    }

    private func fetch(_ parent: CloudDirectoryEntry, cursor: String?) async throws -> CloudDirectoryPage {
        try await CloudDirectoryRequestGate.shared.run(binding.accountID) {
            let snapshot = try await self.account()
            let page = try await self.listing(parent.id, parent.driveID, cursor, self.credential(snapshot))
            try await self.finish(snapshot, updated: page.updatedCredential)
            return page
        }
    }

    private func lookup(_ path: String) async throws -> CloudDirectoryEntry {
        _ = try account()
        if let cached = entries[path] { return cached }
        if path == "/" {
            let root = CloudDirectoryEntry(id: PersonalCloudDirectoryClient.rootID(for: binding.provider),
                                           name: binding.provider.displayName, isDirectory: true)
            entries[path] = root; return root
        }
        let parent = try await lookup(FileServicePath.parent(path))
        guard parent.isDirectory else { throw FileServiceError.path(path) }
        var cursor: String?, cursors = Set<String>(), identifiers = Set<String>()
        var found: CloudDirectoryEntry?
        repeat {
            let page = try await fetch(parent, cursor: cursor)
            var fresh = 0
            for entry in page.entries {
                try validateName(entry.name)
                if identifiers.insert(entry.id).inserted { fresh += 1 }
                let candidate = try FileServicePath.join(FileServicePath.parent(path), entry.name)
                if candidate == path {
                    guard found == nil || found?.id == entry.id else {
                        throw FileServiceError.protocolFailure("网盘目录返回了重复的文件名")
                    }
                    found = entry
                }
                entries[candidate] = entry
            }
            cursor = page.nextCursor
            if let cursor, !cursors.insert(cursor).inserted || fresh == 0 {
                throw FileServiceError.protocolFailure("服务分页未向前推进，未完成目录读取")
            }
        } while cursor != nil
        guard let found else { throw FileServiceError.path(path) }
        return found
    }

    private func fileEntry(_ entry: CloudDirectoryEntry, path: String) -> FileEntry {
        .init(path: path, name: entry.name, isDirectory: entry.isDirectory, size: entry.size,
              version: entry.id + ":" + String(entry.size))
    }
    private func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"), !name.contains("\0") else {
            throw FileServiceError.protocolFailure("网盘返回了无效的文件名")
        }
    }
    private func credential(_ snapshot: CloudDirectoryAccountSnapshot) -> CloudCredential {
        let values = snapshot.values
        switch binding.provider {
        case .ali:
            let refresh = values["aliRefreshToken"] ?? "", access = values["aliAccessToken"] ?? ""
            return .init(provider: .ali, kind: refresh.isEmpty ? .accessToken : .refreshToken,
                         secret: access.isEmpty ? refresh : access, refreshToken: refresh.isEmpty ? nil : refresh,
                         accessToken: access.isEmpty ? nil : access,
                         metadata: ["default_drive_id": values["aliDefaultDriveID"] ?? "",
                                    "ali_auth_domain": values["aliAuthDomain"] ?? "", "user_id": values["aliUserID"] ?? ""])
        case .p115:
            return .init(provider: .p115, kind: .cookie, secret: values["p115Cookie"] ?? "",
                         metadata: ["access_token": values["p115AccessToken"] ?? ""])
        default:
            return .cookie(provider: binding.provider, value: values[binding.provider.rawValue + "Cookie"] ?? "")
        }
    }
    private func finish(_ snapshot: CloudDirectoryAccountSnapshot, updated: CloudCredential?) throws {
        _ = try account()
        guard let updated else { return }
        guard updated.provider == binding.provider else { throw FileServiceError.authorizationExpired }
        var values = snapshot.values
        switch binding.provider {
        case .ali:
            if let refresh = updated.refreshToken { values["aliRefreshToken"] = refresh }
            if let access = updated.accessToken { values["aliAccessToken"] = access }
            for (source, target) in [("default_drive_id", "aliDefaultDriveID"), ("ali_auth_domain", "aliAuthDomain"), ("user_id", "aliUserID")] {
                if let value = updated.metadata[source], !value.isEmpty { values[target] = value }
            }
        case .p115:
            values["p115Cookie"] = updated.secret
            if let access = updated.metadata["access_token"], !access.isEmpty { values["p115AccessToken"] = access }
        default: values[binding.provider.rawValue + "Cookie"] = updated.secret
        }
        if values != snapshot.values { try preferences.refreshCloudDirectoryAccount(snapshot, values: values) }
        _ = try account()
    }
}

/// Serialize only short API requests per account, including credential write-back.
/// Video byte reads run independently, and cancelling a queued scan removes its waiter.
private actor CloudDirectoryRequestGate {
    static let shared = CloudDirectoryRequestGate()
    private struct Waiter { let id: UUID; let continuation: CheckedContinuation<Void, Error> }
    private var owners: [String: UUID] = [:]
    private var waiters: [String: [Waiter]] = [:]

    func run<T: Sendable>(_ key: String, operation: @Sendable () async throws -> T) async throws -> T {
        let id = UUID()
        try Task.checkCancellation()
        if owners[key] == nil { owners[key] = id }
        else {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else { waiters[key, default: []].append(.init(id: id, continuation: continuation)) }
                }
            } onCancel: { Task { await self.cancel(key, id: id) } }
        }
        defer { release(key, id: id) }
        try Task.checkCancellation()
        return try await operation()
    }
    private func cancel(_ key: String, id: UUID) {
        guard let index = waiters[key]?.firstIndex(where: { $0.id == id }),
              let waiter = waiters[key]?.remove(at: index) else { return }
        waiter.continuation.resume(throwing: CancellationError())
        if waiters[key]?.isEmpty == true { waiters[key] = nil }
    }
    private func release(_ key: String, id: UUID) {
        guard owners[key] == id else { return }
        if var pending = waiters.removeValue(forKey: key), !pending.isEmpty {
            let next = pending.removeFirst()
            if !pending.isEmpty { waiters[key] = pending }
            owners[key] = next.id; next.continuation.resume()
        } else { owners[key] = nil }
    }
}
