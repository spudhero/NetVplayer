import AppKit
import MPVShim

@MainActor
public final class MPVOpenGLVideoView: NSView {
    public static var requiredOpenGLSurfaceOrder: Int {
        NVMPVOpenGLView.requiredOpenGLSurfaceOrder()
    }

    private let engine: MPVPlayerEngine
    private let surface: MPVVideoSurface
    private let openGLView: NVMPVOpenGLView
    private var attachmentLease = MPVVideoSurfaceAttachmentLease()

    public init?(engine: MPVPlayerEngine, surface: MPVVideoSurface) {
        let openGLView = NVMPVOpenGLView(frame: .zero)
        guard openGLView.isOpenGLAvailable else { return nil }
        self.engine = engine
        self.surface = surface
        self.openGLView = openGLView
        super.init(frame: .zero)

        openGLView.frame = bounds
        openGLView.autoresizingMask = [.width, .height]
        addSubview(openGLView)
        openGLView.prepareHandler = { [weak self] in
            self?.openGLDidPrepare()
        }
        openGLView.drawHandler = { [weak self] in
            self?.drawOpenGL()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override var acceptsFirstResponder: Bool { true }

    public override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        engine.setRenderSuspended(true, for: self)
    }

    public override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        engine.setRenderSuspended(false, for: self)
        requestOpenGLDisplay()
    }

    var openGLSurfaceOrder: Int {
        openGLView.openGLSurfaceOrder
    }

    public func activatePlaybackSurface() -> UInt64 {
        attachmentLease.activate()
    }

    public func deactivatePlaybackSurface() {
        attachmentLease.deactivate()
    }

    public func acceptsPlaybackSurfaceAttachment(generation: UInt64) -> Bool {
        attachmentLease.accepts(generation: generation)
    }

    public func detachFromPlayerEngine() {
        engine.detach(from: self)
    }

    func makeOpenGLContextCurrent() {
        openGLView.makeOpenGLContextCurrent()
    }

    func updateOpenGLContext() {
        openGLView.updateOpenGLContext()
    }

    func flushOpenGLBuffer() {
        openGLView.flushOpenGLBuffer()
    }

    func requestOpenGLDisplay() {
        openGLView.requestOpenGLDisplay()
    }

    func displayOpenGL() {
        openGLView.displayOpenGL()
    }

    private func openGLDidPrepare() {
        let generation = activatePlaybackSurface()
        Task { @MainActor [weak self] in
            guard let self,
                  acceptsPlaybackSurfaceAttachment(generation: generation) else {
                return
            }
            engine.attach(to: self, surface: surface)
        }
    }

    private func drawOpenGL() {
        engine.render(in: self)
    }
}
