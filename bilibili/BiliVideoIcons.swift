import AppKit
import SwiftUI

enum BiliTheme {
    static let blue = Color(red: 0, green: 174 / 255, blue: 236 / 255)
    static let pink = Color(red: 251 / 255, green: 114 / 255, blue: 153 / 255)
    static let actionInactive = Color(red: 153 / 255, green: 153 / 255, blue: 153 / 255)
    static let videoControlBorder = Color(red: 153 / 255, green: 153 / 255, blue: 153 / 255).opacity(0.5)
}

enum BiliIcon: String {
    case like = "ic_bili_like"
    case likeFilled = "ic_bili_like_filled"
    case coin = "ic_bili_coin"
    case favorite = "ic_bili_favorite"
    case share = "ic_bili_share"
    case play = "ic_bili_play"
    case danmaku = "ic_bili_danmaku"
}

@MainActor
final class ShareClickContext {
    weak var sourceView: NSView?
    var locationInView: NSPoint = .zero
}

struct CoinMenuPressOverlay: NSViewRepresentable {
    let canCoinTwo: Bool
    let canCoinMore: Bool
    let onPrepare: () -> Bool
    let onBlocked: () -> Void
    let onCoinOne: () -> Void
    let onCoinTwo: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCoinOne: onCoinOne, onCoinTwo: onCoinTwo)
    }

    func makeNSView(context: Context) -> CoinMenuPressView {
        let view = CoinMenuPressView()
        view.configure(
            coordinator: context.coordinator,
            canCoinTwo: canCoinTwo,
            canCoinMore: canCoinMore,
            onPrepare: onPrepare,
            onBlocked: onBlocked
        )
        return view
    }

    func updateNSView(_ nsView: CoinMenuPressView, context: Context) {
        context.coordinator.onCoinOne = onCoinOne
        context.coordinator.onCoinTwo = onCoinTwo
        nsView.configure(
            coordinator: context.coordinator,
            canCoinTwo: canCoinTwo,
            canCoinMore: canCoinMore,
            onPrepare: onPrepare,
            onBlocked: onBlocked
        )
    }

    final class Coordinator: NSObject {
        var onCoinOne: () -> Void
        var onCoinTwo: () -> Void

        init(onCoinOne: @escaping () -> Void, onCoinTwo: @escaping () -> Void) {
            self.onCoinOne = onCoinOne
            self.onCoinTwo = onCoinTwo
        }

        @objc func handleCoinOne(_ sender: NSMenuItem) {
            onCoinOne()
        }

        @objc func handleCoinTwo(_ sender: NSMenuItem) {
            onCoinTwo()
        }
    }
}

@MainActor
final class CoinMenuPressView: NSView {
    private let actionMenu = NSMenu()
    private weak var coordinator: CoinMenuPressOverlay.Coordinator?
    private var canCoinTwo = true
    private var canCoinMore = true
    private var onPrepare: (() -> Bool)?
    private var onBlocked: (() -> Void)?

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        guard canCoinMore else {
            onBlocked?()
            return
        }
        guard onPrepare?() == true else { return }
        guard !actionMenu.items.isEmpty else { return }

        let gapBelowButton: CGFloat = 10
        let anchor = NSPoint(x: bounds.midX, y: bounds.minY - gapBelowButton)
        actionMenu.popUp(positioning: nil, at: anchor, in: self)
    }

    func configure(
        coordinator: CoinMenuPressOverlay.Coordinator,
        canCoinTwo: Bool,
        canCoinMore: Bool,
        onPrepare: @escaping () -> Bool,
        onBlocked: @escaping () -> Void
    ) {
        self.coordinator = coordinator
        self.canCoinTwo = canCoinTwo
        self.canCoinMore = canCoinMore
        self.onPrepare = onPrepare
        self.onBlocked = onBlocked

        actionMenu.removeAllItems()

        let oneCoinItem = NSMenuItem(
            title: canCoinTwo ? "1 硬币" : "再投 1 硬币",
            action: #selector(CoinMenuPressOverlay.Coordinator.handleCoinOne(_:)),
            keyEquivalent: ""
        )
        oneCoinItem.target = coordinator
        oneCoinItem.image = Self.coinMenuIcon()
        actionMenu.addItem(oneCoinItem)

        if canCoinTwo {
            let twoCoinItem = NSMenuItem(
                title: "2 硬币",
                action: #selector(CoinMenuPressOverlay.Coordinator.handleCoinTwo(_:)),
                keyEquivalent: ""
            )
            twoCoinItem.target = coordinator
            twoCoinItem.image = Self.coinMenuIcon()
            actionMenu.addItem(twoCoinItem)
        }
    }

    private static func coinMenuIcon() -> NSImage? {
        NSImage(named: BiliIcon.coin.rawValue)
    }
}

struct BiliIconView: View {
    let icon: BiliIcon
    var color: Color = BiliTheme.actionInactive
    var size: CGFloat = 24

    var body: some View {
        Image(icon.rawValue)
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(color)
    }
}

struct BiliStatLabel: View {
    let icon: BiliIcon
    let value: String
    var iconSize: CGFloat = 20
    var font: Font = .callout

    private var iconColor: Color {
        switch icon {
        case .like:
            // 线框点赞图标描边较细，用略深颜色与播放/弹幕视觉对齐。
            Color(red: 115 / 255, green: 115 / 255, blue: 115 / 255)
        default:
            BiliTheme.actionInactive
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            BiliIconView(icon: icon, color: iconColor, size: iconSize)
            Text(value)
                .font(font)
                .foregroundStyle(.secondary)
        }
    }
}

struct VideoDetailActionBar: View {
    let likeCount: Int64
    let coinCount: Int64
    let favoriteCount: Int64
    let shareCount: Int64
    var liked = false
    var coined = false
    var favorited = false
    var canCoinTwo = true
    var canCoinMore = true
    var availableWidth: CGFloat = 320
    var onCoinTap: () -> Bool = { true }
    var onLikeClick: () -> Void = {}
    var onTripleClick: () -> Void = {}
    var onCoinBlocked: () -> Void = {}
    var onCoinOne: () -> Void = {}
    var onCoinTwo: () -> Void = {}
    var onFavoriteClick: () -> Void = {}
    var onShareClick: (ShareClickContext) -> Void = { _ in }

    @State private var holdProgress: CGFloat = 0

    private var metrics: VideoDetailActionBarMetrics {
        VideoDetailActionBarMetrics(width: availableWidth)
    }

    private let tripleHoldDuration: TimeInterval = 2

    var body: some View {
        HStack(spacing: metrics.columnSpacing) {
            actionColumn(
                icon: .likeFilled,
                label: likeCount.compactCount,
                tint: liked ? BiliTheme.blue : BiliTheme.actionInactive,
                ringProgress: holdProgress,
                onTap: onLikeClick,
                onLongPress: onTripleClick,
                onHoldProgress: updateHoldProgress
            )
            coinColumn
            actionColumn(
                icon: .favorite,
                label: favoriteCount.compactCount,
                tint: favorited ? BiliTheme.blue : BiliTheme.actionInactive,
                ringProgress: holdProgress,
                onTap: onFavoriteClick
            )
            shareColumn
        }
        .frame(maxWidth: .infinity)
        .clipped()
    }

    private func actionColumn(
        icon: BiliIcon,
        label: String,
        tint: Color,
        ringProgress: CGFloat,
        onTap: @escaping () -> Void,
        onLongPress: (() -> Void)? = nil,
        onHoldProgress: ((CGFloat) -> Void)? = nil
    ) -> some View {
        VideoDetailActionItem(horizontalPadding: metrics.itemPaddingH) {
            VStack(spacing: 4) {
                actionIconVisual(icon: icon, tint: tint, ringProgress: ringProgress)
                Text(label)
                    .font(.system(size: metrics.labelFontSize, weight: .medium))
                    .foregroundStyle(tint == BiliTheme.blue ? BiliTheme.blue : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
        } pressOverlay: {
            ActionPressOverlay(
                longPressDuration: tripleHoldDuration,
                onTap: onTap,
                onLongPress: onLongPress,
                onHoldProgress: onHoldProgress
            )
        }
    }

    private var shareColumn: some View {
        VideoDetailActionItem(horizontalPadding: metrics.itemPaddingH) {
            VStack(spacing: 4) {
                actionIconVisual(
                    icon: .share,
                    tint: BiliTheme.actionInactive,
                    ringProgress: 0
                )
                Text(shareCount.compactCount)
                    .font(.system(size: metrics.labelFontSize, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
        } pressOverlay: {
            ActionPressOverlay(
                onTap: {},
                onSharePresentation: onShareClick
            )
        }
    }

    private var coinColumn: some View {
        VideoDetailActionItem(horizontalPadding: metrics.itemPaddingH) {
            VStack(spacing: 4) {
                actionIconVisual(
                    icon: .coin,
                    tint: coined ? BiliTheme.blue : BiliTheme.actionInactive,
                    ringProgress: 0
                )
                Text(coinCount.compactCount)
                    .font(.system(size: metrics.labelFontSize, weight: .medium))
                    .foregroundStyle(coined ? BiliTheme.blue : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
        } pressOverlay: {
            CoinMenuPressOverlay(
                canCoinTwo: canCoinTwo,
                canCoinMore: canCoinMore,
                onPrepare: onCoinTap,
                onBlocked: onCoinBlocked,
                onCoinOne: onCoinOne,
                onCoinTwo: onCoinTwo
            )
        }
    }

    private func actionIconVisual(
        icon: BiliIcon,
        tint: Color,
        ringProgress: CGFloat
    ) -> some View {
        ZStack {
            if ringProgress > 0.02 {
                TripleHoldProgressRing(progress: ringProgress, size: metrics.ringSize)
            }
            BiliIconView(icon: icon, color: tint, size: metrics.iconSize)
        }
        .frame(width: metrics.ringSize, height: metrics.ringSize)
    }

    private func updateHoldProgress(_ progress: CGFloat) {
        holdProgress = progress
    }
}

private struct VideoDetailActionBarMetrics {
    let iconSize: CGFloat
    let ringSize: CGFloat
    let labelFontSize: CGFloat
    let columnSpacing: CGFloat
    let itemPaddingH: CGFloat

    init(width: CGFloat) {
        let innerWidth = max(width - AppLayout.videoDetailCardPadding * 2, 0)
        switch innerWidth {
        case ..<188:
            iconSize = 20
            ringSize = 28
            labelFontSize = 9
            columnSpacing = 2
            itemPaddingH = 3
        case ..<240:
            iconSize = 24
            ringSize = 34
            labelFontSize = 10
            columnSpacing = 3
            itemPaddingH = 4
        case ..<280:
            iconSize = 24
            ringSize = 36
            labelFontSize = 11
            columnSpacing = 4
            itemPaddingH = 4
        default:
            iconSize = 30
            ringSize = 44
            labelFontSize = 13
            columnSpacing = 8
            itemPaddingH = 6
        }
    }
}

private struct VideoDetailActionItem<Content: View, PressOverlay: View>: View {
    var showsChrome = false
    var horizontalPadding: CGFloat = 6
    @ViewBuilder var content: () -> Content
    @ViewBuilder var pressOverlay: () -> PressOverlay

    @State private var isHovered = false

    private var showsBackground: Bool {
        isHovered || showsChrome
    }

    var body: some View {
        content()
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 6)
            .frame(minWidth: 0, maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.black.opacity(0.04))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.black.opacity(0.08), lineWidth: 1)
                    }
                    .opacity(showsBackground ? 1 : 0)
            }
            .overlay {
                pressOverlay()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .animation(.easeOut(duration: 0.18), value: showsBackground)
            .onHover { isHovered = $0 }
    }
}

private struct ActionPressOverlay: NSViewRepresentable {
    var longPressDuration: TimeInterval = 2
    var onTap: () -> Void
    var onLongPress: (() -> Void)?
    var onHoldProgress: ((CGFloat) -> Void)?
    var onSharePresentation: ((ShareClickContext) -> Void)?

    func makeNSView(context: Context) -> ActionPressNSView {
        let view = ActionPressNSView()
        sync(view)
        return view
    }

    func updateNSView(_ nsView: ActionPressNSView, context: Context) {
        sync(nsView)
    }

    private func sync(_ view: ActionPressNSView) {
        view.longPressDuration = longPressDuration
        view.onTap = onTap
        view.onLongPress = onLongPress
        view.onHoldProgress = onHoldProgress
        view.onSharePresentation = onSharePresentation
    }
}

@MainActor
private final class ActionPressNSView: NSView {
    var longPressDuration: TimeInterval = 2
    var onTap: (() -> Void)?
    var onLongPress: (() -> Void)?
    var onHoldProgress: ((CGFloat) -> Void)?
    var onSharePresentation: ((ShareClickContext) -> Void)?

    private var holdTimer: Timer?
    private var downPoint = NSPoint.zero
    private var longPressFired = false
    private var holdStart: Date?

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        longPressFired = false
        downPoint = convert(event.locationInWindow, from: nil)
        holdStart = Date()
        if onLongPress != nil {
            startHoldTimer()
        }
    }

    override func mouseUp(with event: NSEvent) {
        let moved = dragDistance(for: event)
        let elapsed = holdStart.map { Date().timeIntervalSince($0) } ?? 0
        stopHoldTimer(resetProgress: true)
        holdStart = nil

        guard !longPressFired, moved < 12 else { return }
        guard onLongPress == nil || elapsed < 0.35 else { return }

        if let onSharePresentation {
            let context = ShareClickContext()
            context.sourceView = self
            context.locationInView = convert(event.locationInWindow, from: nil)
            onSharePresentation(context)
            onTap?()
            return
        }

        onTap?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragDistance(for: event) > 18 else { return }
        stopHoldTimer(resetProgress: true)
        holdStart = nil
    }

    private func dragDistance(for event: NSEvent) -> CGFloat {
        let current = convert(event.locationInWindow, from: nil)
        return hypot(current.x - downPoint.x, current.y - downPoint.y)
    }

    private func startHoldTimer() {
        stopHoldTimer(resetProgress: false)
        holdStart = Date()
        let timer = Timer(timeInterval: 1.0 / 60.0, target: self, selector: #selector(handleHoldTimer(_:)), userInfo: nil, repeats: true)
        holdTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func handleHoldTimer(_ timer: Timer) {
        guard let holdStart else {
            stopHoldTimer(resetProgress: true)
            return
        }
        let elapsed = Date().timeIntervalSince(holdStart)
        let progress = min(1, elapsed / max(0.1, longPressDuration))
        onHoldProgress?(CGFloat(progress))
        if progress >= 1 {
            longPressFired = true
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            onLongPress?()
            stopHoldTimer(resetProgress: true)
        }
    }

    private func stopHoldTimer(resetProgress: Bool) {
        holdTimer?.invalidate()
        holdTimer = nil
        if resetProgress {
            onHoldProgress?(0)
        }
    }
}

private struct TripleHoldProgressRing: View {
    let progress: CGFloat
    let size: CGFloat

    var body: some View {
        Circle()
            .trim(from: 0, to: progress.clamped(to: 0...1))
            .stroke(BiliTheme.pink, style: StrokeStyle(lineWidth: 2.5, lineCap: .butt))
            .rotationEffect(.degrees(-90))
            .frame(width: size, height: size)
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
