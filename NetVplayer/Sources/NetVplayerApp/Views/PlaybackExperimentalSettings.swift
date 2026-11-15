import Models
import PlayerEngine
import Storage
import SwiftUI

/// Shared presentation only; output evidence and preference ownership stay with
/// the existing playback models and stores.
struct PlaybackExperimentalSection<Content: View>: View {
    @Environment(\.appThemePalette) private var palette
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L10n.text("实验功能"), systemImage: "flask")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.muted)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.foreground.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(palette.foreground.opacity(0.08), lineWidth: 1) }
    }
}

struct PlaybackTrueHDObjectSettings: View {
    @Binding var selection: PlaybackTrueHDObjectMode
    var unavailable = false

    var body: some View {
        PlaybackExperimentalSection {
            PlaybackSettingField(title: L10n.text("TrueHD 对象渲染")) {
                Picker(L10n.text("TrueHD 对象渲染"), selection: $selection) {
                    ForEach(PlaybackTrueHDObjectMode.allCases, id: \.self) { mode in
                        Text(mode.description).tag(mode)
                    }
                }
                .accessibilityValue(selection.description)
            }
            Text(modeDescription)
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if selection != .automatic {
                Text(L10n.text("使用 PCM，可调音量和对白增强；其他音轨也按 PCM 输出。"))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if unavailable {
                    FeatureNotice(message: L10n.text("当前设备或运行库不支持所选模式，继续使用自动输出。"),
                        role: .warning, systemImage: "exclamationmark.triangle")
                }
            }
        }.font(.system(size: 12))
    }

    private var modeDescription: String {
        switch selection {
        case .automatic: L10n.text("默认保持原生输出，由片源和设备决定。")
        case .speakers714: L10n.text("需要已配置的 12 声道设备，才能输出 7.1.4 PCM。")
        case .headphones: L10n.text("请佩戴耳机，使用固定空间音频。")
        case .trackedHeadphones: L10n.text("需要兼容耳机与运动权限；无姿态数据时使用固定空间音频。")
        }
    }
}

struct PlaybackSystemDolbyVisionSetting: View {
    @Binding var isOn: Bool
    @Binding var sourceMetadata: Bool
    let available: Bool

    init(isOn: Binding<Bool>, sourceMetadata: Binding<Bool> = .constant(false), available: Bool) {
        _isOn = isOn
        _sourceMetadata = sourceMetadata
        self.available = available
    }

    var body: some View {
        PlaybackExperimentalSection {
            Toggle(L10n.text("系统杜比视界呈现"), isOn: $isOn)
                .disabled(!available)
                .accessibilityValue(L10n.text(isOn ? "偏好已开启，实际输出以诊断为准" : "默认关闭"))
            Text(L10n.text("需要 macOS 15 和 HDR 输出；无法使用时返回常规映射。"))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !available {
                FeatureNotice(message: L10n.text("当前系统或运行库暂不支持此功能。"), systemImage: "info.circle")
            } else if isOn {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(L10n.text("保留兼容片源的动态元数据"), isOn: $sourceMetadata)
                    Text(L10n.text("尝试沿用兼容片源的逐帧色彩信息。"))
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    DisclosureGroup(L10n.text("适用范围与回退")) {
                        Text(L10n.text("仅实验支持部分 P8 片源；字幕、画面变换或不兼容时使用重建画面。系统提交不代表电视已接收 DV。"))
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 4)
                    }
                }
                .padding(.leading, 18)
                Text(L10n.text("电视接收格式仍需设备确认。"))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(L10n.text("偏好已开启；实际呈现请查看输出状态与技术信息。"))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.font(.system(size: 12))
    }
}
