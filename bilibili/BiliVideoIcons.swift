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

struct CoinIconFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next.width > 0, next.height > 0 {
            value = next
        }
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
    @Binding var coinMenuPresented: Bool
    var onCoinTap: () -> Bool = { true }
    var onLikeClick: () -> Void = {}
    var onTripleClick: () -> Void = {}
    var onCoinBlocked: () -> Void = {}
    var onFavoriteClick: () -> Void = {}
    var onShareClick: (ShareClickContext) -> Void = { _ in }

    @State private var holdProgress: CGFloat = 0

    private let iconSize: CGFloat = 30
    private let ringSize: CGFloat = 44
    private let labelFontSize: CGFloat = 13
    private let tripleHoldDuration: TimeInterval = 2

    var body: some View {
        HStack(spacing: 8) {
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
                onTap: {
                    dismissCoinMenu()
                    onFavoriteClick()
                }
            )
            shareColumn
        }
    }

    private var shareColumn: some View {
        VideoDetailActionItem {
            VStack(spacing: 4) {
                actionIconStack(
                    icon: .share,
                    tint: BiliTheme.actionInactive,
                    ringProgress: 0,
                    onTap: { dismissCoinMenu() },
                    onSharePresentation: onShareClick
                )
                Text(shareCount.compactCount)
                    .font(.system(size: labelFontSize, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var coinColumn: some View {
        VideoDetailActionItem(showsChrome: coinMenuPresented) {
            VStack(spacing: 4) {
                actionIconStack(
                    icon: .coin,
                    tint: coined ? BiliTheme.blue : BiliTheme.actionInactive,
                    ringProgress: holdProgress,
                    onTap: toggleCoinMenu
                )
                .background {
                    GeometryReader { geo in
                        Color.clear
                            .preference(
                                key: CoinIconFrameKey.self,
                                value: geo.frame(in: .named("detailPane"))
                            )
                    }
                }
                Text(coinCount.compactCount)
                    .font(.system(size: labelFontSize, weight: .medium))
                    .foregroundStyle(coined ? BiliTheme.blue : .primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
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
        VideoDetailActionItem {
            VStack(spacing: 4) {
                actionIconStack(
                    icon: icon,
                    tint: tint,
                    ringProgress: ringProgress,
                    onTap: {
                        dismissCoinMenu()
                        onTap()
                    },
                    onLongPress: onLongPress,
                    onHoldProgress: onHoldProgress
                )
                Text(label)
                    .font(.system(size: labelFontSize, weight: .medium))
                    .foregroundStyle(tint == BiliTheme.blue ? BiliTheme.blue : .primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func actionIconStack(
        icon: BiliIcon,
        tint: Color,
        ringProgress: CGFloat,
        onTap: @escaping () -> Void,
        onLongPress: (() -> Void)? = nil,
        onHoldProgress: ((CGFloat) -> Void)? = nil,
        onSharePresentation: ((ShareClickContext) -> Void)? = nil
    ) -> some View {
        ZStack {
            if ringProgress > 0.02 {
                TripleHoldProgressRing(progress: ringProgress, size: ringSize)
            }
            BiliIconView(icon: icon, color: tint, size: iconSize)
            ActionPressOverlay(
                longPressDuration: tripleHoldDuration,
                onTap: onTap,
                onLongPress: onLongPress,
                onHoldProgress: onHoldProgress,
                onSharePresentation: onSharePresentation
            )
        }
        .frame(width: ringSize, height: ringSize)
    }

    private func toggleCoinMenu() {
        guard canCoinMore else {
            onCoinBlocked()
            return
        }
        guard onCoinTap() else { return }
        coinMenuPresented.toggle()
    }

    private func dismissCoinMenu() {
        if coinMenuPresented {
            coinMenuPresented = false
        }
    }

    private func updateHoldProgress(_ progress: CGFloat) {
        holdProgress = progress
    }
}

private struct VideoDetailActionItem<Content: View>: View {
    var showsChrome = false
    @ViewBuilder var content: () -> Content

    @State private var isHovered = false

    private var showsBackground: Bool {
        isHovered || showsChrome
    }

    var body: some View {
        content()
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.black.opacity(0.04))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.black.opacity(0.08), lineWidth: 1)
                    }
                    .opacity(showsBackground ? 1 : 0)
            }
            .animation(.easeOut(duration: 0.18), value: showsBackground)
            .onHover { isHovered = $0 }
    }
}

struct VideoCoinChoiceMenu: View {
    let canCoinTwo: Bool
    let onCoinOne: () -> Void
    let onCoinTwo: () -> Void

    var body: some View {
        VStack(spacing: 3) {
            coinMenuRow(canCoinTwo ? "1 硬币" : "再投 1 硬币", action: onCoinOne)
            if canCoinTwo {
                coinMenuRow("2 硬币", action: onCoinTwo)
            }
        }
        .fixedSize(horizontal: true, vertical: true)
        .glassActionMenuPanel()
    }

    private func coinMenuRow(_ title: String, action: @escaping () -> Void) -> some View {
        ActionPressLabel(title: title, action: action)
            .frame(height: 34)
            .padding(.horizontal, 14)
            .background(Color.primary.opacity(0.04), in: Capsule())
    }
}

private struct ActionPressLabel: View {
    let title: String
    let action: () -> Void

    var body: some View {
        ZStack {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: true, vertical: false)
            ActionPressOverlay(onTap: action)
        }
        .contentShape(Capsule())
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
