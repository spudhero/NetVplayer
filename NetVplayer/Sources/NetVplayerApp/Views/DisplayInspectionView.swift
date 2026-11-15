import Models
import PlayerEngine
import SwiftUI

struct DisplayInspectionView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.appThemePalette) private var palette
    @State private var pattern = DisplayInspectionPattern.grayscale
    @State private var image = DisplayInspectionPattern.grayscale.makeImage()
    @State private var screenDescription = L10n.text("显示器信息不可用")

    var body: some View {
        VStack(spacing: 0) {
            FeaturePanelHeader(
                title: L10n.text("显示测试图与指引"),
                subtitle: screenDescription + " · " + L10n.text("目视检查，不替代仪器校准"), systemImage: "display"
            ) {
                dismissWindow(id: AppWindowID.displayInspection)
            }.padding(24)
            Divider()
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Picker(L10n.text("测试图"), selection: $pattern) {
                            ForEach(DisplayInspectionPattern.allCases, id: \.self) { item in
                                Text(item.title).tag(item)
                            }
                        }.pickerStyle(.segmented)
                        ZStack {
                            Color.black
                            if let image {
                                Image(image, scale: 1, label: Text(pattern.title))
                                    .resizable().interpolation(.none).aspectRatio(contentMode: .fit)
                            } else {
                                Text(L10n.text("测试图生成失败")).foregroundStyle(.white)
                            }
                        }
                        .frame(height: max(200, min(380, geometry.size.height * 0.5)))
                        .accessibilityLabel(pattern.title)
                        FeatureNotice(message: pattern.guidance, systemImage: "eye")
                        Text(L10n.text("图中数值为 sRGB 8 位码值；系统负责显示转换。本工具不测量屏幕，也不验证视频播放的颜色。"))
                            .font(.caption).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
                        DisclosureGroup(L10n.text("检查步骤与能力说明")) {
                            VStack(alignment: .leading, spacing: 12) {
                                guide(
                                    L10n.text("检查前"), L10n.text("将窗口移到要检查的屏幕，并保持环境光稳定。记录显示器模式、亮度及夜览／原彩设置；比较前后时使用相同条件。"))
                                guide(
                                    L10n.text("ICC 与应用设置"),
                                    L10n.text(
                                        "播放器自动使用所在屏幕的系统 ICC。系统色彩配置会影响该屏的色彩管理；应用中的映射算法和参考峰值只影响本应用。测试图不会改变这些设置，关闭即可返回。"))
                                guide(
                                    L10n.text("仪器与 iPhone"),
                                    L10n.text(
                                        "可靠校准需要适配显示器的色度计或光谱辐射计，并比较校准前后的测量。当前未提供 iPhone 测量、ICC 导入或 LUT 校准；手机自动白平衡不能代替专业测量。"
                                    ))
                                Link(
                                    L10n.text("查看 Apple 显示器色彩配置说明"),
                                    destination:
                                        URL(
                                            string:
                                                "https://support.apple.com/guide/mac-help/change-your-displays-color-profile-mchlf3ddc60d/mac"
                                        )!)
                            }.padding(.top, 12).frame(maxWidth: .infinity, alignment: .leading)
                        }.disclosureGroupStyle(FullRowDisclosureGroupStyle())
                            .font(.system(size: 12)).tint(palette.accent)
                    }.padding(24)
                }
            }
        }
        .frame(minWidth: 720, idealWidth: 960, minHeight: 650, idealHeight: 780)
        .themedPresentation()
        .background(DisplayInspectionScreenReader(description: $screenDescription).frame(width: 0, height: 0))
        .onChange(of: pattern) { _, value in image = value.makeImage() }
    }

    private func guide(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout.bold())
            Text(body).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
