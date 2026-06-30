import AppKit
import QuartzCore
import SwiftUI

struct DanmakuOverlayView: NSViewRepresentable {
    let items: [BiliDanmakuItem]
    let positionMs: Int64
    let isPlaying: Bool
    let enabled: Bool
    let settings: DanmakuSettings
    var bottomReserve: CGFloat = 46

    func makeNSView(context: Context) -> DanmakuRenderNSView {
        let view = DanmakuRenderNSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.layerContentsRedrawPolicy = .onSetNeedsDisplay
        return view
    }

    func updateNSView(_ nsView: DanmakuRenderNSView, context: Context) {
        nsView.apply(
            items: items,
            positionMs: positionMs,
            isPlaying: isPlaying,
            enabled: enabled,
            settings: settings,
            bottomReserve: bottomReserve
        )
    }

    static func dismantleNSView(_ nsView: DanmakuRenderNSView, coordinator: ()) {
        nsView.stopDisplayLink()
    }
}

final class DanmakuRenderNSView: NSView {
    private let timeline = DanmakuTimeline()
    private var displayLink: CVDisplayLink?
    private var isDisplayLinkRunning = false

    private var items: [BiliDanmakuItem] = []
    private var positionMs: Int64 = 0
    private var isPlaying = false
    private var enabled = false
    private var settings = DanmakuSettings()
    private var bottomReserve: CGFloat = 46
    private var wasPlaying = false

    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            startDisplayLinkIfNeeded()
        } else {
            stopDisplayLink()
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        timeline.configure(
            items: items,
            enabled: enabled,
            settings: settings,
            size: CGSize(width: max(1, newSize.width), height: max(1, newSize.height)),
            bottomReserve: bottomReserve
        )
    }

    func apply(
        items: [BiliDanmakuItem],
        positionMs: Int64,
        isPlaying: Bool,
        enabled: Bool,
        settings: DanmakuSettings,
        bottomReserve: CGFloat
    ) {
        self.items = items
        self.positionMs = positionMs
        self.isPlaying = isPlaying
        self.enabled = enabled
        self.settings = settings
        self.bottomReserve = bottomReserve

        if isPlaying != wasPlaying {
            timeline.reanchorOnPlayStateChange(isPlaying: isPlaying, positionMs: positionMs)
            wasPlaying = isPlaying
        }

        timeline.configure(
            items: items,
            enabled: enabled,
            settings: settings,
            size: CGSize(width: max(1, bounds.width), height: max(1, bounds.height)),
            bottomReserve: bottomReserve
        )

        if !isPlaying || !enabled {
            timeline.sync(positionMs: positionMs, isPlaying: isPlaying)
            needsDisplay = true
        }

        if window != nil {
            startDisplayLinkIfNeeded()
        }
    }

    func startDisplayLinkIfNeeded() {
        guard isPlaying, enabled, !items.isEmpty else {
            stopDisplayLink()
            return
        }
        guard !isDisplayLinkRunning else { return }
        var link: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess, let link else { return }
        displayLink = link

        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, userInfo in
            guard let userInfo else { return kCVReturnSuccess }
            let view = Unmanaged<DanmakuRenderNSView>.fromOpaque(userInfo).takeUnretainedValue()
            DispatchQueue.main.async {
                view.displayTick()
            }
            return kCVReturnSuccess
        }

        CVDisplayLinkSetOutputCallback(link, callback, Unmanaged.passUnretained(self).toOpaque())
        if CVDisplayLinkStart(link) == kCVReturnSuccess {
            isDisplayLinkRunning = true
        }
    }

    func stopDisplayLink() {
        guard let displayLink, isDisplayLinkRunning else { return }
        CVDisplayLinkStop(displayLink)
        isDisplayLinkRunning = false
        self.displayLink = nil
    }

    private func displayTick() {
        guard enabled, isPlaying, !items.isEmpty else { return }
        timeline.sync(positionMs: positionMs, isPlaying: true)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard enabled else { return }
        let frames = timeline.currentDrawFrames()
        guard !frames.isEmpty else { return }

        for frame in frames {
            let drawY = bounds.height - frame.y - frame.textHeight
            frame.mainText.draw(at: CGPoint(x: frame.x, y: drawY))
        }
    }

    deinit {
        stopDisplayLink()
    }
}
