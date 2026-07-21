import AVFoundation
import AppKit
import Combine
import Foundation
import MediaPlayer
import QuartzCore

@MainActor
final class VideoPlaybackEngine: ObservableObject {
    var onSeekCommitted: ((Double) -> Void)?
    var onPlaybackError: ((String) -> Void)?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published var isScrubbing = false
    @Published var scrubPreviewTime: Double?

    private var player: AVPlayer?
    let renderView = MPVRenderView(frame: .zero)
    private var pictureInPictureStream: BiliPlayStream?
    private var pictureInPictureStreamLoader: (() async throws -> BiliPlayStream)?
    private var playbackHeaders: [String: String] = [:]
    private var resumeMPVAfterPictureInPicture = false
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var wheelScrubResumePlayback = false
    private var isWheelScrubbing = false
    private var wheelEndTask: Task<Void, Never>?
    private var preciseMPVTime: Double = 0
    private var lastTimePublishClock: CFTimeInterval = 0

    @Published private(set) var isReady = false
    @Published private(set) var videoAspectRatio: CGFloat = 16.0 / 9.0
    @Published private(set) var videoDisplaySize = CGSize(width: 16, height: 9)
    @Published private(set) var volume: Float = 1
    @Published private(set) var isMuted = false
    @Published private(set) var playbackRate: Float = 1
    @Published private(set) var pictureInPictureRequestID = 0
    @Published private(set) var isPictureInPictureActive = false

    private var presentationSizeObservation: NSKeyValueObservation?
    private var volumeBeforeMute: Float = 1
    private var remoteCommandTargets: [(MPRemoteCommand, Any)] = []
    private var nowPlayingTitle = ""
    private var nowPlayingArtist = ""
    private var nowPlayingArtwork: MPMediaItemArtwork?
    private var artworkTask: Task<Void, Never>?
    private var pictureInPicturePreparationTask: Task<Void, Never>?
    private var pictureInPicturePrewarmTask: Task<Void, Never>?
    private var preparedPictureInPictureItem: AVPlayerItem?
    @Published private(set) var isPictureInPicturePreparing = false

    var avPlayer: AVPlayer? { player }

    var preciseCurrentTime: Double {
        if isPictureInPictureActive,
           let seconds = player?.currentTime().seconds,
           seconds.isFinite {
            return seconds
        }
        return preciseMPVTime
    }

    var displayAspectRatio: CGFloat {
        guard videoDisplaySize.width > 0, videoDisplaySize.height > 0 else {
            guard videoAspectRatio.isFinite, videoAspectRatio > 0 else { return 16.0 / 9.0 }
            return videoAspectRatio
        }
        return videoDisplaySize.width / videoDisplaySize.height
    }

    init() {
        renderView.onTimeChanged = { [weak self] value in
            guard let self, !isScrubbing, !isPictureInPictureActive else { return }
            preciseMPVTime = value
            let clock = CACurrentMediaTime()
            if clock - lastTimePublishClock >= 1.0 / 15.0 || abs(value - currentTime) > 0.5 {
                lastTimePublishClock = clock
                currentTime = value
            }
        }
        renderView.onDurationChanged = { [weak self] value in
            guard let self, value.isFinite, value > 0 else { return }
            duration = value
            updateNowPlayingInfo()
        }
        renderView.onPauseChanged = { [weak self] paused in
            guard let self, !isPictureInPictureActive else { return }
            isPlaying = !paused
            updateNowPlayingInfo()
        }
        renderView.onVideoSizeChanged = { [weak self] size in
            guard let self, size.width > 0, size.height > 0 else { return }
            videoDisplaySize = size
            videoAspectRatio = size.width / size.height
        }
        renderView.onReady = { [weak self] in self?.isReady = true }
        renderView.onEnded = { [weak self] in
            guard let self else { return }
            isPlaying = false
            if duration > 0 {
                preciseMPVTime = duration
                currentTime = duration
            }
            updateNowPlayingInfo()
        }
        renderView.onError = { [weak self] message in
            self?.isPlaying = false
            self?.isReady = false
            self?.updateNowPlayingInfo()
            self?.onPlaybackError?(message)
        }
        installRemoteCommands()
    }

    func configureNowPlaying(title: String, artist: String, artworkURL: URL?) {
        if remoteCommandTargets.isEmpty { installRemoteCommands() }
        nowPlayingTitle = title
        nowPlayingArtist = artist
        nowPlayingArtwork = nil
        updateNowPlayingInfo()

        artworkTask?.cancel()
        guard let artworkURL else { return }
        artworkTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let (data, _) = try await URLSession.shared.data(from: artworkURL)
                guard !Task.isCancelled, let image = NSImage(data: data) else { return }
                nowPlayingArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                updateNowPlayingInfo()
            } catch {
                // 封面失败不影响系统播放控制。
            }
        }
    }

    func clearNowPlaying() {
        artworkTask?.cancel()
        artworkTask = nil
        nowPlayingTitle = ""
        nowPlayingArtist = ""
        nowPlayingArtwork = nil
        for (command, target) in remoteCommandTargets {
            command.removeTarget(target)
        }
        remoteCommandTargets.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    func load(
        stream: BiliPlayStream,
        pictureInPictureStream: BiliPlayStream? = nil,
        pictureInPictureStreamLoader: (() async throws -> BiliPlayStream)? = nil,
        cookieHeader: String,
        startAt startSeconds: Double = 0
    ) async throws {
        stop()
        videoAspectRatio = 16.0 / 9.0
        videoDisplaySize = CGSize(width: 16, height: 9)
        let headers = BilibiliEndpoints.playbackHeaders(cookie: cookieHeader)
        self.pictureInPictureStream = pictureInPictureStream
        self.pictureInPictureStreamLoader = pictureInPictureStreamLoader
        playbackHeaders = headers
        try renderView.load(
            videoURL: stream.videoURL,
            fallbackVideoURLs: stream.videoFallbackURLs,
            audioURL: stream.audioURL,
            headers: headers,
            start: max(0, startSeconds)
        )
        applyVolume()
        startPlayback()
        startPictureInPicturePrewarming()
    }

    func cyclePlaybackRate() {
        switch playbackRate {
        case ..<1.25:
            playbackRate = 1.5
        case ..<1.75:
            playbackRate = 2
        default:
            playbackRate = 1
        }
        if isPlaying {
            renderView.setSpeed(playbackRate)
            player?.rate = playbackRate
        }
    }

    var playbackRateLabel: String {
        switch playbackRate {
        case ..<1.25:
            return "1×"
        case ..<1.75:
            return "1.5×"
        default:
            return "2×"
        }
    }

    func requestPictureInPicture() {
        guard isReady else { return }
        if isPictureInPictureActive {
            pictureInPictureRequestID += 1
            return
        }
        guard pictureInPicturePreparationTask == nil else { return }
        isPictureInPicturePreparing = true
        PictureInPictureHost.shared.beginPictureInPictureAttempt()
        pictureInPicturePreparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                pictureInPicturePreparationTask = nil
                isPictureInPicturePreparing = false
            }
            do {
                if let pictureInPicturePrewarmTask {
                    await pictureInPicturePrewarmTask.value
                }
                let item: AVPlayerItem
                if let preparedPictureInPictureItem {
                    item = preparedPictureInPictureItem
                    self.preparedPictureInPictureItem = nil
                } else {
                    item = try await preparePictureInPictureItem()
                }
                item.preferredForwardBufferDuration = 30
                let pipPlayer = AVPlayer(playerItem: item)
                // AVPictureInPictureController 要求 playerLayer 已经有活动播放时间线。
                // 先静音预播放，避免与 mpv 双重出声；系统确认启动后再切换音频。
                pipPlayer.isMuted = true
                pipPlayer.volume = volume
                let time = CMTime(seconds: preciseCurrentTime, preferredTimescale: 600)
                await pipPlayer.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
                player = pipPlayer
                pipPlayer.play()
                pipPlayer.rate = playbackRate
                try await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else {
                    pipPlayer.pause()
                    player = nil
                    PictureInPictureHost.shared.endPictureInPictureAttempt()
                    return
                }
                pictureInPictureRequestID += 1
            } catch {
                player = nil
                setPictureInPictureActive(false)
                PictureInPictureHost.shared.endPictureInPictureAttempt()
            }
        }
    }

    func setPictureInPictureActive(_ isActive: Bool) {
        if isActive, !isPictureInPictureActive {
            resumeMPVAfterPictureInPicture = isPlaying
            renderView.setPaused(true)
            player?.isMuted = isMuted
            player?.volume = volume
            if resumeMPVAfterPictureInPicture {
                player?.play()
                player?.rate = playbackRate
            }
        } else if !isActive, isPictureInPictureActive {
            if let seconds = player?.currentTime().seconds, seconds.isFinite {
                preciseMPVTime = seconds
                currentTime = seconds
                renderView.seek(to: seconds)
            }
            player?.pause()
            player = nil
            applyVolume()
            renderView.setPaused(!resumeMPVAfterPictureInPicture)
            isPlaying = resumeMPVAfterPictureInPicture
        } else if !isActive {
            // 启动尚未进入 willStart 就失败或超时：临时 AVPlayer 仍在静音
            // 预播放，必须清除，否则会保留旧帧并占用后续画中画请求。
            player?.pause()
            player = nil
            if isPlaying { renderView.setPaused(false) }
        }
        isPictureInPictureActive = isActive
    }

    func pausePlayback() {
        renderView.setPaused(true)
        // Keep the temporary AVPlayer running while PiP is preparing/active;
        // pausing it here is a common reason startPictureInPicture fails.
        if !isPictureInPicturePreparing, !isPictureInPictureActive {
            player?.pause()
        }
        isPlaying = false
        updateNowPlayingInfo()
    }

    func resumePlayback() {
        guard isReady else { return }
        if shouldRestartFromBeginning {
            seek(to: 0, resumeAfter: false)
        }
        startPlayback()
    }

    func togglePlayback() {
        guard isReady else { return }
        if isPlaying {
            pausePlayback()
        } else {
            if shouldRestartFromBeginning {
                seek(to: 0, resumeAfter: false)
            }
            startPlayback()
        }
    }

    /// With `keep-open=yes`, playback stops at the last frame. Treat near-EOF
    /// as finished so play resumes from the start instead of staying stuck.
    private var shouldRestartFromBeginning: Bool {
        guard duration > 0 else { return false }
        return preciseCurrentTime >= max(0, duration - 0.5)
    }

    func seek(to seconds: Double, resumeAfter: Bool = true) {
        guard isReady else { return }
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        renderView.seek(to: seconds)
        player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        preciseMPVTime = max(0, seconds)
        currentTime = preciseMPVTime
        onSeekCommitted?(currentTime)
        updateNowPlayingInfo()
        if resumeAfter, !isPlaying {
            startPlayback()
        }
    }

    func beginScrub(at seconds: Double) {
        isScrubbing = true
        scrubPreviewTime = seconds
        renderView.setPaused(true)
        player?.pause()
        isPlaying = false
    }

    func updateScrubPreview(_ seconds: Double) {
        scrubPreviewTime = seconds
    }

    func endScrub(at seconds: Double) {
        isScrubbing = false
        scrubPreviewTime = nil
        seek(to: seconds)
    }

    func seek(by seconds: Double) {
        let target = min(duration, max(0, preciseCurrentTime + seconds))
        seek(to: target, resumeAfter: isPlaying)
    }

    func toggleMute() {
        if isMuted {
            isMuted = false
            if volume <= 0 {
                volume = volumeBeforeMute > 0 ? volumeBeforeMute : 1
            }
        } else {
            volumeBeforeMute = volume > 0 ? volume : 1
            isMuted = true
        }
        applyVolume()
    }

    private func applyVolume() {
        renderView.setMuted(isMuted)
        renderView.setVolume(volume)
        player?.volume = isMuted ? 0 : volume
    }

    func applyWheelScrub(delta seconds: Double) {
        guard duration > 0 else { return }
        wheelEndTask?.cancel()
        wheelEndTask = nil

        if !isWheelScrubbing {
            isWheelScrubbing = true
            wheelScrubResumePlayback = isPlaying
            if !isScrubbing {
                isScrubbing = true
                scrubPreviewTime = currentTime
                player?.pause()
                isPlaying = false
            } else if scrubPreviewTime == nil {
                scrubPreviewTime = currentTime
            }
        }

        let base = scrubPreviewTime ?? currentTime
        scrubPreviewTime = min(duration, max(0, base + seconds))
    }

    func finishWheelScrub() {
        wheelEndTask?.cancel()
        wheelEndTask = nil
        guard isWheelScrubbing else { return }
        isWheelScrubbing = false
        let target = scrubPreviewTime ?? currentTime
        isScrubbing = false
        scrubPreviewTime = nil
        seek(to: target, resumeAfter: wheelScrubResumePlayback)
    }

    func scheduleWheelScrubEnd(after delay: Duration) {
        wheelEndTask?.cancel()
        wheelEndTask = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            finishWheelScrub()
        }
    }

    func cancelScheduledWheelScrubEnd() {
        wheelEndTask?.cancel()
        wheelEndTask = nil
    }

    func stop() {
        pictureInPicturePreparationTask?.cancel()
        pictureInPicturePreparationTask = nil
        pictureInPicturePrewarmTask?.cancel()
        pictureInPicturePrewarmTask = nil
        preparedPictureInPictureItem = nil
        isPictureInPicturePreparing = false
        wheelEndTask?.cancel()
        wheelEndTask = nil
        isWheelScrubbing = false
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        statusObservation?.invalidate()
        statusObservation = nil
        presentationSizeObservation?.invalidate()
        presentationSizeObservation = nil
        timeObserver = nil
        endObserver = nil
        player?.pause()
        player = nil
        renderView.setPaused(true)
        isReady = false
        isPlaying = false
        preciseMPVTime = 0
        lastTimePublishClock = 0
        currentTime = 0
        duration = 0
        isScrubbing = false
        scrubPreviewTime = nil
        videoAspectRatio = 16.0 / 9.0
        videoDisplaySize = CGSize(width: 16, height: 9)
        playbackRate = 1
        isPictureInPictureActive = false
        updateNowPlayingInfo()
    }

    private func startPictureInPicturePrewarming() {
        pictureInPicturePrewarmTask?.cancel()
        preparedPictureInPictureItem = nil
        guard pictureInPictureStream != nil || pictureInPictureStreamLoader != nil else { return }
        pictureInPicturePrewarmTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { pictureInPicturePrewarmTask = nil }
            do {
                preparedPictureInPictureItem = try await preparePictureInPictureItem()
            } catch {
                preparedPictureInPictureItem = nil
            }
        }
    }

    private func preparePictureInPictureItem() async throws -> AVPlayerItem {
        let stream: BiliPlayStream
        if let pictureInPictureStream {
            stream = pictureInPictureStream
        } else if let pictureInPictureStreamLoader {
            stream = try await pictureInPictureStreamLoader()
            self.pictureInPictureStream = stream
        } else {
            throw APIError.message("没有可用的画中画播放地址")
        }
        let item = try await Self.makePlayerItem(stream: stream, headers: playbackHeaders)
        guard try await item.asset.load(.isPlayable) else {
            throw APIError.message("画中画视频资源不可播放")
        }
        return item
    }

    private func startPlayback() {
        guard isReady || player == nil else { return }
        renderView.setSpeed(playbackRate)
        renderView.setPaused(false)
        player?.play()
        player?.rate = playbackRate
        isPlaying = true
        updateNowPlayingInfo()
    }

    private func installRemoteCommands() {
        guard remoteCommandTargets.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = true
        center.skipForwardCommand.isEnabled = true
        center.skipBackwardCommand.isEnabled = true
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.preferredIntervals = [15]

        addRemoteTarget(center.playCommand) { [weak self] _ in self?.resumePlayback() }
        addRemoteTarget(center.pauseCommand) { [weak self] _ in self?.pausePlayback() }
        addRemoteTarget(center.togglePlayPauseCommand) { [weak self] _ in self?.togglePlayback() }
        addRemoteTarget(center.skipForwardCommand) { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 15
            self?.seek(by: interval)
        }
        addRemoteTarget(center.skipBackwardCommand) { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 15
            self?.seek(by: -interval)
        }
        addRemoteTarget(center.changePlaybackPositionCommand) { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return }
            self?.seek(to: event.positionTime, resumeAfter: self?.isPlaying ?? false)
        }
    }

    private func addRemoteTarget(_ command: MPRemoteCommand, action: @escaping @MainActor (MPRemoteCommandEvent) -> Void) {
        let token = command.addTarget { event in
            Task { @MainActor in action(event) }
            return .success
        }
        remoteCommandTargets.append((command, token))
    }

    private func updateNowPlayingInfo() {
        guard !nowPlayingTitle.isEmpty else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: nowPlayingTitle,
            MPMediaItemPropertyPlaybackDuration: max(0, duration),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0, preciseCurrentTime),
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(playbackRate) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(playbackRate),
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue
        ]
        if !nowPlayingArtist.isEmpty { info[MPMediaItemPropertyArtist] = nowPlayingArtist }
        if let nowPlayingArtwork { info[MPMediaItemPropertyArtwork] = nowPlayingArtwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    private func observeTime(_ player: AVPlayer) {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.isScrubbing else { return }
                self.preciseMPVTime = time.seconds
                self.currentTime = time.seconds
                if let itemDuration = player.currentItem?.duration.seconds, itemDuration.isFinite, itemDuration > 0 {
                    self.duration = itemDuration
                }
            }
        }
    }

    private func observeEnd(_ player: AVPlayer) {
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isPlaying = false
            }
        }
    }

    private func observeStatus(_ item: AVPlayerItem) {
        statusObservation = item.observe(\.status, options: [.new]) { item, _ in
            Task { @MainActor in
                if item.status == .readyToPlay {
                    self.updateVideoAspectRatio(from: item.presentationSize)
                }
                if item.status == .failed {
                    self.isPlaying = false
                }
            }
        }
    }

    private func observePresentationSize(_ item: AVPlayerItem) {
        presentationSizeObservation?.invalidate()
        presentationSizeObservation = item.observe(\.presentationSize, options: [.new, .initial]) { [weak self] item, _ in
            let size = item.presentationSize
            Task { @MainActor [weak self] in
                guard let self else { return }
                updateVideoAspectRatio(from: size)
            }
        }
        Task {
            await loadAspectRatioFromTracks(item)
        }
    }

    private func updateVideoAspectRatio(from size: CGSize) {
        let width = abs(size.width)
        let height = abs(size.height)
        guard width > 0, height > 0 else { return }
        videoAspectRatio = width / height
    }

    private func loadAspectRatioFromTracks(_ item: AVPlayerItem) async {
        if let ratio = try? await Self.resolveAspectRatio(from: item.asset) {
            videoAspectRatio = ratio
        }
    }

    private static func resolveAspectRatio(from asset: AVAsset) async throws -> CGFloat {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw APIError.message("无视频轨道")
        }
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let transformed = naturalSize.applying(transform)
        let width = abs(transformed.width)
        let height = abs(transformed.height)
        guard width > 0, height > 0 else {
            throw APIError.message("无效视频尺寸")
        }
        return width / height
    }

    private static func makePlayerItem(stream: BiliPlayStream, headers: [String: String]) async throws -> AVPlayerItem {
        guard let videoURL = URL(string: stream.videoURL) else {
            throw APIError.message("播放地址无效")
        }

        let options = ["AVURLAssetHTTPHeaderFieldsKey": headers]
        let videoAsset = AVURLAsset(url: videoURL, options: options)

        let audioURLString = stream.audioURL?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let canMergeAudio = audioURLString != nil
            && audioURLString != stream.videoURL
            && BiliPlayStream.isAVPlayerNativeURL(stream.videoURL)
            && BiliPlayStream.isAVPlayerNativeURL(audioURLString!)

        if canMergeAudio, let audioURLString, let audioURL = URL(string: audioURLString) {
            let audioAsset = AVURLAsset(url: audioURL, options: options)
            async let videoTracks = videoAsset.loadTracks(withMediaType: .video)
            async let audioTracks = audioAsset.loadTracks(withMediaType: .audio)
            let (loadedVideoTracks, loadedAudioTracks) = try await (videoTracks, audioTracks)

            if let videoTrack = loadedVideoTracks.first, let audioTrack = loadedAudioTracks.first {
                let composition = AVMutableComposition()
                let compositionVideoTrack = composition.addMutableTrack(
                    withMediaType: .video,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                )!
                let compositionAudioTrack = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                )!
                let assetDuration = try await videoAsset.load(.duration)
                let timeRange = CMTimeRange(start: .zero, duration: assetDuration)
                try compositionVideoTrack.insertTimeRange(timeRange, of: videoTrack, at: .zero)
                try compositionAudioTrack.insertTimeRange(timeRange, of: audioTrack, at: .zero)
                let item = AVPlayerItem(asset: composition)
                try await validatePlayable(item.asset)
                return item
            }
        }

        let item = AVPlayerItem(asset: videoAsset)
        try await validatePlayable(videoAsset)
        return item
    }

    private static func validatePlayable(_ asset: AVAsset) async throws {
        let playable = try await asset.load(.isPlayable)
        guard playable else {
            throw APIError.message("无法打开视频流")
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
