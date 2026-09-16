import SwiftUI
import WebKit

struct PlaybackVerificationView: View {
    let request: PlaybackVerificationRequest
    let onVerified: () -> Void
    let onCancel: () -> Void

    @Environment(\.openURL) private var openURL
    @Environment(\.appThemePalette) private var palette
    @State private var reloadID = UUID()
    @State private var statusMessage = "请完成页面中的滑块验证"

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.shield")
                    .font(.title2)
                    .foregroundStyle(palette.accent)

                VStack(alignment: .leading, spacing: 3) {
                    Text("源站验证")
                        .font(.headline)
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    reloadID = UUID()
                    statusMessage = "请完成页面中的滑块验证"
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("重新加载")

                Button {
                    onCancel()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("关闭")
            }
            .padding(.horizontal, 18)
            .frame(height: 56)

            Divider()

            PlaybackVerificationWebView(
                url: request.interaction.url,
                onVerified: {
                    statusMessage = "验证成功，正在重试播放..."
                    onVerified()
                },
                onFailure: { message in
                    statusMessage = message
                }
            )
            .id(reloadID)
            .frame(minWidth: 680, minHeight: 500)

            Divider()

            HStack(spacing: 12) {
                Button {
                    if let url = URL(string: request.interaction.url) {
                        openURL(url)
                    }
                } label: {
                    Label("浏览器打开", systemImage: "safari")
                }

                Spacer()

                Button("取消", role: .cancel) {
                    onCancel()
                }

                Button {
                    onVerified()
                } label: {
                    Label("完成验证并重试", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 18)
            .frame(height: 62)
        }
        .frame(minWidth: 720, minHeight: 620)
        .tint(palette.accent)
    }
}

private struct PlaybackVerificationWebView: NSViewRepresentable {
    let url: String
    let onVerified: () -> Void
    let onFailure: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onVerified: onVerified, onFailure: onFailure)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: Coordinator.messageName)
        controller.addUserScript(WKUserScript(
            source: Self.bridgeScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        configuration.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        if let target = URL(string: url) {
            webView.load(URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData))
        } else {
            onFailure("验证地址无效")
        }
        return webView
    }

    func updateNSView(_: WKWebView, context _: Context) {}

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.messageName)
        webView.navigationDelegate = nil
    }

    private static let bridgeScript = """
    (() => {
      window.SlideVerifyJsInterface = {
        getSlideVerifyData(payload) {
          window.webkit.messageHandlers.\(Coordinator.messageName).postMessage(payload);
        }
      };
    })();
    """

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        static let messageName = "netvplayerVerification"

        private let onVerified: () -> Void
        private let onFailure: (String) -> Void

        init(onVerified: @escaping () -> Void, onFailure: @escaping (String) -> Void) {
            self.onVerified = onVerified
            self.onFailure = onFailure
        }

        func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == Self.messageName,
                  let payload = message.body as? String,
                  let data = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Self.hasValue("session_id", in: object),
                  Self.hasValue("sig", in: object),
                  Self.hasValue("nc_token", in: object) else {
                onFailure("验证结果无效，请重新完成滑块验证")
                return
            }
            onVerified()
        }

        func webView(_: WKWebView, didFail _: WKNavigation!, withError error: Error) {
            onFailure("验证页加载失败：\(error.localizedDescription)")
        }

        func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
            onFailure("验证页加载失败：\(error.localizedDescription)")
        }

        private static func hasValue(_ key: String, in object: [String: Any]) -> Bool {
            guard let value = object[key] as? String else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}
