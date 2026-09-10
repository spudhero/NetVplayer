import Testing
@testable import PlayerEngine

@MainActor
@Test func testOpenGLSurfaceIsOrderedBehindSwiftUIOverlaysWhenAvailable() {
    #expect(MPVOpenGLVideoView.requiredOpenGLSurfaceOrder == -1)
    if let view = MPVOpenGLVideoView(engine: .vod, surface: .vod) {
        #expect(view.openGLSurfaceOrder == MPVOpenGLVideoView.requiredOpenGLSurfaceOrder)
    }
}
