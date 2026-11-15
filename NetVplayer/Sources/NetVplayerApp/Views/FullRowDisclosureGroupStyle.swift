import Models
import SwiftUI

/// A disclosure header is one keyboard-accessible button, including its empty space.
/// The expanded content is a sibling, so its controls and selectable text stay independent.
struct FullRowDisclosureGroupStyle: DisclosureGroupStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var cardPadding: CGFloat = 0

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .frame(width: 12)
                        .accessibilityHidden(true)
                    configuration.label
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, cardPadding)
                .padding(.vertical, max(4, cardPadding))
                .frame(maxWidth: .infinity, minHeight: cardPadding > 0 ? 44 : 36, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? L10n.text("已展开") : L10n.text("已折叠"))

            if configuration.isExpanded {
                configuration.content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, cardPadding)
                    .padding(.bottom, cardPadding)
            }
        }
    }
}
