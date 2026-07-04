import AppKit
import ApplicationServices
import Combine
import CoreAudio
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
            guard let window, event.window === window else { return event }
            guard handlers.shouldHandle() else { return event }
            return self.handleKeyEvent(event) ? nil : event
        }
    }

    func tearDownMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
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

    private static let step: Float = 1.0 / 16.0
    private static var didPromptAccessibilityThisSession = false
    private static var didShowAccessibilityAlertThisSession = false

    @MainActor
    static func increase() {
        adjust(by: step)
    }

    @MainActor
    static func decrease() {
        adjust(by: -step)
    }

    @MainActor
    static func adjust(by delta: Float) {
        guard delta != 0 else { return }

        let mediaKey = delta > 0 ? MediaKey.soundUp : MediaKey.soundDown
        if AXIsProcessTrusted() {
            postVolumeKey(mediaKey)
            return
        }

        if adjustUsingCoreAudio(by: delta) || adjustViaAppleScript(by: delta) {
            promptForAccessibilityIfNeeded()
            return
        }

        postVolumeKey(mediaKey)
        promptForAccessibilityIfNeeded()
    }

    @MainActor
    private static func adjustUsingCoreAudio(by delta: Float) -> Bool {
        guard let deviceID = defaultOutputDeviceID() else { return false }
        guard var volume = readVolume(deviceID: deviceID) else { return false }
        volume = min(1, max(0, volume + delta))
        return writeVolume(deviceID: deviceID, volume: volume)
    }

    private static func defaultOutputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    private static func readVolume(deviceID: AudioDeviceID) -> Float? {
        if let volume = readVirtualMainVolume(deviceID: deviceID) {
            return volume
        }
        return readScalarVolume(deviceID: deviceID)
    }

    private static func writeVolume(deviceID: AudioDeviceID, volume: Float) -> Bool {
        if writeVirtualMainVolume(deviceID: deviceID, volume: volume) {
            return true
        }
        return writeScalarVolume(deviceID: deviceID, volume: volume)
    }

    private static let virtualMainVolumeSelector: AudioObjectPropertySelector = 0x766D_7663 // 'vmvc'

    private static func readVirtualMainVolume(deviceID: AudioDeviceID) -> Float? {
        var volume = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: virtualMainVolumeSelector,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume)
        guard status == noErr else { return nil }
        return Float(volume)
    }

    private static func writeVirtualMainVolume(deviceID: AudioDeviceID, volume: Float) -> Bool {
        var mutableVolume = Float32(volume)
        var address = AudioObjectPropertyAddress(
            mSelector: virtualMainVolumeSelector,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        let status = AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<Float32>.size),
            &mutableVolume
        )
        return status == noErr
    }

    private static func readScalarVolume(deviceID: AudioDeviceID) -> Float? {
        var volume = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume)
        guard status == noErr else { return nil }
        return Float(volume)
    }

    private static func writeScalarVolume(deviceID: AudioDeviceID, volume: Float) -> Bool {
        var mutableVolume = Float32(volume)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        let status = AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<Float32>.size),
            &mutableVolume
        )
        return status == noErr
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
    private static func adjustViaAppleScript(by delta: Float) -> Bool {
        guard let current = readOutputVolumePercent() else { return false }
        let next = min(100, max(0, current + Int((delta * 100).rounded())))
        guard next != current else { return true }
        return setOutputVolumePercent(next)
    }

    @MainActor
    private static func readOutputVolumePercent() -> Int? {
        var error: NSDictionary?
        let script = NSAppleScript(source: "output volume of (get volume settings)")
        guard let descriptor = script?.executeAndReturnError(&error), error == nil else { return nil }
        let value = descriptor.int32Value
        guard value >= 0 else { return nil }
        return Int(value)
    }

    @MainActor
    private static func setOutputVolumePercent(_ value: Int) -> Bool {
        var error: NSDictionary?
        let script = NSAppleScript(source: "set volume output volume \(value)")
        script?.executeAndReturnError(&error)
        return error == nil
    }

    @MainActor
    private static func promptForAccessibilityIfNeeded() {
        if AXIsProcessTrusted() {
            return
        }

        if !didPromptAccessibilityThisSession {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            didPromptAccessibilityThisSession = true
        }

        guard !didShowAccessibilityAlertThisSession else { return }
        didShowAccessibilityAlertThisSession = true

        let alert = NSAlert()
        alert.messageText = "需要辅助功能权限"
        alert.informativeText = "上下方向键调节系统音量时，需要在「系统设置 → 隐私与安全性 → 辅助功能」中允许 bilibili 控制你的 Mac。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")

        if let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible) {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn {
                    openAccessibilitySettings()
                }
            }
        } else {
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                openAccessibilitySettings()
            }
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
