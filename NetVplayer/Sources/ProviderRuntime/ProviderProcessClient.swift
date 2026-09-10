import Foundation
import ProviderSDK

public enum ProviderProcessError: LocalizedError, Equatable, Sendable {
    case notRunning
    case launchFailed(String)
    case writeFailed(String)
    case invalidResponse
    case duplicateRequest(String)
    case timedOut(String)
    case canceled(String)
    case terminated(Int32)
    case invalidEnvironment(String)
    case statePreparationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notRunning: return "Provider process is not running"
        case .launchFailed(let detail): return "Provider process could not start: \(detail)"
        case .writeFailed(let detail): return "Provider request could not be written: \(detail)"
        case .invalidResponse: return "Provider returned invalid JSON-RPC data"
        case .duplicateRequest(let id): return "Provider request ID is already pending: \(id)"
        case .timedOut(let id): return "Provider request timed out: \(id)"
        case .canceled(let id): return "Provider request was canceled: \(id)"
        case .terminated(let status): return "Provider process exited with status \(status)"
        case .invalidEnvironment(let key): return "Provider command contains an unsafe environment value: \(key)"
        case .statePreparationFailed(let detail): return "Provider state directory could not be prepared: \(detail)"
        }
    }
}

public actor ProviderProcessClient {
    private let command: ProviderCommand
    private let providerID: String
    private let diagnosticWriter: ProviderDiagnosticJSONLWriter
    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var errorHandle: FileHandle?
    private var outputReadTask: Task<Void, Never>?
    private var errorReadTask: Task<Void, Never>?
    private var outputStreamContinuation: AsyncStream<Data>.Continuation?
    private var errorStreamContinuation: AsyncStream<Data>.Continuation?
    private var outputBuffer = Data()
    private var pending: [String: CheckedContinuation<ProviderResponse, Error>] = [:]
    private let quickJSHTTPHost: QuickJSHTTPHost
    private let quickJSJSPHost: QuickJSJSPHost
    private let quickJSCryptoHost: QuickJSCryptoHost
    private let quickJSPersistenceHost: QuickJSPersistenceHost
    private let quickJSTextHost: QuickJSTextHost
    private let quickJSLocalProxyHost: QuickJSLocalProxyHost
    private let quickJSHostCapabilities: Set<String>
    private var quickJSHostTasks: [String: Task<Void, Never>] = [:]

    public init(
        command: ProviderCommand,
        diagnosticWriter: ProviderDiagnosticJSONLWriter? = nil,
        httpSession: URLSession? = nil,
        maximumHTTPResponseBytes: Int = 32 * 1024 * 1024
    ) {
        self.command = command
        providerID = command.environment["NETVPLAYER_PROVIDER_ID"] ?? "unknown"
        self.diagnosticWriter = diagnosticWriter ?? ProviderDiagnosticJSONLWriter(
            stateDirectoryURL: command.stateDirectoryURL
        )
        quickJSHostCapabilities = Set(
            (command.environment["NETVPLAYER_PROVIDER_HOST_CAPABILITIES"] ?? "")
                .split(separator: ",")
                .map(String.init)
        )
        quickJSHTTPHost = QuickJSHTTPHost(
            session: httpSession,
            maximumResponseBytes: maximumHTTPResponseBytes
        )
        quickJSJSPHost = QuickJSJSPHost()
        quickJSCryptoHost = QuickJSCryptoHost()
        quickJSPersistenceHost = QuickJSPersistenceHost(stateDirectoryURL: command.stateDirectoryURL)
        quickJSTextHost = QuickJSTextHost()
        quickJSLocalProxyHost = QuickJSLocalProxyHost()
    }

    deinit {
        outputReadTask?.cancel()
        errorReadTask?.cancel()
        if let process, process.isRunning { process.terminate() }
    }

    public func start() throws {
        if let process, process.isRunning { return }

        emit(level: .info, category: .lifecycle, code: .processStarting)

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = command.executableURL
        process.arguments = command.arguments
        process.currentDirectoryURL = command.currentDirectoryURL
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        do {
            process.environment = try Self.launchEnvironment(for: command)
        } catch {
            emit(
                level: .error,
                category: .process,
                code: .processLaunchFailed,
                message: error.localizedDescription
            )
            throw error
        }

        do {
            try process.run()
        } catch {
            emit(
                level: .error,
                category: .process,
                code: .processLaunchFailed,
                message: error.localizedDescription
            )
            throw ProviderProcessError.launchFailed(error.localizedDescription)
        }

        emit(
            level: .info,
            category: .lifecycle,
            code: .processStarted,
            processID: process.processIdentifier
        )

        self.process = process
        inputHandle = input.fileHandleForWriting
        let outputHandle = output.fileHandleForReading
        let errorHandle = error.fileHandleForReading
        self.outputHandle = outputHandle
        self.errorHandle = errorHandle
        outputBuffer.removeAll(keepingCapacity: true)

        let (outputStream, outputContinuation) = AsyncStream.makeStream(of: Data.self)
        outputStreamContinuation = outputContinuation
        outputReadTask = Task { [weak self] in
            for await data in outputStream {
                guard let self else { return }
                await self.consume(data)
            }
        }
        outputHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                outputContinuation.finish()
                return
            }
            outputContinuation.yield(data)
        }

        let (errorStream, errorContinuation) = AsyncStream.makeStream(of: Data.self)
        errorStreamContinuation = errorContinuation
        errorReadTask = Task { [weak self] in
            for await data in errorStream {
                guard let self else { return }
                await self.recordStandardError(String(decoding: data, as: UTF8.self))
            }
        }
        errorHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                errorContinuation.finish()
            } else {
                errorContinuation.yield(data)
            }
        }

        process.terminationHandler = { [weak self] process in
            Task { await self?.terminated(status: process.terminationStatus) }
        }
    }

    public func request(_ request: ProviderRequest, timeout: Duration = .seconds(15)) async throws -> ProviderResponse {
        emit(
            level: .info,
            category: .request,
            code: .requestStarted,
            requestID: request.requestID,
            processID: process?.processIdentifier
        )
        do {
            try start()
            let response = try await withThrowingTaskGroup(of: ProviderResponse.self) { group in
                group.addTask { try await self.enqueue(request) }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw ProviderProcessError.timedOut(request.requestID)
                }
                guard let response = try await group.next() else {
                    throw ProviderProcessError.notRunning
                }
                group.cancelAll()
                return response
            }
            if response.ok {
                emit(
                    level: .info,
                    category: .request,
                    code: .requestCompleted,
                    requestID: request.requestID,
                    processID: process?.processIdentifier,
                    statusCode: response.proxy?.statusCode,
                    contentType: response.proxy?.contentType
                )
            } else {
                let errorMessage = response.error.map { "\($0.code): \($0.message)" }
                emit(
                    level: .error,
                    category: .request,
                    code: .requestFailed,
                    requestID: request.requestID,
                    processID: process?.processIdentifier,
                    statusCode: response.proxy?.statusCode,
                    contentType: response.proxy?.contentType,
                    message: errorMessage
                )
            }
            return response
        } catch {
            let mapped: Error
            if error is CancellationError || Task.isCancelled {
                mapped = ProviderProcessError.canceled(request.requestID)
            } else {
                mapped = error
            }
            // A duplicate request never owns the existing pending continuation. Do not
            // let the second caller tear down the first request's in-flight operation.
            if case .duplicateRequest = mapped as? ProviderProcessError {
                // The duplicate caller has no pending entry to finish.
            } else {
                fail(requestID: request.requestID, error: mapped)
            }
            let diagnosticCode = Self.diagnosticCode(for: mapped)
            emit(
                level: diagnosticCode == .requestCanceled ? .warning : .error,
                category: .request,
                code: diagnosticCode,
                requestID: request.requestID,
                processID: process?.processIdentifier,
                message: mapped.localizedDescription
            )
            throw mapped
        }
    }

    public func stop(graceful: Bool = true) async {
        emit(
            level: .info,
            category: .lifecycle,
            code: .processStopping,
            processID: process?.processIdentifier
        )
        if graceful, let process, process.isRunning {
            let request = ProviderRequest(providerID: command.environment["NETVPLAYER_PROVIDER_ID"] ?? "", operation: .shutdown)
            _ = try? await self.request(request, timeout: .seconds(2))
        }
        quickJSHostTasks.values.forEach { $0.cancel() }
        quickJSHostTasks.removeAll()
        try? inputHandle?.close()
        inputHandle = nil
        if let process, process.isRunning { process.terminate() }
        stopReaders()
        try? outputHandle?.close()
        try? errorHandle?.close()
        outputHandle = nil
        errorHandle = nil
        self.process = nil
        failAll(ProviderProcessError.notRunning)
        emit(level: .info, category: .lifecycle, code: .processStopped)
    }

    public var isRunning: Bool {
        process?.isRunning == true
    }

    static func launchEnvironment(for command: ProviderCommand) throws -> [String: String] {
        let allowedCommandKeys: Set<String> = [
            "NETVPLAYER_PROVIDER_ID",
            "NETVPLAYER_PROVIDER_PROTOCOL",
            "NETVPLAYER_PROVIDER_ROOT",
            "NETVPLAYER_PROVIDER_SANDBOX",
            "NETVPLAYER_PROVIDER_STATE",
            "NETVPLAYER_PROVIDER_HOST_CAPABILITIES",
            "NETVPLAYER_PROVIDER_HTTP_FIXTURE_URL",
            "PYTHONDONTWRITEBYTECODE",
            "PYTHONNOUSERSITE",
        ]
        if let unsafe = command.environment.keys.first(where: { !allowedCommandKeys.contains($0) }) {
            throw ProviderProcessError.invalidEnvironment(unsafe)
        }
        guard command.environment["NETVPLAYER_PROVIDER_STATE"] == command.stateDirectoryURL.path else {
            throw ProviderProcessError.invalidEnvironment("NETVPLAYER_PROVIDER_STATE")
        }

        let state = command.stateDirectoryURL
        let directories = [
            "home": state.appendingPathComponent("home", isDirectory: true),
            "tmp": state.appendingPathComponent("tmp", isDirectory: true),
            "cache": state.appendingPathComponent("cache", isDirectory: true),
            "config": state.appendingPathComponent("config", isDirectory: true),
            "data": state.appendingPathComponent("data", isDirectory: true),
        ]
        do {
            try preparePrivateDirectory(state)
            for directory in directories.values {
                try preparePrivateDirectory(directory)
            }
        } catch {
            throw ProviderProcessError.statePreparationFailed(error.localizedDescription)
        }

        var environment = [
            "PATH": "/usr/bin:/bin",
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "HOME": directories["home"]!.path,
            "TMPDIR": directories["tmp"]!.path + "/",
            "XDG_CACHE_HOME": directories["cache"]!.path,
            "XDG_CONFIG_HOME": directories["config"]!.path,
            "XDG_DATA_HOME": directories["data"]!.path,
            "PYTHONPYCACHEPREFIX": directories["cache"]!.appendingPathComponent("python").path,
        ]
        environment.merge(command.environment) { _, configured in configured }
        return environment
    }

    private static func preparePrivateDirectory(_ directory: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: directory.path) {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
        } else {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func enqueue(_ request: ProviderRequest) async throws -> ProviderResponse {
        if pending[request.requestID] != nil {
            throw ProviderProcessError.duplicateRequest(request.requestID)
        }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: ProviderProcessError.canceled(request.requestID))
                    return
                }
                pending[request.requestID] = continuation
                do {
                    try write(request)
                } catch {
                    pending.removeValue(forKey: request.requestID)
                    continuation.resume(throwing: ProviderProcessError.writeFailed(error.localizedDescription))
                }
            }
        }, onCancel: {
            Task { await self.cancel(requestID: request.requestID) }
        })
    }

    private func receive(_ response: ProviderResponse) {
        pending.removeValue(forKey: response.requestID)?.resume(returning: response)
    }

    private func consume(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer[..<newline]
            outputBuffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            if receiveQuickJSHostMessage(Data(line)) { continue }
            guard let response = try? JSONDecoder().decode(ProviderResponse.self, from: Data(line)) else {
                emit(
                    level: .error,
                    category: .protocolViolation,
                    code: .invalidResponse,
                    processID: process?.processIdentifier,
                    message: String(decoding: line, as: UTF8.self)
                )
                failAll(ProviderProcessError.invalidResponse)
                continue
            }
            receive(response)
        }
    }

    private func receiveQuickJSHostMessage(_ data: Data) -> Bool {
        guard let control = try? JSONDecoder().decode(QuickJSHostControl.self, from: data) else {
            return false
        }
        switch control.type {
        case "host_cancel":
            quickJSHostTasks[control.requestID]?.cancel()
            return true
        case "host_request":
            quickJSHostTasks[control.requestID]?.cancel()
            guard let capability = control.capability,
                  quickJSHostCapabilities.contains(capability) else {
                let response = QuickJSHostResponse(
                    requestID: control.requestID,
                    ok: false,
                    error: ProviderErrorPayload(
                        code: "capability_denied",
                        message: "QuickJS host capability is not enabled"
                    )
                )
                finishQuickJSHostRequest(requestID: control.requestID, response: response)
                return true
            }
            let httpHost = quickJSHTTPHost
            let jspHost = quickJSJSPHost
            let cryptoHost = quickJSCryptoHost
            let persistenceHost = quickJSPersistenceHost
            let textHost = quickJSTextHost
            let localProxyHost = quickJSLocalProxyHost
            let task = Task { [weak self, httpHost, jspHost, cryptoHost, persistenceHost, textHost, localProxyHost] in
                guard let self else { return }
                let response: QuickJSHostResponse
                switch control.capability {
                case "http":
                    response = await httpHost.handle(control)
                case "jsp":
                    response = await jspHost.handle(control)
                case "crypto":
                    response = await cryptoHost.handle(control)
                case "persistence":
                    response = await persistenceHost.handle(control)
                case "text":
                    response = await textHost.handle(control)
                case "local_proxy":
                    response = localProxyHost.handle(control)
                default:
                    response = QuickJSHostResponse(
                        requestID: control.requestID,
                        ok: false,
                        error: ProviderErrorPayload(
                            code: "unsupported_host_request",
                            message: "Unsupported QuickJS host capability"
                        )
                    )
                }
                await self.finishQuickJSHostRequest(
                    requestID: control.requestID,
                    response: Task.isCancelled ? nil : response
                )
            }
            quickJSHostTasks[control.requestID] = task
            return true
        default:
            return false
        }
    }

    private func finishQuickJSHostRequest(
        requestID: String,
        response: QuickJSHostResponse?
    ) {
        defer { quickJSHostTasks.removeValue(forKey: requestID) }
        guard let response else { return }
        guard process?.isRunning == true, let inputHandle else { return }
        guard let encoded = try? JSONEncoder.providerCanonical.encode(response) else { return }
        try? inputHandle.write(contentsOf: encoded + Data([0x0A]))
    }

    private func cancel(requestID: String) {
        let control = ProviderRequest(
            providerID: command.environment["NETVPLAYER_PROVIDER_ID"] ?? "",
            operation: .cancel,
            arguments: ["target_request_id": .string(requestID)]
        )
        try? write(control)
        fail(requestID: requestID, error: ProviderProcessError.canceled(requestID))
    }

    private func write(_ request: ProviderRequest) throws {
        guard process?.isRunning == true, let inputHandle else { throw ProviderProcessError.notRunning }
        let encoded = try JSONEncoder.providerCanonical.encode(request) + Data([0x0A])
        do {
            try inputHandle.write(contentsOf: encoded)
        } catch {
            throw ProviderProcessError.writeFailed(error.localizedDescription)
        }
    }

    private func fail(requestID: String, error: Error) {
        pending.removeValue(forKey: requestID)?.resume(throwing: error)
    }

    private func terminated(status: Int32) {
        guard process != nil else { return }
        emit(
            level: status == 0 ? .info : .error,
            category: .process,
            code: .processTerminated,
            processID: process?.processIdentifier,
            terminationStatus: status
        )
        process = nil
        inputHandle = nil
        quickJSHostTasks.values.forEach { $0.cancel() }
        quickJSHostTasks.removeAll()
        stopReaders()
        outputHandle = nil
        errorHandle = nil
        failAll(ProviderProcessError.terminated(status))
    }

    private func stopReaders() {
        outputHandle?.readabilityHandler = nil
        errorHandle?.readabilityHandler = nil
        outputStreamContinuation?.finish()
        errorStreamContinuation?.finish()
        outputStreamContinuation = nil
        errorStreamContinuation = nil
        outputReadTask?.cancel()
        errorReadTask?.cancel()
        outputReadTask = nil
        errorReadTask = nil
    }

    private func failAll(_ error: Error) {
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations { continuation.resume(throwing: error) }
    }

    private func recordStandardError(_ value: String) {
        emit(
            level: .warning,
            category: .standardError,
            code: .standardErrorOutput,
            processID: process?.processIdentifier,
            message: value
        )
    }

    private func emit(
        level: ProviderDiagnosticLevel,
        category: ProviderDiagnosticCategory,
        code: ProviderDiagnosticCode,
        requestID: String? = nil,
        processID: Int32? = nil,
        terminationStatus: Int32? = nil,
        statusCode: Int? = nil,
        contentType: String? = nil,
        message: String? = nil
    ) {
        diagnosticWriter.recordSafely(ProviderDiagnosticEvent(
            level: level,
            category: category,
            code: code,
            providerID: providerID,
            requestID: requestID,
            processID: processID,
            terminationStatus: terminationStatus,
            statusCode: statusCode,
            contentType: contentType,
            message: message
        ))
    }

    private static func diagnosticCode(for error: Error) -> ProviderDiagnosticCode {
        guard let processError = error as? ProviderProcessError else {
            return error is CancellationError ? .requestCanceled : .requestFailed
        }
        switch processError {
        case .timedOut:
            return .requestTimedOut
        case .canceled:
            return .requestCanceled
        default:
            return .requestFailed
        }
    }
}
