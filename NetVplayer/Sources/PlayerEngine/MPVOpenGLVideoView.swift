import AppKit
import MPVShim

/// Tokens are mutated by the owning main-actor view; deinit only removes them
/// after ownership has ended, including Swift's nonisolated destruction path.
private final class MPVScreenObservers: @unchecked Sendable {
    var tokens: [NSObjectProtocol] = []
    var workspaceTokens: [NSObjectProtocol] = []
    func removeDisplayObservers() {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        tokens.removeAll()
    }
    func removeAll() {
        removeDisplayObservers()
        for token in workspaceTokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        workspaceTokens.removeAll()
    }
    deinit { removeAll() }
}

@MainActor
public final class MPVOpenGLVideoView: NSView {
    public static var requiredOpenGLSurfaceOrder: Int {
        NVMPVOpenGLView.requiredOpenGLSurfaceOrder()
    }

    /// Invalidates the presentation owner before media replacement or render retirement.
    public enum PresentationInvalidation { case mediaReplacement, retirement, detach }
    public var presentationInvalidated: ((PresentationInvalidation) -> Void)?

    private let engine: MPVPlayerEngine
    private let surface: MPVVideoSurface
    private let openGLView: NVMPVOpenGLView
    private var attachmentLease = MPVVideoSurfaceAttachmentLease()
    private let screenObservers = MPVScreenObservers()
    private weak var taggedWindow: NSWindow?
    private var previousWindowColorSpace: NSColorSpace?
    private(set) var displayICCData: Data?
    private(set) var displayICCSource: PlaybackICCSubmission = .sRGBFallback
    private(set) var displayColorSpace: NSColorSpace = .sRGB
    private(set) var diagnosticScreen: NSScreen?
    private(set) var diagnosticDisplayID: UInt32?
    private(set) var diagnosticDisplayName: String?
    private(set) var diagnosticRefreshRate: Double?
    private var systemIsAsleep = false
    private var screensAreAsleep = false
    private var presentationTransferDepth = 0
    var displayIsAsleep: Bool { systemIsAsleep || screensAreAsleep }
    // The fixed-target AV-03 harness is independent of the opt-in product route.
    private(set) var hdrPrototypeSurface: NVMPVHDRSurface?
    private(set) var dolbyVisionSurface: NVDolbyVisionSurface?
    private(set) var isHDRDevelopmentProbe = false

    func enableHDRPrototype() -> Bool {
        enableHDRSurface(development: true)
    }

    func enableHDRPresentation() -> Bool {
        enableHDRSurface(development: false)
    }

    private func enableHDRSurface(development: Bool) -> Bool {
        if dolbyVisionSurface != nil { disableHDRPrototype() }
        guard hdrPrototypeSurface == nil else { return true }
        guard let surface = NVMPVHDRSurface(hdrFrame: bounds) else { return false }
        surface.asynchronousPresentation = !development
        surface.autoresizingMask = [.width, .height]
        addSubview(surface)
        hdrPrototypeSurface = surface
        isHDRDevelopmentProbe = development
        // HUD/danmaku remain ordinary sRGB; the Metal child owns its linear tag.
        restoreWindowColorSpace()
        return true
    }

    func disableHDRPrototype() {
        makeOpenGLContextCurrent()
        dolbyVisionSurface?.releaseSurface()
        dolbyVisionSurface?.removeFromSuperview()
        dolbyVisionSurface = nil
        hdrPrototypeSurface?.releaseSurface()
        hdrPrototypeSurface?.removeFromSuperview()
        hdrPrototypeSurface = nil
        isHDRDevelopmentProbe = false
    }

    func enableSystemDolbyVisionPresentation() -> Bool {
        guard dolbyVisionSurface == nil else { return true }
        guard NVDolbyVisionSurface.available else { return false }
        disableHDRPrototype()
        guard let surface = NVDolbyVisionSurface.make(frame: bounds) else { return false }
        surface.autoresizingMask = [.width, .height]
        addSubview(surface)
        dolbyVisionSurface = surface
        restoreWindowColorSpace()
        return true
    }

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

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        screenObservers.removeDisplayObservers()
        restoreWindowColorSpace()
        guard let window else {
            if presentationTransferDepth == 0 { cacheDiagnosticScreen(nil) }
            if presentationTransferDepth == 0 { engine.refreshVideoOutputAssessment() }
            return
        }
        for name in [NSWindow.didChangeScreenNotification, NSWindow.didChangeScreenProfileNotification,
                     NSWindow.didChangeBackingPropertiesNotification,
                     NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            screenObservers.tokens.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshDisplayColorProfile(resetHDRActivation: true) }
            })
        }
        screenObservers.tokens.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDisplayColorProfile(resetHDRActivation: true) }
        })
        observeWorkspaceDisplayStateIfNeeded()
        if presentationTransferDepth == 0 { refreshDisplayColorProfile(resetHDRActivation: true) }
    }

    /// Ignore the transient nil window during an atomic same-view migration.
    /// The destination still gets a fresh ICC/headroom assessment before rendering.
    public func beginPresentationTransfer() { presentationTransferDepth += 1 }

    public func endPresentationTransfer() {
        precondition(presentationTransferDepth > 0)
        presentationTransferDepth -= 1
        guard presentationTransferDepth == 0 else { return }
        if window != nil { refreshDisplayColorProfile(resetHDRActivation: true) }
        else { engine.refreshVideoOutputAssessment() }
        requestOpenGLDisplay()
    }

    private func observeWorkspaceDisplayStateIfNeeded() {
        // Keep workspace observers for the view's lifetime: a cached view may
        // leave its window while asleep and must still receive the wake event.
        guard screenObservers.workspaceTokens.isEmpty else { return }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            screenObservers.workspaceTokens.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch name {
                    case NSWorkspace.willSleepNotification: self.systemIsAsleep = true
                    case NSWorkspace.didWakeNotification: self.systemIsAsleep = false
                    case NSWorkspace.screensDidSleepNotification: self.screensAreAsleep = true
                    case NSWorkspace.screensDidWakeNotification: self.screensAreAsleep = false
                    default: break
                    }
                    if self.displayIsAsleep { self.engine.refreshVideoOutputAssessment() }
                    else { self.refreshDisplayColorProfile(resetHDRActivation: true) }
                }
            })
        }
    }

    func refreshDisplayColorProfile(resetHDRActivation: Bool = false) {
        cacheDiagnosticScreen(window?.screen)
        let screenSpace = diagnosticScreen?.colorSpace
        let screenData = screenSpace?.iccProfileData
        if let screenSpace, screenSpace.colorSpaceModel == .rgb, let screenData,
           PlaybackColorPolicy.validICC(screenData) {
            displayColorSpace = screenSpace
            displayICCData = screenData
            displayICCSource = .display
        } else {
            displayColorSpace = .sRGB
            displayICCData = NSColorSpace.sRGB.iccProfileData.flatMap { PlaybackColorPolicy.validICC($0) ? $0 : nil }
            displayICCSource = .sRGBFallback
        }
        if resetHDRActivation { engine.displayConfigurationDidChange(for: self) }
        engine.updateDisplayColorProfile(for: self)
    }

    private func cacheDiagnosticScreen(_ screen: NSScreen?) {
        diagnosticScreen = screen
        diagnosticDisplayID = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        diagnosticDisplayName = screen.map { String($0.localizedName.prefix(128)) }
        diagnosticRefreshRate = diagnosticDisplayID.flatMap { CGDisplayCopyDisplayMode($0)?.refreshRate }
    }

    func tagSurfaceColorSpace(_ space: NSColorSpace) {
        guard let window else { return }
        if taggedWindow !== window {
            restoreWindowColorSpace()
            taggedWindow = window
            previousWindowColorSpace = window.colorSpace
        }
        // The GL pixels have already been transformed into this display space.
        // Matching the window tag prevents a second sRGB-to-display conversion.
        if window.colorSpace != space { window.colorSpace = space }
    }

    private func restoreWindowColorSpace() {
        taggedWindow?.colorSpace = previousWindowColorSpace
        taggedWindow = nil
        previousWindowColorSpace = nil
    }

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

    public var isOpenGLAvailable: Bool {
        openGLView.isOpenGLAvailable
    }

    public var isPlaybackSurfaceActive: Bool {
        attachmentLease.isActive
    }

    public func activatePlaybackSurface() -> UInt64? {
        guard openGLView.restoreOpenGLSurface() else { return nil }
        return attachmentLease.activate()
    }

    public func deactivatePlaybackSurface() {
        attachmentLease.deactivate()
        restoreWindowColorSpace()
        engine.refreshVideoOutputAssessment()
    }

    public func acceptsPlaybackSurfaceAttachment(generation: UInt64) -> Bool {
        attachmentLease.accepts(generation: generation)
    }

    public func detachFromPlayerEngineAndReleaseOpenGLResources() async {
        await engine.detachAndReleaseOpenGLResources(from: self)
    }

    public func releaseOpenGLResources() {
        disableHDRPrototype()
        openGLView.releaseOpenGLSurface()
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
        guard let generation = activatePlaybackSurface() else {
            engine.reportUnavailableVideoSurface(surface)
            return
        }
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
