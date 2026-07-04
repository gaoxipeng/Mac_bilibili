import AppKit
import Combine
import SwiftUI

@MainActor
final class UserProfileModel: ObservableObject {
    let mid: Int64
    let seedName: String
    let seedFaceURL: URL?
    var credential: BilibiliCredential?
    let viewerMid: Int64?

    @Published var profile: BiliUserProfile?
    @Published var videos: [BiliVideo] = []
    @Published var dynamics: [BiliDynamicItem] = []
    @Published var relation = BiliAuthorRelation()
    @Published var loading = true
    @Published var videosLoading = false
    @Published var videosLoadingMore = false
    @Published var dynamicsLoading = false
    @Published var dynamicsLoadingMore = false
    @Published var errorMessage: String?
    @Published var videoSort: BiliUserVideoSort = .latestPublish
    @Published var followLoading = false

    @Published private(set) var videosHasMore = true
    @Published private(set) var dynamicsHasMore = true
    private var videoPage = 1
    private var dynamicsOffset: String?
    private let api = BilibiliAPI()

    init(
        mid: Int64,
        seedName: String,
        seedFaceURL: URL?,
        credential: BilibiliCredential?,
        viewerMid: Int64?
    ) {
        self.mid = mid
        self.seedName = seedName
        self.seedFaceURL = seedFaceURL
        self.credential = credential
        self.viewerMid = viewerMid
    }

    var displayName: String {
        (profile?.name ?? "").ifEmpty(seedName).ifEmpty("UP 主")
    }

    var displayFaceURL: URL? {
        profile?.faceURL ?? seedFaceURL
    }

    var displayCoverURLs: [URL] {
        profile?.displayTopPhotoURLs ?? []
    }

    var authorFollowerCount: Int64 {
        profile?.follower ?? 0
    }

    var isOwnProfile: Bool {
        guard let viewerMid, viewerMid > 0 else { return false }
        return viewerMid == mid
    }

    var showFollowButton: Bool {
        !isOwnProfile && credential != nil
    }

    var spaceWebURL: URL {
        URL(string: "https://space.bilibili.com/\(mid)")!
    }

    var chromeInfo: UserProfileChromeInfo {
        UserProfileChromeInfo(
            faceURL: displayFaceURL,
            name: displayName,
            level: profile?.level ?? 0,
            sign: {
                guard profile != nil else { return "" }
                let sign = profile?.sign ?? ""
                return sign.isEmpty ? "这个人很神秘，什么都没有写" : sign
            }(),
            following: profile?.following,
            follower: profile?.follower,
            likes: profile?.likes,
            videoCount: profile?.videoCount,
            webURL: spaceWebURL,
            showFollowButton: showFollowButton,
            isFollowing: relation.following,
            followerCount: authorFollowerCount,
            followLoading: followLoading,
            coverIsLight: true
        )
    }

    func load() async {
        loading = true
        errorMessage = nil
        defer { loading = false }

        do {
            profile = try await api.userProfile(mid: mid, credential: credential)
            if let credential, !isOwnProfile {
                relation = (try? await api.userRelation(mid: mid, credential: credential)) ?? BiliAuthorRelation()
            }
            async let videosTask: Void = reloadVideos()
            async let dynamicsTask: Void = reloadDynamics()
            _ = await (videosTask, dynamicsTask)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reloadVideos() async {
        videosLoading = true
        videoPage = 1
        videosHasMore = true
        defer { videosLoading = false }

        do {
            let page = try await api.userVideos(
                mid: mid,
                page: 1,
                order: videoSort,
                credential: credential
            )
            videos = page.videos
            videosHasMore = page.hasMore
            videoPage = 1
        } catch {
            if errorMessage == nil {
                errorMessage = error.localizedDescription
            }
        }
    }

    func loadMoreVideos() async {
        guard videosHasMore, !videosLoadingMore, !videosLoading else { return }

        videosLoadingMore = true
        defer { videosLoadingMore = false }

        do {
            let nextPage = videoPage + 1
            let page = try await api.userVideos(
                mid: mid,
                page: nextPage,
                order: videoSort,
                credential: credential
            )
            var seen = Set(videos.map(\.id))
            let newVideos = page.videos.filter { seen.insert($0.id).inserted }
            videos.append(contentsOf: newVideos)
            videosHasMore = page.hasMore && !newVideos.isEmpty
            videoPage = nextPage
        } catch {
            videosHasMore = false
        }
    }

    func reloadDynamics() async {
        dynamicsLoading = true
        dynamicsOffset = nil
        dynamicsHasMore = true
        defer { dynamicsLoading = false }

        do {
            let page = try await api.userSpaceDynamics(
                mid: mid,
                offset: nil,
                credential: credential
            )
            dynamics = page.items
            dynamicsOffset = page.nextOffset
            dynamicsHasMore = page.hasMore
        } catch {
            if errorMessage == nil {
                errorMessage = error.localizedDescription
            }
        }
    }

    func loadMoreDynamics() async {
        guard dynamicsHasMore, !dynamicsLoadingMore, !dynamicsLoading else { return }

        dynamicsLoadingMore = true
        defer { dynamicsLoadingMore = false }

        do {
            let page = try await api.userSpaceDynamics(
                mid: mid,
                offset: dynamicsOffset,
                credential: credential
            )
            var seen = Set(dynamics.map(\.id))
            let newItems = page.items.filter { seen.insert($0.id).inserted }
            dynamics.append(contentsOf: newItems)
            dynamicsOffset = page.nextOffset
            dynamicsHasMore = page.hasMore && !newItems.isEmpty
        } catch {
            dynamicsHasMore = false
        }
    }

    func changeSort(_ sort: BiliUserVideoSort) async {
        guard videoSort != sort else { return }
        videoSort = sort
        await reloadVideos()
    }

    func followAuthor() async {
        guard showFollowButton, !followLoading, !relation.following else { return }
        guard let credential else { return }

        followLoading = true
        defer { followLoading = false }

        do {
            try await api.modifyFollow(mid: mid, follow: true, credential: credential)
            relation.following = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func unfollowAuthor() async {
        guard showFollowButton, !followLoading, relation.following else { return }
        guard let credential else { return }

        followLoading = true
        defer { followLoading = false }

        do {
            try await api.modifyFollow(mid: mid, follow: false, credential: credential)
            relation.following = false
            relation.followerMe = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct UserProfileChromeInfo: Equatable {
    let faceURL: URL?
    let name: String
    let level: Int
    let sign: String
    let following: Int64?
    let follower: Int64?
    let likes: Int64?
    let videoCount: Int64?
    let webURL: URL
    let showFollowButton: Bool
    let isFollowing: Bool
    let followerCount: Int64
    let followLoading: Bool
    let coverIsLight: Bool
}

struct UserProfileChromePreferenceKey: PreferenceKey {
    static var defaultValue: UserProfileChromeInfo?

    static func reduce(value: inout UserProfileChromeInfo?, nextValue: () -> UserProfileChromeInfo?) {
        if let next = nextValue() {
            value = next
        }
    }
}

struct UserProfileChromeHeaderView: View {
    let info: UserProfileChromeInfo

    private let primaryText = Color(red: 0.11, green: 0.11, blue: 0.12)
    private let secondaryText = Color(red: 0.39, green: 0.39, blue: 0.4)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                profileAvatar

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .center, spacing: 6) {
                        Text(info.name)
                            .font(.title)
                            .foregroundStyle(primaryText)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)

                        if info.level > 0 {
                            BiliUserLevelIcon(level: info.level, width: 30, height: 19)
                        }
                    }

                    if !info.sign.isEmpty {
                        Text(info.sign)
                            .font(.callout)
                            .foregroundStyle(secondaryText)
                            .lineSpacing(2)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            ProfileStatsBar(
                following: info.following,
                follower: info.follower,
                likes: info.likes,
                videoCount: info.videoCount,
                primaryText: primaryText,
                secondaryText: secondaryText
            )
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.white.opacity(0.22), lineWidth: 0.6)
        }
        .shadow(color: .black.opacity(0.12), radius: 18, x: 0, y: 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var profileAvatar: some View {
        AsyncImage(url: info.faceURL) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                Image(systemName: "person.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(secondaryText)
            }
        }
        .frame(width: 52, height: 52)
        .background(Color.black.opacity(0.06), in: Circle())
        .clipShape(Circle())
        .overlay {
            Circle().stroke(Color.black.opacity(0.08), lineWidth: 1.5)
        }
    }
}

private struct ProfileStatsBar: View {
    let following: Int64?
    let follower: Int64?
    let likes: Int64?
    let videoCount: Int64?
    let primaryText: Color
    let secondaryText: Color

    var body: some View {
        HStack(spacing: 24) {
            statItem(title: "关注", value: following?.compactCount ?? "-")
            statItem(title: "粉丝", value: follower?.compactCount ?? "-")
            statItem(title: "获赞", value: likes?.compactCount ?? "-")
            statItem(title: "投稿", value: videoCount?.compactCount ?? "-")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statItem(title: String, value: String) -> some View {
        VStack(alignment: .center, spacing: 3) {
            Text(value)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(primaryText)
                .lineLimit(1)
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(secondaryText)
                .lineLimit(1)
        }
    }
}

struct UserProfileView: View {
    @EnvironmentObject private var appModel: AppModel
    @StateObject private var model: UserProfileModel
    @State private var coverIsLight = true

    private let columnInnerPadding: CGFloat = 14
    private let sectionHeaderHeight: CGFloat = 40

    init(
        mid: Int64,
        seedName: String = "",
        seedFaceURL: URL? = nil,
        credential: BilibiliCredential?,
        viewerMid: Int64? = nil
    ) {
        _model = StateObject(
            wrappedValue: UserProfileModel(
                mid: mid,
                seedName: seedName,
                seedFaceURL: seedFaceURL,
                credential: credential,
                viewerMid: viewerMid
            )
        )
    }

    var body: some View {
        GeometryReader { geometry in
            let contentWidth = geometry.size.width
                - AppLayout.videoDetailLeadingInset
                - AppLayout.videoDetailTrailingInset
            let dividerWidth: CGFloat = 0.5
            let columnGutter = columnInnerPadding * 2 + dividerWidth
            let videoColumnWidth = (contentWidth - columnGutter) * 2 / 3
            let dynamicColumnWidth = (contentWidth - columnGutter) / 3

            VStack(alignment: .leading, spacing: 0) {
                ProfileCoverCarousel(
                    urls: model.displayCoverURLs,
                    onTopLuminance: { luminance in
                        coverIsLight = luminance >= 0.58
                    }
                )

                sectionHeadersRow(
                    videoColumnWidth: videoColumnWidth,
                    dynamicColumnWidth: dynamicColumnWidth,
                    dividerWidth: dividerWidth
                )
                .padding(.horizontal, AppLayout.videoDetailLeadingInset)
                .padding(.top, 14)
                .frame(height: sectionHeaderHeight)

                HStack(alignment: .top, spacing: 0) {
                    MacOverlayScrollView(usesOverlayScrollers: true) {
                        videosScrollContent
                            .environment(\.feedViewportWidth, videoColumnWidth)
                    }
                    .frame(width: videoColumnWidth)
                    .padding(.trailing, columnInnerPadding)

                    Rectangle()
                        .fill(Color.black.opacity(0.08))
                        .frame(width: dividerWidth)

                    MacOverlayScrollView(usesOverlayScrollers: true) {
                        dynamicsScrollContent
                    }
                    .frame(width: dynamicColumnWidth)
                    .padding(.leading, columnInnerPadding)
                }
                .padding(.horizontal, AppLayout.videoDetailLeadingInset)
                .padding(.top, 8)
                .padding(.bottom, 20)
                .frame(maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .background(AppLayout.videoDetailPageBackground)
        }
        .navigationBarBackButtonHidden(true)
        .background {
            Color.clear.preference(
                key: UserProfileChromePreferenceKey.self,
                value: profileChromePreference
            )
        }
        .task { await model.load() }
        .onAppear {
            appModel.profilePageHandlers = ProfilePageHandlers(
                follow: { Task { await model.followAuthor() } },
                unfollow: { Task { await model.unfollowAuthor() } }
            )
            MediaPlaybackCoordinator.shared.notifyObscuringPageVisible()
        }
        .onDisappear {
            appModel.clearProfilePageHandlers()
            MediaPlaybackCoordinator.shared.notifyObscuringPageHidden()
        }
    }

    private var profileChromePreference: UserProfileChromeInfo {
        UserProfileChromeInfo(
            faceURL: model.chromeInfo.faceURL,
            name: model.chromeInfo.name,
            level: model.chromeInfo.level,
            sign: model.chromeInfo.sign,
            following: model.chromeInfo.following,
            follower: model.chromeInfo.follower,
            likes: model.chromeInfo.likes,
            videoCount: model.chromeInfo.videoCount,
            webURL: model.chromeInfo.webURL,
            showFollowButton: model.chromeInfo.showFollowButton,
            isFollowing: model.chromeInfo.isFollowing,
            followerCount: model.chromeInfo.followerCount,
            followLoading: model.chromeInfo.followLoading,
            coverIsLight: coverIsLight
        )
    }

    private func sectionHeadersRow(
        videoColumnWidth: CGFloat,
        dynamicColumnWidth: CGFloat,
        dividerWidth: CGFloat
    ) -> some View {
        HStack(alignment: .center, spacing: 0) {
            videoSectionHeader
                .frame(width: videoColumnWidth, alignment: .leading)
                .padding(.trailing, columnInnerPadding)

            Rectangle()
                .fill(Color.clear)
                .frame(width: dividerWidth)

            dynamicSectionHeader
                .frame(width: dynamicColumnWidth, alignment: .leading)
                .padding(.leading, columnInnerPadding)
        }
    }

    private var videoSectionHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("视频")
                    .font(.title)
                if let videoCount = model.profile?.videoCount {
                    Text(videoCount.compactCount)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            ProfileVideoSortControl(
                selection: model.videoSort,
                onChange: { sort in
                    Task { await model.changeSort(sort) }
                }
            )

            Spacer(minLength: 0)
        }
    }

    private var dynamicSectionHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("动态")
                .font(.title)
            Text("\(model.dynamics.count)")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var videosScrollContent: some View {
        if model.loading || model.videosLoading {
            loadingPlaceholder(title: "正在加载投稿")
        } else if model.videos.isEmpty {
            ContentUnavailableView("暂无投稿", systemImage: "video.slash")
                .padding(.vertical, 40)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                VideoFeedGrid(videos: model.videos)

                if model.videosHasMore {
                    FeedLoadMoreFooter(
                        anchorID: model.videos.count,
                        hasMore: model.videosHasMore,
                        loadingMore: model.videosLoadingMore,
                        onLoadMore: {
                            Task { await model.loadMoreVideos() }
                        }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var dynamicsScrollContent: some View {
        if model.loading || model.dynamicsLoading {
            loadingPlaceholder(title: "正在加载动态")
        } else if model.dynamics.isEmpty {
            ContentUnavailableView("暂无动态", systemImage: "text.bubble")
                .padding(.vertical, 40)
        } else {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(model.dynamics) { item in
                    ProfileDynamicCard(item: item)
                }

                if model.dynamicsHasMore {
                    FeedLoadMoreFooter(
                        anchorID: model.dynamics.count,
                        hasMore: model.dynamicsHasMore,
                        loadingMore: model.dynamicsLoadingMore,
                        onLoadMore: {
                            Task { await model.loadMoreDynamics() }
                        }
                    )
                }
            }
        }
    }

    private func loadingPlaceholder(title: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(title)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
    }
}

private struct ProfileDynamicCard: View {
    let item: BiliDynamicItem

    private var openDetail: Bool {
        item.canOpenDetail
    }

    var body: some View {
        Group {
            if openDetail {
                NavigationLink(value: DynamicDetailRequest(item: item)) {
                    cardContent
                }
                .buttonStyle(.plain)
            } else {
                cardContent
            }
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !item.text.isEmpty {
                BiliCommentText(
                    text: item.text,
                    emoticons: item.emoticons,
                    fontSize: 14
                )
                .lineLimit(8)
            }

            if let origin = item.origin {
                DynamicOriginPreview(origin: origin)
                    .padding(.top, item.text.isEmpty ? 0 : 10)
            } else if hasBodyContent {
                DynamicBodyPreview(item: item)
                    .padding(.top, item.text.isEmpty ? 0 : 10)
            } else if item.text.isEmpty {
                Text("该动态暂无预览内容")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }

            DynamicFeedMetaRow(item: item, video: item.video ?? item.origin?.video)
            DynamicFeedInteractionRow(item: item)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var hasBodyContent: Bool {
        item.video != nil || !item.imageURLs.isEmpty || item.link != nil
    }
}

private struct DynamicOriginPreview: View {
    let origin: BiliDynamicOrigin

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !origin.authorName.isEmpty {
                Text("@\(origin.authorName)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            DynamicContentPreview(
                text: origin.text,
                emoticons: origin.emoticons,
                video: origin.video,
                imageURLs: origin.imageURLs,
                link: origin.video == nil ? origin.link : nil
            )
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.96, green: 0.96, blue: 0.97), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct DynamicBodyPreview: View {
    let item: BiliDynamicItem

    var body: some View {
        DynamicContentPreview(
            text: "",
            emoticons: [:],
            video: item.video,
            imageURLs: item.imageURLs,
            link: item.video == nil ? item.link : nil
        )
    }
}

private struct DynamicContentPreview: View {
    let text: String
    let emoticons: [String: String]
    let video: BiliVideo?
    let imageURLs: [URL]
    let link: BiliDynamicLink?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !text.isEmpty {
                BiliCommentText(text: text, emoticons: emoticons, fontSize: 14)
                    .lineLimit(6)
            }

            if let video {
                DynamicVideoPreview(video: video)
            }

            if let link {
                DynamicLinkPreview(link: link)
            }

            if !imageURLs.isEmpty {
                DynamicImageGridPreview(urls: imageURLs)
            }
        }
    }
}

private struct DynamicVideoPreview: View {
    let video: BiliVideo

    var body: some View {
        NavigationLink(value: VideoPlaybackRequest(video)) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottomTrailing) {
                    AsyncImage(url: video.coverURL) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        default:
                            Color.secondary.opacity(0.1)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    if video.duration > 0 {
                        Text(video.durationText)
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .padding(6)
                    }
                }

                if !video.title.isEmpty {
                    Text(video.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

private struct DynamicLinkPreview: View {
    let link: BiliDynamicLink

    var body: some View {
        HStack(spacing: 0) {
            if let coverURL = link.coverURL {
                AsyncImage(url: coverURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        Color.secondary.opacity(0.1)
                    }
                }
                .frame(width: 88, height: 66)
                .clipped()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(link.title.isEmpty ? "查看链接" : link.title)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(2)
                if !link.desc.isEmpty {
                    Text(link.desc)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct DynamicImageGridPreview: View {
    let urls: [URL]

    var body: some View {
        let columns = urls.count == 1 ? 1 : min(2, urls.count)
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns),
            spacing: 6
        ) {
            ForEach(urls.prefix(4), id: \.absoluteString) { url in
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        Color.secondary.opacity(0.08)
                    }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(urls.count == 1 ? 16 / 9 : 1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }
}

private struct DynamicFeedMetaRow: View {
    let item: BiliDynamicItem
    let video: BiliVideo?

    private let metaColor = Color.secondary.opacity(0.58)

    var body: some View {
        let hasPlayStats = video != nil && (video!.viewCount > 0 || video!.danmakuCount > 0)
        let timeText = BiliCommentFormats.formatTime(item.publishDate)
        let ipText = item.ipLocation.map { "IP属地：\($0)" }
        let hasTrailing = !timeText.isEmpty || ipText != nil

        if hasPlayStats || hasTrailing {
            HStack(spacing: 12) {
                if let video {
                    if video.viewCount > 0 {
                        Text("播放 \(video.viewCount.compactCount)")
                    }
                    if video.danmakuCount > 0 {
                        Text("弹幕 \(video.danmakuCount.compactCount)")
                    }
                }
                Spacer(minLength: 0)
                if !timeText.isEmpty {
                    Text(timeText)
                }
                if let ipText {
                    Text(ipText)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(metaColor)
            .lineLimit(1)
            .padding(.top, 8)
        }
    }
}

private struct DynamicFeedInteractionRow: View {
    let item: BiliDynamicItem

    private let actionColor = Color.secondary.opacity(0.62)

    var body: some View {
        HStack(spacing: 0) {
            actionItem(label: "转发", count: item.repostCount)
            actionItem(label: "评论", count: item.commentCount)
            actionItem(label: "赞", count: item.likeCount)
        }
        .padding(.top, 4)
    }

    private func actionItem(label: String, count: Int64) -> some View {
        Text("\(label) \(count.compactCount)")
            .font(.system(size: 11))
            .foregroundStyle(actionColor)
            .frame(maxWidth: .infinity)
    }
}

private struct ProfileCoverCarousel: View {
    let urls: [URL]
    var onTopLuminance: (CGFloat) -> Void = { _ in }

    private let interval: TimeInterval = 5.5
    private let transitionDuration: TimeInterval = 1.35
    private let fallbackAspect: CGFloat = 2.55

    @State private var currentIndex = 0
    @State private var revealProgress: CGFloat = 0
    @State private var isAnimating = false
    @State private var autoplayTask: Task<Void, Never>?
    @State private var imageAspectRatio: CGFloat = 2.55

    private var hasMultiple: Bool { urls.count > 1 }

    private var nextIndex: Int {
        guard !urls.isEmpty else { return 0 }
        return (currentIndex + 1) % urls.count
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack {
                if urls.isEmpty {
                    coverPlaceholder
                } else if hasMultiple {
                    coverImage(urls[currentIndex])
                        .offset(x: -width * slowOutgoingOffset)

                    coverImage(urls[nextIndex])
                        .offset(x: width * fastIncomingOffset)
                        .zIndex(1)
                } else {
                    coverImage(urls[0])
                }

                if hasMultiple {
                    VStack {
                        Spacer()
                        pageIndicators
                            .padding(.bottom, 10)
                    }
                    .zIndex(2)
                }
            }
        }
        .aspectRatio(imageAspectRatio, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipped()
        .onAppear {
            if urls.isEmpty {
                onTopLuminance(0.72)
            }
            restartAutoplay()
        }
        .onDisappear { autoplayTask?.cancel() }
        .onChange(of: urls.map(\.absoluteString)) { _, _ in
            currentIndex = 0
            revealProgress = 0
            isAnimating = false
            imageAspectRatio = fallbackAspect
            restartAutoplay()
        }
    }

    private var slowOutgoingOffset: CGFloat {
        let eased = 1 - pow(1 - revealProgress, 1.8)
        return eased * 0.38
    }

    private var fastIncomingOffset: CGFloat {
        pow(1 - revealProgress, 0.55)
    }

    private var pageIndicators: some View {
        HStack(spacing: 6) {
            ForEach(urls.indices, id: \.self) { index in
                Circle()
                    .fill(Color.white.opacity(index == currentIndex ? 0.95 : 0.45))
                    .frame(width: index == currentIndex ? 7 : 6, height: index == currentIndex ? 7 : 6)
            }
        }
    }

    @ViewBuilder
    private func coverImage(_ url: URL) -> some View {
        ProfileCoverImage(url: url) { aspect, luminance in
            imageAspectRatio = aspect
            onTopLuminance(luminance)
        }
        .frame(maxWidth: .infinity)
    }

    private var coverPlaceholder: some View {
        AppLayout.videoDetailPageBackground
    }

    private func restartAutoplay() {
        autoplayTask?.cancel()
        guard hasMultiple else { return }
        autoplayTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await advance()
            }
        }
    }

    @MainActor
    private func advance() async {
        guard hasMultiple, !isAnimating else { return }
        isAnimating = true
        withAnimation(.easeInOut(duration: transitionDuration)) {
            revealProgress = 1
        }
        try? await Task.sleep(nanoseconds: UInt64(transitionDuration * 1_000_000_000))
        currentIndex = nextIndex
        revealProgress = 0
        isAnimating = false
    }
}

private struct ProfileCoverImage: View {
    let url: URL
    let onImageReady: (CGFloat, CGFloat) -> Void

    @StateObject private var loader = RemoteCoverImageLoader()

    var body: some View {
        Group {
            if let image = loader.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .onAppear {
                        reportMetrics(for: image)
                    }
            } else if loader.failed {
                Color.secondary.opacity(0.08)
            } else {
                Color.secondary.opacity(0.06)
            }
        }
        .onAppear {
            loader.load(url: url, maxPixelLength: 1600)
        }
        .onChange(of: loader.image) { _, image in
            guard let image else { return }
            reportMetrics(for: image)
        }
    }

    private func reportMetrics(for image: NSImage) {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return }
        onImageReady(size.width / size.height, image.topRegionLuminance)
    }
}

private extension NSImage {
    var topRegionLuminance: CGFloat {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return 0.72
        }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return 0.72 }

        let sampleHeight = max(1, height / 3)
        let rect = CGRect(x: 0, y: height - sampleHeight, width: width, height: sampleHeight)
        guard let cropped = cgImage.cropping(to: rect) else { return 0.72 }

        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        var data = [UInt8](repeating: 0, count: bytesPerRow * sampleHeight)
        guard let context = CGContext(
            data: &data,
            width: width,
            height: sampleHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return 0.72
        }

        context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: sampleHeight))

        var total: CGFloat = 0
        let pixelCount = width * sampleHeight
        for index in stride(from: 0, to: data.count, by: bytesPerPixel) {
            let red = CGFloat(data[index]) / 255
            let green = CGFloat(data[index + 1]) / 255
            let blue = CGFloat(data[index + 2]) / 255
            total += 0.2126 * red + 0.7152 * green + 0.0722 * blue
        }
        return total / CGFloat(max(pixelCount, 1))
    }
}

private struct ProfileVideoSortControl: View {
    let selection: BiliUserVideoSort
    let onChange: (BiliUserVideoSort) -> Void

    @State private var isPressing = false
    @State private var dragX: CGFloat?
    @State private var animationTrigger = 0
    @State private var displayedSelection: BiliUserVideoSort

    private let outerPadding: CGFloat = 5
    private let indicatorInset: CGFloat = 3
    private let options = BiliUserVideoSort.allCases

    init(selection: BiliUserVideoSort, onChange: @escaping (BiliUserVideoSort) -> Void) {
        self.selection = selection
        self.onChange = onChange
        _displayedSelection = State(initialValue: selection)
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let segmentWidth = max(1, (size.width - outerPadding * 2) / CGFloat(options.count))
            let indicatorWidth = max(1, segmentWidth - indicatorInset * 2)
            let indicatorHeight = max(1, size.height - outerPadding * 2)
            let restingX = outerPadding + CGFloat(selectedIndex) * segmentWidth + indicatorInset
            let draggingX = clampedIndicatorX(
                centerX: dragX ?? restingX + indicatorWidth / 2,
                indicatorWidth: indicatorWidth,
                totalWidth: size.width
            )
            let indicatorX = isPressing ? draggingX : restingX

            ZStack(alignment: .topLeading) {
                ProfileSortLiquidIndicator(isPressing: isPressing, animationTrigger: animationTrigger)
                    .frame(width: indicatorWidth, height: indicatorHeight)
                    .offset(x: indicatorX, y: outerPadding)
                    .animation(
                        isPressing
                        ? .interactiveSpring(response: 0.18, dampingFraction: 0.78, blendDuration: 0.02)
                        : .spring(response: 0.34, dampingFraction: 0.58, blendDuration: 0.04),
                        value: indicatorX
                    )

                HStack(spacing: 0) {
                    ForEach(options, id: \.self) { sort in
                        Text(sort.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.black.opacity(displayedSelection == sort ? 0.92 : 0.82))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity)
                            .frame(height: indicatorHeight)
                            .offset(y: outerPadding)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                select(sort)
                            }
                    }
                }
            }
            .contentShape(Capsule(style: .continuous))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isPressing {
                            withAnimation(.spring(response: 0.18, dampingFraction: 0.68)) {
                                isPressing = true
                            }
                        }
                        dragX = value.location.x
                        updateSelection(for: value.location.x, segmentWidth: segmentWidth)
                    }
                    .onEnded { value in
                        updateSelection(for: value.location.x, segmentWidth: segmentWidth)
                        dragX = nil
                        animationTrigger += 1
                        withAnimation(.spring(response: 0.36, dampingFraction: 0.56)) {
                            isPressing = false
                        }
                        commitSelection()
                    }
            )
        }
        .frame(width: AppLayout.searchTypeToggleWidth + 28, height: AppLayout.searchBarHeight)
        .background(Color.white.opacity(0.78), in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.035), radius: 6, x: 0, y: 2)
        .onChange(of: selection) { _, newValue in
            displayedSelection = newValue
        }
    }

    private var selectedIndex: Int {
        options.firstIndex(of: displayedSelection) ?? 0
    }

    private func select(_ sort: BiliUserVideoSort) {
        guard displayedSelection != sort else {
            animationTrigger += 1
            return
        }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.58)) {
            displayedSelection = sort
        }
        animationTrigger += 1
        onChange(sort)
    }

    private func updateSelection(for x: CGFloat, segmentWidth: CGFloat) {
        let adjustedX = x - outerPadding
        let index = min(
            options.count - 1,
            max(0, Int((adjustedX / segmentWidth).rounded(.down)))
        )
        let sort = options[index]
        guard displayedSelection != sort else { return }
        withAnimation(.interactiveSpring(response: 0.20, dampingFraction: 0.72)) {
            displayedSelection = sort
        }
    }

    private func commitSelection() {
        guard displayedSelection != selection else { return }
        onChange(displayedSelection)
    }

    private func clampedIndicatorX(centerX: CGFloat, indicatorWidth: CGFloat, totalWidth: CGFloat) -> CGFloat {
        let expandedOverflow = indicatorWidth * 0.08
        return min(
            totalWidth - outerPadding - indicatorWidth - expandedOverflow,
            max(outerPadding + expandedOverflow, centerX - indicatorWidth / 2)
        )
    }
}

private struct ProfileSortLiquidIndicator: View {
    let isPressing: Bool
    let animationTrigger: Int

    var body: some View {
        Capsule(style: .continuous)
            .fill(Color(red: 0.92, green: 0.92, blue: 0.93))
            .glassEffect(.regular.interactive(), in: .capsule)
            .phaseAnimator(ProfileSortPhase.allCases, trigger: animationTrigger) { content, phase in
                content
                    .scaleEffect(
                        x: isPressing ? 1.12 : phase.xScale,
                        y: isPressing ? 1.08 : phase.yScale
                    )
                    .blur(radius: isPressing ? 0.18 : phase.blurRadius)
            } animation: { phase in
                phase.animation
            }
    }
}

private enum ProfileSortPhase: CaseIterable {
    case resting
    case droplet
    case rebound
    case settled

    var xScale: CGFloat {
        switch self {
        case .resting, .settled: 1
        case .droplet: 1.18
        case .rebound: 0.96
        }
    }

    var yScale: CGFloat {
        switch self {
        case .resting, .settled: 1
        case .droplet: 1.08
        case .rebound: 0.98
        }
    }

    var blurRadius: CGFloat {
        switch self {
        case .resting, .settled: 0
        case .droplet: 0.3
        case .rebound: 0.1
        }
    }

    var animation: Animation {
        switch self {
        case .resting: .default
        case .droplet: .spring(response: 0.22, dampingFraction: 0.62)
        case .rebound: .spring(response: 0.28, dampingFraction: 0.58)
        case .settled: .spring(response: 0.34, dampingFraction: 0.62)
        }
    }
}
