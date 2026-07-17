import AppKit
import Libmpv
import Metal
import OSLog
import QuartzCore

private final class MPVMetalLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            guard newValue.width > 1, newValue.height > 1 else { return }
            super.drawableSize = newValue
        }
    }

    override var wantsExtendedDynamicRangeContent: Bool {
        get { super.wantsExtendedDynamicRangeContent }
        set {
            if Thread.isMainThread {
                super.wantsExtendedDynamicRangeContent = newValue
            } else {
                DispatchQueue.main.sync { super.wantsExtendedDynamicRangeContent = newValue }
            }
        }
    }
}

private final class MPVCallbackContext: @unchecked Sendable {
    weak var view: MPVRenderView?

    init(view: MPVRenderView) {
        self.view = view
    }
}

private final class MPVMetalBufferPool: @unchecked Sendable {
    private let lock = NSLock()
    private var available: [MTLBuffer] = []
    private var stopped = false

    func take(device: MTLDevice, minimumLength: Int) -> MTLBuffer? {
        lock.lock()
        available.removeAll { $0.length < minimumLength }
        let buffer = available.popLast()
        let isStopped = stopped
        lock.unlock()
        guard !isStopped else { return nil }
        return buffer ?? device.makeBuffer(length: minimumLength, options: .storageModeShared)
    }

    func put(_ buffer: MTLBuffer) {
        lock.lock()
        if !stopped, available.count < 3 {
            available.append(buffer)
        }
        lock.unlock()
    }

    func stop() {
        lock.lock()
        stopped = true
        available.removeAll()
        lock.unlock()
    }
}

private final class MPVSoftwareMetalRenderer: @unchecked Sendable {
    private let layer: CAMetalLayer
    private let queue = DispatchQueue(label: "bilibili.mpv.metal-render", qos: .userInteractive)
    private let commandQueue: MTLCommandQueue
    private let inFlightFrames = DispatchSemaphore(value: 3)
    private let bufferPool = MPVMetalBufferPool()
    private let displayStateLock = NSLock()
    private var displayAvailable = true
    private var context: OpaquePointer?
    private var drawPending = false
    private var stopped = false

    init?(layer: CAMetalLayer) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else { return nil }
        self.layer = layer
        self.commandQueue = commandQueue
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
        layer.isOpaque = true
        layer.presentsWithTransaction = false
        layer.maximumDrawableCount = 3
        // When the display is off, WindowServer may temporarily stop vending
        // drawables. Never let the serial mpv render queue wait forever.
        layer.allowsNextDrawableTimeout = true
    }

    func createContext(for mpv: OpaquePointer) -> Int32 {
        var api = Array("sw".utf8CString)
        return api.withUnsafeMutableBufferPointer { apiBuffer in
            var params = [
                mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: apiBuffer.baseAddress),
                mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
            ]
            return mpv_render_context_create(&context, mpv, &params)
        }
    }

    func start() {
        resumeAfterDisplayWake()
    }

    func suspendForDisplaySleep() {
        setDisplayAvailable(false)
        guard !stopped, let context else { return }
        // Removing the callback prevents mpv from submitting more draw work.
        // Drain work that passed requestDraw's availability check before the
        // screen-sleep notification so it cannot touch a withdrawn drawable.
        mpv_render_context_set_update_callback(context, nil, nil)
        queue.sync {}
    }

    func resumeAfterDisplayWake() {
        guard !stopped, let context else { return }
        mpv_render_context_set_update_callback(context, { opaque in
            guard let opaque else { return }
            Unmanaged<MPVSoftwareMetalRenderer>.fromOpaque(opaque)
                .takeUnretainedValue().requestDraw()
        }, Unmanaged.passUnretained(self).toOpaque())
        setDisplayAvailable(true)
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        bufferPool.stop()
        if let context {
            mpv_render_context_set_update_callback(context, nil, nil)
            queue.sync { mpv_render_context_free(context) }
            self.context = nil
        }
    }

    func requestDraw() {
        queue.async { [weak self] in
            guard let self, !self.stopped, self.isDisplayAvailable, !self.drawPending else { return }
            self.drawPending = true
            self.draw()
            self.drawPending = false
        }
    }

    func setDisplayAvailable(_ available: Bool) {
        displayStateLock.lock()
        displayAvailable = available
        displayStateLock.unlock()
        if available {
            requestDraw()
        }
    }

    private var isDisplayAvailable: Bool {
        displayStateLock.lock()
        let available = displayAvailable
        displayStateLock.unlock()
        return available
    }

    private func draw() {
        guard isDisplayAvailable, let context, let drawable = layer.nextDrawable() else { return }
        let width = drawable.texture.width
        let height = drawable.texture.height
        guard width > 1, height > 1 else { return }
        guard inFlightFrames.wait(timeout: .now()) == .success else { return }

        let bytesPerRow = ((width * 4 + 63) / 64) * 64
        let requiredLength = bytesPerRow * height
        guard let device = layer.device,
              let buffer = bufferPool.take(device: device, minimumLength: requiredLength) else {
            inFlightFrames.signal()
            return
        }

        var size = [Int32(width), Int32(height)]
        var stride = bytesPerRow
        var format = Array("bgr0".utf8CString)
        let result: Int32 = size.withUnsafeMutableBufferPointer { sizeBuffer in
            format.withUnsafeMutableBufferPointer { formatBuffer in
                withUnsafeMutablePointer(to: &stride) { stridePointer in
                    var params = [
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_SIZE, data: sizeBuffer.baseAddress),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_FORMAT, data: formatBuffer.baseAddress),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_STRIDE, data: stridePointer),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_POINTER, data: buffer.contents()),
                        mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                    ]
                    return mpv_render_context_render(context, &params)
                }
            }
        }
        guard result >= 0,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            bufferPool.put(buffer)
            inFlightFrames.signal()
            return
        }
        blit.copy(
            from: buffer,
            sourceOffset: 0,
            sourceBytesPerRow: bytesPerRow,
            sourceBytesPerImage: requiredLength,
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: drawable.texture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
        let frameSemaphore = inFlightFrames
        let completedBufferPool = bufferPool
        commandBuffer.addCompletedHandler { _ in
            completedBufferPool.put(buffer)
            frameSemaphore.signal()
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
        // MTLCommandBuffer retains encoded resources until GPU completion.
        // Never wait synchronously here: after display sleep/wake Metal may
        // temporarily stop completing presents, and a blocking wait would also
        // prevent the player from shutting down or responding to AppKit events.
    }
}

@MainActor
final class MPVRenderView: NSView {
    private static let playbackLogger = Logger(subsystem: "gaoxipeng.bilibili", category: "Playback")

    var onTimeChanged: ((Double) -> Void)?
    var onDurationChanged: ((Double) -> Void)?
    var onPauseChanged: ((Bool) -> Void)?
    var onVideoSizeChanged: ((CGSize) -> Void)?
    var onReady: (() -> Void)?
    var onEnded: (() -> Void)?
    var onError: ((String) -> Void)?

    private var mpv: OpaquePointer?
    private let eventQueue = DispatchQueue(label: "bilibili.mpv.events", qos: .userInitiated)
    private let metalLayer = MPVMetalLayer()
    private var metalRenderer: MPVSoftwareMetalRenderer?
    private var isConfigured = false
    private var mpvCoreReady = false
    private var pendingAudioURL: String?
    private var remainingVideoURLs: [String] = []
    private var loadOptions: [String] = []
    private var currentFileLoaded = false
    private var callbackContext: Unmanaged<MPVCallbackContext>?
    private var geometryObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var lastDrawablePixelSize = CGSize.zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureView()
    }

    private func configureView() {
        guard !isConfigured else { return }
        isConfigured = true
        autoresizingMask = [.width, .height]
        metalLayer.backgroundColor = NSColor.black.cgColor
        metalLayer.frame = bounds
        metalLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer = metalLayer
        wantsLayer = true
        postsFrameChangedNotifications = true
        postsBoundsChangedNotifications = true
        geometryObservers = [
            NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: self,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.updateMetalLayerGeometry() }
            },
            NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: self,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.updateMetalLayerGeometry() }
            },
        ]
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            workspaceCenter.addObserver(
                forName: NSWorkspace.screensDidSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.screenDidSleep() }
            },
            workspaceCenter.addObserver(
                forName: NSWorkspace.screensDidWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.screenDidWake() }
            },
        ]
        updateMetalLayerGeometry()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        MainActor.assumeIsolated {
            for observer in geometryObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            let workspaceCenter = NSWorkspace.shared.notificationCenter
            for observer in workspaceObservers {
                workspaceCenter.removeObserver(observer)
            }
            shutdown()
        }
    }

    private func screenDidSleep() {
        // Detach and drain rendering before WindowServer withdraws the layer.
        metalRenderer?.suspendForDisplaySleep()
        // Stop audio/decoding while the display is unavailable.
        // Deliberately do not auto-resume playback after unlock.
        setPaused(true)
    }

    private func screenDidWake() {
        updateMetalLayerGeometry()
        metalRenderer?.resumeAfterDisplayWake()
    }

    func load(videoURL: String, fallbackVideoURLs: [String] = [], audioURL: String?, headers: [String: String], start: Double = 0) throws {
        try ensureMPVCore()
        guard mpv != nil else { throw APIError.message("libmpv 初始化失败") }
        setString("http-header-fields", headers.map { "\($0.key): \($0.value)" }.joined(separator: ","))
        pendingAudioURL = audioURL
        remainingVideoURLs = fallbackVideoURLs.filter { !$0.isEmpty && $0 != videoURL }
        loadOptions = start > 0 ? ["start=\(start)"] : []
        currentFileLoaded = false
        try submitLoad(videoURL: videoURL)
    }

    private func submitLoad(videoURL: String) throws {
        let result = command("loadfile", [videoURL, "replace", "-1", loadOptions.joined(separator: ",")])
        Self.playbackLogger.notice("loadfile host=\(URL(string: videoURL)?.host ?? "invalid", privacy: .public) audio=\(self.pendingAudioURL != nil, privacy: .public) result=\(result, privacy: .public)")
        guard result >= 0 else {
            throw APIError.message("mpv 无法提交播放任务：\(String(cString: mpv_error_string(result)))")
        }
    }

    func setPaused(_ paused: Bool) { setFlag("pause", paused) }
    func setMuted(_ muted: Bool) { setFlag("mute", muted) }
    func setVolume(_ volume: Float) { setDouble("volume", Double(volume * 100)) }
    func setSpeed(_ speed: Float) { setDouble("speed", Double(speed)) }
    func seek(to seconds: Double) { command("seek", [String(max(0, seconds)), "absolute+exact"]) }

    func shutdown() {
        let retainedContext = callbackContext
        callbackContext = nil
        guard let handle = mpv else {
            metalRenderer?.stop()
            metalRenderer = nil
            retainedContext?.release()
            return
        }

        // Make the handle unavailable before draining callbacks. A wakeup that
        // was already posted to the main queue will then return without queuing
        // another mpv_wait_event operation.
        mpv = nil
        mpvCoreReady = false
        mpv_set_wakeup_callback(handle, nil, nil)

        metalRenderer?.stop()
        metalRenderer = nil

        // readEvents() consumes the handle on eventQueue. Destroying it on the
        // main actor while that queue is inside mpv_wait_event/log processing
        // is a use-after-free (often surfacing in omp_msg_va after display
        // sleep). Drain all previously submitted event work and destroy the
        // client on that same serial queue.
        eventQueue.sync {
            mpv_terminate_destroy(handle)
        }
        retainedContext?.release()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateMetalLayerGeometry()
        guard window != nil, !mpvCoreReady else { return }
        do {
            try ensureMPVCore()
        } catch {
            reportSetupFailure(error.localizedDescription)
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateMetalLayerGeometry()
    }

    override func layout() {
        super.layout()
        updateMetalLayerGeometry()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateMetalLayerGeometry()
    }

    override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        updateMetalLayerGeometry()
    }

    private func setupMPVCore() {
        guard !mpvCoreReady else { return }
        guard let handle = mpv_create() else { return }
        mpv = handle
        guard let renderer = MPVSoftwareMetalRenderer(layer: metalLayer) else {
            mpv_destroy(handle)
            mpv = nil
            return
        }
        metalRenderer = renderer
        setOption("vo", "libmpv")
        setOption("hwdec", "videotoolbox-copy")
        setOption("ytdl", "no")
        setOption("keep-open", "yes")
        setOption("audio-display", "no")
        // Ask mpv to downmix unusual DASH layouts, while leaving output-device
        // selection and format negotiation automatic. CoreAudio on macOS 27
        // can reject its first layout attempt; mpv's automatic AO path retries
        // successfully, whereas pinning `ao=coreaudio` leaves playback silent.
        setOption("audio-channels", "stereo")
        guard mpv_initialize(handle) >= 0 else {
            metalRenderer = nil
            mpv_destroy(handle)
            mpv = nil
            return
        }
        guard renderer.createContext(for: handle) >= 0 else {
            metalRenderer = nil
            mpv_terminate_destroy(handle)
            mpv = nil
            return
        }
        renderer.start()
        mpv_request_log_messages(handle, "warn")

        let retainedContext = Unmanaged.passRetained(MPVCallbackContext(view: self))
        callbackContext = retainedContext

        observe("time-pos", MPV_FORMAT_DOUBLE)
        observe("duration", MPV_FORMAT_DOUBLE)
        observe("pause", MPV_FORMAT_FLAG)
        observe("video-params/w", MPV_FORMAT_INT64)
        observe("video-params/h", MPV_FORMAT_INT64)
        mpv_set_wakeup_callback(handle, { context in
            guard let context else { return }
            let callback = Unmanaged<MPVCallbackContext>.fromOpaque(context).takeUnretainedValue()
            let view = callback.view
            DispatchQueue.main.async { [weak view] in view?.readEvents() }
        }, retainedContext.toOpaque())
        mpvCoreReady = true
    }

    private func ensureMPVCore() throws {
        if mpv == nil {
            setupMPVCore()
        }
        guard mpv != nil, mpvCoreReady else {
            throw APIError.message("libmpv 初始化失败")
        }
    }

    private func updateMetalLayerGeometry() {
        // Render at logical view resolution. Scaling to Retina pixels here would
        // make libmpv's software color conversion needlessly process 4x pixels.
        let scale: CGFloat = 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.frame = bounds
        metalLayer.contentsScale = scale
        let pixelSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        if pixelSize.width > 1, pixelSize.height > 1 {
            metalLayer.drawableSize = pixelSize
            if pixelSize != lastDrawablePixelSize {
                lastDrawablePixelSize = pixelSize
                Self.playbackLogger.notice("Metal geometry view=\(Int(self.bounds.width), privacy: .public)x\(Int(self.bounds.height), privacy: .public) drawable=\(Int(pixelSize.width), privacy: .public)x\(Int(pixelSize.height), privacy: .public)")
            }
        }
        CATransaction.commit()
        metalRenderer?.requestDraw()
    }

    private func readEvents() {
        guard let handle = mpv else { return }
        let handleAddress = UInt(bitPattern: handle)
        eventQueue.async { [weak self] in
            guard let self, let handle = OpaquePointer(bitPattern: handleAddress) else { return }
            while let event = mpv_wait_event(handle, 0), event.pointee.event_id != MPV_EVENT_NONE {
                self.handle(event.pointee)
            }
        }
    }

    private nonisolated func handle(_ event: mpv_event) {
        switch event.event_id {
        case MPV_EVENT_PROPERTY_CHANGE:
            guard let raw = event.data else { return }
            let property = raw.assumingMemoryBound(to: mpv_event_property.self).pointee
            let name = String(cString: property.name)
            guard let data = property.data else { return }
            switch property.format {
            case MPV_FORMAT_DOUBLE:
                let value = data.assumingMemoryBound(to: Double.self).pointee
                Task { @MainActor in
                    if name == "time-pos" { onTimeChanged?(value) }
                    if name == "duration" { onDurationChanged?(value) }
                }
            case MPV_FORMAT_FLAG:
                let value = data.assumingMemoryBound(to: Int32.self).pointee != 0
                Task { @MainActor in if name == "pause" { onPauseChanged?(value) } }
            default: break
            }
        case MPV_EVENT_FILE_LOADED:
            Task { @MainActor in
                currentFileLoaded = true
                let layerBound = self.layer === self.metalLayer
                Self.playbackLogger.notice("FILE_LOADED vo=\(self.getString("current-vo") ?? "unknown", privacy: .public) metalLayer=\(layerBound, privacy: .public) drawable=\(Int(self.metalLayer.drawableSize.width), privacy: .public)x\(Int(self.metalLayer.drawableSize.height), privacy: .public)")
                if let audioURL = pendingAudioURL {
                    // DASH 的音轨是独立资源。audio-file 是启动选项，运行期修改并不会
                    // 稳定地附着到当前文件；必须等主视频加载完成后显式加入并选中音轨。
                    pendingAudioURL = nil
                    command("audio-add", [audioURL, "select"])
                }
                updateVideoSize()
                onReady?()
            }
        case MPV_EVENT_END_FILE:
            let reason = event.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee
            Task { @MainActor in
                if reason?.reason == MPV_END_FILE_REASON_ERROR {
                    let code = reason?.error ?? Int32(MPV_ERROR_GENERIC.rawValue)
                    Self.playbackLogger.error("END_FILE error=\(code, privacy: .public) message=\(String(cString: mpv_error_string(code)), privacy: .public)")
                    if !currentFileLoaded, !remainingVideoURLs.isEmpty {
                        let nextURL = remainingVideoURLs.removeFirst()
                        Self.playbackLogger.notice("retrying unopened DASH candidate host=\(URL(string: nextURL)?.host ?? "invalid", privacy: .public)")
                        do {
                            try submitLoad(videoURL: nextURL)
                        } catch {
                            onError?(error.localizedDescription)
                        }
                        return
                    }
                    onError?(String(cString: mpv_error_string(code)))
                } else {
                    onEnded?()
                }
            }
        case MPV_EVENT_LOG_MESSAGE:
            guard let raw = event.data else { return }
            let message = raw.assumingMemoryBound(to: mpv_event_log_message.self).pointee
            let level = String(cString: message.level)
            guard level == "warn" || level == "error" || level == "fatal" else { return }
            let text = String(cString: message.text).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            Task { @MainActor in
                Self.playbackLogger.error("mpv: \(text, privacy: .public)")
            }
        default: break
        }
    }

    private func reportSetupFailure(_ message: String) {
        Self.playbackLogger.error("mpv setup failed: \(message, privacy: .public)")
        onError?(message)
    }

    private func updateVideoSize() {
        let width = getInt64("video-params/w")
        let height = getInt64("video-params/h")
        if width > 0, height > 0 {
            Self.playbackLogger.notice("video-size=\(width, privacy: .public)x\(height, privacy: .public)")
            onVideoSizeChanged?(CGSize(width: CGFloat(width), height: CGFloat(height)))
        }
    }

    private func observe(_ name: String, _ format: mpv_format) {
        guard let mpv else { return }
        mpv_observe_property(mpv, 0, name, format)
    }

    @discardableResult
    private func setOption(_ name: String, _ value: String) -> Int32 {
        guard let mpv else { return Int32(MPV_ERROR_UNINITIALIZED.rawValue) }
        let result = mpv_set_option_string(mpv, name, value)
        if result < 0 {
            Self.playbackLogger.error(
                "mpv option rejected name=\(name, privacy: .public) error=\(String(cString: mpv_error_string(result)), privacy: .public)"
            )
        }
        return result
    }

    private func setString(_ name: String, _ value: String) {
        guard let mpv else { return }
        mpv_set_property_string(mpv, name, value)
    }

    private func setFlag(_ name: String, _ value: Bool) {
        guard let mpv else { return }
        var raw: Int32 = value ? 1 : 0
        mpv_set_property(mpv, name, MPV_FORMAT_FLAG, &raw)
    }

    private func setDouble(_ name: String, _ value: Double) {
        guard let mpv else { return }
        var raw = value
        mpv_set_property(mpv, name, MPV_FORMAT_DOUBLE, &raw)
    }

    private func getInt64(_ name: String) -> Int64 {
        guard let mpv else { return 0 }
        var value: Int64 = 0
        mpv_get_property(mpv, name, MPV_FORMAT_INT64, &value)
        return value
    }

    private func getString(_ name: String) -> String? {
        guard let mpv, let value = mpv_get_property_string(mpv, name) else { return nil }
        defer { mpv_free(value) }
        return String(cString: value)
    }

    @discardableResult
    private func command(_ name: String, _ args: [String]) -> Int32 {
        guard let mpv else { return Int32(MPV_ERROR_UNINITIALIZED.rawValue) }
        let strings: [String?] = [name] + args.map(Optional.some) + [nil]
        var pointers: [UnsafePointer<CChar>?] = strings.map { value in
            value.flatMap { UnsafePointer<CChar>(strdup($0)) }
        }
        defer {
            for pointer in pointers where pointer != nil {
                free(UnsafeMutablePointer(mutating: pointer!))
            }
        }
        return mpv_command(mpv, &pointers)
    }

}
