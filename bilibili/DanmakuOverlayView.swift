import AppKit
import QuartzCore
import SwiftUI

struct DanmakuOverlayView: NSViewRepresentable, Equatable {
    let items: [BiliDanmakuItem]
    let positionMs: Int64
    let isPlaying: Bool
    let enabled: Bool
    let settings: DanmakuSettings
    var layoutMode: DanmakuLayoutMode = .inline
    var isActive: Bool = true

    nonisolated static func == (lhs: DanmakuOverlayView, rhs: DanmakuOverlayView) -> Bool {
        if lhs.items.count != rhs.items.count { return false }
        if lhs.items.first?.timeMs != rhs.items.first?.timeMs { return false }
        if lhs.items.first?.content != rhs.items.first?.content { return false }
        if lhs.items.last?.timeMs != rhs.items.last?.timeMs { return false }
        if lhs.items.last?.content != rhs.items.last?.content { return false }
        if lhs.isPlaying != rhs.isPlaying { return false }
        if lhs.enabled != rhs.enabled { return false }
        if lhs.isActive != rhs.isActive { return false }
        if lhs.settings != rhs.settings { return false }
        if lhs.layoutMode != rhs.layoutMode { return false }
        if !lhs.isPlaying, lhs.positionMs != rhs.positionMs { return false }
        return true
    }

    func makeNSView(context: Context) -> DanmakuRenderNSView {
        let view = DanmakuRenderNSView()
        view.wantsLayer = true
        view.layerContentsRedrawPolicy = .onSetNeedsDisplay
        view.layer?.backgroundColor = NSColor.clear.cgColor
        return view
    }

    func updateNSView(_ nsView: DanmakuRenderNSView, context: Context) {
        nsView.apply(
            items: items,
            positionMs: positionMs,
            isPlaying: isPlaying,
            enabled: enabled,
            isActive: isActive,
            settings: settings,
            layoutMode: layoutMode
        )
    }

    static func dismantleNSView(_ nsView: DanmakuRenderNSView, coordinator: ()) {
        nsView.stopDisplayLink()
    }
}

final class DanmakuRenderNSView: NSView {
    private let timeline = DanmakuTimeline()
    private var displayLink: CADisplayLink?

    private var items: [BiliDanmakuItem] = []
    private var positionMs: Int64 = 0
    private var isPlaying = false
    private var enabled = false
    private var isActive = true
    private var settings = DanmakuSettings()
    private var layoutMode: DanmakuLayoutMode = .inline
    private var wasPlaying = false

    private var configuredSize = CGSize.zero
    private var configuredLayoutMode: DanmakuLayoutMode = .inline
    private var configuredSettings = DanmakuSettings()
    private var configuredItemsSignature = DanmakuItemsSignature.empty
    private var configuredEnabled = false
    private var configuredActive = true

    private var renderContext: CGContext?
    private var renderContextPixelSize = CGSize.zero

    private static let layerRenderPixelAreaThreshold: CGFloat = 960 * 540 * 4

    override var isOpaque: Bool { false }

    override var wantsUpdateLayer: Bool {
        layoutMode == .inline && renderPixelArea <= Self.layerRenderPixelAreaThreshold
    }

    private var renderPixelArea: CGFloat {
        let scale = window?.backingScaleFactor ?? 2
        return bounds.width * bounds.height * scale * scale
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reconfigureTimelineIfNeeded(force: true)
        syncCurrentFrameAndRender()
        refreshDisplayLink()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        invalidateRenderContext()
        reconfigureTimelineIfNeeded(force: true)
        syncCurrentFrameAndRender()
    }

    func apply(
        items: [BiliDanmakuItem],
        positionMs: Int64,
        isPlaying: Bool,
        enabled: Bool,
        isActive: Bool,
        settings: DanmakuSettings,
        layoutMode: DanmakuLayoutMode
    ) {
        self.items = items
        self.positionMs = positionMs
        self.isPlaying = isPlaying
        self.enabled = enabled
        self.isActive = isActive
        self.settings = settings
        self.layoutMode = layoutMode

        let playStateChanged = isPlaying != wasPlaying
        if playStateChanged {
            timeline.reanchorOnPlayStateChange(
                isPlaying: isPlaying,
                positionMs: positionMs,
                realtimeMs: currentDisplayLinkTimeMs()
            )
            wasPlaying = isPlaying
        }

        let timelineChanged = reconfigureTimelineIfNeeded(force: false)

        if timelineChanged || playStateChanged || !isPlaying || !enabled || !isActive {
            syncCurrentFrameAndRender()
        }

        if timelineChanged || playStateChanged {
            refreshDisplayLink()
        } else {
            refreshDisplayLinkIfNeeded()
        }
    }

    @discardableResult
    private func reconfigureTimelineIfNeeded(force: Bool) -> Bool {
        let size = CGSize(width: max(1, bounds.width), height: max(1, bounds.height))
        let signature = DanmakuItemsSignature(items: items)
        let changed = force
            || size != configuredSize
            || layoutMode != configuredLayoutMode
            || settings != configuredSettings
            || signature != configuredItemsSignature
            || enabled != configuredEnabled
            || isActive != configuredActive

        guard changed else { return false }

        configuredSize = size
        configuredLayoutMode = layoutMode
        configuredSettings = settings
        configuredItemsSignature = signature
        configuredEnabled = enabled
        configuredActive = isActive

        timeline.configure(
            items: items,
            enabled: enabled && isActive,
            settings: settings,
            size: size,
            layoutMode: layoutMode
        )
        return true
    }

    func startDisplayLinkIfNeeded() {
        guard isActive, isPlaying, enabled, !items.isEmpty, window != nil else { return }
        guard displayLink == nil else { return }

        let link = displayLink(target: self, selector: #selector(displayLinkFired(_:)))

        let maxFPS = window?.screen?.maximumFramesPerSecond ?? 60
        let preferredFPS = min(maxFPS, 90)
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: min(60, Float(preferredFPS)),
            maximum: Float(maxFPS),
            preferred: Float(preferredFPS)
        )
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private func refreshDisplayLinkIfNeeded() {
        let shouldRun = isActive && isPlaying && enabled && !items.isEmpty && window != nil
        if shouldRun {
            startDisplayLinkIfNeeded()
        } else {
            stopDisplayLink()
        }
    }

    private func refreshDisplayLink() {
        stopDisplayLink()
        startDisplayLinkIfNeeded()
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        guard isActive, enabled, isPlaying, !items.isEmpty else { return }
        timeline.sync(
            positionMs: positionMs,
            isPlaying: true,
            realtimeMs: displayLinkTimeMs(link)
        )
        markNeedsRender()
    }

    private func syncCurrentFrameAndRender() {
        timeline.sync(
            positionMs: positionMs,
            isPlaying: isPlaying,
            realtimeMs: currentDisplayLinkTimeMs()
        )
        markNeedsRender()
    }

    private func markNeedsRender() {
        if wantsUpdateLayer {
            layer?.setNeedsDisplay()
            displayIfNeeded()
            return
        }
        needsDisplay = true
        layer?.setNeedsDisplay()
        displayIfNeeded()
    }

    override func updateLayer() {
        guard enabled, isActive else {
            layer?.contents = nil
            return
        }

        let frames = timeline.currentDrawFrames()
        guard !frames.isEmpty, bounds.width > 0, bounds.height > 0 else {
            layer?.contents = nil
            return
        }

        layer?.contents = renderFramesToImage(frames)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard enabled, isActive else { return }

        let frames = timeline.currentDrawFrames()
        guard !frames.isEmpty else { return }

        for frame in frames {
            let drawY = bounds.height - frame.y - frame.textHeight
            frame.mainText.draw(at: CGPoint(x: frame.x, y: drawY))
        }
    }

    private func renderFramesToImage(_ frames: [DanmakuDrawFrame]) -> CGImage? {
        let scale = window?.backingScaleFactor ?? 2
        let pixelWidth = Int(bounds.width * scale)
        let pixelHeight = Int(bounds.height * scale)
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }

        let pixelSize = CGSize(width: pixelWidth, height: pixelHeight)
        let context: CGContext
        if pixelSize == renderContextPixelSize, let renderContext {
            context = renderContext
        } else if let created = makeRenderContext(pixelWidth: pixelWidth, pixelHeight: pixelHeight) {
            renderContext = created
            renderContextPixelSize = pixelSize
            context = created
        } else {
            return nil
        }

        context.clear(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))

        NSGraphicsContext.saveGraphicsState()
        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.current = graphicsContext

        for frame in frames {
            let drawY = bounds.height - frame.y - frame.textHeight
            frame.mainText.draw(at: CGPoint(x: frame.x, y: drawY))
        }

        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    private func makeRenderContext(pixelWidth: Int, pixelHeight: Int) -> CGContext? {
        let scale = window?.backingScaleFactor ?? 2
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.scaleBy(x: scale, y: scale)
        return context
    }

    private func invalidateRenderContext() {
        renderContext = nil
        renderContextPixelSize = .zero
    }

    private func currentDisplayLinkTimeMs() -> Int64 {
        if let displayLink {
            return displayLinkTimeMs(displayLink)
        }
        return Int64(CACurrentMediaTime() * 1000)
    }

    private func displayLinkTimeMs(_ link: CADisplayLink) -> Int64 {
        Int64(link.timestamp * 1000)
    }

    deinit {
        MainActor.assumeIsolated {
            stopDisplayLink()
        }
    }
}

private nonisolated struct DanmakuItemsSignature: Equatable {
    let count: Int
    let firstTimeMs: Int64?
    let firstContentHash: Int?
    let lastTimeMs: Int64?
    let lastContentHash: Int?

    static let empty = DanmakuItemsSignature(items: [])

    init(items: [BiliDanmakuItem]) {
        count = items.count
        firstTimeMs = items.first?.timeMs
        firstContentHash = items.first?.content.stableHashValue
        lastTimeMs = items.last?.timeMs
        lastContentHash = items.last?.content.stableHashValue
    }
}
