import Testing
@testable import NetVplayerApp

@Suite("Themed dialog lifecycle")
@MainActor
struct AppDialogCenterTests {
    @Test
    func selectionResumesOnceAndValidatesItsOwner() async throws {
        let center = AppDialogCenter()
        let task = Task { await center.present(title: "Choose", message: "", confirmTitle: "Open", choices: ["A", "B"]) }
        let request = try await pendingRequest(in: center)
        center.complete(id: request.id, selection: 9)
        #expect(center.request != nil)
        center.complete(id: request.id, selection: 1)
        #expect(await task.value == 1)
        #expect(center.request == nil)
        center.complete(id: request.id, selection: nil)
    }

    @Test
    func dismissingAnOldSheetDoesNotCancelTheNextRequest() async throws {
        let center = AppDialogCenter()
        let first = Task { await center.present(title: "First", message: "", confirmTitle: "OK") }
        let old = try await pendingRequest(in: center)
        center.complete(id: old.id, selection: nil)
        #expect(await first.value == nil)
        let second = Task { await center.present(title: "Second", message: "", confirmTitle: "OK") }
        let current = try await pendingRequest(in: center)
        center.complete(id: old.id, selection: nil)
        #expect(center.request?.id == current.id)
        center.complete(id: current.id, selection: 0)
        #expect(await second.value == 0)
    }

    @Test
    func taskCancellationDismissesTheSheetAndAllowsAnotherRequest() async throws {
        let center = AppDialogCenter()
        let task = Task { await center.present(title: "Waiting", message: "", confirmTitle: "OK") }
        _ = try await pendingRequest(in: center)
        task.cancel()
        #expect(await task.value == nil)
        #expect(center.request == nil)
    }

    @Test
    func competingPresentationKeepsTheActiveChoice() async throws {
        let center = AppDialogCenter()
        let task = Task { await center.present(title: "Active", message: "", confirmTitle: "OK") }
        let request = try await pendingRequest(in: center)
        #expect(await center.present(title: "Other", message: "", confirmTitle: "OK") == nil)
        #expect(center.request?.id == request.id)
        center.complete(id: request.id, selection: nil)
        #expect(await task.value == nil)
    }

    private func pendingRequest(in center: AppDialogCenter) async throws -> AppDialogRequest {
        for _ in 0..<100 where center.request == nil { await Task.yield() }
        return try #require(center.request)
    }
}
