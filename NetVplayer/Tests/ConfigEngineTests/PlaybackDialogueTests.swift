import AppKit
import Darwin
import Foundation
import Models
import MPVShim
import Storage
import Testing
@testable import PlayerEngine

@Suite struct PlaybackDialogueTests {
    private func audio(_ channels: String = "fl-fr", count: Int = 2) -> PlaybackDiagnostics.Audio {
        .init(codec: "pcm_s24le", inputChannels: channels, inputChannelCount: count, inputSampleRate: 48000, mode: .pcm)
    }

    @Test func defaultAndResetDoNotChangeOtherPreferences() throws {
        let suite = "DialoguePreference.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let volume = PlaybackAudioPreferenceStore(defaults: defaults)
        let output = PlaybackAudioOutputPreferenceStore(defaults: defaults)
        volume.setVolume(0.37); volume.setMuted(true)
        output.set(.init(deviceUID: "receiver", mode: .surround71))
        let store = PlaybackDialoguePreferenceStore(defaults: defaults)
        #expect(store.snapshot == .off)
        #expect(PlaybackDialoguePolicy.resolve(strength: .off, audio: audio()).filter.isEmpty)
        store.set(.strong)
        #expect(PlaybackDialoguePreferenceStore(defaults: defaults).snapshot == .strong)
        store.reset()
        #expect(store.snapshot == .off)
        #expect(volume.snapshot.volume == 0.37 && volume.snapshot.isMuted)
        #expect(output.snapshot.deviceUID == "receiver" && output.snapshot.mode == .surround71)
        defaults.set("future", forKey: PlaybackDialoguePreferenceStore.key)
        #expect(PlaybackDialoguePreferenceStore(defaults: defaults).snapshot == .off)
    }

    @Test func layoutsRequireNamesAndKeepSideRearDistinct() {
        for (channels, count, layout) in [("fl-fr-fc-lfe-bl-br", 6, "5.1"), ("fl-fr-fc-lfe-sl-sr", 6, "5.1(side)"), ("fl-fr-fc-lfe-bl-br-sl-sr", 8, "7.1")] {
            let plan = PlaybackDialoguePolicy.resolve(strength: .strong, audio: audio(channels, count: count))
            #expect(plan.status == .center)
            #expect(plan.graph.hasPrefix("pan=\(layout)|"))
        }
        for (channels, count) in [("unknown6", 6), ("fl-fr", 6), ("fc", 1), ("fl-fr-bl-br", 4), ("5.1", 8)] {
            let plan = PlaybackDialoguePolicy.resolve(strength: .medium, audio: audio(channels, count: count))
            #expect(plan.status == .unsupportedLayout && plan.graph.isEmpty)
        }
        #expect(PlaybackDialoguePolicy.resolve(strength: .medium, audio: .init()).status == .checking)
    }

    @Test func passthroughAndSourceFiltersRetainChoiceWithoutConversion() throws {
        var input = audio(); input.mode = .passthrough
        let compressed = PlaybackDialoguePolicy.resolve(strength: .strong, audio: input)
        #expect(compressed.status == .passthrough && compressed.filter.isEmpty && compressed.strength == .strong)
        #expect(PlaybackDialoguePolicy.resolve(strength: .medium, audio: audio(), passthroughRequested: true).status == .passthrough)
        #expect(PlaybackDialoguePolicy.resolve(strength: .light, audio: audio(), sourceFilters: true).status == .sourceFilters)
        #expect(PlaybackDialoguePolicy.hasPassthroughRequest(nil))
        for json in [#"["ac3"]"#, #""eac3,truehd""#, "{}"] { #expect(PlaybackDialoguePolicy.hasPassthroughRequest(Data(json.utf8))) }
        for json in ["[]", #""""#] { #expect(!PlaybackDialoguePolicy.hasPassthroughRequest(Data(json.utf8))) }
    }

    @Test func confirmationRequiresLabelExactGraphAndEnabledState() throws {
        let plan = PlaybackDialoguePolicy.resolve(strength: .medium, audio: audio())
        func property(_ graph: String, enabled: Bool = true) throws -> Data {
            try JSONSerialization.data(withJSONObject: [["name":"lavfi", "label": PlaybackDialoguePolicy.label,
                                                       "enabled":enabled, "params":["graph":graph]]])
        }
        #expect(PlaybackDialoguePolicy.confirms(plan, property: try property(plan.graph)))
        #expect(!PlaybackDialoguePolicy.confirms(plan, property: try property(plan.graph, enabled: false)))
        #expect(!PlaybackDialoguePolicy.confirms(plan, property: try property("anull")))
        #expect(!PlaybackDialoguePolicy.confirms(plan, property: nil))
        let off = PlaybackDialoguePolicy.resolve(strength: .off, audio: audio())
        #expect(PlaybackDialoguePolicy.confirms(off, property: Data("[]".utf8)))
        #expect(!PlaybackDialoguePolicy.confirms(off, property: try property(plan.graph)))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_AV_DIALOGUE_FIXTURES"] != nil))
    func exportProductionFilterPlansForIndependentPCMMeasurement() throws {
        let folder = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["NETVPLAYER_AV_DIALOGUE_FIXTURES"]))
        var plans: [String: [String: String]] = [:]
        for (layout, count) in [("stereo",2),("5.1",6),("5.1(side)",6),("7.1",8)] {
            plans[layout] = Dictionary(uniqueKeysWithValues: PlaybackDialogueStrength.allCases.map {
                ($0.rawValue, PlaybackDialoguePolicy.resolve(strength: $0, audio: audio(layout, count: count)).filter)
            })
        }
        try JSONEncoder().encode(plans).write(to: folder.appendingPathComponent("production-plans.json"), options: .atomic)
    }

    @MainActor @Test func transitionCancellationDoesNotWriteFilterOrPersistGain() async throws {
        var writes = 0
        let gains = DialogueGainRecorder()
        let task = Task { @MainActor in
            try await PlaybackDialogueTransition.run(initialGain: 1, playing: true,
                setGain: { gains.append($0) }, setFilter: { writes += 1; return true })
        }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled transition must throw") } catch {}
        #expect(writes == 0)
        #expect(!gains.values.isEmpty && gains.values.allSatisfy { $0 >= 0 && $0 < 1 })
    }

    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_AV_DIALOGUE_FIXTURES"] != nil))
    func nativePCMTransitionWaveformUsesProductionFade() async throws {
        let folder = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["NETVPLAYER_AV_DIALOGUE_FIXTURES"]))
        let capture = folder.appendingPathComponent("transition-output.f32")
        let handle = DialoguePCMHandle(try #require(nv_mpv_create()))
        var destroyed = false
        defer { if !destroyed { nv_mpv_destroy(handle.context) } }
        let options = ["config":"no", "video":"auto", "vo":"null", "untimed":"no", "ao":"pcm", "ao-pcm-file":capture.path,
                       "ao-pcm-waveheader":"no", "audio-format":"float", "audio-channels":"stereo", "audio-samplerate":"48000",
                       "volume":"100", "idle":"yes", "msg-level":"all=warn"]
        for (name,value) in options { try #require(nv_mpv_set_option_string(handle.context,name,value)>=0) }
        try #require(nv_mpv_initialize(handle.context)>=0)
        try #require(nv_mpv_command3(handle.context,"loadfile",folder.appendingPathComponent("transition.mov").path,"replace")>=0)
        var event = NVMPVEvent()
        let loadedDeadline = ContinuousClock.now.advanced(by:.seconds(3))
        var loaded = false
        while !loaded, ContinuousClock.now < loadedDeadline {
            while nv_mpv_wait_event(handle.context,0,&event)==0, event.event_id != 0 { if event.event_id == 8 { loaded=true } }
            try await Task.sleep(for:.milliseconds(5))
        }
        try #require(loaded)
        try await Task.sleep(for:.seconds(2))
        let transitionStart = ProcessInfo.processInfo.systemUptime
        var changes: [[String:String]] = []
        for (index,strength) in [PlaybackDialogueStrength.strong,.off,.medium,.strong,.off].enumerated() {
            let plan = PlaybackDialoguePolicy.resolve(strength:strength,audio:audio())
            let accepted = try await PlaybackDialogueTransition.run(initialGain:1,playing:true,
                setGain:{ value in _ = nv_mpv_set_property_double_async(handle.context,100,"volume",value*100) },
                setFilter:{
                    let id = UInt64(1000+index)
                    guard nv_mpv_command3_async(handle.context,id,"af","set",plan.filter)>=0 else { return false }
                    let deadline = ContinuousClock.now.advanced(by:.seconds(2))
                    var reply = NVMPVEvent()
                    while ContinuousClock.now < deadline {
                        while nv_mpv_wait_event(handle.context,0,&reply)==0, reply.event_id != 0 {
                            if reply.event_id == 5, reply.reply_userdata == id { return reply.error >= 0 }
                        }
                        try? await Task.sleep(for:.milliseconds(2))
                    }
                    return false
                })
            #expect(accepted)
            changes.append(["strength":strength.rawValue,"filter":plan.filter,"completedElapsedSeconds":String(ProcessInfo.processInfo.systemUptime-transitionStart)])
            if index < 4 { try await Task.sleep(for:.seconds(1)) }
        }
        let deadline = ContinuousClock.now.advanced(by:.seconds(10))
        var ended = false
        while !ended, ContinuousClock.now < deadline {
            while nv_mpv_wait_event(handle.context,0,&event)==0, event.event_id != 0 { if event.event_id == 7 { ended=true } }
            try await Task.sleep(for:.milliseconds(5))
        }
        #expect(ended)
        nv_mpv_destroy(handle.context); destroyed = true
        let data = try Data(contentsOf:capture)
        let floats = data.withUnsafeBytes { Array($0.bindMemory(to:Float.self)) }
        try #require(floats.count > 48000*2*12)
        var maximumStep: Float = 0
        for index in stride(from:2,to:floats.count,by:2) { maximumStep = max(maximumStep,abs(floats[index]-floats[index-2])) }
        let baselineStep = 0.5*sin(.pi*120/48000)
        let extraStep = max(0,Double(maximumStep)-baselineStep)
        let tail = floats.suffix(48000*2)
        let tailRMS = sqrt(tail.reduce(0.0) { $0+Double($1)*Double($1) }/Double(tail.count))
        let report: [String:Any] = ["route":"Bundled mpv AO pcm, vo=null video clock, untimed=no; no CoreAudio/acoustic claim",
            "frames":floats.count/2,"maximumStep":maximumStep,"baselineStep":baselineStep,"extraStep":extraStep,
            "threshold":0.02,"tailRMS":tailRMS,"changes":changes,"passed":extraStep<=0.02 && abs(tailRMS-0.25/sqrt(2))<0.001]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("transition-measurement.json"),options:.withoutOverwriting)
        #expect(extraStep<=0.02)
        #expect(abs(tailRMS-0.25/sqrt(2))<0.001)
    }

    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_AV_DIALOGUE_FIXTURES"] != nil))
    func nativeInvalidFilterCommandRejectsAndPreservesPreviousChain() async throws {
        let folder = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["NETVPLAYER_AV_DIALOGUE_FIXTURES"]))
        let handle = try #require(nv_mpv_create())
        defer { nv_mpv_destroy(handle) }
        for (name,value) in ["config":"no", "vo":"null", "ao":"null", "idle":"yes", "af":"lavfi=[anull]"] {
            try #require(nv_mpv_set_option_string(handle,name,value)>=0)
        }
        try #require(nv_mpv_initialize(handle)>=0)
        try #require(nv_mpv_command3(handle,"loadfile",folder.appendingPathComponent("transition.mov").path,"replace")>=0)
        var loaded = false
        var event = NVMPVEvent()
        let loadDeadline = ContinuousClock.now.advanced(by:.seconds(3))
        while !loaded, ContinuousClock.now < loadDeadline {
            while nv_mpv_wait_event(handle,0,&event)==0, event.event_id != 0 { if event.event_id == 8 { loaded = true } }
            try await Task.sleep(for:.milliseconds(5))
        }
        try #require(loaded)
        let id: UInt64 = 900
        try #require(nv_mpv_command3_async(handle,id,"af","set","lavfi=[netvplayer_intentionally_missing_filter]")>=0)
        let deadline = ContinuousClock.now.advanced(by:.seconds(2))
        var rejected = false
        while !rejected, ContinuousClock.now < deadline {
            while nv_mpv_wait_event(handle,0,&event)==0, event.event_id != 0 {
                if event.event_id == 5, event.reply_userdata == id { rejected = event.error < 0 }
            }
            try await Task.sleep(for:.milliseconds(5))
        }
        #expect(rejected)
        let property = nv_mpv_copy_property_json(handle,"af")
        defer { nv_mpv_free_string(property) }
        let af = property.map { String(cString:$0) }
        #expect(af?.contains("anull") == true)
        #expect(af?.contains("netvplayer_intentionally_missing_filter") == false)
        try JSONEncoder().encode(["rejected":rejected,"previousChainPreserved":af?.contains("anull") == true])
            .write(to:folder.appendingPathComponent("native-rejected-filter.json"),options:.withoutOverwriting)
    }

    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_AV_DIALOGUE_FIXTURES"] != nil))
    func nativeDialogueTracksSubtitlesRapidChangesAndIndependentSessions() async throws {
        let folder = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["NETVPLAYER_AV_DIALOGUE_FIXTURES"]))
        let suite = "DialogueNative.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preference = PlaybackDialoguePreferenceStore(defaults: defaults)
        let volume = PlaybackAudioPreferenceStore(defaults: defaults)
        let output = PlaybackAudioOutputPreferenceStore(defaults: defaults)
        volume.setVolume(0.37); volume.setMuted(true)
        _ = NSApplication.shared
        let engine = MPVPlayerEngine(videoSurface: .vod, audioPreferences: volume, audioOutputPreferences: output, dialoguePreferences: preference)
        let state = PlayerState(); engine.playerState = state
        let window = NSWindow(contentRect: NSRect(x:0,y:0,width:640,height:360), styleMask:[.borderless], backing:.buffered, defer:false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0.01; window.ignoresMouseEvents = true
        let view = try #require(MPVOpenGLVideoView(engine:engine,surface:.vod))
        view.frame = window.contentView!.bounds; window.contentView = view; window.orderFrontRegardless()
        engine.attach(to:view,surface:.vod)
        defer { engine.stop(); engine.detach(from:view); window.orderOut(nil) }
        var reports: [String:String] = [:]
        func checkpoint(_ phase: String) throws {
            try JSONEncoder().encode(["phase": phase]).write(to: folder.appendingPathComponent("native-dialogue-checkpoint.json"), options: .atomic)
        }
        func ready(_ status: PlaybackDialogueStatus, _ strength: PlaybackDialogueStrength) -> Bool {
            state.playbackDiagnostics?.audio.dialogue?.status == status && state.playbackDiagnostics?.audio.dialogue?.requested == strength
                && state.playbackDiagnostics?.audio.dialogue?.filterConfirmed == true
        }
        try checkpoint("initial-off")
        await engine.play(spec: PlaySpec(url: folder.appendingPathComponent("av08-stereo.mov").absoluteString))
        try #require(await wait { ready(.off,.off) && state.playbackDiagnostics?.display.targetFormat == "GL_RGBA8" })
        #expect(engine.nativePropertyJSON("af") == "[]")
        let media = try #require(state.playbackDiagnostics?.mediaID)
        #expect(state.playbackDiagnostics?.ffmpegVersion == "9.0.1")
        reports["initial-off"] = state.playbackDiagnostics?.redactedJSON()
        for strength in [PlaybackDialogueStrength.light,.medium,.strong] {
            try checkpoint("stereo-"+strength.rawValue)
            preference.set(strength)
            try #require(await wait { ready(.stereo,strength) })
            #expect(state.playbackDiagnostics?.mediaID == media)
            #expect(state.volume == 0.37 && state.isMuted)
            reports["stereo-"+strength.rawValue] = state.playbackDiagnostics?.redactedJSON()
        }
        engine.pause()
        try #require(await wait { !state.isPlaying })
        let position = state.position
        let subtitle = try #require(state.subtitleTracks.first)
        engine.selectSubtitleTrack(id: subtitle.id)
        try #require(await wait { state.selectedSubtitleTrackID == subtitle.id })
        engine.speed = 1.5
        preference.set(.light)
        try #require(await wait { ready(.stereo,.light) })
        #expect(!state.isPlaying && abs(state.position-position)<0.3 && state.speed == 1.5)
        #expect(state.selectedSubtitleTrackID == subtitle.id)
        reports["paused-subtitle-speed"] = state.playbackDiagnostics?.redactedJSON()
        engine.speed = 1
        engine.seek(to: 16_000)
        engine.resume()
        try #require(await wait { state.isPlaying && state.position > 16.5 })
        var sync: [Double] = []
        for _ in 0..<8 {
            try await Task.sleep(for: .seconds(1))
            let offset = try #require(state.playbackDiagnostics?.audioVideoOffsetSeconds)
            sync.append(offset); #expect(abs(offset)<=0.080)
        }
        reports["engine-sync"] = String(decoding:try JSONEncoder().encode(sync),as:UTF8.self)
        try checkpoint("rapid-cancellation")
        for strength in [PlaybackDialogueStrength.strong,.off,.medium,.off,.strong,.off] {
            preference.set(strength)
            try await Task.sleep(for: .milliseconds(80))
        }
        try #require(await wait { ready(.off,.off) })
        #expect(engine.nativePropertyJSON("af") == "[]")
        #expect(engine.nativePropertyJSON("volume").flatMap(Double.init).map { abs($0-37)<0.001 } == true)
        #expect(state.selectedSubtitleTrackID == subtitle.id)
        reports["rapid-restored"] = state.playbackDiagnostics?.redactedJSON()
        try checkpoint("sleep-interrupts-transition")
        preference.set(.strong)
        try await Task.sleep(for:.milliseconds(80))
        engine.audioEnvironmentDidChange(sleeping:true)
        try await Task.sleep(for:.milliseconds(100))
        preference.set(.medium)
        engine.audioEnvironmentDidChange(sleeping:false)
        try #require(await wait { ready(.stereo,.medium) })
        #expect(state.volume == 0.37 && state.isMuted && state.selectedSubtitleTrackID == subtitle.id)
        reports["simulated-sleep-during-fade"] = state.playbackDiagnostics?.redactedJSON()
        try checkpoint("external-center")
        preference.set(.medium)
        await engine.play(spec: PlaySpec(url: folder.appendingPathComponent("av08-stereo.mov").absoluteString,
            externalAudioURL: folder.appendingPathComponent("av08-5.1.wav").absoluteString))
        try #require(await wait { ready(.center,.medium) && state.audioTracks.count>=2 })
        let external = try #require(state.selectedAudioTrackID)
        #expect(state.playbackDiagnostics?.audio.inputChannelCount == 6)
        #expect(state.playbackDiagnostics?.mediaID != media)
        reports["external-center"] = state.playbackDiagnostics?.redactedJSON()
        engine.selectAudioTrack(id: try #require(state.audioTracks.first { $0.id != external }?.id))
        try #require(await wait { ready(.stereo,.medium) && state.playbackDiagnostics?.audio.inputChannelCount == 2 })
        engine.selectAudioTrack(id:external)
        try #require(await wait { ready(.center,.medium) && state.playbackDiagnostics?.audio.inputChannelCount == 6 })
        reports["external-return"] = state.playbackDiagnostics?.redactedJSON()
        try checkpoint("dual-session")
        let live = MPVPlayerEngine(videoSurface: .live, audioPreferences: volume, audioOutputPreferences: output, dialoguePreferences: preference)
        let liveState = PlayerState(); live.playerState = liveState
        let liveWindow = NSWindow(contentRect:NSRect(x:0,y:0,width:320,height:180),styleMask:[.borderless],backing:.buffered,defer:false)
        liveWindow.isReleasedWhenClosed=false; liveWindow.alphaValue=0.01; liveWindow.ignoresMouseEvents=true
        let liveView = try #require(MPVOpenGLVideoView(engine:live,surface:.live))
        liveView.frame=liveWindow.contentView!.bounds;liveWindow.contentView=liveView;liveWindow.orderFrontRegardless()
        live.attach(to:liveView,surface:.live)
        defer { live.stop();live.detach(from:liveView);liveWindow.orderOut(nil) }
        await live.play(spec:PlaySpec(url:folder.appendingPathComponent("av08-stereo.mov").absoluteString, metadata:["playback.kind":"live"]))
        try #require(await wait { liveState.playbackDiagnostics?.audio.dialogue?.status == .stereo })
        #expect(liveState.playbackDiagnostics?.mediaID != state.playbackDiagnostics?.mediaID)
        preference.set(.strong)
        try #require(await wait { ready(.center,.strong) && liveState.playbackDiagnostics?.audio.dialogue?.requested == .strong && liveState.playbackDiagnostics?.audio.dialogue?.status == .stereo })
        reports["live-independent-stereo"] = liveState.playbackDiagnostics?.redactedJSON()
        reports["vod-independent-center"] = state.playbackDiagnostics?.redactedJSON()
        try checkpoint("source-filter")
        await engine.play(spec:PlaySpec(url:folder.appendingPathComponent("av08-stereo.mov").absoluteString, mpvOptions:["af":"volume=0.8"]))
        try #require(await wait { ready(.sourceFilters,.strong) })
        #expect(engine.nativePropertyJSON("af")?.contains("netvplayer-dialogue") == false)
        #expect(engine.nativePropertyJSON("af")?.contains("volume") == true)
        reports["source-filter-preserved"] = state.playbackDiagnostics?.redactedJSON()
        preference.reset()
        try #require(await wait { ready(.off,.off) && liveState.playbackDiagnostics?.audio.dialogue?.status == .off })
        #expect(state.volume == 0.37 && state.isMuted && state.speed == 1)
        live.stop();engine.stop()
        try #require(await wait { state.currentSpec == nil && state.playbackDiagnostics == nil })
        try checkpoint("completed")
        try JSONEncoder().encode(reports).write(to:folder.appendingPathComponent("native-dialogue.json"),options:.withoutOverwriting)
    }

    @MainActor private func wait(_ predicate: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by:.seconds(12))
        while !predicate(), ContinuousClock.now < deadline { try? await Task.sleep(for:.milliseconds(30)) }
        return predicate()
    }
}

private final class DialogueGainRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []
    func append(_ value: Double) { lock.lock(); storage.append(value); lock.unlock() }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return storage }
}

private final class DialoguePCMHandle: @unchecked Sendable {
    let context: OpaquePointer
    init(_ context: OpaquePointer) { self.context=context }
}
