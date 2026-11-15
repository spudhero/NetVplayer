import AppKit
import Models
import SwiftUI

/// Only content windows participate. A settings/diagnostics window must not keep
/// hidden poster walls or automatic guide imports active.
struct OptionalWorkWindowVisibility: NSViewRepresentable {
    var budget: PlaybackBackgroundBudget = .shared

    final class Coordinator {
        let id = UUID()
        let budget: PlaybackBackgroundBudget
        init(_ budget: PlaybackBackgroundBudget) { self.budget = budget }
    }

    func makeCoordinator() -> Coordinator { Coordinator(budget) }
    func makeNSView(context: Context) -> PlaybackInformationVisibilityView {
        let owner = context.coordinator
        owner.budget.updateWindow(owner.id, visible: false)
        let view = PlaybackInformationVisibilityView()
        view.changed = { visible in owner.budget.updateWindow(owner.id, visible: visible) }
        return view
    }
    func updateNSView(_ view: PlaybackInformationVisibilityView, context: Context) { view.refreshVisibility() }
    static func dismantleNSView(_ view: PlaybackInformationVisibilityView, coordinator: Coordinator) {
        view.stopObserving()
        coordinator.budget.removeWindow(coordinator.id)
    }
}
