import CoreGraphics
import Foundation

nonisolated enum DanmakuLayoutMode: Sendable, Equatable {
    case inline
    case fullscreen
}

struct DanmakuLayoutMetrics: Sendable, Equatable {
    let mode: DanmakuLayoutMode
    let layoutHeight: CGFloat

    /// 原先滑块 140% 时的实际字号倍率，现作为滑块 100% 的基准。
    private static let legacyInlineFontBoost: Double = 1.20
    private static let rebasedDefaultSliderPercent: Double = 1.40

    static func baselineFontSizeMultiplier(for mode: DanmakuLayoutMode) -> Double {
        switch mode {
        case .inline:
            legacyInlineFontBoost * rebasedDefaultSliderPercent
        case .fullscreen:
            rebasedDefaultSliderPercent
        }
    }

    static func make(mode: DanmakuLayoutMode, layoutHeight: CGFloat) -> DanmakuLayoutMetrics {
        DanmakuLayoutMetrics(mode: mode, layoutHeight: max(1, layoutHeight))
    }

    var trackLineHeight: CGFloat {
        switch mode {
        case .inline: 20
        case .fullscreen: 26
        }
    }

    var scrollGap: CGFloat {
        switch mode {
        case .inline: 28
        case .fullscreen: 36
        }
    }

    var maxTrackCount: Int {
        switch mode {
        case .inline: 18
        case .fullscreen: 40
        }
    }

    var bottomReserve: CGFloat {
        switch mode {
        case .inline: 58
        case .fullscreen: 62
        }
    }

    func effectiveDisplayAreaPercent(from settings: DanmakuSettings) -> Int {
        settings.displayAreaPercent
    }

    func effectiveFontSizePercent(from settings: DanmakuSettings) -> Int {
        let userPercent = settings.fontSizePercent.clamped(to: 50...170)
        let multiplier = Self.baselineFontSizeMultiplier(for: mode)
        return Int((Double(userPercent) * multiplier).rounded()).clamped(to: 50...170)
    }

    func fontSize(itemFontSize: Int, settings: DanmakuSettings) -> CGFloat {
        let fontSizePercent = effectiveFontSizePercent(from: settings)
        switch mode {
        case .inline:
            let scale = min(1.35, max(0.75, layoutHeight / 210))
            let size = CGFloat(itemFontSize) * 0.52 * scale * CGFloat(fontSizePercent) / 100
            return min(28, max(10, size))
        case .fullscreen:
            let scale = min(2.0, max(1.08, layoutHeight / 280))
            let size = CGFloat(itemFontSize) * 0.52 * scale * CGFloat(fontSizePercent) / 100
            return min(44, max(14, size))
        }
    }
}

private extension Int {
    nonisolated func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
