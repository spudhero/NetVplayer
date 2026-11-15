import AppKit
import Darwin
import Foundation
import Models
import MPVShim
import Storage
import Testing
@testable import PlayerEngine

@Suite(.serialized) struct MPVColorRenderTests {
    private struct Chart: Decodable {
        struct Sample: Decodable {
            struct Patch: Decodable { let x: Int; let y: Int; let srgb: [Double]; let linearSRGB: [Double] }
            let file: String
            let patches: [Patch]
        }
        let width: Int
        let height: Int
        let toleranceLSB: Double
        let displayToleranceLSB: Double
        let samples: [Sample]
    }

    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_AV_COLOR_FIXTURES"] != nil))
    func nativeReferenceMatricesRangesTransfersAndICCChanges() async throws {
        let folder = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["NETVPLAYER_AV_COLOR_FIXTURES"]))
        let chart = try JSONDecoder().decode(Chart.self, from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
        _ = NSApplication.shared
        let rect = NSRect(x: 0, y: 0, width: chart.width, height: chart.height)
        let window = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01
        window.ignoresMouseEvents = true
        let view = NVMPVOpenGLView(frame: rect)
        try #require(view.isOpenGLAvailable)
        window.contentView = view
        window.orderFrontRegardless()
        defer { window.orderOut(nil); view.releaseOpenGLSurface() }
        view.makeOpenGLContextCurrent()
        let gl = try ColorReadbackGL()
        let fbo = gl.makeFramebuffer(width: chart.width, height: chart.height)
        defer { gl.destroyFramebuffer(fbo) }
        let context = try #require(nv_mpv_create())
        defer { view.makeOpenGLContextCurrent(); nv_mpv_destroy(context) }
        let base = ["config": "no", "vo": "libmpv", "hwdec": "no", "aid": "no", "sid": "no",
                    "terminal": "no", "keep-open": "yes", "idle": "yes", "scale": "bilinear", "dscale": "bilinear"]
        let options = base.merging(PlaybackColorPolicy.options(source: [:], preference: .init()).mapValues(\.value)) { _, color in color }
        for (name, value) in options.sorted(by: { $0.key < $1.key }) {
            try #require(nv_mpv_set_option_string(context, name, value) >= 0, "Unsupported option: \(name)")
        }
        try #require(nv_mpv_initialize(context) >= 0)
        _ = nv_mpv_request_log_messages(context, "v")
        try #require(nv_mpv_create_render_context(context, nil, nil) >= 0)
        var reports: [[String: Any]] = []
        var debug: [String] = []
        let referenceCGSpace = try #require(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let referenceSpace = try #require(NSColorSpace(cgColorSpace: referenceCGSpace))
        let profiles: [(String, NSColorSpace, Double)] = [
            ("sRGB", .sRGB, chart.toleranceLSB),
            ("Display-P3-simulated", .displayP3, chart.displayToleranceLSB),
            ("current-display", window.screen?.colorSpace ?? .sRGB, chart.displayToleranceLSB),
            ("sRGB-restored", .sRGB, chart.toleranceLSB)
        ]
          // With the Dolby runtime, cross the renderer boundary in the same
          // context before measuring the unchanged SDR/HDR/ICC reference.
          // This catches leaked GL state, stale RPU status and cached frames.
          func primeDolby() async throws {
              guard let path = ProcessInfo.processInfo.environment["NETVPLAYER_NATIVE_DOLBY_FIXTURES"] else { return }
              let file = URL(fileURLWithPath: path).appendingPathComponent("p5.mp4")
              _ = nv_mpv_set_property_flag(context, "pause", 0)
              try #require(nv_mpv_command3(context, "loadfile", file.path, "replace") >= 0)
              let deadline = ContinuousClock.now.advanced(by: .seconds(8))
              repeat {
                  try await renderFrames(context, view: view, fbo: fbo.framebuffer, count: 1)
                  let status = nv_mpv_dolby_renderer_status(context)
                  if status.frame_flags & 1 != 0, status.dovi_frames > 0 { return }
              } while ContinuousClock.now < deadline
              Issue.record("No reconstructed Dolby frame before color transition")
          }
        for sample in chart.samples {
              if ["sdr-limited.mkv", "pq.mkv"].contains(sample.file) { try await primeDolby() }
            try #require(nv_mpv_command3(context, "loadfile", folder.appendingPathComponent(sample.file).path, "replace") >= 0)
            let deadline = ContinuousClock.now.advanced(by: .seconds(8))
            var ready = false
            repeat {
                view.makeOpenGLContextCurrent()
                _ = nv_mpv_render(context, Int32(fbo.framebuffer), Int32(chart.width), Int32(chart.height), 0)
                var event = NVMPVEvent()
                while nv_mpv_wait_event(context, 0, &event) >= 0, event.event_id != 0 {
                    if let text = event.log_text { debug.append(sample.file + ": " + String(cString: text)) }
                }
                if let pointer = nv_mpv_copy_property_string(context, "time-pos") {
                    ready = (Double(String(cString: pointer)) ?? 0) >= 0.1
                    nv_mpv_free_string(pointer)
                }
                if !ready { try await Task.sleep(for: .milliseconds(30)) }
            } while !ready && ContinuousClock.now < deadline
            try #require(ready, "No rendered frame: \(sample.file)")
              if ProcessInfo.processInfo.environment["NETVPLAYER_NATIVE_DOLBY_FIXTURES"] != nil {
                  let status = nv_mpv_dolby_renderer_status(context)
                  #expect(status.rendered_frames > 0 && status.frame_flags == 0)
              }
            for property in ["video-dec-params", "video-params", "video-out-params"] {
                if let pointer = nv_mpv_copy_property_string(context, property) {
                    debug.append(sample.file + ": " + property + "=" + String(cString: pointer))
                    nv_mpv_free_string(pointer)
                }
            }
            _ = nv_mpv_set_property_flag(context, "pause", 1)
            for (name, space, tolerance) in profiles {
                let icc = try #require(space.iccProfileData)
                try #require(PlaybackColorPolicy.validICC(icc))
                view.makeOpenGLContextCurrent()
                try #require(icc.withUnsafeBytes { nv_mpv_set_render_icc(context, $0.baseAddress, $0.count) } >= 0)
                for _ in 0..<3 {
                    try #require(nv_mpv_render(context, Int32(fbo.framebuffer), Int32(chart.width), Int32(chart.height), 0) >= 0)
                    try await Task.sleep(for: .milliseconds(20))
                    view.makeOpenGLContextCurrent()
                }
                let pixels = gl.read(framebuffer: fbo.framebuffer, width: chart.width, height: chart.height)
                var errors: [Double] = []
                var measured: [[Double]] = []
                for patch in sample.patches {
                    let components = (patch.linearSRGB + [1]).map { CGFloat($0) }
                    let expected = try #require(NSColor(colorSpace: referenceSpace, components: components, count: 4).usingColorSpace(space))
                    let target = [expected.redComponent, expected.greenComponent, expected.blueComponent].map { min(1, max(0, $0)) }
                    var average = [Double](repeating: 0, count: 3)
                    for dy in -2...2 { for dx in -2...2 {
                        let offset = ((patch.y + dy)*chart.width + patch.x + dx)*4
                        for c in 0..<3 { average[c] += Double(pixels[offset+c])/25 }
                    } }
                    measured.append(average)
                    for c in 0..<3 { errors.append(abs(average[c] - target[c]*255)) }
                }
                let maximum = errors.max() ?? .infinity
                reports.append(["file": sample.file, "profile": name, "maximumErrorLSB": maximum,
                                "meanErrorLSB": errors.reduce(0, +)/Double(errors.count), "rgb8": measured])
                #expect(maximum <= tolerance, "\(sample.file) / \(name): max error \(maximum), tolerance \(tolerance)")
                if name == "sRGB" {
                    try Data(pixels).write(to: folder.appendingPathComponent(sample.file+".rgba"))
                }
            }
            _ = nv_mpv_set_property_flag(context, "pause", 0)
        }
        try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("native-color-results.json"))
        try debug.joined(separator: "\n").write(to: folder.appendingPathComponent("native-color-debug.log"), atomically: true, encoding: .utf8)

        // Subtitles are sRGB overlays after the video EETF, never PQ/HLG
        // pixels fed back through that EETF. Test libass vectors and decoded
        // PGS bitmaps against the same reference across three input transfers.
        var overlays: [[String: Any]] = []
        let labCGSpace = try #require(CGColorSpace(name: CGColorSpace.genericLab))
        let labSpace = try #require(NSColorSpace(cgColorSpace: labCGSpace))
        let overlayRGB: [[Double]] = [[1,1,1], [128.0/255,128.0/255,128.0/255], [1,0,0], [0,1,0]]
        for file in ["sdr-limited.mkv", "pq.mkv", "hlg.mkv"] {
            for subtitle in ["color-overlay.ass", "color-overlay.sup"] {
                _ = nv_mpv_set_property_flag(context, "pause", 0)
                let input = subtitle.hasSuffix(".sup") ? file.replacingOccurrences(of: ".mkv", with: "-pgs.mkv") : file
                try #require(nv_mpv_command3(context, "loadfile", folder.appendingPathComponent(input).path, "replace") >= 0)
                try await renderFrames(context, view: view, fbo: fbo.framebuffer, count: 12)
                if subtitle.hasSuffix(".sup") {
                    try #require(nv_mpv_set_property_string(context, "sid", "1") >= 0)
                } else {
                    try #require(nv_mpv_command3(context, "sub-add", folder.appendingPathComponent(subtitle).path, "select") >= 0)
                }
                try #require(nv_mpv_command3(context, "seek", "0", "absolute+exact") >= 0)
                try await renderFrames(context, view: view, fbo: fbo.framebuffer, count: 70)
                _ = nv_mpv_set_property_flag(context, "pause", 1)
                for (name, space, tolerance) in profiles.prefix(3) {
                    let icc = try #require(space.iccProfileData)
                    view.makeOpenGLContextCurrent()
                    try #require(icc.withUnsafeBytes { nv_mpv_set_render_icc(context, $0.baseAddress, $0.count) } >= 0)
                    try await renderFrames(context, view: view, fbo: fbo.framebuffer, count: 3)
                    let pixels = gl.read(framebuffer: fbo.framebuffer, width: 640, height: 360)
                    var errors: [Double] = []
                    var neutralErrors: [Double] = []
                    var colorDifferences: [Double] = []
                    var values: [[Double]] = []
                    for (i, rgb) in overlayRGB.enumerated() {
                        let expected = try #require(NSColor(srgbRed: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1).usingColorSpace(space))
                        let target = [expected.redComponent, expected.greenComponent, expected.blueComponent]
                        let offset = (40*640 + 42 + 64*i)*4
                        let actual = (0..<3).map { Double(pixels[offset+$0]) }
                        values.append(actual)
                        errors.append(contentsOf: (0..<3).map { abs(actual[$0]-min(1,max(0,target[$0]))*255) })
                        if i < 2 {
                            neutralErrors.append(contentsOf: (0..<3).map { abs(actual[$0]-min(1,max(0,target[$0]))*255) })
                        } else {
                            let components = (actual.map { $0/255 } + [1]).map { CGFloat($0) }
                            let measuredColor = NSColor(colorSpace: space, components: components, count: 4)
                            let measuredLab = try #require(measuredColor.usingColorSpace(labSpace))
                            let expectedLab = try #require(expected.usingColorSpace(labSpace))
                            var a = [CGFloat](repeating: 0, count: 4), b = a
                            measuredLab.getComponents(&a); expectedLab.getComponents(&b)
                            colorDifferences.append(sqrt((0..<3).reduce(0) { $0 + pow(Double(a[$1]-b[$1]),2) }))
                        }
                    }
                    let maximum = errors.max() ?? .infinity
                    let neutralMaximum = neutralErrors.max() ?? .infinity
                    let deltaE = colorDifferences.max() ?? .infinity
                    overlays.append(["video": file, "subtitle": subtitle, "profile": name, "rgb8": values,
                                     "maximumErrorLSB": maximum, "neutralMaximumErrorLSB": neutralMaximum, "maximumDeltaE76": deltaE])
                    // Keep the fixed video/neutral LSB limits. At saturated
                    // gamut boundaries a 3D LUT's interpolation can introduce
                    // small near-zero channel codes: judge those colored
                    // overlays in perceptual Lab too, with a fixed ΔE76 <= 2.
                    #expect(neutralMaximum <= tolerance && deltaE <= 2,
                            "Overlay \(file)/\(subtitle)/\(name): \(values), neutral \(neutralMaximum), ΔE76 \(deltaE)")
                }
            }
        }
          try await primeDolby()
          _ = nv_mpv_set_property_flag(context, "pause", 0)
        try #require(nv_mpv_command3(context, "loadfile", folder.appendingPathComponent("color-artwork.png").path, "replace") >= 0)
        try await renderFrames(context, view: view, fbo: fbo.framebuffer, count: 20)
        for (name, space, tolerance) in profiles.prefix(3) {
            let icc = try #require(space.iccProfileData)
            view.makeOpenGLContextCurrent()
            try #require(icc.withUnsafeBytes { nv_mpv_set_render_icc(context, $0.baseAddress, $0.count) } >= 0)
            try await renderFrames(context, view: view, fbo: fbo.framebuffer, count: 3)
            let pixels = gl.read(framebuffer: fbo.framebuffer, width: 640, height: 360)
            var errors: [Double] = []
            for (i, rgb) in overlayRGB.enumerated() {
                let expected = try #require(NSColor(srgbRed: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1).usingColorSpace(space))
                let target = [expected.redComponent, expected.greenComponent, expected.blueComponent]
                let offset = (180*640+80+160*i)*4
                errors.append(contentsOf: (0..<3).map { abs(Double(pixels[offset+$0])-min(1,max(0,target[$0]))*255) })
            }
            let maximum = errors.max() ?? .infinity
            overlays.append(["artwork": "color-artwork.png", "profile": name, "maximumErrorLSB": maximum])
            #expect(maximum <= tolerance, "Artwork/\(name): error \(maximum)")
        }
        try JSONSerialization.data(withJSONObject: overlays, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("native-overlay-results.json"))
    }

    @MainActor private func renderFrames(_ context: OpaquePointer, view: NVMPVOpenGLView, fbo: UInt32, count: Int) async throws {
        for _ in 0..<count {
            view.makeOpenGLContextCurrent()
            try #require(nv_mpv_render(context, Int32(fbo), 640, 360, 0) >= 0)
            var event = NVMPVEvent()
            while nv_mpv_wait_event(context, 0, &event) >= 0, event.event_id != 0 {
                if let message = event.log_text,
                   let folder = ProcessInfo.processInfo.environment["NETVPLAYER_AV_COLOR_FIXTURES"] {
                    let url = URL(fileURLWithPath: folder).appendingPathComponent("overlay-debug.log")
                    let data = Data(String(cString: message).utf8)
                    if let output = try? FileHandle(forWritingTo: url) { _ = try? output.seekToEnd(); try? output.write(contentsOf: data); try? output.close() }
                    else { try? data.write(to: url) }
                }
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        view.makeOpenGLContextCurrent()
    }

    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_AV_COLOR_FIXTURES"] != nil))
    func enginePreferencesResetAndProfileNotifications() async throws {
        let folder = try #require(ProcessInfo.processInfo.environment["NETVPLAYER_AV_COLOR_FIXTURES"])
        _ = NSApplication.shared
        let suite = "NetVplayer.native-color-tests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PlaybackColorPreferenceStore(defaults: defaults)
        preferences.set(.init(videoOutput: .sdr))
        let engine = MPVPlayerEngine(videoSurface: .vod, colorPreferences: preferences)
        let state = PlayerState()
        engine.playerState = state
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01
        window.ignoresMouseEvents = true
        let view = try #require(MPVOpenGLVideoView(engine: engine, surface: .vod))
        view.frame = window.contentView!.bounds
        window.contentView = view
        window.orderFrontRegardless()
        engine.attach(to: view, surface: .vod)
        defer { engine.stop(); engine.detach(from: view); view.deactivatePlaybackSurface(); window.orderOut(nil) }
        let source = PlaySpec(url: URL(fileURLWithPath: folder).appendingPathComponent("pq.mkv").absoluteString,
                              mpvOptions: ["tone-mapping": "reinhard", "target-peak": "100"])
        await engine.play(spec: source)
        try #require(await wait { state.playbackDiagnostics?.display.toneMapping == "reinhard"
            && state.playbackDiagnostics?.display.targetFormat == "GL_RGBA8" })
        #expect(state.playbackDiagnostics?.display.referencePeakNits == 100)
        #expect(state.playbackDiagnostics?.display.iccSubmission == .display)
        let owner = state.playbackDiagnostics?.mediaID
        preferences.set(.init(toneMapping: .mobius, peakNits: 150, videoOutput: .sdr))
        try #require(await wait { state.playbackDiagnostics?.display.toneMapping == "mobius" && state.playbackDiagnostics?.display.referencePeakNits == 150 })
        #expect(state.playbackDiagnostics?.mediaID == owner)
        preferences.reset()
        #expect(preferences.snapshot.videoOutput == .automatic)
        preferences.set(.init(videoOutput: .sdr)) // This test measures SDR mapping preferences.
        try #require(await wait { state.playbackDiagnostics?.display.toneMapping == "reinhard" && state.playbackDiagnostics?.display.referencePeakNits == 100 })
        NotificationCenter.default.post(name: NSWindow.didChangeScreenProfileNotification, object: window)
        #expect(window.colorSpace == window.screen?.colorSpace)
        await engine.play(spec: PlaySpec(url: URL(fileURLWithPath: folder).appendingPathComponent("sdr-limited.mkv").absoluteString))
        try #require(await wait { state.playbackDiagnostics?.mediaID != owner && state.playbackDiagnostics?.display.toneMapping == "bt.2390"
            && state.playbackDiagnostics?.display.targetFormat == "GL_RGBA8" })
        #expect(state.playbackDiagnostics?.display.referencePeakNits == 203)
        #expect(state.playbackDiagnostics?.display.edrEnabled == false)
        #expect(state.playbackDiagnostics?.video.interpretedRange == "limited")
        #expect(state.playbackDiagnostics?.video.interpretedMatrix == "bt.709")
        #expect(!state.mpvOptionDiagnostics.contains { $0.status == .rejected })
    }

    @MainActor private func wait(_ predicate: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !predicate(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(30)) }
        return predicate()
    }
}

/// Resolve the existing GL ABI without exposing deprecated AppKit/OpenGL types
/// in the Swift production API. This helper is only linked into the test bundle.
struct ColorReadbackGL {
    private let library: UnsafeMutableRawPointer
    init() throws {
        library = try #require(dlopen("/System/Library/Frameworks/OpenGL.framework/OpenGL", RTLD_NOW))
    }
    private func function<T>(_ name: String, _ type: T.Type) -> T { unsafeBitCast(dlsym(library, name)!, to: T.self) }
    struct Framebuffer { var framebuffer: UInt32; var texture: UInt32 }
    func makeFramebuffer(width: Int, height: Int, internalFormat: Int32 = 0x8058) -> Framebuffer {
        var fbo = Framebuffer(framebuffer: 0, texture: 0)
        function("glGenTextures", (@convention(c) (Int32, UnsafeMutablePointer<UInt32>) -> Void).self)(1, &fbo.texture)
        function("glBindTexture", (@convention(c) (UInt32, UInt32) -> Void).self)(0x0DE1, fbo.texture)
        function("glTexImage2D", (@convention(c) (UInt32, Int32, Int32, Int32, Int32, Int32, UInt32, UInt32, UnsafeRawPointer?) -> Void).self)(0x0DE1, 0, internalFormat, Int32(width), Int32(height), 0, 0x1908, 0x1401, nil)
        let parameter = function("glTexParameteri", (@convention(c) (UInt32, UInt32, Int32) -> Void).self)
        parameter(0x0DE1, 0x2801, 0x2601)
        parameter(0x0DE1, 0x2800, 0x2601)
        function("glGenFramebuffers", (@convention(c) (Int32, UnsafeMutablePointer<UInt32>) -> Void).self)(1, &fbo.framebuffer)
        function("glBindFramebuffer", (@convention(c) (UInt32, UInt32) -> Void).self)(0x8D40, fbo.framebuffer)
        function("glFramebufferTexture2D", (@convention(c) (UInt32, UInt32, UInt32, UInt32, Int32) -> Void).self)(0x8D40, 0x8CE0, 0x0DE1, fbo.texture, 0)
        return fbo
    }
    func destroyFramebuffer(_ fbo: Framebuffer) {
        var fbo = fbo
        function("glDeleteFramebuffers", (@convention(c) (Int32, UnsafePointer<UInt32>) -> Void).self)(1, &fbo.framebuffer)
        function("glDeleteTextures", (@convention(c) (Int32, UnsafePointer<UInt32>) -> Void).self)(1, &fbo.texture)
    }
    func read(framebuffer: UInt32, width: Int, height: Int) -> [UInt8] {
        function("glBindFramebuffer", (@convention(c) (UInt32, UInt32) -> Void).self)(0x8D40, framebuffer)
        var bytes = [UInt8](repeating: 0, count: width*height*4)
        bytes.withUnsafeMutableBytes {
            function("glReadPixels", (@convention(c) (Int32, Int32, Int32, Int32, UInt32, UInt32, UnsafeMutableRawPointer?) -> Void).self)(0, 0, Int32(width), Int32(height), 0x1908, 0x1401, $0.baseAddress)
        }
        return bytes
    }
    func readFloat(framebuffer: UInt32, width: Int, height: Int) -> [Float] {
        function("glBindFramebuffer", (@convention(c) (UInt32, UInt32) -> Void).self)(0x8D40, framebuffer)
        var values = [Float](repeating: 0, count: width*height*4)
        values.withUnsafeMutableBytes {
            function("glReadPixels", (@convention(c) (Int32, Int32, Int32, Int32, UInt32, UInt32, UnsafeMutableRawPointer?) -> Void).self)(0, 0, Int32(width), Int32(height), 0x1908, 0x1406, $0.baseAddress)
        }
        return values
    }
}
