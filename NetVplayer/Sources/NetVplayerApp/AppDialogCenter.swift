import Foundation
import Combine

struct AppDialogRequest: Identifiable {
    let id: UUID
    let title: String
    let message: String
    let confirmTitle: String
    var choices: [String] = []
    var allowsCancel = true
    var isDestructive = false
}

/// Lets async navigation await a themed choice without blocking the AppKit run loop.
@MainActor
final class AppDialogCenter: ObservableObject {
    static let shared = AppDialogCenter()
    @Published private(set) var request: AppDialogRequest?
    private var continuation: CheckedContinuation<Int?, Never>?

    func present(
        title: String, message: String, confirmTitle: String,
        choices: [String] = [], allowsCancel: Bool = true, isDestructive: Bool = false
    ) async -> Int? {
        guard request == nil, !Task.isCancelled else { return nil }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                request = AppDialogRequest(
                    id: id, title: title, message: message, confirmTitle: confirmTitle,
                    choices: choices, allowsCancel: allowsCancel, isDestructive: isDestructive
                )
            }
        } onCancel: {
            Task { @MainActor in self.complete(id: id, selection: nil) }
        }
    }

    func complete(id: UUID, selection: Int?) {
        guard let request, request.id == id else { return }
        if let selection, !request.choices.isEmpty, !request.choices.indices.contains(selection) { return }
        let pending = continuation
        continuation = nil
        self.request = nil
        pending?.resume(returning: selection)
    }
}
