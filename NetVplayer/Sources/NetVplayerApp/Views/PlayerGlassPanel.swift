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
