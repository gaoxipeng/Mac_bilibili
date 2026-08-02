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
    private let timeline = DanmakuTimeline()
    private var displayLink: DispatchSourceTimer?
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
    private var appliedFaceMaskGeneration: UInt64 = .max
    private var scrollingContainer: CALayer?
    private var fixedContainer: CALayer?

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
        reconfigureTimelineIfNeeded(force: true)
        syncCurrentFrameAndRender()
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

        // CADisplayLink may remain in an idle/throttled state after mpv replaces
        // a file and only return to the display cadence after the next mouse
        // event. A main-queue dispatch timer is independent of AppKit's event
        // tracking state, so switching videos cannot reduce danmaku updates to
        // one frame every few seconds.
        let displayRefreshRate = max(window?.screen?.maximumFramesPerSecond ?? 60, 60)
        // The compositor animates text at the display rate. The main-queue
        // timer only advances the timeline and admits/removes layers, so 60 Hz
        // is sufficient and leaves the 120 Hz budget to video/UI work.
        let timelineRefreshRate = min(displayRefreshRate, 60)
        let interval = DispatchTimeInterval.nanoseconds(1_000_000_000 / timelineRefreshRate)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            self?.displayLinkFired()
        }
        displayLink = timer
        timer.resume()
    }

    func stopDisplayLink() {
        displayLink?.setEventHandler {}
        displayLink?.cancel()
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

    private func updateDisplayLinkFrameRate(_ link: DispatchSourceTimer? = nil) {
        guard link != nil || displayLink != nil else { return }
        refreshDisplayLink()
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

    private func displayLinkFired() {
        guard isActive, enabled, isPlaying, !items.isEmpty else { return }
        let positionMillis = resolvedPositionMillis()
        resetRenderedLayersIfPositionJumped(positionMillis)
        timeline.sync(
            positionMillis: positionMillis,
            isPlaying: true,
            realtimeMillis: currentDisplayLinkMillis()
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

        // Let Core Animation's compositor move existing scrolling comments.
        // Updating every text layer from the main thread at 120 Hz competes
        // with mpv and SwiftUI and produces visible judder. The timeline still
        // runs on the display timer, but only layer entry/exit touches AppKit.
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
        // CADisplayLink callbacks can sit outside the usual AppKit event
        // transaction. Submit newly added scrolling animations immediately;
        // otherwise they may remain frozen until the next mouse event.
        CATransaction.flush()
    }

    private func applyFaceMaskIfNeeded(force: Bool = false) {
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

        let mask = CAShapeLayer()
        mask.frame = maskBounds
        mask.contentsScale = window?.backingScaleFactor ?? 2
        mask.fillColor = NSColor.white.cgColor
        mask.fillRule = .evenOdd
        mask.path = path
        scrollingContainer.mask = mask
    }

    private func addExpandedFaceContour(
        _ face: DanmakuFaceMaskAnalyzer.Face,
        to path: CGMutablePath
    ) {
        let points = face.contour.map { point in
            CGPoint(x: point.x * bounds.width, y: point.y * bounds.height)
        }
        guard points.count >= 3 else { return }
        let center = CGPoint(
            x: points.reduce(0) { $0 + $1.x } / CGFloat(points.count),
            y: points.reduce(0) { $0 + $1.y } / CGFloat(points.count)
        )
        // A small contour margin protects the face while avoiding the large
        // rectangular dead zone used by the first implementation.
        let expanded = points.map { point in
            let verticalScale: CGFloat = point.y >= center.y ? 1.36 : 1.12
            return CGPoint(
                x: center.x + (point.x - center.x) * 1.16,
                y: center.y + (point.y - center.y) * verticalScale
            )
        }

        // Face landmarks often stop around the brow line. Add a shallow,
        // rounded forehead cap from the detected face bounds so comments do
        // not slip through the upper part of the face.
        let boundsRect = CGRect(
            x: face.boundingBox.minX * bounds.width,
            y: face.boundingBox.minY * bounds.height,
            width: face.boundingBox.width * bounds.width,
            height: face.boundingBox.height * bounds.height
        )
        let topY = min(
            bounds.height,
            max(expanded.map(\.y).max() ?? boundsRect.maxY,
                boundsRect.maxY + boundsRect.height * 0.24)
        )
        let capInset = boundsRect.width * 0.08
        let capLeft = max(0, boundsRect.minX + capInset)
        let capRight = min(bounds.width, boundsRect.maxX - capInset)
        // Build one non-self-intersecting outline. Landmark point order can
        // vary between Vision revisions; appending a cap directly to that
        // order caused the X-shaped hole seen in the forehead.
        let capPoints = [
            CGPoint(x: capLeft, y: topY - boundsRect.height * 0.04),
            CGPoint(x: (capLeft + capRight) / 2, y: topY),
            CGPoint(x: capRight, y: topY - boundsRect.height * 0.04),
        ]
        let outline = convexHull(expanded + capPoints)
        guard outline.count >= 3 else { return }
        path.move(to: outline[0])
        for point in outline.dropFirst() {
            path.addLine(to: point)
        }
        path.closeSubpath()
    }

    private func convexHull(_ points: [CGPoint]) -> [CGPoint] {
        let sorted = points.sorted { lhs, rhs in
            lhs.x == rhs.x ? lhs.y < rhs.y : lhs.x < rhs.x
        }
        guard sorted.count >= 3 else { return sorted }

        func cross(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }

        var lower: [CGPoint] = []
        for point in sorted {
            while lower.count >= 2,
                  cross(lower[lower.count - 2], lower[lower.count - 1], point) <= 0 {
                lower.removeLast()
            }
            lower.append(point)
        }

        var upper: [CGPoint] = []
        for point in sorted.reversed() {
            while upper.count >= 2,
                  cross(upper[upper.count - 2], upper[upper.count - 1], point) <= 0 {
                upper.removeLast()
            }
            upper.append(point)
        }
        lower.removeLast()
        upper.removeLast()
        return lower + upper
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
        scrollingContainer?.frame = bounds
        fixedContainer?.frame = bounds
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
        ensureDanmakuContainers()
        (frame.isScrolling ? scrollingContainer : fixedContainer)?.addSublayer(created)
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
