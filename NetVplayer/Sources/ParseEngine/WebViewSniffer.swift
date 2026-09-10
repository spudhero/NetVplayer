// ParseEngine/WebViewSniffer.swift
// 基于 WKWebView 的网页视频流媒体嗅探器

import Foundation
import WebKit
import Models

@MainActor
public final class WebViewSniffer: NSObject, WKScriptMessageHandler, @unchecked Sendable {

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<PlaySpec, Error>?
    private var timer: Timer?

    public override init() {
        super.init()
    }

    /// 执行视频网页嗅探
    /// - Parameters:
    ///   - urlString: 目标视频网页地址
    ///   - timeout: 超时限制
    public func sniff(url urlString: String, headers: [String: String] = [:], clickScript: String = "", timeout: TimeInterval = 15) async throws -> PlaySpec {
        guard let url = URL(string: urlString) else {
            return PlaySpec()
        }

        cancel()

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation

            let config = WKWebViewConfiguration()
            let userContentController = WKUserContentController()
            userContentController.add(self, name: "sniffer")

            // 注入 Hook 脚本，拦截 AJAX (XHR), Fetch 以及 video/source 标签的 src 赋值
            let jsString = """
            (function() {
                function checkUrl(url) {
                    if (!url || typeof url !== 'string') return;
                    if (url.includes('.m3u8') || url.includes('.mp4') || url.includes('.flv') || url.includes('video/mp4') || url.includes('video/m3u8')) {
                        window.webkit.messageHandlers.sniffer.postMessage(url);
                    }
                }

                // 1. Hook XMLHttpRequest
                const open = XMLHttpRequest.prototype.open;
                XMLHttpRequest.prototype.open = function(method, url) {
                    checkUrl(url);
                    return open.apply(this, arguments);
                };

                // 2. Hook fetch
                const originalFetch = window.fetch;
                window.fetch = function(input, init) {
                    const url = (typeof input === 'string') ? input : (input && input.url);
                    checkUrl(url);
                    return originalFetch.apply(this, arguments);
                };

                // 3. Hook Video/Source src
                const createElement = document.createElement;
                document.createElement = function(tagName) {
                    const el = createElement.apply(this, arguments);
                    if (tagName.toLowerCase() === 'video' || tagName.toLowerCase() === 'source') {
                        const descriptor = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'src') ||
                                           Object.getOwnPropertyDescriptor(HTMLSourceElement.prototype, 'src');
                        if (descriptor && descriptor.set) {
                            Object.defineProperty(el, 'src', {
                                set: function(val) {
                                    checkUrl(val);
                                    descriptor.set.call(this, val);
                                },
                                get: function() {
                                    return descriptor.get.call(this);
                                }
                            });
                        }
                    }
                    return el;
                };
            })();
            """
            let userScript = WKUserScript(source: jsString, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            userContentController.addUserScript(userScript)
            if !clickScript.isEmpty {
                userContentController.addUserScript(WKUserScript(source: clickScript, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
            }
            config.userContentController = userContentController

            let webView = WKWebView(frame: .zero, configuration: config)
            self.webView = webView
            
            var request = URLRequest(url: url)
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
            webView.load(request)

            // 超时保护
            self.timer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.handleTimeout()
                }
            }
        }
    }

    /// 取消当前的嗅探任务
    public func cancel() {
        timer?.invalidate()
        timer = nil
        webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "sniffer")
        webView = nil
        
        if let continuation = self.continuation {
            self.continuation = nil
            continuation.resume(throwing: CancellationError())
        }
    }

    private func handleTimeout() {
        timer?.invalidate()
        timer = nil
        webView?.stopLoading()
        webView = nil
        
        if let continuation = self.continuation {
            self.continuation = nil
            continuation.resume(returning: PlaySpec())
        }
    }

    // MARK: - WKScriptMessageHandler

    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let url = message.body as? String else { return }
        
        timer?.invalidate()
        timer = nil
        webView?.stopLoading()
        webView = nil
        
        if let continuation = self.continuation {
            self.continuation = nil
            let headers = [
                "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
            ]
            continuation.resume(returning: PlaySpec(url: url, headers: headers))
        }
    }
}
