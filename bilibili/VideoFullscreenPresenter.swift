import AppKit
import Combine
import QuartzCore
import SwiftUI

@MainActor
final class VideoFullscreenPresenter: ObservableObject {
    @Published private(set) var isPresented = false

    private var window: NSWindow?
    private var sourceFrameProvider: (() -> NSRect)?
    private var escapeMonitor: Any?
    private var localEdgeMouseMonitor: Any?
    private var globalEdgeMouseMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var transitionGeneration = 0
    private weak var transitionContentLayer: CALayer?
    private var savedPresentationOptions: NSApplication.PresentationOptions?
    private var isRestoringSystemChrome = false
    /// Which system chrome edge is currently revealed (`nil` = both auto-hidden).
    private var revealedChrome: SystemChromeRevealTarget?
    private var pendingRevealTarget: SystemChromeRevealTarget?
    private var systemChromeRevealWorkItem: DispatchWorkItem?
    private static let systemChromeRevealDelay: TimeInterval = 0.18

    private enum SystemChromeRevealTarget: Equatable {
        case menuBar
        case dock
    }

    func present<Content: View>(
        from sourceFrame: NSRect,
        sourceFrameProvider: @escaping () -> NSRect,
        @ViewBuilder content: @escaping () -> Content
    ) {
        guard !isPresented, sourceFrame.width > 1, sourceFrame.height > 1 else { return }

        let screen = screenContaining(sourceFrame) ?? NSScreen.main
        guard let screen else { return }

        self.sourceFrameProvider = sourceFrameProvider

        let rootView = FullscreenWindowRoot(content: content, onClose: { [weak self] in
            self?.dismiss()
        })
        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = NSRect(origin: .zero, size: sourceFrame.size)
        hosting.layerContentsRedrawPolicy = .onSetNeedsDisplay
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.layer?.isOpaque = false

        let container = FullscreenWindowContainerView(contentView: hosting)
        container.frame = NSRect(origin: .zero, size: sourceFrame.size)
        container.cornerRadius = 0
        container.transitionProgress = 0

        let targetFrame = targetFullscreenFrame(on: screen, excluding: nil)

        let window = FullscreenOverlayWindow(
            contentRect: sourceFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        [
            NSWindow.ButtonType.closeButton,
            .miniaturizeButton,
            .zoomButton,
        ].forEach { buttonType in
            window.standardWindowButton(buttonType)?.isHidden = true
        }
        // Stay above the main window but below the menu bar and Dock so edge hover can reveal them.
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.displaysWhenScreenProfileChanges = true
        window.contentView = container
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.98
        window.ignoresMouseEvents = false
        window.makeKeyAndOrderFront(nil)

        self.window = window
        isPresented = true
        enterSystemFullscreenChrome()
        installEdgeMouseMonitors()
        installActivationObserver()
        installEscapeMonitor()

        animateWindow(
            window,
            container: container,
            from: sourceFrame,
            to: targetFrame,
            duration: 0.72,
            mainWindowAlpha: 0,
            opening: true
        ) {
            window.setFrame(targetFrame, display: true)
            self.setFullscreenBackdropOpaque(true, for: window)
            window.alphaValue = 1
            container.cornerRadius = 0
            container.transitionProgress = 1
            self.applySystemFullscreenChrome()
        }
    }

    func dismiss() {
        guard isPresented, let window, let container = window.contentView as? FullscreenWindowContainerView else {
            dismissImmediately()
            return
        }

        let targetFrame = sourceFrameProvider?() ?? window.frame
        removeEscapeMonitor()
        prepareForSystemChromeRestoration(window: window, activateMainWindow: true)
        setFullscreenBackdropOpaque(false, for: window)

        animateWindow(
            window,
            container: container,
            from: window.frame,
            to: targetFrame,
            duration: 0.62,
            mainWindowAlpha: 1,
            opening: false
        ) { [weak self] in
            guard let self else { return }
            // Reset any residual animation transform before shrinking the window
            // so the covering frame and the subsequent inline handoff stay sharp.
            container.transitionLayer?.transform = CATransform3DIdentity
            window.setFrame(targetFrame, display: true)
            container.layoutSubtreeIfNeeded()

            // Complete the handoff in one AppKit display cycle. Keeping the
            // fullscreen overlay visible after moving the shared Metal view
            // exposes its black background for one frame.
            PlayerClipContainerView.beginFullscreenToInlineHandoff()
            self.isPresented = false
            let renderView = PlayerClipContainerView.handoffRenderViewToInline()
            renderView?.refreshPresentation()
            let inlineWindow = NSApp.windows.first {
                $0 !== window && $0.level == .normal && $0.isVisible
            }
            inlineWindow?.contentView?.layoutSubtreeIfNeeded()
            inlineWindow?.displayIfNeeded()
            window.orderOut(nil)
            self.cleanup()
        }
    }

    func dismissImmediately() {
        cancelTransition()
        PlayerClipContainerView.beginFullscreenToInlineHandoff()
        isPresented = false
        if let window {
            prepareForSystemChromeRestoration(window: window, activateMainWindow: true)
            PlayerClipContainerView.handoffRenderViewToInline()?.refreshPresentation()
            let inlineWindow = NSApp.windows.first {
                $0 !== window && $0.level == .normal && $0.isVisible
            }
            inlineWindow?.contentView?.layoutSubtreeIfNeeded()
            inlineWindow?.displayIfNeeded()
            window.orderOut(nil)
            cleanup()
        } else {
            cleanup()
        }
    }

    /// Exit fullscreen because the user switched away (Dock / Cmd-Tab). Do not
    /// steal activation back from the destination app.
    private func dismissForApplicationSwitch() {
        cancelTransition()
        PlayerClipContainerView.beginFullscreenToInlineHandoff()
        isPresented = false
        if let window {
            prepareForSystemChromeRestoration(window: window, activateMainWindow: false)
            PlayerClipContainerView.handoffRenderViewToInline()?.refreshPresentation()
            window.orderOut(nil)
            cleanup()
        } else {
            cleanup()
        }
    }

    static func restoreMainWindowAppearance() {
        for window in NSApp.windows where window.level == .normal && window.isVisible {
            window.alphaValue = 1
        }
    }

    private func cleanup() {
        cancelTransition()
        PlayerClipContainerView.endFullscreenToInlineHandoff()
        removeEdgeMouseMonitors()
        removeActivationObserver()
        exitSystemFullscreenChrome()
        window = nil
        sourceFrameProvider = nil
        isPresented = false
        isRestoringSystemChrome = false
        cancelSystemChromeReveal()
        removeEscapeMonitor()
        Self.restoreMainWindowAppearance()
    }

    private func setFullscreenBackdropOpaque(_ opaque: Bool, for window: NSWindow) {
        window.isOpaque = opaque
        window.backgroundColor = opaque ? .black : .clear
    }

    private func enterSystemFullscreenChrome() {
        savedPresentationOptions = NSApp.presentationOptions
        cancelSystemChromeReveal()
        applySystemFullscreenChrome()
        DispatchQueue.main.async { [weak self] in
            self?.applySystemFullscreenChrome()
        }
    }

    private func applySystemFullscreenChrome() {
        guard isPresented, !isRestoringSystemChrome else { return }
        // Never force-activate while the user is switching away; that would yank
        // focus back from the Dock / destination app.
        if NSApp.isActive, revealedChrome == nil {
            NSApp.activate(ignoringOtherApps: true)
        }
        var options: NSApplication.PresentationOptions = []
        // Only drop auto-hide for the edge under the cursor — top shows the
        // menu bar/clock, Dock edge shows the Dock, never both at once.
        switch revealedChrome {
        case .none:
            options.insert(.autoHideMenuBar)
            options.insert(.autoHideDock)
        case .menuBar:
            options.insert(.autoHideDock)
        case .dock:
            options.insert(.autoHideMenuBar)
        }
        if Self.isAppInNativeFullscreen {
            options.insert(.fullScreen)
        }
        NSApp.presentationOptions = options
    }

    private static var isAppInNativeFullscreen: Bool {
        NSApp.windows.contains { $0.styleMask.contains(.fullScreen) }
    }

    private func exitSystemFullscreenChrome() {
        guard savedPresentationOptions != nil else { return }
        NSApp.presentationOptions = savedPresentationOptions ?? []
        savedPresentationOptions = nil
        cancelSystemChromeReveal()
    }

    private func prepareForSystemChromeRestoration(window: NSWindow, activateMainWindow: Bool) {
        isRestoringSystemChrome = true
        removeEdgeMouseMonitors()
        removeActivationObserver()
        cancelSystemChromeReveal()
        window.ignoresMouseEvents = true
        exitSystemFullscreenChrome()
        if activateMainWindow {
            NSApp.mainWindow?.makeKeyAndOrderFront(nil)
        } else {
            // Restore inline chrome visibility without ordering this app front.
            Self.restoreMainWindowAppearance()
        }
    }

    private func installEdgeMouseMonitors() {
        removeEdgeMouseMonitors()
        // Local: mouse is delivered to this app while the overlay captures events.
        // Global: once we pass through at the Dock/menu edge, events go elsewhere
        // and only a global monitor keeps updating ignoresMouseEvents.
        localEdgeMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        ) { [weak self] event in
            self?.handleEdgeMouseEvent()
            return event
        }
        globalEdgeMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        ) { [weak self] _ in
            self?.handleEdgeMouseEvent()
        }
        syncEdgeMousePassThrough()
    }

    private func handleEdgeMouseEvent() {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                syncEdgeMousePassThrough()
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.syncEdgeMousePassThrough()
            }
        }
    }

    private func removeEdgeMouseMonitors() {
        if let localEdgeMouseMonitor {
            NSEvent.removeMonitor(localEdgeMouseMonitor)
            self.localEdgeMouseMonitor = nil
        }
        if let globalEdgeMouseMonitor {
            NSEvent.removeMonitor(globalEdgeMouseMonitor)
            self.globalEdgeMouseMonitor = nil
        }
    }

    private func installActivationObserver() {
        removeActivationObserver()
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleApplicationDidResignActive()
            }
        }
    }

    private func removeActivationObserver() {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
    }

    /// Clear auto-hide presentation options and ignore resign-active dismiss so
    /// AVPictureInPictureController can start while the overlay is still up.
    func prepareForPictureInPicture() {
        guard isPresented, !isRestoringSystemChrome else { return }
        removeActivationObserver()
        cancelSystemChromeReveal()
        window?.ignoresMouseEvents = false
        if savedPresentationOptions != nil {
            NSApp.presentationOptions = []
        }
    }

    /// Restore fullscreen chrome policy after a failed PiP attempt.
    func restoreAfterPictureInPictureFailure() {
        guard isPresented, !isRestoringSystemChrome else { return }
        installActivationObserver()
        applySystemFullscreenChrome()
    }

    /// Exit fullscreen after PiP is running, without stealing focus back.
    func dismissForPictureInPicture() {
        guard isPresented else { return }
        dismissForApplicationSwitch()
    }

    private func handleApplicationDidResignActive() {
        guard isPresented, !isRestoringSystemChrome else { return }
        // PiP / system UI can briefly resign activation without leaving this app.
        // Defer and only exit fullscreen when another app is actually frontmost.
        DispatchQueue.main.async { [weak self] in
            self?.dismissFullscreenIfSwitchedToAnotherApp()
        }
    }

    private func dismissFullscreenIfSwitchedToAnotherApp() {
        guard isPresented, !isRestoringSystemChrome else { return }
        if NSApp.isActive { return }
        if PictureInPictureHost.shared.isPictureInPictureBusy { return }

        let frontBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let selfBundleID = Bundle.main.bundleIdentifier
        if frontBundleID == nil || frontBundleID == selfBundleID {
            return
        }

        // Floating fullscreen sits above other apps' normal windows. Exit so
        // Dock / app switching actually reveals the destination app — without
        // re-activating Bilibili.
        dismissForApplicationSwitch()
    }

    private func syncEdgeMousePassThrough() {
        guard isPresented, !isRestoringSystemChrome, let window else { return }
        let screen = window.screen ?? NSScreen.main
        let zone = FullscreenWindowContainerView.systemChromeRevealZone(
            at: NSEvent.mouseLocation,
            screen: screen
        )

        if let zone {
            let target: SystemChromeRevealTarget = (zone == .menuBar) ? .menuBar : .dock
            if revealedChrome == target {
                if !window.ignoresMouseEvents {
                    window.ignoresMouseEvents = true
                }
                return
            }
            if revealedChrome != nil {
                // Already revealing one edge; switch immediately when crossing.
                cancelPendingSystemChromeReveal()
                revealedChrome = target
                window.ignoresMouseEvents = true
                applySystemFullscreenChrome()
                return
            }
            scheduleSystemChromeReveal(for: window, target: target)
        } else {
            cancelPendingSystemChromeReveal()
            if window.ignoresMouseEvents {
                window.ignoresMouseEvents = false
            }
            if revealedChrome != nil {
                revealedChrome = nil
                applySystemFullscreenChrome()
            }
        }
    }

    private func scheduleSystemChromeReveal(for window: NSWindow, target: SystemChromeRevealTarget) {
        if pendingRevealTarget == target, systemChromeRevealWorkItem != nil { return }
        cancelPendingSystemChromeReveal()
        pendingRevealTarget = target
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isPresented, !self.isRestoringSystemChrome else { return }
            self.systemChromeRevealWorkItem = nil
            self.pendingRevealTarget = nil
            self.revealedChrome = target
            window.ignoresMouseEvents = true
            self.applySystemFullscreenChrome()
        }
        systemChromeRevealWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.systemChromeRevealDelay, execute: work)
    }

    private func cancelPendingSystemChromeReveal() {
        systemChromeRevealWorkItem?.cancel()
        systemChromeRevealWorkItem = nil
        pendingRevealTarget = nil
    }

    private func cancelSystemChromeReveal() {
        cancelPendingSystemChromeReveal()
        revealedChrome = nil
    }

    private func screenContaining(_ frame: NSRect) -> NSScreen? {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main
    }

    private func targetFullscreenFrame(on screen: NSScreen, excluding overlayWindow: NSWindow?) -> NSRect {
        if let mainWindow = NSApp.mainWindow,
           mainWindow !== overlayWindow,
           mainWindow.styleMask.contains(.fullScreen),
           mainWindow.screen == screen {
            return mainWindow.frame
        }
        return screen.frame
    }

    private func animateWindow(
        _ window: NSWindow,
        container: FullscreenWindowContainerView,
        from startFrame: NSRect,
        to endFrame: NSRect,
        duration: TimeInterval,
        mainWindowAlpha targetMainWindowAlpha: CGFloat,
        opening: Bool,
        completion: @escaping @MainActor () -> Void
    ) {
        cancelTransition()
        let generation = transitionGeneration
        let mainWindow = NSApp.mainWindow === window ? nil : NSApp.mainWindow
        let fixedWindowFrame = opening ? endFrame : startFrame
        let localStartFrame = localFrame(startFrame, in: fixedWindowFrame)
        let localEndFrame = localFrame(endFrame, in: fixedWindowFrame)

        // 窗口保持固定尺寸，直接变换持续渲染的完整内容图层。mpv 在动画期间
        // 继续解码和呈现新帧，同时避免窗口尺寸变化触发逐帧 SwiftUI 布局。
        window.setFrame(fixedWindowFrame, display: true)
        window.alphaValue = 1
        container.setContentVisible(true)
        container.transitionProgress = opening ? 0 : 1
        container.layoutSubtreeIfNeeded()
        guard let contentLayer = container.transitionLayer else {
            completion()
            return
        }
        transitionContentLayer = contentLayer

        let presenter = self
        let animatedWindow = window
        let animatedContainer = container

        let timing = opening
            ? CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.30, 1.0)
            : CAMediaTimingFunction(controlPoints: 0.40, 0.0, 0.20, 1.0)
        let startTransform = contentTransform(layer: contentLayer, to: localStartFrame)
        let endTransform = contentTransform(layer: contentLayer, to: localEndFrame)
        let transformAnimation = CABasicAnimation(keyPath: "transform")
        transformAnimation.fromValue = NSValue(caTransform3D: startTransform)
        transformAnimation.toValue = NSValue(caTransform3D: endTransform)

        let transitionAnimation = CAAnimationGroup()
        transitionAnimation.animations = [transformAnimation]
        transitionAnimation.duration = duration
        transitionAnimation.timingFunction = timing
        transitionAnimation.isRemovedOnCompletion = false
        transitionAnimation.fillMode = .forwards

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated {
                guard presenter.transitionGeneration == generation else { return }
                contentLayer.removeAnimation(forKey: "fullscreenTransition")
                presenter.transitionContentLayer = nil
                animatedWindow.setFrame(endFrame, display: true)
                animatedWindow.alphaValue = 1
                animatedContainer.cornerRadius = 0
                animatedContainer.transitionProgress = opening ? 1 : 0
                mainWindow?.alphaValue = targetMainWindowAlpha
                completion()
            }
        }
        contentLayer.transform = endTransform
        contentLayer.add(transitionAnimation, forKey: "fullscreenTransition")
        mainWindow?.animator().alphaValue = targetMainWindowAlpha
        CATransaction.commit()
    }

    private func localFrame(_ screenFrame: NSRect, in windowFrame: NSRect) -> NSRect {
        NSRect(
            x: screenFrame.minX - windowFrame.minX,
            y: screenFrame.minY - windowFrame.minY,
            width: screenFrame.width,
            height: screenFrame.height
        )
    }

    private func contentTransform(layer: CALayer, to destination: NSRect) -> CATransform3D {
        let source = layer.bounds
        guard source.width > 0, source.height > 0 else { return CATransform3DIdentity }
        let anchor = layer.anchorPoint
        let desiredAnchor = CGPoint(
            x: destination.minX + destination.width * anchor.x,
            y: destination.minY + destination.height * anchor.y
        )
        var transform = CATransform3DMakeScale(
            destination.width / source.width,
            destination.height / source.height,
            1
        )
        transform.m41 = desiredAnchor.x - layer.position.x
        transform.m42 = desiredAnchor.y - layer.position.y
        return transform
    }

    private func cancelTransition() {
        transitionGeneration &+= 1
        transitionContentLayer?.removeAnimation(forKey: "fullscreenTransition")
        transitionContentLayer?.transform = CATransform3DIdentity
        transitionContentLayer = nil
        (window?.contentView as? FullscreenWindowContainerView)?.setContentVisible(true)
    }

    private func installEscapeMonitor() {
        removeEscapeMonitor()
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, isPresented, event.keyCode == 53 else { return event }
            dismiss()
            return nil
        }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
    }

}

private struct FullscreenWindowRoot<Content: View>: View {
    let content: () -> Content
    let onClose: () -> Void

    var body: some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .ignoresSafeArea()
    }
}

private final class FullscreenOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class FullscreenWindowContainerView: NSView {
    private static let fallbackSystemChromeRevealBand: CGFloat = 12

    private let contentView: NSView

    @objc dynamic var cornerRadius: CGFloat = 0 {
        didSet { updateCornerMask() }
    }

    @objc dynamic var transitionProgress: CGFloat = 1 {
        didSet { updateTransitionAppearance() }
    }

    init(contentView: NSView) {
        self.contentView = contentView
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(contentView)
        updateCornerMask()
        updateTransitionAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        contentView.frame = bounds
        contentView.autoresizingMask = [.width, .height]
        updateCornerMask()
        updateTransitionAppearance()
    }

    override var acceptsFirstResponder: Bool { true }

    var transitionLayer: CALayer? { contentView.layer }

    func setContentVisible(_ visible: Bool) {
        contentView.isHidden = !visible
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        if isSystemChromeRevealPoint(point) {
            return nil
        }
        return super.hitTest(point)
    }

    private func isSystemChromeRevealPoint(_ point: NSPoint) -> Bool {
        guard let window else { return false }
        let screenPoint = window.convertPoint(toScreen: convert(point, to: nil))
        return Self.isScreenPointInSystemChromeRevealZone(screenPoint, screen: window.screen ?? NSScreen.main)
    }

    enum SystemChromeRevealZone: Equatable {
        case menuBar
        case dock
    }

    static func systemChromeRevealZone(at screenPoint: NSPoint, screen: NSScreen?) -> SystemChromeRevealZone? {
        guard let screen else { return nil }

        let frame = screen.frame
        let band = systemChromeRevealBand(for: screen)

        if screenPoint.y >= frame.maxY - band {
            return .menuBar
        }

        let dockEdges = dockRevealEdges()
        if dockEdges.bottom, screenPoint.y <= frame.minY + band {
            return .dock
        }
        if dockEdges.left, screenPoint.x <= frame.minX + band {
            return .dock
        }
        if dockEdges.right, screenPoint.x >= frame.maxX - band {
            return .dock
        }
        return nil
    }

    static func isScreenPointInSystemChromeRevealZone(_ screenPoint: NSPoint, screen: NSScreen?) -> Bool {
        systemChromeRevealZone(at: screenPoint, screen: screen) != nil
    }

    private static func systemChromeRevealBand(for screen: NSScreen) -> CGFloat {
        let prefs = UserDefaults.standard.persistentDomain(forName: "com.apple.dock") ?? [:]
        if let area = prefs["autohide-edge-area"] as? Double, area > 0 {
            return CGFloat(area)
        }
        if let area = prefs["autohide-edge-area"] as? Int, area > 0 {
            return CGFloat(area)
        }
        // Match the default Dock/menu-bar edge trigger when the pref is unset.
        return fallbackSystemChromeRevealBand
    }

    private static func dockRevealEdges() -> (bottom: Bool, left: Bool, right: Bool) {
        let prefs = UserDefaults.standard.persistentDomain(forName: "com.apple.dock") ?? [:]
        switch prefs["orientation"] as? String {
        case "left":
            return (false, true, false)
        case "right":
            return (false, false, true)
        default:
            return (true, false, false)
        }
    }

    private func updateCornerMask() {
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = cornerRadius > 0
    }

    private func updateTransitionAppearance() {
        wantsLayer = true
        let progress = transitionProgress.clamped(to: 0...1)
        if progress >= 1 {
            layer?.backgroundColor = NSColor.clear.cgColor
        } else {
            layer?.backgroundColor = NSColor.black.withAlphaComponent(0.88 + 0.12 * progress).cgColor
        }
    }
}

struct PlayerScreenFrameReader: NSViewRepresentable {
    let onChange: (NSRect) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = PlayerScreenFrameReaderView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? PlayerScreenFrameReaderView else { return }
        view.onChange = onChange
        view.reportFrame()
    }
}

private final class PlayerScreenFrameReaderView: NSView {
    var onChange: ((NSRect) -> Void)?
    private var lastReportedFrame = NSRect.zero

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportFrame(force: true)
    }

    override func layout() {
        super.layout()
        reportFrame()
    }

    func reportFrame(force: Bool = false) {
        guard bounds.width > 1, bounds.height > 1 else { return }
        guard let window else { return }
        let inWindow = convert(bounds, to: nil)
        let screenFrame = window.convertToScreen(inWindow)
        guard force || framesDiffer(lastReportedFrame, screenFrame) else { return }
        lastReportedFrame = screenFrame
        let callback = onChange
        DispatchQueue.main.async {
            callback?(screenFrame)
        }
    }

    private func framesDiffer(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) > 0.5
            || abs(lhs.origin.y - rhs.origin.y) > 0.5
            || abs(lhs.width - rhs.width) > 0.5
            || abs(lhs.height - rhs.height) > 0.5
    }
}

private extension CGFloat {
    nonisolated func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
