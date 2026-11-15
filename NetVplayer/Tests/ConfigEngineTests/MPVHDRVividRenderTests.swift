import AppKit
import Foundation
import MPVShim
import Models
import Testing
@testable import PlayerEngine

@Suite(.serialized) struct MPVHDRVividRenderTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_HDR_VIVID_FIXTURES"] != nil))
    @MainActor func decodedMetadataChangesPixelsAndNeverLeaksAcrossFrames() async throws {
        let folder = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["NETVPLAYER_HDR_VIVID_FIXTURES"]))
        let output = folder.appendingPathComponent("native-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        _ = NSApplication.shared
        let rect = NSRect(x: 20, y: 60, width: 640, height: 360)
        let window = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0.01
        let view = NVMPVOpenGLView(frame: rect)
        try #require(view.isOpenGLAvailable)
        window.contentView = view; window.orderFrontRegardless()
        defer { window.orderOut(nil); view.releaseOpenGLSurface() }
        view.makeOpenGLContextCurrent()
        let gl = try ColorReadbackGL(), fbo = gl.makeFramebuffer(width: 640, height: 360)
        defer { gl.destroyFramebuffer(fbo) }
        let context = try #require(nv_mpv_create())
        defer { view.makeOpenGLContextCurrent(); nv_mpv_destroy(context) }
        let base = ["config":"no", "vo":"libmpv", "hwdec":"no", "aid":"no", "sid":"no",
                    "terminal":"no", "idle":"yes", "keep-open":"yes", "dither-depth":"no"]
        let options = PlaybackColorPolicy.options(source: [:], preference: .init())
            .mapValues(\.value).merging(base) { _, v in v }
        for (key, value) in options { try #require(nv_mpv_set_option_string(context, key, value) >= 0) }
        try #require(nv_mpv_initialize(context) >= 0)
        try #require(nv_mpv_create_render_context(context, nil, nil) >= 0)
        let icc = try #require(NSColorSpace.sRGB.iccProfileData)
        try #require(icc.withUnsafeBytes { nv_mpv_set_render_icc(context, $0.baseAddress, $0.count) } >= 0)
        var floating = false, currentFramebuffer = fbo.framebuffer
        var currentFlags: UInt64 = 0

        @MainActor func events() -> Bool {
            var event = NVMPVEvent(), loaded = false
            while nv_mpv_wait_event(context, 0, &event) >= 0 && event.event_id != 0 {
                if event.event_id == 8 { loaded = true }
            }
            return loaded
        }
        @MainActor func draw() throws {
            view.makeOpenGLContextCurrent()
            let code = floating
                ? nv_mpv_render_fp16(context, Int32(currentFramebuffer), 640, 360, 0)
                : nv_mpv_render(context, Int32(currentFramebuffer), 640, 360, 0)
            try #require(code >= 0)
        }
        @MainActor func seek(_ seconds: Double, expectedFlags: UInt64? = nil) async throws -> (pixels: [UInt8], flags: UInt64) {
            let generation = nv_mpv_dolby_renderer_status(context).generation
            try #require(nv_mpv_command3(context, "seek", String(seconds), "absolute+exact") >= 0)
            let end = ContinuousClock.now.advanced(by: .seconds(10))
            var ready = false
            repeat {
                try draw(); _ = events()
                let status = nv_mpv_dolby_renderer_status(context)
                ready = status.generation > generation && status.rendered_frames > 0 &&
                    status.pts >= seconds && status.pts < seconds + 0.1 &&
                    status.frame_flags & 112 == (expectedFlags ?? currentFlags)
                if !ready { try await Task.sleep(for: .milliseconds(20)) }
            } while !ready && ContinuousClock.now < end
            try #require(ready)
            try draw()
            let status = nv_mpv_dolby_renderer_status(context)
            #expect(status.capabilities & 16 != 0 && status.frame_flags & 8 == 0)
            return (gl.read(framebuffer: currentFramebuffer, width: 640, height: 360), status.frame_flags)
        }
        @MainActor func load(_ name: String, root: URL? = nil) async throws -> (pixels: [UInt8], flags: UInt64) {
            _ = events()
            currentFlags = name.contains("plain") ? 0 :
                (name.contains("unsupported") || name.contains("bad-base")) ? 80 : 48
            let generation = nv_mpv_dolby_renderer_status(context).generation
            _ = nv_mpv_set_property_flag(context, "pause", 0)
            try #require(nv_mpv_command3(context, "loadfile", (root ?? folder).appendingPathComponent(name).path, "replace") >= 0)
            let end = ContinuousClock.now.advanced(by: .seconds(10))
            var loaded = false, ready = false
            repeat {
                try draw(); loaded = events() || loaded
                let status = nv_mpv_dolby_renderer_status(context)
                // A reconfigure can briefly advance generation while the old
                // frame is still displayed. Wait for this file's frame proof.
                ready = loaded && status.generation > generation && status.rendered_frames > 0 &&
                    status.pts > 0.15 && status.frame_flags & 112 == currentFlags
                if !ready { try await Task.sleep(for: .milliseconds(20)) }
            } while !ready && ContinuousClock.now < end
            try #require(ready)
            _ = nv_mpv_set_property_flag(context, "pause", 1)
            return try await seek(0.5)
        }
        func difference(_ a: [UInt8], _ b: [UInt8]) -> Int {
            zip(a,b).map { abs(Int($0) - Int($1)) }.max() ?? 0
        }
        let manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("manifest.json"))) as? [String: Any])
        let grayReference = try #require(manifest["grayReference"] as? [String: [[String: Int]]])
        var report: [[String: Any]] = []
        for transfer in ["pq", "hlg"] {
            var images: [String: [UInt8]] = [:]
            for variant in ["plain", "a", "b", "saturation", "authored", "spline", "bad-base", "unsupported", "a", "plain"] {
                let result = try await load("\(transfer)-\(variant).mp4")
                let expected: UInt64 = variant == "plain" ? 0 : ["bad-base", "unsupported"].contains(variant) ? 80 : 48
                #expect(result.flags & 112 == expected, "\(transfer)-\(variant): \(result.flags)")
                if let previous = images[variant] { #expect(difference(previous, result.pixels) <= 1) }
                images[variant] = result.pixels
                try Data(result.pixels).write(to: output.appendingPathComponent("\(transfer)-\(variant).rgba"))
            }
            let a = try #require(images["a"]), b = try #require(images["b"]), plain = try #require(images["plain"])
            let saturation = try #require(images["saturation"])
            let metadataDelta = difference(a, b), saturationDelta = difference(a, saturation)
            #expect(metadataDelta > 2 && saturationDelta > 2)
            if transfer == "pq" {
                for variant in ["a", "b"] {
                    let pixels = try #require(images[variant])
                    for patch in try #require(grayReference[variant]) {
                        let x = try #require(patch["x"]), y = try #require(patch["y"]), expected = try #require(patch["rgb8"])
                        for channel in 0..<3 {
                            let actual = Int(pixels[(y*640+x)*4+channel])
                            #expect(abs(actual-expected) <= 4, "Reference \(variant) @\(x): \(actual) != \(expected)")
                        }
                    }
                }
            }
            for variant in ["bad-base", "unsupported"] {
                #expect(difference(try #require(images[variant]), plain) <= 1)
            }
            _ = try await load("\(transfer)-changing.mp4")
            let changed = try await seek(1.5)
            #expect(changed.flags & 112 == 48 && difference(changed.pixels, b) <= 1)
            let back = try await seek(0.5)
            #expect(back.flags & 112 == 48 && difference(back.pixels, a) <= 1)
            _ = try await load("\(transfer)-missing.mp4")
            let missing = try await seek(1.5, expectedFlags: 0)
            #expect(missing.flags & 112 == 0 && difference(missing.pixels, plain) <= 1)
            report.append(["transfer": transfer, "maximumMetadataDeltaLSB": metadataDelta,
                           "maximumSaturationDeltaLSB": saturationDelta, "frameFlagsMapped": 48,
                           "frameFlagsFallback": 80, "seekAndMetadataRemovalVerified": true])
        }
        // The chapter decoder uses screenshot-raw. It must traverse the same
        // dynamic curve as visible playback, including the SDR preview target.
        let decoder = PlayerChapterThumbnailDecoder()
        var previews: [[UInt8]] = []
        for variant in ["a", "b"] {
            let data = try #require(await decoder.imageData(
                spec: PlaySpec(url: folder.appendingPathComponent("pq-\(variant).mp4").absoluteString), seconds: 0.5))
            try data.write(to: output.appendingPathComponent("preview-\(variant).png"))
            let bitmap = try #require(NSBitmapImageRep(data: data)), bytes = try #require(bitmap.bitmapData)
            previews.append(Array(UnsafeBufferPointer(start: bytes, count: bitmap.bytesPerRow * bitmap.pixelsHigh)))
        }
        #expect(difference(previews[0], previews[1]) > 2)
        var realSamples: [String] = []
        if let path = ProcessInfo.processInfo.environment["NETVPLAYER_HDR_VIVID_REAL_SAMPLES"] {
            for name in ["B.1-03.mp4", "B.1-04.mp4"] {
                let result = try await load(name, root: URL(fileURLWithPath: path))
                #expect(result.flags & 112 == 48)
                #expect(result.pixels.enumerated().contains { $0.offset % 4 != 3 && $0.element > 16 })
                realSamples.append(name)
            }
        }
        // An actual floating FBO must retain HDR values above SDR white.
        view.makeOpenGLContextCurrent()
        let hdrFbo = gl.makeFramebuffer(width: 640, height: 360, internalFormat: 0x881A)
        defer { view.makeOpenGLContextCurrent(); gl.destroyFramebuffer(hdrFbo) }
        floating = true; currentFramebuffer = hdrFbo.framebuffer
        try #require(nv_mpv_set_render_icc(context, nil, 0) >= 0)
        for (key,value) in ["target-trc":"linear", "target-prim":"bt.2020", "target-peak":"800"] {
            try #require(nv_mpv_set_property_string(context, key, value) >= 0)
        }
        var hdrResults: [[String: Any]] = []
        for transfer in ["pq", "hlg"] {
            var captures: [[Float]] = []
            for variant in ["a", "b", "a"] {
                let result = try await load("\(transfer)-\(variant).mp4")
                #expect(result.flags & 112 == 48)
                view.makeOpenGLContextCurrent()
                let values = gl.readFloat(framebuffer: currentFramebuffer, width: 640, height: 360)
                #expect(values.allSatisfy { $0.isFinite && $0 >= -0.001 && $0 < 5 })
                #expect((values.max() ?? 0) > 1.1)
                captures.append(values)
            }
            let delta = zip(captures[0], captures[1]).map { abs($0-$1) }.max() ?? 0
            let replay = zip(captures[0], captures[2]).map { abs($0-$1) }.max() ?? 1
            #expect(delta > 0.01 && replay < 0.001)
            hdrResults.append(["transfer":transfer, "maximumLinearValue":captures[0].max() ?? 0,
                               "maximumMetadataDelta":delta, "maximumReplayDelta":replay])
        }
        try JSONSerialization.data(withJSONObject: ["results": report, "floatingHDR": hdrResults,
            "realSamplesMapped": realSamples, "chapterMetadataApplied": true,
            "nativeVividSignalSent": false, "physicalHDRVerified": false], options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("report.json"))
    }
}
