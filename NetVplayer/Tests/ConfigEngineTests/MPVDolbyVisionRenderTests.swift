import AppKit
import Foundation
import MPVShim
import Models
import Testing
@testable import PlayerEngine

@Suite struct MPVDolbyVisionRenderTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_AV_DOVI_FIXTURES"] != nil))
    @MainActor func baseLayerReferenceAndSceneMetadataCausalComparison() async throws {
        let folder=URL(fileURLWithPath:try #require(ProcessInfo.processInfo.environment["NETVPLAYER_AV_DOVI_FIXTURES"]))
        let output=folder.appendingPathComponent("native-render-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:false)
        let reference=try #require(JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent("reference.json"))) as? [String:Any])
        let patches=try #require(reference["patches"] as? [[String:Any]])
        _=NSApplication.shared
        let rect=NSRect(x:20,y:60,width:640,height:360)
        let window=NSWindow(contentRect:rect,styleMask:[.borderless],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.alphaValue=0.01
        let view=NVMPVOpenGLView(frame:rect);try #require(view.isOpenGLAvailable)
        window.contentView=view;window.orderFrontRegardless()
        defer {window.orderOut(nil);view.releaseOpenGLSurface()}
        view.makeOpenGLContextCurrent()
        let gl=try ColorReadbackGL(), fbo=gl.makeFramebuffer(width:640,height:360)
        defer {gl.destroyFramebuffer(fbo)}
        let context=try #require(nv_mpv_create())
        defer {view.makeOpenGLContextCurrent();nv_mpv_destroy(context)}
        // The fixed reference is the HDR10 base layer. Disable Dolby mapping
        // explicitly while measuring it, regardless of the runtime capability.
        let base=["config":"no","vo":"libmpv","hwdec":"no","aid":"no","sid":"no","terminal":"no","idle":"yes","keep-open":"yes","dither-depth":"no","vf":"format=dolbyvision=no"]
        let options=PlaybackColorPolicy.options(source:[:],preference:.init()).mapValues(\.value).merging(base){_,v in v}
        for (key,value) in options {try #require(nv_mpv_set_option_string(context,key,value)>=0)}
        try #require(nv_mpv_initialize(context)>=0)
        try #require(nv_mpv_create_render_context(context,nil,nil)>=0)
        var images:[String:[UInt8]]=[:], results:[[String:Any]]=[]
        let referenceSpace=try #require(NSColorSpace(cgColorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!))
        for name in ["p81-no-rpu.mp4","p81-a.mp4","p81-b.mp4"] {
              var pending = NVMPVEvent()
              while nv_mpv_wait_event(context, 0, &pending) >= 0 && pending.event_id != 0 {}
            _=nv_mpv_set_property_flag(context,"pause",0)
            try #require(nv_mpv_command3(context,"loadfile",folder.appendingPathComponent(name).path,"replace")>=0)
              let end=ContinuousClock.now.advanced(by:.seconds(10));var ready=false, loaded=false
            while !ready && ContinuousClock.now<end {
                view.makeOpenGLContextCurrent()
                _=nv_mpv_render(context,Int32(fbo.framebuffer),640,360,0)
                var event=NVMPVEvent()
                  while nv_mpv_wait_event(context,0,&event)>=0 && event.event_id != 0 { if event.event_id == 8 { loaded = true } }
                  if let ptr=nv_mpv_copy_property_string(context,"time-pos") {ready=loaded && (Double(String(cString:ptr)) ?? 0)>0.2;nv_mpv_free_string(ptr)}
                if !ready {try await Task.sleep(for:.milliseconds(20))}
            }
            try #require(ready);_=nv_mpv_set_property_flag(context,"pause",1)
            for (label,space,tolerance) in [("sRGB",NSColorSpace.sRGB,4.0),("P3-simulated",.displayP3,6.0),("display",window.screen?.colorSpace ?? .sRGB,6.0),("sRGB-restored",.sRGB,4.0)] {
                view.makeOpenGLContextCurrent()
                let icc=try #require(space.iccProfileData)
                try #require(icc.withUnsafeBytes {nv_mpv_set_render_icc(context,$0.baseAddress,$0.count)}>=0)
                for _ in 0..<3 {
                    _=nv_mpv_render(context,Int32(fbo.framebuffer),640,360,0)
                    try await Task.sleep(for:.milliseconds(20));view.makeOpenGLContextCurrent()
                }
                let pixels=gl.read(framebuffer:fbo.framebuffer,width:640,height:360)
                var errors:[Double]=[],observed:[[Double]]=[]
                for patch in patches {
                    let x=try #require(patch["x"] as? Int),y=try #require(patch["y"] as? Int)
                    let linear=try #require(patch["linearSRGB"] as? [Double])
                    let components=(linear+[1]).map { CGFloat($0) }
                    let color=try #require(NSColor(colorSpace:referenceSpace,components:components,count:4).usingColorSpace(space))
                    let target=[color.redComponent,color.greenComponent,color.blueComponent].map{min(1,max(0,$0))*255}
                    var avg=[Double](repeating:0,count:3)
                    for dy in -2...2 {for dx in -2...2 {for c in 0..<3 {avg[c]+=Double(pixels[((y+dy)*640+x+dx)*4+c])/25}}}
                    observed.append(avg)
                    for c in 0..<3 {errors.append(abs(avg[c]-target[c]))}
                }
                let maxError=errors.max() ?? .infinity
                results.append(["sample":name,"profile":label,"maximumErrorLSB":maxError,"toleranceLSB":tolerance,"patchRGB":observed])
                #expect(maxError<=tolerance,"\(name) / \(label): \(maxError)")
                if label=="sRGB" {images[name]=pixels;try Data(pixels).write(to:output.appendingPathComponent(name+".rgba"))}
            }
        }
        var comparisons:[[String:Any]]=[]
        for (a,b) in [("p81-a.mp4","p81-no-rpu.mp4"),("p81-a.mp4","p81-b.mp4")] {
            let first=try #require(images[a]),second=try #require(images[b])
            let maximum=zip(first,second).map{abs(Int($0)-Int($1))}.max() ?? 999
            comparisons.append(["first":a,"second":b,"maximumDifferenceLSB":maximum])
            #expect(maximum<=1)
        }
        try #require(nv_mpv_set_property_string(context, "vf", "") >= 0)
        var dynamicComparison: [String: Any] = ["supported": false]
        if nv_mpv_runtime_capabilities(context) & 3 == 3 {
            // Identical base-layer pixels with different L1 scene metadata must
            // now produce different mapped pixels. Replaying A after B must
            // reproduce A, proving the active metadata is not stale/cumulative.
            var reconstructed: [[UInt8]] = []
            for name in ["p81-a.mp4", "p81-b.mp4", "p81-a.mp4"] {
                  var pending = NVMPVEvent()
                  while nv_mpv_wait_event(context, 0, &pending) >= 0 && pending.event_id != 0 {}
                let generation = nv_mpv_dolby_renderer_status(context).generation
                _ = nv_mpv_set_property_flag(context, "pause", 0)
                try #require(nv_mpv_command3(context, "loadfile", folder.appendingPathComponent(name).path, "replace") >= 0)
                let deadline = ContinuousClock.now.advanced(by: .seconds(10))
                  var ready = false, loaded = false
                repeat {
                    view.makeOpenGLContextCurrent()
                    try #require(nv_mpv_render(context, Int32(fbo.framebuffer), 640, 360, 0) >= 0)
                      var event = NVMPVEvent()
                      while nv_mpv_wait_event(context, 0, &event) >= 0 && event.event_id != 0 {
                          if event.event_id == 8 { loaded = true }
                      }
                    let status = nv_mpv_dolby_renderer_status(context)
                      ready = loaded && status.generation > generation && status.frame_flags & 1 != 0 && status.pts > 0.2
                    if !ready { try await Task.sleep(for: .milliseconds(20)) }
                } while !ready && ContinuousClock.now < deadline
                try #require(ready)
                _ = nv_mpv_set_property_flag(context, "pause", 1)
                  // Compare the same presentation timestamp; loadfile can
                  // return while the previous file is still being torn down.
                  let seekGeneration = nv_mpv_dolby_renderer_status(context).generation
                  try #require(nv_mpv_command3(context, "seek", "1", "absolute+exact") >= 0)
                  let seekDeadline = ContinuousClock.now.advanced(by: .seconds(10))
                  ready = false
                  repeat {
                      view.makeOpenGLContextCurrent()
                      try #require(nv_mpv_render(context, Int32(fbo.framebuffer), 640, 360, 0) >= 0)
                      var event = NVMPVEvent()
                      while nv_mpv_wait_event(context, 0, &event) >= 0 && event.event_id != 0 {}
                      let status = nv_mpv_dolby_renderer_status(context)
                      ready = status.generation > seekGeneration && status.frame_flags & 1 != 0 && status.pts >= 1 && status.pts < 1.1
                      if !ready { try await Task.sleep(for: .milliseconds(20)) }
                  } while !ready && ContinuousClock.now < seekDeadline
                  try #require(ready)
                view.makeOpenGLContextCurrent()
                  let pixels = gl.read(framebuffer: fbo.framebuffer, width: 640, height: 360)
                  try Data(pixels).write(to: output.appendingPathComponent("reconstructed-\(reconstructed.count).rgba"))
                  reconstructed.append(pixels)
            }
            let delta = zip(reconstructed[0], reconstructed[1]).map { abs(Int($0)-Int($1)) }.max() ?? 0
            let replay = zip(reconstructed[0], reconstructed[2]).map { abs(Int($0)-Int($1)) }.max() ?? 999
            #expect(delta > 1 && replay <= 1)
            dynamicComparison = ["supported": true, "maximumMetadataDeltaLSB": delta, "maximumReplayDeltaLSB": replay]
              let decoder = PlayerChapterThumbnailDecoder()
              var previewErrors: [Double] = []
              for (index, name) in ["p81-a.mp4", "p81-b.mp4"].enumerated() {
                  let data = try #require(await decoder.imageData(
                      spec: PlaySpec(url: folder.appendingPathComponent(name).absoluteString), seconds: 1))
                  try data.write(to: output.appendingPathComponent("preview-\(index).png"))
                  let preview = try #require(NSBitmapImageRep(data: data))
                  #expect(preview.pixelsWide == 320 && preview.pixelsHigh == 180)
                  try #require(preview.bitsPerSample == 8 && preview.samplesPerPixel == 4 &&
                      !preview.bitmapFormat.contains(.alphaFirst))
                  let bytes = try #require(preview.bitmapData)
                  for patch in patches {
                      let x = try #require(patch["x"] as? Int), y = try #require(patch["y"] as? Int)
                      // Compare encoded sRGB bytes directly. colorAt's device
                      // color conversion can apply the current display profile.
                      for channel in 0..<3 {
                          let value = bytes[(y / 2) * preview.bytesPerRow + (x / 2) * 4 + channel]
                          previewErrors.append(abs(Double(value) - Double(reconstructed[index][(y * 640 + x) * 4 + channel])))
                      }
                  }
              }
              let previewError = previewErrors.max() ?? .infinity
              #expect(previewError <= 6, "Chapter previews must match the reconstructed playback image: \(previewError)")
              dynamicComparison["maximumChapterPreviewDifferenceLSB"] = previewError
        }
        // The very same render API can consume a decoded P5 frame without
        // exposing it. Check all RGB values in the cleared framebuffer.
        _=nv_mpv_set_property_flag(context,"pause",0)
        _=nv_mpv_command3(context,"loadfile",folder.appendingPathComponent("p5.mp4").path,"replace")
        for _ in 0..<15 {
            view.makeOpenGLContextCurrent()
            try #require(nv_mpv_render_suppressed(context,Int32(fbo.framebuffer))>=0)
            let pixels=gl.read(framebuffer:fbo.framebuffer,width:640,height:360)
            #expect(pixels.enumerated().allSatisfy{$0.offset%4==3 || $0.element==0})
            #expect(nv_mpv_render_target_format(context)==0)
            try await Task.sleep(for:.milliseconds(30))
        }
        let report:[String:Any]=["reference":results,"baseLayerComparisons":comparisons,"reconstructionComparison":dynamicComparison,"suppressedP5Frames":15,"physicalHDRVerified":false,"dolbyVisionSignalVerified":false]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("report.json"))
    }
}
