// NetVplayerApp/Views/WebHomeView.swift
// Default-off WKWebView surface wired to the sanitized WebHome bridge.

import SwiftUI
import WebKit
import WebHomeEngine

struct WebHomeView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.appThemePalette) private var palette
    @AppStorage("webHomeEnabled") private var webHomeEnabled: Bool = false
    @AppStorage("webHomeURL") private var webHomeURL: String = ""

    var body: some View {
        Group {
            if !webHomeEnabled {
                unavailableView(title: "WebHome 未启用", message: "请先在设置中开启实验入口。")
                    .onAppear { appState.updateWebHomeURLStatus("关闭") }
            } else {
                switch resolvedDestination {
                case .success(let destination):
                    VStack(spacing: 0) {
                        WebHomeContainerView(
                            destination: destination,
                            dispatcher: appState.makeWebHomeBridgeDispatcher(),
                            palette: palette
                        )
                        WebHomeDebugPanel(diagnostic: appState.webHomeSessionDiagnostic)
                            .frame(height: 188)
                    }
                    .onAppear { appState.updateWebHomeURLStatus(destination.statusText) }
                    .onChange(of: webHomeURL) { _, _ in
                        if case .success(let destination) = resolvedDestination {
                            appState.updateWebHomeURLStatus(destination.statusText)
                        }
                    }
                case .failure(let error):
                    unavailableView(title: "WebHome URL 不可用", message: error.localizedDescription)
                        .onAppear { appState.updateWebHomeURLStatus("URL 拒绝：\(error.localizedDescription)") }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.background.opacity(0.42))
        .navigationTitle(appState.webHomeChromeTitle)
    }

    private var resolvedDestination: Swift.Result<WebHomeDestination, Error> {
        Swift.Result { try WebHomeDestination.resolve(webHomeURL) }
    }

    private func unavailableView(title: String, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "globe.badge.chevron.backward")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct WebHomeDebugPanel: View {
    @Environment(\.appThemePalette) private var palette
    let diagnostic: WebHomeSessionDiagnostic

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Label("Bridge 调试", systemImage: "ladybug")
                    .font(.headline)
                statusChip(diagnostic.currentURLStatus)
                statusChip("Cache \(diagnostic.cacheKeyCount)")
                if let lastError = diagnostic.lastError, !lastError.isEmpty {
                    statusChip(lastError, isError: true)
                }
                Spacer()
            }

            if diagnostic.invocations.isEmpty {
                Text("暂无调用")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(diagnostic.invocations.prefix(8)) { invocation in
                            invocationCard(invocation)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.thinMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
        }
    }

    private func invocationCard(_ invocation: WebHomeBridgeInvocation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: invocation.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(
                        invocation.ok
                            ? palette.color(for: .success)
                            : palette.color(for: .danger)
                    )
                Text(invocation.method)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text("\(invocation.durationMs)ms")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(invocation.error ?? "\(invocation.responseBytes) bytes")
                .font(.caption2)
                .foregroundStyle(
                    invocation.ok
                        ? palette.muted
                        : palette.color(for: .danger)
                )
                .lineLimit(1)
            Text(invocation.paramsSummary.isEmpty ? "{}" : invocation.paramsSummary)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(10)
        .frame(width: 220, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private func statusChip(_ text: String, isError: Bool = false) -> some View {
        Text(text.isEmpty ? "-" : text)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(
                isError ? palette.color(for: .danger) : palette.muted
            )
            .background(Color.primary.opacity(0.055), in: Capsule())
    }
}

private struct WebHomeContainerView: NSViewRepresentable {
    let destination: WebHomeDestination
    let dispatcher: WebHomeBridgeDispatcher
    let palette: AppThemePalette

    func makeCoordinator() -> Coordinator {
        Coordinator(dispatcher: dispatcher)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, name: Coordinator.messageHandlerName)
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.bridgeScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        configuration.userContentController.addUserScript(
            AppWebScrollbarStyle.userScript(for: .standard, palette: palette)
        )
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        load(destination, in: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.dispatcher = dispatcher
        AppWebScrollbarStyle.apply(theme: .standard, palette: palette, to: webView)
        load(destination, in: webView, coordinator: context.coordinator)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.messageHandlerName)
        nsView.stopLoading()
    }

    private func load(_ destination: WebHomeDestination, in webView: WKWebView, coordinator: Coordinator) {
        let identity = destination.identity
        guard coordinator.lastLoadedIdentity != identity else { return }
        coordinator.lastLoadedIdentity = identity
        switch destination {
        case .localDemo:
            webView.loadHTMLString(WebHomeDemoPage.html, baseURL: nil)
        case .remote(let url):
            webView.load(URLRequest(url: url))
        }
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        static let messageHandlerName = "netvplayer"
        var dispatcher: WebHomeBridgeDispatcher
        var lastLoadedIdentity: String?

        init(dispatcher: WebHomeBridgeDispatcher) {
            self.dispatcher = dispatcher
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let bridgeMessage = Self.bridgeMessage(from: message.body) else { return }
            Task {
                let response = await dispatcher.dispatch(bridgeMessage)
                guard let data = try? JSONEncoder().encode(response),
                      let json = String(data: data, encoding: .utf8) else { return }
                let script = "window.NetVplayerBridge && window.NetVplayerBridge.__resolve(\(json));"
                await MainActor.run {
                    message.webView?.evaluateJavaScript(script)
                }
            }
        }

        private static func bridgeMessage(from body: Any) -> WebHomeBridgeMessage? {
            if let string = body as? String,
               let data = string.data(using: .utf8) {
                return try? JSONDecoder().decode(WebHomeBridgeMessage.self, from: data)
            }
            guard JSONSerialization.isValidJSONObject(body),
                  let data = try? JSONSerialization.data(withJSONObject: body) else {
                return nil
            }
            return try? JSONDecoder().decode(WebHomeBridgeMessage.self, from: data)
        }
    }

    private static let bridgeScript = """
    window.NetVplayerBridge = window.NetVplayerBridge || {
      _callbacks: {},
      call: function(method, params) {
        const id = Math.random().toString(36).slice(2) + Date.now().toString(36);
        const payload = { id, method, params: params || {} };
        window.webkit.messageHandlers.netvplayer.postMessage(payload);
        return new Promise((resolve) => { this._callbacks[id] = resolve; });
      },
      __resolve: function(response) {
        const callback = this._callbacks[response.id];
        if (callback) { callback(response); delete this._callbacks[response.id]; }
      }
    };
    """
}

enum WebHomeDemoPage {
    static let html = """
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width,initial-scale=1">
      <style>
        :root { color-scheme: light dark; font-family: -apple-system, BlinkMacSystemFont, sans-serif; }
        body { margin: 0; padding: 28px; background: Canvas; color: CanvasText; }
        main { max-width: 880px; margin: auto; display: grid; gap: 16px; }
        h1 { margin: 0; font-size: 28px; }
        input, button { font: inherit; border-radius: 8px; border: 1px solid color-mix(in srgb, CanvasText 18%, transparent); padding: 10px 12px; }
        button { background: color-mix(in srgb, AccentColor 18%, Canvas); color: CanvasText; }
        button:active { transform: translateY(1px); }
        .row { display: flex; gap: 10px; }
        .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(160px, 1fr)); gap: 10px; }
        input { flex: 1; background: Canvas; color: CanvasText; }
        pre { white-space: pre-wrap; border: 1px solid color-mix(in srgb, CanvasText 14%, transparent); border-radius: 8px; padding: 14px; min-height: 220px; max-height: 420px; overflow: auto; }
        .hint { color: color-mix(in srgb, CanvasText 62%, transparent); margin: 0; }
      </style>
    </head>
    <body>
      <main>
        <h1>WebHome</h1>
        <p class="hint">内置离线 demo，只调用 NetVplayer 白名单 bridge。</p>
        <div class="row">
          <input id="keyword" value="测试" aria-label="keyword">
          <button onclick="demoSearch()">搜索</button>
          <button onclick="callBridge('history.query', { limit: 12 })">历史</button>
        </div>
        <div class="row">
          <input id="shareURL" value="https://pan.quark.cn/s/demo" aria-label="share url">
          <button onclick="callBridge('pan.check', { shareURL: document.getElementById('shareURL').value })">网盘检查</button>
        </div>
        <div class="grid">
          <button onclick="setDemoCache()">写入缓存</button>
          <button onclick="callBridge('cache.get', { key: 'demo.last' })">读取缓存</button>
          <button onclick="readLastResultToken()">读取大结果</button>
          <button onclick="demoPlay()">播放入口</button>
        </div>
        <pre id="out"></pre>
      </main>
      <script>
        let lastResultToken = '';
        function keyword() { return document.getElementById('keyword').value || '测试'; }
        async function callBridge(method, params) {
          try {
            const response = await window.NetVplayerBridge.call(method, params);
            const result = response && response.result;
            if (result && result.resultToken) { lastResultToken = result.resultToken; }
            document.getElementById('out').textContent = JSON.stringify(response, null, 2);
          } catch (error) {
            document.getElementById('out').textContent = String(error);
          }
        }
        function demoSearch() {
          return callBridge('search', { keyword: keyword(), limit: 20 });
        }
        function setDemoCache() {
          return callBridge('cache.set', {
            key: 'demo.last',
            value: {
              title: keyword(),
              poster: 'https://cdn.example.test/poster.jpg?demo=1',
              savedAt: new Date().toISOString()
            }
          });
        }
        function readLastResultToken() {
          return callBridge('cache.get', { key: lastResultToken || 'demo.last' });
        }
        function demoPlay() {
          return callBridge('play', {
            url: 'https://media.example.test/webhome-demo.mp4?demo=1',
            title: 'WebHome Demo',
            siteKey: 'webhome-demo'
          });
        }
        window.NetVplayerBridge.call('ui.chrome', { title: 'WebHome' });
      </script>
    </body>
    </html>
    """
}

private extension WebHomeDestination {
    var identity: String {
        switch self {
        case .localDemo:
            return "local-demo"
        case .remote(let url):
            return url.absoluteString
        }
    }

    var statusText: String {
        switch self {
        case .localDemo:
            return "内置 demo"
        case .remote(let url):
            return "已校验 \(url.host ?? "remote")"
        }
    }
}
