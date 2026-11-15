import AppKit
import Combine
import Foundation
import Models
import Storage

@MainActor
final class LocalAutomationController: ObservableObject {
    @Published private(set) var port: UInt16?
    @Published private(set) var busy = false
    @Published private(set) var failed = false
    @Published private(set) var copied = false
    @Published private(set) var selectedServices: [String: UUID] = [:]
    private let read: LocalReadOnlyServer.Read
    private lazy var server = LocalReadOnlyServer(onFailure: { [weak self] in
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.port = nil; self.failed = true; self.copied = false; self.clearOwnClipboard()
        }
    }, read: read)
    private var clipboardChange: Int?
    init(read: @escaping LocalReadOnlyServer.Read) { self.read = read }
    var enabled: Bool { port != nil }
    var baseURL: String? { port.map { "http://127.0.0.1:\($0)" } }
    func setEnabled(_ enabled: Bool) async {
        guard !busy else { return }
        busy = true; failed = false; defer { busy = false }
        if enabled {
            do { port = try await server.start() }
            catch { port = nil; failed = true }
        } else { await shutdown() }
    }
    func shutdown() async {
        await server.stop(); port = nil; clearOwnClipboard(); copied = false
    }
    func rotate() async {
        guard enabled, !busy else { return }
        busy = true; defer { busy = false }
        clearOwnClipboard(); copied = false
        do { try await server.rotateToken(); await copyToken() }
        catch { await shutdown(); failed = true }
    }
    func copyToken() async {
        guard let token = await server.tokenForUser(), enabled else { return }
        let clipboard = NSPasteboard.general
        clipboard.clearContents(); clipboard.setString(token, forType: .string)
        clipboardChange = clipboard.changeCount; copied = true
    }
    private func clearOwnClipboard() {
        if let clipboardChange, NSPasteboard.general.changeCount == clipboardChange { NSPasteboard.general.clearContents() }
        clipboardChange = nil
    }
    func select(_ key: String, enabled: Bool) {
        if enabled, selectedServices.count < 32 { selectedServices[key] = selectedServices[key] ?? UUID() }
        else { selectedServices[key] = nil }
    }
}

struct AutomationServiceChoice: Identifiable {
    enum Kind: String, Encodable { case local, smb, webDAV, alist, openList, emby, jellyfin }
    let id: String
    let name: String
    let kind: Kind
    let scope: ServiceConnectionObservations.Scope
}

extension AppState {
    /// Configuration names exist only in the native selection UI. Only a fresh
    /// session alias and enum can cross the HTTP boundary, never the saved ID.
    var automationServiceChoices: [AutomationServiceChoice] {
        let files = fileServiceStore.load().services.prefix(256).map {
            AutomationServiceChoice(id: "file:" + $0.id.uuidString, name: $0.name,
                kind: .init(rawValue: $0.kind.rawValue)!, scope: fileServiceStore.connectionObservationScope($0))
        }
        let servers = mediaServerStore.load().prefix(256).map {
            AutomationServiceChoice(id: "server:" + $0.id.uuidString, name: $0.name,
                kind: .init(rawValue: $0.kind.rawValue)!, scope: mediaServerStore.connectionObservationScope($0))
        }
        return files + servers
    }

    func localAutomationData(_ endpoint: LocalReadOnlyServer.Endpoint, now: Date = Date()) async throws -> Data {
        guard !isTerminating else { throw LocalReadOnlyServer.Failure.unavailable }
        switch endpoint {
        case .tasks:
            // Match the manual MSC-06 export. In particular, a query must not
            // initialize a scanner/runtime singleton just to inspect activity.
            return try taskDiagnosticStore.exportData(now: now, activeTaskIDs: activeTaskDiagnosticIDs)
        case .services:
            struct Service: Encodable {
                let serviceID: UUID; let kind: AutomationServiceChoice.Kind
                let connection: ServiceConnectionObservations.Snapshot
            }
            struct Report: Encodable { let schemaVersion: Int; let generatedAt: Date; let services: [Service] }
            let choices = automationServiceChoices
            let values = localAutomation.selectedServices.sorted { $0.key < $1.key }.compactMap { key, alias -> Service? in
                guard let choice = choices.first(where: { $0.id == key }) else { return nil }
                return .init(serviceID: alias, kind: choice.kind,
                    connection: ServiceConnectionObservations.shared.snapshot(choice.scope, now: now))
            }
            return try automationEncode(Report(schemaVersion: 1, generatedAt: now, services: values))
        case .health:
            enum Health: String, Encodable { case ready, startupDeferred, startupDegraded }
            enum History: String, Encodable { case readable, unavailable }
            struct Report: Encodable {
                let schemaVersion: Int; let generatedAt: Date; let application: Health
                let taskHistory: History; let readOnly: Bool
            }
            let history: History = (try? taskDiagnosticStore.records(now: now)) != nil ? .readable : .unavailable
            return try automationEncode(Report(schemaVersion: 1, generatedAt: now,
                application: startupServiceFailed ? .startupDegraded : startupRestorationDeferred ? .startupDeferred : .ready,
                taskHistory: history, readOnly: true))
        }
    }
    private func automationEncode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }
}
