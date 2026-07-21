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
                // Never sync back to the main actor from the Metal render queue.
                // `shutdown` / display-sleep drain that queue with `queue.sync`
                // on the main thread; a nested main.sync here deadlocks the UI
                // and can leave libmpv mid-log (mp_msg_va EXC_BAD_ACCESS).
                DispatchQueue.main.async {
                    super.wantsExtendedDynamicRangeContent = newValue
                }
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
        let alreadyAvailable = available.contains { $0 === buffer }
        if !stopped, !alreadyAvailable, available.count < 3 {
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
    private var wantsDraw = false
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
        // Upscale native-resolution SW frames on the GPU instead of rasterizing
        // at full Retina drawable size on the CPU.
        layer.contentsGravity = .resizeAspect
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
            guard let self, !self.stopped, self.isDisplayAvailable else { return }
            if self.drawPending {
                self.wantsDraw = true
                return
            }
            repeat {
                self.wantsDraw = false
                self.drawPending = true
                self.draw()
                self.drawPending = false
            } while self.wantsDraw && !self.stopped && self.isDisplayAvailable
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
        // Skip full-frame memset: render targets match the video DAR and mpv
        // fills the buffer. Zeroing multi‑MB Retina frames dominated CPU use.

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
    /// Bumped on shutdown so already-posted main-queue drains bail out before destroy.
    private var eventSessionID: UInt64 = 0
    private let metalLayer = MPVMetalLayer()
    private var metalRenderer: MPVSoftwareMetalRenderer?
    private var isConfigured = false
    private var mpvCoreReady = false
    private var pendingAudioURL: String?
    private var remainingVideoURLs: [String] = []
    private var loadOptions: [String] = []
    private var currentFileLoaded = false
    private var callbackContext: Unmanaged<MPVCallbackContext>?
    private var isEventDrainScheduled = false
    private var eventWakePending = false
    private var geometryObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var lastDrawablePixelSize = CGSize.zero
    private var videoFramePixelSize = CGSize.zero
    private var seamlessResizeGeneration = 0
    private var isDeferringDrawableResize = false

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
        metalLayer.masksToBounds = true
        layer = metalLayer
        wantsLayer = true
        clipsToBounds = true
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
        videoFramePixelSize = .zero
        lastDrawablePixelSize = .zero
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

    /// Re-present the current frame after the Metal view is reparented/resized.
    /// Needed especially while paused — mpv won't push a new frame on its own,
    /// so a handoff from fullscreen back to the inline card can leave a black layer.
    func refreshPresentation() {
        layoutSubtreeIfNeeded()
        updateMetalLayerGeometry()
        metalRenderer?.requestDraw()

        if getFlag("pause") {
            let seconds = getDouble("time-pos")
            if seconds.isFinite, seconds >= 0 {
                // Force libmpv to rebuild a video frame for the new drawable size.
                seek(to: seconds)
            }
        }

        // Seek + Metal present are both async; kick a few follow-up redraws.
        for delay in [0.02, 0.06, 0.12] as [TimeInterval] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.updateMetalLayerGeometry()
                self.metalRenderer?.requestDraw()
            }
        }
    }

    /// Keep the last presented CAMetalLayer drawable alive while AppKit moves
    /// this view between the fullscreen and inline windows. Resizing the
    /// drawable immediately discards that frame before mpv can present the
    /// first frame at the new size, which appears as a brief black flash.
    func beginSeamlessReparent() {
        seamlessResizeGeneration &+= 1
        let generation = seamlessResizeGeneration
        isDeferringDrawableResize = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self, self.seamlessResizeGeneration == generation else { return }
            self.isDeferringDrawableResize = false
            self.updateMetalLayerGeometry()
            self.metalRenderer?.requestDraw()
        }
    }

    func shutdown() {
        let retainedContext = callbackContext
        callbackContext = nil
        guard let handle = mpv else {
            metalRenderer?.stop()
            metalRenderer = nil
            retainedContext?.release()
            return
        }

        // Invalidate before clearing the pointer so any already-queued main
        // drain returns without calling into a destroyed handle.
        eventSessionID &+= 1

        // Make the handle unavailable before clearing callbacks. A wakeup that
        // was already posted to the main queue will then return without calling
        // mpv_wait_event.
        mpv = nil
        mpvCoreReady = false
        eventWakePending = false
        isEventDrainScheduled = false
        mpv_set_wakeup_callback(handle, nil, nil)

        metalRenderer?.stop()
        metalRenderer = nil

        // Event draining and all other client API calls run on the main actor.
        // Destroy here only after the render context is freed and wakeups are
        // cleared, so demux/vo threads cannot log through a half-torn-down
        // client (mp_msg_va EXC_BAD_ACCESS on a null log context).
        mpv_terminate_destroy(handle)
        retainedContext?.release()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            refreshPresentation()
        } else {
            updateMetalLayerGeometry()
        }
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

        let retainedContext = Unmanaged.passRetained(MPVCallbackContext(view: self))
        callbackContext = retainedContext

        observe("time-pos", MPV_FORMAT_DOUBLE)
        observe("duration", MPV_FORMAT_DOUBLE)
        observe("pause", MPV_FORMAT_FLAG)
        observe("video-params/w", MPV_FORMAT_INT64)
        observe("video-params/h", MPV_FORMAT_INT64)
        observe("video-params/dw", MPV_FORMAT_INT64)
        observe("video-params/dh", MPV_FORMAT_INT64)
        mpv_set_wakeup_callback(handle, { context in
            guard let context else { return }
            let callback = Unmanaged<MPVCallbackContext>.fromOpaque(context).takeUnretainedValue()
            let view = callback.view
            DispatchQueue.main.async { [weak view] in view?.scheduleEventDrain() }
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
        guard bounds.width > 0, bounds.height > 0 else { return }
        let pixelScale = max(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2, 1)
        let viewPixelWidth = max(1, Int((bounds.width * pixelScale).rounded()))
        let viewPixelHeight = max(1, Int((bounds.height * pixelScale).rounded()))
        // Software rasterization at full Retina size is the main CPU cost.
        // Cap the drawable at the video's native pixels and let CAMetalLayer
        // upscale — no crop/zoom of the picture content.
        let pixelSize = softwareRenderPixelSize(
            viewPixelWidth: viewPixelWidth,
            viewPixelHeight: viewPixelHeight
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.frame = bounds
        metalLayer.contentsScale = pixelScale
        metalLayer.contentsGravity = .resizeAspect
        metalLayer.cornerRadius = 0
        metalLayer.masksToBounds = true
        let sizeChanged = pixelSize != lastDrawablePixelSize
        var shouldRedraw = false
        if pixelSize.width > 1, pixelSize.height > 1, !isDeferringDrawableResize, sizeChanged {
            metalLayer.drawableSize = pixelSize
            lastDrawablePixelSize = pixelSize
            shouldRedraw = true
            Self.playbackLogger.debug("Metal geometry view=\(viewPixelWidth, privacy: .public)x\(viewPixelHeight, privacy: .public) drawable=\(Int(pixelSize.width), privacy: .public)x\(Int(pixelSize.height), privacy: .public)")
        }
        CATransaction.commit()
        if shouldRedraw {
            metalRenderer?.requestDraw()
        }
    }

    /// Prefer native video resolution; only downscale when the view is smaller.
    private func softwareRenderPixelSize(viewPixelWidth: Int, viewPixelHeight: Int) -> CGSize {
        let videoWidth = videoFramePixelSize.width
        let videoHeight = videoFramePixelSize.height
        guard videoWidth > 1, videoHeight > 1 else {
            return CGSize(width: viewPixelWidth, height: viewPixelHeight)
        }
        let fitScale = min(
            CGFloat(viewPixelWidth) / videoWidth,
            CGFloat(viewPixelHeight) / videoHeight
        )
        let scale = min(1, fitScale)
        let width = max(1, Int((videoWidth * scale).rounded()))
        let height = max(1, Int((videoHeight * scale).rounded()))
        return CGSize(width: width, height: height)
    }

    private func scheduleEventDrain() {
        guard mpv != nil else { return }
        if isEventDrainScheduled {
            eventWakePending = true
            return
        }
        isEventDrainScheduled = true
        eventWakePending = false
        readEvents()
    }

    private func readEvents() {
        // Keep wait_event on the main actor with all other client API calls.
        // Draining on a background queue while MainActor sets/gets properties
        // races inside libmpv and commonly crashes in mp_msg_va (null log ctx).
        guard let handle = mpv else {
            isEventDrainScheduled = false
            eventWakePending = false
            return
        }
        let session = eventSessionID
        while session == eventSessionID,
              let event = mpv_wait_event(handle, 0),
              event.pointee.event_id != MPV_EVENT_NONE {
            handleEvent(event.pointee)
        }
        guard session == eventSessionID else {
            isEventDrainScheduled = false
            eventWakePending = false
            return
        }
        isEventDrainScheduled = false
        if eventWakePending {
            scheduleEventDrain()
        }
    }

    private func handleEvent(_ event: mpv_event) {
        switch event.event_id {
        case MPV_EVENT_PROPERTY_CHANGE:
            guard let raw = event.data else { return }
            let property = raw.assumingMemoryBound(to: mpv_event_property.self).pointee
            let name = String(cString: property.name)
            guard let data = property.data else { return }
            switch property.format {
            case MPV_FORMAT_DOUBLE:
                let value = data.assumingMemoryBound(to: Double.self).pointee
                if name == "time-pos" { onTimeChanged?(value) }
                if name == "duration" { onDurationChanged?(value) }
            case MPV_FORMAT_FLAG:
                let value = data.assumingMemoryBound(to: Int32.self).pointee != 0
                if name == "pause" { onPauseChanged?(value) }
            case MPV_FORMAT_INT64:
                if name.hasPrefix("video-params/") {
                    // Defer property reads until after the current wait_event
                    // drain finishes to avoid re-entering the client API mid-loop.
                    DispatchQueue.main.async { [weak self] in
                        self?.updateVideoSize()
                    }
                }
            default: break
            }
        case MPV_EVENT_FILE_LOADED:
            // Defer load-side commands so they run after this drain returns.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.currentFileLoaded = true
                let layerBound = self.layer === self.metalLayer
                Self.playbackLogger.notice("FILE_LOADED vo=\(self.getString("current-vo") ?? "unknown", privacy: .public) metalLayer=\(layerBound, privacy: .public) drawable=\(Int(self.metalLayer.drawableSize.width), privacy: .public)x\(Int(self.metalLayer.drawableSize.height), privacy: .public)")
                if let audioURL = self.pendingAudioURL {
                    // DASH 的音轨是独立资源。audio-file 是启动选项，运行期修改并不会
                    // 稳定地附着到当前文件；必须等主视频加载完成后显式加入并选中音轨。
                    self.pendingAudioURL = nil
                    self.command("audio-add", [audioURL, "select"])
                }
                self.setDouble("panscan", 0)
                self.setDouble("video-zoom", 0)
                self.updateVideoSize()
                self.onReady?()
            }
        case MPV_EVENT_END_FILE:
            let reason = event.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if reason?.reason == MPV_END_FILE_REASON_ERROR {
                    let code = reason?.error ?? Int32(MPV_ERROR_GENERIC.rawValue)
                    Self.playbackLogger.error("END_FILE error=\(code, privacy: .public) message=\(String(cString: mpv_error_string(code)), privacy: .public)")
                    if !self.currentFileLoaded, !self.remainingVideoURLs.isEmpty {
                        let nextURL = self.remainingVideoURLs.removeFirst()
                        Self.playbackLogger.notice("retrying unopened DASH candidate host=\(URL(string: nextURL)?.host ?? "invalid", privacy: .public)")
                        do {
                            try self.submitLoad(videoURL: nextURL)
                        } catch {
                            self.onError?(error.localizedDescription)
                        }
                        return
                    }
                    self.onError?(String(cString: mpv_error_string(code)))
                } else {
                    self.onEnded?()
                }
            }
        default: break
        }
    }

    private func reportSetupFailure(_ message: String) {
        Self.playbackLogger.error("mpv setup failed: \(message, privacy: .public)")
        onError?(message)
    }

    private func updateVideoSize() {
        let displayWidth = getInt64("video-params/dw")
        let displayHeight = getInt64("video-params/dh")
        if displayWidth > 0, displayHeight > 0 {
            let pixels = CGSize(width: CGFloat(displayWidth), height: CGFloat(displayHeight))
            if pixels != videoFramePixelSize {
                videoFramePixelSize = pixels
                Self.playbackLogger.debug("video-display-size=\(displayWidth, privacy: .public)x\(displayHeight, privacy: .public)")
                updateMetalLayerGeometry()
            }
            onVideoSizeChanged?(pixels)
            return
        }

        let width = getInt64("video-params/w")
        let height = getInt64("video-params/h")
        if width > 0, height > 0 {
            let aspect = getDouble("video-params/aspect")
            if aspect.isFinite, aspect > 0 {
                Self.playbackLogger.debug("video-size=\(width, privacy: .public)x\(height, privacy: .public) aspect=\(aspect, privacy: .public)")
                onVideoSizeChanged?(CGSize(width: aspect, height: 1))
                return
            }
            let pixels = CGSize(width: CGFloat(width), height: CGFloat(height))
            if pixels != videoFramePixelSize {
                videoFramePixelSize = pixels
                Self.playbackLogger.debug("video-size=\(width, privacy: .public)x\(height, privacy: .public)")
                updateMetalLayerGeometry()
            }
            onVideoSizeChanged?(pixels)
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

    private func getDouble(_ name: String) -> Double {
        guard let mpv else { return .nan }
        var value: Double = 0
        guard mpv_get_property(mpv, name, MPV_FORMAT_DOUBLE, &value) >= 0 else { return .nan }
        return value
    }

    private func getFlag(_ name: String) -> Bool {
        guard let mpv else { return false }
        var value: Int32 = 0
        guard mpv_get_property(mpv, name, MPV_FORMAT_FLAG, &value) >= 0 else { return false }
        return value != 0
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
