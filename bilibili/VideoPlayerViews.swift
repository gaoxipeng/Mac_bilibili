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
    }

    private func applyRoundedMask() {
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = cornerRadius > 0
    }
}

final class NonSeekingPlayerView: AVPlayerView {
    override func scrollWheel(with event: NSEvent) {
        // Wheel seeking is handled by VideoScrollWheelMonitor.
    }
}

struct VideoPlayerSurface: NSViewRepresentable {
    @ObservedObject var player: VideoPlaybackEngine
    var cornerRadius: CGFloat = VideoPlayerChrome.cornerRadius

    func makeNSView(context: Context) -> PlayerClipContainerView {
        let container = PlayerClipContainerView(cornerRadius: cornerRadius)
        container.playerView.controlsStyle = .none
        container.playerView.videoGravity = .resizeAspectFill
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

    func makeNSView(context: Context) -> FullscreenPlayerHostNSView {
        let view = FullscreenPlayerHostNSView()
        view.sync(model: model)
        return view
    }

    func updateNSView(_ nsView: FullscreenPlayerHostNSView, context: Context) {
        nsView.sync(model: model)
    }
}

final class FullscreenPlayerHostNSView: NSView {
    private let playerContainer = PlayerClipContainerView(cornerRadius: 0)
    private let danmakuView = DanmakuRenderNSView()
    private let wheelMonitor = VideoScrollWheelMonitorView()
    private weak var currentModel: VideoDetailModel?

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

        addSubview(playerContainer)
        addSubview(danmakuView)
        addSubview(wheelMonitor)
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
        playerContainer.autoresizingMask = [.width, .height]
        danmakuView.autoresizingMask = [.width, .height]
        wheelMonitor.autoresizingMask = [.width, .height]
        if let currentModel {
            sync(model: currentModel)
        }
    }

    func sync(model: VideoDetailModel) {
        currentModel = model
        let player = model.player
        wheelMonitor.player = player
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
        if window != nil {
            wheelMonitor.installMonitorIfNeeded()
            if let currentModel {
                sync(model: currentModel)
            }
        } else {
            wheelMonitor.tearDownMonitor()
        }
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
