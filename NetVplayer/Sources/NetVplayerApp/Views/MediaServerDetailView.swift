import Models
import SwiftUI

/// Uses the same detail composition as NAS, without NAS-only edits or filters.
struct MediaServerDetailView: View {
  @EnvironmentObject private var appState: AppState
  let vod: Vod
  let size: CGSize
  var body: some View {
    NASMediaDetailContent(
      vod: vod, size: size,
      metadata: vod.mediaServerDetail?.metadata
        ?? .init(
          title: vod.vodName,
          year: Int(vod.vodYear),
          kind: ["Series", "Season", "Episode"].contains(vod.vodRemarks) ? .television : .movies,
          plot: vod.vodContent, poster: vod.vodPic, fanart: vod.vodBackground),
      files: [], serviceName: appState.activeSite?.name ?? L10n.text("媒体服务器"), libraryName: "",
      serverDetail: vod.mediaServerDetail)
  }
}

enum MediaServerFilePresentation {
  static func summary(_ file: MediaServerFileDetail) -> String {
    var values = [file.container?.uppercased(), file.videoCodec?.uppercased()].compactMap { $0 }
    if let width = file.width, let height = file.height { values.append("\(width) × \(height)") }
    if let range = file.videoRange { values.append(range) }
    if let bytes = file.size {
      values.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
    }
    return values.joined(separator: " · ")
  }
}

struct MediaServerFilesSection: View {
  @Environment(\.appThemePalette) private var palette
  let files: [MediaServerFileDetail]
  var selectedSourceID: String?
  var select: (String) -> Void = { _ in }
  var play: (String) -> Void = { _ in }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(L10n.text("文件信息")).font(.headline)
      if files.isEmpty {
        Text(L10n.text("服务器未提供文件与轨道资料；仍可使用上方播放入口。"))
          .font(.callout).foregroundStyle(palette.muted)
      }
      ForEach(files) { file in
        fileCard(file)
      }
    }
  }

  private func fileCard(_ file: MediaServerFileDetail) -> some View {
    let selectable = file.playbackLocator != nil
    let selected = selectable && file.sourceID == selectedSourceID
    return VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        Button {
          if let sourceID = file.sourceID { select(sourceID) }
        } label: {
          HStack(spacing: 10) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
              .foregroundStyle(selected ? palette.accent : palette.muted)
              .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
              Text(file.name).font(.callout.bold())
              Text(MediaServerFilePresentation.summary(file)).font(.caption).foregroundStyle(palette.muted)
                DolbySourceBadges(formats: DolbySourceFormat.serverFile(file))
              if !selectable {
                Text(L10n.text("此版本暂无法原始播放")).font(.caption).foregroundStyle(palette.muted)
              } else if selected {
                Text(L10n.text("已选择此版本")).font(.caption).foregroundStyle(palette.accent)
              }
            }.fixedSize(horizontal: false, vertical: true)
          }
          .padding(14)
          .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!selectable)
        .accessibilityLabel(L10n.text("选择版本：{0}", [file.name]))
        .accessibilityValue(selected ? L10n.text("已选择") : L10n.text("未选择"))
        Button {
          if let sourceID = file.sourceID { play(sourceID) }
        } label: {
          Label(L10n.text("播放此版本"), systemImage: "play.fill").padding(.vertical, 4)
        }
        .buttonStyle(.bordered).disabled(!selectable)
        .accessibilityLabel(L10n.text("播放版本：{0}", [file.name]))
        .padding(.trailing, 14)
      }
      DisclosureGroup(L10n.text("音轨与字幕")) {
        VStack(alignment: .leading, spacing: 10) {
          tracks(L10n.text("音频"), file.audio)
          tracks(L10n.text("字幕"), file.subtitles)
        }.padding(.top, 8)
      }
      .disclosureGroupStyle(FullRowDisclosureGroupStyle(cardPadding: 14))
      .font(.caption).foregroundStyle(palette.muted)
    }
    .background(palette.foreground.opacity(selected ? 0.08 : 0.045), in: RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? palette.accent.opacity(0.65) : palette.foreground.opacity(0.08)))
  }
  private func tracks(_ label: String, _ values: [String]) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(label).font(.caption.bold())
      Text(values.isEmpty ? L10n.text("服务器未提供") : values.joined(separator: "\n"))
        .font(.caption).foregroundStyle(palette.muted).textSelection(.enabled)
    }
  }
}
