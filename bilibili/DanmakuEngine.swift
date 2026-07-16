import AppKit
import Foundation
import QuartzCore

private let fixedDanmakuDurationMs: Int64 = 4_000
private let scrollBaseDurationMs: Int64 = 7_200
private let scrollPerCharDurationMs: Int64 = 120
private let spawnLookaheadMs: Int64 = 900
private let spawnBacklogSkipMs: Int64 = 14_000
private let maxSpawnInspectionsPerFrame = 180
private let maxDanmakuTrackCapacity = 48
private let fixedDanmakuRowCount = 14
private let trackGapSec: Float = 0.12
private let playbackDriftReanchorThresholdMs: Double = 260

func danmakuScrollDurationMs(item: BiliDanmakuItem, speedMultiplier: Float) -> Int64 {
    let base = scrollBaseDurationMs + Int64(item.content.count) * scrollPerCharDurationMs
    let clamped = min(14_000, max(5_000, base))
    return Int64(Float(clamped) * max(0.1, speedMultiplier))
}

func danmakuFontSize(
    itemFontSize: Int,
    settings: DanmakuSettings,
    metrics: DanmakuLayoutMetrics
) -> CGFloat {
    metrics.fontSize(itemFontSize: itemFontSize, settings: settings)
}

struct DanmakuDrawFrame {
    let id: Int
    let mode: BiliDanmakuMode
    let x: CGFloat
    let y: CGFloat
    let endX: CGFloat
    let textWidth: CGFloat
    let textHeight: CGFloat
    let elapsedMillis: Double
    let durationMillis: Double
    let mainText: NSAttributedString

    var isScrolling: Bool {
        mode == .scroll || mode == .reverseScroll
    }
}

private struct ActiveDanmaku {
    let item: BiliDanmakuItem
    var track: Int
    var animStartDisplayTimeMillis: Double
    let textWidth: CGFloat
    let textHeight: CGFloat
    let fontSize: CGFloat
    let mainText: NSAttributedString
    let scrollDurationMs: Int64
}

@MainActor
final class DanmakuTimeline {
    private var items: [BiliDanmakuItem] = []
    private var activeDanmaku: [ActiveDanmaku] = []
    private var spawnedIDs = Set<Int>()
    private var trackReleaseTimes = [Float](repeating: 0, count: maxDanmakuTrackCapacity)
    private var topFixedReleaseTimes = [Float](repeating: 0, count: fixedDanmakuRowCount)
    private var bottomFixedReleaseTimes = [Float](repeating: 0, count: fixedDanmakuRowCount)
    private var nextIndex = 0

    private var displayTimeMillis: Double = 0
    private var anchorPositionMillis: Double = 0
    private var anchorRealtimeMillis: Double = 0
    private var lastObservedPositionMillis: Double = 0

    private var settings = DanmakuSettings()
    private var enabled = false
    private var layoutWidth: CGFloat = 1
    private var layoutMetrics = DanmakuLayoutMetrics.make(mode: .inline, layoutHeight: 1)
    private var layoutStrategy = DanmakuLayoutStrategy.inline
    private var trackLineHeight: CGFloat = 24
    private var itemsSignature = DanmakuItemsSignature.empty
    private var drawFrames: [DanmakuDrawFrame] = []
    private var measureCache: [DanmakuMeasureKey: DanmakuMeasuredText] = [:]

    func configure(
        items: [BiliDanmakuItem],
        enabled: Bool,
        settings: DanmakuSettings,
        size: CGSize,
        layoutMode: DanmakuLayoutMode
    ) {
        let signature = DanmakuItemsSignature(items: items)
        let layoutHeight = max(1, size.height)
        let metrics = DanmakuLayoutMetrics.make(mode: layoutMode, layoutHeight: layoutHeight)
        let sizeChanged = abs(layoutWidth - size.width) > 0.5 || !layoutMetricsApproximatelyEqual(self.layoutMetrics, metrics)
        let settingsChanged = self.settings != settings
        let itemsChanged = signature != itemsSignature
        self.items = items
        self.enabled = enabled
        self.settings = settings
        layoutWidth = max(1, size.width)
        layoutMetrics = metrics
        layoutStrategy = DanmakuLayoutStrategy(
            mode: layoutMode,
            settings: settings,
            width: max(1, size.width),
            metrics: metrics
        )
        trackLineHeight = Self.resolvedTrackLineHeight(
            items: items,
            settings: settings,
            metrics: metrics,
            strategy: layoutStrategy
        )
        itemsSignature = signature
        if itemsChanged || settingsChanged {
            measureCache.removeAll()
        }
        if itemsChanged || settingsChanged || sizeChanged {
            resetTimeline(positionMillis: anchorPositionMillis)
        }
    }

    func sync(
        positionMillis: Double,
        isPlaying: Bool,
        playbackSpeed: Float = 1,
        realtimeMillis: Double? = nil
    ) {
        guard enabled, !items.isEmpty else {
            activeDanmaku.removeAll()
            drawFrames.removeAll(keepingCapacity: true)
            return
        }

        let positionDelta = positionMillis - lastObservedPositionMillis
        let positionJumped = positionDelta > 1_500 || positionDelta < -500
        lastObservedPositionMillis = positionMillis
        if positionJumped {
            resetTimeline(positionMillis: positionMillis)
        } else if !isPlaying {
            anchorPositionMillis = positionMillis
            anchorRealtimeMillis = realtimeMillis ?? currentRealtimeMillis()
            displayTimeMillis = positionMillis
        }

        if isPlaying {
            if let realtimeMillis {
                let elapsed = realtimeMillis - anchorRealtimeMillis
                displayTimeMillis = anchorPositionMillis + elapsed * Double(max(0.1, playbackSpeed))
                let drift = positionMillis - displayTimeMillis
                if abs(drift) > playbackDriftReanchorThresholdMs {
                    anchorPositionMillis = positionMillis
                    anchorRealtimeMillis = realtimeMillis
                    displayTimeMillis = positionMillis
                }
            } else {
                displayTimeMillis = positionMillis
            }
        }

        spawnDue(displayTimeMillis: displayTimeMillis)
        pruneExpired(displayTimeMillis: displayTimeMillis)
        rebuildDrawFrames()
    }

    func currentDrawFrames() -> [DanmakuDrawFrame] {
        drawFrames
    }

    func reanchorOnPlayStateChange(isPlaying: Bool, positionMillis: Double, realtimeMillis: Double? = nil) {
        anchorPositionMillis = positionMillis
        displayTimeMillis = positionMillis
        anchorRealtimeMillis = realtimeMillis ?? currentRealtimeMillis()
        lastObservedPositionMillis = positionMillis
    }

    private func resetTimeline(positionMillis: Double) {
        activeDanmaku.removeAll(keepingCapacity: true)
        spawnedIDs.removeAll(keepingCapacity: true)
        drawFrames.removeAll(keepingCapacity: true)
        trackReleaseTimes = [Float](repeating: 0, count: maxDanmakuTrackCapacity)
        topFixedReleaseTimes = [Float](repeating: 0, count: fixedDanmakuRowCount)
        bottomFixedReleaseTimes = [Float](repeating: 0, count: fixedDanmakuRowCount)
        nextIndex = spawnIndexForPosition(
            items: items,
            positionMillis: max(0, positionMillis - Double(spawnBacklogSkipMs))
        )
        anchorPositionMillis = positionMillis
        displayTimeMillis = positionMillis
        anchorRealtimeMillis = currentRealtimeMillis()
        lastObservedPositionMillis = positionMillis
    }

    private func spawnDue(displayTimeMillis: Double) {
        if nextIndex < items.count,
           Double(items[nextIndex].timeMs) < displayTimeMillis - Double(spawnBacklogSkipMs) {
            nextIndex = spawnIndexForPosition(
                items: items,
                positionMillis: displayTimeMillis - Double(spawnLookaheadMs)
            )
        }
        var inspected = 0
        while nextIndex < items.count,
              Double(items[nextIndex].timeMs) <= displayTimeMillis + Double(spawnLookaheadMs),
              inspected < maxSpawnInspectionsPerFrame {
            let item = items[nextIndex]
            nextIndex += 1
            inspected += 1
            _ = trySpawn(
                item: item,
                animStartDisplayTimeMillis: Double(item.timeMs),
                displayTimeMillis: displayTimeMillis
            )
        }
    }

    private func trySpawn(item: BiliDanmakuItem, animStartDisplayTimeMillis: Double, displayTimeMillis: Double) -> Bool {
        guard !spawnedIDs.contains(item.id) else { return false }
        guard layoutStrategy.shouldKeep(item: item, totalItemCount: items.count) else { return false }
        guard let measured = measureDanmaku(item: item) else { return false }

        let mode = BiliDanmakuMode.from(item.mode) ?? .scroll
        let speedMultiplier = layoutStrategy.speedMultiplier
        let scrollAreaHeight = scrollAreaHeightPx()
        let screenWidth = layoutWidth
        let gapPx = layoutMetrics.scrollGap
        let scheduledStartMillis = scheduledDisplayTimeMillis(for: item, mode: mode)

        let active: ActiveDanmaku?
        switch mode {
        case .bottom, .top:
            let maxRows = fixedDanmakuMaxRows(scrollAreaHeight: scrollAreaHeight, lineHeight: trackLineHeight)
            var releaseTimes = mode == .top ? topFixedReleaseTimes : bottomFixedReleaseTimes
            let durationSec = Float(fixedDanmakuDurationMs) * speedMultiplier / 1000
            if let row = assignFixedDanmakuRow(
                releaseTimes: &releaseTimes,
                maxRows: maxRows,
                currentTimeSec: Float(scheduledStartMillis / 1000),
                durationSec: durationSec
            ) {
                if mode == .top {
                    topFixedReleaseTimes = releaseTimes
                } else {
                    bottomFixedReleaseTimes = releaseTimes
                }
                active = ActiveDanmaku(
                    item: item,
                    track: row,
                    animStartDisplayTimeMillis: scheduledStartMillis,
                    textWidth: measured.textWidth,
                    textHeight: measured.textHeight,
                    fontSize: measured.fontSize,
                    mainText: measured.mainText,
                    scrollDurationMs: Int64(Float(fixedDanmakuDurationMs) * speedMultiplier)
                )
            } else {
                active = nil
            }
        case .scroll, .reverseScroll:
            let durationSec = Float(layoutStrategy.scrollDurationMillis(for: item)) / 1000
            let maxTracks = min(layoutStrategy.maxTrackCount, max(1, Int(scrollAreaHeight / trackLineHeight)))
            let reverse = mode == .reverseScroll
            let durationMs = layoutStrategy.scrollDurationMillis(for: item)
            if let track = assignDanmakuTrack(
                activeDanmaku: activeDanmaku,
                displayTimeMillis: scheduledStartMillis,
                trackReleaseTimes: &trackReleaseTimes,
                maxTracks: maxTracks,
                durationSec: durationSec,
                textWidth: measured.textWidth,
                durationMs: durationMs,
                screenWidth: screenWidth,
                gapPx: gapPx,
                speedMultiplier: speedMultiplier,
                reverse: reverse
            ) {
                active = ActiveDanmaku(
                    item: item,
                    track: track,
                    animStartDisplayTimeMillis: scheduledStartMillis,
                    textWidth: measured.textWidth,
                    textHeight: measured.textHeight,
                    fontSize: measured.fontSize,
                    mainText: measured.mainText,
                    scrollDurationMs: durationMs
                )
            } else {
                active = nil
            }
        }

        guard let active else { return false }
        spawnedIDs.insert(item.id)
        activeDanmaku.append(active)
        return true
    }

    private func scheduledDisplayTimeMillis(for item: BiliDanmakuItem, mode: BiliDanmakuMode) -> Double {
        let spread = layoutStrategy.spawnSpreadMillis(for: item, mode: mode, totalItemCount: items.count)
        return Double(item.timeMs) + spread
    }

    private func measureDanmaku(item: BiliDanmakuItem) -> DanmakuMeasuredText? {
        let fontSize = danmakuFontSize(
            itemFontSize: item.fontSize,
            settings: settings,
            metrics: layoutMetrics
        )
        let opacity = Double(settings.opacityPercent.clamped(to: 10...100)) / 100
        let key = DanmakuMeasureKey(
            content: item.content,
            colorArgb: item.colorArgb,
            fontSize: fontSize,
            opacityPercent: settings.opacityPercent,
            layoutMode: layoutMetrics.mode
        )
        if let cached = measureCache[key] {
            return cached
        }

        let baseColor = danmakuNSColor(item.colorArgb).withAlphaComponent(opacity)
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let shadow = NSShadow()
        shadow.shadowOffset = NSSize(width: 1, height: -1)
        shadow.shadowBlurRadius = 2
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.72 * opacity)
        let mainAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: baseColor,
            .shadow: shadow,
        ]
        let mainText = NSAttributedString(string: item.content, attributes: mainAttributes)
        let size = mainText.size()
        guard size.width > 0 else { return nil }

        let measured = DanmakuMeasuredText(
            textWidth: size.width,
            textHeight: size.height,
            fontSize: fontSize,
            mainText: mainText
        )
        measureCache[key] = measured
        return measured
    }

    private func pruneExpired(displayTimeMillis: Double) {
        let speedMultiplier = layoutStrategy.speedMultiplier
        activeDanmaku.removeAll { active in
            let elapsed = displayTimeMillis - active.animStartDisplayTimeMillis
            guard elapsed >= 0 else { return false }
            let mode = BiliDanmakuMode.from(active.item.mode) ?? .scroll
            switch mode {
            case .bottom, .top:
                return elapsed > Double(fixedDanmakuDurationMs) * Double(speedMultiplier)
            case .scroll, .reverseScroll:
                return elapsed > Double(active.scrollDurationMs)
            }
        }
    }

    private func rebuildDrawFrames() {
        let bottomReservePx = layoutMetrics.bottomReserve
        let heightPx = layoutMetrics.layoutHeight
        let widthPx = layoutWidth
        let fixedPadding: CGFloat = 4

        drawFrames.removeAll(keepingCapacity: true)
        drawFrames.reserveCapacity(activeDanmaku.count)

        for active in activeDanmaku {
            let elapsed = displayTimeMillis - active.animStartDisplayTimeMillis
            guard elapsed >= 0 else { continue }
            let mode = BiliDanmakuMode.from(active.item.mode) ?? .scroll
            let durationMillis: Double
            switch mode {
            case .bottom, .top:
                durationMillis = Double(fixedDanmakuDurationMs) * Double(layoutStrategy.speedMultiplier)
            case .scroll, .reverseScroll:
                durationMillis = Double(active.scrollDurationMs)
            }
            let rowGap = trackLineHeight
            let y: CGFloat
            switch mode {
            case .bottom:
                y = max(
                    0,
                    heightPx - bottomReservePx - active.textHeight - fixedPadding - CGFloat(active.track) * rowGap
                )
            case .top:
                y = CGFloat(active.track) * rowGap + max(0, (rowGap - active.textHeight) / 2)
            case .scroll, .reverseScroll:
                y = CGFloat(active.track) * rowGap + max(0, (rowGap - active.textHeight) / 2)
            }
            let x: CGFloat
            let endX: CGFloat
            switch mode {
            case .bottom, .top:
                x = (widthPx - active.textWidth) / 2
                endX = x
            case .reverseScroll:
                let duration = CGFloat(active.scrollDurationMs)
                let progress = min(1, max(0, CGFloat(elapsed) / max(1, duration)))
                x = -active.textWidth + (widthPx + active.textWidth) * progress
                endX = widthPx
            case .scroll:
                let duration = CGFloat(active.scrollDurationMs)
                let progress = min(1, max(0, CGFloat(elapsed) / max(1, duration)))
                x = widthPx - (widthPx + active.textWidth) * progress
                endX = -active.textWidth
            }
                drawFrames.append(
                    DanmakuDrawFrame(
                        id: active.item.id,
                        mode: mode,
                        x: x,
                        y: y,
                        endX: endX,
                        textWidth: active.textWidth,
                        textHeight: active.textHeight,
                        elapsedMillis: elapsed,
                        durationMillis: durationMillis,
                        mainText: active.mainText
                )
            )
        }
    }

    private func scrollAreaHeightPx() -> CGFloat {
        let full = max(1, layoutMetrics.layoutHeight - layoutMetrics.bottomReserve)
        let percent = CGFloat(
            layoutMetrics.effectiveDisplayAreaPercent(from: settings).clamped(to: 10...100)
        ) / 100
        return full * percent
    }

    private func currentRealtimeMillis() -> Double {
        CACurrentMediaTime() * 1000
    }

    private static func resolvedTrackLineHeight(
        items: [BiliDanmakuItem],
        settings: DanmakuSettings,
        metrics: DanmakuLayoutMetrics,
        strategy: DanmakuLayoutStrategy
    ) -> CGFloat {
        let fallbackFontSize: CGFloat = metrics.mode == .inline ? 28 : 44
        let maxFontSize = items.reduce(CGFloat(0)) { partial, item in
            max(partial, metrics.fontSize(itemFontSize: item.fontSize, settings: settings))
        }
        let protectedFontSize = max(maxFontSize, min(fallbackFontSize, metrics.fontSize(itemFontSize: 25, settings: settings)))
        return max(strategy.minimumTrackLineHeight, ceil(protectedFontSize * strategy.lineHeightMultiplier + strategy.lineHeightPadding))
    }
}

private func danmakuNSColor(_ argb: Int) -> NSColor {
    let value = argb & 0xFFFFFF
    return NSColor(
        red: CGFloat((value >> 16) & 0xFF) / 255,
        green: CGFloat((value >> 8) & 0xFF) / 255,
        blue: CGFloat(value & 0xFF) / 255,
        alpha: 1
    )
}

private func layoutMetricsApproximatelyEqual(_ lhs: DanmakuLayoutMetrics, _ rhs: DanmakuLayoutMetrics) -> Bool {
    lhs.mode == rhs.mode && abs(lhs.layoutHeight - rhs.layoutHeight) <= 0.5
}

private struct DanmakuLayoutStrategy {
    let mode: DanmakuLayoutMode
    let speedMultiplier: Float
    let spawnSpreadMillis: Double
    let fixedSpawnSpreadMillis: Double
    let densityKeepRatio: Double
    let minimumTrackLineHeight: CGFloat
    let lineHeightMultiplier: CGFloat
    let lineHeightPadding: CGFloat
    let maxTrackCount: Int

    static let inline = DanmakuLayoutStrategy(
        mode: .inline,
        speedMultiplier: DanmakuSpeedLevel.medium.durationMultiplier,
        spawnSpreadMillis: 520,
        fixedSpawnSpreadMillis: 220,
        densityKeepRatio: 1,
        minimumTrackLineHeight: 24,
        lineHeightMultiplier: 1.36,
        lineHeightPadding: 6,
        maxTrackCount: 18
    )

    init(mode: DanmakuLayoutMode, settings: DanmakuSettings, width: CGFloat, metrics: DanmakuLayoutMetrics) {
        self.mode = mode
        speedMultiplier = settings.speedLevel.durationMultiplier
        switch mode {
        case .inline:
            spawnSpreadMillis = 560
            fixedSpawnSpreadMillis = 220
            densityKeepRatio = metrics.layoutHeight < 220 ? 0.94 : 0.98
            minimumTrackLineHeight = 24
            lineHeightMultiplier = 1.38
            lineHeightPadding = 7
            maxTrackCount = 24
        case .fullscreen:
            spawnSpreadMillis = width > 1_600 ? 780 : 680
            fixedSpawnSpreadMillis = 320
            densityKeepRatio = 1
            minimumTrackLineHeight = 34
            lineHeightMultiplier = 1.34
            lineHeightPadding = 8
            maxTrackCount = 44
        }
    }

    private init(
        mode: DanmakuLayoutMode,
        speedMultiplier: Float,
        spawnSpreadMillis: Double,
        fixedSpawnSpreadMillis: Double,
        densityKeepRatio: Double,
        minimumTrackLineHeight: CGFloat,
        lineHeightMultiplier: CGFloat,
        lineHeightPadding: CGFloat,
        maxTrackCount: Int
    ) {
        self.mode = mode
        self.speedMultiplier = speedMultiplier
        self.spawnSpreadMillis = spawnSpreadMillis
        self.fixedSpawnSpreadMillis = fixedSpawnSpreadMillis
        self.densityKeepRatio = densityKeepRatio
        self.minimumTrackLineHeight = minimumTrackLineHeight
        self.lineHeightMultiplier = lineHeightMultiplier
        self.lineHeightPadding = lineHeightPadding
        self.maxTrackCount = maxTrackCount
    }

    func scrollDurationMillis(for item: BiliDanmakuItem) -> Int64 {
        danmakuScrollDurationMs(item: item, speedMultiplier: speedMultiplier)
    }

    func spawnSpreadMillis(for item: BiliDanmakuItem, mode: BiliDanmakuMode, totalItemCount: Int) -> Double {
        let base = mode == .scroll || mode == .reverseScroll ? spawnSpreadMillis : fixedSpawnSpreadMillis
        guard base > 0 else { return 0 }
        let densityBoost = totalItemCount > 4_000 ? 1.18 : (totalItemCount > 1_500 ? 1.08 : 1)
        return Double(stableDanmakuHash(item.id, item.timeMs) % 1_000) / 999 * base * densityBoost
    }

    func shouldKeep(item: BiliDanmakuItem, totalItemCount: Int) -> Bool {
        guard densityKeepRatio < 0.999 else { return true }
        let pressureRatio: Double
        if totalItemCount > 8_000 {
            pressureRatio = densityKeepRatio * 0.83
        } else if totalItemCount > 4_000 {
            pressureRatio = densityKeepRatio * 0.89
        } else if totalItemCount > 2_000 {
            pressureRatio = densityKeepRatio * 0.95
        } else {
            pressureRatio = densityKeepRatio
        }
        let bucket = stableDanmakuHash(item.id, item.timeMs) % 10_000
        return Double(bucket) < pressureRatio * 10_000
    }
}

private struct DanmakuMeasuredText {
    let textWidth: CGFloat
    let textHeight: CGFloat
    let fontSize: CGFloat
    let mainText: NSAttributedString
}

private struct DanmakuMeasureKey: Hashable {
    let content: String
    let colorArgb: Int
    let fontSize: CGFloat
    let opacityPercent: Int
    let layoutMode: DanmakuLayoutMode
}

private struct DanmakuItemsSignature: Equatable {
    let count: Int
    let firstID: Int?
    let lastID: Int?

    static let empty = DanmakuItemsSignature(items: [])

    init(items: [BiliDanmakuItem]) {
        count = items.count
        firstID = items.first?.id
        lastID = items.last?.id
    }
}

private func spawnIndexForPosition(items: [BiliDanmakuItem], positionMillis: Double) -> Int {
    guard !items.isEmpty else { return 0 }
    let positionMs = Int64(positionMillis.rounded(.down))
    if let index = items.firstIndex(where: { $0.timeMs >= positionMs }) {
        return index
    }
    return items.count
}

private func stableDanmakuHash(_ id: Int, _ timeMs: Int64) -> Int {
    var value = UInt64(bitPattern: Int64(id))
    value &+= UInt64(bitPattern: timeMs) &* 0x9E37_79B9_7F4A_7C15
    value ^= value >> 30
    value &*= 0xBF58_476D_1CE4_E5B9
    value ^= value >> 27
    value &*= 0x94D0_49BB_1331_11EB
    value ^= value >> 31
    return Int(value % UInt64(Int.max))
}

private func fixedDanmakuMaxRows(scrollAreaHeight: CGFloat, lineHeight: CGFloat) -> Int {
    guard lineHeight > 0 else { return 1 }
    let rows = Int(scrollAreaHeight * 0.35 / lineHeight)
    return min(fixedDanmakuRowCount, max(1, rows))
}

private func assignFixedDanmakuRow(
    releaseTimes: inout [Float],
    maxRows: Int,
    currentTimeSec: Float,
    durationSec: Float
) -> Int? {
    let rowCount = min(maxRows, releaseTimes.count)
    let idleRows = (0..<rowCount).filter { releaseTimes[$0] <= currentTimeSec }
    if !idleRows.isEmpty {
        let row = idleRows[Int(currentTimeSec * 1000) % idleRows.count]
        releaseTimes[row] = currentTimeSec + durationSec + trackGapSec
        return row
    }
    var bestRow = 0
    var earliest = releaseTimes[0]
    for index in 1..<rowCount where releaseTimes[index] < earliest {
        earliest = releaseTimes[index]
        bestRow = index
    }
    guard earliest - currentTimeSec <= 0.2 else { return nil }
    releaseTimes[bestRow] = currentTimeSec + durationSec + trackGapSec
    return bestRow
}

private func assignDanmakuTrack(
    activeDanmaku: [ActiveDanmaku],
    displayTimeMillis: Double,
    trackReleaseTimes: inout [Float],
    maxTracks: Int,
    durationSec: Float,
    textWidth: CGFloat,
    durationMs: Int64,
    screenWidth: CGFloat,
    gapPx: CGFloat,
    speedMultiplier: Float,
    reverse: Bool
) -> Int? {
    let trackCount = min(maxTracks, trackReleaseTimes.count)
    let currentTimeSec = Float(displayTimeMillis / 1000)
    let available = (0..<trackCount).filter { track in
        trackReleaseTimes[track] <= currentTimeSec &&
            canSpawnScrollOnTrack(
                track: track,
                activeDanmaku: activeDanmaku,
                displayTimeMillis: displayTimeMillis,
                screenWidth: screenWidth,
                gapPx: gapPx,
                speedMultiplier: speedMultiplier,
                reverse: reverse
            )
    }
    guard !available.isEmpty else { return nil }
    let track = available[Int(Int64(displayTimeMillis) % Int64(available.count))]
    let entryBlock = scrollTrackEntryBlockSec(
        durationSec: durationSec,
        textWidth: textWidth,
        screenWidth: screenWidth,
        gapPx: gapPx
    )
    trackReleaseTimes[track] = max(trackReleaseTimes[track], currentTimeSec) + entryBlock
    return track
}

private func canSpawnScrollOnTrack(
    track: Int,
    activeDanmaku: [ActiveDanmaku],
    displayTimeMillis: Double,
    screenWidth: CGFloat,
    gapPx: CGFloat,
    speedMultiplier: Float,
    reverse: Bool
) -> Bool {
    for active in activeDanmaku where active.track == track {
        guard let mode = BiliDanmakuMode.from(active.item.mode) else { continue }
        let isReverse = mode == .reverseScroll
        guard mode == .scroll || isReverse else { continue }
        guard reverse == isReverse else { continue }

        let elapsed = displayTimeMillis - active.animStartDisplayTimeMillis
        guard elapsed >= 0 else { continue }
        let durationMs = danmakuScrollDurationMs(item: active.item, speedMultiplier: speedMultiplier)
        guard elapsed < Double(durationMs) else { continue }

        let leftPx: CGFloat
        if reverse {
            let progress = CGFloat(elapsed) / CGFloat(max(1, durationMs))
            leftPx = -active.textWidth + (screenWidth + active.textWidth) * progress
        } else {
            let progress = CGFloat(elapsed) / CGFloat(max(1, durationMs))
            leftPx = screenWidth - (screenWidth + active.textWidth) * progress
        }
        let rightPx = leftPx + active.textWidth
        if reverse {
            // Reverse comments enter from the left. The previous comment must
            // have moved far enough right to leave an entry gap at x = 0.
            if leftPx - gapPx < 0 { return false }
        } else if rightPx + gapPx > screenWidth {
            // Normal comments enter from the right. Reuse the track once the
            // previous comment's trailing edge has cleared the entry gap.
            return false
        }
    }
    return true
}

private func scrollTrackEntryBlockSec(
    durationSec: Float,
    textWidth: CGFloat,
    screenWidth: CGFloat,
    gapPx: CGFloat
) -> Float {
    guard screenWidth > 0 else {
        return min(durationSec * 0.6, max(0.35, durationSec * 0.28 + trackGapSec))
    }
    let block = durationSec * Float((textWidth + gapPx) / (screenWidth + textWidth)) + trackGapSec
    return min(durationSec * 0.85, max(0.35, block))
}

private extension Int {
    nonisolated func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
