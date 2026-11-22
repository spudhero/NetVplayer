import SwiftUI

/// Shared chrome for player dialogs and popovers, including playback completion.
struct PlayerGlassPanel: View {
    var cornerRadius: CGFloat = 22
    var strokeOpacity: Double = 0.28

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.ultraThinMaterial)
            .opacity(PlayerHUDVisualPolicy.glassPanelMaterialOpacity)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(PlayerHUDPalette.surface.opacity(PlayerHUDVisualPolicy.glassPanelSurfaceOpacity))
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(LinearGradient(
                        colors: [PlayerHUDPalette.lavender.opacity(strokeOpacity),
                                 PlayerHUDPalette.accent.opacity(strokeOpacity * 0.75), .white.opacity(0.08)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ), lineWidth: 1)
            }
            .shadow(color: PlayerHUDPalette.accent.opacity(0.12), radius: 18, x: 0, y: 8)
    }
}

struct PlayerControlPopover<Content: View>: View {
    static var arrowHeight: CGFloat { 8 }
    let arrowX: CGFloat
    let cornerRadius: CGFloat
    let content: Content

    init(arrowX: CGFloat, cornerRadius: CGFloat, @ViewBuilder content: () -> Content) {
        self.arrowX = arrowX
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    var body: some View {
        let shape = PlayerControlPopoverShape(arrowX: arrowX, arrowHeight: Self.arrowHeight, cornerRadius: cornerRadius)
        ViewThatFits(in: .vertical) {
            content.fixedSize(horizontal: false, vertical: true)
            ScrollView { content }
        }
        .padding(.bottom, Self.arrowHeight)
        .foregroundStyle(PlayerHUDPalette.foreground)
        .background {
            PlayerTransportGlass(shape: shape)
                .contentShape(shape)
                .onTapGesture { }
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
    }
}

struct PlayerTransportGlass<Surface: Shape>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let shape: Surface

    var body: some View {
        ZStack {
            if reduceTransparency {
                shape.fill(PlayerHUDPalette.surface)
            } else {
                shape.fill(.ultraThinMaterial).opacity(PlayerHUDVisualPolicy.bottomGlassMaterialOpacity)
                shape.fill(PlayerHUDPalette.surface.opacity(PlayerHUDVisualPolicy.bottomGlassSurfaceOpacity))
            }
            shape.stroke(LinearGradient(
                colors: [PlayerHUDPalette.lavender.opacity(0.25), PlayerHUDPalette.accent.opacity(0.12), .white.opacity(0.06)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ), lineWidth: 1)
            shape.fill(LinearGradient(
                colors: [.white.opacity(PlayerHUDVisualPolicy.bottomGlassTopHighlightOpacity),
                         PlayerHUDPalette.lavender.opacity(0.03), .clear],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ))
            shape.stroke(.black.opacity(PlayerHUDVisualPolicy.bottomGlassBottomInsetOpacity), lineWidth: 1)
        }
        .shadow(color: .black.opacity(PlayerHUDVisualPolicy.bottomGlassShadowOpacity),
                radius: PlayerHUDVisualPolicy.bottomGlassShadowRadius, y: 18)
    }
}

struct PlayerProgressThumb: View {
    let isEnabled: Bool

    var body: some View {
        Circle()
            .fill(.white.opacity(isEnabled ? 0.98 : 0.45))
            .frame(width: PlayerHUDVisualPolicy.timelineThumbSize, height: PlayerHUDVisualPolicy.timelineThumbSize)
            .overlay {
                Circle().stroke(PlayerHUDPalette.accent.opacity(isEnabled
                    ? PlayerHUDVisualPolicy.timelineThumbBorderOpacity : PlayerHUDVisualPolicy.activeLavenderShadowOpacity),
                    lineWidth: 2)
            }
            .shadow(color: PlayerHUDPalette.accent.opacity(isEnabled ? PlayerHUDVisualPolicy.timelineThumbShadowOpacity : 0),
                    radius: PlayerHUDVisualPolicy.timelineThumbShadowRadius)
    }
}

private struct PlayerControlPopoverShape: Shape {
    let arrowX: CGFloat
    let arrowHeight: CGFloat
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let body = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(0, rect.height - arrowHeight))
        let halfArrow: CGFloat = 8
        let center = min(max(cornerRadius + halfArrow, arrowX), body.width - cornerRadius - halfArrow)
        let corners = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).path(in: body)
        let arrow = Path { path in
            path.move(to: CGPoint(x: center - halfArrow, y: body.maxY - 1))
            path.addLine(to: CGPoint(x: center, y: rect.maxY))
            path.addLine(to: CGPoint(x: center + halfArrow, y: body.maxY - 1))
            path.closeSubpath()
        }
        return corners.union(arrow)
    }
}

struct PlayerControlPopoverRowStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration, isSelected: isSelected)
    }

    private struct Row: View {
        let configuration: Configuration
        let isSelected: Bool
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(fill)
                }
                .onHover { isHovered = $0 }
        }

        private var fill: Color {
            let highlighted = isHovered || configuration.isPressed
            if isSelected {
                return PlayerHUDPalette.lavender.opacity(highlighted
                    ? PlayerHUDVisualPolicy.activeLavenderShadowOpacity : PlayerHUDVisualPolicy.activeLavenderBackgroundOpacity)
            }
            return .white.opacity(highlighted ? PlayerHUDVisualPolicy.topControlBackgroundOpacity : 0)
        }
    }
}
