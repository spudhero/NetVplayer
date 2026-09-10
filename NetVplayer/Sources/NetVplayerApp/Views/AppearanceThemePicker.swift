import SwiftUI

struct AppearanceThemePicker: View {
    let selectedThemeID: AppAppearanceThemeID
    let onSelect: (AppAppearanceThemeID) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 230, maximum: 290), spacing: 12),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            themeGroup(
                title: "亮色主题",
                systemImage: "sun.max",
                ids: AppThemeCatalog.lightThemeIDs
            )

            themeGroup(
                title: "暗色主题",
                systemImage: "moon.stars",
                ids: AppThemeCatalog.darkThemeIDs
            )
        }
    }

    private func themeGroup(
        title: String,
        systemImage: String,
        ids: [AppAppearanceThemeID]
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(ids) { id in
                    AppearanceThemePreview(
                        palette: AppThemeCatalog.palette(for: id),
                        isSelected: selectedThemeID == id,
                        onSelect: { onSelect(id) }
                    )
                }
            }
        }
    }
}

private struct AppearanceThemePreview: View {
    let palette: AppThemePalette
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            ZStack {
                AppThemeBackdropLayer(palette: palette)

                HStack(spacing: 0) {
                    miniatureSidebar

                    VStack(alignment: .leading, spacing: 10) {
                        header
                        miniaturePanel
                    }
                    .padding(11)
                }
            }
            .frame(height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        isSelected
                            ? palette.accent.opacity(0.92)
                            : palette.foreground.opacity(isHovered ? 0.28 : 0.14),
                        lineWidth: isSelected ? 2 : 1
                    )
            }
            .shadow(
                color: isSelected
                    ? palette.accent.opacity(0.18)
                    : Color.black.opacity(isHovered ? 0.16 : 0.08),
                radius: isHovered ? 10 : 5,
                y: 3
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.14), value: isHovered)
        .accessibilityLabel("\(palette.id.displayName)主题")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var miniatureSidebar: some View {
        VStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(palette.surface.opacity(0.78))
                .frame(width: 20, height: 20)
                .overlay {
                    Image(systemName: palette.id.symbolName)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(palette.accent)
                }

            ForEach(0..<3, id: \.self) { index in
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(
                        index == 1
                            ? AnyShapeStyle(
                                LinearGradient(
                                    colors: [
                                        palette.accent.opacity(
                                            palette.surfaceTokens.selectionPrimaryOpacity
                                        ),
                                        palette.lavender.opacity(
                                            palette.surfaceTokens.selectionSecondaryOpacity
                                        ),
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            : AnyShapeStyle(Color.clear)
                    )
                    .frame(width: 28, height: 17)
                    .overlay {
                        Circle()
                            .fill(index == 1 ? palette.accent : palette.muted.opacity(0.5))
                            .frame(width: 7, height: 7)
                    }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .frame(width: 42)
        .background(
            palette.surface.opacity(palette.surfaceTokens.primarySidebarChromeOpacity)
        )
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(palette.foreground.opacity(0.10))
                .frame(width: 1)
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Text(palette.id.displayName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.foreground)
                .lineLimit(1)

            Spacer(minLength: 4)

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.accent)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, palette.id == .monochromeFlow ? 6 : 0)
        .padding(.vertical, palette.id == .monochromeFlow ? 4 : 0)
        .background {
            if palette.id == .monochromeFlow {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(palette.surface.opacity(0.90))
            }
        }
    }

    private var miniaturePanel: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Circle().fill(palette.accent)
                Circle().fill(palette.lavender)
            }
            .frame(width: 26, height: 10)

            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(palette.accent)
                .frame(width: 38, height: 22)
                .overlay {
                    Image(systemName: "play.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(palette.color(for: .onAccent))
                }

            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(
                    palette.surface.opacity(
                        palette.surfaceTokens.controlOpacity + 0.18
                    )
                )
                .frame(maxWidth: .infinity)
                .frame(height: 22)
                .overlay(alignment: .leading) {
                    Image(systemName: "film")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(palette.lavender)
                        .padding(.leading, 7)
                }
        }
        .padding(9)
        .background(
            palette.surface.opacity(palette.surfaceTokens.panelOpacity),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(
                    palette.foreground.opacity(palette.surfaceTokens.borderOpacity),
                    lineWidth: 1
                )
        }
    }
}
