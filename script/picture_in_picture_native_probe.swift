import AppKit
import SwiftUI
import Foundation
import Storage
import Models
import NativePIP
import MPVShim
@testable import PlayerEngine
@testable import NetVplayerApp

@main struct PiPNativeMain {
    @MainActor static func main() {
        guard CommandLine.arguments.count == 3 else { return }
        let app = NSApplication.shared
        let delegate = PiPNativeDelegate()
        app.delegate = delegate; app.setActivationPolicy(.regular); app.run()
        _ = delegate
    }
}

@MainActor final class PiPNativeDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let output = URL(fileURLWithPath: CommandLine.arguments[1])
    let base = CommandLine.arguments[2]
    var checks: [String: Bool] = [:]
    var facts: [String: Any] = [:]
    var windows: [NSWindow] = []
    var presentation: PlayerPictureInPicture?
    var engine: MPVPlayerEngine?
    var fullScreenEntered = false
    var fullScreenExited = false
    func windowDidEnterFullScreen(_ notification: Notification) { fullScreenEntered = true }
    func windowDidExitFullScreen(_ notification: Notification) { fullScreenExited = true }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
            do { try await verify(); await finish("passed") }
            catch { await finish("failed", error: String(describing: error)) }
        }
    }
    func require(_ condition: @autoclosure () -> Bool, _ name: String) throws {
        guard condition() else { throw NSError(domain: "PiPProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
        checks[name] = true
        FileHandle.standardOutput.write(Data(("PASS " + name + "\n").utf8))
    }
    func wait(_ name: String, seconds: Double = 15, _ predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !predicate(), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard predicate() else { throw NSError(domain: "PiPProbe", code: 2, userInfo: [NSLocalizedDescriptionKey:
            "\(name) timed out; phase=\(String(describing: presentation?.phase)); failure=\(presentation?.failure ?? "none"); windows=\(NSApp.windows.map { "\($0.title):\($0.isVisible)" })"]) }
    }
    func window(_ title: String, content: NSView) -> NSWindow {
        let w = NSWindow(contentRect: .init(x: 180, y: 200, width: 640, height: 360),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = title; w.isReleasedWhenClosed = false; w.contentView = content
        w.delegate = self; w.collectionBehavior.insert(.fullScreenPrimary)
        windows.append(w); w.makeKeyAndOrderFront(nil); return w
    }
    func capture(_ window: NSWindow, name: String) throws {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        if String(describing: type(of: window)) == "PIPPanel", let screen = NSScreen.screens.first {
            let r = window.frame
            p.arguments = ["-x", "-R\(Int(r.minX)),\(Int(screen.frame.maxY - r.maxY)),\(Int(r.width)),\(Int(r.height))", output.appendingPathComponent(name).path]
        } else {
            p.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", output.appendingPathComponent(name).path]
        }
        try p.run(); p.waitUntilExit()
        try require(p.terminationStatus == 0, "native window screenshot " + name)
        let bitmap = NSBitmapImageRep(data: try Data(contentsOf: output.appendingPathComponent(name)))!
        var visible = 0
        for y in stride(from: bitmap.pixelsHigh / 4, to: bitmap.pixelsHigh * 3 / 4, by: 8) {
            for x in stride(from: bitmap.pixelsWide / 4, to: bitmap.pixelsWide * 3 / 4, by: 8) {
                if let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                   max(c.redComponent, c.greenComponent, c.blueComponent) > 0.2 { visible += 1 }
            }
        }
        try require(visible > 40, "visible compositor pixels " + name)
    }
    func captureFittedPicture(_ window: NSWindow, name: String) async throws {
        // Wait for paused OpenGL redraw and the compositor after the aspect change.
        try await Task.sleep(for: .milliseconds(750))
        try capture(window, name: name)
        let bitmap = NSBitmapImageRep(data: try Data(contentsOf: output.appendingPathComponent(name)))!
        let content = window.contentRect(forFrameRect: window.frame)
        let scale = Double(bitmap.pixelsWide) / window.frame.width
        let top = (window.frame.height - content.height) * scale
        let height = content.height * scale
        let points = [(0.1, 0.5), (0.9, 0.5), (0.5, 0.1), (0.5, 0.5)]
        try require(points.allSatisfy { x, y in
            guard let c = bitmap.colorAt(x: Int(Double(bitmap.pixelsWide) * x), y: Int(top + height * y))?
                .usingColorSpace(.sRGB) else { return false }
            return max(c.redComponent, c.greenComponent, c.blueComponent) > 0.25
        }, "actual decoded picture reaches content edges " + name)
    }
    func requestCount() async throws -> Int {
        let (data, _) = try await URLSession.shared.data(from: URL(string: base + "/request-count")!)
        return Int(String(decoding: data, as: UTF8.self))!
    }
    func verify() async throws {
        let initialHDR = try NVSystemHDRDisplay.readDisplays().map(\.prefersHDR)
        let suite = "com.netvplayer.pip-native." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let audio = PlaybackAudioPreferenceStore(defaults: defaults); audio.setMuted(true)
        let colors = PlaybackColorPreferenceStore(defaults: defaults)
        let e = MPVPlayerEngine(videoSurface: .vod, audioPreferences: audio,
            audioOutputPreferences: .init(defaults: defaults), dialoguePreferences: .init(defaults: defaults),
            colorPreferences: colors)
        engine = e
        e.performanceDiagnosticsHandler = { _, _ in }
        let state = PlayerState(); e.playerState = state
        var clockOffset = 0.0
        var available = true
        var injected: InjectedPiPDriver?
        let p = PlayerPictureInPicture(engine: e, surface: .vod,
            available: { available && NVPictureInPicture.available },
            makeDriver: { if let injected { return injected }; return NVPictureInPicture() },
            now: { ProcessInfo.processInfo.systemUptime + clockOffset })
        presentation = p
        let host = NSView(frame: .init(x: 0, y: 0, width: 640, height: 360))
        let w = window("OV87-09 single mpv SDR", content: host)
        p.mount(in: host) { w.makeKeyAndOrderFront(nil) }
        if ProcessInfo.processInfo.environment["NETVPLAYER_PIP_CONTROLS_ONLY"] == "1" {
            try await verifyPlayerFloatingControls(engine: e, presentation: p, window: w)
            facts["scope"] = "Real libmpv floating-window verification; control route recorded separately; system PiP matrix skipped."
            return
        }
        try require(p.isAvailable, "system PIP framework ABI available")
        await e.play(spec: PlaySpec(url: base + "/fixture.mp4", title: "OV87-09 original fixture"))
        try await wait("real playback") { state.position > 0.3 }
        let identity = e.presentationProbeIdentity
        let view = p.videoView!
        try require(identity.context != 0 && identity.readSession != nil, "one real mpv context and read session")
        e.loadExternalSubtitle(Sub(name: "Original PiP subtitle", url: output.appendingPathComponent("fixture.srt").absoluteString, format: "srt"))
        try await wait("subtitle loaded") { state.selectedSubtitleTrackID != nil }
        let subtitle = state.selectedSubtitleTrackID
        try await wait("inline frames") { e.performanceFrameSnapshot.freshFrames > 10 }
        try capture(w, name: "native-sdr-inline.png")
        let requests = try await requestCount()
        p.enter()
        try await wait("native PiP active") { p.phase == .active }
        try require(abs(view.bounds.width - view.window!.contentView!.bounds.width) < 1, "PiP content resizes to native host without cropping")
        try require(view === p.videoView && view.window !== w && view.window?.isVisible == true,
                    "same render view in real native PiP window")
        try require(identity == e.presentationProbeIdentity, "enter preserves mpv and read identity")
        let framesAtEntry = e.performanceFrameSnapshot.freshFrames
        try await wait("PiP frames") { e.performanceFrameSnapshot.freshFrames > framesAtEntry + 24 }
        try capture(view.window!, name: "native-sdr-pip.png")
        facts["nativeWindows"] = NSApp.windows.map { ["title": $0.title, "class": String(describing: type(of: $0)),
            "number": $0.windowNumber, "visible": $0.isVisible, "frame": NSStringFromRect($0.frame)] }
        facts["viewGeometry"] = ["render": NSStringFromRect(view.bounds), "child": view.subviews.map { NSStringFromRect($0.bounds) }, "scale": view.window!.backingScaleFactor]
        let pipWindow = view.window!
        pipWindow.setContentSize(NSSize(width: 520, height: 292))
        try await wait("PiP resize") { abs(view.bounds.width - pipWindow.contentView!.bounds.width) < 1 }
        try require(identity == e.presentationProbeIdentity, "native PiP resize preserves render attachment and context")
        e.pause(); try await wait("pause") { !state.isPlaying }
        let pausedPosition = state.position
        p.exit(returnToWindow: true)
        try await wait("return") { p.phase == .inline }
        try require(view.superview === host && !state.isPlaying && abs(state.position - pausedPosition) < 0.2,
                    "paused return keeps view and clock")
        p.enter(); try await wait("paused PiP") { p.phase == .active }
        try require(!state.isPlaying, "paused reentry does not resume")
        e.seek(to: 30_000)
        try await wait("paused seek") { abs(state.position - 30) < 1 }
        try require(!state.isPlaying, "seek in PiP preserves pause")
        e.resume(); try await wait("resume") { state.position > 30.2 && state.isPlaying }
        w.miniaturize(nil); try await wait("minimize") { w.isMiniaturized }
        let beforeMinimized = state.position
        try await wait("background playback") { state.position > beforeMinimized + 0.5 }
        try require(view.window?.isVisible == true, "minimized main window keeps PiP advancing")
        p.exit(returnToWindow: true); try await wait("return from minimized") { p.phase == .inline && !w.isMiniaturized }
        try require(w.isVisible && view.window === w, "return deminiaturizes source window")
        p.enter(); try await wait("PiP before close") { p.phase == .active }
        p.unmount(host); w.close()
        let beforeClosed = state.position
        try await wait("closed main playback") { state.position > beforeClosed + 0.5 }
        try require(!w.isVisible && view.window?.isVisible == true, "destroyed inline host does not detach PiP")
        let newHost = NSView(frame: host.frame)
        w.contentView = newHost
        p.mount(in: newHost) { w.makeKeyAndOrderFront(nil) }
        try require(view.superview !== newHost, "new inline host cannot steal active PiP")
        p.unmount(host)
        p.exit(returnToWindow: true); try await wait("recreated main") { p.phase == .inline }
        try require(w.isVisible && view.superview === newHost, "return restores new host and stale unmount is ignored")
        w.toggleFullScreen(nil); try await wait("fullscreen didEnter") { fullScreenEntered }
        p.enter()
        try require(p.phase == .waitingForFullScreen && view.window === w, "PiP waits for real fullscreen exit")
        try await wait("fullscreen exit and PiP", seconds: 20) { fullScreenExited && p.phase == .active }
        try require(!w.styleMask.contains(.fullScreen) && view.window !== w, "migration follows actual didExitFullScreen")
        p.exit(returnToWindow: false); try await wait("close PiP") { p.phase == .inline && !state.isPlaying }
        try require(identity == e.presentationProbeIdentity, "all SDR transitions preserve context and read owner")
        try require(state.selectedSubtitleTrackID == subtitle, "subtitle selection survives real PiP pause seek and fullscreen")
        // Seek may issue a range request, so separately prove pure transitions add none.
        let countBefore = try await requestCount()
        for _ in 0..<3 {
            p.enter(); try await wait("repeat enter") { p.phase == .active }
            p.exit(returnToWindow: true); try await wait("repeat exit") { p.phase == .inline }
        }
        let countAfter = try await requestCount()
        try require(countBefore == countAfter, "pure migrations do not add media requests")
        facts["requestsBeforeFirstPiP"] = requests
        facts["requestsBeforeAndAfterRepeatedMigration"] = [countBefore, countAfter]
        p.unmount(newHost); p.mount(in: newHost) { w.makeKeyAndOrderFront(nil) }
        await Task.yield()
        try require(view.isPlaybackSurfaceActive && identity == e.presentationProbeIdentity,
                    "queued unmount cannot detach immediately remounted surface")
        // Explicit injection tests are distinguished from real system-PiP checks.
        let oldTicket = p.generation
        p.enter(); p.exit(returnToWindow: true)
        try require(p.phase == .inline && view.superview === newHost, "rapid entering cancellation restores inline")
        p.enter(); try await wait("successor PiP") { p.phase == .active }
        p.receive("closed", generation: oldTicket)
        p.receive("stop", generation: oldTicket)
        try require(p.phase == .active, "injected stale callbacks cannot close successor")
        let rival = PlayerPictureInPicture(engine: e, surface: .live)
        rival.enter()
        try require(!rival.isPresented && rival.failure != nil, "second PiP owner excluded")
        p.exit(returnToWindow: true); try await wait("successor exit") { p.phase == .inline }
        available = false; p.enter()
        try require(p.phase == .inline && view.window === w, "unavailable interface leaves player usable")
        available = true
        let failed = InjectedPiPDriver(); failed.succeeds = false; injected = failed
        p.enter()
        try require(p.phase == .inline && p.failure != nil && view.superview === newHost, "injected native failure restores original view")
        let silent = InjectedPiPDriver(); injected = silent
        p.enter(); let lateCallback = silent.eventHandler
        clockOffset += 9; p.reconcile()
        try require(p.phase == .inline && p.failure != nil && silent.invalidated, "injected entry timeout is failure not active")
        let stalledExit = InjectedPiPDriver(); stalledExit.usesWindow = true; injected = stalledExit
        p.enter(); p.reconcile()
        try require(p.phase == .active, "injected exit fixture entered")
        w.orderOut(nil)
        let stopTicket = p.generation
        p.receive("stop", generation: stopTicket)
        p.receive("return", generation: stopTicket)
        try require(p.phase == .exiting && !w.isVisible, "close intent cannot be overwritten by native return callback")
        clockOffset += 9; p.reconcile()
        try require(p.phase == .inline && p.failure != nil && w.isVisible,
                    "injected exit timeout restores usable source and reports failure")
        injected = nil
        p.enter(); try await wait("real entry after timeout") { p.phase == .active }
        lateCallback?("closed"); lateCallback?("pause")
        try require(p.phase == .active, "late timed-out driver cannot affect real successor")
        let replaced = e.presentationProbeIdentity
        await e.play(spec: PlaySpec(url: output.appendingPathComponent("fixture.mp4").absoluteString, title: "Replacement fixture"))
        try await wait("replacement") { p.phase == .inline && state.position > 0.3 }
        try require(e.presentationProbeIdentity.context == replaced.context && e.presentationProbeIdentity.readSession != replaced.readSession,
                    "media replacement invalidates PiP while reusing engine")
        p.enter(); try await wait("PiP before stop") { p.phase == .active }

        await e.stopAndWaitForRetirement()
        try await wait("stop invalidates PiP") { p.phase == .inline }
        try require(e.presentationProbeIdentity.context == 0, "existing stop awaits actual mpv retirement")
        // Independently exercise PQ and HLG with the existing temporary-HDR policy.
        var hdrEvidence: [[String: Any]] = []
        colors.set(.init(videoOutput: .hdrIfAvailable))
        for sample in ["pq", "hlg"] {
            await e.play(spec: PlaySpec(url: output.appendingPathComponent("hdr/" + sample + ".mkv").absoluteString,
                                       title: "Original " + sample + " signal"))
            try await wait(sample + " source") { state.position > 0.3 && state.playbackDiagnostics?.display.videoOutput != nil }
            try await wait(sample + " display mode settled", seconds: 20) { state.position > 6 && !SystemHDRController.shared.isChangingDisplay }
            try await wait(sample + " settled output", seconds: 20) {
                guard let d = state.playbackDiagnostics?.display.videoOutput?.disposition else { return false }
                return d == .edrPresentation || d == .hdrMappedToSDR
            }
            let modeBefore = state.playbackDiagnostics!.display.videoOutput!.disposition
            e.pause(); try await wait(sample + " pause") { !state.isPlaying }
            try await Task.sleep(for: .milliseconds(300))
            let hdrBefore = hdrPixels(view)
            let handle = e.presentationProbeIdentity
            p.enter(); try await wait(sample + " PiP") { p.phase == .active }
            try await wait(sample + " PiP output", seconds: 15) { state.playbackDiagnostics?.display.videoOutput?.disposition == modeBefore }
            try await Task.sleep(for: .milliseconds(500))
            try capture(view.window!, name: "native-" + sample + "-pip.png")
            let hdrAfter = hdrPixels(view)
            let display = state.playbackDiagnostics!.display
            var entry: [String: Any] = ["sample": sample, "disposition": modeBefore.rawValue,
                "currentHeadroom": view.window!.screen!.maximumExtendedDynamicRangeColorComponentValue,
                "edrEnabled": display.edrEnabled ?? false, "targetFormat": display.targetFormat ?? "unknown"]
            if let before = hdrBefore, let after = hdrAfter {
                let difference = zip(before, after).map { abs($0 - $1) }.max()!
                entry["maximumPatchDifference"] = difference
                entry["maximumLinearSample"] = after.max()!
                try require(difference <= 0.035 && after.max()! > 1, sample + " real FP16 patches preserved in PiP within 0.035")
            } else {
                try require(modeBefore == .hdrMappedToSDR && view.hdrPrototypeSurface == nil,
                            sample + " unavailable EDR safely maps to SDR")
            }
            try require(handle == e.presentationProbeIdentity && !state.isPlaying,
                        sample + " migration preserves engine read owner and pause")
            p.exit(returnToWindow: true); try await wait(sample + " return") { p.phase == .inline && view.window === w }
            colors.set(.init(videoOutput: .sdr))
            try await wait(sample + " SDR fallback") { view.hdrPrototypeSurface == nil && state.playbackDiagnostics?.display.targetFormat == "GL_RGBA8" }
            try require(handle == e.presentationProbeIdentity, sample + " SDR fallback keeps same mpv")
            hdrEvidence.append(entry)
            await e.stopAndWaitForRetirement()
            colors.set(.init(videoOutput: .hdrIfAvailable))
        }
        colors.set(.init(videoOutput: .sdr))
        p.unmount(newHost)
        var swiftUIHost: NSHostingView<MPVVideoView>? = NSHostingView(rootView: MPVVideoView(presentation: p))
        w.contentView = swiftUIHost
        try await wait("SwiftUI mount") { view.window === w && view.isPlaybackSurfaceActive }
        await e.play(spec: PlaySpec(url: output.appendingPathComponent("fixture.mp4").absoluteString, title: "SwiftUI attachment fixture"))
        try await wait("SwiftUI playback") { state.position > 0.3 }
        let swiftIdentity = e.presentationProbeIdentity
        p.enter(); try await wait("SwiftUI PiP") { p.phase == .active }
        w.contentView = nil; swiftUIHost = nil
        await Task.yield()
        try require(view.window !== w && view.isPlaybackSurfaceActive && swiftIdentity == e.presentationProbeIdentity,
                    "actual SwiftUI dismantle preserves native PiP renderer")
        w.contentView = NSHostingView(rootView: MPVVideoView(presentation: p))
        try await Task.sleep(for: .milliseconds(200))
        p.exit(returnToWindow: true); try await wait("SwiftUI return") { p.phase == .inline && view.window === w }
        try require(swiftIdentity == e.presentationProbeIdentity, "actual SwiftUI remount reuses same renderer and engine")
        await e.stopAndWaitForRetirement()
        if ProcessInfo.processInfo.environment["NETVPLAYER_PIP_CONTROL_INTERACTION"] == "1" {
            try await verifyPlayerFloatingControls(engine: e, presentation: p, window: w)
        }
        await MPVPlayerEngine.restoreSystemHDRForTermination()
        let finalHDR = try NVSystemHDRDisplay.readDisplays().map(\.prefersHDR)
        try require(initialHDR == finalHDR, "system HDR preferences restored after real PQ HLG tests")
        facts["systemHDRBeforeAfter"] = [initialHDR, finalHDR]
        facts["HDR"] = hdrEvidence
        facts["screens"] = NSScreen.screens.map { ["name": $0.localizedName, "scale": $0.backingScaleFactor,
            "currentEDR": $0.maximumExtendedDynamicRangeColorComponentValue,
            "potentialEDR": $0.maximumPotentialExtendedDynamicRangeColorComponentValue] }
        facts["system"] = ProcessInfo.processInfo.operatingSystemVersionString
        facts["scope"] = "Real system PiP, one real libmpv, original SDR and loopback HTTP. No physical multidisplay/DV claim."
        p.unmount(newHost); w.close()
    }

    /// These stages wait for actual external clicks in the product's PlayerView.
    /// The same native window and renderer must survive every presentation change.
    func verifyPlayerFloatingControls(engine: MPVPlayerEngine, presentation: PlayerPictureInPicture,
                                     window: NSWindow) async throws {
        let suite = "com.netvplayer.floating-controls." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let appState = AppState(loadDefaultConfig: false, startProxyServer: false, startProviderRuntime: false,
            storageManager: StorageManager(storageDirectory: output.appendingPathComponent("ui-storage")),
            userPreferences: UserPreferences(defaults: defaults, credentialStore: MemoryCredentialStore()),
            providerRuntimeBootstrap: nil)
        engine.playerState = appState.playerState
        let configuration = PlayerVisualRegressionConfiguration(state: .normal, fixtureURL: nil,
            viewport: .init(width: 1480, height: 833), outputURL: nil)
        let context = PlayerWindowContext()
        window.setContentSize(configuration.viewport)
        window.center()
        context.attach(window)
        PlayerWindowChromePolicy.configurePlaybackPresentation(window, isCompact: false)
        let root = PlayerView(playerState: appState.playerState, windowContext: context,
            visualRegressionConfiguration: configuration, pictureInPicture: presentation)
            .environmentObject(appState)
        window.contentView = NSHostingView(rootView: root)
        window.title = "Floating player · isolated original fixture"
        window.makeKeyAndOrderFront(nil)
        await engine.play(spec: PlaySpec(url: output.appendingPathComponent("floating-wide.mp4").absoluteString,
                                       title: "Floating player · original test pattern"))
        try await wait("player control playback") {
            appState.playerState.position > 0.3 && appState.playerState.videoDisplayAspectRatio != nil
        }
        appState.playerState.chapters = (0..<24).map { PlayerChapter(id: $0, title: "Chapter \($0 + 1)", seconds: Double($0 * 7)) }
        engine.pause()
        try await wait("player controls paused") { !appState.playerState.isPlaying }
        let identity = engine.presentationProbeIdentity
        let position = appState.playerState.position
        let regularFrame = window.frame
        let originalAspect = window.contentAspectRatio
        let originalIncrements = window.contentResizeIncrements
        let usesModelControls = ProcessInfo.processInfo.environment["NETVPLAYER_PIP_MODEL_CONTROLS"] == "1"
        facts["windowControlRoute"] = usesModelControls ? "product model APIs; not button clicks" : "actual external button clicks"
        try capture(window, name: "player-controls-aligned.png")
        func stage(_ name: String) throws {
            try Data(name.utf8).write(to: output.appendingPathComponent("interaction-ready.txt"), options: .atomic)
            if usesModelControls {
                switch name {
                case "floating-enter", "fullscreen-floating-enter", "letterbox-enter", "crop-reenter": _ = context.enterFloatingWindow()
                case "pin", "unpin": _ = context.toggleAlwaysOnTop()
                case "restore", "restore-after-fullscreen", "crop-restore": _ = context.restoreRegularWindow()
                default: break
                }
            }
        }
        try stage("floating-enter")
        try await wait("actual floating-window enter click", seconds: 120) {
            context.isCompact && context.isAlwaysOnTop && window.level == .floating
        }
        try require(presentation.phase == .inline && presentation.videoView?.window === window
                    && identity == engine.presentationProbeIdentity,
                    "floating enter reuses original window renderer and engine without PiP")
        try await Task.sleep(for: .milliseconds(300))
        let observedBounds = presentation.videoView?.bounds.size ?? .zero
        facts["floatingObservedGeometry"] = ["width": observedBounds.width, "height": observedBounds.height,
            "frameWidth": window.frame.width, "frameHeight": window.frame.height,
            "osd": engine.nativePropertyJSON("osd-dimensions") ?? "none"]
        try capture(window, name: "floating-layout.png")
        try await wait("floating video surface finished layout") {
            let size = presentation.videoView?.bounds.size ?? .zero
            return abs(size.width - 480) < 2 && abs(size.height - 201) <= 1
        }
        let videoBounds = presentation.videoView?.bounds.size ?? .zero
        let osd = engine.nativePropertyJSON("osd-dimensions")?.data(using: .utf8)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let margins = ["mt", "mb", "ml", "mr"].compactMap { (osd?[$0] as? NSNumber)?.doubleValue }
        // AppKit rounds the frame to whole points; permit at most one point of picture padding.
        try require(abs(videoBounds.width - 480) < 2 && abs(videoBounds.height - 201) <= 1
                    && margins.count == 4 && margins.allSatisfy { $0 <= 2 },
                    "floating widescreen video is 480 points wide and fits the picture without window letterboxing")
        facts["floatingGeometry"] = ["width": videoBounds.width, "height": videoBounds.height,
            "mpvAspect": appState.playerState.videoDisplayAspectRatio ?? 0]
        try capture(window, name: "floating-pinned.png")
        try stage("unpin")
        try await wait("actual unpin click", seconds: 120) { !context.isAlwaysOnTop && window.level == .normal }
        try require(context.isCompact && identity == engine.presentationProbeIdentity, "unpin keeps compact playback in original window")
        try stage("pin")
        try await wait("actual pin click", seconds: 120) { context.isAlwaysOnTop && window.level == .floating }
        try stage("restore")
        try await wait("actual restore click", seconds: 120) { !context.isCompact && window.level == .normal }
        try require(window.frame == regularFrame && !context.isAlwaysOnTop, "restore returns original regular frame and clears pin")
        try require(window.contentAspectRatio == originalAspect && window.contentResizeIncrements == originalIncrements,
                    "restore clears floating aspect constraint for freely resizable regular window")
        window.toggleFullScreen(nil)
        try await wait("floating fixture actual fullscreen") { context.isFullScreen }
        try stage("fullscreen-floating-enter")
        try await wait("actual floating enter from fullscreen", seconds: 120) {
            context.isCompact && context.isAlwaysOnTop && !window.styleMask.contains(.fullScreen)
                && PlayerFullScreenCoordinator.attached(to: window).state.transition == nil
        }
        try require(presentation.videoView?.window === window && identity == engine.presentationProbeIdentity,
                    "fullscreen floating waits for actual exit and keeps same render view")
        try stage("restore-after-fullscreen")
        try await wait("actual restore after fullscreen", seconds: 120) { !context.isCompact && window.level == .normal }
        try require(window.frame == regularFrame && identity == engine.presentationProbeIdentity
                    && !appState.playerState.isPlaying && abs(appState.playerState.position - position) < 0.2,
                    "floating pin restore and fullscreen clicks preserve paused position and engine")
        await engine.play(spec: PlaySpec(url: output.appendingPathComponent("floating-letterbox.mp4").absoluteString,
                                       title: "Floating player · encoded bars and IMAX expansion"))
        try await wait("letterbox fixture loaded") { appState.playerState.position > 0.3 }
        engine.pause()
        try await wait("letterbox fixture paused") { !appState.playerState.isPlaying }
        let cropIdentity = engine.presentationProbeIdentity
        try stage("letterbox-enter")
        try await wait("encoded black bars removed after stable samples", seconds: 20) {
            (appState.playerState.videoDisplayAspectRatio ?? 0) > 2.35
        }
        facts["automaticCrop"] = ["property": engine.nativePropertyJSON("video-crop") ?? "none",
            "aspect": appState.playerState.videoDisplayAspectRatio ?? 0]
        try require(engine.presentationProbeIdentity == cropIdentity && !appState.playerState.isPlaying,
                    "automatic black bar crop keeps original decoder read owner and paused state")
        try await captureFittedPicture(window, name: "floating-auto-crop.png")
        facts["croppedRenderOSD"] = engine.nativePropertyJSON("osd-dimensions") ?? "none"
        try stage("crop-restore")
        try await wait("restoring regular window removes temporary crop", seconds: 120) {
            !context.isCompact && engine.nativePropertyJSON("video-crop") == "\"\""
        }
        try require(engine.presentationProbeIdentity == cropIdentity && window.frame == regularFrame,
                    "restoring regular window removes crop and preserves original frame and decoder")
        try stage("crop-reenter")
        try await wait("reentering floating redetects encoded black bars", seconds: 120) {
            context.isCompact && (appState.playerState.videoDisplayAspectRatio ?? 0) > 2.35
        }
        try require(engine.presentationProbeIdentity == cropIdentity,
                    "reentering floating redetects crop on the same paused playback")
        engine.seek(to: 12_000)
        try await wait("expanded picture restores full frame", seconds: 20) {
            abs((appState.playerState.videoDisplayAspectRatio ?? 0) - 16.0 / 9) < 0.01
                && (engine.nativePropertyJSON("video-crop") == "\"\"")
        }
        try require(engine.presentationProbeIdentity == cropIdentity && !appState.playerState.isPlaying,
                    "expanded picture automatically clears crop without replacing engine or read owner")
        try await captureFittedPicture(window, name: "floating-expanded.png")
        facts["expandedRenderOSD"] = engine.nativePropertyJSON("osd-dimensions") ?? "none"
        _ = context.restoreRegularWindow()
        try? FileManager.default.removeItem(at: output.appendingPathComponent("interaction-ready.txt"))
        await engine.stopAndWaitForRetirement()
        context.detach(window)
        window.contentView = nil
        try await appState.prepareForApplicationTermination()
    }
    func hdrPixels(_ view: MPVOpenGLVideoView) -> [Double]? {
        guard let surface = view.hdrPrototypeSurface, let data = surface.copyPresentedHalfFloats(),
              let width = surface.facts["width"] as? Int, let height = surface.facts["height"] as? Int else { return nil }
        return (0..<16).flatMap { i -> [Double] in
            let x = (40 + 80 * (i % 8)) * width / 640
            let y = (90 + 180 * (i / 8)) * height / 360
            return (0..<3).map { channel in
                data.withUnsafeBytes { Double(Float16(bitPattern: $0.loadUnaligned(fromByteOffset: (y * width + x) * 8 + channel * 2, as: UInt16.self))) }
            }
        }
    }
    func finish(_ status: String, error: String? = nil) async {
        presentation?.invalidate()
        await engine?.stopAndWaitForRetirement()
        await MPVPlayerEngine.restoreSystemHDRForTermination()
        let record: [String: Any] = ["status": status, "checks": checks, "facts": facts, "error": error ?? ""]
        if let data = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output.appendingPathComponent("native-validation.json"))
        }
        NSApp.terminate(nil)
    }
}

@MainActor final class InjectedPiPDriver: PictureInPictureDriver {
    var eventHandler: ((String) -> Void)?
    var succeeds = true
    var invalidated = false
    var usesWindow = false
    var window: NSWindow?
    func present(_ content: NSViewController, window: NSWindow, rect: NSRect, aspect: NSSize, playing: Bool) -> Bool {
        if usesWindow {
            let w = NSWindow(contentRect: .init(x: 100, y: 100, width: 320, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false; w.contentView = content.view; w.makeKeyAndOrderFront(nil); self.window = w
        }
        return succeeds
    }
    func dismiss() -> Bool { usesWindow }
    func setPlaying(_ playing: Bool) {}
    func invalidate() { invalidated = true; eventHandler = nil; window?.close(); window = nil }
}
