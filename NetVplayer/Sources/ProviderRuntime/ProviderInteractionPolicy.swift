import Foundation

public enum ProviderInteractionError: LocalizedError, Equatable, Sendable {
    case timedOut
    case canceled

    public var errorDescription: String? {
        switch self {
        case .timedOut: return "扫码或交互等待超时，请重新播放并按来源提示完成操作"
        case .canceled: return "已取消当前授权操作"
        }
    }
}

/// App-owned presentation signals contain only a request UUID and a UI state.
/// A visible input dialog gets a bounded budget separate from network work.
public struct ProviderInteractionPolicy: Sendable {
    public let directory: URL
    public let maximumWait: Duration
    let pollInterval: Duration
    let onDialogActive: (@Sendable (Int32) async -> Void)?

    public init(directory: URL, maximumWait: Duration = .seconds(180),
                onDialogActive: (@Sendable (Int32) async -> Void)? = nil) {
        self.init(directory: directory, maximumWait: maximumWait, pollInterval: .milliseconds(100),
                  onDialogActive: onDialogActive)
    }

    init(directory: URL, maximumWait: Duration, pollInterval: Duration,
         onDialogActive: (@Sendable (Int32) async -> Void)? = nil) {
        self.directory = directory
        self.maximumWait = maximumWait
        self.pollInterval = pollInterval
        self.onDialogActive = onDialogActive
    }

    func begin(requestID: String) throws -> Wait {
        guard UUID(uuidString: requestID) != nil else { throw ProviderProcessError.invalidResponse }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let current = directory.appendingPathComponent("interaction-request")
        try requestID.write(to: current, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: current.path)
        return Wait(policy: self, requestID: requestID)
    }

    struct Wait: Sendable {
        let policy: ProviderInteractionPolicy
        let requestID: String

        var stateFile: URL { policy.directory.appendingPathComponent("interaction-\(requestID).state") }

        func state() -> String {
            guard let size = try? stateFile.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 16,
                  let value = try? String(contentsOf: stateFile, encoding: .utf8) else { return "" }
            return value
        }

        func waitForTimeout(networkTimeout: Duration, processID: Int32?) async throws -> Never {
            let clock = ContinuousClock()
            var last = clock.now
            var networkElapsed = Duration.zero
            var interactionElapsed = Duration.zero
            var previousActive = false
            var interacted = false
            while true {
                try Task.checkCancellation()
                let now = clock.now
                let elapsed = last.duration(to: now)
                last = now
                if previousActive { interactionElapsed += elapsed }
                else { networkElapsed += elapsed }
                let value = state()
                if value == "canceled" { throw ProviderInteractionError.canceled }
                let active = value == "active"
                interacted = interacted || active || value == "idle"
                if interactionElapsed >= policy.maximumWait || networkElapsed >= networkTimeout {
                    if interacted { throw ProviderInteractionError.timedOut }
                    throw ProviderProcessError.timedOut(requestID)
                }
                let opened = active && !previousActive
                previousActive = active
                if opened, let processID, let onDialogActive = policy.onDialogActive {
                    await onDialogActive(processID)
                }
                let remaining = active ? policy.maximumWait - interactionElapsed : networkTimeout - networkElapsed
                try await Task.sleep(for: min(policy.pollInterval, remaining))
            }
        }

        func finish() {
            let current = policy.directory.appendingPathComponent("interaction-request")
            if (try? String(contentsOf: current, encoding: .utf8)) == requestID {
                try? FileManager.default.removeItem(at: current)
            }
            try? FileManager.default.removeItem(at: stateFile)
        }
    }
}
