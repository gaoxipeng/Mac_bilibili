import AppKit
import Combine
import QuartzCore
import SwiftUI

@MainActor
final class VideoFullscreenPresenter: ObservableObject {
    @Published private(set) var isPresented = false
    @Published private(set) var isExiting = false
    /// The fullscreen window remains presented throughout its exit animation,
    /// but inline chrome should already be available underneath it so the title
    /// fades back with the rest of the main window.
    @Published private(set) var suppressesInlineChrome = false

    private var window: NSWindow?
    private var sourceFrameProvider: (() -> NSRect)?
    private var escapeMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var transitionGeneration = 0
    private weak var transitionContentLayer: CALayer?
    private var savedPresentationOptions: NSApplication.PresentationOptions?
    private var isRestoringSystemChrome = false

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
        // Keep the video above the main window while presentation options hide
        // the system menu bar and Dock for the entire video fullscreen session.
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.displaysWhenScreenProfileChanges = true
        window.contentView = container
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.98
        window.ignoresMouseEvents = false

        self.window = window
        isExiting = false
        suppressesInlineChrome = true
        isPresented = true
        enterSystemFullscreenChrome()
        // Apply the system presentation policy before exposing the overlay so
        // the menu bar cannot flash during the first fullscreen frame.
        window.makeKeyAndOrderFront(nil)
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
        guard !isExiting else { return }

        isExiting = true
        let targetFrame = sourceFrameProvider?() ?? window.frame
        suppressesInlineChrome = false
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

    /// Reverse an in-flight exit without rebuilding or reparenting the player.
    /// The new opening animation starts from the layer's current presentation
    /// transform, so repeated fullscreen shortcuts remain visually continuous.
    func resumePresentation() {
        guard isPresented,
              isExiting,
              let window,
              let container = window.contentView as? FullscreenWindowContainerView else { return }

        isExiting = false
        suppressesInlineChrome = true
        isRestoringSystemChrome = false
        window.ignoresMouseEvents = false
        enterSystemFullscreenChrome()
        installActivationObserver()
        installEscapeMonitor()
        setFullscreenBackdropOpaque(false, for: window)

        let screen = window.screen ?? screenContaining(window.frame) ?? NSScreen.main
        guard let screen else { return }
        let targetFrame = targetFullscreenFrame(on: screen, excluding: window)

        animateWindow(
            window,
            container: container,
            from: window.frame,
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

    func togglePresentedState() {
        if isExiting {
            resumePresentation()
        } else {
            dismiss()
        }
    }

    func dismissImmediately() {
        cancelTransition()
        PlayerClipContainerView.beginFullscreenToInlineHandoff()
        suppressesInlineChrome = false
        isPresented = false
        isExiting = false
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
        suppressesInlineChrome = false
        isPresented = false
        isExiting = false
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
        removeActivationObserver()
        exitSystemFullscreenChrome()
        window = nil
        sourceFrameProvider = nil
        suppressesInlineChrome = false
        isPresented = false
        isExiting = false
        isRestoringSystemChrome = false
        removeEscapeMonitor()
        Self.restoreMainWindowAppearance()
        NotificationCenter.default.post(name: .videoFullscreenDidFinishExit, object: nil)
    }

    private func setFullscreenBackdropOpaque(_ opaque: Bool, for window: NSWindow) {
        window.isOpaque = opaque
        window.backgroundColor = opaque ? .black : .clear
    }

    private func enterSystemFullscreenChrome() {
        if savedPresentationOptions == nil {
            savedPresentationOptions = NSApp.presentationOptions
        }
        applySystemFullscreenChrome()
        DispatchQueue.main.async { [weak self] in
            self?.applySystemFullscreenChrome()
        }
    }

    private func applySystemFullscreenChrome() {
        guard isPresented, !isRestoringSystemChrome else { return }
        // Never force-activate while the user is switching away; that would yank
        // focus back from the Dock / destination app.
        if NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        // Match native macOS fullscreen behavior: the menu bar and Dock remain
        // hidden until the pointer reaches their screen edge, then reappear.
        var options: NSApplication.PresentationOptions = [
            .autoHideMenuBar,
            .autoHideDock,
        ]
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
    }

    private func prepareForSystemChromeRestoration(window: NSWindow, activateMainWindow: Bool) {
        isRestoringSystemChrome = true
        removeActivationObserver()
        window.ignoresMouseEvents = true
        exitSystemFullscreenChrome()
        if activateMainWindow {
            NSApp.mainWindow?.makeKeyAndOrderFront(nil)
        } else {
            // Restore inline chrome visibility without ordering this app front.
            Self.restoreMainWindowAppearance()
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
        let interruptedTransform = cancelTransition(preservingPresentationTransform: true)
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
        let startTransform = interruptedTransform
            ?? contentTransform(layer: contentLayer, to: localStartFrame)
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

    @discardableResult
    private func cancelTransition(
        preservingPresentationTransform: Bool = false
    ) -> CATransform3D? {
        let interruptedTransform = preservingPresentationTransform
            ? transitionContentLayer?.presentation()?.transform
            : nil
        transitionGeneration &+= 1
        transitionContentLayer?.removeAnimation(forKey: "fullscreenTransition")
        transitionContentLayer?.transform = interruptedTransform ?? CATransform3DIdentity
        transitionContentLayer = nil
        (window?.contentView as? FullscreenWindowContainerView)?.setContentVisible(true)
        return interruptedTransform
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
        return super.hitTest(point)
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
