import SwiftUI

/// Shared visual container; each segment remains a native, keyboard-accessible Button.
struct ThemedSegmentedControl<Content: View>: View {
    @Environment(\.appThemePalette) private var palette
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 0, content: content)
            .background(palette.surface.opacity(palette.surfaceOpacity(for: .control, reduceTransparency: reduceTransparency)),
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(palette.foreground.opacity(palette.surfaceTokens.borderOpacity))
                    .allowsHitTesting(false)
            }
    }
}

struct ThemedSegmentButton: View {
    @Environment(\.appThemePalette) private var palette
    @FocusState private var isFocused: Bool
    let title: String
    var systemImage: String? = nil
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .foregroundStyle(isSelected ? palette.accent : palette.muted)
                        .accessibilityHidden(true)
                }
                Text(title).lineLimit(1).fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 32)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(ThemedSegmentButtonStyle(isSelected: isSelected))
        .focused($isFocused)
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isFocused ? palette.color(for: .focusRing) : .clear, lineWidth: 2)
                .padding(-3).allowsHitTesting(false)
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct ThemedSegmentButtonStyle: ButtonStyle {
    @Environment(\.appThemePalette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? palette.foreground : palette.muted)
            .background(isSelected
                ? palette.accent.opacity(palette.surfaceTokens.selectionPrimaryOpacity)
                : palette.foreground.opacity(configuration.isPressed ? 0.12 : hovering ? 0.06 : 0),
                in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? palette.accent : .clear, lineWidth: 1)
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .onHover { hovering = $0 }
    }
}
