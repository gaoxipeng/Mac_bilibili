import SwiftUI

private enum VideoCardLayout {
    static let minWidth: CGFloat = 272
    static let gridSpacing: CGFloat = 22
    static let coverAspect: CGFloat = 16.0 / 9.0
    static let cornerRadius: CGFloat = 10

    static let gridColumns = [
        GridItem(.adaptive(minimum: minWidth), spacing: gridSpacing, alignment: .top)
    ]
}

struct FollowingView: View {
    let videos: [BiliVideo]
    let loading: Bool
    let loadingMore: Bool
    let hasMore: Bool
    let error: String?
    let loggedIn: Bool
    let onLoadMore: () -> Void

    private let columns = VideoCardLayout.gridColumns

    var body: some View {
        ScrollView {
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

                    LazyVGrid(columns: columns, alignment: .leading, spacing: VideoCardLayout.gridSpacing) {
                        ForEach(videos) { video in
                            VideoCard(video: video, largeTypography: true)
                        }
                    }

                    if hasMore {
                        loadMoreFooter
                    }
                }
            }
            .padding(28)
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
                    .onAppear(perform: onLoadMore)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

struct VideoGridView: View {
    let title: String
    let subtitle: String
    let videos: [BiliVideo]
    let loading: Bool
    let error: String?
    let emptyTitle: String

    private let columns = VideoCardLayout.gridColumns

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                PageHeader(title: title, subtitle: subtitle)
                StateBanner(loading: loading, error: error, isEmpty: videos.isEmpty, emptyTitle: emptyTitle)

                LazyVGrid(columns: columns, alignment: .leading, spacing: VideoCardLayout.gridSpacing) {
                    ForEach(videos) { video in
                        VideoCard(video: video)
                    }
                }
            }
            .padding(28)
        }
    }
}

struct LiveRoomGridView: View {
    let rooms: [BiliLiveRoom]
    let loading: Bool
    let error: String?

    private let columns = VideoCardLayout.gridColumns

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "直播", subtitle: "热门直播间")
                StateBanner(loading: loading, error: error, isEmpty: rooms.isEmpty, emptyTitle: "暂时没有直播内容")

                LazyVGrid(columns: columns, alignment: .leading, spacing: VideoCardLayout.gridSpacing) {
                    ForEach(rooms) { room in
                        LiveRoomCard(room: room)
                    }
                }
            }
            .padding(28)
        }
    }
}

struct SearchDashboard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                PageHeader(title: "搜索", subtitle: "查找视频、UP 主和当前热词")

                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        SearchField(text: $model.searchQuery) {
                            Task { await model.search() }
                        }
                        Button {
                            Task { await model.search() }
                        } label: {
                            Label("搜索", systemImage: "magnifyingglass")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.pink)
                    }

                    if !model.hotWords.isEmpty {
                        FlowLayout(spacing: 8) {
                            ForEach(model.hotWords) { word in
                                Button {
                                    Task { await model.search(keyword: word.keyword) }
                                } label: {
                                    Text(word.keyword)
                                        .lineLimit(1)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                }
                .padding(18)
                .materialPanel()

                StateBanner(
                    loading: model.isLoading,
                    error: model.errorMessage,
                    isEmpty: model.searchResults.isEmpty && !model.searchQuery.isEmpty,
                    emptyTitle: "没有找到相关视频"
                )

                LazyVGrid(columns: VideoCardLayout.gridColumns, spacing: VideoCardLayout.gridSpacing) {
                    ForEach(model.searchResults) { video in
                        VideoCard(video: video)
                    }
                }
            }
            .padding(28)
        }
    }
}

struct HistoryView: View {
    let items: [BiliHistoryItem]
    let loading: Bool
    let error: String?
    let loggedIn: Bool

    var body: some View {
        ScrollView {
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
            .padding(28)
        }
    }
}

struct MineView: View {
    @ObservedObject var model: AppModel
    @State private var showLogin = false
    @StateObject private var webSession = BilibiliWebSession()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "我的", subtitle: model.account == nil ? "登录后同步个人资料、关注和历史" : "账号与资料")
                if let account = model.account {
                    ProfileCard(account: account, profile: model.profile)
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
            .padding(28)
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
    let subtitle: String
    var largeTypography = false

    var body: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(largeTypography ? .system(size: 40, weight: .bold) : .largeTitle.weight(.bold))
                Text(subtitle)
                    .font(largeTypography ? .body : .callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
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

    var body: some View {
        NavigationLink(value: video) {
            VStack(alignment: .leading, spacing: 14) {
                ZStack {
                    RemoteCover(
                        url: video.coverURL,
                        aspectRatio: VideoCardLayout.coverAspect
                    )
                }
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: VideoCardLayout.cornerRadius, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    if video.duration > 0 {
                        Text(video.durationText)
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.64), in: Capsule())
                            .foregroundStyle(.white)
                            .padding(8)
                    }
                }
                .scaleEffect(isCoverHovered ? 1.05 : 1)
                .animation(.easeOut(duration: 0.22), value: isCoverHovered)
                .onHover { hovering in
                    isCoverHovered = hovering
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text(video.title)
                        .font(largeTypography ? .title3.weight(.semibold) : .title3.weight(.medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 8) {
                        AsyncImage(url: video.authorFaceURL) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().scaledToFill()
                            default:
                                Image(systemName: "person.fill")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: largeTypography ? 26 : 24, height: largeTypography ? 26 : 24)
                        .clipShape(Circle())

                        Text(video.authorName.ifEmpty("未知 UP 主"))
                            .font(largeTypography ? .subheadline : .callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    HStack(spacing: 12) {
                        BiliStatLabel(icon: .play, value: video.viewCount.compactCount)
                        BiliStatLabel(icon: .danmaku, value: video.danmakuCount.compactCount)
                        if video.likeCount > 0 {
                            BiliStatLabel(icon: .like, value: video.likeCount.compactCount)
                        }
                    }
                    .font(largeTypography ? .subheadline : .callout)
                    .foregroundStyle(.secondary)
                }
                .padding([.horizontal, .bottom], 16)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: VideoCardLayout.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .materialPanel()
    }
}

struct HistoryRow: View {
    let item: BiliHistoryItem

    var body: some View {
        NavigationLink(value: item.video) {
            HStack(spacing: 14) {
                RemoteCover(url: item.video.coverURL, aspectRatio: 16.0 / 9.0)
                    .frame(width: 156)
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

struct ProfileCard: View {
    let account: BiliAccount
    let profile: BiliUserProfile?

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            AsyncImage(url: profile?.faceURL ?? account.faceURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    Image(systemName: "person.fill")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 86, height: 86)
            .background(Color.secondary.opacity(0.14), in: Circle())
            .clipShape(Circle())

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

    var body: some View {
        Group {
            if let width, let height {
                coverImage
                    .frame(width: width, height: height)
                    .clipped()
            } else {
                Color.clear
                    .aspectRatio(aspectRatio, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .overlay {
                        coverImage
                    }
                    .clipped()
            }
        }
        .background(Color.secondary.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private var coverImage: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFill()
            case .failure:
                placeholder(systemImage: "photo")
            default:
                placeholder(systemImage: "play.rectangle")
            }
        }
    }

    private func placeholder(systemImage: String) -> some View {
        ZStack {
            LinearGradient(colors: [.pink.opacity(0.18), .cyan.opacity(0.16)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.secondary)
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

struct SearchField: View {
    @Binding var text: String
    let onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索 B 站", text: $text)
                .textFieldStyle(.plain)
                .onSubmit(onSubmit)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.secondary.opacity(0.28), lineWidth: 0.5)
        }
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
