import Foundation
import Network
import Security

/// A separate, session-only control socket. It has no reference to the media
/// proxy, service clients, credentials, recovery commands or resource loaders.
final class LocalReadOnlyServer: @unchecked Sendable {
    enum Endpoint: String, Sendable { case tasks = "/v1/tasks", services = "/v1/services", health = "/v1/health" }
    enum Failure: Error { case unavailable }
    typealias Read = @Sendable (Endpoint) async throws -> Data
    private let queue = DispatchQueue(label: "NetVplayer.local-read-only")
    private let read: Read
    private let onFailure: @Sendable () -> Void
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var reads: [UUID: Task<Void, Never>] = [:]
    private var credential: String?
    private var generation = UUID()
    private var listenerGeneration = UUID()
    private var port: UInt16?
    private var windowStart: TimeInterval = 0
    private var accepted = 0
    private let requestsPerMinute: Int
    private var startReply: CheckedContinuation<UInt16, Error>?

    init(requestsPerMinute: Int = 60, onFailure: @escaping @Sendable () -> Void = {}, read: @escaping Read) {
        self.requestsPerMinute = min(60, max(1, requestsPerMinute)); self.read = read; self.onFailure = onFailure
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { reply in
            queue.async { [self] in
                guard listener == nil else { reply.resume(throwing: Failure.unavailable); return }
                do {
                    let token = try Self.newToken()
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
                    parameters.allowLocalEndpointReuse = false
                    let socket = try NWListener(using: parameters)
                    let epoch = UUID(); listenerGeneration = epoch; generation = epoch; credential = token; listener = socket
                    windowStart = ProcessInfo.processInfo.systemUptime; accepted = 0; startReply = reply
                    socket.newConnectionHandler = { [weak self] connection in self?.accept(connection, epoch: epoch) }
                    socket.stateUpdateHandler = { [weak self] state in
                        guard let self, self.listener === socket else { return }
                        switch state {
                        case .ready:
                            guard let value = socket.port?.rawValue else { self.shutdown(); return }
                            self.port = value
                            self.startReply?.resume(returning: value); self.startReply = nil
                        case .failed, .cancelled:
                            let wasReady = self.port != nil
                            self.shutdown()
                            if wasReady { self.onFailure() }
                        default: break
                        }
                    }
                    socket.start(queue: queue)
                    queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                        guard let self, self.listener === socket, self.startReply != nil else { return }
                        self.shutdown()
                    }
                } catch { reply.resume(throwing: Failure.unavailable) }
            }
        }
    }

    func stop() async { await withCheckedContinuation { reply in queue.async { self.shutdown(); reply.resume() } } }

    /// Auth changes and admission checks run on the same queue. Pending replies
    /// recheck the generation, so a rotated token cannot finish a later read.
    func rotateToken() async throws {
        try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    guard self.listener != nil, self.port != nil else { throw Failure.unavailable }
                    self.credential = try Self.newToken(); self.generation = UUID()
                    reply.resume()
                } catch { self.shutdown(); reply.resume(throwing: Failure.unavailable) }
            }
        }
    }

    func tokenForUser() async -> String? {
        await withCheckedContinuation { reply in queue.async { reply.resume(returning: self.credential) } }
    }

    private static func newToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw Failure.unavailable }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private func shutdown() {
        credential = nil; generation = UUID(); port = nil
        let socket = listener; listener = nil
        socket?.stateUpdateHandler = nil; socket?.newConnectionHandler = nil; socket?.cancel()
        startReply?.resume(throwing: Failure.unavailable); startReply = nil
        reads.values.forEach { $0.cancel() }; reads.removeAll()
        connections.values.forEach { $0.cancel() }; connections.removeAll()
    }

    private func accept(_ connection: NWConnection, epoch: UUID) {
        // NWListener callbacks use queue. The binding excludes other interfaces;
        // checking the peer also rejects any unexpected transport configuration.
        guard listener != nil, listenerGeneration == epoch, case let .hostPort(host, _) = connection.endpoint,
              host == .ipv4(.loopback), connections.count < 16 else { connection.cancel(); return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - windowStart >= 60 { windowStart = now; accepted = 0 }
        let id = UUID(); connections[id] = connection
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in self?.close(id) }
        accepted += 1
        if accepted > requestsPerMinute { respond(id, status: 429); return }
        receive(id, bytes: Data())
    }

    private func receive(_ id: UUID, bytes: Data) {
        guard let connection = connections[id] else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8193 - bytes.count) { [weak self] data, _, complete, error in
            guard let self, self.connections[id] != nil else { return }
            var buffer = bytes; if let data { buffer.append(data) }
            guard buffer.count <= 8192 else { self.respond(id, status: 431); return }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                guard end.upperBound == buffer.endIndex else { self.respond(id, status: 400); return }
                self.handle(id, header: Data(buffer[..<end.lowerBound]))
            } else if complete || error != nil { self.close(id) }
            else { self.receive(id, bytes: buffer) }
        }
    }

    private func handle(_ id: UUID, header: Data) {
        guard let text = String(data: header, encoding: .utf8), let port else { respond(id, status: 400); return }
        let lines = text.components(separatedBy: "\r\n")
        let request = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: false)
        guard request.count == 3, request[2] == "HTTP/1.1" else { respond(id, status: 400); return }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), line.first != " ", line.first != "\t" else { respond(id, status: 400); return }
            let name = String(line[..<colon]).lowercased()
            guard !name.isEmpty, name.utf8.allSatisfy({ (97...122).contains($0) || $0 == 45 }), headers[name] == nil else { respond(id, status: 400); return }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["host"] == "127.0.0.1:\(port)", headers["origin"] == nil,
              headers["transfer-encoding"] == nil, headers["content-length"] == nil || headers["content-length"] == "0" else { respond(id, status: 400); return }
        guard let credential, Self.matches(headers["authorization"], token: credential) else { respond(id, status: 401); return }
        guard request[0] == "GET" else { respond(id, status: 405); return }
        guard let endpoint = Endpoint(rawValue: String(request[1])) else { respond(id, status: 404); return }
        let authorization = generation
        reads[id] = Task { [weak self, read] in
            let data: Data?
            do { data = try await read(endpoint) } catch { data = nil }
            self?.queue.async { [weak self] in
                guard let self, self.connections[id] != nil else { return }
                self.reads[id] = nil
                guard self.generation == authorization, self.credential != nil else { self.respond(id, status: 401); return }
                guard let data, data.count <= 512 * 1024 else { self.respond(id, status: 503); return }
                self.respond(id, status: 200, data: data)
            }
        }
    }

    private static func matches(_ authorization: String?, token: String) -> Bool {
        let expected = Array(("Bearer " + token).utf8), actual = Array((authorization ?? "").utf8)
        guard actual.count == expected.count else { return false }
        var difference: UInt8 = 0
        for i in expected.indices { difference |= expected[i] ^ actual[i] }
        return difference == 0
    }

    private func respond(_ id: UUID, status: Int, data: Data? = nil) {
        guard let connection = connections[id] else { return }
        let names = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 405: "Method Not Allowed",
                     429: "Too Many Requests", 431: "Request Header Fields Too Large", 503: "Service Unavailable"]
        let body = data ?? Data("{\"error\":\(status)}".utf8)
        var head = "HTTP/1.1 \(status) \(names[status] ?? "Error")\r\nContent-Type: application/json\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\nContent-Length: \(body.count)\r\n"
        if status == 429 { head += "Retry-After: 60\r\n" }
        if status == 405 { head += "Allow: GET\r\n" }
        if status == 401 { head += "WWW-Authenticate: Bearer\r\n" }
        var response = Data((head + "\r\n").utf8); response.append(body)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in self?.close(id) })
    }

    private func close(_ id: UUID) {
        reads.removeValue(forKey: id)?.cancel()
        connections.removeValue(forKey: id)?.cancel()
    }
}
