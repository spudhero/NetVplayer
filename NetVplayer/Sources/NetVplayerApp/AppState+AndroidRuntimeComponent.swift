import Foundation
import SpiderEngine

extension AppState {
    func refreshAndroidRuntimeComponent() async {
        do {
            let status = try await AndroidRuntimeComponentStore.application().status()
            androidRuntimeComponentVersion = status.version
            androidRuntimePreviousVersion = status.previousVersion
            androidRuntimeComponentError = nil
        } catch {
            androidRuntimeComponentVersion = nil
            androidRuntimePreviousVersion = try? await AndroidRuntimeComponentStore.application().previousVersion()
            androidRuntimeComponentError = error.localizedDescription
        }
    }

    func installAndroidRuntimeComponent(directory: URL) async {
        guard !androidRuntimeComponentBusy else { return }
        androidRuntimeComponentBusy = true
        defer { androidRuntimeComponentBusy = false }
        do {
            let status = try await AndroidRuntimeComponentStore.application().install(directory: directory)
            androidRuntimeComponentVersion = status.version
            androidRuntimePreviousVersion = status.previousVersion
            androidRuntimeComponentError = nil
            androidRuntimeComponentRequiresRestart = true
        } catch { androidRuntimeComponentError = error.localizedDescription }
    }

    func rollbackAndroidRuntimeComponent() async {
        guard !androidRuntimeComponentBusy else { return }
        androidRuntimeComponentBusy = true
        defer { androidRuntimeComponentBusy = false }
        do {
            let status = try await AndroidRuntimeComponentStore.application().rollback()
            androidRuntimeComponentVersion = status.version
            androidRuntimePreviousVersion = status.previousVersion
            androidRuntimeComponentError = nil
            androidRuntimeComponentRequiresRestart = true
        } catch { androidRuntimeComponentError = error.localizedDescription }
    }
}
