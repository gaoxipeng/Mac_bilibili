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
    var timeline: DanmakuTimeline
    var playbackEngine: VideoPlaybackEngine?
    var faceMaskAnalyzer: DanmakuFaceMaskAnalyzer?

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
        view.useTimeline(timeline)
        view.faceMaskAnalyzer = faceMaskAnalyzer
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
        nsView.useTimeline(timeline)
        nsView.faceMaskAnalyzer = faceMaskAnalyzer
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
    private var timeline = DanmakuTimeline()
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
    private var hasAppliedConfiguration = false

    private var configuredSize = CGSize.zero
    private var configuredLayoutMode: DanmakuLayoutMode = .inline
    private var configuredSettings = DanmakuSettings()
    private var configuredItemsSignature = DanmakuItemsSignature.empty
    private var configuredEnabled = false
    private var configuredActive = true
    private var appliedFaceMaskGeneration: UInt64 = .max
    private var scrollingContainer: CALayer?
    private var fixedContainer: CALayer?
    private let faceMaskLayer = CAShapeLayer()

    weak var playbackEngine: VideoPlaybackEngine?
    var faceMaskAnalyzer: DanmakuFaceMaskAnalyzer? {
        didSet {
            appliedFaceMaskGeneration = .max
            applyFaceMaskIfNeeded(force: true)
        }
    }

    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        ensureDanmakuContainers()
        updateScreenChangeObservation()
        if hasAppliedConfiguration, isActive {
            reconfigureTimelineIfNeeded(force: true)
            syncCurrentFrameAndRender()
        }
        applyFaceMaskIfNeeded(force: true)
        refreshDisplayLink()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDisplayLinkFrameRate()
        updateTextLayerContentsScale()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard hasAppliedConfiguration, isActive else { return }
        let size = normalizedRenderSize()
        guard danmakuSizeChanged(size, configuredSize) else { return }
        reconfigureTimelineIfNeeded(force: true)
        syncCurrentFrameAndRender()
        applyFaceMaskIfNeeded(force: true)
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
        let wasActive = self.isActive
        hasAppliedConfiguration = true
        self.items = items
        self.positionMs = positionMs
        self.isPlaying = isPlaying
        self.enabled = enabled
        self.isActive = isActive
        self.settings = settings
        self.layoutMode = layoutMode

        // The inline and fullscreen hosts share one timeline. The inactive
        // host must not reconfigure or advance it while the other host owns
        // the visible danmaku layers.
        guard isActive else {
            removeStaleTextLayers(keeping: [])
            stopDisplayLink()
            updateLayerTreePlayback()
            return
        }

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

        let timelineChanged = reconfigureTimelineIfNeeded(force: isActive && !wasActive)

        if timelineChanged, isPlaying, enabled, isActive {
            // A part switch can pause the existing layer tree and publish the
            // stop/start states in one SwiftUI transaction. Start the new
            // timeline from a clean Core Animation clock instead of waiting
            // for a later mouse event to wake the paused tree.
            resetLayerTreeClockForNewTimeline()
        }

        if timelineChanged || playStateChanged || !isPlaying || !enabled || !isActive {
            syncCurrentFrameAndRender(positionMillis: currentPositionMillis)
        }

        if timelineChanged || playStateChanged {
            refreshDisplayLink()
        } else {
            refreshDisplayLinkIfNeeded()
        }
        updateLayerTreePlayback()

        if timelineChanged, isPlaying, enabled, isActive {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                self.refreshDisplayLink()
                self.syncCurrentFrameAndRender()
                self.commitNewTimelineToWindow()
            }
        }
    }

    func useTimeline(_ timeline: DanmakuTimeline) {
        guard self.timeline !== timeline else { return }
        self.timeline = timeline
        hasAppliedConfiguration = false
        configuredSize = .zero
        configuredLayoutMode = .inline
        configuredSettings = DanmakuSettings()
        configuredItemsSignature = .empty
        configuredEnabled = false
        configuredActive = true
        removeStaleTextLayers(keeping: [])
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

        // AppKit binds this display link to the screen containing the view.
        // The callback runs on the main run loop at the display's native
        // cadence, so ProMotion and high-refresh external displays are not
        // reduced to a fixed 60/120 Hz timer.
        let link = displayLink(
            target: self,
            selector: #selector(displayLinkDidFire(_:))
        )
        displayLink = link
        link.add(to: .main, forMode: .common)
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

    private func updateDisplayLinkFrameRate() {
        guard displayLink != nil else { return }
        refreshDisplayLink()
    }

    @objc private func displayLinkDidFire(_ link: CADisplayLink) {
        // Use the display's scheduled frame time rather than callback arrival
        // time, which fluctuates with main-thread work.
        displayLinkFired(realtimeMillis: link.timestamp * 1000)
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

    private func displayLinkFired(realtimeMillis: Double) {
        guard isActive, enabled, isPlaying, !items.isEmpty else { return }
        let positionMillis = resolvedPositionMillis()
        resetRenderedLayersIfPositionJumped(positionMillis)
        timeline.sync(
            positionMillis: positionMillis,
            isPlaying: true,
            playbackSpeed: playbackEngine?.playbackRate ?? 1,
            realtimeMillis: realtimeMillis
        )
        applyFaceMaskIfNeeded()
        renderCurrentFrame()
    }

    private func syncCurrentFrameAndRender(positionMillis: Double? = nil) {
        let positionMillis = positionMillis ?? resolvedPositionMillis()
        resetRenderedLayersIfPositionJumped(positionMillis)
        timeline.sync(
            positionMillis: positionMillis,
            isPlaying: isPlaying,
            playbackSpeed: playbackEngine?.playbackRate ?? 1,
            realtimeMillis: currentDisplayLinkMillis()
        )
        applyFaceMaskIfNeeded()
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

    private func applyFaceMaskIfNeeded(force: Bool = false) {
        // Mask changes must be atomic with the current video frame. Implicit
        // layer animations can crossfade old/new silhouettes and leave trails.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        ensureDanmakuContainers()
        guard let scrollingContainer else { return }
        guard settings.smartFaceAvoidanceEnabled else {
            scrollingContainer.mask = nil
            return
        }
        let snapshot = faceMaskAnalyzer?.snapshot() ?? DanmakuFaceMaskAnalyzer.Snapshot(
            generation: 0,
            faces: []
        )
        guard force || snapshot.generation != appliedFaceMaskGeneration else { return }
        appliedFaceMaskGeneration = snapshot.generation

        guard !snapshot.faces.isEmpty, bounds.width > 1, bounds.height > 1 else {
            scrollingContainer.mask = nil
            return
        }

        let maskBounds = CGRect(origin: .zero, size: bounds.size)
        let path = CGMutablePath()
        path.addRect(maskBounds)
        for face in snapshot.faces {
            addExpandedFaceContour(face, to: path)
        }

        // Reuse the mask instead of allocating and attaching a new full-size
        // compositing layer for every detection result.
        let mask = faceMaskLayer
        mask.frame = maskBounds
        mask.contentsScale = window?.backingScaleFactor ?? 2
        mask.fillColor = NSColor.white.cgColor
        mask.fillRule = .evenOdd
        mask.path = path
        if scrollingContainer.mask !== mask {
            scrollingContainer.mask = mask
        }
    }

    private func addExpandedFaceContour(
        _ face: DanmakuFaceMaskAnalyzer.Face,
        to path: CGMutablePath
    ) {
        let contentRect = videoContentRect()
        let points = face.contour.map { point in
            CGPoint(
                x: contentRect.minX + point.x * contentRect.width,
                y: contentRect.minY + point.y * contentRect.height
            )
        }
        guard points.count >= 3 else { return }
        let center = CGPoint(
            x: points.reduce(0) { $0 + $1.x } / CGFloat(points.count),
            y: points.reduce(0) { $0 + $1.y } / CGFloat(points.count)
        )
        // Segmentation already supplies the head silhouette; expand it only
        // slightly to cover antialiasing and sampling uncertainty.
        let expanded = points.map { point in
            return CGPoint(
                x: center.x + (point.x - center.x) * 1.04,
                y: center.y + (point.y - center.y) * 1.04
            )
        }
        path.move(to: expanded[0])
        for point in expanded.dropFirst() {
            path.addLine(to: point)
        }
        path.closeSubpath()
    }

    /// The mpv layer uses resize-aspect. In fullscreen a 4:3 video therefore
    /// occupies a centered rectangle with side bars, while the danmaku view
    /// spans the entire window. Face coordinates must be projected into that
    /// displayed video rectangle or the mask will drift horizontally.
    private func videoContentRect() -> CGRect {
        let aspectRatio = playbackEngine?.displayAspectRatio ?? 0
        guard aspectRatio.isFinite, aspectRatio > 0 else { return bounds }
        let fittedWidth = min(bounds.width, bounds.height * aspectRatio)
        let fittedHeight = min(bounds.height, bounds.width / aspectRatio)
        let size = CGSize(width: fittedWidth, height: fittedHeight)
        return CGRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    private func ensureDanmakuContainers() {
        guard let layer else { return }
        if scrollingContainer == nil {
            let container = CALayer()
            container.frame = bounds
            container.masksToBounds = true
            layer.addSublayer(container)
            scrollingContainer = container
        }
        if fixedContainer == nil {
            let container = CALayer()
            container.frame = bounds
            container.masksToBounds = true
            layer.addSublayer(container)
            fixedContainer = container
        }
        if scrollingContainer?.frame != bounds {
            scrollingContainer?.frame = bounds
        }
        if fixedContainer?.frame != bounds {
            fixedContainer?.frame = bounds
        }
    }

    private func renderNewLayer(frame: DanmakuDrawFrame, contentsScale: CGFloat) {
        let created = CALayer()
        created.actions = [
            "position": NSNull(),
            "bounds": NSNull(),
            "frame": NSNull(),
            "contents": NSNull(),
            "opacity": NSNull()
        ]
        created.frame = layerFrame(for: frame)
        let textLayer = CATextLayer()
        textLayer.string = frame.mainText
        textLayer.frame = created.bounds
        configureTextLayer(textLayer, contentsScale: contentsScale)
        created.addSublayer(textLayer)
        ensureDanmakuContainers()
        (frame.isScrolling ? scrollingContainer : fixedContainer)?.addSublayer(created)
        if frame.isScrolling {
            addScrollAnimation(to: created, frame: frame)
        }
        textLayers[frame.id] = DanmakuTextLayerState(layer: created)
    }

    private func configureTextLayer(_ layer: CATextLayer, contentsScale: CGFloat) {
        layer.contentsScale = contentsScale
        layer.isWrapped = false
        layer.truncationMode = .none
        layer.alignmentMode = .left
        layer.rasterizationScale = contentsScale
        layer.shouldRasterize = false
        layer.actions = ["position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "contents": NSNull()]
    }

    private func addScrollAnimation(to textLayer: CALayer, frame: DanmakuDrawFrame) {
        let remainingMillis = frame.durationMillis - frame.elapsedMillis
        guard remainingMillis > 16 else { return }
        let startX = frame.x + textLayer.bounds.width / 2
        let endX = frame.endX + textLayer.bounds.width / 2
        let y = textLayer.position.y
        textLayer.position = CGPoint(x: endX, y: y)
        let animation = CABasicAnimation(keyPath: "position.x")
        animation.fromValue = startX
        animation.toValue = endX
        animation.duration = remainingMillis / 1000
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.isRemovedOnCompletion = false
        animation.fillMode = .forwards
        textLayer.add(animation, forKey: "danmaku-scroll-x")
    }

    private func layerFrame(for frame: DanmakuDrawFrame) -> CGRect {
        CGRect(
            x: frame.x,
            y: bounds.height - frame.y - frame.textHeight,
            width: frame.textWidth + 4,
            height: frame.textHeight + 3
        )
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
        CATransaction.flush()
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
            resumeAnimationLayer(layer)
            if let scrollingContainer { resumeAnimationLayer(scrollingContainer) }
            if let fixedContainer { resumeAnimationLayer(fixedContainer) }
        } else {
            pauseAnimationLayer(layer)
            if let scrollingContainer { pauseAnimationLayer(scrollingContainer) }
            if let fixedContainer { pauseAnimationLayer(fixedContainer) }
        }
    }

    private func pauseAnimationLayer(_ layer: CALayer) {
        guard layer.speed != 0 else { return }
        layer.timeOffset = layer.convertTime(CACurrentMediaTime(), from: nil)
        layer.speed = 0
    }

    private func resumeAnimationLayer(_ layer: CALayer) {
        guard layer.speed == 0 else { return }
        let pausedTime = layer.timeOffset
        layer.speed = 1
        layer.timeOffset = 0
        layer.beginTime = 0
        layer.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - pausedTime
    }

    private func resetLayerTreeClockForNewTimeline() {
        guard let layer else { return }
        layer.speed = 1
        layer.timeOffset = 0
        layer.beginTime = 0
        commitNewTimelineToWindow()
    }

    private func commitNewTimelineToWindow() {
        needsLayout = true
        layoutSubtreeIfNeeded()
        layer?.setNeedsLayout()
        layer?.layoutIfNeeded()
        CATransaction.flush()
        window?.displayIfNeeded()
    }

    private func currentDisplayLinkMillis() -> Double {
        return CACurrentMediaTime() * 1000
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
    let layer: CALayer
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
