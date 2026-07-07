import AppKit
import SwiftUI

enum BiliTheme {
    static let blue = Color(red: 0, green: 174 / 255, blue: 236 / 255)
    static let blueHover = Color(red: 128 / 255, green: 210 / 255, blue: 245 / 255)
    static let pink = Color(red: 251 / 255, green: 114 / 255, blue: 153 / 255)
    static let actionInactive = Color(red: 153 / 255, green: 153 / 255, blue: 153 / 255)
    static let videoControlBorder = Color(red: 153 / 255, green: 153 / 255, blue: 153 / 255).opacity(0.5)

    static var actionInactiveNSColor: NSColor {
        NSColor(red: 153 / 255, green: 153 / 255, blue: 153 / 255, alpha: 1)
    }
}

enum BiliMenuPopUpAnchor {
    static let gapBelowButton: CGFloat = 10

    static func popUp(_ menu: NSMenu, in view: NSView) {
        let menuWidth = max(menu.minimumWidth, fittedWidth(for: menu))
        if menuWidth > 0 {
            menu.minimumWidth = menuWidth
        }
        let bounds = view.bounds
        let point = NSPoint(
            x: bounds.midX - menuWidth / 2,
            y: bounds.minY - gapBelowButton
        )
        menu.popUp(positioning: nil, at: point, in: view)
    }

    private static func fittedWidth(for menu: NSMenu) -> CGFloat {
        let font = NSFont.menuFont(ofSize: NSFont.systemFontSize)
        return menu.items.reduce(0) { width, item in
            if let itemView = item.view {
                return max(width, ceil(itemView.fittingSize.width))
            }
            if let attributedTitle = item.attributedTitle, attributedTitle.length > 0 {
                let textWidth = (attributedTitle.string as NSString).size(withAttributes: [.font: font]).width
                let chrome: CGFloat = item.image == nil ? 28 : 48
                return max(width, ceil(textWidth + chrome))
            }
            let textWidth = (item.title as NSString).size(withAttributes: [.font: font]).width
            let chrome: CGFloat = item.image == nil ? 28 : 48
            return max(width, ceil(textWidth + chrome))
        }
    }
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
        BiliMenuPopUpAnchor.popUp(actionMenu, in: self)
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

struct VideoPartMenuPressOverlay: NSViewRepresentable {
    let pages: [BiliVideoPage]
    let activeCID: Int64
    let onSelect: (BiliVideoPage) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect)
    }

    func makeNSView(context: Context) -> VideoPartMenuPressView {
        let view = VideoPartMenuPressView()
        view.configure(
            coordinator: context.coordinator,
            pages: pages,
            activeCID: activeCID
        )
        return view
    }

    func updateNSView(_ nsView: VideoPartMenuPressView, context: Context) {
        context.coordinator.onSelect = onSelect
        nsView.configure(
            coordinator: context.coordinator,
            pages: pages,
            activeCID: activeCID
        )
    }

    final class Coordinator: NSObject {
        var pages: [BiliVideoPage] = []
        var onSelect: (BiliVideoPage) -> Void

        init(onSelect: @escaping (BiliVideoPage) -> Void) {
            self.onSelect = onSelect
        }

        @objc func handleSelect(_ sender: NSMenuItem) {
            let index = sender.tag
            guard pages.indices.contains(index) else { return }
            onSelect(pages[index])
        }
    }
}

@MainActor
final class VideoPartMenuPressView: NSView {
    private let actionMenu = NSMenu()
    private weak var coordinator: VideoPartMenuPressOverlay.Coordinator?

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        guard !actionMenu.items.isEmpty else { return }
        BiliMenuPopUpAnchor.popUp(actionMenu, in: self)
    }

    func configure(
        coordinator: VideoPartMenuPressOverlay.Coordinator,
        pages: [BiliVideoPage],
        activeCID: Int64
    ) {
        self.coordinator = coordinator
        coordinator.pages = pages

        actionMenu.removeAllItems()
        actionMenu.autoenablesItems = false

        let menuWidth = fittedEpisodeMenuWidth(for: pages)
        actionMenu.minimumWidth = menuWidth

        for (index, part) in pages.enumerated() {
            let item = NSMenuItem(
                title: "",
                action: #selector(VideoPartMenuPressOverlay.Coordinator.handleSelect(_:)),
                keyEquivalent: ""
            )
            item.attributedTitle = episodeMenuAttributedTitle(for: part, menuWidth: menuWidth)
            item.target = coordinator
            item.tag = index
            item.isEnabled = true
            if part.cid == activeCID {
                item.state = .on
            }
            actionMenu.addItem(item)
        }
    }

    private func fittedEpisodeMenuWidth(for pages: [BiliVideoPage]) -> CGFloat {
        let menuFont = NSFont.menuFont(ofSize: NSFont.systemFontSize)
        var width: CGFloat = 260

        for part in pages {
            let title = episodeMainTitle(for: part)
            let titleWidth = (title as NSString).size(withAttributes: [.font: menuFont]).width
            let durationWidth = part.duration > 0
                ? (part.duration.episodeMenuDurationText as NSString).size(withAttributes: [.font: menuFont]).width
                : 0
            width = max(width, titleWidth + durationWidth + 44)
        }

        return min(ceil(width), 460)
    }

    private func episodeMainTitle(for part: BiliVideoPage) -> String {
        let title = part.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = title.isEmpty ? "第\(part.page)话" : title
        return "\(part.page)  \(label)"
    }

    private func episodeMenuAttributedTitle(for part: BiliVideoPage, menuWidth: CGFloat) -> NSAttributedString {
        let font = NSFont.menuFont(ofSize: NSFont.systemFontSize)
        let mainTitle = episodeMainTitle(for: part)
        guard part.duration > 0 else {
            return NSAttributedString(string: mainTitle, attributes: [.font: font])
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [
            NSTextTab(textAlignment: .right, location: max(menuWidth - 16, 180), options: [:])
        ]
        let text = "\(mainTitle)\t\(part.duration.episodeMenuDurationText)"
        return NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .paragraphStyle: paragraph,
            ]
        )
    }
}

private extension Int {
    var episodeMenuDurationText: String {
        guard self > 0 else { return "" }
        let hours = self / 3600
        let minutes = (self % 3600) / 60
        let seconds = self % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

struct AuthorFollowButton: View {
    let isFollowing: Bool
    var followerMe = false
    let followerCount: Int64
    let isLoading: Bool
    var showsFollowerCount = true
    var overlayOnCover = false
    var coverIsLight = true
    var usesProfileChromeSizing = false
    var fixedCapsuleHeight: CGFloat?
    let onFollow: () -> Void
    let onUnfollow: () -> Void

    @State private var isHovered = false

    private var fontSize: CGFloat {
        usesProfileChromeSizing ? 14 : 12
    }

    private var horizontalPadding: CGFloat {
        usesProfileChromeSizing ? 16 : 10
    }

    private var verticalPadding: CGFloat {
        usesProfileChromeSizing ? 9 : 6
    }

    private var followLabel: String {
        if isFollowing && followerMe { return "互相关注" }
        if isFollowing { return "已关注" }
        return "+ 关注"
    }

    var body: some View {
        ZStack {
            HStack(spacing: usesProfileChromeSizing ? 8 : 6) {
                Text(followLabel)
                if showsFollowerCount {
                    Text(followerCount.compactCount)
                        .monospacedDigit()
                }
            }
            .font(.system(size: fontSize, weight: .semibold))
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, fixedCapsuleHeight == nil ? verticalPadding : 0)
            .frame(height: fixedCapsuleHeight)
            .background(backgroundColor, in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .stroke(borderColor, lineWidth: 0.5)
            }
            .foregroundStyle(foregroundColor)
            .contentTransition(.interpolate)
            .animation(.easeInOut(duration: 0.2), value: isFollowing)
            .animation(.easeInOut(duration: 0.2), value: followerMe)
            .animation(.easeInOut(duration: 0.18), value: isHovered)
            .allowsHitTesting(!isLoading)

            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }

            if isFollowing {
                AuthorUnfollowMenuOverlay(onUnfollow: onUnfollow)
            } else {
                AuthorFollowTapOverlay(onFollow: onFollow)
            }
        }
        .fixedSize()
        .onHover { isHovered = $0 }
    }

    private var foregroundColor: Color {
        if isFollowing {
            if overlayOnCover && !coverIsLight {
                return Color(red: 224 / 255, green: 224 / 255, blue: 224 / 255)
            }
            return Color(red: 117 / 255, green: 117 / 255, blue: 117 / 255)
        }
        if overlayOnCover && !coverIsLight {
            return BiliTheme.blue
        }
        return isHovered ? BiliTheme.blueHover : BiliTheme.blue
    }

    private var backgroundColor: Color {
        if isFollowing {
            if overlayOnCover && !coverIsLight {
                return Color.white.opacity(0.92)
            }
            return Color(red: 245 / 255, green: 245 / 255, blue: 245 / 255)
        }
        if overlayOnCover && !coverIsLight {
            return Color.white.opacity(isHovered ? 0.98 : 0.94)
        }
        if overlayOnCover && coverIsLight {
            return isHovered ? BiliTheme.blue.opacity(0.18) : Color.white.opacity(0.92)
        }
        return isHovered ? BiliTheme.blue.opacity(0.16) : BiliTheme.blue.opacity(0.1)
    }

    private var borderColor: Color {
        if isFollowing {
            if overlayOnCover && !coverIsLight {
                return Color.white.opacity(0.35)
            }
            return Color.black.opacity(0.06)
        }
        if overlayOnCover && !coverIsLight {
            return Color.white.opacity(isHovered ? 0.55 : 0.42)
        }
        if overlayOnCover && coverIsLight {
            return Color.black.opacity(isHovered ? 0.1 : 0.06)
        }
        return isHovered ? BiliTheme.blueHover.opacity(0.45) : BiliTheme.blue.opacity(0.22)
    }
}

private struct AuthorFollowTapOverlay: NSViewRepresentable {
    let onFollow: () -> Void

    func makeNSView(context: Context) -> AuthorFollowTapView {
        let view = AuthorFollowTapView()
        view.onFollow = onFollow
        return view
    }

    func updateNSView(_ nsView: AuthorFollowTapView, context: Context) {
        nsView.onFollow = onFollow
    }
}

@MainActor
private final class AuthorFollowTapView: NSView {
    var onFollow: (() -> Void)?

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        onFollow?()
    }
}

private struct AuthorUnfollowMenuOverlay: NSViewRepresentable {
    let onUnfollow: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onUnfollow: onUnfollow)
    }

    func makeNSView(context: Context) -> AuthorUnfollowMenuView {
        let view = AuthorUnfollowMenuView()
        view.configure(coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: AuthorUnfollowMenuView, context: Context) {
        nsView.configure(coordinator: context.coordinator)
    }

    final class Coordinator: NSObject {
        var onUnfollow: () -> Void

        init(onUnfollow: @escaping () -> Void) {
            self.onUnfollow = onUnfollow
        }

        @objc func handleUnfollow(_ sender: NSMenuItem) {
            onUnfollow()
        }
    }
}

@MainActor
private final class AuthorUnfollowMenuView: NSView {
    private let actionMenu = NSMenu()
    private weak var coordinator: AuthorUnfollowMenuOverlay.Coordinator?

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        guard !actionMenu.items.isEmpty else { return }
        BiliMenuPopUpAnchor.popUp(actionMenu, in: self)
    }

    func configure(coordinator: AuthorUnfollowMenuOverlay.Coordinator) {
        self.coordinator = coordinator
        actionMenu.removeAllItems()

        let unfollowItem = NSMenuItem(
            title: "取消关注",
            action: #selector(AuthorUnfollowMenuOverlay.Coordinator.handleUnfollow(_:)),
            keyEquivalent: ""
        )
        unfollowItem.target = coordinator
        actionMenu.addItem(unfollowItem)
    }
}

struct BiliIconView: View {
    let icon: BiliIcon
    var color: Color = BiliTheme.actionInactive
    var size: CGFloat = 24
    var symbolScale: CGFloat = 1

    var body: some View {
        Image(icon.rawValue)
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .scaledToFit()
            .frame(width: size, height: size)
            .scaleEffect(symbolScale)
            .foregroundStyle(color)
    }
}

enum BiliRasterIconCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 96
        return cache
    }()

    static func image(icon: BiliIcon, size: CGFloat, color: NSColor, symbolScale: CGFloat) -> NSImage {
        let pointSize = max(1, size)
        let key = "v2#\(icon.rawValue)#\(Int(pointSize * 100))#\(Int(symbolScale * 100))#\(color.hash)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }

        guard let template = NSImage(named: icon.rawValue) else {
            return NSImage(size: NSSize(width: pointSize, height: pointSize))
        }
        template.isTemplate = true

        let drawSize = pointSize * max(0.1, symbolScale)
        let inset = (pointSize - drawSize) / 2
        let destRect = NSRect(x: inset, y: inset, width: drawSize, height: drawSize)
        let sourceRect = NSRect(origin: .zero, size: template.size)

        let image = NSImage(size: NSSize(width: pointSize, height: pointSize))
        image.lockFocus()
        color.set()
        destRect.fill()
        template.draw(in: destRect, from: sourceRect, operation: .destinationIn, fraction: 1.0)
        image.unlockFocus()

        cache.setObject(image, forKey: key)
        return image
    }
}

struct BiliStatLabel: View {
    let icon: BiliIcon
    let value: String
    var iconSize: CGFloat = 20
    var font: Font = .callout

    private var iconColor: Color {
        .secondary
    }

    private var iconSymbolScale: CGFloat {
        icon == .like ? 1.04 : 1
    }

    var body: some View {
        HStack(spacing: 4) {
            BiliIconView(icon: icon, color: iconColor, size: iconSize, symbolScale: iconSymbolScale)
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
    @Binding var coinHintMessage: String?
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
        HStack(alignment: .top, spacing: metrics.columnSpacing) {
            actionColumn(
                icon: .likeFilled,
                label: likeCount.compactCount,
                isActive: liked,
                ringProgress: holdProgress,
                onTap: onLikeClick,
                onLongPress: onTripleClick,
                onHoldProgress: updateHoldProgress
            )
            coinColumn
            actionColumn(
                icon: .favorite,
                label: favoriteCount.compactCount,
                isActive: favorited,
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
        isActive: Bool,
        ringProgress: CGFloat,
        onTap: @escaping () -> Void,
        onLongPress: (() -> Void)? = nil,
        onHoldProgress: ((CGFloat) -> Void)? = nil
    ) -> some View {
        VideoDetailActionItem(horizontalPadding: metrics.itemPaddingH) { isHovered in
            let tint = isActive || isHovered ? BiliTheme.blue : Color.secondary
            VStack(spacing: 4) {
                actionIconVisual(icon: icon, tint: tint, ringProgress: ringProgress)
                Text(label)
                    .font(.system(size: metrics.labelFontSize, weight: .medium))
                    .foregroundStyle(tint)
                    .contentTransition(.interpolate)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .animation(.easeInOut(duration: 0.18), value: isHovered)
            .animation(.easeInOut(duration: 0.18), value: isActive)
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
        VideoDetailActionItem(horizontalPadding: metrics.itemPaddingH) { isHovered in
            let tint = isHovered ? BiliTheme.blue : Color.secondary
            VStack(spacing: 4) {
                actionIconVisual(
                    icon: .share,
                    tint: tint,
                    ringProgress: 0
                )
                Text(shareCount.compactCount)
                    .font(.system(size: metrics.labelFontSize, weight: .medium))
                    .foregroundStyle(tint)
                    .contentTransition(.interpolate)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .animation(.easeInOut(duration: 0.18), value: isHovered)
        } pressOverlay: {
            ActionPressOverlay(
                onTap: {},
                onSharePresentation: onShareClick
            )
        }
    }

    private var coinColumn: some View {
        VStack(spacing: 2) {
            VideoDetailActionItem(horizontalPadding: metrics.itemPaddingH) { isHovered in
                let tint = coined || isHovered ? BiliTheme.blue : Color.secondary
                VStack(spacing: 4) {
                    actionIconVisual(
                        icon: .coin,
                        tint: tint,
                        ringProgress: 0
                    )
                    Text(coinCount.compactCount)
                        .font(.system(size: metrics.labelFontSize, weight: .medium))
                        .foregroundStyle(tint)
                        .contentTransition(.interpolate)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .frame(maxWidth: .infinity)
                .animation(.easeInOut(duration: 0.18), value: isHovered)
                .animation(.easeInOut(duration: 0.18), value: coined)
            } pressOverlay: {
                if canCoinMore {
                    CoinMenuPressOverlay(
                        canCoinTwo: canCoinTwo,
                        canCoinMore: canCoinMore,
                        onPrepare: onCoinTap,
                        onBlocked: onCoinBlocked,
                        onCoinOne: onCoinOne,
                        onCoinTwo: onCoinTwo
                    )
                } else {
                    ActionPressOverlay(onTap: onCoinBlocked)
                }
            }

            if let message = coinHintMessage, !message.isEmpty {
                VideoDetailCoinHint(message: message)
                    .frame(maxWidth: .infinity)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.2), value: coinHintMessage)
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

private struct VideoDetailCoinHint: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.caption.weight(.medium))
            .foregroundStyle(.primary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.black.opacity(0.08), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.1), radius: 8, y: 3)
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
    @ViewBuilder var content: (_ isHovered: Bool) -> Content
    @ViewBuilder var pressOverlay: () -> PressOverlay

    @State private var isHovered = false

    private var showsBackground: Bool {
        isHovered || showsChrome
    }

    var body: some View {
        content(isHovered)
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
