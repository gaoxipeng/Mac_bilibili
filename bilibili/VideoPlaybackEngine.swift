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
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var wheelScrubResumePlayback = false
    private var isWheelScrubbing = false
    private var wheelEndTask: Task<Void, Never>?

    @Published private(set) var isReady = false
    @Published private(set) var videoAspectRatio: CGFloat = 16.0 / 9.0

    private var presentationSizeObservation: NSKeyValueObservation?

    var avPlayer: AVPlayer? { player }

    var displayAspectRatio: CGFloat {
        guard videoAspectRatio.isFinite, videoAspectRatio > 0 else { return 16.0 / 9.0 }
        return videoAspectRatio
    }

    func load(stream: BiliPlayStream, cookieHeader: String) async throws {
        stop()
        videoAspectRatio = 16.0 / 9.0
        let headers = BilibiliEndpoints.playbackHeaders(cookie: cookieHeader)
        let item = try await Self.makePlayerItem(stream: stream, headers: headers)
        if let ratio = try? await Self.resolveAspectRatio(from: item.asset) {
            videoAspectRatio = ratio
        }
        let player = AVPlayer(playerItem: item)
        self.player = player
        isReady = true
        observeTime(player)
        observeEnd(player)
        observeStatus(item)
        observePresentationSize(item)
        player.play()
        isPlaying = true
    }

    func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    func seek(to seconds: Double, resumeAfter: Bool = true) {
        guard let player else { return }
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = max(0, seconds)
        if resumeAfter, !isPlaying {
            player.play()
            isPlaying = true
        }
    }

    func beginScrub(at seconds: Double) {
        isScrubbing = true
        scrubPreviewTime = seconds
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

    func nudgePlayback(by seconds: Double) {
        applyWheelScrub(delta: seconds)
        scheduleWheelScrubEnd(after: .milliseconds(150))
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
        isReady = false
        isPlaying = false
        currentTime = 0
        duration = 0
        isScrubbing = false
        scrubPreviewTime = nil
        videoAspectRatio = 16.0 / 9.0
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
            Task { @MainActor in
                self?.updateVideoAspectRatio(from: item.presentationSize)
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
