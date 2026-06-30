import AVKit
import Combine
import SwiftUI

@MainActor
final class VideoDetailModel: ObservableObject {
    let seedVideo: BiliVideo
    private let api = BilibiliAPI()
    private let credential: BilibiliCredential?

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

    @Published var danmakuItems: [BiliDanmakuItem] = []
    @Published var danmakuVisible = DanmakuPlayerPreferences.isDanmakuVisible()
    @Published var danmakuSettings = DanmakuPlayerPreferences.readDanmakuSettings()
    @Published var showDanmakuSettings = false

    init(video: BiliVideo, credential: BilibiliCredential?) {
        self.seedVideo = video
        self.credential = credential
        self.activeCID = video.cid
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
            await loadPlayback()
            await scheduleInitialCommentsLoad()
        } catch {
            detailError = error.localizedDescription
        }
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
            await loadDanmaku(cid: cid)
        } catch {
            playError = error.localizedDescription
        }
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
        player.stop()
        loadedCommentsKey = nil
        commentsLoadInFlight = false
    }
}

struct VideoDetailView: View {
    @StateObject private var model: VideoDetailModel

    init(video: BiliVideo, credential: BilibiliCredential?) {
        _model = StateObject(wrappedValue: VideoDetailModel(video: video, credential: credential))
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .top, spacing: 28) {
                playerSection
                    .frame(width: playerWidth(in: geometry.size.width))

                rightColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(.top, AppLayout.floatingChromeReservedHeight)
            .padding(.horizontal, AppLayout.pageHorizontalInset)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color.white)
        .navigationBarBackButtonHidden(true)
        .task { await model.load() }
        .onDisappear { model.cleanup() }
    }

    private func playerWidth(in totalWidth: CGFloat) -> CGFloat {
        let horizontalPadding = AppLayout.pageHorizontalInset * 2
        let columnSpacing: CGFloat = 28
        let minRightColumn: CGFloat = 320
        let available = max(totalWidth - horizontalPadding - columnSpacing, 0)
        let maxPlayerWidth = max(available - minRightColumn, 280)
        let preferred = available * 0.58
        return min(max(preferred, 400), maxPlayerWidth)
    }

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            introSection

            Divider()
                .padding(.vertical, 12)

            commentsHeader

            ScrollView {
                VideoCommentsPanel(model: model)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var introSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let error = model.detailError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }

            authorRow
            titleBlock
            statsRow
            descriptionBlock
            VideoDetailActionBar(
                likeCount: model.displayVideo.likeCount,
                coinCount: model.detail?.coinCount ?? 0,
                favoriteCount: model.detail?.favoriteCount ?? 0,
                shareCount: model.detail?.shareCount ?? 0
            )

            if let pages = model.detail?.pages, !pages.isEmpty {
                partsSection(pages)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var commentsHeader: some View {
        HStack {
            Text("评论 \(commentCountLabel)")
                .font(.headline)
            Spacer()
            Button {
                Task { await model.toggleCommentSort() }
            } label: {
                Label(model.commentSort.title, systemImage: "arrow.up.arrow.down")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.bottom, 10)
    }

    private var playerSection: some View {
        VideoPlayerSection(model: model)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 0.6)
            }
            .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 10)
            .frame(maxHeight: .infinity, alignment: .top)
    }

    private var authorRow: some View {
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
            .frame(width: 44, height: 44)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayVideo.authorName.ifEmpty("未知 UP 主"))
                    .font(.headline)
                Text("UP 主")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var titleBlock: some View {
        Text(model.displayVideo.title)
            .font(.title2.weight(.bold))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var statsRow: some View {
        HStack(spacing: 18) {
            BiliStatLabel(icon: .play, value: model.displayVideo.viewCount.compactCount)
            BiliStatLabel(icon: .danmaku, value: model.displayVideo.danmakuCount.compactCount)
            if let publishTime = model.detail?.publishTime {
                Text(publishTime.formatted(date: .abbreviated, time: .omitted))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var descriptionBlock: some View {
        let text = model.displayVideo.description.ifEmpty("这个视频还没有写简介")
        return ScrollView {
            Text(text)
                .font(.body)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 140)
    }

    private func partsSection(_ pages: [BiliVideoPage]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("分 P 列表")
                .font(.headline)
            ForEach(pages) { part in
                Button {
                    Task { await model.selectPart(part) }
                } label: {
                    HStack {
                        Text("P\(part.page) \(part.title.ifEmpty("未命名分P"))")
                            .font(.callout)
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

    init(model: VideoDetailModel) {
        self.model = model
        _player = ObservedObject(wrappedValue: model.player)
    }

    var body: some View {
        ZStack {
            Color.black
            if let playError = model.playError {
                ContentUnavailableView("无法播放", systemImage: "play.slash", description: Text(playError))
                    .foregroundStyle(.white.opacity(0.86))
            } else {
                VideoPlayerSurface(player: player)
                if model.danmakuVisible, !model.danmakuItems.isEmpty {
                    DanmakuOverlayView(
                        items: model.danmakuItems,
                        positionMs: Int64((player.currentTime * 1000).rounded()),
                        isPlaying: player.isPlaying && !player.isScrubbing,
                        enabled: model.danmakuVisible,
                        settings: model.danmakuSettings,
                        bottomReserve: 46
                    )
                }
            }
            if model.showDanmakuSettings {
                DanmakuSettingsOverlay(
                    settings: model.danmakuSettings,
                    onSettingsChange: model.updateDanmakuSettings,
                    onDismiss: { model.showDanmakuSettings = false }
                )
            }
            VStack {
                Spacer()
                if !model.showDanmakuSettings {
                    VideoControlCapsule(
                        player: player,
                        danmakuVisible: model.danmakuVisible,
                        onDanmakuToggle: model.toggleDanmakuVisible,
                        onDanmakuLongPress: { model.showDanmakuSettings = true }
                    )
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
            }
        }
    }
}

private struct VideoPlayerSurface: NSViewRepresentable {
    @ObservedObject var player: VideoPlaybackEngine

    func makeNSView(context: Context) -> NonSeekingPlayerView {
        let view = NonSeekingPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player.avPlayer
        return view
    }

    func updateNSView(_ nsView: NonSeekingPlayerView, context: Context) {
        _ = player.isReady
        nsView.player = player.avPlayer
    }
}

private final class NonSeekingPlayerView: AVPlayerView {
    override func scrollWheel(with event: NSEvent) {
        enclosingScrollView?.scrollWheel(with: event)
    }
}

private struct VideoControlCapsule: View {
    @ObservedObject var player: VideoPlaybackEngine
    let danmakuVisible: Bool
    let onDanmakuToggle: () -> Void
    let onDanmakuLongPress: () -> Void

    @State private var dragProgress: Double?
    @State private var displayedProgress: Double = 0

    private var progress: Double {
        if let dragProgress { return dragProgress }
        guard player.duration > 0 else { return 0 }
        let time = player.isScrubbing ? (player.scrubPreviewTime ?? player.currentTime) : player.currentTime
        return min(1, max(0, time / player.duration))
    }

    private var positionTime: Double {
        player.isScrubbing ? (player.scrubPreviewTime ?? player.currentTime) : player.currentTime
    }

    var body: some View {
        GlassEffectContainer {
            ZStack {
                VideoControlCapsuleProgress(progress: displayedProgress)
                HStack(spacing: 6) {
                    Text(formatTime(positionTime))
                        .font(.system(size: 12))
                        .foregroundStyle(.white)
                        .frame(minWidth: 36, alignment: .leading)

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
                        onLongPress: onDanmakuLongPress
                    )

                    GeometryReader { proxy in
                        Color.clear
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        let fraction = min(1, max(0, value.location.x / max(proxy.size.width, 1)))
                                        let target = fraction * max(player.duration, 0)
                                        if dragProgress == nil {
                                            player.beginScrub(at: target)
                                        } else {
                                            player.updateScrubPreview(target)
                                        }
                                        dragProgress = fraction
                                    }
                                    .onEnded { value in
                                        let fraction = min(1, max(0, value.location.x / max(proxy.size.width, 1)))
                                        let target = fraction * max(player.duration, 0)
                                        player.endScrub(at: target)
                                        dragProgress = nil
                                    }
                            )
                    }

                    Text(formatTime(max(0, player.duration - positionTime)))
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.82))
                        .frame(minWidth: 36, alignment: .trailing)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
            }
            .frame(height: 34)
            .glassEffect(.regular.interactive(), in: .capsule)
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
    let onLongPress: () -> Void

    @State private var suppressNextTap = false

    var body: some View {
        Text("弹")
            .font(.system(size: 14, weight: visible ? .bold : .regular))
            .foregroundStyle(.white.opacity(visible ? 1 : 0.42))
            .frame(minWidth: 28, minHeight: 28)
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 0.45) {
                suppressNextTap = true
                onLongPress()
            }
            .onTapGesture {
                guard !suppressNextTap else {
                    suppressNextTap = false
                    return
                }
                onTap()
            }
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
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(BiliTheme.blue)
                                .padding(.leading, 56)
                                .padding(.vertical, 8)
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
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CommentRow: View {
    let comment: BiliCommentItem
    let nested: Bool

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
            .frame(width: nested ? 30 : 38, height: nested ? 30 : 38)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(comment.authorName.ifEmpty("用户"))
                        .font(.callout.weight(.semibold))
                    if comment.level > 0 {
                        BiliUserLevelIcon(level: comment.level)
                    }
                    Spacer()
                }

                if !comment.content.isEmpty {
                    BiliCommentText(text: comment.content, emoticons: comment.emoticons)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(
                    BiliCommentFormats.metaLine(
                        time: comment.publishTime,
                        ipLocation: comment.ipLocation,
                        likeCount: comment.likeCount
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary.opacity(0.58))

                if comment.replyCount > 0, !nested {
                    Label(comment.replyCount.compactCount, systemImage: "bubble.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 12)
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
