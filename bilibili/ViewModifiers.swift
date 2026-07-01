import AppKit
import SwiftUI

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
    static let searchBarPreferredWidth: CGFloat = 580
    static let searchBarMinWidth: CGFloat = 520
    static let searchPageTopInset: CGFloat = 24
    static let sidebarBackground = Color(red: 0.969, green: 0.969, blue: 0.973)
    static let sidebarBlurWhiteTint: CGFloat = 0.46
    static let sidebarBlurMaterial: NSVisualEffectView.Material = .popover
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
        floatingChromeInset + 88
    }

    /// 右侧简介栏不与左侧浮动标题重叠，顶部留白更小。
    static var videoDetailRightColumnTopInset: CGFloat {
        floatingChromeInset + 4
    }

    /// 视频详情右侧栏内容与窗口右缘的内边距。
    static let videoDetailRightColumnTrailingInset: CGFloat = 16
}

struct GlassCircleButton: View {
    let systemImage: String
    var size: CGFloat = 32
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
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
        .buttonStyle(GlassCircleButtonStyle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.18)) {
                isHovered = hovering
            }
        }
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
    @ViewBuilder private var content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        ScrollView {
            content()
        }
        .background(MacOverlayScrollConfigurator())
    }
}

private struct MacOverlayScrollConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> MacOverlayScrollFinderView {
        MacOverlayScrollFinderView()
    }

    func updateNSView(_ nsView: MacOverlayScrollFinderView, context: Context) {
        nsView.applyOverlayStyle()
    }
}

private final class MacOverlayScrollFinderView: NSView {
    private weak var configuredScrollView: NSScrollView?

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
        window.isOpaque = true
        window.backgroundColor = .white
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
                AppLayout.sidebarBackground
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
