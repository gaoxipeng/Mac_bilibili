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
    var playbackEngine: VideoPlaybackEngine?

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
        view.layer?.backgroundColor = NSColor.clear.cgColor
        // Scrolling text starts just outside the right edge and ends outside
        // the left edge. Keep those animation layers clipped to the video
        // viewport instead of allowing them to leak across the whole window.
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ nsView: DanmakuRenderNSView, context: Context) {
        nsView.playbackEngine = playbackEngine
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
    private var screenChangeObserver: NSObjectProtocol?
    private var textLayers: [Int: DanmakuTextLayerState] = [:]
    private var lastResolvedPositionMillis: Double?

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

    weak var playbackEngine: VideoPlaybackEngine?

    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateScreenChangeObservation()
        reconfigureTimelineIfNeeded(force: true)
        syncCurrentFrameAndRender()
        refreshDisplayLink()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDisplayLinkFrameRate()
        updateTextLayerContentsScale()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let size = normalizedRenderSize()
        guard danmakuSizeChanged(size, configuredSize) else { return }
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
        let currentPositionMillis = resolvedPositionMillis()
        if playStateChanged {
            timeline.reanchorOnPlayStateChange(
                isPlaying: isPlaying,
                positionMillis: currentPositionMillis,
                realtimeMillis: currentDisplayLinkMillis()
            )
            wasPlaying = isPlaying
        }

        let timelineChanged = reconfigureTimelineIfNeeded(force: false)

        if timelineChanged || playStateChanged || !isPlaying || !enabled || !isActive {
            syncCurrentFrameAndRender(positionMillis: currentPositionMillis)
        }

        if timelineChanged || playStateChanged {
            refreshDisplayLink()
        } else {
            refreshDisplayLinkIfNeeded()
        }
        updateLayerTreePlayback()
    }

    @discardableResult
    private func reconfigureTimelineIfNeeded(force: Bool) -> Bool {
        let size = normalizedRenderSize()
        let signature = DanmakuItemsSignature(items: items)
        let changed = force
            || danmakuSizeChanged(size, configuredSize)
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
        if changed {
            removeStaleTextLayers(keeping: [])
        }
        return true
    }

    func startDisplayLinkIfNeeded() {
        guard isActive, isPlaying, enabled, !items.isEmpty, window != nil else { return }
        guard displayLink == nil else { return }

        let link = displayLink(target: self, selector: #selector(displayLinkFired(_:)))
        updateDisplayLinkFrameRate(link)
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

    private func updateDisplayLinkFrameRate(_ link: CADisplayLink? = nil) {
        let targetLink = link ?? displayLink
        guard let targetLink else { return }

        // Follow the active display instead of capping the danmaku clock at
        // 60 Hz. ProMotion displays therefore request 120 Hz, while ordinary
        // displays keep their native 60/75 Hz cadence.
        let refreshRate = Float(max(window?.screen?.maximumFramesPerSecond ?? 60, 60))
        targetLink.preferredFrameRateRange = CAFrameRateRange(
            minimum: min(60, refreshRate),
            maximum: refreshRate,
            preferred: refreshRate
        )
    }

    private func updateScreenChangeObservation() {
        if let screenChangeObserver {
            NotificationCenter.default.removeObserver(screenChangeObserver)
            self.screenChangeObserver = nil
        }
        guard let window else { return }
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateDisplayLinkFrameRate()
            }
        }
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        guard isActive, enabled, isPlaying, !items.isEmpty else { return }
        let positionMillis = resolvedPositionMillis()
        resetRenderedLayersIfPositionJumped(positionMillis)
        timeline.sync(
            positionMillis: positionMillis,
            isPlaying: true,
            realtimeMillis: displayLinkTimeMillis(link)
        )
        renderCurrentFrame()
    }

    private func syncCurrentFrameAndRender(positionMillis: Double? = nil) {
        let positionMillis = positionMillis ?? resolvedPositionMillis()
        resetRenderedLayersIfPositionJumped(positionMillis)
        timeline.sync(
            positionMillis: positionMillis,
            isPlaying: isPlaying,
            realtimeMillis: currentDisplayLinkMillis()
        )
        renderCurrentFrame()
    }

    private func resolvedPositionMillis() -> Double {
        if let playbackEngine,
           playbackEngine.isPlaying,
           !playbackEngine.isScrubbing {
            return playbackEngine.preciseCurrentTime * 1000
        }

        if let playbackEngine, playbackEngine.isScrubbing {
            let seconds = playbackEngine.scrubPreviewTime ?? playbackEngine.preciseCurrentTime
            return seconds * 1000
        }

        return Double(positionMs)
    }

    private func renderCurrentFrame() {
        guard enabled, isActive, bounds.width > 1, bounds.height > 1 else {
            removeStaleTextLayers(keeping: [])
            return
        }

        let frames = timeline.currentDrawFrames()
        guard !frames.isEmpty else {
            removeStaleTextLayers(keeping: [])
            return
        }

        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        var visibleIDs = Set<Int>()
        visibleIDs.reserveCapacity(frames.count)
        var newFrames: [DanmakuDrawFrame] = []

        for frame in frames {
            visibleIDs.insert(frame.id)
            if textLayers[frame.id] == nil {
                newFrames.append(frame)
            }
        }

        let staleIDs = textLayers.keys.filter { !visibleIDs.contains($0) }
        guard !newFrames.isEmpty || !staleIDs.isEmpty else { return }

        // Existing scrolling layers move entirely on Core Animation's
        // compositor. Re-submitting every visible CATextLayer at 120 Hz made
        // the much denser fullscreen layout compete with video presentation on
        // the main thread. Only mutate the layer tree when comments enter/exit.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for frame in newFrames {
            renderNewLayer(frame: frame, contentsScale: scale)
        }
        for id in staleIDs {
            textLayers[id]?.layer.removeFromSuperlayer()
            textLayers.removeValue(forKey: id)
        }
        CATransaction.commit()
    }

    private func renderNewLayer(frame: DanmakuDrawFrame, contentsScale: CGFloat) {
        let created = CATextLayer()
        created.string = frame.mainText
        created.contentsScale = contentsScale
        created.isWrapped = false
        created.truncationMode = .none
        created.alignmentMode = .left
        created.rasterizationScale = contentsScale
        created.shouldRasterize = true
        created.actions = [
            "position": NSNull(),
            "bounds": NSNull(),
            "frame": NSNull(),
            "contents": NSNull(),
            "opacity": NSNull()
        ]
        created.frame = layerFrame(for: frame)
        layer?.addSublayer(created)
        if frame.isScrolling {
            _ = addScrollAnimation(to: created, frame: frame)
        }
        textLayers[frame.id] = DanmakuTextLayerState(layer: created)
    }

    private func layerFrame(for frame: DanmakuDrawFrame) -> CGRect {
        CGRect(
            x: frame.x,
            y: bounds.height - frame.y - frame.textHeight,
            width: frame.textWidth + 4,
            height: frame.textHeight + 3
        )
    }

    private func addScrollAnimation(to textLayer: CATextLayer, frame: DanmakuDrawFrame) -> Bool {
        let remainingMillis = frame.durationMillis - frame.elapsedMillis
        guard remainingMillis > 16 else { return false }

        let startX = frame.x + (frame.textWidth + 4) / 2
        let endX = frame.endX + (frame.textWidth + 4) / 2
        let currentY = textLayer.position.y
        textLayer.position = CGPoint(x: endX, y: currentY)

        let animation = CABasicAnimation(keyPath: "position.x")
        animation.fromValue = startX
        animation.toValue = endX
        animation.duration = remainingMillis / 1000
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.isRemovedOnCompletion = false
        animation.fillMode = .forwards
        textLayer.add(animation, forKey: "danmaku-scroll-x")
        return true
    }

    private func removeStaleTextLayers(keeping visibleIDs: Set<Int>) {
        guard !textLayers.isEmpty else { return }
        let staleIDs = textLayers.keys.filter { !visibleIDs.contains($0) }
        guard !staleIDs.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for id in staleIDs {
            textLayers[id]?.layer.removeFromSuperlayer()
            textLayers.removeValue(forKey: id)
        }
        CATransaction.commit()
    }

    private func updateTextLayerContentsScale() {
        guard !textLayers.isEmpty else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for state in textLayers.values {
            state.layer.contentsScale = scale
            state.layer.rasterizationScale = scale
        }
        CATransaction.commit()
    }

    private func resetRenderedLayersIfPositionJumped(_ positionMillis: Double) {
        defer { lastResolvedPositionMillis = positionMillis }
        guard let lastResolvedPositionMillis else { return }
        let delta = positionMillis - lastResolvedPositionMillis
        if delta > 1_500 || delta < -500 {
            removeStaleTextLayers(keeping: [])
        }
    }

    private func updateLayerTreePlayback() {
        guard let layer else { return }
        let shouldPlay = isActive && enabled && isPlaying
        if shouldPlay {
            guard layer.speed == 0 else { return }
            let pausedTime = layer.timeOffset
            layer.speed = 1
            layer.timeOffset = 0
            layer.beginTime = 0
            let elapsedSincePause = layer.convertTime(CACurrentMediaTime(), from: nil) - pausedTime
            layer.beginTime = elapsedSincePause
        } else {
            guard layer.speed != 0 else { return }
            let pausedTime = layer.convertTime(CACurrentMediaTime(), from: nil)
            layer.speed = 0
            layer.timeOffset = pausedTime
        }
    }

    private func currentDisplayLinkMillis() -> Double {
        if let displayLink {
            return displayLinkTimeMillis(displayLink)
        }
        return CACurrentMediaTime() * 1000
    }

    private func displayLinkTimeMillis(_ link: CADisplayLink) -> Double {
        link.timestamp * 1000
    }

    private func normalizedRenderSize() -> CGSize {
        CGSize(width: max(1, bounds.width), height: max(1, bounds.height))
    }

    deinit {
        MainActor.assumeIsolated {
            if let screenChangeObserver {
                NotificationCenter.default.removeObserver(screenChangeObserver)
            }
            stopDisplayLink()
            removeStaleTextLayers(keeping: [])
        }
    }
}

private struct DanmakuTextLayerState {
    let layer: CATextLayer
}

private nonisolated func danmakuSizeChanged(_ lhs: CGSize, _ rhs: CGSize) -> Bool {
    abs(lhs.width - rhs.width) > 0.5 || abs(lhs.height - rhs.height) > 0.5
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
