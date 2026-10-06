import SwiftUI
import Models

/// Shared by settings and the player so a failed source never traps the user.
struct LiveSourcePicker: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Picker(L10n.text("直播源"), selection: Binding(
            get: { appState.activeLive?.name ?? "" },
            set: { name in
                guard let live = appState.lives.first(where: { $0.name == name }) else { return }
                Task { await appState.changeLive(live) }
            }
        )) {
            if appState.activeLive == nil {
                Text(L10n.text("选择直播源")).tag("")
            }
            ForEach(appState.lives) { live in
                Text(live.name).tag(live.name)
            }
        }
        .pickerStyle(.menu)
        .disabled(appState.lives.isEmpty || appState.isLoadingLiveConfiguration)
        .help(L10n.text("选择直播源"))
        .accessibilityIdentifier("live-source-picker")
    }
}
