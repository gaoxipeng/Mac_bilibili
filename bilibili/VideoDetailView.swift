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

    let player = VideoPlaybackEngine()
    private var commentsCursor: String?
    private var loadedCommentsKey: String?
    private var commentsLoadInFlight = false
    private var danmakuCache: [Int64: [BiliDanmakuItem]] = [:]
    private let watchHistoryReporter = WatchHistoryReporter()
    private var watchHistoryTask: Task<Void, Never>?
    private let initialProgressSeconds: Int
    private var hasAppliedInitialProgress = false

    @Published var danmakuItems: [BiliDanmakuItem] = []
    @Published var danmakuVisible = DanmakuPlayerPreferences.isDanmakuVisible()
    @Published var danmakuSettings = DanmakuPlayerPreferences.readDanmakuSettings()
    @Published var showDanmakuSettings = false

    @Published var videoRelation = BiliVideoRelation()
    @Published var videoActionLoading = false
    @Published var actionMessage: String?
    @Published var needsLoginPrompt = false

    init(video: BiliVideo, credential: BilibiliCredential?, initialProgressSeconds: Int = 0) {
        self.seedVideo = video
        self.credential = credential
        self.activeCID = video.cid
        self.initialProgressSeconds = max(0, initialProgressSeconds)
    }

    var displayVideo: BiliVideo {
        detail?.video ?? seedVideo
    }

    func load() async {
        isLoadingDetail = true
        detailError = nil
        defer { isLoadingDetail = false }

        do {
            let loaded = try await api.videoDetail(bvid: seedVideo.bvid, credential: credential)
            detail = loaded
            if activeCID <= 0 {
                activeCID = loaded.video.cid
            }
            await loadVideoRelation()
            await loadPlayback()
            await scheduleInitialCommentsLoad()
        } catch {
            detailError = error.localizedDescription
        }
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
            actionMessage = error.localizedDescription
        }
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

    func selectPart(_ part: BiliVideoPage) async {
        guard part.cid != activeCID else { return }
        activeCID = part.cid
        await loadPlayback()
    }

    func loadPlayback() async {
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
            stream = BiliPlayStream(
                videoURL: stream.videoURL,
                audioURL: stream.audioURL,
                aid: displayVideo.aid,
                cid: cid
            )
            let cookieHeader = await api.httpCookieHeader(credential: credential)
            try await player.load(stream: stream, cookieHeader: cookieHeader)
            applyInitialProgressIfNeeded()
            startWatchHistoryReporting(aid: displayVideo.aid, cid: cid)
            await loadDanmaku(cid: cid)
        } catch {
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

    func cleanup() {
        stopWatchHistoryReporting()
        player.stop()
        danmakuItems = []
        danmakuCache.removeAll()
        comments = []
        loadedCommentsKey = nil
        commentsLoadInFlight = false
    }
}

struct VideoDetailChromeInfo: Equatable {
    let title: String
    let viewCount: Int64
    let danmakuCount: Int64
    let publishTime: Date?
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
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            HStack(spacing: 16) {
                BiliStatLabel(icon: .play, value: info.viewCount.compactCount, iconSize: 20)
                BiliStatLabel(icon: .danmaku, value: info.danmakuCount.compactCount, iconSize: 20)
                if let publishTime = info.publishTime {
                    Text(publishTime.numericDateString)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct VideoDetailView: View {
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
    @State private var coinMenuPresented = false
    @State private var coinIconFrame: CGRect = .zero
    @State private var coinMenuHeight: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .top, spacing: 28) {
                playerSection(
                    maxWidth: playerWidth(in: geometry.size.width),
                    maxHeight: playerMaxHeight(in: geometry)
                )
                .padding(.top, AppLayout.videoDetailChromeReservedHeight)
                .opacity(fullscreenPresenter.isPresented ? 0 : 1)
                .allowsHitTesting(!fullscreenPresenter.isPresented)

                rightColumn
                    .padding(.top, AppLayout.videoDetailRightColumnTopInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(.horizontal, AppLayout.pageHorizontalInset)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color.white)
        .navigationBarBackButtonHidden(true)
        .background {
            Color.clear
                .preference(key: VideoDetailChromePreferenceKey.self, value: detailChromeInfo)
        }
        .task { await model.load() }
        .onDisappear {
            fullscreenPresenter.dismissImmediately()
            model.cleanup()
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

    private func playerMaxHeight(in geometry: GeometryProxy) -> CGFloat {
        let verticalInsets = AppLayout.videoDetailChromeReservedHeight + 24
        return max(240, geometry.size.height - verticalInsets)
    }

    private func playerWidth(in totalWidth: CGFloat) -> CGFloat {
        let horizontalPadding = AppLayout.pageHorizontalInset * 2
        let columnSpacing: CGFloat = 28
        let minRightColumn: CGFloat = 300
        let available = max(totalWidth - horizontalPadding - columnSpacing, 0)
        let maxPlayerWidth = max(available - minRightColumn, 280)
        let preferred = available * 0.66
        return min(max(preferred, 400), maxPlayerWidth)
    }

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            introSection

            Divider()
                .padding(.vertical, 8)

            commentsHeader

            ScrollView {
                VideoCommentsPanel(model: model)
            }
            .padding(.trailing, -AppLayout.pageHorizontalInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .coordinateSpace(name: "detailPane")
        .overlay {
            if coinMenuPresented {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { coinMenuPresented = false }

                VideoCoinChoiceMenu(
                    canCoinTwo: model.videoRelation.coinCount == 0,
                    onCoinOne: {
                        coinMenuPresented = false
                        Task { await model.coin(multiply: 1) }
                    },
                    onCoinTwo: {
                        coinMenuPresented = false
                        Task { await model.coin(multiply: 2) }
                    }
                )
                .background {
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { coinMenuHeight = geo.size.height }
                            .onChange(of: geo.size.height) { _, height in
                                coinMenuHeight = height
                            }
                    }
                }
                .fixedSize()
                .position(
                    x: coinIconFrame.midX,
                    y: coinIconFrame.maxY + max(coinMenuHeight, 48) / 2 + 6
                )
            }
        }
        .onPreferenceChange(CoinIconFrameKey.self) { frame in
            coinIconFrame = frame
        }
    }

    private var introSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = model.detailError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }

            authorRow
            descriptionBlock
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
                coinMenuPresented: $coinMenuPresented,
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
                onFavoriteClick: {
                    Task { await model.toggleFavorite() }
                },
                onShareClick: { context in
                    Task { await model.share(from: context) }
                }
            )

            if let pages = model.detail?.pages, !pages.isEmpty {
                partsSection(pages)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, AppLayout.videoDetailRightColumnTrailingInset)
    }

    private var commentsHeader: some View {
        HStack {
            Text("评论 \(commentCountLabel)")
                .font(.system(size: 17, weight: .semibold))
            Spacer()
            BiliCommentSortToggle(sort: model.commentSort) {
                Task { await model.toggleCommentSort() }
            }
        }
        .padding(.bottom, 10)
        .padding(.trailing, AppLayout.videoDetailRightColumnTrailingInset)
    }

    private func playerSection(maxWidth: CGFloat, maxHeight: CGFloat) -> some View {
        VideoPlayerSection(
            model: model,
            maxWidth: maxWidth,
            maxHeight: maxHeight,
            rendersDanmaku: !fullscreenPresenter.isPresented,
            onToggleFullscreen: enterFullscreen
        )
        .background {
            PlayerScreenFrameReader { frame in
                playerScreenFrame = frame
            }
        }
        .frame(maxHeight: .infinity, alignment: .center)
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
        HStack(spacing: 12) {
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

            VStack(alignment: .leading, spacing: 4) {
                Text(model.displayVideo.authorName.ifEmpty("未知 UP 主"))
                    .font(.system(size: 18, weight: .semibold))
                Text("UP 主")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var detailChromeInfo: VideoDetailChromeInfo {
        VideoDetailChromeInfo(
            title: model.displayVideo.title,
            viewCount: model.displayVideo.viewCount,
            danmakuCount: model.displayVideo.danmakuCount,
            publishTime: model.detail?.publishTime
        )
    }

    private var descriptionBlock: some View {
        let text = model.displayVideo.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayText = text.isEmpty ? "这个视频还没有写简介" : text
        return Text(displayText)
            .font(.system(size: 16))
            .foregroundStyle(text.isEmpty ? .secondary : .primary)
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    private func partsSection(_ pages: [BiliVideoPage]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("分 P 列表")
                .font(.system(size: 17, weight: .semibold))
            ForEach(pages) { part in
                Button {
                    Task { await model.selectPart(part) }
                } label: {
                    HStack {
                        Text("P\(part.page) \(part.title.ifEmpty("未命名分P"))")
                            .font(.system(size: 15))
                            .lineLimit(1)
                        Spacer()
                        if part.cid == model.activeCID {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(BiliTheme.blue)
                        } else if part.duration > 0 {
                            Text(part.duration.durationText)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .background(part.cid == model.activeCID ? BiliTheme.blue.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                .materialPanel()
            }
        }
    }

    private var commentCountLabel: String {
        let count = model.detail?.replyCount ?? 0
        return count > 0 ? count.compactCount : ""
    }
}

private struct VideoPlayerSection: View {
    @ObservedObject var model: VideoDetailModel
    @ObservedObject private var player: VideoPlaybackEngine
    let maxWidth: CGFloat
    let maxHeight: CGFloat
    var isFullscreen = false
    var rendersDanmaku = true
    var onToggleFullscreen: (() -> Void)?

    init(
        model: VideoDetailModel,
        maxWidth: CGFloat,
        maxHeight: CGFloat,
        isFullscreen: Bool = false,
        rendersDanmaku: Bool = true,
        onToggleFullscreen: (() -> Void)? = nil
    ) {
        self.model = model
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.isFullscreen = isFullscreen
        self.rendersDanmaku = rendersDanmaku
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
                        isActive: rendersDanmaku
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
                onSingleClick: { player.togglePlayback() },
                onDoubleClick: { onToggleFullscreen?() }
            )
            VStack {
                Spacer()
                if !model.showDanmakuSettings {
                    VideoControlCapsule(
                        player: player,
                        danmakuVisible: model.danmakuVisible,
                        onDanmakuToggle: model.toggleDanmakuVisible,
                        onDanmakuRightClick: { model.showDanmakuSettings = true }
                    )
                    .padding(.horizontal, 16)
                    .padding(.bottom, isFullscreen ? 28 : 24)
                }
            }
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
        .shadow(color: .black.opacity(isFullscreen ? 0 : 0.18), radius: 18, x: 0, y: 10)
        .animation(.easeOut(duration: 0.2), value: player.displayAspectRatio)
        .frame(maxWidth: isFullscreen ? .infinity : nil, maxHeight: isFullscreen ? .infinity : nil)
    }

    private func playbackTimeMs(_ player: VideoPlaybackEngine) -> Double {
        let seconds = player.isScrubbing ? (player.scrubPreviewTime ?? player.preciseCurrentTime) : player.preciseCurrentTime
        return seconds * 1000
    }
}

private struct VideoPlayerFullscreenContent: View {
    @ObservedObject var model: VideoDetailModel
    @ObservedObject private var player: VideoPlaybackEngine
    let onClose: () -> Void

    init(model: VideoDetailModel, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
        _player = ObservedObject(wrappedValue: model.player)
    }

    var body: some View {
        ZStack {
            FullscreenPlayerHostView(model: model)

            if model.danmakuVisible, !model.danmakuItems.isEmpty {
                DanmakuOverlayView(
                    items: model.danmakuItems,
                    positionMs: currentPositionMs,
                    isPlaying: player.isPlaying && !player.isScrubbing,
                    enabled: model.danmakuVisible,
                    settings: model.danmakuSettings,
                    layoutMode: .fullscreen,
                    isActive: true
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
                onSingleClick: { player.togglePlayback() },
                onDoubleClick: onClose
            )

            VStack {
                HStack {
                    Button(action: onClose) {
                        Text("关闭")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.white.opacity(0.14), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)

                Spacer()

                if !model.showDanmakuSettings {
                    VideoControlCapsule(
                        player: player,
                        danmakuVisible: model.danmakuVisible,
                        onDanmakuToggle: model.toggleDanmakuVisible,
                        onDanmakuRightClick: { model.showDanmakuSettings = true }
                    )
                    .padding(.horizontal, 16)
                    .padding(.bottom, 28)
                }
            }
        }
        .background(Color.black)
        .ignoresSafeArea()
    }

    private var currentPositionMs: Int64 {
        let seconds = player.isScrubbing ? (player.scrubPreviewTime ?? player.preciseCurrentTime) : player.preciseCurrentTime
        return Int64((seconds * 1000).rounded())
    }
}

private struct VideoPlayerClickOverlay: NSViewRepresentable {
    let onSingleClick: () -> Void
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> VideoPlayerClickView {
        let view = VideoPlayerClickView()
        view.onSingleClick = onSingleClick
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ nsView: VideoPlayerClickView, context: Context) {
        nsView.onSingleClick = onSingleClick
        nsView.onDoubleClick = onDoubleClick
    }
}

private final class VideoPlayerClickView: NSView {
    var onSingleClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    private var singleClickWorkItem: DispatchWorkItem?

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        if point.y <= 52 {
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
}

private struct VideoControlCapsule: View {
    @ObservedObject var player: VideoPlaybackEngine
    let danmakuVisible: Bool
    let onDanmakuToggle: () -> Void
    let onDanmakuRightClick: () -> Void

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

            HStack(spacing: 6) {
                Text(formatTime(positionTime))
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .frame(minWidth: 36, alignment: .leading)
                    .allowsHitTesting(false)

                Button(action: player.togglePlayback) {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 25, height: 25)
                }
                .buttonStyle(.plain)

                DanmakuToggleButton(
                    visible: danmakuVisible,
                    onTap: onDanmakuToggle,
                    onRightClick: onDanmakuRightClick
                )

                Spacer(minLength: 0)
                    .allowsHitTesting(false)

                Text(formatTime(max(0, player.duration - positionTime)))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.82))
                    .frame(minWidth: 36, alignment: .trailing)
                    .allowsHitTesting(false)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
        }
        .frame(height: 34)
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
    }

    private func scrubGesture(totalWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
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
                let lineWidth: CGFloat = 2.5
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
            .font(.system(size: 14, weight: visible ? .bold : .regular))
            .foregroundStyle(.white.opacity(visible ? 1 : 0.42))
            .frame(minWidth: 28, minHeight: 28)
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

private struct VideoCommentsPanel: View {
    @ObservedObject var model: VideoDetailModel

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            if model.commentsLoading, model.comments.isEmpty {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("正在加载评论")
                        .foregroundStyle(.secondary)
                }
                .padding(24)
            } else if let error = model.commentsError, model.comments.isEmpty {
                ContentUnavailableView("评论加载失败", systemImage: "bubble.left.and.exclamationmark", description: Text(error))
                    .padding(32)
            } else if model.comments.isEmpty {
                ContentUnavailableView("还没有评论", systemImage: "bubble.left")
                    .padding(32)
            } else {
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
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(BiliTheme.blue)
                                .padding(.leading, 56)
                                .padding(.top, 2)
                                .padding(.bottom, 4)
                        }
                        .buttonStyle(.plain)
                    }
                    Divider().padding(.leading, 20)
                }

                if model.commentsLoadingMore && !model.comments.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在加载更多")
                            .foregroundStyle(.secondary)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity)
                } else if !model.commentsEnd, !model.comments.isEmpty, !model.commentsLoading, !model.commentsLoadingMore {
                    Color.clear
                        .frame(height: 1)
                        .onAppear {
                            Task { await model.loadComments(reset: false) }
                        }
                }
            }
        }
        .padding(.trailing, AppLayout.videoDetailRightColumnTrailingInset)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CommentRow: View {
    let comment: BiliCommentItem
    let nested: Bool

    private let authorFontSize: CGFloat = 15
    private let bodyFontSize: CGFloat = 15
    private let metaFontSize: CGFloat = 12

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if nested {
                Spacer().frame(width: 24)
            }
            AsyncImage(url: comment.authorFaceURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    Image(systemName: "person.fill")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: nested ? 32 : 40, height: nested ? 32 : 40)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 3) {
                    Text(comment.authorName.ifEmpty("用户"))
                        .font(.system(size: authorFontSize, weight: .semibold))
                        .lineLimit(1)
                    if comment.level > 0 {
                        BiliUserLevelIcon(level: comment.level, width: 30, height: 19)
                    }
                }

                Text(
                    BiliCommentFormats.metaLine(
                        time: comment.publishTime,
                        ipLocation: comment.ipLocation,
                        likeCount: comment.likeCount
                    )
                )
                .font(.system(size: metaFontSize))
                .foregroundStyle(.secondary.opacity(0.58))
                .padding(.top, 2)

                if !comment.content.isEmpty {
                    BiliCommentText(
                        text: comment.content,
                        emoticons: comment.emoticons,
                        fontSize: bodyFontSize
                    )
                    .padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 7)
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






