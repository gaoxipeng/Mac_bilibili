import AppKit
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
    @MainActor
    static func adjust(by delta: Float) {
        guard let current = currentVolume() else { return }
        setVolume((current + delta).clamped(to: 0...1))
    }

    private static func currentVolume() -> Float? {
        guard let deviceID = defaultOutputDeviceID() else { return nil }
        if let master = volume(deviceID: deviceID, element: kAudioObjectPropertyElementMain) {
            return master
        }
        let channels = outputChannels(deviceID: deviceID)
        let values = channels.compactMap { volume(deviceID: deviceID, element: $0) }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Float(values.count)
    }

    private static func setVolume(_ volume: Float) {
        guard let deviceID = defaultOutputDeviceID() else { return }
        if setVolume(volume, deviceID: deviceID, element: kAudioObjectPropertyElementMain) {
            return
        }
        for channel in outputChannels(deviceID: deviceID) {
            _ = setVolume(volume, deviceID: deviceID, element: channel)
        }
    }

    private static func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
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

    private static func volume(deviceID: AudioDeviceID, element: AudioObjectPropertyElement) -> Float? {
        var address = volumeAddress(element: element)
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume)
        guard status == noErr else { return nil }
        return volume
    }

    private static func setVolume(
        _ volume: Float,
        deviceID: AudioDeviceID,
        element: AudioObjectPropertyElement
    ) -> Bool {
        var address = volumeAddress(element: element)
        guard AudioObjectHasProperty(deviceID, &address) else {
            return false
        }
        var isSettable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(deviceID, &address, &isSettable) == noErr,
              isSettable.boolValue else { return false }
        var value = Float32(volume)
        let size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &value)
        return status == noErr
    }

    private static func volumeAddress(element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
    }

    private static func outputChannels(deviceID: AudioDeviceID) -> [AudioObjectPropertyElement] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioBufferList>.size) else {
            return [1, 2]
        }
        let bufferList = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufferList.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, bufferList) == noErr else {
            return [1, 2]
        }
        let audioBufferList = UnsafeMutableAudioBufferListPointer(bufferList.assumingMemoryBound(to: AudioBufferList.self))
        let channelCount = audioBufferList.reduce(0) { partial, buffer in
            partial + Int(buffer.mNumberChannels)
        }
        guard channelCount > 0 else { return [1, 2] }
        return (1...channelCount).map(AudioObjectPropertyElement.init)
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

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
