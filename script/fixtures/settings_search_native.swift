import AppKit
import SwiftUI
import Combine
import Foundation
import Models
import Storage
import ObjectiveC
@testable import NetVplayerApp

// No real-service traffic in the diagnostic host.
private final class FixtureHTTP: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main private struct Main {
    @MainActor static func main() {
        installFixtureHTTP()
        let app = NSApplication.shared
        let delegate = Delegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        _ = delegate
    }
}
@MainActor private final class LayoutCapture {
    var anchors: [SettingsSearchTarget: SettingsSearchAnchorPosition] = [:]
    var viewport: CGRect = .zero
}
@MainActor private final class Delegate: NSObject, NSApplicationDelegate {
    let output = URL(fileURLWithPath: CommandLine.arguments[1])
    var records: [[String: Any]] = []
    var keyboard: [String: Any] = [:]
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 100) { self.finish("failed", error: "watchdog expired") }
        Task { @MainActor in
            do { try await exercise(); finish("passed") }
            catch { finish("failed", error: String(describing: error)) }
        }
    }
    private func exercise() async throws {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        guard home.path.hasPrefix(output.path) else { throw failure("home not isolated: " + home.path) }
        guard TestRuntime.isRunning else { throw failure("memory credential guard missing") }
        let defaults = UserDefaults.standard
        defaults.set("en", forKey: L10n.preferenceKey)
        UserPreferences.shared.defaultDecodeMode = 2
        UserPreferences.shared.proxyMode = 1
        UserPreferences.shared.customProxyPort = 8787
        UserPreferences.shared.danmakuEnabled = false
        UserPreferences.shared.webHomeEnabled = false
        let state = AppState(loadDefaultConfig: false, startProxyServer: false, startProviderRuntime: false,
            storageManager: StorageManager(storageDirectory: home.appendingPathComponent("state")),
            userPreferences: UserPreferences.shared, providerRuntimeBootstrap: nil)
        let navigation = SettingsSearchNavigation()
        let capture = LayoutCapture()
        let host = NSHostingView(rootView: SettingsView(searchNavigation: navigation).environmentObject(state)
            .onPreferenceChange(SettingsSearchAnchorKey.self) { capture.anchors = $0 }
            .onPreferenceChange(SettingsSearchViewportKey.self) { capture.viewport = $0 })
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 80, y: 120, width: 1100, height: 800),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "OV91-07 isolated settings search"
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.close() }
        try await pause(350)
        let domain = Bundle.main.bundleIdentifier!
        let before = (defaults.persistentDomain(forName: domain) ?? [:]) as NSDictionary
        for target in SettingsSearchTarget.allCases {
            try await locate(target, navigation: navigation, capture: capture, host: host, width: 1100)
        }
        window.setContentSize(NSSize(width: 600, height: 700))
        try await pause(180)
        for target: SettingsSearchTarget in [.customProxy, .quark, .tmdbCredential, .compatibility,
                                             .subtitlePosition, .toneMapping, .audioDevice, .webHomeURL] {
            try await locate(target, navigation: navigation, capture: capture, host: host, width: 600)
            try save(host, name: "narrow-" + target.rawValue)
        }
        state.openTaskSettings()
        try await pause(120)
        guard navigation.section == .dataSource, state.settingsNavigationDestination == nil,
              navigation.target == nil else { throw failure("existing task-settings route failed") }
        state.openFeedback()
        try await pause(120)
        guard navigation.section == .feedback, state.settingsNavigationDestination == nil,
              navigation.target == nil else { throw failure("existing feedback route failed") }
        guard before == (defaults.persistentDomain(forName: domain) ?? [:]) as NSDictionary else {
            let after = (defaults.persistentDomain(forName: domain) ?? [:]) as NSDictionary
            let changes = Set(before.allKeys.compactMap { $0 as? String } + after.allKeys.compactMap { $0 as? String })
                .filter { String(describing: before[$0]) != String(describing: after[$0]) }
            throw failure("preferences changed: " + changes.sorted().joined(separator: ","))
        }
        // Exercise the production text field and Return / arrows through the actual window responder.
        navigation.select(section: .network)
        try await pause(160)
        guard let field = textFields(host).first(where: { $0.placeholderString == L10n.text("搜索设置") }) else {
            throw failure("native search text field not found")
        }
        window.makeFirstResponder(field)
        field.stringValue = "proxy"
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)
        try await pause(180)
        try save(host, name: "narrow-search-results")
        sendKey(window, code: 125, characters: NSDownArrowFunctionKey)
        try await pause(100)
        sendKey(window, code: 36, characters: 13)
        try await pause(250)
        guard navigation.target == SettingsSearchIndex.matches("proxy")[1].id else {
            throw failure("Down + Return selected \(String(describing: navigation.target))")
        }
        let selected = navigation.target!
        let request = navigation.requestID
        navigation.reveal(selected)
        guard request != navigation.requestID else { throw failure("repeat location request was reused") }
        try await pause(4_200)
        guard !navigation.isHighlighted, navigation.target == selected else { throw failure("highlight lifecycle failed") }
        window.makeFirstResponder(field)
        field.stringValue = "no-such-settings-fixture"
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)
        try await pause(120)
        sendKey(window, code: 36, characters: 13)
        guard navigation.target == nil else { throw failure("empty results activated a setting") }
        try save(host, name: "narrow-empty-results")
        sendKey(window, code: 53, characters: 27)
        try await pause(100)
        try save(host, name: "narrow-escape")
        window.makeFirstResponder(field)
        field.stringValue = "subtitle"
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)
        try await pause(120)
        sendKey(window, code: 125, characters: NSDownArrowFunctionKey)
        sendKey(window, code: 126, characters: NSUpArrowFunctionKey)
        sendKey(window, code: 36, characters: 13)
        try await pause(180)
        guard navigation.target == SettingsSearchIndex.matches("subtitle").first?.id else {
            throw failure("Up + Return did not restore the first result")
        }
        navigation.reveal(.quark)
        navigation.reveal(.customProxy)
        try await pause(250)
        let current = capture.anchors[.customProxy]
        guard navigation.target == .customProxy, current?.request == navigation.requestID,
              current!.frame.intersects(capture.viewport) else { throw failure("rapid navigation accepted stale anchor") }
        keyboard = ["query": "proxy", "downThenReturn": selected.rawValue, "repeatRequestRenewed": true,
                    "highlightExpired": true, "emptyReturnIgnored": true, "escapeDismissed": true,
                    "upThenReturn": "subtitle", "rapidNavigation": true, "existingExternalRoutes": ["task-settings", "feedback"],
                    "preferencesUnchanged": before == (defaults.persistentDomain(forName: domain) ?? [:]) as NSDictionary]
    }
    private func locate(_ target: SettingsSearchTarget, navigation: SettingsSearchNavigation,
                        capture: LayoutCapture, host: NSView, width: Int) async throws {
        navigation.reveal(target)
        let anchor = SettingsSearchContext().anchor(for: target)
        let request = navigation.requestID
        try await pause(160)
        var frame: CGRect = .zero
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while .now < deadline {
            try await pause(60)
            host.layoutSubtreeIfNeeded()
            if let position = capture.anchors[anchor], position.request == request,
               position.frame.intersection(capture.viewport.intersection(host.bounds)).height >= min(24, position.frame.height) {
                frame = position.frame
                break
            }
        }
        guard !frame.isEmpty else {
            try? save(host, name: "failed-" + target.rawValue)
            throw failure("destination not visible: \(target.rawValue), anchors=\(capture.anchors.keys.map(\.rawValue)), viewport=\(capture.viewport), position=\(String(describing: capture.anchors[anchor]))")
        }
        records.append(["target": target.rawValue, "anchor": anchor.rawValue, "width": width,
                        "frame": rect(frame), "viewport": rect(capture.viewport), "visible": true,
                        "section": navigation.section.rawValue, "page": navigation.page.rawValue])
    }
    private func textFields(_ view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(textFields)
    }
    private func sendKey(_ window: NSWindow, code: UInt16, characters: Int) {
        let text = String(UnicodeScalar(characters)!)
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text,
            isARepeat: false, keyCode: code)!
        window.sendEvent(event)
    }
    private func pause(_ milliseconds: Int) async throws { try await Task.sleep(for: .milliseconds(milliseconds)) }
    private func rect(_ value: CGRect) -> [Double] { [value.minX, value.minY, value.width, value.height] }
    private func save(_ host: NSView, name: String) throws {
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw failure("bitmap unavailable") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
    }
    private func failure(_ text: String) -> Error { NSError(domain: "SettingsSearchProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
    private func finish(_ status: String, error: String = "") {
        let record: [String: Any] = ["status": status, "error": error, "locations": records, "keyboard": keyboard,
            "isolatedHome": NSHomeDirectory(), "memoryCredentials": TestRuntime.isRunning,
            "httpSessionsUseFixtureProtocol": true, "realServiceVerified": false]
        try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("native-validation.json"))
        NSApp.terminate(nil)
    }
}
private extension URLSessionConfiguration {
    @objc class func ov91_settingsDefault() -> URLSessionConfiguration {
        let config = ov91_settingsDefault(); config.protocolClasses = [FixtureHTTP.self]; return config
    }
    @objc class func ov91_settingsEphemeral() -> URLSessionConfiguration {
        let config = ov91_settingsEphemeral(); config.protocolClasses = [FixtureHTTP.self]; return config
    }
}
@MainActor private func installFixtureHTTP() {
    for (original, replacement) in [("defaultSessionConfiguration", "ov91_settingsDefault"),
                                     ("ephemeralSessionConfiguration", "ov91_settingsEphemeral")] {
        let a = class_getClassMethod(URLSessionConfiguration.self, NSSelectorFromString(original))!
        let b = class_getClassMethod(URLSessionConfiguration.self, NSSelectorFromString(replacement))!
        method_exchangeImplementations(a, b)
    }
}
