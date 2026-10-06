import SwiftUI
import Models

enum FormFieldRequirement {
    case required, optional, serverDependent

    var title: String {
        switch self {
        case .required: L10n.text("必填")
        case .optional: L10n.text("选填")
        case .serverDependent: L10n.text("按需填写")
        }
    }
}

struct FormFieldLabel: View {
    @Environment(\.appThemePalette) private var palette
    let title: String
    var requirement: FormFieldRequirement?

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 13, weight: .semibold))
            if let requirement {
                Text(requirement.title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(palette.muted)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(palette.foreground.opacity(0.06), in: Capsule())
            }
        }
    }
}

struct SettingsPasswordField: View {
    @Environment(\.appThemePalette) private var palette
    @Environment(\.scenePhase) private var scenePhase
    let title: String
    @Binding var text: String
    @State private var revealed = false
    @FocusState private var focus: Field?
    private enum Field { case secure, visible }

    init(_ title: String, text: Binding<String>) {
        self.title = title
        _text = text
    }

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if revealed {
                    TextField(title, text: $text).focused($focus, equals: .visible)
                } else {
                    SecureField(title, text: $text).focused($focus, equals: .secure)
                }
            }
            .textFieldStyle(.plain)
            .accessibilityLabel(title)
            .frame(maxWidth: .infinity)
            Button {
                revealed.toggle()
                focus = revealed ? .visible : .secure
            } label: {
                Image(systemName: revealed ? "eye.slash" : "eye")
                    .font(.system(size: 13))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.muted)
            .accessibilityLabel(revealed ? L10n.text("隐藏密码或令牌") : L10n.text("显示密码或令牌"))
            .help(revealed ? L10n.text("隐藏内容") : L10n.text("显示内容，检查是否填写正确"))
        }
        .padding(.leading, 10).padding(.trailing, 4).padding(.vertical, 4)
        .frame(minHeight: 34)
        .foregroundStyle(palette.foreground)
        .background { AppGlassSurface(cornerRadius: 8, role: .control, usesSystemMaterial: false) }
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(focus != nil ? palette.accent : .clear, lineWidth: 2) }
        .onChange(of: scenePhase) { _, phase in if phase != .active { revealed = false } }
        .onDisappear { revealed = false }
    }
}
