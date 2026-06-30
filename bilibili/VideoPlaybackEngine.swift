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

    @Published private(set) var isReady = false

    var avPlayer: AVPlayer? { player }

    func load(stream: BiliPlayStream, cookieHeader: String) async throws {
        stop()
        let headers = BilibiliEndpoints.playbackHeaders(cookie: cookieHeader)
        let item = try await Self.makePlayerItem(stream: stream, headers: headers)
        let player = AVPlayer(playerItem: item)
        self.player = player
        isReady = true
        observeTime(player)
        observeEnd(player)
        observeStatus(item)
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

    func stop() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        statusObservation?.invalidate()
        statusObservation = nil
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
                if item.status == .failed {
                    self.isPlaying = false
                }
            }
        }
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
