import AVFoundation
import Combine
import Foundation

@MainActor
final class VideoPlaybackEngine: ObservableObject {
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

    @Published private(set) var isReady = false
    @Published private(set) var videoAspectRatio: CGFloat = 16.0 / 9.0
    @Published private(set) var volume: Float = 1
    @Published private(set) var isMuted = false
    @Published private(set) var playbackRate: Float = 1
    @Published private(set) var pictureInPictureRequestID = 0
    @Published private(set) var isPictureInPictureActive = false

    private var presentationSizeObservation: NSKeyValueObservation?
    private var volumeBeforeMute: Float = 1

    var avPlayer: AVPlayer? { player }

    var preciseCurrentTime: Double {
        if isPictureInPictureActive,
           let seconds = player?.currentTime().seconds,
           seconds.isFinite {
            return seconds
        }
        return currentTime
    }

    var displayAspectRatio: CGFloat {
        guard videoAspectRatio.isFinite, videoAspectRatio > 0 else { return 16.0 / 9.0 }
        return videoAspectRatio
    }

    init() {
        renderView.onTimeChanged = { [weak self] value in
            guard let self, !isScrubbing, !isPictureInPictureActive else { return }
            currentTime = value
        }
        renderView.onDurationChanged = { [weak self] value in
            guard let self, value.isFinite, value > 0 else { return }
            duration = value
        }
        renderView.onPauseChanged = { [weak self] paused in
            guard let self, !isPictureInPictureActive else { return }
            isPlaying = !paused
        }
        renderView.onVideoSizeChanged = { [weak self] size in
            guard let self, size.width > 0, size.height > 0 else { return }
            videoAspectRatio = size.width / size.height
        }
        renderView.onReady = { [weak self] in self?.isReady = true }
        renderView.onEnded = { [weak self] in self?.isPlaying = false }
        renderView.onError = { [weak self] _ in
            self?.isPlaying = false
            self?.isReady = false
        }
    }

    func load(
        stream: BiliPlayStream,
        pictureInPictureStream: BiliPlayStream? = nil,
        pictureInPictureStreamLoader: (() async throws -> BiliPlayStream)? = nil,
        cookieHeader: String
    ) async throws {
        stop()
        videoAspectRatio = 16.0 / 9.0
        let headers = BilibiliEndpoints.playbackHeaders(cookie: cookieHeader)
        self.pictureInPictureStream = pictureInPictureStream
        self.pictureInPictureStreamLoader = pictureInPictureStreamLoader
        playbackHeaders = headers
        try renderView.load(
            videoURL: stream.videoURL,
            audioURL: stream.audioURL,
            headers: headers
        )
        applyVolume()
        startPlayback()
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
        Task { @MainActor in
            do {
                let stream: BiliPlayStream
                if let pictureInPictureStream {
                    stream = pictureInPictureStream
                } else if let pictureInPictureStreamLoader {
                    stream = try await pictureInPictureStreamLoader()
                    self.pictureInPictureStream = stream
                } else {
                    return
                }
                let item = try await Self.makePlayerItem(stream: stream, headers: playbackHeaders)
                item.preferredForwardBufferDuration = 30
                let pipPlayer = AVPlayer(playerItem: item)
                pipPlayer.volume = isMuted ? 0 : volume
                let time = CMTime(seconds: preciseCurrentTime, preferredTimescale: 600)
                await pipPlayer.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
                player = pipPlayer
                pictureInPictureRequestID += 1
            } catch {
                player = nil
            }
        }
    }

    func setPictureInPictureActive(_ isActive: Bool) {
        if isActive, !isPictureInPictureActive {
            resumeMPVAfterPictureInPicture = isPlaying
            renderView.setPaused(true)
            if resumeMPVAfterPictureInPicture {
                player?.play()
                player?.rate = playbackRate
            }
        } else if !isActive, isPictureInPictureActive {
            if let seconds = player?.currentTime().seconds, seconds.isFinite {
                currentTime = seconds
                renderView.seek(to: seconds)
            }
            player?.pause()
            player = nil
            renderView.setPaused(!resumeMPVAfterPictureInPicture)
            isPlaying = resumeMPVAfterPictureInPicture
        }
        isPictureInPictureActive = isActive
    }

    func pausePlayback() {
        renderView.setPaused(true)
        player?.pause()
        isPlaying = false
    }

    func resumePlayback() {
        guard isReady, player != nil else { return }
        startPlayback()
    }

    func togglePlayback() {
        guard isReady else { return }
        if isPlaying {
            pausePlayback()
        } else {
            startPlayback()
        }
    }

    func seek(to seconds: Double, resumeAfter: Bool = true) {
        guard isReady else { return }
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        renderView.seek(to: seconds)
        player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = max(0, seconds)
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
        currentTime = 0
        duration = 0
        isScrubbing = false
        scrubPreviewTime = nil
        videoAspectRatio = 16.0 / 9.0
        playbackRate = 1
        isPictureInPictureActive = false
    }

    private func startPlayback() {
        guard isReady || player == nil else { return }
        renderView.setSpeed(playbackRate)
        renderView.setPaused(false)
        player?.play()
        player?.rate = playbackRate
        isPlaying = true
    }

    private func observeTime(_ player: AVPlayer) {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.isScrubbing else { return }
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
