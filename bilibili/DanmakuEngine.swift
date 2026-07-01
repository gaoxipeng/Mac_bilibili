import AppKit
import Foundation
import QuartzCore
import SwiftUI

private let fixedDanmakuDurationMs: Int64 = 4_000
private let scrollBaseDurationMs: Int64 = 7_000
private let scrollPerCharDurationMs: Int64 = 120
private let spawnLookaheadMs: Int64 = 120
private let spawnBacklogSkipMs: Int64 = 14_000
private let maxSpawnInspectionsPerFrame = 80
private let maxDanmakuTrackCapacity = 28
private let fixedDanmakuRowCount = 8
private let trackGapSec: Float = 0.15

func danmakuScrollDurationMs(item: BiliDanmakuItem, speedMultiplier: Float) -> Int64 {
    let base = scrollBaseDurationMs + Int64(item.content.count) * scrollPerCharDurationMs
    let clamped = min(14_000, max(5_000, base))
    return Int64(Float(clamped) * max(0.1, speedMultiplier))
}

func danmakuColor(_ argb: Int) -> Color {
    let value = argb & 0xFFFFFF
    return Color(
        red: Double((value >> 16) & 0xFF) / 255,
        green: Double((value >> 8) & 0xFF) / 255,
        blue: Double(value & 0xFF) / 255
    )
}

func danmakuFontSize(
    itemFontSize: Int,
    settings: DanmakuSettings,
    metrics: DanmakuLayoutMetrics
) -> CGFloat {
    metrics.fontSize(itemFontSize: itemFontSize, settings: settings)
}

struct DanmakuDrawFrame {
    let x: CGFloat
    let y: CGFloat
    let textHeight: CGFloat
    let mainText: NSAttributedString
}

private struct ActiveDanmaku {
    let item: BiliDanmakuItem
    var track: Int
    var animStartDisplayTimeMs: Int64
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

    private var displayTimeMs: Int64 = 0
    private var anchorPositionMs: Int64 = 0
    private var anchorRealtimeMs: Int64 = 0
    private var lastObservedPositionMs: Int64 = 0

    private var settings = DanmakuSettings()
    private var enabled = false
    private var layoutWidth: CGFloat = 1
    private var layoutMetrics = DanmakuLayoutMetrics.make(mode: .inline, layoutHeight: 1)
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
        let sizeChanged = layoutWidth != size.width || self.layoutMetrics != metrics
        let settingsChanged = self.settings != settings
        let itemsChanged = signature != itemsSignature
        self.items = items
        self.enabled = enabled
        self.settings = settings
        layoutWidth = max(1, size.width)
        layoutMetrics = metrics
        itemsSignature = signature
        if itemsChanged || settingsChanged {
            measureCache.removeAll()
        }
        if itemsChanged || settingsChanged || sizeChanged {
            resetTimeline(positionMs: anchorPositionMs)
        }
    }

    func sync(
        positionMs: Int64,
        isPlaying: Bool,
        playbackSpeed: Float = 1,
        realtimeMs: Int64? = nil
    ) {
        guard enabled, !items.isEmpty else {
            activeDanmaku.removeAll()
            drawFrames.removeAll(keepingCapacity: true)
            return
        }

        let positionDelta = positionMs - lastObservedPositionMs
        let positionJumped = positionDelta > 1_500 || positionDelta < -120
        lastObservedPositionMs = positionMs
        if positionJumped {
            resetTimeline(positionMs: positionMs)
        } else if !isPlaying {
            anchorPositionMs = positionMs
            anchorRealtimeMs = realtimeMs ?? currentRealtimeMs()
            displayTimeMs = positionMs
        }

        if isPlaying {
            let elapsed = (realtimeMs ?? currentRealtimeMs()) - anchorRealtimeMs
            displayTimeMs = anchorPositionMs + Int64(Double(elapsed) * Double(max(0.1, playbackSpeed)))
        }

        spawnDue(displayTimeMs: displayTimeMs)
        pruneExpired(displayTimeMs: displayTimeMs)
        rebuildDrawFrames()
    }

    func currentDrawFrames() -> [DanmakuDrawFrame] {
        drawFrames
    }

    func reanchorOnPlayStateChange(isPlaying: Bool, positionMs: Int64, realtimeMs: Int64? = nil) {
        if isPlaying {
            anchorPositionMs = positionMs
            displayTimeMs = positionMs
            anchorRealtimeMs = realtimeMs ?? currentRealtimeMs()
        } else {
            anchorPositionMs = positionMs
            displayTimeMs = positionMs
            anchorRealtimeMs = realtimeMs ?? currentRealtimeMs()
        }
    }

    private func resetTimeline(positionMs: Int64) {
        activeDanmaku.removeAll(keepingCapacity: true)
        spawnedIDs.removeAll(keepingCapacity: true)
        drawFrames.removeAll(keepingCapacity: true)
        trackReleaseTimes = [Float](repeating: 0, count: maxDanmakuTrackCapacity)
        topFixedReleaseTimes = [Float](repeating: 0, count: fixedDanmakuRowCount)
        bottomFixedReleaseTimes = [Float](repeating: 0, count: fixedDanmakuRowCount)
        nextIndex = spawnIndexForPosition(items: items, positionMs: max(0, positionMs - spawnBacklogSkipMs))
        anchorPositionMs = positionMs
        displayTimeMs = positionMs
        anchorRealtimeMs = currentRealtimeMs()
        lastObservedPositionMs = positionMs
    }

    private func spawnDue(displayTimeMs: Int64) {
        if nextIndex < items.count,
           items[nextIndex].timeMs < displayTimeMs - spawnBacklogSkipMs {
            nextIndex = spawnIndexForPosition(items: items, positionMs: displayTimeMs - spawnLookaheadMs)
        }
        var inspected = 0
        while nextIndex < items.count,
              items[nextIndex].timeMs <= displayTimeMs + spawnLookaheadMs,
              inspected < maxSpawnInspectionsPerFrame {
            let item = items[nextIndex]
            nextIndex += 1
            inspected += 1
            _ = trySpawn(item: item, animStartDisplayTimeMs: item.timeMs, displayTimeMs: displayTimeMs)
        }
    }

    private func trySpawn(item: BiliDanmakuItem, animStartDisplayTimeMs: Int64, displayTimeMs: Int64) -> Bool {
        guard !spawnedIDs.contains(item.id) else { return false }
        guard passesDensityGate(item: item, items: items) else { return false }
        guard let measured = measureDanmaku(item: item) else { return false }

        let mode = BiliDanmakuMode.from(item.mode) ?? .scroll
        let speedMultiplier = settings.speedLevel.durationMultiplier
        let currentTimeSec = Float(animStartDisplayTimeMs) / 1000
        let scrollAreaHeight = scrollAreaHeightPx()
        let screenWidth = layoutWidth
        let gapPx = layoutMetrics.scrollGap
        let trackLineHeight = layoutMetrics.trackLineHeight

        let active: ActiveDanmaku?
        switch mode {
        case .bottom, .top:
            let maxRows = fixedDanmakuMaxRows(scrollAreaHeight: scrollAreaHeight, lineHeight: trackLineHeight)
            var releaseTimes = mode == .top ? topFixedReleaseTimes : bottomFixedReleaseTimes
            let durationSec = Float(fixedDanmakuDurationMs) * speedMultiplier / 1000
            if let row = assignFixedDanmakuRow(
                releaseTimes: &releaseTimes,
                maxRows: maxRows,
                currentTimeSec: currentTimeSec,
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
                    animStartDisplayTimeMs: animStartDisplayTimeMs,
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
            let durationSec = Float(danmakuScrollDurationMs(item: item, speedMultiplier: speedMultiplier)) / 1000
            let maxTracks = min(layoutMetrics.maxTrackCount, max(1, Int(scrollAreaHeight / trackLineHeight)))
            let reverse = mode == .reverseScroll
            let durationMs = danmakuScrollDurationMs(item: item, speedMultiplier: speedMultiplier)
            if let track = assignDanmakuTrack(
                activeDanmaku: activeDanmaku,
                displayTimeMs: animStartDisplayTimeMs,
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
                    animStartDisplayTimeMs: animStartDisplayTimeMs,
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

    private func pruneExpired(displayTimeMs: Int64) {
        let speedMultiplier = settings.speedLevel.durationMultiplier
        activeDanmaku.removeAll { active in
            let elapsed = displayTimeMs - active.animStartDisplayTimeMs
            guard elapsed >= 0 else { return false }
            let mode = BiliDanmakuMode.from(active.item.mode) ?? .scroll
            switch mode {
            case .bottom, .top:
                return elapsed > Int64(Float(fixedDanmakuDurationMs) * speedMultiplier)
            case .scroll, .reverseScroll:
                return elapsed > active.scrollDurationMs
            }
        }
    }

    private func rebuildDrawFrames() {
        let trackLineHeight = layoutMetrics.trackLineHeight
        let bottomReservePx = layoutMetrics.bottomReserve
        let heightPx = layoutMetrics.layoutHeight
        let widthPx = layoutWidth
        let fixedPadding: CGFloat = 4

        drawFrames.removeAll(keepingCapacity: true)
        drawFrames.reserveCapacity(activeDanmaku.count)

        for active in activeDanmaku {
            let elapsed = displayTimeMs - active.animStartDisplayTimeMs
            guard elapsed >= 0 else { continue }
            let mode = BiliDanmakuMode.from(active.item.mode) ?? .scroll
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
            switch mode {
            case .bottom, .top:
                x = (widthPx - active.textWidth) / 2
            case .reverseScroll:
                let duration = CGFloat(active.scrollDurationMs)
                let progress = min(1, max(0, CGFloat(elapsed) / max(1, duration)))
                x = -active.textWidth + (widthPx + active.textWidth) * progress
            case .scroll:
                let duration = CGFloat(active.scrollDurationMs)
                let progress = min(1, max(0, CGFloat(elapsed) / max(1, duration)))
                x = widthPx - (widthPx + active.textWidth) * progress
            }
            drawFrames.append(
                DanmakuDrawFrame(
                    x: x,
                    y: y,
                    textHeight: active.textHeight,
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

    private func currentRealtimeMs() -> Int64 {
        Int64(CACurrentMediaTime() * 1000)
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

private func spawnIndexForPosition(items: [BiliDanmakuItem], positionMs: Int64) -> Int {
    guard !items.isEmpty else { return 0 }
    if let index = items.firstIndex(where: { $0.timeMs >= positionMs }) {
        return index
    }
    return items.count
}

private func passesDensityGate(item: BiliDanmakuItem, items: [BiliDanmakuItem]) -> Bool {
    guard items.count > 1_200 else { return true }
    let keepRatio: Float = {
        if items.count > 8_000 { return 0.45 }
        if items.count > 4_000 { return 0.55 }
        if items.count > 2_000 { return 0.68 }
        return 0.82
    }()
    return abs(item.id % 100) < Int(keepRatio * 100)
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
    displayTimeMs: Int64,
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
    let currentTimeSec = Float(displayTimeMs) / 1000
    let available = (0..<trackCount).filter { track in
        trackReleaseTimes[track] <= currentTimeSec &&
            canSpawnScrollOnTrack(
                track: track,
                activeDanmaku: activeDanmaku,
                displayTimeMs: displayTimeMs,
                screenWidth: screenWidth,
                gapPx: gapPx,
                speedMultiplier: speedMultiplier,
                reverse: reverse
            )
    }
    guard !available.isEmpty else { return nil }
    let track = available[Int(displayTimeMs % Int64(available.count))]
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
    displayTimeMs: Int64,
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

        let elapsed = displayTimeMs - active.animStartDisplayTimeMs
        guard elapsed >= 0 else { continue }
        let durationMs = danmakuScrollDurationMs(item: active.item, speedMultiplier: speedMultiplier)
        guard elapsed < durationMs else { continue }

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
            if rightPx + gapPx > screenWidth { return false }
        } else if leftPx < screenWidth + gapPx {
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
