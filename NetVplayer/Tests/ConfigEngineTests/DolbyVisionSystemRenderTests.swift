import AppKit
import Foundation
import MPVShim
import Testing
@testable import PlayerEngine

@Suite struct DolbyVisionSystemRenderTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_AV_DV_SYSTEM_FIXTURES"] != nil))
    @MainActor func reconstructedFramesCarryCurrentSystemRPUAndKeepSession() async throws {
        _ = NSApplication.shared
        let folder = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["NETVPLAYER_AV_DV_SYSTEM_FIXTURES"]))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0.01
        let gl = NVMPVOpenGLView(frame: window.contentView!.bounds)
        try #require(gl.isOpenGLAvailable)
        let surface = try #require(NVDolbyVisionSurface.make(frame: gl.bounds))
        gl.addSubview(surface); window.contentView = gl; window.orderFrontRegardless()
        gl.makeOpenGLContextCurrent()
        let context = try #require(nv_mpv_create())
        defer {
            gl.makeOpenGLContextCurrent(); surface.releaseSurface(); nv_mpv_destroy(context)
            window.orderOut(nil); gl.releaseOpenGLSurface()
        }
        let base = ["config":"no", "vo":"libmpv", "hwdec":"no", "aid":"no", "sid":"no",
                    "terminal":"no", "idle":"yes", "keep-open":"yes", "volume":"37", "mute":"yes"]
        for (key, value) in base.merging(DolbyVisionSystemPresentationPolicy.options, uniquingKeysWith: { _, value in value }) {
            try #require(nv_mpv_set_option_string(context, key, value) >= 0)
        }
        try #require(nv_mpv_initialize(context) >= 0)
        try #require(nv_mpv_create_render_context(context, nil, nil) >= 0)
        try #require(nv_mpv_runtime_capabilities(context) & 3 == 3)
        var reports: [[String: Any]] = []
        var loaded = false
        func property(_ name: String) -> String {
            guard let value = nv_mpv_copy_property_string(context, name) else { return "<unavailable>" }
            defer { nv_mpv_free_string(value) }; return String(cString: value)
        }
        func draw(until predicate: (DolbyRendererObservation) -> Bool) async throws -> DolbyRendererObservation {
            let deadline = ContinuousClock.now.advanced(by: .seconds(12))
            repeat {
                var event = NVMPVEvent()
                while nv_mpv_wait_event(context, 0, &event) >= 0 && event.event_id != 0 {
                    if event.event_id == 8 { loaded = true }
                }
                gl.makeOpenGLContextCurrent()
                if surface.prepareWidth(640, height: 360) {
                    try #require(nv_mpv_render_fp16(context, surface.framebuffer, 640, 360, 0) >= 0)
                    if let observed = DolbyRendererObservation.read(context), observed.frameReconstructed {
                        try #require(surface.presentPTS(observed.pts, generation: observed.generation))
                        nv_mpv_report_swap(context)
                        if loaded && Double(property("time-pos")) != nil && predicate(observed) { return observed }
                    }
                } else { try #require(surface.temporarilyUnavailable) }
                try await Task.sleep(for: .milliseconds(15))
            } while ContinuousClock.now < deadline
            throw NSError(domain: "DVSystemTestTimeout", code: 1)
        }
        for name in ["p81-a.mp4", "p81-b.mp4", "p5.mp4", "p84.mp4"] {
            surface.releaseSurface()
            loaded = false
            let generation = nv_mpv_dolby_renderer_status(context).generation
            _ = nv_mpv_set_property_flag(context, "pause", 0)
            try #require(nv_mpv_command3(context, "loadfile", folder.appendingPathComponent(name).path, "replace") >= 0)
            _ = try await draw { $0.generation > generation && $0.pts > 0.3 }
            _ = nv_mpv_set_property_flag(context, "pause", 1)
            let seekGeneration = nv_mpv_dolby_renderer_status(context).generation
            try #require(nv_mpv_command3(context, "seek", "1", "absolute+exact") >= 0)
            let observed = try await draw { $0.generation > seekGeneration && $0.pts >= 1 && $0.pts < 1.1 }
            let pixels = try #require(surface.copyPresentedHalfFloats())
            #expect(pixels.count == 640*360*8)
            let finite = pixels.withUnsafeBytes { raw in
                stride(from: 0, to: raw.count, by: 2).allSatisfy {
                    Float16(bitPattern: raw.loadUnaligned(fromByteOffset: $0, as: UInt16.self)).isFinite
                }
            }
            #expect(finite)
            let rpu = try #require(surface.copyPresentedRPU())
            try rpu.write(to: folder.appendingPathComponent(name + ".system.rpu"))
            let facts = surface.facts
            #expect(DolbyVisionSystemPresentation.read(facts: facts, renderer: observed, sameMedia: true).currentFrameSubmitted)
            reports.append(["source": name, "facts": facts, "pts": observed.pts, "allFinite": finite])
        }
        // A presentation failure/fallback changes only the video target. Keep the
        // same core, loaded path, pause, selected aid and user gain/mute values.
        let names = ["path", "pause", "aid", "volume", "mute"]
        let before = Dictionary(uniqueKeysWithValues: names.map { ($0, property($0)) })
        surface.releaseSurface()
        for (key, value) in PlaybackColorPolicy.options(source: [:], preference: .init()) {
            try #require(nv_mpv_set_property_string(context, key, value.value) >= 0)
        }
        gl.makeOpenGLContextCurrent()
        try #require(nv_mpv_render(context, 0, 640, 360, 1) >= 0)
        #expect(nv_mpv_render_target_format(context) == 0x8058)
        let after = Dictionary(uniqueKeysWithValues: names.map { ($0, property($0)) })
        #expect(before == after)
        #expect((surface.facts["currentMetadataSubmitted"] as? NSNumber)?.boolValue == false)
        let report: [String: Any] = ["sources": reports, "fallbackBefore": before, "fallbackAfter": after,
            "sameCore": true, "sourceRPUPassthrough": false, "receiverDolbyVisionVerified": false]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("system-presentation.json"))
    }
}
