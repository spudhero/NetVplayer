import Foundation
import Models
import SpiderEngine

extension AppState {
    func updateAndroidRuntimePreparation(phase: String) {
        if phase == "failed" {
            androidRuntimeComponentBusy = false
            androidRuntimeComponentProgress = nil
            androidRuntimeComponentError = L10n.text("Android 运行组件准备失败，请检查网络后重试。")
            return
        }
        androidRuntimeComponentBusy = phase != "ready"
        let message: String
        switch phase {
        case "checking": message = "正在检查 Android 运行组件…"
        case "downloading-installer": message = "正在下载 Android 安装组件…"
        case "downloading-java", "installing-java": message = "正在准备 Java 运行环境…"
        case "downloading-framework", "preparing-framework": message = "正在准备 Android 兼容框架…"
        case "downloading-host", "preparing-host": message = "正在准备 Android 宿主…"
        case "downloading-compatibility": message = "正在下载 Android 兼容依赖…"
        case "verifying-runtime", "activating": message = "正在校验并启用 Android 运行组件…"
        case "ready": message = "Android 运行组件已就绪"
        default: message = "正在准备 Android 运行组件…"
        }
        androidRuntimeComponentProgress = L10n.text(message)
        androidRuntimeComponentError = nil
    }

    func prepareAndroidRuntimeAutomatically() async {
        guard !androidRuntimeComponentBusy else { return }
        androidRuntimeComponentBusy = true
        defer { androidRuntimeComponentBusy = false }
        do {
            try await DevelopmentAndroidSiteProvider.prepareRuntime { [weak self] phase in
                await self?.updateAndroidRuntimePreparation(phase: phase)
            }
            await refreshAndroidRuntimeComponent()
            // Replace any unavailable source registrations in this process.
            let configURL = libraryConfigurationURL.isEmpty ? userPreferences.currentVodConfigUrl : libraryConfigurationURL
            if !configURL.isEmpty {
                await loadConfig(url: configURL, persistUserConfig: false, restoreSavedConfiguration: true)
            }
        } catch {
            androidRuntimeComponentError = L10n.text("Android 运行组件准备失败，请检查网络后重试。")
        }
    }

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
