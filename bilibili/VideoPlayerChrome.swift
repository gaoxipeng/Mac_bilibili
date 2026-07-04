import AppKit
import Combine
import CoreGraphics
import SwiftUI

@MainActor
final class VideoPlayerChromeState: ObservableObject {
    @Published private(set) var showsControls = true

    private var hideTask: Task<Void, Never>?
    private static let autoHideDelay: Duration = .seconds(5)

    func revealControls(scheduleAutoHide: Bool = true) {
        showsControls = true
        hideTask?.cancel()
        hideTask = nil
        guard scheduleAutoHide else { return }
        hideTask = Task {
            try? await Task.sleep(for: Self.autoHideDelay)
            guard !Task.isCancelled else { return }
            showsControls = false
        }
    }

    func showControlsPersistently() {
        hideTask?.cancel()
        hideTask = nil
        showsControls = true
    }

    func reset() {
        hideTask?.cancel()
        hideTask = nil
        showsControls = true
    }
}

struct VideoPlayerKeyboardHandlers {
    var isFullscreen = false
    var shouldHandle: () -> Bool = { true }
    var onInteraction: () -> Void = {}
    var onTogglePlayback: () -> Void = {}
    var onSeekBackward: () -> Void = {}
    var onSeekForward: () -> Void = {}
    var onVolumeUp: () -> Void = {}
    var onVolumeDown: () -> Void = {}
    var onToggleFullscreen: () -> Void = {}
    var onExitFullscreen: () -> Void = {}
    var onToggleMute: () -> Void = {}
    var onToggleDanmaku: () -> Void = {}
}

struct VideoPlayerKeyboardMonitor: NSViewRepresentable {
    var handlers: VideoPlayerKeyboardHandlers

    func makeNSView(context: Context) -> VideoPlayerKeyboardMonitorView {
        let view = VideoPlayerKeyboardMonitorView()
        view.handlers = handlers
        return view
    }

    func updateNSView(_ nsView: VideoPlayerKeyboardMonitorView, context: Context) {
        nsView.handlers = handlers
    }

    static func dismantleNSView(_ nsView: VideoPlayerKeyboardMonitorView, coordinator: ()) {
        nsView.tearDownMonitor()
    }
}

@MainActor
final class VideoPlayerKeyboardMonitorView: NSView {
    var handlers = VideoPlayerKeyboardHandlers()
    private var keyMonitor: Any?

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            installMonitorIfNeeded()
        } else {
            tearDownMonitor()
        }
    }

    func installMonitorIfNeeded() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let handlers = self.handlers
            if handlers.isFullscreen {
                guard handlers.shouldHandle() else { return event }
                return self.handleKeyEvent(event) ? nil : event
            }
            guard handlers.shouldHandle() else { return event }
            guard self.shouldReceiveKeyboardEvent(event) else { return event }
            return self.handleKeyEvent(event) ? nil : event
        }
    }

    func tearDownMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private func shouldReceiveKeyboardEvent(_ event: NSEvent) -> Bool {
        guard let window else { return false }
        guard let eventWindow = event.window ?? NSApp.keyWindow else { return false }
        return eventWindow === window
    }

    func handleKeyEvent(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else {
            return false
        }

        handlers.onInteraction()

        switch event.keyCode {
        case 49:
            handlers.onTogglePlayback()
            return true
        case 123:
            handlers.onSeekBackward()
            return true
        case 124:
            handlers.onSeekForward()
            return true
        case 126:
            handlers.onVolumeUp()
            return true
        case 125:
            handlers.onVolumeDown()
            return true
        case 53:
            if handlers.isFullscreen {
                handlers.onExitFullscreen()
                return true
            }
            return false
        default:
            break
        }

        guard let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        switch key {
        case "f":
            handlers.onToggleFullscreen()
            return true
        case "m":
            handlers.onToggleMute()
            return true
        case "d":
            handlers.onToggleDanmaku()
            return true
        default:
            return false
        }
    }
}

enum SystemAudioVolume {
    private enum MediaKey {
        static let soundUp: Int32 = 0
        static let soundDown: Int32 = 1
    }

    private static var didRequestPostEventAccess = false
    private static var didShowHUDPermissionHint = false

    @MainActor
    static func adjust(by delta: Float) {
        guard delta != 0 else { return }

        let mediaKey = delta > 0 ? MediaKey.soundUp : MediaKey.soundDown
        requestPostEventAccessIfNeeded()
        postVolumeKey(mediaKey)

        if !CGPreflightPostEventAccess() {
            promptForHUDAccessIfNeeded()
        }
    }

    @MainActor
    private static func requestPostEventAccessIfNeeded() {
        guard !CGPreflightPostEventAccess(), !didRequestPostEventAccess else { return }
        didRequestPostEventAccess = true
        _ = CGRequestPostEventAccess()
    }

    @MainActor
    private static func postVolumeKey(_ keyCode: Int32) {
        for isKeyDown in [true, false] {
            let keyState = isKeyDown ? 0xA00 : 0xB00
            let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(keyState)),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: Int((Int(keyCode) << 16) | keyState),
                data2: -1
            )
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    @MainActor
    private static func promptForHUDAccessIfNeeded() {
        guard !didShowHUDPermissionHint else { return }
        didShowHUDPermissionHint = true

        let alert = NSAlert()
        alert.messageText = "需要辅助功能权限以显示系统音量条"
        alert.informativeText = """
        上下方向键要弹出系统音量条，需要在「系统设置 → 隐私与安全性 → 辅助功能」中允许 bilibili。

        授权后请完全退出并重新打开应用。
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")

        if let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible) {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn {
                    openAccessibilitySettings()
                }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            openAccessibilitySettings()
        }
    }

    @MainActor
    private static func openAccessibilitySettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
        ]
        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            if NSWorkspace.shared.open(url) {
                return
            }
        }
    }
}

enum VideoPlayerKeyboardRouting {
    @MainActor
    static func shouldHandleInVideoDetail(in window: NSWindow? = nil) -> Bool {
        let targetWindow = window ?? NSApp.keyWindow
        guard let responder = targetWindow?.firstResponder else { return true }
        if let textView = responder as? NSTextView, textView.isEditable {
            return false
        }
        if let textField = responder as? NSTextField, textField.isEditable {
            return false
        }
        return true
    }
}
