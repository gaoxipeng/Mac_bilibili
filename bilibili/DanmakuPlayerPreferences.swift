import Foundation

enum DanmakuPlayerPreferences {
    private static let defaults = UserDefaults.standard
    private static let danmakuVisibleKey = "danmaku_visible"
    private static let displayAreaKey = "danmaku_display_area"
    private static let opacityKey = "danmaku_opacity"
    private static let fontSizeKey = "danmaku_font_size"
    private static let speedKey = "danmaku_speed"

    static func isDanmakuVisible() -> Bool {
        if defaults.object(forKey: danmakuVisibleKey) == nil {
            return true
        }
        return defaults.bool(forKey: danmakuVisibleKey)
    }

    static func setDanmakuVisible(_ visible: Bool) {
        defaults.set(visible, forKey: danmakuVisibleKey)
    }

    static func readDanmakuSettings() -> DanmakuSettings {
        let savedArea = defaults.integer(forKey: displayAreaKey)
        let displayArea = DanmakuSettings.displayAreaOptions.first(where: { $0 == savedArea })
            ?? DanmakuSettings.displayAreaOptions.last!
        return DanmakuSettings(
            displayAreaPercent: displayArea,
            opacityPercent: defaults.object(forKey: opacityKey) == nil
                ? 100
                : defaults.integer(forKey: opacityKey).clamped(to: 10...100),
            fontSizePercent: defaults.object(forKey: fontSizeKey) == nil
                ? 100
                : defaults.integer(forKey: fontSizeKey).clamped(to: 50...170),
            speedLevel: DanmakuSpeedLevel.fromIndex(defaults.integer(forKey: speedKey))
        )
    }

    static func setDanmakuSettings(_ settings: DanmakuSettings) {
        defaults.set(settings.displayAreaPercent, forKey: displayAreaKey)
        defaults.set(settings.opacityPercent, forKey: opacityKey)
        defaults.set(settings.fontSizePercent, forKey: fontSizeKey)
        defaults.set(settings.speedLevel.rawValue, forKey: speedKey)
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
