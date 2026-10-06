import SwiftUI
import Models

struct SubtitleAppearanceControls: View {
    @Binding var appearance: SubtitleAppearance
    var isBitmap = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if isBitmap {
                Text(L10n.text("图片字幕使用缩放，字体和颜色由片源决定。"))
                    .font(.caption).foregroundStyle(.secondary)
                SubtitleSettingSlider(title: L10n.text("图片字幕缩放"), value: $appearance.bitmapScale,
                    range: 0.5...3, step: 0.1, valueText: String(format: "%.1f×", appearance.bitmapScale))
            } else {
                HStack {
                    Text(L10n.text("字体"))
                    Spacer()
                    choiceMenu(title: L10n.text("字幕字体"), value: appearance.fontName) {
                        ForEach(["PingFang SC", "Heiti SC", "Arial"], id: \.self) { font in
                            Button { appearance.fontName = font } label: {
                                if appearance.fontName == font { Label(font, systemImage: "checkmark") }
                                else { Text(font) }
                            }
                        }
                    }
                }
                HStack {
                    Text(L10n.text("颜色"))
                    Spacer()
                    choiceMenu(title: L10n.text("字幕颜色"), value: appearance.color.displayName) {
                        ForEach(SubtitleTextColor.allCases, id: \.self) { color in
                            Button { appearance.color = color } label: {
                                if appearance.color == color { Label(color.displayName, systemImage: "checkmark") }
                                else { Text(color.displayName) }
                            }
                        }
                    }
                }
                SubtitleSettingSlider(title: L10n.text("描边宽度"), value: $appearance.borderWidth,
                    range: 0...5, step: 0.5, valueText: String(format: "%.1f", appearance.borderWidth))
                SubtitleSettingSlider(title: L10n.text("背景不透明度"), value: $appearance.backgroundOpacity,
                    range: 0...1, step: 0.1, valueText: "\(Int(appearance.backgroundOpacity * 100))%")
            }
        }
        .font(.system(size: 13))
    }

    private func choiceMenu<Options: View>(title: String, value: String, @ViewBuilder options: () -> Options) -> some View {
        Menu(content: options) {
            HStack(spacing: 8) {
                Text(value).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
            }
            .padding(.horizontal, 10).frame(width: 180, height: 32)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .accessibilityLabel(title).accessibilityValue(value)
    }
}

struct SubtitleSettingSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let valueText: String

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(valueText).monospacedDigit().foregroundStyle(.secondary)
            }.font(.system(size: 13))
            Slider(value: $value, in: range, step: step)
                .labelsHidden().accessibilityLabel(title).accessibilityValue(valueText)
        }
    }
}
