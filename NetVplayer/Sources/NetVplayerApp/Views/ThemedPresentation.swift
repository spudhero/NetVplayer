import SwiftUI
import Models

/// App-owned actions use theme colors even when macOS highlights a default button.
struct ThemedDialogButtonStyle: ButtonStyle {
    @Environment(\.appThemePalette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false
    var isPrimary = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: isPrimary ? .semibold : .regular))
            .foregroundStyle(isPrimary ? palette.color(for: .onAccent)
                : configuration.role == .destructive ? palette.color(for: .danger) : palette.foreground)
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .background(isPrimary ? palette.accent
                : palette.foreground.opacity(configuration.isPressed ? 0.14 : hovering ? 0.10 : 0.06),
                in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isPrimary ? palette.accent : palette.foreground.opacity(0.16), lineWidth: 1)
            }
            .opacity(isEnabled ? (configuration.isPressed && isPrimary ? 0.8 : 1) : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .onHover { hovering = $0 }
    }
}

/// Shared surface for app-owned sheets and popovers, including light themes.
private struct ThemedPresentationSurface: ViewModifier {
    @Environment(\.appThemePalette) private var palette

    func body(content: Content) -> some View {
        content
            .foregroundStyle(palette.foreground)
            .tint(palette.accent)
            .buttonStyle(ThemedDialogButtonStyle())
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
                .buttonStyle(ThemedDialogButtonStyle(isPrimary: true))
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
            .buttonStyle(ThemedDialogButtonStyle(isPrimary: true))
            .keyboardShortcut(.defaultAction)
        }
    }
}
