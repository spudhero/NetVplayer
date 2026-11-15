import AppKit
import SwiftUI
import Models

/// Original horizontal artwork, with its proportions intact. Black/white is
/// chosen for the surface; confirmation color belongs to the surrounding UI.
@MainActor struct DolbyFormatLogo: View {
    let format: DolbyMediaFormat
    var height: CGFloat = 14
    @Environment(\.colorScheme) private var colorScheme
    private static let artwork: [DolbyMediaFormat: NSImage] = Dictionary(uniqueKeysWithValues:
        DolbyMediaFormat.allCases.compactMap { format in
            guard let url = AppThemeResourceBundle.bundle.url(forResource: format.assetName, withExtension: "png"),
                  let image = NSImage(contentsOf: url) else { return nil }
            return (format, image)
        })

    var body: some View {
        Group {
            if let artwork = Self.artwork[format] {
                Image(nsImage: artwork).renderingMode(.template).resizable()
                    .aspectRatio(format.aspectRatio, contentMode: .fit)
                    .frame(width: format.aspectRatio * height, height: height)
                    .foregroundStyle(colorScheme == .dark ? Color.white : .black)
            } else {
                Text(format.rawValue).font(.system(size: height, weight: .semibold))
            }
        }.accessibilityLabel(format.rawValue)
    }
}

struct DolbySourceBadges: View {
    let formats: [DolbySourceFormat]
    @Environment(\.appThemePalette) private var palette

    var body: some View {
        if !formats.isEmpty {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { badges }
                VStack(alignment: .leading, spacing: 8) { badges }
            }
        }
    }

    @ViewBuilder private var badges: some View {
        ForEach(formats) { source in
            DolbyFormatLogo(format: source.format)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(palette.foreground.opacity(0.045), in: RoundedRectangle(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).stroke(palette.foreground.opacity(0.12)) }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L10n.text("片源格式：{0}", [source.format.rawValue]))
                .accessibilityHint(explanation(source.evidence))
                .help(explanation(source.evidence))
        }
    }

    private func explanation(_ evidence: DolbySourceFormat.Evidence) -> String {
        switch evidence {
        case .server: L10n.text("服务器标记的片源格式；实际输出请查看播放器。")
        case .filename: L10n.text("文件名标记的片源格式，尚未验证；实际输出请查看播放器。")
        }
    }
}
