import Models
import PlayerEngine
import SwiftUI

struct PlaybackSettingsDisclosure<Content: View>: View {
    @Environment(\.appThemePalette) private var palette
    @State private var expanded: Bool
    let title: String
    let summary: String
    let systemImage: String
    let content: Content

    init(
        _ title: String, summary: String, systemImage: String,
        initiallyExpanded: Bool = false, @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.summary = summary
        self.systemImage = systemImage
        self.content = content()
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 12) { content }
                .padding(.top, 12)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: systemImage).foregroundStyle(palette.accent)
                    .frame(width: 20).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(palette.foreground)
                    Text(summary).font(.system(size: 11)).foregroundStyle(palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
        .tint(palette.accent)
        .disclosureGroupStyle(FullRowDisclosureGroupStyle(cardPadding: 12))
        .background(palette.foreground.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(palette.foreground.opacity(0.08), lineWidth: 1) }
    }
}

struct PlaybackSettingField<Content: View>: View {
    @Environment(\.appThemePalette) private var palette
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11)).foregroundStyle(palette.muted)
            content.frame(maxWidth: .infinity, alignment: .leading)
                .labelsHidden()
                .accessibilityLabel(title)
        }
    }
}

struct PlaybackOutputSettingRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title).foregroundStyle(.secondary).frame(width: 100, alignment: .leading)
            content.labelsHidden().frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityLabel(title)
        }
        .font(.system(size: 12)).frame(minHeight: 44)
    }
}

struct PlaybackOutputActualSummary: View {
    let status: PlaybackFormatStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(status?.actualOutput ?? L10n.text("播放后显示实际输出"))
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(status?.compactIsActive == true ? PlaybackFormatPalette.active : .primary)
                .fixedSize(horizontal: false, vertical: true)
            if let device = status?.device {
                Text(device).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }.accessibilityElement(children: .combine)
    }
}

struct PlaybackOutputTechnicalInfo<AdditionalInfo: View>: View {
    let status: PlaybackFormatStatus?
    @ViewBuilder let additionalInfo: AdditionalInfo

    var body: some View {
        DisclosureGroup(L10n.text("技术信息")) {
            VStack(alignment: .leading, spacing: 10) {
                if let status {
                    LabeledContent(L10n.text("片源"), value: status.source)
                    ForEach(status.details, id: \.label) { detail in
                        LabeledContent(detail.label, value: detail.value)
                    }
                    Text(status.explanation).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                additionalInfo
            }.padding(.top, 4).padding(.bottom, 8).textSelection(.enabled)
        }
        .font(.system(size: 12))
        .disclosureGroupStyle(FullRowDisclosureGroupStyle(cardPadding: 4))
    }
}

extension PlayerState {
    var currentOutputSummary: PlaybackFormatSummary {
        .init(diagnostics: playbackDiagnostics, ownerID: chapterOwnerID,
              hasPlayback: currentSpec != nil, selectedAudioTrackID: selectedAudioTrackID)
    }
}
