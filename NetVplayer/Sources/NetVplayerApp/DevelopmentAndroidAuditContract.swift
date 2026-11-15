import Foundation
import SpiderEngine

/// Source keys are identifiers, not evidence of the expected media format.
/// A phone baseline may explicitly require audio; otherwise require both tracks.
/// Completion of the App operation is independent of receiving a usable detail.
/// A result may come from the cache; this state does not count SDK calls.
enum VodDetailRequestOutcome: String {
    case notRequested, loading, result, empty, failed
}

enum DevelopmentAndroidAuditContract {
    static func sourceOrder(available: [String], requested: [String]?) -> [String] {
        let known = Set(available)
        var seen = Set<String>()
        return (requested ?? available).filter { known.contains($0) && seen.insert($0).inserted }
    }

    enum RequiredOutput: String, Codable {
        case audio
        case audioAndVideo = "audio_and_video"

        func accepts(audioDecoded: Bool, videoDecoded: Bool, separateAudio: Bool) -> Bool {
            audioDecoded && (self == .audio || videoDecoded) && (!separateAudio || videoDecoded)
        }
    }

    static func catalogStatus(completed: Bool, isCurrentSite: Bool, error: String?, items: Int,
                              requestFailed: Bool = false) -> String {
        guard completed, isCurrentSite else { return "catalog_incomplete" }
        guard !requestFailed, error?.isEmpty != false else { return "catalog_error" }
        return items > 0 ? "catalog_observed" : "catalog_empty"
    }

    @MainActor
    static func categoryStatus(state: AppState, id: String, completed: Bool) -> String {
        guard let site = state.activeSite, state.selectedCategory?.typeId == id,
              let observation = state.developmentAndroidCategoryObservation,
              observation.siteSHA256 == DevelopmentAndroidLifecycleDiagnostics.sha256(Data(site.key.utf8)),
              observation.categorySHA256 == DevelopmentAndroidLifecycleDiagnostics.sha256(Data(id.utf8)),
              observation.contentGeneration == state.contentCatalogState.generation,
              observation.outcome != "discarded" else { return "catalog_incomplete" }
        return catalogStatus(completed: completed && !state.isLoadingVod && !state.isCatalogRefreshing,
            isCurrentSite: true, error: state.vodError, items: state.vods.count,
            requestFailed: ["error", "error_retained_content", "unsupported"].contains(observation.outcome ?? ""))
    }

    static func requestedCategoryFailure(advertised: Bool, status: String?) -> String {
        guard advertised else { return "requested_category_not_advertised" }
        switch status {
        case "catalog_empty": return "requested_category_empty"
        case "catalog_incomplete": return "requested_category_incomplete"
        default: return "requested_category_unavailable"
        }
    }

    static func detailRequestFailure(_ outcome: VodDetailRequestOutcome) -> String? {
        switch outcome {
        case .failed: return "detail_request_failed"
        case .empty: return "detail_empty_result"
        case .notRequested, .loading: return "detail_incomplete"
        case .result: return nil
        }
    }

    static func detailFailure(presented: Bool, hasDetail: Bool, episodes: Int, requestedIndex: Int,
                              requestOutcome: VodDetailRequestOutcome = .result) -> String? {
        if let failure = detailRequestFailure(requestOutcome) { return failure }
        guard presented, hasDetail else { return "detail_missing" }
        guard episodes > 0 else { return "detail_no_episodes" }
        return (0..<episodes).contains(requestedIndex) ? nil : "requested_episode_missing"
    }
}
