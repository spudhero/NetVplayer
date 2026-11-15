import SwiftUI
import Models

struct TaskStatusLabel: View {
    let event: TaskDiagnosticEvent
    var isActive = false
    @Environment(\.appThemePalette) private var palette

    private var role: AppSemanticColorRole {
        switch event.state {
        case .completed: .success
        case .needsAttention: .danger
        case .needsLogin, .waitingConfirmation: .warning
        case .processing: isActive ? .loading : .warning
        case .cancelled: .secondaryText
        }
    }
    private var symbol: String {
        switch event.state {
        case .completed: "checkmark.circle"
        case .needsAttention: "exclamationmark.circle"
        case .needsLogin: "person.crop.circle.badge.exclamationmark"
        case .waitingConfirmation, .processing: "clock"
        case .cancelled: "minus.circle"
        }
    }
    var body: some View {
        HStack(spacing: 6) {
            if isActive && (event.state == .processing || event.state == .waitingConfirmation) {
                ProgressView().controlSize(.mini)
            } else { Image(systemName: symbol).accessibilityHidden(true) }
            Text(UserFacingErrorPresenter.taskState(event, isActive: isActive))
        }
        .font(.caption.weight(.medium)).foregroundStyle(palette.color(for: role))
        .accessibilityElement(children: .combine)
    }
}
