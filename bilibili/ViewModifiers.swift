import AppKit
import SwiftUI

struct SearchUserResultLayout: Equatable {
    let columnCount: Int
    let capsuleWidth: CGFloat
    let gridWidth: CGFloat
}

enum AppLayout {
    static let sidebarWidth: CGFloat = 72
    static let sidebarBackgroundColor = Color(red: 0.97, green: 0.97, blue: 0.975)
    static let sidebarNavTopInset: CGFloat = 44
    static let sidebarNavItemSpacing: CGFloat = 4
    static let sidebarNavItemHeight: CGFloat = 58
    static let sidebarNavLabelSize: CGFloat = 13
    static let sidebarBottomInset: CGFloat = 16
    static let floatingChromeInset: CGFloat = 20
    static let floatingChromeBackOnlyHeight: CGFloat = floatingChromeInset + 32 + 8
    static let floatingChromeButtonSize: CGFloat = 32
    static let floatingChromeBottomSpacing: CGFloat = 12
    static let pageHorizontalInset: CGFloat = 20
    static let feedHorizontalInset: CGFloat = 64
    static let feedOverlayScrollbarWidth: CGFloat = 14
    static let feedVerticalInset: CGFloat = 28
    static let mainContentPaddingCompact: CGFloat = 24
    static let searchPageMaxWidth: CGFloat = 1040
    static let searchPageCompactBreakpoint: CGFloat = 900
    static let searchBarPreferredWidth: CGFloat = 440
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
    static let sidebarSelectionCornerRadius: CGFloat = 10
    static let sidebarSelectionFill = BiliTheme.pink.opacity(0.10)
    static let sidebarHoverFill = Color.black.opacity(0.04)
    static let searchSurfaceBorder = Color.black.opacity(0.06)
    static let searchChipFill = Color.black.opacity(0.05)
    static let searchChipHoverFill = Color.black.opacity(0.08)
    static let searchRowHoverFill = Color.black.opacity(0.03)

    static var floatingChromeReservedHeight: CGFloat {
        floatingChromeInset + floatingChromeButtonSize + floatingChromeBottomSpacing
    }

    /// 播放器顶部留白：避开浮动返回栏与标题，略低于标题底边。
    static var videoDetailPlayerTopInset: CGFloat {
        floatingChromeReservedHeight + 12
    }

    static let videoDetailPageBackground = Color(red: 0.961, green: 0.963, blue: 0.969)
    static let videoDetailCardCornerRadius: CGFloat = 12
    static let videoDetailCardPadding: CGFloat = 16
    static let videoDetailLeadingInset: CGFloat = 8
    static let videoDetailTrailingInset: CGFloat = 12
    static let videoDetailSectionSpacing: CGFloat = 8
    static let videoDetailSidebarMinWidth: CGFloat = 240
    static let videoDetailSidebarMinContentWidth: CGFloat = 200
    static let videoDetailSidebarWidthRatio: CGFloat = 0.24
    static let videoDetailSidebarMaxWidthRatio: CGFloat = 0.32
    static let videoDetailChromeBottomSpacing: CGFloat = 4
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

    static let userRelationFallbackChromeHeight: CGFloat = 72

    static func userRelationFloatingChromeHeight(headerHeight: CGFloat) -> CGFloat {
        AppLayout.floatingChromeInset + (headerHeight > 0 ? headerHeight : userRelationFallbackChromeHeight)
    }

    static func userRelationContentTopInset(chromeHeight: CGFloat) -> CGFloat {
        let chrome = chromeHeight > 0 ? chromeHeight : userRelationFloatingChromeHeight(headerHeight: 0)
        return chrome + userProfileChromeBottomSpacing
    }

    /// Aligns the relation-list tab toggle with the right edge of the two-column user grid.
    static var userRelationToggleTrailingInset: CGFloat {
        feedHorizontalInset + searchUserResultsHorizontalInset - floatingChromeInset
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

private struct MeasuredHeightReporter<K: PreferenceKey>: ViewModifier where K.Value == CGFloat {
    let when: Bool

    func body(content: Content) -> some View {
        content.background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: K.self,
                    value: when ? geometry.size.height : 0
                )
            }
        }
    }
}

extension View {
    func reportMeasuredHeight<K: PreferenceKey>(
        to key: K.Type,
        when: Bool = true
    ) -> some View where K.Value == CGFloat {
        modifier(MeasuredHeightReporter<K>(when: when))
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

struct BiliLiquidSegmentedControl<Tab: Hashable & Identifiable>: View {
    @Binding var selection: Tab
    let tabs: [Tab]
    let title: (Tab) -> String
    var width: CGFloat
    var height: CGFloat

    @State private var isPressing = false
    @State private var isHovered = false
    @State private var dragX: CGFloat?
    @State private var animationTrigger = 0

    private let outerPadding: CGFloat = 5
    private let indicatorInset: CGFloat = 3

    init(
        selection: Binding<Tab>,
        title: @escaping (Tab) -> String,
        width: CGFloat = AppLayout.searchTypeToggleWidth,
        height: CGFloat = AppLayout.searchBarHeight
    ) where Tab: CaseIterable {
        _selection = selection
        self.tabs = Array(Tab.allCases)
        self.title = title
        self.width = width
        self.height = height
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let segmentWidth = max(1, (size.width - outerPadding * 2) / CGFloat(tabs.count))
            let indicatorWidth = max(1, segmentWidth - indicatorInset * 2)
            let indicatorHeight = max(1, size.height - outerPadding * 2)
            let restingX = outerPadding + CGFloat(selectedIndex) * segmentWidth + indicatorInset
            let draggingX = clampedIndicatorX(
                centerX: dragX ?? restingX + indicatorWidth / 2,
                indicatorWidth: indicatorWidth,
                totalWidth: size.width
            )
            let indicatorX = isPressing ? draggingX : restingX

            ZStack(alignment: .topLeading) {
                BiliLiquidSegmentIndicator(isPressing: isPressing, animationTrigger: animationTrigger)
                    .frame(width: indicatorWidth, height: indicatorHeight)
                    .offset(x: indicatorX, y: outerPadding)
                    .animation(
                        isPressing
                        ? .interactiveSpring(response: 0.18, dampingFraction: 0.78, blendDuration: 0.02)
                        : .spring(response: 0.34, dampingFraction: 0.58, blendDuration: 0.04),
                        value: indicatorX
                    )
                    .animation(.spring(response: 0.22, dampingFraction: 0.62, blendDuration: 0.02), value: isPressing)

                HStack(spacing: 0) {
                    ForEach(tabs) { tab in
                        Text(title(tab))
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Color.black.opacity(selection == tab ? 0.92 : 0.82))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .frame(height: indicatorHeight)
                            .offset(y: outerPadding)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                select(tab)
                            }
                    }
                }
            }
            .contentShape(Capsule(style: .continuous))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isPressing {
                            withAnimation(.spring(response: 0.18, dampingFraction: 0.68, blendDuration: 0.02)) {
                                isPressing = true
                            }
                        }
                        dragX = value.location.x
                        updateSelection(for: value.location.x, segmentWidth: segmentWidth)
                    }
                    .onEnded { value in
                        updateSelection(for: value.location.x, segmentWidth: segmentWidth)
                        dragX = nil
                        animationTrigger += 1
                        withAnimation(.spring(response: 0.36, dampingFraction: 0.56, blendDuration: 0.04)) {
                            isPressing = false
                        }
                    }
            )
        }
        .frame(width: width, height: height)
        .searchHeaderCapsuleChrome(isEmphasized: isPressing, isHovered: isHovered)
        .contentShape(Capsule(style: .continuous))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }

    private var selectedIndex: Int {
        tabs.firstIndex(where: { $0 == selection }) ?? 0
    }

    private func select(_ tab: Tab) {
        guard selection != tab else {
            animationTrigger += 1
            return
        }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.58, blendDuration: 0.04)) {
            selection = tab
        }
        animationTrigger += 1
    }

    private func updateSelection(for x: CGFloat, segmentWidth: CGFloat) {
        let adjustedX = x - outerPadding
        let index = min(
            tabs.count - 1,
            max(0, Int((adjustedX / segmentWidth).rounded(.down)))
        )
        let tab = tabs[index]
        guard selection != tab else { return }
        withAnimation(.interactiveSpring(response: 0.20, dampingFraction: 0.72, blendDuration: 0.02)) {
            selection = tab
        }
    }

    private func clampedIndicatorX(centerX: CGFloat, indicatorWidth: CGFloat, totalWidth: CGFloat) -> CGFloat {
        let expandedOverflow = indicatorWidth * 0.08
        return min(
            totalWidth - outerPadding - indicatorWidth - expandedOverflow,
            max(outerPadding + expandedOverflow, centerX - indicatorWidth / 2)
        )
    }
}

private struct BiliLiquidSegmentIndicator: View {
    let isPressing: Bool
    let animationTrigger: Int

    var body: some View {
        Capsule(style: .continuous)
            .fill(Color(red: 0.92, green: 0.92, blue: 0.93))
            .glassEffect(.regular.interactive(), in: .capsule)
            .phaseAnimator(
                BiliLiquidSegmentPhase.allCases,
                trigger: animationTrigger
            ) { content, phase in
                content
                    .scaleEffect(
                        x: isPressing ? 1.12 : phase.xScale,
                        y: isPressing ? 1.08 : phase.yScale
                    )
                    .blur(radius: isPressing ? 0.18 : phase.blurRadius)
                    .shadow(
                        color: .black.opacity(isPressing ? 0.08 : 0.025),
                        radius: isPressing ? 8 : 3,
                        x: 0,
                        y: isPressing ? 3 : 1
                    )
            } animation: { phase in
                phase.animation
            }
    }
}

private enum BiliLiquidSegmentPhase: CaseIterable {
    case resting
    case droplet
    case rebound
    case settled

    var xScale: CGFloat {
        switch self {
        case .resting, .settled: 1
        case .droplet: 1.18
        case .rebound: 0.96
        }
    }

    var yScale: CGFloat {
        switch self {
        case .resting, .settled: 1
        case .droplet: 0.90
        case .rebound: 1.04
        }
    }

    var blurRadius: CGFloat {
        self == .droplet ? 0.2 : 0
    }

    var animation: Animation {
        switch self {
        case .resting:
            .linear(duration: 0.01)
        case .droplet:
            .smooth(duration: 0.11)
        case .rebound:
            .spring(response: 0.18, dampingFraction: 0.58, blendDuration: 0.02)
        case .settled:
            .spring(response: 0.26, dampingFraction: 0.68, blendDuration: 0.04)
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
    @State private var viewportWidth: CGFloat = 0

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        ScrollView {
            content()
                .padding(.leading, AppLayout.feedHorizontalInset)
                .padding(.trailing, AppLayout.feedTrailingInset)
                .padding(.vertical, AppLayout.feedVerticalInset)
                .frame(maxWidth: .infinity, alignment: .leading)
                .environment(\.feedViewportWidth, viewportWidth)
        }
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear {
                        viewportWidth = geometry.size.width
                    }
                    .onChange(of: geometry.size.width) { _, width in
                        viewportWidth = width
                    }
            }
        }
        .background(MacOverlayScrollConfigurator())
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
    func configureTransparentWindow() -> some View {
        background {
            TransparentWindowConfigurator()
        }
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
                .clipShape(flushShape)
                .overlay {
                    flushShape.stroke(Color.black.opacity(0.06), lineWidth: 0.6)
                }
        } else {
            content
                .padding(padding)
                .background(Color.white, in: regularShape)
                .clipShape(regularShape)
                .overlay {
                    regularShape.stroke(Color.black.opacity(0.06), lineWidth: 0.6)
                }
        }
    }
}

extension View {
    func videoCoverHover(isHovered: Binding<Bool>) -> some View {
        overlay {
            VideoCoverHoverDetector(isHovered: isHovered)
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

/// AppKit tracking area hover detection with scroll-driven reset for stationary pointers.
struct VideoCoverHoverDetector: NSViewRepresentable {
    @Binding var isHovered: Bool

    func makeNSView(context: Context) -> VideoCoverHoverTrackingView {
        let view = VideoCoverHoverTrackingView()
        view.onHoverChanged = { isHovered = $0 }
        return view
    }

    func updateNSView(_ nsView: VideoCoverHoverTrackingView, context: Context) {
        nsView.onHoverChanged = { isHovered = $0 }
    }
}

@MainActor
private enum VideoCoverHoverScrollCenter {
    private static var trackedViewsByScrollView: [ObjectIdentifier: NSHashTable<VideoCoverHoverTrackingView>] = [:]
    private static var activeViews = NSHashTable<VideoCoverHoverTrackingView>.weakObjects()
    private static var scrollBoundsObservers: [ObjectIdentifier: NSObjectProtocol] = [:]
    private static var scrollIdleWorkItems: [ObjectIdentifier: DispatchWorkItem] = [:]
    private static var activeScrollDeadlines: [ObjectIdentifier: CFTimeInterval] = [:]
    private static let scrollSettleDelay: TimeInterval = 0.08

    static func prepare(_ view: VideoCoverHoverTrackingView) {
        if let scrollView = view.hoverScrollView() {
            track(view, in: scrollView)
            registerScrollViewIfNeeded(scrollView)
        }
    }

    static func untrack(_ view: VideoCoverHoverTrackingView) {
        activeViews.remove(view)
        if let scrollView = view.cachedScrollView {
            trackedViewsByScrollView[ObjectIdentifier(scrollView)]?.remove(view)
        }
    }

    static func activate(_ view: VideoCoverHoverTrackingView) {
        activeViews.add(view)
        if let scrollView = view.hoverScrollView() {
            track(view, in: scrollView)
            registerScrollViewIfNeeded(scrollView)
        }
    }

    static func deactivate(_ view: VideoCoverHoverTrackingView) {
        activeViews.remove(view)
    }

    private static func track(_ view: VideoCoverHoverTrackingView, in scrollView: NSScrollView) {
        let id = ObjectIdentifier(scrollView)
        let views = trackedViewsByScrollView[id] ?? NSHashTable<VideoCoverHoverTrackingView>.weakObjects()
        views.add(view)
        trackedViewsByScrollView[id] = views
    }

    private static func registerScrollViewIfNeeded(_ scrollView: NSScrollView) {
        let id = ObjectIdentifier(scrollView)
        guard scrollBoundsObservers[id] == nil else { return }

        let clipView = scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        let scrollViewBox = WeakScrollViewBox(scrollView)
        scrollBoundsObservers[id] = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                handleScrollBoundsChanged(in: scrollViewBox.value)
            }
        }
    }

    private static func handleScrollBoundsChanged(in scrollView: NSScrollView?) {
        guard let scrollView else { return }

        let id = ObjectIdentifier(scrollView)
        let settleDeadline = CACurrentMediaTime() + scrollSettleDelay
        activeScrollDeadlines[id] = settleDeadline

        scrollIdleWorkItems[id]?.cancel()
        let scrollViewBox = WeakScrollViewBox(scrollView)
        let idleWorkItem = DispatchWorkItem {
            MainActor.assumeIsolated {
                guard activeScrollDeadlines[id] == settleDeadline else { return }
                activeScrollDeadlines[id] = nil
                scrollIdleWorkItems[id] = nil
                guard let scrollView = scrollViewBox.value else { return }
                recheckTrackedViews(in: scrollView)
            }
        }
        scrollIdleWorkItems[id] = idleWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + scrollSettleDelay, execute: idleWorkItem)
    }

    private static func recheckTrackedViews(in scrollView: NSScrollView) {
        guard let mouseInWindow = scrollView.window?.mouseLocationOutsideOfEventStream else {
            for view in activeViews.allObjects where view.hoverScrollView() === scrollView {
                view.forceDeactivateHover()
            }
            return
        }

        let trackedInScrollView = trackedViewsByScrollView[ObjectIdentifier(scrollView)]?.allObjects ?? []
        for view in trackedInScrollView {
            guard view.needsScrollHoverRecheck(mouseInWindow: mouseInWindow) else { continue }
            view.recheckHoverState(mouseInWindow: mouseInWindow)
        }
    }
}

private final class WeakScrollViewBox: @unchecked Sendable {
    weak var value: NSScrollView?

    init(_ value: NSScrollView) {
        self.value = value
    }
}

final class VideoCoverHoverTrackingView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    weak var cachedScrollView: NSScrollView?
    private var isHovering = false

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTrackingAreas()
        if window != nil {
            MainActor.assumeIsolated {
                VideoCoverHoverScrollCenter.prepare(self)
            }
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            VideoCoverHoverScrollCenter.untrack(self)
            cachedScrollView = nil
            forceDeactivateHover()
        }
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
        setHovering(true)
    }

    override func mouseExited(with event: NSEvent) {
        forceDeactivateHover()
    }

    func hoverScrollView() -> NSScrollView? {
        if let cachedScrollView {
            return cachedScrollView
        }

        var candidate: NSView? = self
        while let view = candidate {
            if let scrollView = view.enclosingScrollView {
                cachedScrollView = scrollView
                return scrollView
            }
            candidate = view.superview
        }
        return nil
    }

    func forceDeactivateHover() {
        setHovering(false)
    }

    func recheckHoverState(mouseInWindow providedMouseInWindow: NSPoint? = nil) {
        guard let window else {
            forceDeactivateHover()
            return
        }
        let mouseInWindow = providedMouseInWindow ?? window.mouseLocationOutsideOfEventStream
        setHovering(isMouseInsideCover(mouseInWindow: mouseInWindow))
    }

    func needsScrollHoverRecheck(mouseInWindow: NSPoint) -> Bool {
        isHovering || mayContainMouse(mouseInWindow: mouseInWindow)
    }

    private func mayContainMouse(mouseInWindow: NSPoint) -> Bool {
        let coverFrameInWindow = convert(bounds, to: nil)
        guard coverFrameInWindow.width > 0, coverFrameInWindow.height > 0 else { return false }
        return coverFrameInWindow.insetBy(dx: -6, dy: -6).contains(mouseInWindow)
    }

    private func isMouseInsideCover(mouseInWindow: NSPoint) -> Bool {
        let coverFrameInWindow = convert(bounds, to: nil)
        guard coverFrameInWindow.width > 0, coverFrameInWindow.height > 0 else { return false }

        if let scrollView = hoverScrollView() {
            let clipView = scrollView.contentView
            let visibleInWindow = clipView.convert(clipView.bounds, to: nil)
            let visibleCover = coverFrameInWindow.intersection(visibleInWindow)
            guard visibleCover.width > 0, visibleCover.height > 0 else { return false }
            return visibleCover.contains(mouseInWindow)
        }

        return coverFrameInWindow.contains(mouseInWindow)
    }

    private func setHovering(_ hovering: Bool) {
        guard isHovering != hovering else { return }
        isHovering = hovering
        if hovering {
            VideoCoverHoverScrollCenter.activate(self)
        } else {
            VideoCoverHoverScrollCenter.deactivate(self)
        }
        onHoverChanged?(hovering)
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
