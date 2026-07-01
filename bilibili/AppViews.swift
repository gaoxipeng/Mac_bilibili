import SwiftUI

enum VideoCardLayout {
    static let minWidth: CGFloat = 288
    static let gridSpacing: CGFloat = 14
    static let coverAspect: CGFloat = 16.0 / 9.0
    static let cornerRadius: CGFloat = 10
    static let cardBorderColor = Color(red: 232 / 255, green: 232 / 255, blue: 232 / 255)
    static let coverHoverScale: CGFloat = 1.035
    static let coverHoverAnimation = Animation.interactiveSpring(response: 0.18, dampingFraction: 0.82, blendDuration: 0.04)
    static let coverHoverExitAnimation = Animation.easeOut(duration: 0.14)
    static let metadataSpacing: CGFloat = 8
    static let metadataPadding = EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
    /// Feed 封面解码目标像素，避免滚动时为每个 cell 做 GeometryReader 测量。
    static func feedCoverPixelLength(displayScale: CGFloat) -> Int {
        Int((minWidth * max(1, displayScale) * 1.05).rounded(.up))
    }

    static let gridColumns = [
        GridItem(.adaptive(minimum: minWidth), spacing: gridSpacing, alignment: .top)
    ]
}

struct VideoFeedGrid<Trailing: View>: View {
    let videos: [BiliVideo]
    var largeTypography = false
    var onVideoAppear: ((BiliVideo) -> Void)? = nil
    @ViewBuilder var trailing: () -> Trailing

    init(
        videos: [BiliVideo],
        largeTypography: Bool = false,
        onVideoAppear: ((BiliVideo) -> Void)? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.videos = videos
        self.largeTypography = largeTypography
        self.onVideoAppear = onVideoAppear
        self.trailing = trailing
    }

    var body: some View {
        LazyVGrid(
            columns: VideoCardLayout.gridColumns,
            alignment: .leading,
            spacing: VideoCardLayout.gridSpacing
        ) {
            videoItems
            trailing()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var videoItems: some View {
        ForEach(videos) { video in
            FeedVideoCard(video: video, largeTypography: largeTypography)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: nil,
                    alignment: .top
                )
                .onAppear { onVideoAppear?(video) }
        }
    }
}

private struct FeedVideoCard: View {
    let video: BiliVideo
    let largeTypography: Bool

    var body: some View {
        VideoCard(video: video, largeTypography: largeTypography)
    }
}

struct FollowingView: View {
    let videos: [BiliVideo]
    let loading: Bool
    let loadingMore: Bool
    let hasMore: Bool
    let error: String?
    let loggedIn: Bool
    let onLoadMore: () -> Void

    var body: some View {
        AppScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                PageHeader(
                    title: "关注",
                    subtitle: loggedIn ? "你关注的 UP 主更新" : "登录后查看关注 UP 的最新视频",
                    largeTypography: true
                )

                if !loggedIn {
                    ContentUnavailableView(
                        "登录后查看关注内容",
                        systemImage: "person.2",
                        description: Text("在「我的」页面完成登录，即可同步关注动态")
                    )
                    .padding(.vertical, 40)
                    .frame(maxWidth: .infinity)
                    .materialPanel()
                } else {
                    StateBanner(
                        loading: loading,
                        error: error,
                        isEmpty: videos.isEmpty,
                        emptyTitle: "暂无关注视频，先去关注几个 UP 主吧"
                    )

                    VideoFeedGrid(
                        videos: videos,
                        largeTypography: true,
                        onVideoAppear: { video in
                            guard hasMore,
                                  !loadingMore,
                                  shouldPrefetchMore(afterAppearing: video, in: videos) else {
                                return
                            }
                            onLoadMore()
                        },
                        trailing: {
                            if hasMore {
                                loadMoreFooter
                            }
                        }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var loadMoreFooter: some View {
        Group {
            if loadingMore {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在加载更多")
                        .foregroundStyle(.secondary)
                }
            } else {
                Color.clear
                    .frame(height: 1)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

struct FavoritesView: View {
    let videos: [BiliVideo]
    let loading: Bool
    let loadingMore: Bool
    let hasMore: Bool
    let error: String?
    let loggedIn: Bool
    let onLoadMore: () -> Void

    var body: some View {
        AppScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                PageHeader(
                    title: "收藏",
                    subtitle: loggedIn ? "默认收藏夹" : "登录后查看收藏视频",
                    largeTypography: true
                )

                if !loggedIn {
                    ContentUnavailableView(
                        "登录后查看收藏",
                        systemImage: "star",
                        description: Text("在「我的」页面完成登录，即可同步收藏内容")
                    )
                    .padding(.vertical, 40)
                    .frame(maxWidth: .infinity)
                    .materialPanel()
                } else {
                    StateBanner(
                        loading: loading,
                        error: error,
                        isEmpty: videos.isEmpty,
                        emptyTitle: "暂无收藏视频"
                    )

                    VideoFeedGrid(
                        videos: videos,
                        largeTypography: true,
                        onVideoAppear: { video in
                            guard hasMore,
                                  !loadingMore,
                                  shouldPrefetchMore(afterAppearing: video, in: videos) else {
                                return
                            }
                            onLoadMore()
                        },
                        trailing: {
                            if hasMore {
                                loadMoreFooter
                            }
                        }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var loadMoreFooter: some View {
        Group {
            if loadingMore {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在加载更多")
                        .foregroundStyle(.secondary)
                }
            } else {
                Color.clear
                    .frame(height: 1)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

struct VideoGridView: View {
    var title: String? = nil
    var subtitle: String? = nil
    let videos: [BiliVideo]
    let loading: Bool
    let error: String?
    let emptyTitle: String
    var compactHeader = false
    var showsPageHeader = true
    var loadingMore = false
    var hasMore = false
    var onLoadMore: (() -> Void)? = nil

    @State private var loadMoreTask: Task<Void, Never>?

    var body: some View {
        AppScrollView {
            LazyVStack(alignment: .leading, spacing: compactHeader ? 10 : 20) {
                if showsPageHeader, let title, !title.isEmpty {
                    PageHeader(title: title, subtitle: subtitle, compact: compactHeader)
                }
                StateBanner(loading: loading, error: error, isEmpty: videos.isEmpty, emptyTitle: emptyTitle)

                VideoFeedGrid(
                    videos: videos,
                    onVideoAppear: scheduleLoadMoreIfNeeded,
                    trailing: {
                        if hasMore {
                            loadMoreFooter
                        }
                    }
                )
            }
        }
        .onDisappear {
            loadMoreTask?.cancel()
            loadMoreTask = nil
        }
    }

    private func scheduleLoadMoreIfNeeded(_ video: BiliVideo) {
        guard hasMore,
              !loadingMore,
              shouldPrefetchMore(afterAppearing: video, in: videos) else {
            return
        }
        loadMoreTask?.cancel()
        loadMoreTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            onLoadMore?()
        }
    }

    @ViewBuilder
    private var loadMoreFooter: some View {
        Group {
            if loadingMore {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在加载更多")
                        .foregroundStyle(.secondary)
                }
            } else {
                Color.clear
                    .frame(height: 1)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

private func shouldPrefetchMore(afterAppearing video: BiliVideo, in videos: [BiliVideo]) -> Bool {
    guard videos.count > 8 else { return false }
    return videos.suffix(4).contains { $0.bvid == video.bvid }
}

struct LiveRoomGridView: View {
    let rooms: [BiliLiveRoom]
    let loading: Bool
    let error: String?

    private let columns = VideoCardLayout.gridColumns

    var body: some View {
        AppScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "直播", subtitle: "热门直播间")
                StateBanner(loading: loading, error: error, isEmpty: rooms.isEmpty, emptyTitle: "暂时没有直播内容")

                LazyVGrid(columns: columns, alignment: .leading, spacing: VideoCardLayout.gridSpacing) {
                    ForEach(rooms) { room in
                        LiveRoomCard(room: room)
                    }
                }
            }
        }
    }
}

struct HistoryView: View {
    let items: [BiliHistoryItem]
    let loading: Bool
    let error: String?
    let loggedIn: Bool

    var body: some View {
        AppScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "历史", subtitle: "观看记录")
                StateBanner(
                    loading: loading,
                    error: error,
                    isEmpty: items.isEmpty,
                    emptyTitle: loggedIn ? "暂无观看历史" : "登录后查看观看历史"
                )

                ForEach(items) { item in
                    HistoryRow(item: item)
                }
            }
        }
    }
}

struct MineView: View {
    @ObservedObject var model: AppModel
    @State private var showLogin = false
    @StateObject private var webSession = BilibiliWebSession()

    var body: some View {
        AppScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "我的", subtitle: model.account == nil ? "登录后同步个人资料、关注和历史" : "账号与资料")
                if let account = model.account {
                    if let mid = Int64(account.uid), mid > 0 {
                        NavigationLink(
                            value: UserProfileRequest(
                                mid: mid,
                                seedName: account.name,
                                seedFaceURL: account.faceURL
                            )
                        ) {
                            ProfileCard(account: account, profile: model.profile)
                        }
                        .buttonStyle(.plain)
                    } else {
                        ProfileCard(account: account, profile: model.profile)
                    }
                } else {
                    LoginCard {
                        showLogin = true
                    }
                }

                if let message = model.loginMessage {
                    Label(message, systemImage: message.hasPrefix("已") ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(message.hasPrefix("已") ? .green : .orange)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .materialPanel()
                }

                AccountActionGrid(
                    loggedIn: model.account != nil,
                    onFollowing: { model.selectedSection = .following },
                    onHistory: { model.selectedSection = .history },
                    onHome: { model.selectedSection = .home },
                    onLogout: { model.logout() }
                )

            }
        }
        .sheet(isPresented: $showLogin) {
            WebLoginSheet(session: webSession) {
                Task {
                    guard let credential = await webSession.readCredential() else { return }
                    let success = await model.login(credential: credential)
                    if success {
                        showLogin = false
                    }
                }
            }
        }
    }
}

struct PageHeader: View {
    let title: String
    var subtitle: String? = nil
    var largeTypography = false
    var compact = false

    var body: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: compact ? 0 : 6) {
                Text(title)
                    .font(largeTypography ? .system(size: 40, weight: .bold) : .largeTitle.weight(.bold))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(largeTypography ? .body : .callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.bottom, compact ? -4 : 0)
    }
}

struct StateBanner: View {
    let loading: Bool
    let error: String?
    let isEmpty: Bool
    let emptyTitle: String

    var body: some View {
        if loading {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("正在加载")
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .materialPanel()
        } else if let error {
            Label(error, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .materialPanel()
        } else if isEmpty {
            ContentUnavailableView(emptyTitle, systemImage: "tray")
                .padding(40)
                .materialPanel()
        }
    }
}

struct VideoCard: View {
    let video: BiliVideo
    var largeTypography = false
    @State private var isCoverHovered = false

    private var titleFont: Font {
        return largeTypography ? .title2.weight(.semibold) : .title3.weight(.medium)
    }

    private var authorFont: Font {
        largeTypography ? .body : .subheadline
    }

    private var statsFont: Font {
        largeTypography ? .body : .subheadline
    }

    private var avatarSize: CGFloat {
        largeTypography ? 30 : 26
    }

    private var statIconSize: CGFloat {
        largeTypography ? 20 : 18
    }

    private var likeStatIconSize: CGFloat {
        statIconSize - 3
    }

    private var cornerRadius: CGFloat {
        VideoCardLayout.cornerRadius
    }

    var body: some View {
        mosaicCard
        .frame(
            maxWidth: .infinity,
            maxHeight: nil,
            alignment: .top
        )
    }

    private var mosaicCard: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            coverSection
            metadataSection
        }
        .background {
            ZStack {
                shape.fill(Color.white)
                shape.stroke(VideoCardLayout.cardBorderColor, lineWidth: 0.5)
            }
        }
        .shadow(color: .black.opacity(isCoverHovered ? 0.07 : 0), radius: isCoverHovered ? 8 : 0, x: 0, y: isCoverHovered ? 4 : 0)
        .zIndex(isCoverHovered ? 2 : 0)
    }

    private var coverHoverAnimation: Animation {
        isCoverHovered ? VideoCardLayout.coverHoverAnimation : VideoCardLayout.coverHoverExitAnimation
    }

    private var coverSection: some View {
        let coverShape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return NavigationLink(value: VideoPlaybackRequest(video)) {
            ZStack(alignment: .bottomTrailing) {
                RemoteCover(
                    url: video.coverURL,
                    aspectRatio: VideoCardLayout.coverAspect,
                    appliesCornerClip: false,
                    allowsOverflow: true
                )
                .frame(maxWidth: .infinity)
                .clipShape(coverShape)
                .scaleEffect(isCoverHovered ? VideoCardLayout.coverHoverScale : 1)
                .animation(coverHoverAnimation, value: isCoverHovered)

                if video.duration > 0 {
                    Text(video.durationText)
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.68), in: Capsule())
                        .padding(8)
                }
            }
            .contentShape(coverShape)
        }
        .buttonStyle(.plain)
        .videoCoverHover(isHovered: $isCoverHovered)
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: VideoCardLayout.metadataSpacing) {
            NavigationLink(value: VideoPlaybackRequest(video)) {
                VStack(alignment: .leading, spacing: VideoCardLayout.metadataSpacing) {
                    Text(video.title)
                        .font(titleFont)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .fixedSize(horizontal: false, vertical: true)

                    statsRow
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            authorRow
        }
        .padding(VideoCardLayout.metadataPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var authorRow: some View {
        if video.authorMid > 0 {
            NavigationLink(
                value: UserProfileRequest(
                    mid: video.authorMid,
                    seedName: video.authorName,
                    seedFaceURL: video.authorFaceURL
                )
            ) {
                authorRowContent
            }
            .buttonStyle(.plain)
        } else {
            authorRowContent
        }
    }

    private var authorRowContent: some View {
        HStack(spacing: 8) {
            RemoteAvatar(
                url: video.authorFaceURL,
                size: avatarSize,
                foreground: .secondary,
                background: Color.secondary.opacity(0.11),
                border: Color.black.opacity(0.05)
            )

            Text(video.authorName.ifEmpty("未知 UP 主"))
                .font(authorFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var statsRow: some View {
        HStack(spacing: 12) {
            BiliStatLabel(
                icon: .play,
                value: video.viewCount.compactCount,
                iconSize: statIconSize,
                font: statsFont
            )
            BiliStatLabel(
                icon: .danmaku,
                value: video.danmakuCount.compactCount,
                iconSize: statIconSize,
                font: statsFont
            )
            BiliStatLabel(
                icon: .like,
                value: video.likeCount.compactCount,
                iconSize: likeStatIconSize,
                font: statsFont
            )
        }
        .foregroundStyle(.secondary)
    }
}

struct HistoryRow: View {
    let item: BiliHistoryItem

    var body: some View {
        NavigationLink(value: VideoPlaybackRequest(item.video, progressSeconds: item.progressSeconds)) {
            HStack(spacing: 14) {
                ZStack(alignment: .bottomTrailing) {
                    RemoteCover(url: item.video.coverURL, aspectRatio: 16.0 / 9.0)
                        .frame(width: 156)
                    if item.progressSeconds > 0,
                       item.durationSeconds > 0,
                       item.progressSeconds < item.durationSeconds {
                        Text(historyProgressLabel(
                            progressSeconds: item.progressSeconds,
                            durationSeconds: item.durationSeconds
                        ))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .padding(6)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.video.title)
                        .font(.headline)
                        .lineLimit(2)
                    Text(item.video.authorName.ifEmpty("未知 UP 主"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if let viewedAt = item.viewedAt {
                        Text(viewedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
        }
        .buttonStyle(.plain)
        .materialPanel()
    }
}

private func historyProgressLabel(progressSeconds: Int, durationSeconds: Int) -> String {
    "\(formatClockDuration(progressSeconds)) / \(formatClockDuration(durationSeconds))"
}

private func formatClockDuration(_ seconds: Int) -> String {
    let safe = max(0, seconds)
    let hours = safe / 3600
    let minutes = (safe % 3600) / 60
    let remaining = safe % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, remaining)
    }
    return String(format: "%d:%02d", minutes, remaining)
}

struct ProfileCard: View {
    let account: BiliAccount
    let profile: BiliUserProfile?

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            RemoteAvatar(
                url: profile?.faceURL ?? account.faceURL,
                size: 86,
                foreground: .secondary,
                background: Color.secondary.opacity(0.14),
                border: Color.black.opacity(0.06)
            )

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(profile?.name ?? account.name)
                        .font(.title.weight(.bold))
                    if let level = profile?.level, level > 0 {
                        Text("Lv.\(level)")
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.pink.opacity(0.14), in: Capsule())
                            .foregroundStyle(.pink)
                    }
                }

                Text(profile?.sign.isEmpty == false ? profile?.sign ?? "" : "这个人还没有写签名")
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                HStack(spacing: 20) {
                    ProfileMetric(title: "关注", value: profile?.following.compactCount ?? "-")
                    ProfileMetric(title: "粉丝", value: profile?.follower.compactCount ?? "-")
                    ProfileMetric(title: "获赞", value: profile?.likes.compactCount ?? "-")
                    ProfileMetric(title: "硬币", value: profile?.coinCount.compactCount ?? "-")
                    ProfileMetric(title: "B币", value: profile.map { String(format: "%.1f", $0.bcoinBalance) } ?? "-")
                }
                .padding(.top, 4)
            }
            Spacer()
        }
        .padding(20)
        .materialPanel()
    }
}

struct ProfileMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.headline.monospacedDigit())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct LoginCard: View {
    let onLogin: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(.pink)
                VStack(alignment: .leading, spacing: 5) {
                    Text("登录哔哩哔哩")
                        .font(.title2.weight(.bold))
                    Text("在应用内完成登录，即可同步关注、历史、个人资料、硬币和 B 币余额。")
                        .foregroundStyle(.secondary)
                }
            }
            Button(action: onLogin) {
                Label("登录", systemImage: "arrow.right.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.pink)
            .controlSize(.large)
        }
        .padding(20)
        .materialPanel()
    }
}

struct AccountActionGrid: View {
    let loggedIn: Bool
    let onFollowing: () -> Void
    let onHistory: () -> Void
    let onHome: () -> Void
    let onLogout: () -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 14)], spacing: 14) {
            ActionCard(title: "首页推荐", subtitle: "刷新推荐流", symbol: "house", action: onHome)
            ActionCard(title: "关注", subtitle: loggedIn ? "查看关注更新" : "需要登录", symbol: "person.2", action: onFollowing)
            ActionCard(title: "历史", subtitle: loggedIn ? "查看观看记录" : "需要登录", symbol: "clock.arrow.circlepath", action: onHistory)
            if loggedIn {
                ActionCard(title: "退出登录", subtitle: "清除本地账号", symbol: "rectangle.portrait.and.arrow.right", action: onLogout)
            }
        }
    }
}

struct ActionCard: View {
    let title: String
    let subtitle: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.title3.weight(.semibold))
                    .frame(width: 32, height: 32)
                    .foregroundStyle(.pink)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(16)
        }
        .buttonStyle(.plain)
        .materialPanel()
    }
}

struct WebLoginSheet: View {
    @ObservedObject var session: BilibiliWebSession
    let onCompleteLogin: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            BilibiliWebView(webView: session.webView)
                .clipShape(RoundedRectangle(cornerRadius: 0))
        }
        .frame(minWidth: 720, minHeight: 560)
        .background(.regularMaterial)
        .task {
            session.openLogin()
            await session.refreshLoginState()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("哔哩哔哩登录")
                    .font(.title2.weight(.bold))
                Text("在下方页面完成登录。登录成功后点击「完成登录」返回应用。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 10) {
                Button("重新打开") {
                    session.openLogin(forceReload: true)
                }
                .buttonStyle(.bordered)

                if session.hasLoginCookie {
                    Button("完成登录", action: onCompleteLogin)
                        .buttonStyle(.borderedProminent)
                        .tint(.pink)
                } else {
                    Button("关闭") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .background(.ultraThinMaterial)
    }
}

struct LiveRoomCard: View {
    let room: BiliLiveRoom
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            if let url = room.webURL {
                openURL(url)
            }
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                RemoteCover(url: room.coverURL, aspectRatio: 16.0 / 9.0)
                    .overlay(alignment: .topLeading) {
                        Text("LIVE")
                            .font(.caption2.weight(.black))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(.pink, in: Capsule())
                            .foregroundStyle(.white)
                            .padding(8)
                    }

                VStack(alignment: .leading, spacing: 8) {
                    Text(room.title)
                        .font(.headline)
                        .lineLimit(2)
                    Text(room.userName.ifEmpty("主播"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        MetricLabel(systemImage: "person.2", value: room.online.compactCount)
                        if !room.areaName.isEmpty {
                            MetricLabel(systemImage: "tag", value: room.areaName)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding([.horizontal, .bottom], 14)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .materialPanel()
    }
}

struct RemoteCover: View {
    let url: URL?
    let aspectRatio: CGFloat
    var width: CGFloat?
    var height: CGFloat?
    var appliesCornerClip = true
    var allowsOverflow = false
    @StateObject private var imageLoader = RemoteCoverImageLoader()
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            if let width, let height {
                coverImageLayer
                    .frame(width: width, height: height)
                    .modifier(RemoteCoverOverflowClip(enabled: !allowsOverflow))
            } else {
                Color.clear
                    .aspectRatio(aspectRatio, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .overlay {
                        coverImageLayer
                    }
                    .modifier(RemoteCoverOverflowClip(enabled: !allowsOverflow))
            }
        }
        .background(Color.white)
        .modifier(RemoteCoverCornerClip(enabled: appliesCornerClip))
        .task(id: loadTaskID) {
            if let width, let height {
                imageLoader.load(url: url, targetSize: CGSize(width: width, height: height), scale: displayScale)
            } else {
                imageLoader.load(url: url, maxPixelLength: VideoCardLayout.feedCoverPixelLength(displayScale: displayScale))
            }
        }
        .onDisappear {
            imageLoader.cancel()
        }
    }

    @ViewBuilder
    private var coverImageLayer: some View {
        ZStack {
            if let image = imageLoader.image ?? cachedImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else if imageLoader.failed {
                placeholder(systemImage: "photo")
            } else {
                placeholder(systemImage: "play.rectangle")
            }
        }
    }

    private var loadTaskID: String {
        if let width, let height {
            return "\(url?.absoluteString ?? "")#\(Int(width))x\(Int(height))#\(displayScale)"
        }
        let pixel = VideoCardLayout.feedCoverPixelLength(displayScale: displayScale)
        return "\(url?.absoluteString ?? "")#feed#\(pixel)"
    }

    private var coverPixelLength: Int {
        if let width, let height {
            let displayMax = max(width, height)
            return Int((displayMax * max(1, displayScale)).rounded(.up))
        }
        return VideoCardLayout.feedCoverPixelLength(displayScale: displayScale)
    }

    private var cachedImage: NSImage? {
        RemoteCoverImageLoader.cachedImage(url: url, maxPixelLength: coverPixelLength)
    }

    private func placeholder(systemImage: String) -> some View {
        ZStack {
            Color.white
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(Color.secondary.opacity(0.42))
        }
    }
}

struct RemoteAvatar: View {
    let url: URL?
    let size: CGFloat
    var foreground: Color = .secondary
    var background: Color = Color.secondary.opacity(0.12)
    var border: Color = Color.black.opacity(0.06)

    @StateObject private var imageLoader = RemoteCoverImageLoader()
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack {
            if let image = imageLoader.image ?? cachedImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.54, weight: .semibold))
                    .foregroundStyle(foreground)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: size, height: size)
        .background(background, in: Circle())
        .overlay {
            Circle().stroke(border, lineWidth: 0.5)
        }
        .clipShape(Circle())
        .task(id: loadTaskID) {
            imageLoader.load(url: url, maxPixelLength: avatarPixelLength)
        }
        .onDisappear {
            imageLoader.cancel()
        }
    }

    private var avatarPixelLength: Int {
        max(48, Int((size * max(1, displayScale) * 1.25).rounded(.up)))
    }

    private var loadTaskID: String {
        "\(url?.absoluteString ?? "")#avatar#\(avatarPixelLength)"
    }

    private var cachedImage: NSImage? {
        RemoteCoverImageLoader.cachedImage(url: url, maxPixelLength: avatarPixelLength)
    }
}

private struct RemoteCoverCornerClip: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            content
        }
    }
}

private struct RemoteCoverOverflowClip: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.clipped()
        } else {
            content
        }
    }
}

struct MetricLabel: View {
    let systemImage: String
    let value: String

    var body: some View {
        Label(value, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for item in arrange(proposal: ProposedViewSize(width: bounds.width, height: bounds.height), subviews: subviews).items {
            subviews[item.index].place(
                at: CGPoint(x: bounds.minX + item.frame.minX, y: bounds.minY + item.frame.minY),
                proposal: ProposedViewSize(width: item.frame.width, height: item.frame.height)
            )
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (items: [(index: Int, frame: CGRect)], size: CGSize) {
        let maxWidth = proposal.width ?? 600
        var items: [(Int, CGRect)] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            items.append((index, CGRect(origin: CGPoint(x: x, y: y), size: size)))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        return (items, CGSize(width: maxWidth, height: y + rowHeight))
    }
}
