import AppKit
import AVKit
import Combine
import SwiftUI

@MainActor
final class VideoDetailModel: ObservableObject {
    let seedVideo: BiliVideo
    private let api = BilibiliAPI()
    private var credential: BilibiliCredential?

    @Published var detail: BiliVideoDetail?
    @Published var activeCID: Int64 = 0
    @Published var isLoadingDetail = true
    @Published var detailError: String?
    @Published var playError: String?
    @Published var isLoadingPlayback = false

    @Published var commentSort: BiliCommentSort = .hot
    @Published var comments: [BiliCommentItem] = []
    @Published var commentsLoading = false
    @Published var commentsLoadingMore = false
    @Published var commentsError: String?
    @Published var commentsEnd = false
    @Published private(set) var commentsScrollToTopToken = 0

    let player = VideoPlaybackEngine()
    private var commentsCursor: String?
    private var loadedCommentsKey: String?
    private var commentsLoadInFlight = false
    private var danmakuCache: [Int64: [BiliDanmakuItem]] = [:]
    private let watchHistoryReporter = WatchHistoryReporter()
    private var watchHistoryTask: Task<Void, Never>?
    private var watchHistoryContext: (aid: Int64, cid: Int64)?
    private let initialProgressSeconds: Int
    private var activeEpid: Int64
    private let playbackRefererURL: URL?
    private var hasAppliedInitialProgress = false
    private var playerChangeSink: AnyCancellable?
    private var lifecycleGeneration = 0
    private var isTornDown = false
    private var isPlaybackSuspended = false
    private var wasPlayingBeforeSuspend = false

    @Published var danmakuItems: [BiliDanmakuItem] = []
    @Published var danmakuVisible = DanmakuPlayerPreferences.isDanmakuVisible()
    @Published var danmakuSettings = DanmakuPlayerPreferences.readDanmakuSettings()
    @Published var showDanmakuSettings = false

    @Published var videoRelation = BiliVideoRelation()
    @Published var authorSign = ""
    @Published var authorIpLocation: String?
    @Published var authorLevel = 0
    @Published var authorFollowerCount: Int64 = 0
    @Published var authorRelation = BiliAuthorRelation()
    @Published var authorFollowLoading = false
    @Published var onlineCount: Int64 = 0
    @Published var videoTags: [String] = []
    @Published var videoActionLoading = false
    @Published var actionMessage: String?
    @Published var coinHintMessage: String?
    @Published var needsLoginPrompt = false

    private var coinHintDismissTask: Task<Void, Never>?
    private var authorIpRefreshTask: Task<Void, Never>?
    private var prefetchedStream: BiliPlayStream?

    func applyPrefetchedStream(_ stream: BiliPlayStream?) {
        prefetchedStream = stream
    }

    init(
        video: BiliVideo,
        credential: BilibiliCredential?,
        initialProgressSeconds: Int = 0,
        playbackEpid: Int64 = 0,
        playbackRefererURL: URL? = nil
    ) {
        self.seedVideo = video
        self.credential = credential
        self.activeCID = video.cid
        self.initialProgressSeconds = max(0, initialProgressSeconds)
        let resolvedEpid = playbackEpid > 0 ? playbackEpid : video.pgcEpid
        self.activeEpid = max(0, resolvedEpid)
        self.playbackRefererURL = playbackRefererURL
        playerChangeSink = player.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var isBangumiPlayback: Bool {
        activeEpid > 0
    }

    var displayVideo: BiliVideo {
        detail?.video ?? seedVideo
    }

    func makePlaybackRequest() -> VideoPlaybackRequest {
        VideoPlaybackRequest(
            displayVideo,
            progressSeconds: Int(player.currentTime.rounded(.down)),
            epid: activeEpid,
            refererURL: playbackRefererURL
        )
    }

    var showAuthorFollowControl: Bool {
        guard let credential, displayVideo.authorMid > 0 else { return false }
        let viewerMid = Int64(credential.dedeUserId) ?? 0
        return viewerMid != displayVideo.authorMid
    }

    func load() async {
        let generation = lifecycleGeneration
        isLoadingDetail = true
        detailError = nil
        authorSign = ""
        authorIpLocation = nil
        authorLevel = 0
        authorFollowerCount = 0
        authorRelation = BiliAuthorRelation()
        onlineCount = 0
        videoTags = []
        defer { isLoadingDetail = false }

        if isBangumiPlayback {
            do {
                let loaded = try await api.pgcVideoDetail(epid: activeEpid, credential: credential)
                guard isLifecycleActive(generation), !Task.isCancelled else { return }
                activeCID = loaded.video.cid
                detail = loaded
                async let authorCardTask = loadAuthorCardInfo()
                async let onlineCountTask = loadOnlineCount()
                async let videoTagsTask = loadVideoTags()
                await loadVideoRelation()
                guard isLifecycleActive(generation), !Task.isCancelled else { return }
                await loadPlayback()
                guard isLifecycleActive(generation), !Task.isCancelled else { return }
                await scheduleInitialCommentsLoad()
                await authorCardTask
                await onlineCountTask
                await videoTagsTask
                scheduleAuthorIpRefresh(generation: generation)
            } catch {
                guard isLifecycleActive(generation) else { return }
                detailError = error.localizedDescription
            }
            return
        }

        do {
            let loaded = try await api.videoDetail(bvid: seedVideo.bvid, credential: credential)
            guard isLifecycleActive(generation), !Task.isCancelled else { return }

            if loaded.video.pgcEpid > 0 {
                activeEpid = loaded.video.pgcEpid
                let pgcLoaded = try await api.pgcVideoDetail(epid: activeEpid, credential: credential)
                guard isLifecycleActive(generation), !Task.isCancelled else { return }
                activeCID = pgcLoaded.video.cid
                detail = pgcLoaded
            } else {
                detail = loaded
                if activeCID <= 0 {
                    activeCID = loaded.video.cid
                }
            }

            async let authorCardTask = loadAuthorCardInfo()
            async let onlineCountTask = loadOnlineCount()
            async let videoTagsTask = loadVideoTags()
            await loadVideoRelation()
            guard isLifecycleActive(generation), !Task.isCancelled else { return }
            await loadPlayback()
            guard isLifecycleActive(generation), !Task.isCancelled else { return }
            await scheduleInitialCommentsLoad()
            await authorCardTask
            await onlineCountTask
            await videoTagsTask
            scheduleAuthorIpRefresh(generation: generation)
        } catch {
            guard isLifecycleActive(generation) else { return }
            detailError = error.localizedDescription
        }
    }

    private func loadAuthorCardInfo() async {
        let mid = displayVideo.authorMid
        guard mid > 0 else {
            authorSign = ""
            authorLevel = 0
            authorFollowerCount = 0
            authorRelation = BiliAuthorRelation()
            return
        }
        guard let snapshot = await api.userCardSnapshot(mid: mid, credential: credential) else {
            authorSign = await api.userSign(mid: mid, credential: credential)
            return
        }
        authorSign = snapshot.sign
        authorLevel = snapshot.level
        authorFollowerCount = snapshot.followerCount
        authorRelation = snapshot.relation
    }

    private func scheduleAuthorIpRefresh(generation: Int) {
        authorIpRefreshTask?.cancel()
        authorIpRefreshTask = nil
        let mid = displayVideo.authorMid
        guard mid > 0, isLifecycleActive(generation) else { return }

        authorIpRefreshTask = Task(priority: .background) { [weak self] in
            guard let self else { return }
            let ipLocation = await self.resolveAuthorIpLocation(mid: mid)
            guard !Task.isCancelled, self.isLifecycleActive(generation) else { return }
            self.authorIpLocation = JSONParser.normalizeIpLocation(ipLocation)
        }
    }

    private func resolveAuthorIpLocation(mid: Int64) async -> String? {
        await api.userSpaceIpLocation(
            mid: mid,
            credential: credential
        )
    }

    func followAuthor() async {
        guard showAuthorFollowControl, !authorFollowLoading, !authorRelation.following else { return }
        guard let credential = requireCredential() else { return }

        authorFollowLoading = true
        defer { authorFollowLoading = false }

        let mid = displayVideo.authorMid
        do {
            try await api.modifyFollow(mid: mid, follow: true, credential: credential)
            authorRelation.following = true
            authorFollowerCount = max(0, authorFollowerCount + 1)
            actionMessage = nil
        } catch {
            actionMessage = error.localizedDescription
        }
    }

    func unfollowAuthor() async {
        guard showAuthorFollowControl, !authorFollowLoading, authorRelation.following else { return }
        guard let credential = requireCredential() else { return }

        authorFollowLoading = true
        defer { authorFollowLoading = false }

        let mid = displayVideo.authorMid
        do {
            try await api.modifyFollow(mid: mid, follow: false, credential: credential)
            authorRelation.following = false
            authorRelation.followerMe = false
            authorFollowerCount = max(0, authorFollowerCount - 1)
            actionMessage = nil
        } catch {
            actionMessage = error.localizedDescription
        }
    }

    private func loadOnlineCount() async {
        let video = displayVideo
        let cid = activeCID > 0 ? activeCID : video.cid
        guard !video.bvid.isEmpty, cid > 0 else {
            onlineCount = 0
            return
        }
        onlineCount = await api.videoOnlineCount(
            bvid: video.bvid,
            aid: video.aid,
            cid: cid,
            credential: credential
        )
    }

    private func loadVideoTags() async {
        let aid = displayVideo.aid
        guard aid > 0 else {
            videoTags = []
            return
        }
        videoTags = (try? await api.videoTags(aid: aid, credential: credential)) ?? []
    }

    func loadVideoRelation() async {
        let video = displayVideo
        guard !video.bvid.isEmpty || video.aid > 0 else { return }
        if let relation = try? await api.videoRelation(
            bvid: video.bvid,
            aid: video.aid,
            credential: credential
        ) {
            videoRelation = relation
        }
    }

    func toggleLike() async {
        guard !videoActionLoading else { return }
        guard let credential = requireCredential() else { return }

        videoActionLoading = true
        defer { videoActionLoading = false }

        let targetLike = !videoRelation.liked
        do {
            try await api.likeVideo(
                bvid: displayVideo.bvid,
                aid: displayVideo.aid,
                like: targetLike,
                credential: credential
            )
            videoRelation = BiliVideoRelation(
                liked: targetLike,
                favorited: videoRelation.favorited,
                coinCount: videoRelation.coinCount
            )
            let delta: Int64 = targetLike ? 1 : -1
            updateDetail(likeDelta: delta)
        } catch {
            actionMessage = error.localizedDescription
        }
    }

    func tripleLike() async {
        guard !videoActionLoading else { return }
        guard let credential = requireCredential() else { return }

        videoActionLoading = true
        defer { videoActionLoading = false }

        do {
            let result = try await api.tripleVideo(
                bvid: displayVideo.bvid,
                aid: displayVideo.aid,
                credential: credential
            )
            videoRelation = BiliVideoRelation(
                liked: result.liked || videoRelation.liked,
                favorited: result.favorited || videoRelation.favorited,
                coinCount: result.coined ? 2 : videoRelation.coinCount
            )
            if let refreshed = try? await api.videoDetail(bvid: displayVideo.bvid, credential: credential) {
                detail = refreshed
            }
        } catch {
            actionMessage = error.localizedDescription
        }
    }

    func coin(multiply: Int) async {
        guard !videoActionLoading else { return }
        guard let credential = requireCredential() else { return }

        if videoRelation.coinCount >= 2 {
            showCoinHint("已经投过币了")
            return
        }

        videoActionLoading = true
        defer { videoActionLoading = false }

        do {
            try await api.coinVideo(
                bvid: displayVideo.bvid,
                aid: displayVideo.aid,
                multiply: multiply,
                credential: credential
            )
            videoRelation = BiliVideoRelation(
                liked: videoRelation.liked,
                favorited: videoRelation.favorited,
                coinCount: min(2, videoRelation.coinCount + multiply)
            )
            updateDetail(coinDelta: Int64(multiply))
        } catch {
            actionMessage = error.localizedDescription
        }
    }

    func toggleFavorite() async {
        guard !videoActionLoading else { return }
        guard let credential = requireCredential() else { return }

        videoActionLoading = true
        defer { videoActionLoading = false }

        let targetFavorite = !videoRelation.favorited
        do {
            try await api.modifyVideoFavorite(
                bvid: displayVideo.bvid,
                aid: displayVideo.aid,
                add: targetFavorite,
                credential: credential
            )
            videoRelation = BiliVideoRelation(
                liked: videoRelation.liked,
                favorited: targetFavorite,
                coinCount: videoRelation.coinCount
            )
            let delta: Int64 = targetFavorite ? 1 : -1
            updateDetail(favoriteDelta: delta)
        } catch {
            actionMessage = error.localizedDescription
        }
    }

    func share(from context: ShareClickContext) async {
        let video = displayVideo
        guard let url = video.webURL else { return }

        presentShareSheet(for: url, context: context)

        guard !videoActionLoading else { return }
        videoActionLoading = true
        defer { videoActionLoading = false }

        do {
            try await api.shareVideo(
                bvid: video.bvid,
                aid: video.aid,
                credential: credential
            )
            updateDetail(shareDelta: 1)
        } catch {
            guard !Self.isDuplicateShareError(error) else { return }
            actionMessage = error.localizedDescription
        }
    }

    private static func isDuplicateShareError(_ error: Error) -> Bool {
        guard case APIError.message(let message) = error else { return false }
        return message.contains("重复分享")
            || message.contains("已经分享")
            || message.contains("已分享过")
    }

    func presentShareSheet(for url: URL, context: ShareClickContext) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)

        guard let sourceView = context.sourceView else { return }
        let point = context.locationInView
        let rect = NSRect(x: point.x, y: point.y, width: 1, height: 1)
        let picker = NSSharingServicePicker(items: [url])
        picker.show(relativeTo: rect, of: sourceView, preferredEdge: .maxY)
    }

    func updateCredential(_ credential: BilibiliCredential?) {
        self.credential = credential
    }

    func prepareCoin() -> Bool {
        if videoRelation.coinCount >= 2 {
            showCoinHint("已经投过币了")
            return false
        }
        guard requireCredential() != nil else { return false }
        return true
    }

    func showCoinHint(_ message: String) {
        coinHintDismissTask?.cancel()
        coinHintMessage = message
        coinHintDismissTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            coinHintMessage = nil
        }
    }

    private func requireCredential() -> BilibiliCredential? {
        guard let credential, !credential.biliJct.isEmpty else {
            actionMessage = "请先登录"
            needsLoginPrompt = true
            return nil
        }
        return credential
    }

    private func updateDetail(
        likeDelta: Int64 = 0,
        coinDelta: Int64 = 0,
        favoriteDelta: Int64 = 0,
        shareDelta: Int64 = 0
    ) {
        guard var current = detail else { return }
        let video = current.video
        if likeDelta != 0 {
            let likeCount = max(0, video.likeCount + likeDelta)
            current = BiliVideoDetail(
                video: BiliVideo(
                    id: video.id,
                    bvid: video.bvid,
                    aid: video.aid,
                    title: video.title,
                    coverURL: video.coverURL,
                    authorName: video.authorName,
                    authorFaceURL: video.authorFaceURL,
                    authorMid: video.authorMid,
                    viewCount: video.viewCount,
                    danmakuCount: video.danmakuCount,
                    likeCount: likeCount,
                    duration: video.duration,
                    description: video.description,
                    cid: video.cid,
                    publishTime: video.publishTime
                ),
                publishTime: current.publishTime,
                replyCount: current.replyCount,
                coinCount: max(0, current.coinCount + coinDelta),
                favoriteCount: max(0, current.favoriteCount + favoriteDelta),
                shareCount: max(0, current.shareCount + shareDelta),
                pages: current.pages
            )
        } else {
            current = BiliVideoDetail(
                video: video,
                publishTime: current.publishTime,
                replyCount: current.replyCount,
                coinCount: max(0, current.coinCount + coinDelta),
                favoriteCount: max(0, current.favoriteCount + favoriteDelta),
                shareCount: max(0, current.shareCount + shareDelta),
                pages: current.pages
            )
        }
        detail = current
    }

    private func scheduleInitialCommentsLoad() async {
        try? await Task.sleep(nanoseconds: 600_000_000)
        await loadCommentsIfNeeded()
    }

    func loadCommentsIfNeeded() async {
        let aid = displayVideo.aid
        guard aid > 0 else { return }
        let key = "\(aid):\(commentSort.rawValue)"
        guard loadedCommentsKey != key else { return }
        await loadComments(reset: true)
        loadedCommentsKey = key
    }

    var commentsHaveLoaded: Bool {
        loadedCommentsKey != nil
    }

    func selectPart(_ part: BiliVideoPage) async {
        let generation = lifecycleGeneration
        if part.epid > 0, part.epid != activeEpid {
            activeEpid = part.epid
            activeCID = part.cid
            isLoadingDetail = true
            defer { isLoadingDetail = false }
            do {
                let loaded = try await api.pgcVideoDetail(epid: part.epid, credential: credential)
                guard isLifecycleActive(generation), !Task.isCancelled else { return }
                activeCID = loaded.video.cid
                detail = loaded
                loadedCommentsKey = nil
                comments = []
                commentsEnd = false
                await loadVideoRelation()
                await loadPlayback()
                guard isLifecycleActive(generation) else { return }
                await loadOnlineCount()
                await scheduleInitialCommentsLoad()
            } catch {
                guard isLifecycleActive(generation) else { return }
                playError = error.localizedDescription
            }
            return
        }

        if !part.bvid.isEmpty, part.bvid != displayVideo.bvid {
            activeCID = part.cid
            isLoadingDetail = true
            defer { isLoadingDetail = false }
            do {
                let loaded = try await api.videoDetail(bvid: part.bvid, credential: credential)
                guard isLifecycleActive(generation), !Task.isCancelled else { return }
                activeCID = loaded.video.cid
                detail = loaded
                loadedCommentsKey = nil
                comments = []
                commentsEnd = false
                await loadVideoRelation()
                await loadVideoTags()
                await loadPlayback()
                guard isLifecycleActive(generation) else { return }
                await loadOnlineCount()
                await scheduleInitialCommentsLoad()
            } catch {
                guard isLifecycleActive(generation) else { return }
                playError = error.localizedDescription
            }
            return
        }

        guard part.cid != activeCID else { return }
        activeCID = part.cid
        await loadPlayback()
        guard isLifecycleActive(generation) else { return }
        await loadOnlineCount()
    }

    func loadPlayback() async {
        let generation = lifecycleGeneration
        stopWatchHistoryReporting()

        let bvid = displayVideo.bvid
        let cid = activeCID > 0 ? activeCID : displayVideo.cid
        if isBangumiPlayback {
            guard activeEpid > 0 else {
                playError = "无法确定番剧分集"
                return
            }
        } else {
            guard !bvid.isEmpty, cid > 0 else {
                playError = "无法确定视频分 P"
                return
            }
        }

        isLoadingPlayback = true
        playError = nil
        defer { isLoadingPlayback = false }

        do {
            let stream: BiliPlayStream
            if let prefetchedStream,
               prefetchedStream.cid == cid,
               !prefetchedStream.videoURL.isEmpty {
                stream = BiliPlayStream(
                    videoURL: prefetchedStream.videoURL,
                    audioURL: prefetchedStream.audioURL,
                    aid: displayVideo.aid > 0 ? displayVideo.aid : prefetchedStream.aid,
                    cid: cid
                )
                self.prefetchedStream = nil
            } else {
                stream = try await resolvePlayStream(bvid: bvid, cid: cid)
            }
            guard isLifecycleActive(generation), !Task.isCancelled else { return }

            let resolvedStream = BiliPlayStream(
                videoURL: stream.videoURL,
                audioURL: stream.audioURL,
                aid: displayVideo.aid > 0 ? displayVideo.aid : stream.aid,
                cid: cid
            )
            let cookieHeader = await api.httpCookieHeader(credential: credential)
            guard isLifecycleActive(generation), !Task.isCancelled else { return }

            try await player.load(stream: resolvedStream, cookieHeader: cookieHeader)
            guard isLifecycleActive(generation) else {
                player.stop()
                return
            }

            if isPlaybackSuspended {
                player.pausePlayback()
            }

            applyInitialProgressIfNeeded()
            let reportAid = displayVideo.aid > 0 ? displayVideo.aid : resolvedStream.aid
            startWatchHistoryReporting(aid: reportAid, cid: cid)
            if cid > 0 {
                await loadDanmaku(cid: cid)
            } else {
                danmakuItems = []
            }
        } catch {
            guard isLifecycleActive(generation), !Task.isCancelled else { return }
            playError = error.localizedDescription
        }
    }

    private func loadBangumiEpisodeContext(epid: Int64) async throws -> (BiliPGCEpisodeContext, BiliVideoDetail) {
        let context = try await api.pgcEpisodeContext(epid: epid, credential: credential)
        let loaded = try await api.videoDetail(bvid: context.bvid, credential: credential)
        return (context, loaded)
    }

    private func applyBangumiDetail(context: BiliPGCEpisodeContext, loaded: BiliVideoDetail) -> BiliVideoDetail {
        BiliVideoDetail(
            video: mergeVideoWithPGCContext(loaded.video, context: context),
            publishTime: loaded.publishTime,
            replyCount: loaded.replyCount,
            coinCount: loaded.coinCount,
            favoriteCount: loaded.favoriteCount,
            shareCount: loaded.shareCount,
            pages: context.pages.isEmpty ? loaded.pages : context.pages
        )
    }

    private func mergeVideoWithPGCContext(_ video: BiliVideo, context: BiliPGCEpisodeContext) -> BiliVideo {
        BiliVideo(
            id: "pgc:\(context.epid)",
            bvid: context.bvid,
            aid: context.aid,
            title: context.seasonTitle.ifEmpty(video.title),
            coverURL: context.coverURL ?? video.coverURL,
            authorName: video.authorName,
            authorFaceURL: video.authorFaceURL,
            authorMid: video.authorMid,
            viewCount: video.viewCount,
            danmakuCount: video.danmakuCount,
            likeCount: video.likeCount,
            duration: context.duration > 0 ? context.duration : video.duration,
            description: context.evaluate.ifEmpty(video.description),
            cid: context.cid,
            publishTime: video.publishTime
        )
    }

    private func resolvePlayStream(bvid: String, cid: Int64) async throws -> BiliPlayStream {
        let referer = playbackRefererURL?.absoluteString ?? "https://www.bilibili.com"
        if !bvid.isEmpty, cid > 0 {
            do {
                return try await api.playURL(bvid: bvid, cid: cid, credential: credential)
            } catch {
                if isBangumiPlayback, activeEpid > 0 {
                    return try await api.pgcPlayURL(
                        epid: activeEpid,
                        cid: cid,
                        credential: credential,
                        referer: referer
                    )
                }
                throw error
            }
        }
        if isBangumiPlayback, activeEpid > 0 {
            return try await api.pgcPlayURL(
                epid: activeEpid,
                cid: cid,
                credential: credential,
                referer: referer
            )
        }
        throw APIError.message("无法获取播放地址")
    }

    private func applyInitialProgressIfNeeded() {
        guard !hasAppliedInitialProgress else { return }
        hasAppliedInitialProgress = true
        guard initialProgressSeconds > 0 else { return }

        let durationSeconds = player.duration > 0
            ? Int(player.duration.rounded())
            : displayVideo.duration
        guard durationSeconds <= 0 || initialProgressSeconds < durationSeconds else { return }
        player.seek(to: Double(initialProgressSeconds))
    }

    private func startWatchHistoryReporting(aid: Int64, cid: Int64) {
        guard let credential, aid > 0, cid > 0 else { return }

        watchHistoryContext = (aid, cid)
        watchHistoryTask = Task { @MainActor [weak self] in
            guard let self else { return }

            await self.reportWatchHistoryProgress(aid: aid, cid: cid, credential: credential)
            var ticksSinceReport = 0

            do {
                while !Task.isCancelled {
                    let playing = self.player.isPlaying && !self.player.isScrubbing
                    if playing {
                        if ticksSinceReport >= 20 {
                            await self.reportWatchHistoryProgress(aid: aid, cid: cid, credential: credential)
                            ticksSinceReport = 0
                        } else {
                            ticksSinceReport += 1
                        }
                    } else if ticksSinceReport > 0 {
                        await self.reportWatchHistoryProgress(aid: aid, cid: cid, credential: credential)
                        ticksSinceReport = 0
                    }
                    try await Task.sleep(nanoseconds: 250_000_000)
                }
            } catch {}

            await self.reportWatchHistoryProgress(aid: aid, cid: cid, credential: credential)
        }
    }

    private func reportWatchHistoryProgress(
        aid: Int64,
        cid: Int64,
        credential: BilibiliCredential
    ) async {
        let progress = Int64(player.currentTime.rounded(.down))
        await watchHistoryReporter.reportIfNeeded(
            api: api,
            aid: aid,
            cid: cid,
            progressSeconds: progress,
            credential: credential
        )
    }

    private func stopWatchHistoryReporting() {
        watchHistoryTask?.cancel()
        watchHistoryTask = nil
    }

    private func restartWatchHistoryReportingIfNeeded() {
        guard let context = watchHistoryContext else { return }
        startWatchHistoryReporting(aid: context.aid, cid: context.cid)
    }

    func suspendPlayback() {
        guard !isTornDown, !isPlaybackSuspended else { return }
        isPlaybackSuspended = true
        wasPlayingBeforeSuspend = player.isPlaying
        player.pausePlayback()
        stopWatchHistoryReporting()
    }

    func pauseForUserInitiatedExternalAction() {
        guard !isTornDown else { return }
        isPlaybackSuspended = false
        wasPlayingBeforeSuspend = false
        player.pausePlayback()
        stopWatchHistoryReporting()
    }

    func resumePlaybackIfNeeded() {
        guard !isTornDown, isPlaybackSuspended else { return }
        isPlaybackSuspended = false

        if player.isReady {
            if wasPlayingBeforeSuspend {
                player.resumePlayback()
            }
            restartWatchHistoryReportingIfNeeded()
        } else if playError == nil, !isLoadingPlayback {
            Task { await loadPlayback() }
        }
    }

    func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
        isPlaybackSuspended = false
        lifecycleGeneration += 1
        cleanup()
    }

    func reactivateIfNeeded() {
        guard isTornDown else { return }
        isTornDown = false
        isPlaybackSuspended = false
        wasPlayingBeforeSuspend = false
        Task { await loadPlayback() }
    }

    private func isLifecycleActive(_ generation: Int) -> Bool {
        !isTornDown && generation == lifecycleGeneration
    }

    func cleanup() {
        stopWatchHistoryReporting()
        watchHistoryContext = nil
        player.stop()
        danmakuItems = []
        danmakuCache.removeAll()
        comments = []
        loadedCommentsKey = nil
        commentsLoadInFlight = false
        coinHintDismissTask?.cancel()
        coinHintDismissTask = nil
        coinHintMessage = nil
        authorIpRefreshTask?.cancel()
        authorIpRefreshTask = nil
        authorSign = ""
        authorIpLocation = nil
        authorLevel = 0
        authorFollowerCount = 0
        authorRelation = BiliAuthorRelation()
        onlineCount = 0
        videoTags = []
    }

    func loadDanmaku(cid: Int64) async {
        if let cached = danmakuCache[cid] {
            danmakuItems = cached
            return
        }
        let durationSeconds = Int(
            player.duration > 0 ? player.duration.rounded() : Double(displayVideo.duration)
        )
        let referer = displayVideo.webURL?.absoluteString ?? BilibiliEndpoints.home
        do {
            let items = try await api.danmakuList(
                cid: cid,
                durationSeconds: durationSeconds,
                credential: credential,
                referer: referer
            )
            danmakuCache[cid] = items
            if activeCID == cid {
                danmakuItems = items
            }
        } catch {
            if activeCID == cid {
                danmakuItems = []
            }
        }
    }

    func toggleDanmakuVisible() {
        danmakuVisible.toggle()
        DanmakuPlayerPreferences.setDanmakuVisible(danmakuVisible)
    }

    func updateDanmakuSettings(_ settings: DanmakuSettings) {
        danmakuSettings = settings
        DanmakuPlayerPreferences.setDanmakuSettings(settings)
    }

    func loadComments(reset: Bool) async {
        let aid = displayVideo.aid
        let bvid = displayVideo.bvid
        guard aid > 0 else { return }
        guard !commentsLoadInFlight else { return }

        if reset {
            commentsCursor = nil
            commentsEnd = false
            commentsError = nil
            commentsLoading = true
        } else {
            if commentsEnd || commentsLoadingMore || commentsLoading || comments.isEmpty {
                return
            }
            if commentsCursor?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                commentsEnd = true
                return
            }
            commentsLoadingMore = true
        }

        commentsLoadInFlight = true
        let previousCount = comments.count
        defer {
            commentsLoading = false
            commentsLoadingMore = false
            commentsLoadInFlight = false
        }

        do {
            let page = try await api.videoComments(
                aid: aid,
                bvid: bvid,
                sort: commentSort,
                cursor: reset ? nil : commentsCursor,
                credential: credential
            )
            if reset {
                comments = page.comments
            } else {
                let existing = Set(comments.map(\.id))
                comments.append(contentsOf: page.comments.filter { !existing.contains($0.id) })
            }
            commentsCursor = page.nextCursor
            commentsEnd = resolveCommentsEnd(
                page: page,
                mergedCount: comments.count,
                previousCount: previousCount
            )
            commentsError = nil
        } catch {
            if reset {
                comments = []
                commentsEnd = true
                commentsError = error.localizedDescription
            }
        }
    }

    private func resolveCommentsEnd(page: BiliCommentPage, mergedCount: Int, previousCount: Int) -> Bool {
        if page.isEnd { return true }
        if page.nextCursor?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { return true }
        if page.comments.isEmpty { return true }
        if mergedCount == previousCount { return true }
        return false
    }

    func toggleCommentSort() async {
        let newSort: BiliCommentSort = commentSort == .hot ? .time : .hot
        guard newSort != commentSort else { return }
        commentSort = newSort
        loadedCommentsKey = nil
        await loadComments(reset: true)
        loadedCommentsKey = "\(displayVideo.aid):\(commentSort.rawValue)"
        commentsScrollToTopToken += 1
    }

    func loadMoreReplies(for commentID: Int64) async {
        guard let index = comments.firstIndex(where: { $0.id == commentID }) else { return }
        var comment = comments[index]
        guard !comment.repliesEnd else { return }

        let aid = displayVideo.aid
        let bvid = displayVideo.bvid
        let nextPage = (comment.loadedReplies.count / 20) + 1
        do {
            let page = try await api.commentReplies(
                aid: aid,
                rootID: commentID,
                bvid: bvid,
                page: nextPage,
                credential: credential
            )
            let merged = comment.loadedReplies + page.replies.filter { reply in
                !comment.loadedReplies.contains(where: { $0.id == reply.id })
            }
            comment = BiliCommentItem(
                id: comment.id,
                authorMid: comment.authorMid,
                authorName: comment.authorName,
                authorFaceURL: comment.authorFaceURL,
                level: comment.level,
                content: comment.content,
                likeCount: comment.likeCount,
                replyCount: comment.replyCount,
                publishTime: comment.publishTime,
                ipLocation: comment.ipLocation,
                emoticons: comment.emoticons,
                pictures: comment.pictures,
                replies: comment.replies,
                loadedReplies: merged,
                repliesEnd: page.isEnd,
                isPinned: comment.isPinned
            )
            comments[index] = comment
        } catch {
            commentsError = error.localizedDescription
        }
    }
}

struct VideoDetailChromeInfo: Equatable {
    let title: String
    let viewCount: Int64
    let danmakuCount: Int64
    let publishTime: Date?
    let onlineCount: Int64
    let webURL: URL?
    let authorFaceURL: URL?
    let authorName: String?
    let authorLevel: Int

    init(
        title: String,
        viewCount: Int64,
        danmakuCount: Int64,
        publishTime: Date?,
        onlineCount: Int64,
        webURL: URL?,
        authorFaceURL: URL? = nil,
        authorName: String? = nil,
        authorLevel: Int = 0
    ) {
        self.title = title
        self.viewCount = viewCount
        self.danmakuCount = danmakuCount
        self.publishTime = publishTime
        self.onlineCount = onlineCount
        self.webURL = webURL
        self.authorFaceURL = authorFaceURL
        self.authorName = authorName
        self.authorLevel = authorLevel
    }

    var showsAuthorHeader: Bool {
        authorName != nil
    }
}

struct VideoDetailChromeHeaderView: View {
    let info: VideoDetailChromeInfo

    var body: some View {
        if info.showsAuthorHeader {
            authorHeader
        } else {
            videoHeader
        }
    }

    private var authorHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            AsyncImage(url: info.authorFaceURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    Image(systemName: "person.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 40, height: 40)
            .background(Color.black.opacity(0.06), in: Circle())
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(info.authorName ?? "用户")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if info.authorLevel > 0 {
                        BiliUserLevelIcon(level: info.authorLevel, width: 26, height: 16)
                    }
                }

                if let publishTime = info.publishTime {
                    Text(BiliCommentFormats.formatTime(publishTime))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var videoHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(info.title)
                .font(.title)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 16) {
                BiliStatLabel(icon: .play, value: info.viewCount.compactCount, iconSize: 20)
                BiliStatLabel(icon: .danmaku, value: info.danmakuCount.compactCount, iconSize: 20)
                if let publishTime = info.publishTime {
                    Text(publishTime.numericDateString)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if info.onlineCount > 0 {
                    Text("\(info.onlineCount.compactCount) 人在看")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct VideoDetailView: View {
    @Environment(\.videoDetailChromeHeight) private var chromeHeight
    @EnvironmentObject private var appModel: AppModel
    @StateObject private var model: VideoDetailModel

    init(
        video: BiliVideo,
        credential: BilibiliCredential?,
        initialProgressSeconds: Int = 0,
        playbackEpid: Int64 = 0,
        playbackRefererURL: URL? = nil
    ) {
        _model = StateObject(
            wrappedValue: VideoDetailModel(
                video: video,
                credential: credential,
                initialProgressSeconds: initialProgressSeconds,
                playbackEpid: playbackEpid,
                playbackRefererURL: playbackRefererURL
            )
        )
    }

    @StateObject private var fullscreenPresenter = VideoFullscreenPresenter()
    @State private var playerScreenFrame: NSRect = .zero
    @State private var showLogin = false
    @StateObject private var webSession = BilibiliWebSession()
    @State private var publishesFloatingChrome = false
    @State private var commentFullscreenPicture: CommentFullscreenPicture?

    private func updateFloatingChrome() {
        if publishesFloatingChrome {
            appModel.presentVideoFloatingChrome(detailChromeInfo)
        } else {
            appModel.refreshVideoFloatingChrome(detailChromeInfo)
        }
    }

    private func publishVideoFloatingChrome() {
        appModel.presentVideoFloatingChrome(detailChromeInfo)
    }

    private func updateImmersiveChromeSuppression() {
        appModel.setFloatingChromeSuppressed(
            commentFullscreenPicture != nil || fullscreenPresenter.isPresented
        )
    }

    var body: some View {
        GeometryReader { geometry in
            let columnWidths = AppLayout.videoDetailColumnWidths(in: geometry.size.width)
            let sidebarWidth = columnWidths.sidebar
            let playerWidth = columnWidths.player
            let keepsSidebarLayoutForPortraitVideo = model.player.displayAspectRatio < 1
            let showCommentsInSidebar = sidebarWidth >= 320 || keepsSidebarLayoutForPortraitVideo
            let pageBottomInset = AppLayout.videoDetailBottomInset
            let playerTopInset = chromeHeight > 0 ? chromeHeight : AppLayout.videoDetailPlayerTopInset
            let contentHeight = max(0, geometry.size.height - playerTopInset - pageBottomInset)

            HStack(alignment: .top, spacing: AppLayout.videoDetailSectionSpacing) {
                leftColumn(
                    playerWidth: playerWidth,
                    contentHeight: contentHeight,
                    showCommentsBelowIntro: !showCommentsInSidebar
                )
                .frame(width: playerWidth, alignment: .leading)

                rightSidebar(
                    sidebarWidth: sidebarWidth,
                    contentHeight: contentHeight,
                    showCommentsInSidebar: showCommentsInSidebar
                )
            }
            .frame(width: geometry.size.width, alignment: .topLeading)
            .padding(.leading, AppLayout.videoDetailLeadingInset)
            .padding(.trailing, showCommentsInSidebar ? AppLayout.videoDetailTrailingInset : 0)
            .padding(.top, playerTopInset)
            .padding(.bottom, pageBottomInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(AppLayout.videoDetailPageBackground)
        .background {
            PictureInPictureHostInstaller(player: model.player)
        }
        .navigationBarBackButtonHidden(true)
        .task {
            model.applyPrefetchedStream(appModel.cachedPlayStream(for: model.seedVideo))
            await model.load()
        }
        .onAppear {
            publishesFloatingChrome = true
            publishVideoFloatingChrome()
            MediaPlaybackCoordinator.shared.notifyDetailVisible(model)
        }
        .task(id: model.seedVideo.id) {
            if publishesFloatingChrome {
                publishVideoFloatingChrome()
            }
        }
        .onDisappear {
            publishesFloatingChrome = false
            appModel.setFloatingChromeSuppressed(false)
            appModel.resignVideoFloatingChrome()
            fullscreenPresenter.dismissImmediately()
            MediaPlaybackCoordinator.shared.notifyDetailHidden(model)
            VideoFullscreenPresenter.restoreMainWindowAppearance()
        }
        .onChange(of: commentFullscreenPicture) { _, _ in
            updateImmersiveChromeSuppression()
        }
        .onChange(of: fullscreenPresenter.isPresented) { _, _ in
            updateImmersiveChromeSuppression()
        }
        .onChange(of: model.displayVideo.title) { _, _ in updateFloatingChrome() }
        .onChange(of: model.displayVideo.viewCount) { _, _ in updateFloatingChrome() }
        .onChange(of: model.displayVideo.danmakuCount) { _, _ in updateFloatingChrome() }
        .onChange(of: model.onlineCount) { _, _ in updateFloatingChrome() }
        .onChange(of: model.detail?.publishTime) { _, _ in updateFloatingChrome() }
        .onChange(of: model.needsLoginPrompt) { _, needsLogin in
            if needsLogin {
                showLogin = true
                model.needsLoginPrompt = false
            }
        }
        .alert("提示", isPresented: Binding(
            get: { model.actionMessage != nil },
            set: { if !$0 { model.actionMessage = nil } }
        )) {
            Button("好") { model.actionMessage = nil }
        } message: {
            Text(model.actionMessage ?? "")
        }
        .sheet(isPresented: $showLogin) {
            WebLoginSheet(session: webSession) {
                Task {
                    guard let credential = await webSession.readCredential() else { return }
                    let api = BilibiliAPI()
                    if (try? await api.validate(credential: credential)) != nil {
                        model.updateCredential(credential)
                        showLogin = false
                        await model.loadVideoRelation()
                    }
                }
            }
            .environmentObject(appModel)
        }
        .commentImageFullscreenOverlay(selection: $commentFullscreenPicture)
    }

    private func playerMaxHeight(
        contentHeight: CGFloat
    ) -> CGFloat {
        max(1, contentHeight)
    }

    @ViewBuilder
    private func leftColumn(
        playerWidth: CGFloat,
        contentHeight: CGFloat,
        showCommentsBelowIntro: Bool
    ) -> some View {
        let maxHeight = playerMaxHeight(contentHeight: contentHeight)

        Group {
            if showCommentsBelowIntro {
                let introHeight = compactIntroHeight(playerWidth: playerWidth, contentHeight: contentHeight)

                VStack(alignment: .leading, spacing: AppLayout.videoDetailSectionSpacing) {
                    playerSection(maxWidth: playerWidth, maxHeight: maxHeight)
                        .frame(
                            width: playerWidth,
                            alignment: model.player.displayAspectRatio < 1 ? .center : .leading
                        )
                        .opacity(fullscreenPresenter.isPresented ? 0 : 1)
                        .allowsHitTesting(!fullscreenPresenter.isPresented)

                    VideoIntroCard(
                        model: model,
                        maxHeight: introHeight,
                        onTagTap: { appModel.openSearch(for: $0, returningTo: model.makePlaybackRequest()) }
                    )
                    .frame(width: playerWidth)
                    .fixedSize(horizontal: false, vertical: true)

                    commentsCard
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .layoutPriority(1)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: contentHeight, alignment: .topLeading)
            } else {
                VStack(alignment: .leading, spacing: AppLayout.videoDetailSectionSpacing) {
                    playerSection(maxWidth: playerWidth, maxHeight: maxHeight)
                        .frame(
                            width: playerWidth,
                            alignment: model.player.displayAspectRatio < 1 ? .center : .leading
                        )
                        .opacity(fullscreenPresenter.isPresented ? 0 : 1)
                        .allowsHitTesting(!fullscreenPresenter.isPresented)

                    VideoIntroCard(
                        model: model,
                        maxHeight: regularIntroHeight(playerWidth: playerWidth, contentHeight: contentHeight),
                        fillToHeight: true,
                        onTagTap: { appModel.openSearch(for: $0, returningTo: model.makePlaybackRequest()) }
                    )
                    .frame(width: playerWidth)
                    .layoutPriority(1)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: contentHeight, alignment: .topLeading)
            }
        }
    }

    private func compactIntroHeight(playerWidth: CGFloat, contentHeight: CGFloat) -> CGFloat {
        let playerHeight = VideoPlayerChrome.detailPlayerSize(
            maxWidth: playerWidth,
            maxHeight: contentHeight,
            aspectRatio: model.player.displayAspectRatio
        ).height
        let remainingHeight = contentHeight
            - playerHeight
            - AppLayout.videoDetailSectionSpacing * 2
        let heightThatPreservesComments = remainingHeight - AppLayout.videoDetailCompactCommentsMinHeight

        return max(
            1,
            min(
                remainingHeight,
                AppLayout.videoDetailCompactIntroMaxHeight,
                max(AppLayout.videoDetailCompactIntroMinHeight, heightThatPreservesComments)
            )
        )
    }

    private func regularIntroHeight(playerWidth: CGFloat, contentHeight: CGFloat) -> CGFloat {
        let playerHeight = VideoPlayerChrome.detailPlayerSize(
            maxWidth: playerWidth,
            maxHeight: contentHeight,
            aspectRatio: model.player.displayAspectRatio
        ).height
        return max(
            1,
            contentHeight
                - playerHeight
                - AppLayout.videoDetailSectionSpacing
        )
    }

    private func rightSidebar(
        sidebarWidth: CGFloat,
        contentHeight: CGFloat,
        showCommentsInSidebar: Bool
    ) -> some View {
        let isCompact = sidebarWidth < 360

        return VStack(alignment: .leading, spacing: AppLayout.videoDetailSectionSpacing) {
            authorCard(isCompact: isCompact)
            if (model.detail?.pages.count ?? 0) > 1 {
                VideoEpisodeSection(model: model)
            }
            actionCard(sidebarWidth: sidebarWidth)
            if showCommentsInSidebar {
                commentsCard
                    .layoutPriority(1)
            }
        }
        .frame(width: sidebarWidth, alignment: .leading)
        .frame(height: contentHeight, alignment: .topLeading)
    }

    private func authorCard(isCompact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            authorRow(isCompact: isCompact)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .videoDetailCard()
    }

    private func actionCard(sidebarWidth: CGFloat) -> some View {
        VideoDetailActionBar(
            likeCount: model.displayVideo.likeCount,
            coinCount: model.detail?.coinCount ?? 0,
            favoriteCount: model.detail?.favoriteCount ?? 0,
            shareCount: model.detail?.shareCount ?? 0,
            liked: model.videoRelation.liked,
            coined: model.videoRelation.coinCount > 0,
            favorited: model.videoRelation.favorited,
            canCoinTwo: model.videoRelation.coinCount == 0,
            canCoinMore: model.videoRelation.coinCount < 2,
            coinHintMessage: $model.coinHintMessage,
            availableWidth: sidebarWidth,
            onCoinTap: { model.prepareCoin() },
            onLikeClick: {
                Task { await model.toggleLike() }
            },
            onTripleClick: {
                Task { await model.tripleLike() }
            },
            onCoinBlocked: {
                model.showCoinHint("已经投过币了")
            },
            onCoinOne: {
                Task { await model.coin(multiply: 1) }
            },
            onCoinTwo: {
                Task { await model.coin(multiply: 2) }
            },
            onFavoriteClick: {
                Task { await model.toggleFavorite() }
            },
            onShareClick: { context in
                Task { await model.share(from: context) }
            }
        )
        .frame(maxWidth: .infinity)
        .videoDetailCard()
    }

    private var commentsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            commentsHeader
                .padding(.horizontal, AppLayout.videoDetailCardPadding)
                .padding(.top, AppLayout.videoDetailCardPadding)
                .padding(.bottom, 12)

            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    MacOverlayScrollView(usesOverlayScrollers: false, clipsContent: true) {
                        Color.clear
                            .frame(height: 0)
                            .id(CommentsScrollAnchor.top)

                        VideoCommentsPanel(
                            model: model,
                            contentMinHeight: geometry.size.height,
                            onPictureSelect: { commentFullscreenPicture = $0 }
                        )
                        .padding(.horizontal, AppLayout.videoDetailCardPadding)
                        .padding(.bottom, AppLayout.videoDetailCardPadding)
                    }
                    .onChange(of: model.commentsScrollToTopToken) { _, _ in
                        proxy.scrollTo(CommentsScrollAnchor.top, anchor: .top)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .videoDetailCard(padding: 0)
    }

    private var commentsHeader: some View {
        HStack {
            Text("评论 \(commentCountLabel)")
                .font(.system(size: 16, weight: .semibold))
            Spacer()
            BiliCommentSortToggle(sort: model.commentSort) {
                Task { await model.toggleCommentSort() }
            }
        }
    }

    private func playerSection(maxWidth: CGFloat, maxHeight: CGFloat) -> some View {
        VideoPlayerSection(
            model: model,
            maxWidth: maxWidth,
            maxHeight: maxHeight,
            rendersDanmaku: !fullscreenPresenter.isPresented,
            acceptsKeyboardShortcuts: !fullscreenPresenter.isPresented,
            onToggleFullscreen: toggleFullscreen
        )
        .background {
            PlayerScreenFrameReader { frame in
                playerScreenFrame = frame
            }
        }
    }

    private func toggleFullscreen() {
        if fullscreenPresenter.isPresented {
            fullscreenPresenter.dismiss()
        } else {
            enterFullscreen()
        }
    }

    private func enterFullscreen() {
        fullscreenPresenter.present(
            from: playerScreenFrame,
            sourceFrameProvider: { playerScreenFrame }
        ) {
            VideoPlayerFullscreenContent(
                model: model,
                onClose: { fullscreenPresenter.dismiss() }
            )
        }
    }

    private func authorRow(isCompact: Bool) -> some View {
        Group {
            if isCompact {
                authorRowCompact
            } else {
                authorRowRegular
            }
        }
    }

    private var authorRowRegular: some View {
        HStack(alignment: .center, spacing: 12) {
            authorAvatarLink
                .fixedSize(horizontal: true, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                authorNameLink
                authorBioAndIP
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            followButtonIfNeeded(isCompact: false)
                .fixedSize(horizontal: true, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var authorRowCompact: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                authorAvatarLink
                    .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 6) {
                    authorNameLink
                    followButtonIfNeeded(isCompact: true)
                        .fixedSize(horizontal: true, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            authorBioAndIP
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var authorBioAndIP: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(authorSignSubtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

            if let ipLocation = model.authorIpLocation, !ipLocation.isEmpty {
                Text("IP属地：\(ipLocation)")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private func followButtonIfNeeded(isCompact: Bool) -> some View {
        if model.showAuthorFollowControl {
            let capsuleHeight: CGFloat = isCompact ? 38 : ProfileChromeCapsuleMetrics.height
            AuthorFollowButton(
                isFollowing: model.authorRelation.following,
                followerMe: model.authorRelation.followerMe,
                followerCount: model.authorFollowerCount,
                isLoading: model.authorFollowLoading,
                usesProfileChromeSizing: true,
                fixedCapsuleHeight: capsuleHeight,
                onFollow: {
                    Task { await model.followAuthor() }
                },
                onUnfollow: {
                    Task { await model.unfollowAuthor() }
                }
            )
        }
    }

    @ViewBuilder
    private var authorAvatarLink: some View {
        if model.displayVideo.authorMid > 0 {
            NavigationLink(
                value: UserProfileRequest(mid: model.displayVideo.authorMid)
            ) {
                authorAvatar
            }
            .buttonStyle(.plain)
        } else {
            authorAvatar
        }
    }

    private var authorAvatar: some View {
        AsyncImage(url: model.displayVideo.authorFaceURL) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                Image(systemName: "person.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(Circle())
    }

    @ViewBuilder
    private var authorNameLink: some View {
        if model.displayVideo.authorMid > 0 {
            NavigationLink(
                value: UserProfileRequest(mid: model.displayVideo.authorMid)
            ) {
                VideoDetailAuthorNameLabel(
                    name: model.displayVideo.authorName,
                    level: model.authorLevel
                )
            }
            .buttonStyle(.plain)
        } else {
            VideoDetailAuthorNameLabel(
                name: model.displayVideo.authorName,
                level: model.authorLevel
            )
        }
    }

    private var authorSignSubtitle: String {
        let sign = model.authorSign.trimmingCharacters(in: .whitespacesAndNewlines)
        return sign.isEmpty ? "这个人还没有写简介" : sign
    }

    private var detailChromeInfo: VideoDetailChromeInfo {
        VideoDetailChromeInfo(
            title: model.displayVideo.title,
            viewCount: model.displayVideo.viewCount,
            danmakuCount: model.displayVideo.danmakuCount,
            publishTime: model.detail?.publishTime,
            onlineCount: model.onlineCount,
            webURL: model.displayVideo.webURL
        )
    }

    private var commentCountLabel: String {
        let count = model.detail?.replyCount ?? 0
        return count > 0 ? count.compactCount : ""
    }
}

private struct VideoIntroCard: View {
    @ObservedObject var model: VideoDetailModel
    var maxHeight: CGFloat? = nil
    var fillToHeight = false
    let onTagTap: (String) -> Void

    var body: some View {
        Group {
            if let maxHeight {
                if fillToHeight {
                    GeometryReader { geometry in
                        MacOverlayScrollView(usesOverlayScrollers: false, clipsContent: true) {
                            introContent
                                .frame(minHeight: geometry.size.height, alignment: .topLeading)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                    .frame(height: maxHeight, alignment: .topLeading)
                } else {
                    MacOverlayScrollView(usesOverlayScrollers: false, clipsContent: true) {
                        introContent
                    }
                    .frame(maxWidth: .infinity, maxHeight: maxHeight, alignment: .topLeading)
                    .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                introContent
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .videoDetailCard(padding: 0)
    }

    private var introContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let error = model.detailError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 13))
                    .foregroundStyle(.orange)
            }

            overviewContent
                .padding(.trailing, 4)
        }
        .padding(AppLayout.videoDetailCardPadding)
    }

    private var overviewContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(descriptionText)
                .font(.system(size: 14))
                .foregroundStyle(hasDescription ? .primary : .secondary)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

            if !model.videoTags.isEmpty {
                VideoTagChipFlow(tags: model.videoTags, onTagTap: onTagTap)
            }
        }
    }

    private var hasDescription: Bool {
        !model.displayVideo.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var descriptionText: String {
        let text = model.displayVideo.description.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "这个视频还没有写简介" : text
    }
}

private struct VideoEpisodeSection: View {
    @ObservedObject var model: VideoDetailModel

    private var pages: [BiliVideoPage] {
        model.detail?.pages ?? []
    }

    private var activePart: BiliVideoPage? {
        let activeBvid = model.displayVideo.bvid
        return pages.first(where: { part in
            part.cid == model.activeCID
                && (part.bvid.isEmpty || part.bvid == activeBvid)
        }) ?? pages.first
    }

    var body: some View {
        if let activePart {
            VideoCurrentEpisodeRow(
                part: activePart,
                totalCount: pages.count
            )
            .videoDetailCard()
            .overlay {
                VideoPartMenuPressOverlay(
                    pages: pages,
                    activeCID: model.activeCID,
                    activeBvid: model.displayVideo.bvid,
                    onSelect: { part in
                        Task { await model.selectPart(part) }
                    }
                )
            }
        }
    }
}

private struct VideoCurrentEpisodeRow: View {
    let part: BiliVideoPage
    let totalCount: Int

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Text("分集")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(BiliTheme.pink)

            Text("\(part.page)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(BiliTheme.pink)
                .frame(width: 28, height: 22)
                .background(
                    BiliTheme.pink.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                )

            Text(part.title.ifEmpty("未命名分P"))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("共\(totalCount)集")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            isHovered ? Color.black.opacity(0.06) : Color.black.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

private struct VideoTagChipFlow: View {
    let tags: [String]
    let onTagTap: (String) -> Void

    var body: some View {
        VideoDetailTagFlowLayout(spacing: 8) {
            ForEach(tags, id: \.self) { tag in
                VideoTagChip(title: tag) {
                    onTagTap(tag)
                }
            }
        }
    }
}

private struct VideoTagChip: View {
    let title: String
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(
                    isHovered
                        ? Color(red: 0.25, green: 0.28, blue: 0.35)
                        : Color(red: 0.35, green: 0.38, blue: 0.45)
                )
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(chipBackground, in: Capsule(style: .continuous))
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(Color.black.opacity(isHovered ? 0.08 : 0.04), lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }

    private var chipBackground: Color {
        isHovered ? AppLayout.searchChipHoverFill : Color.black.opacity(0.04)
    }
}

private struct VideoDetailTagFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }

        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

private struct VideoPlayerSection: View {
    @ObservedObject var model: VideoDetailModel
    @ObservedObject private var player: VideoPlaybackEngine
    @StateObject private var chromeState = VideoPlayerChromeState()
    let maxWidth: CGFloat
    let maxHeight: CGFloat
    var isFullscreen = false
    var fullscreenTitle: String? = nil
    var rendersDanmaku = true
    var acceptsKeyboardShortcuts = true
    var onToggleFullscreen: (() -> Void)?

    init(
        model: VideoDetailModel,
        maxWidth: CGFloat,
        maxHeight: CGFloat,
        isFullscreen: Bool = false,
        fullscreenTitle: String? = nil,
        rendersDanmaku: Bool = true,
        acceptsKeyboardShortcuts: Bool = true,
        onToggleFullscreen: (() -> Void)? = nil
    ) {
        self.model = model
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.isFullscreen = isFullscreen
        self.fullscreenTitle = fullscreenTitle
        self.rendersDanmaku = rendersDanmaku
        self.acceptsKeyboardShortcuts = acceptsKeyboardShortcuts
        self.onToggleFullscreen = onToggleFullscreen
        _player = ObservedObject(wrappedValue: model.player)
    }

    private var fittedSize: CGSize {
        VideoPlayerChrome.detailPlayerSize(
            maxWidth: maxWidth,
            maxHeight: maxHeight,
            aspectRatio: player.displayAspectRatio
        )
    }

    var body: some View {
        ZStack {
            Color.black

            playerContentStack
                .compositingGroup()

            playerChromeOverlay
        }
        .background {
            VideoPlayerKeyboardMonitor(handlers: keyboardHandlers)
        }
        .onAppear {
            syncChromeVisibility()
        }
        .onChange(of: player.isPlaying) { _, _ in
            syncChromeVisibility()
        }
        .overlay {
            VideoScrollWheelMonitor(player: player)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: isFullscreen ? nil : fittedSize.width, height: isFullscreen ? nil : fittedSize.height)
        .clipShape(RoundedRectangle(cornerRadius: isFullscreen ? 0 : VideoPlayerChrome.cornerRadius, style: .continuous))
        .overlay {
            if !isFullscreen {
                RoundedRectangle(cornerRadius: VideoPlayerChrome.cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 0.6)
            }
        }
        .animation(.easeOut(duration: 0.2), value: player.displayAspectRatio)
        .onChange(of: chromeState.showsControls) { _, visible in
            guard isFullscreen else { return }
            if !visible && !model.showDanmakuSettings {
                NSCursor.setHiddenUntilMouseMoves(true)
            }
        }
    }

    @ViewBuilder
    private var playerContentStack: some View {
        ZStack {
            if let playError = model.playError {
                ContentUnavailableView("无法播放", systemImage: "play.slash", description: Text(playError))
                    .foregroundStyle(.white.opacity(0.86))
            } else if !player.isReady {
                Color.clear
            } else {
                VideoPlayerSurface(
                    player: player,
                    cornerRadius: isFullscreen ? 0 : VideoPlayerChrome.cornerRadius
                )
                if model.danmakuVisible, !model.danmakuItems.isEmpty, rendersDanmaku, !player.isPictureInPictureActive {
                    DanmakuOverlayView(
                        items: model.danmakuItems,
                        positionMs: Int64(playbackTimeMs(player).rounded()),
                        isPlaying: player.isPlaying && !player.isScrubbing,
                        enabled: model.danmakuVisible,
                        settings: model.danmakuSettings,
                        layoutMode: isFullscreen ? .fullscreen : .inline,
                        isActive: rendersDanmaku,
                        playbackEngine: player
                    )
                    .equatable()
                }
                if player.isPictureInPictureActive {
                    Color.black
                }
            }
            VideoPlayerClickOverlay(
                onSingleClick: {
                    chromeState.revealControls()
                    player.togglePlayback()
                },
                onDoubleClick: {
                    chromeState.revealControls()
                    onToggleFullscreen?()
                },
                onActivity: { chromeState.revealControls() }
            )
        }
    }

    @ViewBuilder
    private var playerChromeOverlay: some View {
        ZStack {
            if model.showDanmakuSettings {
                DanmakuSettingsOverlay(
                    settings: model.danmakuSettings,
                    onSettingsChange: model.updateDanmakuSettings,
                    onDismiss: { model.showDanmakuSettings = false }
                )
            }

            VStack(spacing: 0) {
                if isFullscreen, let fullscreenTitle {
                    VideoFullscreenTitleBar(title: fullscreenTitle)
                        .opacity(chromeState.showsControls ? 1 : 0)
                        .allowsHitTesting(false)
                }

                Spacer()

                if !model.showDanmakuSettings {
                    VideoControlCapsule(
                        player: player,
                        danmakuVisible: model.danmakuVisible,
                        onDanmakuToggle: model.toggleDanmakuVisible,
                        onDanmakuRightClick: { model.showDanmakuSettings = true },
                        onInteraction: { chromeState.revealControls() }
                    )
                    .opacity(chromeState.showsControls ? 1 : 0)
                    .allowsHitTesting(chromeState.showsControls)
                    .padding(.horizontal, 16)
                    .padding(.bottom, isFullscreen ? 32 : 28)
                }
            }
            .animation(.easeInOut(duration: 0.28), value: chromeState.showsControls)
        }
    }

    private func playbackTimeMs(_ player: VideoPlaybackEngine) -> Double {
        let seconds = player.isScrubbing ? (player.scrubPreviewTime ?? player.preciseCurrentTime) : player.preciseCurrentTime
        return seconds * 1000
    }

    private func syncChromeVisibility() {
        chromeState.revealControls()
    }

    private var keyboardHandlers: VideoPlayerKeyboardHandlers {
        VideoPlayerKeyboardHandlers(
            isFullscreen: isFullscreen,
            shouldHandle: {
                acceptsKeyboardShortcuts
                    && !model.showDanmakuSettings
                    && VideoPlayerKeyboardRouting.shouldHandleInVideoDetail()
            },
            onInteraction: { chromeState.revealControls() },
            onTogglePlayback: { player.togglePlayback() },
            onSeekBackward: { player.seek(by: -5) },
            onSeekForward: { player.seek(by: 5) },
            onVolumeUp: { SystemAudioVolume.adjust(by: 0.1) },
            onVolumeDown: { SystemAudioVolume.adjust(by: -0.1) },
            onToggleFullscreen: { onToggleFullscreen?() },
            onExitFullscreen: { onToggleFullscreen?() },
            onToggleMute: { player.toggleMute() },
            onToggleDanmaku: { model.toggleDanmakuVisible() }
        )
    }
}

private struct VideoPlayerFullscreenContent: View {
    @ObservedObject var model: VideoDetailModel
    let onClose: () -> Void

    var body: some View {
        VideoPlayerSection(
            model: model,
            maxWidth: 0,
            maxHeight: 0,
            isFullscreen: true,
            fullscreenTitle: model.displayVideo.title,
            onToggleFullscreen: onClose
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .ignoresSafeArea()
    }
}

private struct VideoPlayerClickOverlay: NSViewRepresentable {
    let onSingleClick: () -> Void
    let onDoubleClick: () -> Void
    var onActivity: (() -> Void)?

    func makeNSView(context: Context) -> VideoPlayerClickView {
        let view = VideoPlayerClickView()
        view.onSingleClick = onSingleClick
        view.onDoubleClick = onDoubleClick
        view.onActivity = onActivity
        return view
    }

    func updateNSView(_ nsView: VideoPlayerClickView, context: Context) {
        nsView.onSingleClick = onSingleClick
        nsView.onDoubleClick = onDoubleClick
        nsView.onActivity = onActivity
    }
}

private final class VideoPlayerClickView: NSView {
    var onSingleClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onActivity: (() -> Void)?
    private var singleClickWorkItem: DispatchWorkItem?
    private var mouseMoveMonitor: Any?
    private var lastActivityTime: TimeInterval = 0

    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            installMouseMoveMonitorIfNeeded()
        } else {
            tearDownMouseMoveMonitor()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        let options: NSTrackingArea.Options = [
            .activeAlways,
            .mouseMoved,
            .inVisibleRect,
            .enabledDuringMouseDrag
        ]
        addTrackingArea(NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        notifyActivity()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        if point.y <= VideoControlLayout.chromeHitTestClearance {
            return nil
        }
        return super.hitTest(point)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        if event.clickCount == 2 {
            singleClickWorkItem?.cancel()
            singleClickWorkItem = nil
            onDoubleClick?()
            return
        }
        guard event.clickCount == 1 else { return }
        singleClickWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.onSingleClick?()
            self?.singleClickWorkItem = nil
        }
        singleClickWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }

    private func installMouseMoveMonitorIfNeeded() {
        guard mouseMoveMonitor == nil else { return }
        mouseMoveMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        ) { [weak self] event in
            guard let self, let window, event.window === window else { return event }
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point) else { return event }
            notifyActivity()
            return event
        }
    }

    private func tearDownMouseMoveMonitor() {
        if let mouseMoveMonitor {
            NSEvent.removeMonitor(mouseMoveMonitor)
            self.mouseMoveMonitor = nil
        }
    }

    private func notifyActivity() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastActivityTime > 0.08 else { return }
        lastActivityTime = now
        onActivity?()
    }

    deinit {
        MainActor.assumeIsolated {
            tearDownMouseMoveMonitor()
        }
    }
}

private enum VideoControlLayout {
    static let capsuleHeight: CGFloat = 62
    static let horizontalPadding: CGFloat = 16
    static let verticalPadding: CGFloat = 13
    static let itemSpacing: CGFloat = 12
    static let timeMinWidth: CGFloat = 54
    static let speedMinWidth: CGFloat = 42
    static let trailingControlSpacing: CGFloat = 12
    static let pictureInPictureButtonSize: CGFloat = 50
    static let pictureInPictureIconSize: CGFloat = 26
    static let playIconSize: CGFloat = 22
    static let playButtonSize: CGFloat = 42
    static let danmakuFontSize: CGFloat = 20
    static let danmakuButtonSize: CGFloat = 44
    static let progressLineWidth: CGFloat = 6
    static let chromeHitTestClearance: CGFloat = 80
}

private struct VideoControlInteractiveForeground: ViewModifier {
    var isEnabled: Bool = true
    var baseOpacity: CGFloat = 1

    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .foregroundStyle(isHovered && isEnabled ? BiliTheme.pink : .white.opacity(baseOpacity))
            .animation(.easeOut(duration: 0.15), value: isHovered)
            .onHover { hovering in
                guard isEnabled else { return }
                isHovered = hovering
            }
    }
}

private extension View {
    func videoControlHoverForeground(isEnabled: Bool = true, baseOpacity: CGFloat = 1) -> some View {
        modifier(VideoControlInteractiveForeground(isEnabled: isEnabled, baseOpacity: baseOpacity))
    }
}

private struct VideoFullscreenTitleBar: View {
    let title: String

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(title.ifEmpty("视频"))
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .shadow(color: .black.opacity(0.45), radius: 8, y: 2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
    }
}

private struct VideoControlCapsule: View {
    @ObservedObject var player: VideoPlaybackEngine
    let danmakuVisible: Bool
    let onDanmakuToggle: () -> Void
    let onDanmakuRightClick: () -> Void
    var onInteraction: () -> Void = {}

    @State private var dragProgress: Double?
    @State private var displayedProgress: Double = 0

    private var progress: Double {
        if let dragProgress { return dragProgress }
        guard player.duration > 0 else { return 0 }
        let time = player.isScrubbing ? (player.scrubPreviewTime ?? player.preciseCurrentTime) : player.preciseCurrentTime
        return min(1, max(0, time / player.duration))
    }

    private var positionTime: Double {
        player.isScrubbing ? (player.scrubPreviewTime ?? player.preciseCurrentTime) : player.preciseCurrentTime
    }

    private var pictureInPictureEnabled: Bool {
        AVPictureInPictureController.isPictureInPictureSupported() && player.isReady
    }

    var body: some View {
        ZStack {
            GeometryReader { proxy in
                Color.clear
                    .contentShape(Capsule())
                    .gesture(scrubGesture(totalWidth: proxy.size.width))
            }

            VideoControlCapsuleProgress(progress: displayedProgress)
                .allowsHitTesting(false)

            HStack(spacing: VideoControlLayout.itemSpacing) {
                Text(formatTime(positionTime))
                    .font(.system(size: VideoControlLayout.danmakuFontSize, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(minWidth: VideoControlLayout.timeMinWidth, alignment: .leading)
                    .allowsHitTesting(false)

                Button(action: {
                    onInteraction()
                    player.togglePlayback()
                }) {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: VideoControlLayout.playIconSize, weight: .bold))
                        .videoControlHoverForeground()
                        .frame(
                            width: VideoControlLayout.playButtonSize,
                            height: VideoControlLayout.playButtonSize
                        )
                }
                .buttonStyle(.plain)

                DanmakuToggleButton(
                    visible: danmakuVisible,
                    onTap: {
                        onInteraction()
                        onDanmakuToggle()
                    },
                    onRightClick: {
                        onInteraction()
                        onDanmakuRightClick()
                    }
                )

                Spacer(minLength: 0)
                    .allowsHitTesting(false)

                HStack(spacing: VideoControlLayout.trailingControlSpacing) {
                    Button(action: {
                        onInteraction()
                        player.requestPictureInPicture()
                    }) {
                        Image(nsImage: player.isPictureInPictureActive
                            ? AVPictureInPictureController.pictureInPictureButtonStopImage
                            : AVPictureInPictureController.pictureInPictureButtonStartImage
                        )
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .videoControlHoverForeground(isEnabled: pictureInPictureEnabled)
                            .frame(
                                width: VideoControlLayout.pictureInPictureIconSize,
                                height: VideoControlLayout.pictureInPictureIconSize
                            )
                            .frame(
                                width: VideoControlLayout.pictureInPictureButtonSize,
                                height: VideoControlLayout.pictureInPictureButtonSize
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!pictureInPictureEnabled)
                    .opacity(pictureInPictureEnabled ? 1 : 0.42)

                    Button(action: {
                        onInteraction()
                        player.cyclePlaybackRate()
                    }) {
                        Text(player.playbackRateLabel)
                            .font(.system(size: VideoControlLayout.danmakuFontSize, weight: .bold))
                            .videoControlHoverForeground()
                            .frame(minWidth: VideoControlLayout.speedMinWidth, alignment: .center)
                    }
                    .buttonStyle(.plain)

                    Text(formatTime(max(0, player.duration - positionTime)))
                        .font(.system(size: VideoControlLayout.danmakuFontSize, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(minWidth: VideoControlLayout.timeMinWidth, alignment: .trailing)
                        .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, VideoControlLayout.horizontalPadding)
            .padding(.vertical, VideoControlLayout.verticalPadding)
        }
        .frame(height: VideoControlLayout.capsuleHeight)
        .clipShape(Capsule(style: .continuous))
        .modifier(VideoControlCapsuleChrome())
        .onChange(of: progress) { _, newValue in
            if player.isScrubbing || !player.isPlaying {
                displayedProgress = newValue
            } else {
                withAnimation(.linear(duration: 0.12)) {
                    displayedProgress = newValue
                }
            }
        }
        .onAppear {
            displayedProgress = progress
        }
        .onHover { hovering in
            if hovering {
                onInteraction()
            }
        }
    }

    private func scrubGesture(totalWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                onInteraction()
                let fraction = scrubFraction(at: value.location.x, totalWidth: totalWidth)
                let target = fraction * max(player.duration, 0)
                if dragProgress == nil {
                    player.beginScrub(at: target)
                } else {
                    player.updateScrubPreview(target)
                }
                dragProgress = fraction
            }
            .onEnded { value in
                onInteraction()
                let fraction = scrubFraction(at: value.location.x, totalWidth: totalWidth)
                player.endScrub(at: fraction * max(player.duration, 0))
                dragProgress = nil
            }
    }

    private func scrubFraction(at x: CGFloat, totalWidth: CGFloat) -> Double {
        min(1, max(0, Double(x / max(totalWidth, 1))))
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

private struct VideoControlCapsuleChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .glassEffect(.clear, in: .capsule)
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(BiliTheme.videoControlBorder, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.22), radius: 10, x: 0, y: 3)
    }
}

private struct VideoControlCapsuleProgress: View {
    let progress: Double

    var body: some View {
        GeometryReader { proxy in
            let clamped = min(1, max(0, progress))
            let lineWidth = VideoControlLayout.progressLineWidth
            let trackHeight = proxy.size.height
            if clamped > 0 {
                let offset = min(
                    max(0, proxy.size.width * clamped - lineWidth / 2),
                    max(0, proxy.size.width - lineWidth)
                )
                Capsule(style: .continuous)
                    .fill(BiliTheme.pink)
                    .frame(width: lineWidth, height: trackHeight)
                    .offset(x: offset)
            }
        }
    }
}

private struct DanmakuToggleButton: View {
    let visible: Bool
    let onTap: () -> Void
    let onRightClick: () -> Void

    @State private var isHovered = false

    var body: some View {
        Text("弹")
            .font(.system(size: VideoControlLayout.danmakuFontSize, weight: visible ? .bold : .regular))
            .foregroundStyle(
                isHovered ? BiliTheme.pink : .white.opacity(visible ? 1 : 0.42)
            )
            .animation(.easeOut(duration: 0.15), value: isHovered)
            .frame(
                minWidth: VideoControlLayout.danmakuButtonSize,
                minHeight: VideoControlLayout.danmakuButtonSize
            )
            .contentShape(Rectangle())
            .overlay {
                DanmakuToggleClickView(
                    onTap: onTap,
                    onRightClick: onRightClick,
                    onHoverChange: { isHovered = $0 }
                )
            }
    }
}

private struct DanmakuToggleClickView: NSViewRepresentable {
    let onTap: () -> Void
    let onRightClick: () -> Void
    let onHoverChange: (Bool) -> Void

    func makeNSView(context: Context) -> DanmakuToggleClickNSView {
        let view = DanmakuToggleClickNSView()
        view.onTap = onTap
        view.onRightClick = onRightClick
        view.onHoverChange = onHoverChange
        return view
    }

    func updateNSView(_ nsView: DanmakuToggleClickNSView, context: Context) {
        nsView.onTap = onTap
        nsView.onRightClick = onRightClick
        nsView.onHoverChange = onHoverChange
    }
}

private final class DanmakuToggleClickNSView: NSView {
    var onTap: (() -> Void)?
    var onRightClick: (() -> Void)?
    var onHoverChange: ((Bool) -> Void)?

    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let options: NSTrackingArea.Options = [.activeAlways, .mouseEnteredAndExited, .inVisibleRect]
        let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        DispatchQueue.main.async { [weak self] in
            self?.onHoverChange?(true)
        }
    }

    override func mouseExited(with event: NSEvent) {
        DispatchQueue.main.async { [weak self] in
            self?.onHoverChange?(false)
        }
    }

    override func mouseDown(with event: NSEvent) {
        onTap?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?()
    }
}

private enum CommentsScrollAnchor {
    static let top = "comments-scroll-top"
}

private struct VideoCommentsPanel: View {
    @ObservedObject var model: VideoDetailModel
    var contentMinHeight: CGFloat = 0
    var onPictureSelect: (CommentFullscreenPicture) -> Void = { _ in }

    var body: some View {
        Group {
            switch panelState {
            case .notLoaded:
                centeredPlaceholder {
                    commentsPlaceholder(title: "评论还未加载")
                }
            case .loading:
                centeredPlaceholder {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在加载评论")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
            case .failed(let error):
                centeredPlaceholder {
                    ContentUnavailableView(
                        "评论加载失败",
                        systemImage: "bubble.left.and.exclamationmark",
                        description: Text(error)
                    )
                }
            case .empty:
                centeredPlaceholder {
                    commentsPlaceholder(title: "还没有评论")
                }
            case .content:
                commentList
            }
        }
        .frame(maxWidth: .infinity, minHeight: usesCenteredPlaceholder ? contentMinHeight : 0, alignment: .topLeading)
    }

    private enum PanelState: Equatable {
        case notLoaded
        case loading
        case failed(String)
        case empty
        case content
    }

    private var panelState: PanelState {
        if model.commentsLoading, model.comments.isEmpty {
            return .loading
        }
        if !model.commentsHaveLoaded, model.comments.isEmpty, model.commentsError == nil {
            return .notLoaded
        }
        if let error = model.commentsError, model.comments.isEmpty {
            return .failed(error)
        }
        if model.comments.isEmpty {
            return .empty
        }
        return .content
    }

    private var usesCenteredPlaceholder: Bool {
        panelState != .content
    }

    private var commentList: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(model.comments) { comment in
                CommentRow(
                    comment: comment,
                    nested: false,
                    videoAuthorMid: model.displayVideo.authorMid,
                    onPictureSelect: onPictureSelect
                )
                ForEach(comment.loadedReplies) { reply in
                    CommentRow(
                        comment: reply,
                        nested: true,
                        videoAuthorMid: model.displayVideo.authorMid,
                        onPictureSelect: onPictureSelect
                    )
                }
                if comment.replyCount > Int64(comment.loadedReplies.count), !comment.repliesEnd {
                    Button {
                        Task { await model.loadMoreReplies(for: comment.id) }
                    } label: {
                        Text("查看 \(max(0, comment.replyCount - Int64(comment.loadedReplies.count))) 条回复")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(BiliTheme.blue)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, nestedReplyIndent)
                            .padding(.top, 2)
                            .padding(.bottom, 2)
                    }
                    .buttonStyle(.plain)
                }
            }

            if model.commentsLoadingMore && !model.comments.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在加载更多")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
            } else if !model.commentsEnd, !model.comments.isEmpty, !model.commentsLoading, !model.commentsLoadingMore {
                Color.clear
                    .frame(height: 1)
                    .onAppear {
                        Task { await model.loadComments(reset: false) }
                    }
            }
        }
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func centeredPlaceholder<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func commentsPlaceholder(title: String) -> some View {
        ContentUnavailableView(title, systemImage: "bubble.left")
    }

    private var nestedReplyIndent: CGFloat { 44 }
}

private struct VideoDetailAuthorNameLabel: View {
    let name: String
    let level: Int

    @State private var isHovered = false

    private let defaultColor = Color(red: 0.14, green: 0.14, blue: 0.16)

    var body: some View {
        HStack(spacing: 6) {
            Text(name.ifEmpty("未知 UP 主"))
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(isHovered ? BiliTheme.blue : defaultColor)
                .contentTransition(.interpolate)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if level > 0 {
                BiliUserLevelIcon(level: level, width: 28, height: 18)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isHovered)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
    }
}

private struct CommentRow: View {
    let comment: BiliCommentItem
    let nested: Bool
    let videoAuthorMid: Int64
    let onPictureSelect: (CommentFullscreenPicture) -> Void

    private var isVideoAuthor: Bool {
        videoAuthorMid > 0 && comment.authorMid == videoAuthorMid
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if nested {
                Spacer().frame(width: 16)
            }

            authorAvatarLink

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 6) {
                    authorNameLink

                    if comment.level > 0 {
                        BiliUserLevelIcon(level: comment.level, width: 22, height: 14)
                    }

                    if isVideoAuthor {
                        BiliUpAuthorBadge()
                    }

                    if comment.isPinned {
                        BiliPinnedCommentBadge()
                    }
                }

                if !comment.content.isEmpty {
                    BiliCommentText(
                        text: comment.content,
                        emoticons: comment.emoticons,
                        fontSize: nested ? 14 : 15
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !comment.pictures.isEmpty {
                    CommentPictureAttachments(pictures: comment.pictures, onSelect: onPictureSelect)
                }

                commentMetaRow
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, nested ? 4 : 6)
    }

    @ViewBuilder
    private var authorAvatarLink: some View {
        let avatar = authorAvatar
        if comment.authorMid > 0 {
            NavigationLink(value: UserProfileRequest(mid: comment.authorMid)) {
                avatar
            }
            .buttonStyle(.plain)
        } else {
            avatar
        }
    }

    private var authorAvatar: some View {
        AsyncImage(url: comment.authorFaceURL) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                Image(systemName: "person.fill")
                    .font(.system(size: nested ? 12 : 14))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: nested ? 28 : 34, height: nested ? 28 : 34)
        .clipShape(Circle())
        .contentShape(Circle())
    }

    @ViewBuilder
    private var authorNameLink: some View {
        if comment.authorMid > 0 {
            NavigationLink(value: UserProfileRequest(mid: comment.authorMid)) {
                authorNameLabel
            }
            .buttonStyle(.plain)
        } else {
            authorNameLabel
        }
    }

    private var authorNameLabel: some View {
        Text(comment.authorName.ifEmpty("用户"))
            .font(.system(size: nested ? 14 : 15, weight: .semibold))
            .foregroundStyle(Color(red: 0.14, green: 0.14, blue: 0.16))
            .lineLimit(1)
            .contentShape(Rectangle())
    }

    private var commentMetaRow: some View {
        HStack(spacing: 10) {
            let timeText = BiliCommentFormats.formatTime(comment.publishTime)
            if !timeText.isEmpty {
                Text(timeText)
            }

            if let ip = comment.ipLocation?.trimmingCharacters(in: .whitespacesAndNewlines), !ip.isEmpty {
                Text(ip)
            }

            HStack(spacing: 2) {
                Text("赞")
                Text(comment.likeCount.compactCount)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(Color(red: 0.62, green: 0.64, blue: 0.68))
        .lineLimit(1)
    }
}

private extension Int {
    var durationText: String {
        guard self > 0 else { return "" }
        let hours = self / 3600
        let minutes = (self % 3600) / 60
        let seconds = self % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

private extension Date {
    var numericDateString: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: self)
    }
}
