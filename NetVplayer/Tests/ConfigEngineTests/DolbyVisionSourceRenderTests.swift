import AppKit
import CryptoKit
import Foundation
import MPVShim
import Testing
@testable import PlayerEngine

@Suite struct DolbyVisionSourceRenderTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_BMH04_FIXTURES"] != nil))
    @MainActor func sourceFramesLifecycleAndPairedTiming() async throws {
        _ = NSApplication.shared
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "DV paired timing validation")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let folder = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["NETVPLAYER_BMH04_FIXTURES"]))
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["NETVPLAYER_BMH04_OUTPUT"]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 640, height: 360),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "NetVplayer DV metadata validation"
        window.isReleasedWhenClosed = false
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
        try #require(nv_mpv_dolby_renderer_status(context).capabilities & 32 != 0)
        var loaded = false
        var renderMS = 0.0, presentMS = 0.0
        func property(_ name: String) -> String {
            guard let value = nv_mpv_copy_property_string(context, name) else { return "<unavailable>" }
            defer { nv_mpv_free_string(value) }; return String(cString: value)
        }
        func draw() throws -> DolbyRendererObservation? {
            var event = NVMPVEvent()
            while nv_mpv_wait_event(context, 0, &event) >= 0 && event.event_id != 0 {
                if event.event_id == 8 { loaded = true }
            }
            gl.makeOpenGLContextCurrent()
            guard surface.prepareWidth(640, height: 360) else {
                try #require(surface.temporarilyUnavailable); return nil
            }
            let start = ProcessInfo.processInfo.systemUptime
            try #require(renderDolbyVisionFrame(context: context, surface: surface, width: 640, height: 360) >= 0)
            renderMS = (ProcessInfo.processInfo.systemUptime - start)*1000
            guard let observed = DolbyRendererObservation.read(context), observed.frameReconstructed else { return nil }
            let submitStart = ProcessInfo.processInfo.systemUptime
            try #require(surface.presentPTS(observed.pts, generation: observed.generation))
            presentMS = (ProcessInfo.processInfo.systemUptime - submitStart)*1000
            nv_mpv_report_swap(context)
            return observed
        }
        func wait(_ predicate: (DolbyRendererObservation) -> Bool) async throws -> DolbyRendererObservation {
            let end = ContinuousClock.now.advanced(by: .seconds(12))
            repeat {
                if let observed = try draw(), loaded, Double(property("time-pos")) != nil, predicate(observed) { return observed }
                try await Task.sleep(for: .milliseconds(4))
            } while ContinuousClock.now < end
            print("BMH04 timeout facts", surface.facts, property("path"))
            throw NSError(domain: "BMH04FrameTimeout", code: 1)
        }
        func load(_ name: String, source: Bool, compatibility: Int32) async throws {
            surface.releaseSurface(); surface.sourceMetadataEnabled = source; surface.sourceCompatibility = compatibility
            #expect(surface.copyPresentedRPU() == nil)
            var pending = NVMPVEvent()
            while nv_mpv_wait_event(context, 0, &pending) >= 0 && pending.event_id != 0 {}
            loaded = false
            let previous = nv_mpv_dolby_renderer_status(context).generation
            _ = nv_mpv_set_property_flag(context, "pause", 0)
            try #require(nv_mpv_command3(context, "loadfile", folder.appendingPathComponent(name).path, "replace") >= 0)
            // Repeated load of the same path can briefly leave the outgoing
            // frame at its old PTS. FILE_LOADED alone does not identify pixels.
            _ = try await wait {
                $0.generation > previous && $0.pts > 0.3 && $0.pts < 2 &&
                    abs($0.pts - (Double(property("time-pos")) ?? -.infinity)) < 0.1
            }
        }
        func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        func frameRPU(_ name: String, index: Int) throws -> Data {
            let data = try Data(contentsOf: folder.appendingPathComponent(name))
            let prefix = Data([0,0,0,1])
            try #require(data.starts(with: prefix))
            var start = 4
            for _ in 0..<index {
                start = try #require(data.range(of: prefix, in: start..<data.endIndex)).upperBound
            }
            let end = data.range(of: prefix, in: start..<data.endIndex)?.lowerBound ?? data.endIndex
            return data.subdata(in: start..<end)
        }
        var lifecycle: [[String: Any]] = []
        for (name, compatibility) in [("p81-a.mp4", 1), ("p81-b.mp4", 1), ("p84.mp4", 4), ("p5.mp4", 0)] {
            try await load(name, source: true, compatibility: Int32(compatibility))
            _ = nv_mpv_set_property_flag(context, "pause", 1)
            let generation = nv_mpv_dolby_renderer_status(context).generation
            surface.invalidate(beforeGeneration: generation + 1)
            #expect(surface.copyPresentedRPU() == nil)
            _ = try draw() // Old queued frame cannot reestablish presentation proof.
            #expect((surface.facts["currentMetadataSubmitted"] as? NSNumber)?.boolValue == false)
            try #require(nv_mpv_command3(context, "seek", "1", "absolute+exact") >= 0)
            let observed = try await wait { $0.generation > generation && $0.pts >= 1 && $0.pts < 1.1 }
            let rpu = try #require(surface.copyPresentedRPU())
            let facts = surface.facts
            try #require(DolbyVisionSystemPresentation.read(facts: facts, renderer: observed, sameMedia: true).currentFrameSubmitted)
            let expectedSource = compatibility != 0
            #expect((facts["sourceRPUBytesPreserved"] as? NSNumber)?.boolValue == expectedSource)
            if expectedSource {
                #expect(facts["l1MinimumPQ"] is NSNull)
                #expect(facts["l1MaximumPQ"] is NSNull)
                #expect(facts["l1AveragePQ"] is NSNull)
            }
            var report: [String: Any] = ["sample": name, "facts": facts, "pts": observed.pts, "rpuSHA256": sha(rpu)]
            if expectedSource {
                #expect(rpu == (try frameRPU(name.replacingOccurrences(of: ".mp4", with: ".rpu"), index: Int((observed.pts*24).rounded()))))
                let pixels = try #require(surface.copyPresentedSourcePlanes())
                let reference = try Data(contentsOf: output.appendingPathComponent(name + ".p010"))
                #expect(pixels == reference)
                report["p010SHA256"] = sha(pixels)
                report["originalDecodedPixelsEqual"] = pixels == reference
                var attachments: [String: String] = [:]
                for (key, value) in surface.copyPresentedColorAttachments() {
                    if let data = value as? Data { attachments[String(describing: key)] = sha(data) }
                    else { attachments[String(describing: key)] = String(describing: value) }
                }
                report["attachments"] = attachments
                try rpu.write(to: output.appendingPathComponent(name + ".source.rpu"))
                // Same-PTS paused redraw must keep the source pixels and payload.
                _ = try await wait { abs($0.pts - observed.pts) < 0.000001 }
                #expect(surface.copyPresentedRPU() == rpu)
                #expect(surface.copyPresentedSourcePlanes() == pixels)
                // Opting out clears proof immediately, before another frame.
                surface.sourceMetadataEnabled = false
                #expect(surface.copyPresentedRPU() == nil)
                #expect((surface.facts["currentMetadataSubmitted"] as? NSNumber)?.boolValue == false)
                _ = try await wait { abs($0.pts - observed.pts) < 0.000001 }
                #expect(surface.facts["metadataOrigin"] as? String == "system-regenerated+gpu-l1")
                #expect(surface.copyPresentedRPU() != rpu)
            }
            lifecycle.append(report)
        }
        // Actual PGS composition must not disappear under the source image.
        try await load("p81-pgs.mkv", source: true, compatibility: 1)
        try #require(nv_mpv_set_property_string(context, "sid", "1") >= 0)
        _ = try await wait { $0.pts > 2 }
        print("BMH04 subtitle", property("sid"), property("sub-visibility"), surface.facts)
        #expect(property("sid") == "1")
        #expect(surface.facts["metadataOrigin"] as? String == "system-regenerated+gpu-l1")
        #expect(surface.facts["sourceCaptureReason"] as? String == "composition-or-transform")
        lifecycle.append(["sample": "p81-pgs.mkv", "facts": surface.facts])
        _ = nv_mpv_set_property_string(context, "sid", "no")

        let names = ["path", "pause", "aid", "volume", "mute"]
        _ = nv_mpv_set_property_flag(context, "pause", 1)
        let before = Dictionary(uniqueKeysWithValues: names.map { ($0, property($0)) })
        surface.releaseSurface()
        #expect(surface.copyPresentedRPU() == nil && surface.copyPresentedSourcePlanes() == nil)
        #expect((surface.facts["currentMetadataSubmitted"] as? NSNumber)?.boolValue == false)
        let after = Dictionary(uniqueKeysWithValues: names.map { ($0, property($0)) })
        #expect(before == after)

        // A/B/B/A in the same visible window, same source, same runtime, same OS.
        // Render-call time includes mpv's deadline wait; it is not GPU time.
        var timings: [[String: Any]] = []
        for source in [false, true, true, false] {
            try await load("p84.mp4", source: source, compatibility: 4)
            let first = try await wait { $0.pts >= 1 }
            let wall = ProcessInfo.processInfo.systemUptime
            var samples: [[String: Double]] = [], last = first.pts, lastWall = wall
            while last < first.pts + 4 {
                if let frame = try draw(), frame.pts > last {
                    last = frame.pts
                    let now = ProcessInfo.processInfo.systemUptime
                    try #require((surface.facts["sourceRPUBytesPreserved"] as? NSNumber)?.boolValue == source)
                    samples.append(["pts": last, "wallSincePreviousFrameMS": (now-lastWall)*1000, "renderCallMS": renderMS, "presentMS": presentMS,
                        "sourceCopyMS": (surface.facts["sourceCopyMS"] as? NSNumber)?.doubleValue ?? 0,
                        "statisticsMS": (surface.facts["statisticsMS"] as? NSNumber)?.doubleValue ?? 0,
                        "glFinishMS": (surface.facts["glFinishMS"] as? NSNumber)?.doubleValue ?? 0])
                    lastWall = now
                }
                try await Task.sleep(for: .milliseconds(4))
                try #require(ProcessInfo.processInfo.systemUptime-wall < 12)
            }
            let duration = ProcessInfo.processInfo.systemUptime-wall
            #expect(abs(duration - (last-first.pts)) < 0.4)
            timings.append(["sourceMetadata": source, "sample": "p84.mp4", "wallSeconds": duration,
                "ptsSeconds": last-first.pts, "uniqueFrames": samples.count, "samples": samples,
                "screen": window.screen?.localizedName ?? "unknown",
                "currentHeadroom": window.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1,
                "screenNumber": window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? 0])
        }
        surface.releaseSurface()
        try #require(nv_mpv_command1(context, "stop") >= 0)
        #expect(surface.copyPresentedRPU() == nil)
        let result: [String: Any] = ["lifecycle": lifecycle, "timing": timings,
            "sameCore": true, "fallbackBefore": before, "fallbackAfter": after,
            "audioDisabled": true, "hardwareDecodeUsed": false, "targetSize": [640,360],
            "receiverDolbyVisionVerified": false, "systemRPUConsumptionVerified": false]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("source-system-integration.json"))
    }
}
