import Models
import SwiftUI

/// Shared hierarchy for the subtitle tools and display utility. Colors always
/// come from the active application theme, including semantic status colors.
struct FeaturePanelHeader: View {
    @Environment(\.appThemePalette) private var palette
    let title: String
    let subtitle: String
    let systemImage: String
    let close: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(palette.accent)
                .frame(width: 40, height: 40)
                .background(palette.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 20, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(action: close) { Image(systemName: "xmark").frame(width: 20, height: 20) }
                .buttonStyle(.borderless)
                .foregroundStyle(palette.muted)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel(L10n.text("关闭"))
                .help(L10n.text("关闭"))
        }
    }
}

struct FeatureStepCard<Content: View>: View {
    @Environment(\.appThemePalette) private var palette
    let number: Int
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(String(number)).font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(palette.accent)
                    .frame(width: 22, height: 22)
                    .background(palette.accent.opacity(0.12), in: Circle())
                    .accessibilityHidden(true)
                Text(title).font(.system(size: 13, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(palette.surface.opacity(0.62), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(palette.foreground.opacity(0.08), lineWidth: 1) }
    }
}

struct FeatureNotice: View {
    @Environment(\.appThemePalette) private var palette
    let message: String
    var role: AppSemanticColorRole = .secondaryText
    var systemImage = "info.circle"

    var body: some View {
        Label {
            Text(message).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage).accessibilityHidden(true)
        }
        .font(.system(size: 12))
        .foregroundStyle(palette.color(for: role))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(palette.color(for: role).opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .textSelection(.enabled)
    }
}

struct FeatureProgress: View {
    @Environment(\.appThemePalette) private var palette
    let title: String
    let completed: Int
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title)
                Spacer()
                Text("\(completed) / \(total)").monospacedDigit()
            }
            .font(.system(size: 12))
            .foregroundStyle(palette.muted)
            ProgressView(value: Double(completed), total: Double(max(1, total)))
                .tint(total > 0 && completed >= total ? palette.color(for: .success) : palette.accent)
                .accessibilityLabel(title)
                .accessibilityValue("\(completed) / \(total)")
        }
    }
}
