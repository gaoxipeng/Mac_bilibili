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
    private var transitionTimer: Timer?
    private var transitionDriver: WindowTransitionDriver?

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

        let container = FullscreenWindowContainerView(contentView: hosting)
        container.frame = NSRect(origin: .zero, size: sourceFrame.size)
        container.cornerRadius = 14
        container.transitionProgress = 0

        let window = NSWindow(
            contentRect: sourceFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.displaysWhenScreenProfileChanges = true
        window.contentView = container
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.98
        window.makeKeyAndOrderFront(nil)

        self.window = window
        isPresented = true
        installEscapeMonitor()

        animateWindow(
            window,
            container: container,
            from: sourceFrame,
            to: screen.frame,
            duration: 0.54,
            mainWindowAlpha: 0.72,
            opening: true
        ) {
            window.setFrame(screen.frame, display: true)
            window.alphaValue = 1
            container.cornerRadius = 0
            container.transitionProgress = 1
        }
    }

    func dismiss() {
        guard isPresented, let window, let container = window.contentView as? FullscreenWindowContainerView else {
            dismissImmediately()
            return
        }

        let targetFrame = sourceFrameProvider?() ?? window.frame
        removeEscapeMonitor()

        animateWindow(
            window,
            container: container,
            from: window.frame,
            to: targetFrame,
            duration: 0.46,
            mainWindowAlpha: 1,
            opening: false
        ) { [weak self] in
            window.orderOut(nil)
            self?.isPresented = false
            self?.cleanup()
        }
    }

    func dismissImmediately() {
        cancelTransition()
        window?.orderOut(nil)
        cleanup()
    }

    static func restoreMainWindowAppearance() {
        for window in NSApp.windows where window.level == .normal && window.isVisible {
            window.alphaValue = 1
        }
    }

    private func cleanup() {
        cancelTransition()
        window = nil
        sourceFrameProvider = nil
        isPresented = false
        removeEscapeMonitor()
        Self.restoreMainWindowAppearance()
    }

    private func screenContaining(_ frame: NSRect) -> NSScreen? {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main
    }

    private func fadeMainWindow(to alpha: CGFloat, duration: TimeInterval) {
        guard let mainWindow = NSApp.mainWindow, mainWindow !== window else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            mainWindow.animator().alphaValue = alpha
        }
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

        let startTime = CACurrentMediaTime()
        let startMainAlpha = NSApp.mainWindow === window ? 1 : (NSApp.mainWindow?.alphaValue ?? 1)
        let mainWindow = NSApp.mainWindow === window ? nil : NSApp.mainWindow
        let startCorner = container.cornerRadius
        let endCorner: CGFloat = opening ? 0 : 14
        let startProgress = container.transitionProgress
        let endProgress: CGFloat = opening ? 1 : 0

        window.setFrame(startFrame, display: true)
        window.alphaValue = opening ? 0.985 : 1

        let driver = WindowTransitionDriver()
        driver.presenter = self
        driver.window = window
        driver.container = container
        driver.mainWindow = mainWindow
        driver.startTime = startTime
        driver.duration = duration
        driver.startFrame = startFrame
        driver.endFrame = endFrame
        driver.startMainAlpha = startMainAlpha
        driver.targetMainWindowAlpha = targetMainWindowAlpha
        driver.startCorner = startCorner
        driver.endCorner = endCorner
        driver.startProgress = startProgress
        driver.endProgress = endProgress
        driver.opening = opening
        driver.completion = completion

        let timer = Timer(
            timeInterval: 1.0 / 120.0,
            target: driver,
            selector: #selector(WindowTransitionDriver.tick(_:)),
            userInfo: nil,
            repeats: true
        )
        driver.timer = timer
        transitionDriver = driver
        transitionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func cancelTransition() {
        transitionTimer?.invalidate()
        transitionTimer = nil
        transitionDriver = nil
    }

    fileprivate func finishTransition(timer: Timer) {
        transitionTimer = nil
        transitionDriver = nil
        timer.invalidate()
    }

    private nonisolated static func safariFullscreenEase(_ progress: CGFloat, opening: Bool) -> CGFloat {
        let p = progress.clamped(to: 0...1)
        if opening {
            return cubicBezier(p, x1: 0.16, y1: 1.0, x2: 0.30, y2: 1.0)
        }
        return cubicBezier(p, x1: 0.40, y1: 0.0, x2: 0.20, y2: 1.0)
    }

    private nonisolated static func cubicBezier(_ x: CGFloat, x1: CGFloat, y1: CGFloat, x2: CGFloat, y2: CGFloat) -> CGFloat {
        var t = x
        for _ in 0..<5 {
            let currentX = bezier(t, 0, x1, x2, 1)
            let derivative = bezierDerivative(t, 0, x1, x2, 1)
            guard abs(derivative) > 0.001 else { break }
            t -= (currentX - x) / derivative
            t = t.clamped(to: 0...1)
        }
        return bezier(t, 0, y1, y2, 1).clamped(to: 0...1)
    }

    private nonisolated static func bezier(_ t: CGFloat, _ p0: CGFloat, _ p1: CGFloat, _ p2: CGFloat, _ p3: CGFloat) -> CGFloat {
        let oneMinusT = 1 - t
        return oneMinusT * oneMinusT * oneMinusT * p0
            + 3 * oneMinusT * oneMinusT * t * p1
            + 3 * oneMinusT * t * t * p2
            + t * t * t * p3
    }

    private nonisolated static func bezierDerivative(_ t: CGFloat, _ p0: CGFloat, _ p1: CGFloat, _ p2: CGFloat, _ p3: CGFloat) -> CGFloat {
        let oneMinusT = 1 - t
        return 3 * oneMinusT * oneMinusT * (p1 - p0)
            + 6 * oneMinusT * t * (p2 - p1)
            + 3 * t * t * (p3 - p2)
    }

    private nonisolated static func interpolateRect(from start: NSRect, to end: NSRect, progress: CGFloat) -> NSRect {
        NSRect(
            x: interpolate(from: start.origin.x, to: end.origin.x, progress: progress),
            y: interpolate(from: start.origin.y, to: end.origin.y, progress: progress),
            width: interpolate(from: start.width, to: end.width, progress: progress),
            height: interpolate(from: start.height, to: end.height, progress: progress)
        )
    }

    private nonisolated static func interpolate(from start: CGFloat, to end: CGFloat, progress: CGFloat) -> CGFloat {
        start + (end - start) * progress
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

    @MainActor
    private final class WindowTransitionDriver: NSObject {
        weak var presenter: VideoFullscreenPresenter?
        weak var window: NSWindow?
        weak var container: FullscreenWindowContainerView?
        weak var mainWindow: NSWindow?
        weak var timer: Timer?

        var startTime: CFTimeInterval = 0
        var duration: TimeInterval = 0
        var startFrame = NSRect.zero
        var endFrame = NSRect.zero
        var startMainAlpha: CGFloat = 1
        var targetMainWindowAlpha: CGFloat = 1
        var startCorner: CGFloat = 0
        var endCorner: CGFloat = 0
        var startProgress: CGFloat = 0
        var endProgress: CGFloat = 0
        var opening = false
        var completion: (@MainActor () -> Void)?

        @MainActor
        @objc func tick(_ timer: Timer) {
            guard let presenter, let window, let container else {
                presenter?.finishTransition(timer: timer)
                return
            }

            let elapsed = CACurrentMediaTime() - startTime
            let rawProgress = min(1, max(0, elapsed / duration))
            let eased = VideoFullscreenPresenter.safariFullscreenEase(CGFloat(rawProgress), opening: opening)

            window.setFrame(VideoFullscreenPresenter.interpolateRect(from: startFrame, to: endFrame, progress: eased), display: true)
            window.alphaValue = opening
                ? VideoFullscreenPresenter.interpolate(from: 0.985, to: 1, progress: eased)
                : VideoFullscreenPresenter.interpolate(from: 1, to: 0.985, progress: eased)
            container.cornerRadius = VideoFullscreenPresenter.interpolate(from: startCorner, to: endCorner, progress: eased)
            container.transitionProgress = VideoFullscreenPresenter.interpolate(from: startProgress, to: endProgress, progress: eased)
            mainWindow?.alphaValue = VideoFullscreenPresenter.interpolate(from: startMainAlpha, to: targetMainWindowAlpha, progress: eased)

            if rawProgress >= 1 {
                mainWindow?.alphaValue = targetMainWindowAlpha
                presenter.finishTransition(timer: timer)
                completion?()
            }
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

    private func updateCornerMask() {
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = cornerRadius > 0
    }

    private func updateTransitionAppearance() {
        wantsLayer = true
        let progress = transitionProgress.clamped(to: 0...1)
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.88 + 0.12 * progress).cgColor
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
