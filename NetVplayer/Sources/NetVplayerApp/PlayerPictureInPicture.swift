import AppKit
import SwiftUI
import Models
import PlayerEngine
import NativePIP

@MainActor
protocol PictureInPictureDriver: AnyObject {
    var eventHandler: ((String) -> Void)? { get set }
    func present(_ content: NSViewController, window: NSWindow, rect: NSRect, aspect: NSSize, playing: Bool) -> Bool
    func dismiss() -> Bool
    func setPlaying(_ playing: Bool)
    func invalidate()
}

extension NVPictureInPicture: PictureInPictureDriver {}

/// Owns one stable render view. SwiftUI owns only replaceable inline containers.
@MainActor
final class PlayerPictureInPicture: ObservableObject {
    enum Phase: String { case inline, waitingForFullScreen, entering, active, exiting }
    static let vod = PlayerPictureInPicture(engine: .vod, surface: .vod)
    static let live = PlayerPictureInPicture(engine: .live, surface: .live)
    private static weak var owner: PlayerPictureInPicture?

    let engine: MPVPlayerEngine
    let surface: MPVVideoSurface
    @Published private(set) var phase: Phase = .inline
    @Published private(set) var failure: String?
    private(set) var generation: UInt64 = 0
    private(set) var videoView: MPVOpenGLVideoView?
    private weak var host: NSView?
    private weak var sourceWindow: NSWindow?
    private var content: NSViewController?
    private var driver: (any PictureInPictureDriver)?
    private var timer: Timer?
    private var deadline: TimeInterval = 0
    private var lastPlaying: Bool?
    private var returning = false
    private var openSourceWindow: (() -> Void)?
    private let available: () -> Bool
    private let makeDriver: () -> any PictureInPictureDriver
    private let now: () -> TimeInterval
    private let transitionTimeout: TimeInterval

    var isPresented: Bool { phase != .inline }
    var isAvailable: Bool { available() }
    var canEnter: Bool { isAvailable && engine.playerState?.currentSpec != nil && videoView?.window != nil }

    init(engine: MPVPlayerEngine, surface: MPVVideoSurface,
         available: @escaping () -> Bool = { NVPictureInPicture.available },
         makeDriver: @escaping () -> any PictureInPictureDriver = { NVPictureInPicture() },
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         transitionTimeout: TimeInterval = 8) {
        self.engine = engine; self.surface = surface
        self.available = available; self.makeDriver = makeDriver
        self.now = now; self.transitionTimeout = transitionTimeout
    }

    func mount(in host: NSView, openWindow: @escaping () -> Void) {
        let alreadyMounted = self.host === host && videoView?.superview === host && videoView?.isPlaybackSurfaceActive == true
        self.host = host
        openSourceWindow = openWindow
        if videoView == nil {
            videoView = MPVOpenGLVideoView(engine: engine, surface: surface)
            videoView?.presentationInvalidated = { [weak self] reason in
                self?.invalidate(returnToWindow: reason == .mediaReplacement)
            }
        }
        guard let videoView else { engine.reportUnavailableVideoSurface(surface); return }
        guard !isPresented, !alreadyMounted else { return }
        moveVideo(to: host)
        guard let lease = videoView.activatePlaybackSurface() else {
            engine.reportUnavailableVideoSurface(surface); return
        }
        Task { @MainActor [weak self, weak host] in
            guard let self, let host, self.host === host, !self.isPresented,
                  videoView.acceptsPlaybackSurfaceAttachment(generation: lease) else { return }
            self.engine.attach(to: videoView, surface: self.surface)
        }
    }

    func unmount(_ host: NSView) {
        guard self.host === host else { return }
        self.host = nil
        guard !isPresented, let videoView else { return }
        videoView.deactivatePlaybackSurface()
        Task { @MainActor [weak self] in
            guard let self, self.host == nil, !self.isPresented, !videoView.isPlaybackSurfaceActive else { return }
            await videoView.detachFromPlayerEngineAndReleaseOpenGLResources()
        }
    }

    func enter() {
        guard phase == .inline else { return }
        failure = nil
        guard Self.owner == nil || Self.owner === self else {
            failure = L10n.text("已有画中画窗口，请先返回播放器。"); return
        }
        guard canEnter, let window = videoView?.window else {
            failure = L10n.text("当前无法开启画中画，请继续使用播放器。"); return
        }
        generation &+= 1; Self.owner = self; sourceWindow = window; returning = false
        let fullScreen = PlayerFullScreenCoordinator.attached(to: window)
        if window.styleMask.contains(.fullScreen) || fullScreen.state.transition != nil {
            phase = .waitingForFullScreen
            NotificationCenter.default.addObserver(self, selector: #selector(fullScreenExited(_:)),
                name: NSWindow.didExitFullScreenNotification, object: window)
            fullScreen.request(false)
        } else {
            beginNativePresentation()
        }
        if isPresented { armTimer() }
    }

    @objc private func fullScreenExited(_ notification: Notification) {
        guard phase == .waitingForFullScreen, notification.object as? NSWindow === sourceWindow,
              sourceWindow?.styleMask.contains(.fullScreen) == false else { return }
        NotificationCenter.default.removeObserver(self)
        beginNativePresentation()
        if isPresented { armTimer() }
    }

    private func beginNativePresentation() {
        guard let sourceWindow, sourceWindow.isVisible, let videoView, let host,
              !sourceWindow.styleMask.contains(.fullScreen) else { fail(); return }
        phase = .entering
        let ticket = generation
        let native = makeDriver()
        let controller = NSViewController()
        controller.view = PictureInPictureContentView(frame: videoView.bounds)
        controller.view.autoresizingMask = [.width, .height]
        content = controller; driver = native
        native.eventHandler = { [weak self] event in self?.receive(event, generation: ticket) }
        let rect = host.convert(host.bounds, to: nil)
        let size = videoView.bounds.size
        videoView.beginPresentationTransfer()
        defer { videoView.endPresentationTransfer() }
        moveVideo(to: controller.view)
        guard native.present(controller, window: sourceWindow, rect: rect,
                             aspect: size.width > 0 && size.height > 0 ? size : NSSize(width: 16, height: 9),
                             playing: engine.playerState?.isPlaying == true) else { fail(); return }
        deadline = now() + transitionTimeout
    }

    func exit(returnToWindow: Bool) {
        // Native stop and should-close can arrive in the same dismissal. The
        // first intent owns it; a later callback cannot turn Close into Return.
        guard isPresented, phase != .exiting else { return }
        returning = returnToWindow
        if !returnToWindow { engine.pause() }
        if returnToWindow { showSourceWindow() }
        if phase == .waitingForFullScreen || phase == .entering {
            // A cancelled presentation cannot reuse its native delegate or content controller.
            finish(); return
        }
        phase = .exiting; deadline = now() + transitionTimeout
        guard driver?.dismiss() == true else { fail(); return }
    }

    func receive(_ event: String, generation ticket: UInt64) {
        guard ticket == generation, isPresented else { return }
        switch event {
        case "play": if phase == .active { engine.resume() }
        case "pause": if phase == .active { engine.pause() }
        case "stop": exit(returnToWindow: false)
        case "return": exit(returnToWindow: true)
        case "closed": finish()
        default: break
        }
    }

    /// The engine calls this before replacement and before retiring the render context.
    func invalidate(returnToWindow: Bool = false) {
        guard isPresented else { return }
        returning = returnToWindow
        finish()
    }

    private func showSourceWindow() {
        if let sourceWindow, sourceWindow.isVisible || sourceWindow.isMiniaturized {
            if sourceWindow.isMiniaturized { sourceWindow.deminiaturize(nil) }
            sourceWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else { openSourceWindow?() }
    }

    private func moveVideo(to parent: NSView) {
        guard let videoView else { return }
        if videoView.superview !== parent {
            videoView.removeFromSuperview()
            videoView.frame = parent.bounds
            videoView.autoresizingMask = [.width, .height]
            parent.addSubview(videoView)
        }
        videoView.frame = parent.bounds
    }

    private func finish() {
        generation &+= 1
        timer?.invalidate(); timer = nil
        NotificationCenter.default.removeObserver(self)
        // Remove the render view before disposing a native controller that may finish late.
        videoView?.beginPresentationTransfer()
        videoView?.removeFromSuperview()
        if let host { moveVideo(to: host) }
        videoView?.endPresentationTransfer()
        let retired = driver
        driver = nil; content = nil; lastPlaying = nil
        retired?.invalidate()
        phase = .inline
        if Self.owner === self { Self.owner = nil }
        if returning { showSourceWindow() }
        returning = false
        sourceWindow = nil
    }

    private func fail() {
        failure = L10n.text("画中画未能完成，已返回播放器。")
        returning = true
        finish()
    }

    private func armTimer() {
        timer?.invalidate()
        deadline = now() + transitionTimeout
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            MainActor.assumeIsolated { self.reconcile() }
        }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }

    func reconcile() {
        guard isPresented else { return }
        if phase == .entering, let window = videoView?.window, window !== sourceWindow,
           window.isVisible, (videoView?.bounds.width ?? 0) > 0 {
            phase = .active
        }
        if phase != .active, now() >= deadline { fail(); return }
        if phase == .waitingForFullScreen, sourceWindow?.isVisible != true { fail(); return }
        let playing = engine.playerState?.isPlaying == true
        if playing != lastPlaying { driver?.setPlaying(playing); lastPlaying = playing }
    }
}

/// PIP.framework initially inserts the content into a differently sized host.
/// A plain NSViewController does not resize its root view at that attachment.
@MainActor private final class PictureInPictureContentView: NSView {
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let superview { frame = superview.bounds }
    }
}

struct PictureInPicturePlaceholder: View {
    @ObservedObject var presentation: PlayerPictureInPicture
    var compact = false
    var body: some View {
        if presentation.isPresented {
            VStack(spacing: compact ? 10 : 16) {
                if !compact {
                    Image(systemName: "pip.fill")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(PlayerHUDPalette.lavender)
                }
                Text(L10n.text("正在画中画中播放"))
                    .font(.system(size: compact ? 14 : 18, weight: .semibold))
                if !compact {
                    Text(presentation.surface == .vod
                         ? L10n.text("当前影片已移到悬浮窗口。可最小化此窗口，或在下方调整播放。")
                         : L10n.text("当前频道已移到悬浮窗口，可最小化此窗口继续观看。"))
                        .font(.system(size: 13))
                        .foregroundStyle(PlayerHUDPalette.muted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    presentation.exit(returnToWindow: true)
                } label: {
                    Label(L10n.text("返回播放器"), systemImage: "pip.exit")
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(PlayerHUDPalette.lavender)
                .accessibilityIdentifier("player.picture-in-picture.return")
                .help(L10n.text("将当前影片移回播放器"))
            }
            .foregroundStyle(PlayerHUDPalette.foreground)
            .padding(compact ? 12 : 24)
            .frame(maxWidth: compact ? 300 : 380)
        }
    }
}
