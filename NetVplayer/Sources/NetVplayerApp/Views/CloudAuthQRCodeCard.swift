import AppKit
import Models
import SwiftUI

/// Theme only the surrounding card. The image keeps its pixels and a white quiet zone.
struct CloudAuthQRCodeCard: View {
    @Environment(\.appThemePalette) private var palette
    let image: NSImage?
    var isLoading = false
    var isManual = false
    var side: CGFloat = 238
    var loadingTitle = L10n.text("正在获取二维码")

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(width: side - 24, height: side - 24)
                    .padding(12)
                    .background(.white, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel(L10n.text("登录二维码"))
                    .accessibilityIdentifier("cloud.auth.qrcode")
            } else {
                VStack(spacing: 10) {
                    if isLoading {
                        ProgressView().controlSize(.regular).tint(palette.accent)
                        Text(loadingTitle)
                    } else if isManual {
                        Image(systemName: "doc.text.viewfinder").font(.system(size: 32))
                        Text(L10n.text("粘贴登录信息"))
                    } else {
                        Image(systemName: "exclamationmark.circle").font(.system(size: 28))
                            .foregroundStyle(palette.color(for: .warning))
                        Text(L10n.text("二维码暂不可用"))
                        Text(L10n.text("请刷新二维码重试。"))
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(palette.muted)
                .multilineTextAlignment(.center)
                .padding(16)
                .frame(width: side, height: side)
                .background(palette.foreground.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8).stroke(palette.foreground.opacity(0.12), lineWidth: 1)
                }
            }
        }
        .frame(width: side, height: side)
    }
}
