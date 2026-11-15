import AppKit
import Foundation
import Models
import MPVShim
import Storage
import Testing
@testable import PlayerEngine

@Suite struct PlaybackDolbyVisionTests {
    private func video(_ profile: Int? = nil, matrix: String = "dolbyvision") -> PlaybackDiagnostics.Video {
        var track: [String: Any] = ["codec":"hevc", "ff-index":0]
        track["dolby-vision-profile"] = profile
        return PlaybackDiagnostics(mediaID: UUID(), properties: [
            "current-tracks/video": try! JSONSerialization.data(withJSONObject: track),
            "video-dec-params": try! JSONSerialization.data(withJSONObject: ["colormatrix":matrix,"gamma":"pq","pixelformat":"p010"])
        ]).video
    }
    private func local(_ profile: Int? = 8, compatibility: Int? = 1) -> LocalDolbyVisionObservation {
        .init(profile:profile,level:1,compatibilityID:compatibility,rpuFlag:true,enhancementLayer:false,baseLayer:true,
              frameRPU:true,frameMetadata:true,rpuHeaderProfile:1,rpuInferredProfile:profile,streamIndex:0,status:"first-frame-inspected")
    }
    @Test func compatibilityAndMetadataAreIndependentFacts() throws {
        var source = local()
        source.frameRPU = false; source.frameMetadata = false
        let result = try #require(PlaybackDolbyVision.assess(video:video(8,matrix:"bt.2020-ncl"),local:source,trackIndex:0))
        #expect(result.route == .hdr10BaseLayer)
        #expect(result.configurationRPUFlag == true)
        #expect(result.decodedRPUDetected == false && result.decodedMetadataDetected == false)
        #expect(!result.dynamicMappingApplied && !result.dolbyVisionSignalSent)
        #expect(try JSONDecoder().decode(PlaybackDolbyVision.self,from:JSONEncoder().encode(result)) == result)
    }
    @Test func absentWrongTrackOrConflictingConfigurationCannotApproveBaseLayer() {
        for source in [nil, local(8,compatibility:nil), local(7), local(5)] {
            #expect(PlaybackDolbyVision.assess(video:video(8),local:source,trackIndex:0)?.route.blocksVideo == true)
        }
        #expect(PlaybackDolbyVision.assess(video:video(8),local:local(),trackIndex:1)?.route.blocksVideo == true)
        var mixed=local();mixed.rpuInferredProfile=5
        #expect(PlaybackDolbyVision.assess(video:video(8),local:mixed,trackIndex:0)?.evidenceConflict == true)
        #expect(PlaybackDolbyVision.assess(video:video(8),local:mixed,trackIndex:0)?.route.blocksVideo == true)
        mixed=local();mixed.enhancementLayer=true
        #expect(PlaybackDolbyVision.assess(video:video(8),local:mixed,trackIndex:0)?.route.blocksVideo == true)
    }
    @Test func profile5OrRPUOnlyNeverReachesOrdinaryYUVRenderer() {
        #expect(PlaybackDolbyVision.assess(video:video(5),local:nil,trackIndex:0)?.route == .blockedProfile5)
        var source=local(nil,compatibility:nil);source.rpuInferredProfile=5;source.rpuHeaderProfile=0
        #expect(PlaybackDolbyVision.assess(video:video(),local:source,trackIndex:0)?.route == .blockedProfile5)
        #expect(PlaybackDolbyVision.assess(video:video(),local:nil,trackIndex:0)?.route == .blockedUnverified)
        #expect(PlaybackDolbyVision.assess(video:video(nil,matrix:"bt.2020-ncl"),local:nil,trackIndex:0) == nil)
    }
    @Test func HDRPreferenceAndEDRHeadroomNeverOverrideBlock() throws {
        var input=video(5)
        input.dolbyVision=PlaybackDolbyVision.assess(video:input,local:nil,trackIndex:0)
        for mode in PlaybackVideoOutputMode.allCases {
            let result=PlaybackVideoOutputPolicy.assess(mode:mode,video:input,display:.init(currentEDRHeadroom:4,potentialEDRHeadroom:8))
            #expect(result.disposition == .dolbyVisionBlocked)
            #expect(!PlaybackVideoOutputPolicy.allowsHDRPresentation(mode: mode, video: input))
        }
    }
    @Test func nativeRendererRequiresCurrentSuccessfulFrameAndPreservesFailure() throws {
        var renderer = DolbyRendererObservation(capabilities: 15, generation: 1, frames: 0,
            doviFrames: 0, enhancementFrames: 0, felFrames: 0, failures: 0, frameFlags: 0, pts: 0)
        let pending = try #require(PlaybackDolbyVision.assess(video: video(7), local: nil,
            trackIndex: 0, renderer: renderer))
        #expect(pending.route == .preparingReconstruction && !pending.dynamicMappingApplied)

        renderer.frames = 1; renderer.doviFrames = 1; renderer.enhancementFrames = 1
        renderer.felFrames = 1; renderer.frameFlags = 7
        var source = video(7)
        source.dolbyVision = PlaybackDolbyVision.assess(video: source, local: nil, trackIndex: 0, renderer: renderer)
        #expect(source.dolbyVision?.route == .reconstructedFEL)
        #expect(source.dolbyVision?.dynamicMappingApplied == true)
        #expect(source.dolbyVision?.dolbyVisionSignalSent == false)
        #expect(PlaybackVideoOutputPolicy.allowsHDRPresentation(mode: .hdrIfAvailable, video: source))
        #expect(PlaybackVideoOutputPolicy.allowsHDRPresentation(mode: .automatic, video: source))

        renderer.frameFlags = 8; renderer.failures = 1
        let failed = try #require(PlaybackDolbyVision.assess(video: video(7), local: nil,
            trackIndex: 0, renderer: renderer))
        #expect(failed.route == .blockedRendererFailure && !failed.dynamicMappingApplied)
        // A previous frame's counters must not approve a new, unmapped frame.
        renderer.frameFlags = 0
        #expect(PlaybackDolbyVision.assess(video: video(5), local: nil, trackIndex: 0,
            renderer: renderer)?.route.blocksVideo == true)
    }

    @Test func nativeSingleLayerReconstructionDoesNotClaimFELOrOverrideConflictingEvidence() {
        let renderer = DolbyRendererObservation(capabilities: 15, generation: 3, frames: 5,
            doviFrames: 5, enhancementFrames: 0, felFrames: 0, failures: 0, frameFlags: 1, pts: 0.16)
        for profile in [5, 8] {
            let result = PlaybackDolbyVision.assess(video: video(profile), local: nil, trackIndex: 0, renderer: renderer)
            #expect(result?.route == .reconstructed && result?.dynamicMappingApplied == true)
        }
        let conflict = PlaybackDolbyVision.assess(video: video(7), local: local(5), trackIndex: 0, renderer: renderer)
        #expect(conflict?.route.blocksVideo == true && conflict?.dynamicMappingApplied == false)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_AV_DOVI_FIXTURES"] != nil))
    func actualBundledDecoderDistinguishesConfigurationFromRPU() throws {
        let folder=URL(fileURLWithPath:try #require(ProcessInfo.processInfo.environment["NETVPLAYER_AV_DOVI_FIXTURES"]))
        let library=try #require(ProcessInfo.processInfo.environment["NETVPLAYER_LIBMPV_PATH"])
        for (name,profile,compatibility,rpu) in [("p81-a.mp4",8,1,true),("p81-a.mkv",8,1,true),
                                               ("p5.mp4",5,0,true),("p81-no-rpu.mp4",8,1,false),("p5-no-rpu.mp4",5,0,false)] {
            let result=LocalDolbyVisionObservation.read(library:library,file:folder.appendingPathComponent(name))
            #expect(result.status == "first-frame-inspected", "\(name): \(result)")
            #expect(result.profile == profile && result.compatibilityID == compatibility)
            #expect(result.rpuFlag == true && result.frameRPU == rpu && result.frameMetadata == rpu)
        }
        let raw=LocalDolbyVisionObservation.read(library:library,file:folder.appendingPathComponent("p5.hevc"))
        #expect(raw.profile == nil && raw.compatibilityID == nil)
        #expect(raw.rpuInferredProfile == 5 && raw.frameMetadata)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_AV_DOVI_FIXTURES"] != nil))
    @MainActor func actualEngineHonorsRuntimeCapabilityAndRecoversAcrossMediaAndIndependentLiveSurface() async throws {
        let folder=URL(fileURLWithPath:try #require(ProcessInfo.processInfo.environment["NETVPLAYER_AV_DOVI_FIXTURES"]))
        let probe = try #require(nv_mpv_create())
        let reconstructsDolby = nv_mpv_runtime_capabilities(probe) & 3 == 3
        nv_mpv_destroy(probe)
        let suite="NetVplayer.AV06.test."+UUID().uuidString
        let defaults=UserDefaults(suiteName:suite)!;defer { defaults.removePersistentDomain(forName:suite) }
        let preferences=PlaybackColorPreferenceStore(defaults:defaults)
        let engine=MPVPlayerEngine(videoSurface:.vod,colorPreferences:preferences), state=PlayerState()
        engine.playerState=state
        let window=NSWindow(contentRect:NSRect(x:40,y:80,width:640,height:360),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false
        let view=try #require(MPVOpenGLVideoView(engine:engine,surface:.vod));view.frame=window.contentView!.bounds
        window.contentView=view;window.orderFrontRegardless();engine.attach(to:view,surface:.vod)
        defer {engine.stop();view.deactivatePlaybackSurface();window.orderOut(nil)}
        var snapshots:[[String:Any]]=[]
        for name in ["p5.mp4","p81-a.mp4","p5.hevc","p81-no-rpu.mp4","p5-no-rpu.mp4","p81-a.mkv"] {
            preferences.set(.init(videoOutput: .sdr))
            let previous=state.playbackDiagnostics?.mediaID
            await engine.play(spec:PlaySpec(url:folder.appendingPathComponent(name).absoluteString,
                subs:[Sub(name:"AV06 explicit sidecar",url:folder.appendingPathComponent("p81-a.srt").absoluteString,format:"srt")]))
            let blocked = reconstructsDolby ? name.contains("no-rpu") : name.hasPrefix("p5")
            try await wait {
                guard let info=state.playbackDiagnostics, info.mediaID != previous,
                      let dv=info.video.dolbyVision,
                      reconstructsDolby ? dv.renderer != nil : dv.localProbeStatus != nil else { return false }
                return blocked ? state.videoCompatibilityMessage != nil && !state.isPlaying : info.display.targetFormat == "GL_RGBA8" && state.position > 0.1
            }
            try await wait {engine.nativePropertyJSON("track-list")?.contains("AV06 explicit sidecar") == true}
            #expect(state.subtitleStatus?.contains("加载失败") != true)
            let info=try #require(state.playbackDiagnostics)
            #expect(info.video.dolbyVision?.route.blocksVideo == blocked)
            if blocked {
                #expect(info.display.targetFormat == nil)
                engine.resume();try await Task.sleep(for:.milliseconds(100));#expect(!state.isPlaying)
                view.makeOpenGLContextCurrent();view.displayOpenGL()
                #expect(state.videoCompatibilityMessage != nil)
            } else {
                engine.pause();let position=state.position, owner=info.mediaID
                NotificationCenter.default.post(name:NSWindow.didChangeScreenProfileNotification,object:window)
                preferences.set(.init(videoOutput:.hdrIfAvailable))
                try await Task.sleep(for:.milliseconds(120))
                #expect(state.playbackDiagnostics?.mediaID == owner && abs(state.position-position)<0.2)
                if reconstructsDolby, (window.screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1) > 1.01 {
                    try await wait { state.playbackDiagnostics?.display.edrEnabled == true }
                    #expect(state.playbackDiagnostics?.video.dolbyVision?.dynamicMappingApplied == true)
                } else {
                    #expect(state.playbackDiagnostics?.display.edrEnabled == false)
                }
                #expect(state.videoCompatibilityMessage == nil)
            }
            var record=try #require(JSONSerialization.jsonObject(with:Data(info.redactedJSON().utf8)) as? [String:Any])
            record["sample"]=name;snapshots.append(record)
        }

        preferences.set(.init(videoOutput: .sdr))
        let live=MPVPlayerEngine(videoSurface:.live,colorPreferences:preferences), liveState=PlayerState()
        live.playerState=liveState
        let liveWindow=NSWindow(contentRect:NSRect(x:720,y:80,width:640,height:360),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        liveWindow.isReleasedWhenClosed=false
        let liveView=try #require(MPVOpenGLVideoView(engine:live,surface:.live));liveView.frame=liveWindow.contentView!.bounds
        liveWindow.contentView=liveView;liveWindow.orderFrontRegardless();live.attach(to:liveView,surface:.live)
        defer {live.stop();liveView.deactivatePlaybackSurface();liveWindow.orderOut(nil)}
        await live.play(spec:PlaySpec(url:folder.appendingPathComponent("p81-a.mp4").absoluteString,metadata:["playback.kind":"live"]))
        try await wait {liveState.playbackDiagnostics?.display.targetFormat == "GL_RGBA8" && liveState.position>0.1}
        let liveOwner=liveState.playbackDiagnostics?.mediaID
        await engine.play(spec:PlaySpec(url:folder.appendingPathComponent("p5-no-rpu.mp4").absoluteString))
        try await wait {state.videoCompatibilityMessage != nil}
        #expect(liveState.playbackDiagnostics?.mediaID == liveOwner && liveState.videoCompatibilityMessage == nil && liveState.isPlaying)
        // Replace again while the first session's asynchronous work can still be queued.
        await engine.play(spec:PlaySpec(url:folder.appendingPathComponent("p5.hevc").absoluteString))
        await engine.play(spec:PlaySpec(url:folder.appendingPathComponent("p81-a.mp4").absoluteString))
        try await wait {state.playbackDiagnostics?.video.dolbyVision?.route == (reconstructsDolby ? .reconstructed : .hdr10BaseLayer) && state.playbackDiagnostics?.display.targetFormat == "GL_RGBA8"}
        #expect(state.videoCompatibilityMessage == nil)
        engine.stop()
        try await wait {state.playbackDiagnostics == nil && state.videoCompatibilityMessage == nil}
        try JSONSerialization.data(withJSONObject:snapshots,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("native-engine-"+UUID().uuidString+".json"))
    }
    @MainActor private func wait(_ predicate:()->Bool) async throws {
        let end=ContinuousClock.now.advanced(by:.seconds(12))
        while !predicate() && ContinuousClock.now<end {try await Task.sleep(for:.milliseconds(30))}
        try #require(predicate())
    }
}
