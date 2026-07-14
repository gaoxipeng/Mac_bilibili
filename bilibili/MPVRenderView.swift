import AppKit
import Libmpv
import OpenGL.GL

@MainActor
final class MPVRenderView: NSOpenGLView {
    var onTimeChanged: ((Double) -> Void)?
    var onDurationChanged: ((Double) -> Void)?
    var onPauseChanged: ((Bool) -> Void)?
    var onVideoSizeChanged: ((CGSize) -> Void)?
    var onReady: (() -> Void)?
    var onEnded: (() -> Void)?
    var onError: ((String) -> Void)?

    private var mpv: OpaquePointer?
    private var renderContext: OpaquePointer?
    private let eventQueue = DispatchQueue(label: "bilibili.mpv.events", qos: .userInitiated)
    private var defaultFBO: GLint = -1
    private var isConfigured = false
    private var pendingAudioURL: String?

    override class func defaultPixelFormat() -> NSOpenGLPixelFormat {
        let attributes: [NSOpenGLPixelFormatAttribute] = [
            NSOpenGLPixelFormatAttribute(NSOpenGLPFADoubleBuffer),
            NSOpenGLPixelFormatAttribute(NSOpenGLPFAColorSize), 32,
            NSOpenGLPixelFormatAttribute(NSOpenGLPFADepthSize), 24,
            NSOpenGLPixelFormatAttribute(0)
        ]
        return NSOpenGLPixelFormat(attributes: attributes)!
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureView()
    }

    override init?(frame frameRect: NSRect, pixelFormat format: NSOpenGLPixelFormat?) {
        super.init(frame: frameRect, pixelFormat: format ?? Self.defaultPixelFormat())
        configureView()
    }

    private func configureView() {
        guard !isConfigured else { return }
        isConfigured = true
        autoresizingMask = [.width, .height]
        wantsBestResolutionOpenGLSurface = true
        setupMPV()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func load(videoURL: String, audioURL: String?, headers: [String: String], start: Double = 0) throws {
        guard mpv != nil else { throw APIError.message("libmpv 初始化失败") }
        setString("http-header-fields", headers.map { "\($0.key): \($0.value)" }.joined(separator: ","))
        pendingAudioURL = audioURL
        var options: [String] = []
        if start > 0 { options.append("start=\(start)") }
        command("loadfile", [videoURL, "replace", "-1", options.joined(separator: ",")])
    }

    func setPaused(_ paused: Bool) { setFlag("pause", paused) }
    func setMuted(_ muted: Bool) { setFlag("mute", muted) }
    func setVolume(_ volume: Float) { setDouble("volume", Double(volume * 100)) }
    func setSpeed(_ speed: Float) { setDouble("speed", Double(speed)) }
    func seek(to seconds: Double) { command("seek", [String(max(0, seconds)), "absolute+exact"]) }

    func shutdown() {
        guard let mpv else { return }
        mpv_set_wakeup_callback(mpv, nil, nil)
        if let renderContext {
            mpv_render_context_set_update_callback(renderContext, nil, nil)
            mpv_render_context_free(renderContext)
            self.renderContext = nil
        }
        mpv_terminate_destroy(mpv)
        self.mpv = nil
    }

    private func setupMPV() {
        guard let handle = mpv_create() else { return }
        mpv = handle
        setOption("vo", "libmpv")
        setOption("hwdec", "videotoolbox")
        setOption("ytdl", "no")
        setOption("keep-open", "yes")
        setOption("audio-display", "no")
        guard mpv_initialize(handle) >= 0 else {
            mpv_destroy(handle)
            mpv = nil
            return
        }

        openGLContext?.makeCurrentContext()
        var glInit = mpv_opengl_init_params(
            get_proc_address: { _, name in MPVRenderView.openGLProcAddress(name) },
            get_proc_address_ctx: nil
        )
        let api = UnsafeMutableRawPointer(mutating: (MPV_RENDER_API_TYPE_OPENGL as NSString).utf8String)
        withUnsafeMutablePointer(to: &glInit) { pointer in
            var params = [
                mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: api),
                mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: pointer),
                mpv_render_param()
            ]
            guard mpv_render_context_create(&renderContext, handle, &params) >= 0 else { return }
        }

        if let renderContext {
            mpv_render_context_set_update_callback(renderContext, { context in
                guard let context else { return }
                let view = Unmanaged<MPVRenderView>.fromOpaque(context).takeUnretainedValue()
                DispatchQueue.main.async { view.needsDisplay = true }
            }, Unmanaged.passUnretained(self).toOpaque())
        }

        observe("time-pos", MPV_FORMAT_DOUBLE)
        observe("duration", MPV_FORMAT_DOUBLE)
        observe("pause", MPV_FORMAT_FLAG)
        observe("video-params/w", MPV_FORMAT_INT64)
        observe("video-params/h", MPV_FORMAT_INT64)
        mpv_set_wakeup_callback(handle, { context in
            guard let context else { return }
            Unmanaged<MPVRenderView>.fromOpaque(context).takeUnretainedValue().readEvents()
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let renderContext, let openGLContext else { return }
        openGLContext.makeCurrentContext()
        glClearColor(0, 0, 0, 1)
        glClear(UInt32(GL_COLOR_BUFFER_BIT))
        glGetIntegerv(UInt32(GL_FRAMEBUFFER_BINDING), &defaultFBO)
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        var fbo = mpv_opengl_fbo(
            fbo: Int32(defaultFBO),
            w: Int32(max(1, bounds.width * scale)),
            h: Int32(max(1, bounds.height * scale)),
            internal_format: 0
        )
        var flip: CInt = 1
        withUnsafeMutablePointer(to: &fbo) { fboPointer in
            withUnsafeMutablePointer(to: &flip) { flipPointer in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: fboPointer),
                    mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: flipPointer),
                    mpv_render_param()
                ]
                mpv_render_context_render(renderContext, &params)
            }
        }
        openGLContext.flushBuffer()
    }

    private func readEvents() {
        guard let handle = mpv else { return }
        eventQueue.async { [weak self] in
            guard let self else { return }
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
                    onError?(String(cString: mpv_error_string(code)))
                } else {
                    onEnded?()
                }
            }
        default: break
        }
    }

    private func updateVideoSize() {
        let width = getInt64("video-params/w")
        let height = getInt64("video-params/h")
        if width > 0, height > 0 {
            onVideoSizeChanged?(CGSize(width: CGFloat(width), height: CGFloat(height)))
        }
    }

    private func observe(_ name: String, _ format: mpv_format) {
        guard let mpv else { return }
        mpv_observe_property(mpv, 0, name, format)
    }

    private func setOption(_ name: String, _ value: String) {
        guard let mpv else { return }
        mpv_set_option_string(mpv, name, value)
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

    private func command(_ name: String, _ args: [String]) {
        guard let mpv else { return }
        let strings: [String?] = [name] + args.map(Optional.some) + [nil]
        var pointers: [UnsafePointer<CChar>?] = strings.map { value in
            value.flatMap { UnsafePointer<CChar>(strdup($0)) }
        }
        defer {
            for pointer in pointers where pointer != nil {
                free(UnsafeMutablePointer(mutating: pointer!))
            }
        }
        _ = mpv_command(mpv, &pointers)
    }

    private static func openGLProcAddress(_ name: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
        guard let name else { return nil }
        let symbol = CFStringCreateWithCString(nil, name, CFStringBuiltInEncodings.ASCII.rawValue)
        let bundle = CFBundleGetBundleWithIdentifier("com.apple.opengl" as CFString)
        return CFBundleGetFunctionPointerForName(bundle, symbol)
    }

}
