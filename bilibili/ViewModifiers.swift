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
    static let feedOverlayScrollbarWidth: CGFloat = 14
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

    static var feedTrailingInset: CGFloat {
        feedHorizontalInset + feedOverlayScrollbarWidth
    }

    static func feedContentWidth(viewportWidth: CGFloat) -> CGFloat {
        max(0, viewportWidth - feedHorizontalInset - feedTrailingInset)
    }

    static func feedContentWidthSymmetric(viewportWidth: CGFloat) -> CGFloat {
        max(0, viewportWidth - feedHorizontalInset * 2)
    }

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
    static let sidebarBlurWhiteTint: CGFloat = 0.04
    static let sidebarBlurMaterial: NSVisualEffectView.Material = .hudWindow
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
    static let userProfileFallbackChromeHeight: CGFloat = 152
    static let userProfileChromeShadowOverflow: CGFloat = 8

    static let userProfileChromeBottomSpacing: CGFloat = 10

    static func userProfileFloatingChromeHeight(headerHeight: CGFloat) -> CGFloat {
        AppLayout.floatingChromeInset + (headerHeight > 0 ? headerHeight : userProfileFallbackChromeHeight)
    }

    static func userProfileContentTopInset(chromeHeight: CGFloat) -> CGFloat {
        let chrome = chromeHeight > 0 ? chromeHeight : userProfileFloatingChromeHeight(headerHeight: 0)
        return chrome + userProfileChromeBottomSpacing + userProfileChromeShadowOverflow
    }

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

struct SearchHeaderCapsuleChrome: ViewModifier {
    var isEmphasized: Bool
    var isHovered: Bool

    private var borderColor: Color {
        if isEmphasized {
            return Color.black.opacity(0.18)
        }
        if isHovered {
            return Color.black.opacity(0.16)
        }
        return Color.black.opacity(0.14)
    }

    private var borderLineWidth: CGFloat {
        0.8
    }

    func body(content: Content) -> some View {
        content
            .glassEffect(.clear, in: .capsule)
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(borderColor, lineWidth: borderLineWidth)
            }
            .shadow(
                color: .black.opacity(isEmphasized ? 0.08 : 0.04),
                radius: isEmphasized ? 10 : 6,
                x: 0,
                y: 3
            )
    }
}

extension View {
    func searchHeaderCapsuleChrome(isEmphasized: Bool, isHovered: Bool) -> some View {
        modifier(SearchHeaderCapsuleChrome(isEmphasized: isEmphasized, isHovered: isHovered))
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

struct GlassMoreDotsIcon: View {
    var size: CGFloat = 32
    var isHovered = false

    var body: some View {
        ZStack {
            Circle()
                .fill(isHovered ? Color.black.opacity(0.08) : Color.white.opacity(0.92))

            HStack(spacing: size * 0.094) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle()
                        .fill(Color.primary)
                        .frame(width: size * 0.09375, height: size * 0.09375)
                }
            }
        }
        .frame(width: size, height: size)
        .overlay {
            Circle().stroke(Color.black.opacity(0.08), lineWidth: 0.6)
        }
        .shadow(color: .black.opacity(0.08), radius: 10, x: 0, y: 4)
    }
}

struct GlassMoreButton: View {
    let webURL: URL

    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        ZStack {
            GlassMoreDotsIcon(
                size: AppLayout.floatingChromeButtonSize,
                isHovered: isHovered
            )
            .scaleEffect(isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.14), value: isPressed)

            GlassMorePopUpButtonRepresentable(webURL: webURL, isPressed: $isPressed)
                .frame(
                    width: AppLayout.floatingChromeButtonSize,
                    height: AppLayout.floatingChromeButtonSize
                )
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.18)) {
                isHovered = hovering
            }
        }
        .transition(.glassMoreButton)
    }
}

struct GlassMorePopUpButtonRepresentable: NSViewRepresentable {
    let webURL: URL
    @Binding var isPressed: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> GlassMorePopUpButtonView {
        let view = GlassMorePopUpButtonView()
        view.configure(webURL: webURL, coordinator: context.coordinator, isPressed: $isPressed)
        return view
    }

    func updateNSView(_ nsView: GlassMorePopUpButtonView, context: Context) {
        nsView.configure(webURL: webURL, coordinator: context.coordinator, isPressed: $isPressed)
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
    private let actionMenu = NSMenu()
    private weak var coordinator: GlassMorePopUpButtonRepresentable.Coordinator?
    private var isPressedBinding: Binding<Bool>?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        nil
    }

    private func setup() {
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: AppLayout.floatingChromeButtonSize),
            heightAnchor.constraint(equalToConstant: AppLayout.floatingChromeButtonSize),
        ])
    }

    override func mouseDown(with event: NSEvent) {
        setPressed(true)
        guard !actionMenu.items.isEmpty else { return }
        BiliMenuPopUpAnchor.popUp(actionMenu, in: self)
    }

    override func mouseUp(with event: NSEvent) {
        setPressed(false)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    func configure(
        webURL: URL,
        coordinator: GlassMorePopUpButtonRepresentable.Coordinator,
        isPressed: Binding<Bool>
    ) {
        self.coordinator = coordinator
        self.isPressedBinding = isPressed
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

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {}

    func menuWillOpen(_ menu: NSMenu) {}

    func menuDidClose(_ menu: NSMenu) {
        setPressed(false)
    }

    private func setPressed(_ pressed: Bool) {
        guard let isPressedBinding else { return }
        if isPressedBinding.wrappedValue != pressed {
            isPressedBinding.wrappedValue = pressed
        }
    }
}

private struct FeedViewportWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

private struct FeedSymmetricHorizontalInsetsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var feedViewportWidth: CGFloat {
        get { self[FeedViewportWidthKey.self] }
        set { self[FeedViewportWidthKey.self] = newValue }
    }

    var feedSymmetricHorizontalInsets: Bool {
        get { self[FeedSymmetricHorizontalInsetsKey.self] }
        set { self[FeedSymmetricHorizontalInsetsKey.self] = newValue }
    }
}

struct AppScrollView<Content: View>: View {
    @ViewBuilder private var content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                content()
                    .padding(.leading, AppLayout.feedHorizontalInset)
                    .padding(.trailing, AppLayout.feedTrailingInset)
                    .padding(.vertical, AppLayout.feedVerticalInset)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .environment(\.feedViewportWidth, geometry.size.width)
            }
            .scrollClipDisabled()
            .background(MacOverlayScrollConfigurator())
        }
    }
}

struct MacOverlayScrollView<Content: View>: View {
    var usesOverlayScrollers: Bool
    var clipsContent: Bool
    @ViewBuilder private var content: () -> Content

    init(
        usesOverlayScrollers: Bool = true,
        clipsContent: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.usesOverlayScrollers = usesOverlayScrollers
        self.clipsContent = clipsContent
        self.content = content
    }

    var body: some View {
        ScrollView {
            content()
        }
        .modifier(MacOverlayScrollClipModifier(clipsContent: clipsContent))
        .background(MacOverlayScrollConfigurator(usesOverlayScrollers: usesOverlayScrollers))
    }
}

private struct MacOverlayScrollClipModifier: ViewModifier {
    let clipsContent: Bool

    func body(content: Content) -> some View {
        if clipsContent {
            content
        } else {
            content.scrollClipDisabled()
        }
    }
}

struct MacScrollOffsetObserver: NSViewRepresentable {
    @Binding var offsetY: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(offsetY: $offsetY)
    }

    func makeNSView(context: Context) -> MacScrollOffsetObserverView {
        let view = MacScrollOffsetObserverView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: MacScrollOffsetObserverView, context: Context) {
        nsView.coordinator = context.coordinator
        nsView.attachIfNeeded()
    }

    final class Coordinator {
        var offsetY: Binding<CGFloat>

        init(offsetY: Binding<CGFloat>) {
            self.offsetY = offsetY
        }

        func update(_ y: CGFloat) {
            if offsetY.wrappedValue != y {
                offsetY.wrappedValue = y
            }
        }
    }
}

final class MacScrollOffsetObserverView: NSView {
    weak var coordinator: MacScrollOffsetObserver.Coordinator?
    private weak var observedScrollView: NSScrollView?
    private var boundsObservation: NSKeyValueObservation?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachIfNeeded()
    }

    override func layout() {
        super.layout()
        if observedScrollView == nil {
            attachIfNeeded()
        }
    }

    func attachIfNeeded() {
        guard let scrollView = resolveScrollView() else { return }
        guard observedScrollView !== scrollView || boundsObservation == nil else { return }

        boundsObservation?.invalidate()
        observedScrollView = scrollView
        reportOffset(from: scrollView)

        boundsObservation = scrollView.contentView.observe(\.bounds, options: [.new]) { [weak self] _, _ in
            guard let self, let scrollView = self.observedScrollView else { return }
            self.reportOffset(from: scrollView)
        }
    }

    private func reportOffset(from scrollView: NSScrollView) {
        let offset = scrollView.documentVisibleRect.origin.y
        DispatchQueue.main.async { [weak self] in
            self?.coordinator?.update(offset)
        }
    }

    private func resolveScrollView() -> NSScrollView? {
        if let observedScrollView {
            return observedScrollView
        }

        var candidate: NSView? = superview
        while let view = candidate {
            if let scrollView = view as? NSScrollView {
                return scrollView
            }
            candidate = view.superview
        }
        return nil
    }

    deinit {
        boundsObservation?.invalidate()
    }
}

private struct MacOverlayScrollConfigurator: NSViewRepresentable {
    var usesOverlayScrollers: Bool = true

    fileprivate func makeNSView(context: Context) -> MacOverlayScrollFinderView {
        let view = MacOverlayScrollFinderView()
        view.usesOverlayScrollers = usesOverlayScrollers
        return view
    }

    fileprivate func updateNSView(_ nsView: MacOverlayScrollFinderView, context: Context) {
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
        window.titlebarAppearsTransparent = true
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
                LinearGradient(
                    colors: [
                        .white.opacity(0.06),
                        .white.opacity(0.015),
                        .clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
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
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = AppLayout.sidebarBlurMaterial
        nsView.blendingMode = .behindWindow
        nsView.state = .active
        nsView.isEmphasized = true
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
