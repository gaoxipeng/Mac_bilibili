import Foundation

enum FeedLayoutMode: String, CaseIterable, Sendable {
    /// 原生卡片：封面下方展示标题 / 作者（应用最初的信息流样式）
    /// rawValue 沿用 waterfall，避免已选默认布局的用户被误迁移。
    case native = "waterfall"
    /// 叠层卡片：更大卡片，标题 / 作者 / 数据叠在封面上
    case overlay = "overlay"

    var menuTitle: String {
        switch self {
        case .native: "原生卡片"
        case .overlay: "叠层卡片"
        }
    }

    var menuSubtitle: String {
        switch self {
        case .native: "封面下方展示标题与作者"
        case .overlay: "更大卡片，标题与数据叠在封面上"
        }
    }
}

enum FeedLayoutPreferences {
    private static let defaults = UserDefaults.standard
    private static let modeKey = "feed_layout_mode"

    static func read() -> FeedLayoutMode {
        guard let raw = defaults.string(forKey: modeKey) else {
            return .native
        }
        switch raw {
        case FeedLayoutMode.native.rawValue, "multiColumn":
            return .native
        case FeedLayoutMode.overlay.rawValue, "singleColumn", "native":
            // "native" 曾表示叠层样式，迁移到 overlay
            return .overlay
        default:
            return .native
        }
    }

    static func write(_ mode: FeedLayoutMode) {
        defaults.set(mode.rawValue, forKey: modeKey)
    }
}
