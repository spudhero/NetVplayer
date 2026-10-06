import SwiftUI
import Models

/// Shared surface for app-owned sheets and popovers, including light themes.
private struct ThemedPresentationSurface: ViewModifier {
    @Environment(\.appThemePalette) private var palette

    func body(content: Content) -> some View {
        content
            .foregroundStyle(palette.foreground)
            .tint(palette.accent)
            .preferredColorScheme(palette.preferredColorScheme)
            .background {
                AppThemeBackdropLayer(palette: palette)
                    .overlay(palette.surface.opacity(0.35))
                    .clipped()
                    .ignoresSafeArea()
            }
            .presentationBackground(palette.surface)
    }
}

extension View {
    func themedPresentation() -> some View {
        modifier(ThemedPresentationSurface())
    }

    func themedConfirmation(
        _ title: String,
        isPresented: Binding<Bool>,
        confirmTitle: String,
        message: String,
        role: ButtonRole? = .destructive,
        action: @escaping () -> Void
    ) -> some View {
        sheet(isPresented: isPresented) {
            SettingsEditorContainer(title: title, width: 500) {
                Text(message)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } actions: {
                Spacer()
                Button(L10n.text("取消")) { isPresented.wrappedValue = false }
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle, role: role) {
                    // Run first: the presentation binding may clear the selected record.
                    action()
                    isPresented.wrappedValue = false
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

struct AppDialogView: View {
    let request: AppDialogRequest
    let complete: (Int?) -> Void
    @State private var selection = 0

    var body: some View {
        SettingsEditorContainer(title: request.title, width: 520) {
            Text(request.message)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if !request.choices.isEmpty {
                SettingsControlRow(title: L10n.text("原始配置"), labelWidth: 100) {
                    SettingsChoicePicker(
                        title: L10n.text("原始配置"), selection: $selection,
                        choices: Array(request.choices.indices), label: { request.choices[$0] }
                    )
                }.padding(.top, 12)
            }
        } actions: {
            Spacer()
            if request.allowsCancel {
                Button(L10n.text("取消")) { complete(nil) }.keyboardShortcut(.cancelAction)
            }
            Button(request.confirmTitle, role: request.isDestructive ? .destructive : nil) {
                complete(selection)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
    }
}
