import Models

public enum DrivePlaybackTransitionOutcome: Equatable, Sendable {
    case started(DrivePlaybackCandidate)
    case coalesced
    case stale
    case exhausted
}

@MainActor
public final class DrivePlaybackSessionController {
    private enum Phase: Equatable {
        case idle
        case starting
        case playing
        case switching(from: String, to: String)
        case exhausted
    }

    private var generation: UInt64 = 0
    private var plan: DrivePlaybackPlan?
    private var activeCandidateID: String?
    private var manualSelection = false
    private var phase: Phase = .idle
    private var terminalDelivered = false
    private var refreshAttemptedCandidateIDs = Set<String>()

    public init() {}

    @discardableResult
    public func begin(plan: DrivePlaybackPlan, candidateID: String) -> UInt64 {
        generation &+= 1
        self.plan = plan
        activeCandidateID = candidateID
        manualSelection = false
        phase = .starting
        terminalDelivered = false
        refreshAttemptedCandidateIDs.removeAll()
        return generation
    }

    public func requestFailure(for spec: PlaySpec, message: String) -> DrivePlaybackTransitionOutcome {
        guard let plan,
              spec.drivePlaybackSessionGeneration == generation,
              let failed = DrivePlaybackRoutePolicy.candidate(for: spec) else {
            return .stale
        }

        if case let .switching(from, to) = phase {
            if failed.id == from { return .coalesced }
            guard failed.id == to else { return .stale }
            activeCandidateID = failed.id
        } else if failed.id != activeCandidateID {
            return .stale
        }

        if manualSelection {
            return exhaustOnce()
        }
        if shouldRefresh(failed, message: message),
           refreshAttemptedCandidateIDs.insert(failed.id).inserted {
            phase = .switching(from: failed.id, to: failed.id)
            return .started(failed)
        }
        guard let next = plan.candidate(after: failed.id) else {
            return exhaustOnce()
        }
        phase = .switching(from: failed.id, to: next.id)
        return .started(next)
    }

    public func requestRefreshFailure(for spec: PlaySpec) -> DrivePlaybackTransitionOutcome {
        guard spec.drivePlaybackSessionGeneration == generation,
              let failed = DrivePlaybackRoutePolicy.candidate(for: spec) else {
            return .stale
        }
        guard case let .switching(from, to) = phase else { return .stale }
        guard from == failed.id, to == failed.id else { return .coalesced }
        activeCandidateID = failed.id
        phase = .playing
        guard let plan, let next = plan.candidate(after: failed.id) else {
            return exhaustOnce()
        }
        phase = .switching(from: failed.id, to: next.id)
        return .started(next)
    }

    public func replacePlan(_ plan: DrivePlaybackPlan, generation expectedGeneration: UInt64?) -> Bool {
        guard expectedGeneration == generation, plan.provider == self.plan?.provider else { return false }
        self.plan = plan
        return true
    }

    public func requestManualTransition(
        to candidateID: String,
        generation expectedGeneration: UInt64?
    ) -> DrivePlaybackTransitionOutcome {
        guard expectedGeneration == generation,
              let plan,
              let candidate = plan.candidates.first(where: { $0.id == candidateID }) else {
            return .stale
        }
        if case .switching = phase { return .coalesced }
        guard candidate.id != activeCandidateID else { return .coalesced }
        phase = .switching(from: activeCandidateID ?? "", to: candidate.id)
        manualSelection = true
        terminalDelivered = false
        refreshAttemptedCandidateIDs.removeAll()
        return .started(candidate)
    }

    public func confirmStarted(spec: PlaySpec) -> Bool {
        guard spec.drivePlaybackSessionGeneration == generation,
              let candidate = DrivePlaybackRoutePolicy.candidate(for: spec) else {
            return false
        }
        if case let .switching(_, target) = phase, target != candidate.id {
            return false
        }
        activeCandidateID = candidate.id
        phase = .playing
        terminalDelivered = false
        return true
    }

    public func cancel() {
        generation &+= 1
        plan = nil
        activeCandidateID = nil
        manualSelection = false
        phase = .idle
        terminalDelivered = false
    }

    private func exhaustOnce() -> DrivePlaybackTransitionOutcome {
        guard !terminalDelivered else { return .coalesced }
        terminalDelivered = true
        phase = .exhausted
        return .exhausted
    }

    private func shouldRefresh(_ candidate: DrivePlaybackCandidate, message: String) -> Bool {
        switch candidate.refreshPolicy {
        case .none:
            return false
        case .refreshURLOnce:
            let lower = message.lowercased()
            return lower.contains("400")
                || lower.contains("401")
                || lower.contains("403")
                || lower.contains("410")
                || lower.contains("forbidden")
                || lower.contains("expired")
                || lower.contains("signature")
                || lower.contains("token")
        case .refreshCredentialAndURLOnce:
            let lower = message.lowercased()
            return lower.contains("401")
                || lower.contains("410")
                || lower.contains("not login")
                || lower.contains("unauthorized")
                || lower.contains("expired")
                || lower.contains("signature")
                || lower.contains("token")
        }
    }
}
