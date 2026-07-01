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
    @Published var onlineCount: Int64 = 0
    @Published var videoTags: [String] = []
    @Published var videoActionLoading = false
    @Published var actionMessage: String?
    @Published var needsLoginPrompt = false

    init(video: BiliVideo, credential: BilibiliCredential?, initialProgressSeconds: Int = 0) {
        self.seedVideo = video
        self.credential = credential
        self.activeCID = video.cid
        self.initialProgressSeconds = max(0, initialProgressSeconds)
        playerChangeSink = player.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var displayVideo: BiliVideo {
        detail?.video ?? seedVideo
    }

    func load() async {
        let generation = lifecycleGeneration
        isLoadingDetail = true
        detailError = nil
        authorSign = ""
        onlineCount = 0
        videoTags = []
        defer { isLoadingDetail = false }

        do {
            let loaded = try await api.videoDetail(bvid: seedVideo.bvid, credential: credential)
            guard isLifecycleActive(generation), !Task.isCancelled else { return }
            detail = loaded
            if activeCID <= 0 {
                activeCID = loaded.video.cid
            }
            async let authorSignTask = loadAuthorSign()
            async let onlineCountTask = loadOnlineCount()
            async let videoTagsTask = loadVideoTags()
            await loadVideoRelation()
            guard isLifecycleActive(generation), !Task.isCancelled else { return }
            await loadPlayback()
            guard isLifecycleActive(generation), !Task.isCancelled else { return }
            await scheduleInitialCommentsLoad()
            await authorSignTask
            await onlineCountTask
            await videoTagsTask
        } catch {
            guard isLifecycleActive(generation) else { return }
            detailError = error.localizedDescription
        }
    }

    private func loadAuthorSign() async {
        let mid = displayVideo.authorMid
        guard mid > 0 else {
            authorSign = ""
            return
        }
        authorSign = await api.userSign(mid: mid, credential: credential)
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
            actionMessage = "已经投过币了"
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
            actionMessage = "已经投过币了"
            return false
        }
        guard requireCredential() != nil else { return false }
        return true
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
                    cid: video.cid
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
        guard part.cid != activeCID else { return }
        let generation = lifecycleGeneration
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
        guard !bvid.isEmpty, cid > 0 else {
            playError = "无法确定视频分 P"
            return
        }

        isLoadingPlayback = true
        playError = nil
        defer { isLoadingPlayback = false }

        do {
            var stream = try await api.playURL(bvid: bvid, cid: cid, credential: credential)
            guard isLifecycleActive(generation), !Task.isCancelled else { return }

            stream = BiliPlayStream(
                videoURL: stream.videoURL,
                audioURL: stream.audioURL,
                aid: displayVideo.aid,
                cid: cid
            )
            let cookieHeader = await api.httpCookieHeader(credential: credential)
            guard isLifecycleActive(generation), !Task.isCancelled else { return }

            try await player.load(stream: stream, cookieHeader: cookieHeader)
            guard isLifecycleActive(generation) else {
                player.stop()
                return
            }

            applyInitialProgressIfNeeded()
            startWatchHistoryReporting(aid: displayVideo.aid, cid: cid)
            await loadDanmaku(cid: cid)
        } catch {
            guard isLifecycleActive(generation), !Task.isCancelled else { return }
            playError = error.localizedDescription
        }
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
        authorSign = ""
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
                replies: comment.replies,
                loadedReplies: merged,
                repliesEnd: page.isEnd
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
}

struct VideoDetailChromePreferenceKey: PreferenceKey {
    static var defaultValue: VideoDetailChromeInfo?

    static func reduce(value: inout VideoDetailChromeInfo?, nextValue: () -> VideoDetailChromeInfo?) {
        if let next = nextValue() {
            value = next
        }
    }
}

struct VideoDetailChromeHeaderView: View {
    let info: VideoDetailChromeInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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

    init(video: BiliVideo, credential: BilibiliCredential?, initialProgressSeconds: Int = 0) {
        _model = StateObject(
            wrappedValue: VideoDetailModel(
                video: video,
                credential: credential,
                initialProgressSeconds: initialProgressSeconds
            )
        )
    }

    @StateObject private var fullscreenPresenter = VideoFullscreenPresenter()
    @State private var playerScreenFrame: NSRect = .zero
    @State private var showLogin = false
    @StateObject private var webSession = BilibiliWebSession()

    var body: some View {
        GeometryReader { geometry in
            let columnWidths = AppLayout.videoDetailColumnWidths(in: geometry.size.width)
            let sidebarWidth = columnWidths.sidebar
            let playerWidth = columnWidths.player
            let playerTopInset = AppLayout.videoDetailPlayerTopInset(chromeHeight: chromeHeight)

            HStack(alignment: .top, spacing: AppLayout.videoDetailSectionSpacing) {
                leftColumn(
                    playerWidth: playerWidth,
                    playerTopInset: playerTopInset,
                    geometry: geometry
                )
                .frame(width: playerWidth, alignment: .leading)
                .clipped()

                rightSidebar(
                    playerTopInset: playerTopInset,
                    sidebarWidth: sidebarWidth
                )
            }
            .frame(width: geometry.size.width, alignment: .topLeading)
            .padding(.leading, AppLayout.videoDetailLeadingInset)
            .padding(.trailing, AppLayout.videoDetailTrailingInset)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(AppLayout.videoDetailPageBackground)
        .navigationBarBackButtonHidden(true)
        .background {
            Color.clear
                .preference(key: VideoDetailChromePreferenceKey.self, value: detailChromeInfo)
        }
        .task { await model.load() }
        .onAppear {
            MediaPlaybackCoordinator.shared.notifyDetailVisible(model)
        }
        .onDisappear {
            fullscreenPresenter.dismissImmediately()
            MediaPlaybackCoordinator.shared.notifyDetailHidden(model)
            VideoFullscreenPresenter.restoreMainWindowAppearance()
        }
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
        }
    }

    private func playerMaxHeight(
        in geometry: GeometryProxy,
        playerTopInset: CGFloat
    ) -> CGFloat {
        let reservedBelowPlayer: CGFloat = 150
        let verticalInsets = playerTopInset + reservedBelowPlayer + 24
        return max(280, geometry.size.height - verticalInsets)
    }

    @ViewBuilder
    private func leftColumn(
        playerWidth: CGFloat,
        playerTopInset: CGFloat,
        geometry: GeometryProxy
    ) -> some View {
        let maxHeight = playerMaxHeight(in: geometry, playerTopInset: playerTopInset)
        let fittedPlayerSize = VideoPlayerChrome.fittedSize(
            maxWidth: playerWidth,
            maxHeight: maxHeight,
            aspectRatio: model.player.displayAspectRatio
        )

        VStack(alignment: .leading, spacing: AppLayout.videoDetailSectionSpacing) {
            playerSection(
                maxWidth: playerWidth,
                maxHeight: maxHeight
            )
            .frame(maxWidth: playerWidth, alignment: .leading)
            .opacity(fullscreenPresenter.isPresented ? 0 : 1)
            .allowsHitTesting(!fullscreenPresenter.isPresented)

            VideoIntroCard(
                model: model,
                onTagTap: { appModel.openSearch(for: $0) }
            )
            .frame(width: min(fittedPlayerSize.width, playerWidth))

            if (model.detail?.pages.count ?? 0) > 1 {
                VideoMultiPartCard(model: model)
                    .frame(width: min(fittedPlayerSize.width, playerWidth))
            }
        }
        .padding(.top, playerTopInset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rightSidebar(playerTopInset: CGFloat, sidebarWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: AppLayout.videoDetailSectionSpacing) {
            authorCard
            actionCard(sidebarWidth: sidebarWidth)
            commentsCard
        }
        .frame(width: sidebarWidth, alignment: .leading)
        .clipped()
        .padding(.top, playerTopInset)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private var authorCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            authorRow
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
            availableWidth: sidebarWidth,
            onCoinTap: { model.prepareCoin() },
            onLikeClick: {
                Task { await model.toggleLike() }
            },
            onTripleClick: {
                Task { await model.tripleLike() }
            },
            onCoinBlocked: {
                model.actionMessage = "已经投过币了"
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
        .clipped()
    }

    private var commentsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            commentsHeader
                .padding(.horizontal, AppLayout.videoDetailCardPadding)
                .padding(.top, AppLayout.videoDetailCardPadding)
                .padding(.bottom, 12)

            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    MacOverlayScrollView(usesOverlayScrollers: false) {
                        Color.clear
                            .frame(height: 0)
                            .id(CommentsScrollAnchor.top)

                        VideoCommentsPanel(
                            model: model,
                            contentMinHeight: geometry.size.height
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

    private var authorRow: some View {
        Group {
            if model.displayVideo.authorMid > 0 {
                NavigationLink(
                    value: UserProfileRequest(
                        mid: model.displayVideo.authorMid,
                        seedName: model.displayVideo.authorName,
                        seedFaceURL: model.displayVideo.authorFaceURL
                    )
                ) {
                    authorRowContent
                }
                .buttonStyle(.plain)
            } else {
                authorRowContent
            }
        }
    }

    private var authorRowContent: some View {
        HStack(alignment: .top, spacing: 12) {
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

            VStack(alignment: .leading, spacing: 6) {
                Text(model.displayVideo.authorName.ifEmpty("未知 UP 主"))
                    .font(.system(size: 18, weight: .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(authorSignSubtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
    let onTagTap: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let error = model.detailError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 13))
                    .foregroundStyle(.orange)
            }

            overviewContent
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .videoDetailCard()
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

private struct VideoMultiPartCard: View {
    @ObservedObject var model: VideoDetailModel
    @State private var showsPartSheet = false

    private var pages: [BiliVideoPage] {
        model.detail?.pages ?? []
    }

    var body: some View {
        Button {
            showsPartSheet = true
        } label: {
            VideoMultiPartEntryRow(
                title: model.displayVideo.title,
                partCount: pages.count
            )
        }
        .buttonStyle(.plain)
        .videoDetailCard()
        .sheet(isPresented: $showsPartSheet) {
            VideoPartCollectionSheet(
                pages: pages,
                activeCID: model.activeCID,
                onSelect: { part in
                    showsPartSheet = false
                    Task { await model.selectPart(part) }
                },
                onDismiss: { showsPartSheet = false }
            )
        }
    }
}

private struct VideoMultiPartEntryRow: View {
    let title: String
    let partCount: Int

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Text("合集")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(BiliTheme.pink)

            Text(title.ifEmpty("未命名视频"))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("\(partCount)P")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
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

private struct VideoPartCollectionSheet: View {
    let pages: [BiliVideoPage]
    let activeCID: Int64
    let onSelect: (BiliVideoPage) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("分集 (\(pages.count))")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Color.black.opacity(0.05), in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(pages) { part in
                            VideoPartCollectionRow(
                                part: part,
                                isSelected: part.cid == activeCID,
                                onSelect: { onSelect(part) }
                            )
                            .id(part.cid)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                }
                .onAppear {
                    scrollToActivePart(using: proxy)
                }
                .onChange(of: activeCID) { _, _ in
                    scrollToActivePart(using: proxy)
                }
            }
        }
        .frame(width: 440, height: min(520, CGFloat(pages.count) * 58 + 72))
    }

    private func scrollToActivePart(using proxy: ScrollViewProxy) {
        guard activeCID > 0 else { return }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(activeCID, anchor: .center)
            }
        }
    }
}

private struct VideoPartCollectionRow: View {
    let part: BiliVideoPage
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovered = false

    private var titleColor: Color {
        isSelected ? BiliTheme.pink : .primary
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 10) {
                Text("\(part.page)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(titleColor)
                    .frame(width: 26, height: 20)
                    .background(
                        isSelected ? BiliTheme.pink.opacity(0.12) : Color.black.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(part.title.ifEmpty("未命名分P"))
                        .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(titleColor)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if part.duration > 0 {
                        Text(part.duration.durationText)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .background(
                isHovered ? Color.black.opacity(0.04) : Color.clear,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
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
    var rendersDanmaku = true
    var acceptsKeyboardShortcuts = true
    var onToggleFullscreen: (() -> Void)?

    init(
        model: VideoDetailModel,
        maxWidth: CGFloat,
        maxHeight: CGFloat,
        isFullscreen: Bool = false,
        rendersDanmaku: Bool = true,
        acceptsKeyboardShortcuts: Bool = true,
        onToggleFullscreen: (() -> Void)? = nil
    ) {
        self.model = model
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.isFullscreen = isFullscreen
        self.rendersDanmaku = rendersDanmaku
        self.acceptsKeyboardShortcuts = acceptsKeyboardShortcuts
        self.onToggleFullscreen = onToggleFullscreen
        _player = ObservedObject(wrappedValue: model.player)
    }

    private var fittedSize: CGSize {
        VideoPlayerChrome.fittedSize(
            maxWidth: maxWidth,
            maxHeight: maxHeight,
            aspectRatio: player.displayAspectRatio
        )
    }

    var body: some View {
        ZStack {
            if let playError = model.playError {
                Color.black
                ContentUnavailableView("无法播放", systemImage: "play.slash", description: Text(playError))
                    .foregroundStyle(.white.opacity(0.86))
            } else if !player.isReady {
                Color.black
            } else {
                VideoPlayerSurface(
                    player: player,
                    cornerRadius: isFullscreen ? 0 : VideoPlayerChrome.cornerRadius
                )
                if model.danmakuVisible, !model.danmakuItems.isEmpty, rendersDanmaku {
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
            }
            if model.showDanmakuSettings {
                DanmakuSettingsOverlay(
                    settings: model.danmakuSettings,
                    onSettingsChange: model.updateDanmakuSettings,
                    onDismiss: { model.showDanmakuSettings = false }
                )
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
            VStack {
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
        .frame(width: fittedSize.width, height: fittedSize.height)
        .compositingGroup()
        .clipShape(RoundedRectangle(cornerRadius: isFullscreen ? 0 : VideoPlayerChrome.cornerRadius, style: .continuous))
        .overlay {
            if !isFullscreen {
                RoundedRectangle(cornerRadius: VideoPlayerChrome.cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 0.6)
            }
        }
        .animation(.easeOut(duration: 0.2), value: player.displayAspectRatio)
        .frame(
            width: isFullscreen ? nil : fittedSize.width,
            height: isFullscreen ? nil : fittedSize.height
        )
    }

    private func playbackTimeMs(_ player: VideoPlaybackEngine) -> Double {
        let seconds = player.isScrubbing ? (player.scrubPreviewTime ?? player.preciseCurrentTime) : player.preciseCurrentTime
        return seconds * 1000
    }

    private func syncChromeVisibility() {
        if player.isPlaying {
            chromeState.revealControls()
        } else {
            chromeState.showControlsPersistently()
        }
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
    @ObservedObject private var player: VideoPlaybackEngine
    @StateObject private var chromeState = VideoPlayerChromeState()
    let onClose: () -> Void

    init(model: VideoDetailModel, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
        _player = ObservedObject(wrappedValue: model.player)
    }

    var body: some View {
        ZStack {
            FullscreenPlayerHostView(
                model: model,
                keyboardHandlers: fullscreenKeyboardHandlers
            )

            if model.danmakuVisible, !model.danmakuItems.isEmpty {
                DanmakuOverlayView(
                    items: model.danmakuItems,
                    positionMs: currentPositionMs,
                    isPlaying: player.isPlaying && !player.isScrubbing,
                    enabled: model.danmakuVisible,
                    settings: model.danmakuSettings,
                    layoutMode: .fullscreen,
                    isActive: true,
                    playbackEngine: player
                )
                .allowsHitTesting(false)
                .ignoresSafeArea()
            }

            if model.showDanmakuSettings {
                DanmakuSettingsOverlay(
                    settings: model.danmakuSettings,
                    onSettingsChange: model.updateDanmakuSettings,
                    onDismiss: { model.showDanmakuSettings = false }
                )
            }

            VideoPlayerClickOverlay(
                onSingleClick: {
                    chromeState.revealControls()
                    player.togglePlayback()
                },
                onDoubleClick: {
                    chromeState.revealControls()
                    onClose()
                },
                onActivity: { chromeState.revealControls() }
            )

            VStack {
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
                    .padding(.bottom, 32)
                }
            }
            .animation(.easeInOut(duration: 0.28), value: chromeState.showsControls)
        }
        .onAppear {
            syncChromeVisibility()
        }
        .onChange(of: player.isPlaying) { _, _ in
            syncChromeVisibility()
        }
        .background(Color.black)
        .ignoresSafeArea()
    }

    private var currentPositionMs: Int64 {
        let seconds = player.isScrubbing ? (player.scrubPreviewTime ?? player.preciseCurrentTime) : player.preciseCurrentTime
        return Int64((seconds * 1000).rounded())
    }

    private func syncChromeVisibility() {
        if player.isPlaying {
            chromeState.revealControls()
        } else {
            chromeState.showControlsPersistently()
        }
    }

    private var fullscreenKeyboardHandlers: VideoPlayerKeyboardHandlers {
        VideoPlayerKeyboardHandlers(
            isFullscreen: true,
            shouldHandle: {
                guard !model.showDanmakuSettings else { return false }
                return VideoPlayerKeyboardRouting.shouldHandleInVideoDetail()
            },
            onInteraction: { chromeState.revealControls() },
            onTogglePlayback: { player.togglePlayback() },
            onSeekBackward: { player.seek(by: -5) },
            onSeekForward: { player.seek(by: 5) },
            onVolumeUp: { SystemAudioVolume.adjust(by: 0.1) },
            onVolumeDown: { SystemAudioVolume.adjust(by: -0.1) },
            onToggleFullscreen: onClose,
            onExitFullscreen: onClose,
            onToggleMute: { player.toggleMute() },
            onToggleDanmaku: { model.toggleDanmakuVisible() }
        )
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
    static let capsuleHeight: CGFloat = 44
    static let horizontalPadding: CGFloat = 12
    static let verticalPadding: CGFloat = 10
    static let itemSpacing: CGFloat = 8
    static let timeFontSize: CGFloat = 13
    static let timeMinWidth: CGFloat = 42
    static let playIconSize: CGFloat = 16
    static let playButtonSize: CGFloat = 30
    static let danmakuFontSize: CGFloat = 15
    static let danmakuButtonSize: CGFloat = 32
    static let progressLineWidth: CGFloat = 3
    static let chromeHitTestClearance: CGFloat = 60
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
                    .font(.system(size: VideoControlLayout.timeFontSize, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(minWidth: VideoControlLayout.timeMinWidth, alignment: .leading)
                    .allowsHitTesting(false)

                Button(action: {
                    onInteraction()
                    player.togglePlayback()
                }) {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: VideoControlLayout.playIconSize, weight: .bold))
                        .foregroundStyle(.white)
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

                Text(formatTime(max(0, player.duration - positionTime)))
                    .font(.system(size: VideoControlLayout.timeFontSize, weight: .medium))
                    .foregroundStyle(.white.opacity(0.82))
                    .frame(minWidth: VideoControlLayout.timeMinWidth, alignment: .trailing)
                    .allowsHitTesting(false)
            }
            .padding(.horizontal, VideoControlLayout.horizontalPadding)
            .padding(.vertical, VideoControlLayout.verticalPadding)
        }
        .frame(height: VideoControlLayout.capsuleHeight)
        .clipShape(Capsule())
        .overlay {
            Capsule()
                .stroke(BiliTheme.videoControlBorder, lineWidth: 0.5)
        }
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

private struct VideoControlCapsuleProgress: View {
    let progress: Double

    var body: some View {
        GeometryReader { proxy in
            let clamped = min(1, max(0, progress))
            if clamped > 0 {
                let lineWidth = VideoControlLayout.progressLineWidth
                let offset = min(
                    max(0, proxy.size.width * clamped - lineWidth),
                    max(0, proxy.size.width - lineWidth)
                )
                Capsule()
                    .fill(BiliTheme.pink)
                    .frame(width: lineWidth)
                    .offset(x: offset)
            }
        }
    }
}

private struct DanmakuToggleButton: View {
    let visible: Bool
    let onTap: () -> Void
    let onRightClick: () -> Void

    var body: some View {
        Text("弹")
            .font(.system(size: VideoControlLayout.danmakuFontSize, weight: visible ? .bold : .regular))
            .foregroundStyle(.white.opacity(visible ? 1 : 0.42))
            .frame(
                minWidth: VideoControlLayout.danmakuButtonSize,
                minHeight: VideoControlLayout.danmakuButtonSize
            )
            .contentShape(Rectangle())
            .overlay {
                DanmakuToggleClickView(onTap: onTap, onRightClick: onRightClick)
            }
    }
}

private struct DanmakuToggleClickView: NSViewRepresentable {
    let onTap: () -> Void
    let onRightClick: () -> Void

    func makeNSView(context: Context) -> DanmakuToggleClickNSView {
        let view = DanmakuToggleClickNSView()
        view.onTap = onTap
        view.onRightClick = onRightClick
        return view
    }

    func updateNSView(_ nsView: DanmakuToggleClickNSView, context: Context) {
        nsView.onTap = onTap
        nsView.onRightClick = onRightClick
    }
}

private final class DanmakuToggleClickNSView: NSView {
    var onTap: (() -> Void)?
    var onRightClick: (() -> Void)?

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
        LazyVStack(alignment: .leading, spacing: 4) {
            ForEach(model.comments) { comment in
                CommentRow(comment: comment, nested: false)
                ForEach(comment.loadedReplies) { reply in
                    CommentRow(comment: reply, nested: true)
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
                            .padding(.bottom, 6)
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

private struct CommentRow: View {
    let comment: BiliCommentItem
    let nested: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if nested {
                Spacer().frame(width: 16)
            }

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

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(comment.authorName.ifEmpty("用户"))
                        .font(.system(size: nested ? 14 : 15, weight: .semibold))
                        .foregroundStyle(Color(red: 0.14, green: 0.14, blue: 0.16))
                        .lineLimit(1)

                    if comment.level > 0 {
                        BiliUserLevelIcon(level: comment.level, width: 22, height: 14)
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

                commentMetaRow
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, nested ? 8 : 12)
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


