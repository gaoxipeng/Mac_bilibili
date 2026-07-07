import AVKit
import AppKit
import SwiftUI

enum VideoPlayerChrome {
    static let cornerRadius: CGFloat = 14

    static func fittedSize(maxWidth: CGFloat, maxHeight: CGFloat, aspectRatio: CGFloat) -> CGSize {
        let ratio = max(aspectRatio, 0.01)
        if ratio < 1 {
            var height = max(1, maxHeight)
            var width = height * ratio
            if width > maxWidth {
                width = max(1, maxWidth)
                height = width / ratio
            }
            return CGSize(width: width, height: height)
        }

        var width = max(1, maxWidth)
        var height = width / ratio
        if height > maxHeight {
            height = max(1, maxHeight)
            width = height * ratio
        }
        return CGSize(width: width, height: height)
    }

    /// 播放页内嵌播放器：按列宽和视频比例计算尺寸，不预留黑边。
    static func inlinePlayerSize(maxWidth: CGFloat, aspectRatio: CGFloat) -> CGSize {
        let ratio = max(aspectRatio, 0.01)
        let width = max(1, maxWidth)
        return CGSize(width: width, height: width / ratio)
    }

    /// 播放页：竖屏优先占满可用高度，横屏优先占满列宽。
    static func detailPlayerSize(maxWidth: CGFloat, maxHeight: CGFloat, aspectRatio: CGFloat) -> CGSize {
        let ratio = max(aspectRatio, 0.01)
        if ratio < 1 {
            return fittedSize(maxWidth: maxWidth, maxHeight: maxHeight, aspectRatio: aspectRatio)
        }
        return inlinePlayerSize(maxWidth: maxWidth, aspectRatio: aspectRatio)
    }
}

final class PlayerClipContainerView: NSView {
    let playerView = NonSeekingPlayerView()
    var cornerRadius: CGFloat {
        didSet { applyRoundedMask() }
    }

    init(cornerRadius: CGFloat = VideoPlayerChrome.cornerRadius) {
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
        applyRoundedMask()
        addSubview(playerView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        playerView.frame = bounds
        playerView.autoresizingMask = [.width, .height]
        applyRoundedMask()
        PictureInPictureHost.shared.updatePlaybackSurface(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            PictureInPictureHost.shared.unregisterPlaybackSurface(self)
        } else {
            PictureInPictureHost.shared.updatePlaybackSurface(self)
        }
    }

    deinit {
        MainActor.assumeIsolated {
            PictureInPictureHost.shared.unregisterPlaybackSurface(self)
        }
    }

    private func applyRoundedMask() {
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = cornerRadius > 0
    }
}

@MainActor
final class PictureInPictureHost: NSObject {
    static let shared = PictureInPictureHost()

    private let anchorView = PictureInPictureAnchorView()
    private var hostWindow: NSPanel?
    private var pictureInPictureController: AVPictureInPictureController?
    private weak var playbackEngine: VideoPlaybackEngine?
    private weak var hostingWindow: NSWindow?
    private weak var playbackSurface: PlayerClipContainerView?
    private var lastHandledRequestID = 0
    private var pictureInPictureResizeBlocker: PictureInPictureWindowResizeBlocker?

    private static let parkedHostFrame = NSRect(x: -20_000, y: -20_000, width: 2, height: 2)

    private override init() {
        super.init()
    }

    func attach(to window: NSWindow?) {
        guard let window else { return }
        hostingWindow = window
        ensureHostWindow()
        hostWindow?.orderFrontRegardless()
    }

    func detach() {
        hostWindow?.orderOut(nil)
        hostingWindow = nil
        playbackSurface = nil
    }

    func updatePlaybackSurface(_ surface: PlayerClipContainerView) {
        guard isEligiblePlaybackSurface(surface) else { return }

        if let current = playbackSurface, let currentWindow = current.window {
            let currentIsKey = currentWindow === NSApp.keyWindow
            let newIsKey = surface.window === NSApp.keyWindow
            if currentIsKey, !newIsKey { return }
        }

        playbackSurface = surface
    }

    func unregisterPlaybackSurface(_ surface: PlayerClipContainerView) {
        if playbackSurface === surface {
            playbackSurface = nil
        }
    }

    func handleRequest(player: VideoPlaybackEngine, requestID: Int) {
        playbackEngine = player
        guard let avPlayer = player.avPlayer else { return }
        ensureHostWindow()
        anchorView.playerLayer.player = avPlayer

        guard requestID > lastHandledRequestID else { return }
        lastHandledRequestID = requestID
        guard player.isReady,
              AVPictureInPictureController.isPictureInPictureSupported() else { return }

        guard let controller = pictureInPictureController(for: avPlayer) else { return }
        if controller.isPictureInPictureActive {
            alignAnchorWithPlaybackSurface()
            controller.stopPictureInPicture()
        } else {
            blockWindowResizeDuringPictureInPictureStart()
            alignAnchorWithPlaybackSurface()
            controller.startPictureInPicture()
        }
    }

    private func isEligiblePlaybackSurface(_ surface: PlayerClipContainerView) -> Bool {
        guard let window = surface.window, window.isVisible, !surface.isHidden else { return false }
        guard surface.bounds.width > 1, surface.bounds.height > 1 else { return false }

        var candidate: NSView? = surface
        while let view = candidate {
            if view.isHidden || view.alphaValue < 0.01 {
                return false
            }
            candidate = view.superview
        }
        return true
    }

    private func alignAnchorWithPlaybackSurface() {
        guard let surface = playbackSurface,
              let window = surface.window else { return }
        ensureHostWindow()

        let frameInWindow = surface.convert(surface.bounds, to: nil)
        let screenFrame = window.convertToScreen(frameInWindow)
        hostWindow?.level = window.level
        hostWindow?.setFrame(screenFrame, display: true)
        if let contentView = hostWindow?.contentView {
            anchorView.frame = contentView.bounds
            anchorView.needsLayout = true
            anchorView.layoutSubtreeIfNeeded()
        }
        hostWindow?.orderFrontRegardless()
    }

    private func parkHostWindowOffScreen() {
        hostWindow?.setFrame(Self.parkedHostFrame, display: false)
        hostWindow?.level = .normal
    }

    private func ensureHostWindow() {
        guard hostWindow == nil else { return }
        let panel = NSPanel(
            contentRect: Self.parkedHostFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .normal
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]
        anchorView.frame = panel.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 2, height: 2)
        panel.contentView = anchorView
        hostWindow = panel
    }

    private func publishPictureInPictureActive(_ isActive: Bool) {
        Task { @MainActor in
            playbackEngine?.setPictureInPictureActive(isActive)
        }
    }

    private func pictureInPictureController(for player: AVPlayer) -> AVPictureInPictureController? {
        if anchorView.playerLayer.player !== player {
            anchorView.playerLayer.player = player
            pictureInPictureController = nil
        }
        if let pictureInPictureController {
            return pictureInPictureController
        }
        guard let controller = AVPictureInPictureController(playerLayer: anchorView.playerLayer) else {
            return nil
        }
        pictureInPictureController = controller
        controller.delegate = self
        return controller
    }

    private func blockWindowResizeDuringPictureInPictureStart() {
        guard let window = hostingWindow ?? anchorView.window else { return }
        pictureInPictureResizeBlocker = PictureInPictureWindowResizeBlocker(window: window)
        releasePictureInPictureResizeBlocker(after: 3.0)
    }

    private func releasePictureInPictureResizeBlocker(after delay: TimeInterval = 1.0) {
        guard let blocker = pictureInPictureResizeBlocker else { return }
        Task { @MainActor [weak self, weak blocker] in
            let nanoseconds = UInt64(max(0, delay) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard let self, self.pictureInPictureResizeBlocker === blocker else { return }
            self.pictureInPictureResizeBlocker?.invalidate()
            self.pictureInPictureResizeBlocker = nil
        }
    }
}

extension PictureInPictureHost: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        publishPictureInPictureActive(true)
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        parkHostWindowOffScreen()
        releasePictureInPictureResizeBlocker()
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        publishPictureInPictureActive(false)
        parkHostWindowOffScreen()
        releasePictureInPictureResizeBlocker(after: 0)
    }

    func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        alignAnchorWithPlaybackSurface()
        publishPictureInPictureActive(false)
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        publishPictureInPictureActive(false)
        parkHostWindowOffScreen()
        releasePictureInPictureResizeBlocker(after: 0)
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }
}

private final class PictureInPictureAnchorView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct PictureInPictureHostInstaller: NSViewRepresentable {
    @ObservedObject var player: VideoPlaybackEngine

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PictureInPictureHostInstallerView {
        let view = PictureInPictureHostInstallerView()
        view.onWindowChange = { window in
            if let window {
                PictureInPictureHost.shared.attach(to: window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: PictureInPictureHostInstallerView, context: Context) {
        if let window = nsView.window {
            PictureInPictureHost.shared.attach(to: window)
        }

        let requestID = player.pictureInPictureRequestID
        guard requestID > context.coordinator.lastHandledRequestID else { return }
        context.coordinator.lastHandledRequestID = requestID

        let engine = player
        DispatchQueue.main.async {
            PictureInPictureHost.shared.handleRequest(player: engine, requestID: requestID)
        }
    }

    static func dismantleNSView(_ nsView: PictureInPictureHostInstallerView, coordinator: Coordinator) {
        PictureInPictureHost.shared.detach()
    }

    final class Coordinator {
        var lastHandledRequestID = 0
    }
}

final class PictureInPictureHostInstallerView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }
}

final class NonSeekingPlayerView: AVPlayerView {
    override func scrollWheel(with event: NSEvent) {
        // Wheel seeking is handled by VideoScrollWheelMonitor.
    }
}

@MainActor
private final class PictureInPictureWindowResizeBlocker: NSObject, NSWindowDelegate {
    private weak var window: NSWindow?
    private weak var previousDelegate: NSWindowDelegate?
    private let lockedFrame: NSRect
    private let lockedMinSize: NSSize
    private let lockedMaxSize: NSSize
    private var isValid = true

    init(window: NSWindow) {
        self.window = window
        self.previousDelegate = window.delegate
        self.lockedFrame = window.frame
        self.lockedMinSize = window.minSize
        self.lockedMaxSize = window.maxSize
        super.init()

        window.delegate = self
        if !window.styleMask.contains(.fullScreen) {
            window.minSize = lockedFrame.size
            window.maxSize = lockedFrame.size
        }
    }

    func invalidate() {
        guard isValid, let window else { return }
        isValid = false
        window.minSize = lockedMinSize
        window.maxSize = lockedMaxSize
        if window.delegate === self {
            window.delegate = previousDelegate
        }
    }

    deinit {
        MainActor.assumeIsolated {
            invalidate()
        }
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        lockedFrame.size
    }

    func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool {
        false
    }

    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
        lockedFrame
    }
}

struct VideoPlayerSurface: NSViewRepresentable {
    @ObservedObject var player: VideoPlaybackEngine
    var cornerRadius: CGFloat = VideoPlayerChrome.cornerRadius

    func makeNSView(context: Context) -> PlayerClipContainerView {
        let container = PlayerClipContainerView(cornerRadius: cornerRadius)
        container.playerView.controlsStyle = .none
        container.playerView.allowsPictureInPicturePlayback = false
        container.playerView.videoGravity = .resizeAspect
        container.playerView.player = player.avPlayer
        return container
    }

    func updateNSView(_ nsView: PlayerClipContainerView, context: Context) {
        _ = player.isReady
        nsView.cornerRadius = cornerRadius
        nsView.playerView.player = player.avPlayer
    }
}

struct FullscreenPlayerHostView: NSViewRepresentable {
    @ObservedObject var model: VideoDetailModel
    var keyboardHandlers: VideoPlayerKeyboardHandlers

    func makeNSView(context: Context) -> FullscreenPlayerHostNSView {
        let view = FullscreenPlayerHostNSView()
        view.sync(model: model, keyboardHandlers: keyboardHandlers)
        return view
    }

    func updateNSView(_ nsView: FullscreenPlayerHostNSView, context: Context) {
        nsView.sync(model: model, keyboardHandlers: keyboardHandlers)
    }
}

final class FullscreenPlayerHostNSView: NSView {
    private let playerContainer = PlayerClipContainerView(cornerRadius: 0)
    private let danmakuView = DanmakuRenderNSView()
    private let wheelMonitor = VideoScrollWheelMonitorView()
    private let keyboardMonitor = VideoPlayerKeyboardMonitorView()
    private weak var currentModel: VideoDetailModel?

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        playerContainer.playerView.controlsStyle = .none
        playerContainer.playerView.videoGravity = .resizeAspect
        danmakuView.wantsLayer = true
        danmakuView.layerContentsRedrawPolicy = .onSetNeedsDisplay
        danmakuView.layer?.backgroundColor = NSColor.clear.cgColor
        danmakuView.layer?.zPosition = 10
        wheelMonitor.wantsLayer = true
        wheelMonitor.layer?.backgroundColor = NSColor.clear.cgColor
        wheelMonitor.layer?.zPosition = 20
        keyboardMonitor.wantsLayer = true
        keyboardMonitor.layer?.backgroundColor = NSColor.clear.cgColor
        keyboardMonitor.layer?.zPosition = 30

        addSubview(playerContainer)
        addSubview(danmakuView)
        addSubview(wheelMonitor)
        addSubview(keyboardMonitor)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        playerContainer.frame = bounds
        danmakuView.frame = bounds
        wheelMonitor.frame = bounds
        keyboardMonitor.frame = bounds
        playerContainer.autoresizingMask = [.width, .height]
        danmakuView.autoresizingMask = [.width, .height]
        wheelMonitor.autoresizingMask = [.width, .height]
        keyboardMonitor.autoresizingMask = [.width, .height]
        if let currentModel {
            sync(model: currentModel, keyboardHandlers: keyboardMonitor.handlers)
        }
    }

    func sync(model: VideoDetailModel, keyboardHandlers: VideoPlayerKeyboardHandlers) {
        currentModel = model
        let player = model.player
        wheelMonitor.player = player
        keyboardMonitor.handlers = keyboardHandlers
        playerContainer.playerView.player = player.avPlayer

        guard player.isReady else {
            danmakuView.apply(
                items: [],
                positionMs: 0,
                isPlaying: false,
                enabled: false,
                isActive: true,
                settings: model.danmakuSettings,
                layoutMode: .fullscreen
            )
            return
        }

        danmakuView.apply(
            items: [],
            positionMs: 0,
            isPlaying: false,
            enabled: false,
            isActive: true,
            settings: model.danmakuSettings,
            layoutMode: .fullscreen
        )
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            wheelMonitor.installMonitorIfNeeded()
            keyboardMonitor.installMonitorIfNeeded()
            window.makeFirstResponder(self)
            if let currentModel {
                sync(model: currentModel, keyboardHandlers: keyboardMonitor.handlers)
            }
        } else {
            wheelMonitor.tearDownMonitor()
            keyboardMonitor.tearDownMonitor()
        }
    }

    override func keyDown(with event: NSEvent) {
        if keyboardMonitor.handlers.shouldHandle(),
           keyboardMonitor.handleKeyEvent(event) {
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if keyboardMonitor.handlers.shouldHandle(),
           keyboardMonitor.handleKeyEvent(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

struct VideoScrollWheelMonitor: NSViewRepresentable {
    @ObservedObject var player: VideoPlaybackEngine

    func makeNSView(context: Context) -> VideoScrollWheelMonitorView {
        let view = VideoScrollWheelMonitorView()
        view.player = player
        view.autoresizingMask = [.width, .height]
        return view
    }

    func updateNSView(_ nsView: VideoScrollWheelMonitorView, context: Context) {
        nsView.player = player
    }

    static func dismantleNSView(_ nsView: VideoScrollWheelMonitorView, coordinator: ()) {
        nsView.tearDownMonitor()
    }
}

@MainActor
final class VideoScrollWheelMonitorView: NSView {
    weak var player: VideoPlaybackEngine?
    private var scrollMonitor: Any?

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            installMonitorIfNeeded()
        } else {
            tearDownMonitor()
        }
    }

    func installMonitorIfNeeded() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let window, window == event.window else { return event }
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point) else { return event }
            guard let player else { return event }
            Self.handleScroll(event, player: player)
            return nil
        }
    }

    func tearDownMonitor() {
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
            self.scrollMonitor = nil
        }
    }

    static func handleScroll(_ event: NSEvent, player: VideoPlaybackEngine) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY
        guard abs(delta) > 0.01 else { return }

        let phase = event.phase
        let momentumPhase = event.momentumPhase
        if phase == .began || momentumPhase == .began {
            player.cancelScheduledWheelScrubEnd()
        }

        let sensitivity = event.hasPreciseScrollingDeltas ? 0.1 : 1.8
        player.applyWheelScrub(delta: -Double(delta) * sensitivity)

        if phase == .ended || phase == .cancelled || momentumPhase == .ended {
            player.finishWheelScrub()
            return
        }

        let endDelay: Duration = event.hasPreciseScrollingDeltas ? .milliseconds(180) : .milliseconds(120)
        player.scheduleWheelScrubEnd(after: endDelay)
    }

    deinit {
        MainActor.assumeIsolated {
            tearDownMonitor()
        }
    }
}
