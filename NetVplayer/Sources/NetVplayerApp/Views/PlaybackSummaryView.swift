import SwiftUI
import Models
import PlayerEngine

/// Observes only static cache revisions, never PlayerState's playback clock.
struct PlaybackSummaryView: View {
    @ObservedObject var store: PlaybackSummaryStore
    let identity: PlaybackSummaryIdentity?
    let episodeName: String

    var body: some View {
        if let identity, let summary = store.summary(for: identity) {
            VStack(alignment: .leading, spacing: 6) {
                Label(L10n.text("本次运行已播放规格"), systemImage: "play.rectangle")
                    .font(.caption.weight(.semibold))
                Text(episodeName).font(.caption).lineLimit(2)
                Text(video(summary)).font(.caption).textSelection(.enabled)
                if summary.audioCodec != nil {
                    Text([summary.audioCodec, summary.sampleRate.map { "\($0) Hz" },
                          summary.channels.map { "\($0) ch" }].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).textSelection(.enabled)
                }
                Text(L10n.text("来自此来源、线路与集数的实际播放；输出状态请查看播放信息。"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func video(_ summary: PlaybackStaticSummary) -> String {
        let resolution = summary.width.flatMap { w in summary.height.map { "\(w) × \($0)" } }
        return [summary.videoCodec, resolution, summary.bitDepth.map { "\($0) bit" }, summary.sourceRange,
                PlaybackStatistics.fps(summary.nominalFPS).map { L10n.text("媒体标称：{0}", [$0]) }]
            .compactMap { $0 }.joined(separator: " · ")
    }
}
