import Testing
@testable import PlayerEngine

@MainActor
@Test func testUnavailableVideoSurfaceReportsOnlyToItsOwnEngine() {
    let engine = MPVPlayerEngine(videoSurface: .vod)
    engine.reportUnavailableVideoSurface(.live)
    if case .idle = engine.status {} else {
        Issue.record("A different video surface must not fail this engine")
    }
    engine.reportUnavailableVideoSurface(.vod)
    if case .error(let message) = engine.status {
        #expect(!message.isEmpty)
    } else {
        Issue.record("Unavailable video surfaces must produce a recoverable error")
    }
}

@MainActor
@Test func testOpenGLSurfaceIsOrderedBehindSwiftUIOverlaysWhenAvailable() {
    #expect(MPVOpenGLVideoView.requiredOpenGLSurfaceOrder == -1)
    if let view = MPVOpenGLVideoView(engine: .vod, surface: .vod) {
        #expect(view.openGLSurfaceOrder == MPVOpenGLVideoView.requiredOpenGLSurfaceOrder)
    }
}

@MainActor
@Test func testOpenGLSurfaceCanBeReleasedAndRestoredRepeatedlyWhenAvailable() {
    guard let view = MPVOpenGLVideoView(engine: .vod, surface: .vod) else { return }

    for _ in 0..<16 {
        view.deactivatePlaybackSurface()
        view.releaseOpenGLResources()
        #expect(!view.isOpenGLAvailable)

        guard view.activatePlaybackSurface() != nil else {
            Issue.record("An explicitly released OpenGL surface must be restorable")
            return
        }
        #expect(view.isOpenGLAvailable)
        #expect(view.openGLSurfaceOrder == MPVOpenGLVideoView.requiredOpenGLSurfaceOrder)
    }

    view.deactivatePlaybackSurface()
    view.releaseOpenGLResources()
}
