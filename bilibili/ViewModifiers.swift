import AppKit
import SwiftUI

struct SearchUserResultLayout: Equatable {
    let columnCount: Int
    let capsuleWidth: CGFloat
    let gridWidth: CGFloat

    var usesTwoColumns: Bool { columnCount >= 2 }
}

enum AppLayout {
    static let sidebarWidth: CGFloat = 188
    static let sidebarNavTopInset: CGFloat = 52
    static let floatingChromeInset: CGFloat = 20
    static let floatingChromeButtonSize: CGFloat = 32
    static let floatingChromeBottomSpacing: CGFloat = 12
    static let pageHorizontalInset: CGFloat = 20
    static let feedHorizontalInset: CGFloat = 16
    static let feedVerticalInset: CGFloat = 28
    static let mainContentPadding: CGFloat = 40
    static let mainContentPaddingCompact: CGFloat = 24
    static let searchPageMaxWidth: CGFloat = 1040
    static let searchPageWideBreakpoint: CGFloat = 1440
    static let searchPageCompactBreakpoint: CGFloat = 900
    static let searchBarPreferredWidth: CGFloat = 440
    static let searchBarMinWidth: CGFloat = 360
    static let searchBarHeight: CGFloat = 42
    static let searchHeaderSpacing: CGFloat = 10
    static let searchTypeToggleWidth: CGFloat = 132
    static let searchSuggestionPanelWidth: CGFloat = 760
    static let searchSuggestionPanelMaxHeight: CGFloat = 520
    static let searchDiscoveryContentWidth: CGFloat = 620
    static let searchUserResultCapsuleWidth: CGFloat = 560
    static let searchUserResultCapsuleHeight: CGFloat = 104
    static let searchUserResultColumnSpacing: CGFloat = 12
    static let searchUserResultsHorizontalInset: CGFloat = 32

    static func searchUserResultLayout(contentWidth: CGFloat) -> SearchUserResultLayout {
        let minWidthForTwoColumns = searchUserResultCapsuleWidth * 2 + searchUserResultColumnSpacing
        if contentWidth >= minWidthForTwoColumns {
            let columnWidth = (contentWidth - searchUserResultColumnSpacing) / 2
            let gridWidth = columnWidth * 2 + searchUserResultColumnSpacing
            return SearchUserResultLayout(
                columnCount: 2,
                capsuleWidth: columnWidth,
                gridWidth: gridWidth
            )
        }
        let capsuleWidth = min(searchUserResultCapsuleWidth, contentWidth)
        return SearchUserResultLayout(
            columnCount: 1,
            capsuleWidth: capsuleWidth,
            gridWidth: capsuleWidth
        )
    }

    static var searchHeaderGroupWidth: CGFloat {
        searchBarPreferredWidth + searchHeaderSpacing + searchTypeToggleWidth
    }

    static func searchSuggestionPanelWidth(for contentWidth: CGFloat) -> CGFloat {
        min(
            searchSuggestionPanelWidth,
            max(searchBarPreferredWidth, contentWidth)
        )
    }

    /// 搜索框顶部与浮动返回/刷新按钮顶部对齐。
    static var searchBarTopOffset: CGFloat {
        floatingChromeInset
    }
    static let sidebarBackground = Color(red: 0.969, green: 0.969, blue: 0.973)
    static let sidebarBlurWhiteTint: CGFloat = 0.42
    static let sidebarBlurMaterial: NSVisualEffectView.Material = .sidebar
    static let sidebarSelectionCornerRadius: CGFloat = 10
    static let sidebarNavItemHeight: CGFloat = 42
    static let sidebarSelectionFill = BiliTheme.pink.opacity(0.12)
    static let sidebarHoverFill = Color.black.opacity(0.04)
    static let searchSurfaceBorder = Color.black.opacity(0.06)
    static let searchChipFill = Color.black.opacity(0.05)
    static let searchChipHoverFill = Color.black.opacity(0.08)
    static let searchRowHoverFill = Color.black.opacity(0.03)

    static var floatingChromeReservedHeight: CGFloat {
        floatingChromeInset + floatingChromeButtonSize + floatingChromeBottomSpacing
    }

    static var videoDetailChromeReservedHeight: CGFloat {
        floatingChromeReservedHeight + 48
    }

    /// 竖屏长标题需要更多顶部留白，避免与播放器、右侧信息重叠。
    static var videoDetailPortraitChromeReservedHeight: CGFloat {
        floatingChromeReservedHeight + 56
    }

    /// 右侧简介栏顶部留白；横屏时与标题区错层，竖屏时与播放器同步下移。
    static var videoDetailRightColumnTopInset: CGFloat {
        videoDetailPlayerTopInset
    }

    /// 播放器顶部留白：避开浮动返回栏与标题，略低于标题底边。
    static var videoDetailPlayerTopInset: CGFloat {
        floatingChromeReservedHeight + 22
    }

    static let videoDetailPageBackground = Color(red: 0.961, green: 0.963, blue: 0.969)
    static let videoDetailCardCornerRadius: CGFloat = 12
    static let videoDetailCardPadding: CGFloat = 16
    static let videoDetailLeadingInset: CGFloat = 12
    static let videoDetailTrailingInset: CGFloat = 16
    static let videoDetailSectionSpacing: CGFloat = 8
    static let videoDetailSidebarMinWidth: CGFloat = 260
    static let videoDetailSidebarMinContentWidth: CGFloat = 200
    static let videoDetailSidebarWidthRatio: CGFloat = 0.28
    static let videoDetailSidebarMaxWidthRatio: CGFloat = 0.36
    static let videoDetailChromeBottomSpacing: CGFloat = 10

    static func videoDetailSidebarWidth(in availableWidth: CGFloat) -> CGFloat {
        guard availableWidth > 0 else { return 0 }
        let adaptiveMin = min(videoDetailSidebarMinWidth, availableWidth * 0.42)
        let target = availableWidth * videoDetailSidebarWidthRatio
        let preferred = max(target, adaptiveMin)
        let maxWidth = max(availableWidth * videoDetailSidebarMaxWidthRatio, preferred)
        return min(preferred, maxWidth, availableWidth)
    }

    static func videoDetailColumnWidths(in totalWidth: CGFloat) -> (player: CGFloat, sidebar: CGFloat) {
        let horizontalPadding = videoDetailLeadingInset + videoDetailTrailingInset
        let contentWidth = max(totalWidth - horizontalPadding, 0)
        guard contentWidth > videoDetailSectionSpacing else { return (0, 0) }

        let columnsWidth = contentWidth - videoDetailSectionSpacing
        guard columnsWidth > 0 else { return (0, 0) }

        let minPlayerWidth: CGFloat = 180
        var sidebar = min(videoDetailSidebarWidth(in: columnsWidth), columnsWidth)
        var player = columnsWidth - sidebar

        let contentMin = min(videoDetailSidebarMinContentWidth, columnsWidth)
        if sidebar < contentMin, columnsWidth - contentMin >= minPlayerWidth {
            sidebar = contentMin
            player = columnsWidth - sidebar
        } else if player < minPlayerWidth, columnsWidth > minPlayerWidth {
            sidebar = max(columnsWidth - minPlayerWidth, columnsWidth * videoDetailSidebarWidthRatio)
            player = columnsWidth - sidebar
        }

        return (max(0, player), max(0, sidebar))
    }

    static func videoDetailPlayerTopInset(chromeHeight: CGFloat) -> CGFloat {
        let baseline = videoDetailPlayerTopInset
        guard chromeHeight > 0 else { return baseline }
        return max(baseline, chromeHeight + videoDetailChromeBottomSpacing)
    }
}

struct VideoDetailChromeMeasuredHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct VideoDetailChromeHeightEnvironmentKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var videoDetailChromeHeight: CGFloat {
        get { self[VideoDetailChromeHeightEnvironmentKey.self] }
        set { self[VideoDetailChromeHeightEnvironmentKey.self] = newValue }
    }
}

struct GlassCircleButton: View {
    let systemImage: String
    var size: CGFloat = 32
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            GlassCircleIcon(systemImage: systemImage, size: size, isHovered: isHovered)
        }
        .buttonStyle(GlassCircleButtonStyle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.18)) {
                isHovered = hovering
            }
        }
    }
}

struct GlassCircleIcon: View {
    let systemImage: String
    var size: CGFloat = 32
    var isHovered = false

    var body: some View {
        ZStack {
            Circle()
                .fill(isHovered ? Color.black.opacity(0.08) : Color.white.opacity(0.92))

            Image(systemName: systemImage)
                .font(.system(size: size * 0.41, weight: .semibold))
                .foregroundStyle(.primary)
        }
        .frame(width: size, height: size)
        .overlay {
            Circle().stroke(Color.black.opacity(0.08), lineWidth: 0.6)
        }
        .shadow(color: .black.opacity(0.08), radius: 10, x: 0, y: 4)
    }
}

private struct GlassCircleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

private extension AnyTransition {
    static var glassBackButton: AnyTransition {
        .opacity
    }

    static var glassRefreshButton: AnyTransition {
        .asymmetric(
            insertion: .opacity
                .combined(with: .offset(x: 10))
                .combined(with: .scale(scale: 0.86, anchor: .center)),
            removal: .opacity
                .combined(with: .offset(x: 8))
                .combined(with: .scale(scale: 0.92, anchor: .center))
        )
    }

    static var glassMoreButton: AnyTransition {
        glassRefreshButton
    }
}

struct GlassBackButton: View {
    let action: () -> Void

    var body: some View {
        GlassCircleButton(systemImage: "chevron.left", action: action)
            .transition(.glassBackButton)
    }
}

struct GlassRefreshButton: View {
    let action: () -> Void

    var body: some View {
        GlassCircleButton(systemImage: "arrow.clockwise", action: action)
            .transition(.glassRefreshButton)
    }
}

struct GlassMoreButton: View {
    let webURL: URL

    var body: some View {
        GlassMorePopUpButtonRepresentable(webURL: webURL)
            .frame(width: AppLayout.floatingChromeButtonSize, height: AppLayout.floatingChromeButtonSize)
            .transition(.glassMoreButton)
    }
}

struct GlassMorePopUpButtonRepresentable: NSViewRepresentable {
    let webURL: URL

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> GlassMorePopUpButtonView {
        let view = GlassMorePopUpButtonView()
        view.configure(webURL: webURL, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: GlassMorePopUpButtonView, context: Context) {
        nsView.configure(webURL: webURL, coordinator: context.coordinator)
    }

    final class Coordinator: NSObject {
        var webURL: URL?

        @objc func openInBrowser(_ sender: NSMenuItem) {
            guard let webURL else { return }
            NSWorkspace.shared.open(webURL)
        }
    }
}

final class GlassMorePopUpButtonView: NSView, NSMenuDelegate {
    private let iconView = NSImageView()
    private let actionMenu = NSMenu()
    private weak var coordinator: GlassMorePopUpButtonRepresentable.Coordinator?
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        nil
    }

    private func setup() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleNone
        iconView.imageAlignment = .alignCenter
        iconView.isEditable = false
        iconView.animates = false

        addSubview(iconView)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: AppLayout.floatingChromeButtonSize),
            heightAnchor.constraint(equalToConstant: AppLayout.floatingChromeButtonSize),
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: AppLayout.floatingChromeButtonSize),
            iconView.heightAnchor.constraint(equalToConstant: AppLayout.floatingChromeButtonSize),
        ])

        wantsLayer = true
        layer?.cornerRadius = AppLayout.floatingChromeButtonSize / 2
        iconView.image = Self.makeMoreIconImage()
        updateChromeBackground(hovered: false)
    }

    override func mouseDown(with event: NSEvent) {
        guard !actionMenu.items.isEmpty else { return }
        let gapBelowButton: CGFloat = 10
        let anchor = NSPoint(x: bounds.midX, y: bounds.minY - gapBelowButton)
        actionMenu.popUp(positioning: nil, at: anchor, in: self)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    func configure(webURL: URL, coordinator: GlassMorePopUpButtonRepresentable.Coordinator) {
        self.coordinator = coordinator
        coordinator.webURL = webURL

        actionMenu.removeAllItems()
        actionMenu.delegate = self

        let openItem = NSMenuItem(
            title: "在浏览器中打开",
            action: #selector(GlassMorePopUpButtonRepresentable.Coordinator.openInBrowser(_:)),
            keyEquivalent: ""
        )
        openItem.target = coordinator
        openItem.image = NSImage(systemSymbolName: "safari", accessibilityDescription: nil)
        actionMenu.addItem(openItem)

        toolTip = "更多"
    }

    private static func makeMoreIconImage() -> NSImage {
        let buttonSize = AppLayout.floatingChromeButtonSize
        let image = NSImage(size: NSSize(width: buttonSize, height: buttonSize))
        image.lockFocus()

        let dotRadius: CGFloat = 2.1
        let spacing: CGFloat = 4.6
        let center = CGPoint(x: buttonSize / 2, y: buttonSize / 2)
        NSColor.labelColor.setFill()
        for offset in [-spacing, 0, spacing] {
            let rect = NSRect(
                x: center.x + offset - dotRadius,
                y: center.y - dotRadius,
                width: dotRadius * 2,
                height: dotRadius * 2
            )
            NSBezierPath(ovalIn: rect).fill()
        }

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {}

    func menuWillOpen(_ menu: NSMenu) {}

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        updateChromeBackground(hovered: true)
    }

    override func mouseExited(with event: NSEvent) {
        updateChromeBackground(hovered: false)
    }

    private func updateChromeBackground(hovered: Bool) {
        let fill: NSColor = hovered
            ? NSColor.black.withAlphaComponent(0.08)
            : NSColor.white.withAlphaComponent(0.92)
        layer?.backgroundColor = fill.cgColor
        layer?.borderColor = NSColor.black.withAlphaComponent(0.08).cgColor
        layer?.borderWidth = 0.6
        layer?.shadowColor = NSColor.black.withAlphaComponent(0.08).cgColor
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -4)
    }
}

struct AppScrollView<Content: View>: View {
    @ViewBuilder private var content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        ScrollView {
            content()
                .padding(.horizontal, AppLayout.feedHorizontalInset)
                .padding(.vertical, AppLayout.feedVerticalInset)
        }
        .scrollClipDisabled()
        .background(MacOverlayScrollConfigurator())
    }
}

struct MacOverlayScrollView<Content: View>: View {
    var usesOverlayScrollers: Bool
    @ViewBuilder private var content: () -> Content

    init(usesOverlayScrollers: Bool = true, @ViewBuilder content: @escaping () -> Content) {
        self.usesOverlayScrollers = usesOverlayScrollers
        self.content = content
    }

    var body: some View {
        ScrollView {
            content()
        }
        .background(MacOverlayScrollConfigurator(usesOverlayScrollers: usesOverlayScrollers))
    }
}

private struct MacOverlayScrollConfigurator: NSViewRepresentable {
    var usesOverlayScrollers: Bool = true

    func makeNSView(context: Context) -> MacOverlayScrollFinderView {
        let view = MacOverlayScrollFinderView()
        view.usesOverlayScrollers = usesOverlayScrollers
        return view
    }

    func updateNSView(_ nsView: MacOverlayScrollFinderView, context: Context) {
        nsView.usesOverlayScrollers = usesOverlayScrollers
        nsView.applyOverlayStyle()
    }
}

private final class MacOverlayScrollFinderView: NSView {
    private weak var configuredScrollView: NSScrollView?
    var usesOverlayScrollers = true

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyOverlayStyle()
    }

    override func layout() {
        super.layout()
        if configuredScrollView == nil {
            applyOverlayStyle()
        }
    }

    func applyOverlayStyle() {
        if let configuredScrollView {
            configure(configuredScrollView)
            return
        }

        var candidate: NSView? = superview
        while let view = candidate {
            if let scrollView = view as? NSScrollView {
                configuredScrollView = scrollView
                configure(scrollView)
                return
            }
            candidate = view.superview
        }
    }

    private func configure(_ scrollView: NSScrollView) {
        if usesOverlayScrollers {
            guard scrollView.scrollerStyle != .overlay
                || !scrollView.autohidesScrollers
                || scrollView.drawsBackground
                || scrollView.borderType != .noBorder else {
                return
            }

            scrollView.scrollerStyle = .overlay
            scrollView.autohidesScrollers = true
            scrollView.drawsBackground = false
            scrollView.borderType = .noBorder
        } else {
            scrollView.scrollerStyle = .legacy
            scrollView.hasVerticalScroller = true
            scrollView.autohidesScrollers = true
            scrollView.drawsBackground = false
            scrollView.borderType = .noBorder
            scrollView.verticalScrollElasticity = .automatic
        }
    }
}

final class TransparentWindowConfiguratorView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        WindowActivationController.configure(window)
    }
}

@MainActor
enum WindowActivationController {
    static func configure(_ window: NSWindow) {
        window.isOpaque = false
        window.backgroundColor = .clear
    }

    static func activateApplication(bringing window: NSWindow? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        NSApp.windows
            .filter { $0.level == .normal && $0.isVisible }
            .forEach { $0.makeKeyAndOrderFront(nil) }
    }
}

struct TransparentWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> TransparentWindowConfiguratorView {
        TransparentWindowConfiguratorView()
    }

    func updateNSView(_ nsView: TransparentWindowConfiguratorView, context: Context) {}
}

extension View {
    func desktopBlurSidebarBackground() -> some View {
        background {
            ZStack {
                DesktopSidebarBlurBackground()
                Color.white.opacity(AppLayout.sidebarBlurWhiteTint)
            }
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(Color.primary.opacity(0.06))
                    .frame(width: 0.5)
            }
        }
    }

    func configureTransparentWindow() -> some View {
        background {
            TransparentWindowConfigurator()
        }
    }
}

private struct DesktopSidebarBlurBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = AppLayout.sidebarBlurMaterial
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = AppLayout.sidebarBlurMaterial
        nsView.blendingMode = .behindWindow
        nsView.state = .active
        nsView.isEmphasized = false
    }
}

private struct VideoDetailCardModifier: ViewModifier {
    let padding: CGFloat
    let trailingFlush: Bool

    private var flushShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            cornerRadii: RectangleCornerRadii(
                topLeading: AppLayout.videoDetailCardCornerRadius,
                bottomLeading: AppLayout.videoDetailCardCornerRadius,
                bottomTrailing: 0,
                topTrailing: 0
            ),
            style: .continuous
        )
    }

    private var regularShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: AppLayout.videoDetailCardCornerRadius, style: .continuous)
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if trailingFlush {
            content
                .padding(.leading, padding)
                .padding(.trailing, 0)
                .padding(.vertical, padding)
                .background(Color.white, in: flushShape)
                .overlay {
                    flushShape.stroke(Color.black.opacity(0.06), lineWidth: 0.6)
                }
        } else {
            content
                .padding(padding)
                .background(Color.white, in: regularShape)
                .overlay {
                    regularShape.stroke(Color.black.opacity(0.06), lineWidth: 0.6)
                }
        }
    }
}

extension View {
    func videoCoverHover(isHovered: Binding<Bool>) -> some View {
        overlay {
            ReliableHoverDetector(isHovered: isHovered)
        }
    }

    func materialPanel() -> some View {
        self
            .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.black.opacity(0.07), lineWidth: 0.6)
            }
            .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 3)
    }

    func videoDetailCard(
        padding: CGFloat = AppLayout.videoDetailCardPadding,
        trailingFlush: Bool = false
    ) -> some View {
        modifier(VideoDetailCardModifier(padding: padding, trailingFlush: trailingFlush))
    }

    func glassActionMenuPanel() -> some View {
        self
            .padding(5)
            .background(Color.white.opacity(0.96), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.black.opacity(0.08), lineWidth: 0.6)
            }
            .shadow(color: .black.opacity(0.08), radius: 12, x: 0, y: 6)
    }
}

struct VideoCoverDurationBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.28), radius: 1, x: 0, y: 0.5)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .glassEffect(.clear, in: .capsule)
            .overlay {
                Capsule()
                    .stroke(.white.opacity(0.24), lineWidth: 0.5)
            }
    }
}

/// AppKit tracking area hover detection — only enter/exit events, unlike `onContinuousHover`.
struct ReliableHoverDetector: NSViewRepresentable {
    @Binding var isHovered: Bool

    func makeNSView(context: Context) -> ReliableHoverTrackingView {
        let view = ReliableHoverTrackingView()
        view.onHoverChanged = { isHovered = $0 }
        return view
    }

    func updateNSView(_ nsView: ReliableHoverTrackingView, context: Context) {
        nsView.onHoverChanged = { isHovered = $0 }
    }
}

final class ReliableHoverTrackingView: NSView {
    var onHoverChanged: ((Bool) -> Void)?

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTrackingAreas()
    }

    override func layout() {
        super.layout()
        updateTrackingAreas()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        guard bounds.width > 0, bounds.height > 0 else { return }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInActiveApp, .mouseEnteredAndExited, .inVisibleRect, .enabledDuringMouseDrag],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }
}

extension BiliVideo {
    var durationText: String {
        guard duration > 0 else { return "" }
        let hours = duration / 3600
        let minutes = (duration % 3600) / 60
        let seconds = duration % 60
        if hours > 0 {
            return "\(hours):\(String(format: "%02d", minutes)):\(String(format: "%02d", seconds))"
        }
        return "\(minutes):\(String(format: "%02d", seconds))"
    }
}
