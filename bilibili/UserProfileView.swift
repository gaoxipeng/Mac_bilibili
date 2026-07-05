import AppKit
import Combine
import SwiftUI

@MainActor
final class UserProfileModel: ObservableObject {
    let mid: Int64
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
        credential: BilibiliCredential?,
        viewerMid: Int64?
    ) {
        self.mid = mid
        self.credential = credential
        self.viewerMid = viewerMid
    }

    var displayName: String {
        guard let profile else { return "" }
        return profile.name.ifEmpty("UP 主")
    }

    var displayFaceURL: URL? {
        profile?.faceURL
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
            followerMe: relation.followerMe,
            followerCount: authorFollowerCount,
            followLoading: followLoading
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
            applyFollowerDelta(1)
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
            applyFollowerDelta(-1)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func applyFollowerDelta(_ delta: Int64) {
        guard let current = profile else { return }
        profile = BiliUserProfile(
            mid: current.mid,
            name: current.name,
            faceURL: current.faceURL,
            sign: current.sign,
            level: current.level,
            following: current.following,
            follower: max(0, current.follower + delta),
            likes: current.likes,
            coinCount: current.coinCount,
            bcoinBalance: current.bcoinBalance,
            videoCount: current.videoCount,
            ipLocation: current.ipLocation
        )
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
    let followerMe: Bool
    let followerCount: Int64
    let followLoading: Bool
}

struct UserProfileChromeMeasuredHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private enum ProfileChromeCapsuleMetrics {
    static let height: CGFloat = 48
    static let horizontalPadding: CGFloat = 14
    static let selectedInset: CGFloat = 6
    static let statColumnCount: CGFloat = 4
    static let barWidth: CGFloat = 300
}

struct UserProfileChromeHeaderView: View {
    let info: UserProfileChromeInfo
    var showsBackButton = false
    var onBack: () -> Void = {}
    var onFollow: () -> Void = {}
    var onUnfollow: () -> Void = {}
    var onFollowingTap: (() -> Void)?
    var onFollowersTap: (() -> Void)?

    private let primaryText = Color(red: 0.11, green: 0.11, blue: 0.12)
    private let secondaryText = Color(red: 0.39, green: 0.39, blue: 0.4)
    private let cardCornerRadius: CGFloat = 22

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if showsBackButton {
                GlassBackButton(action: onBack)
            }

            HStack(alignment: .center, spacing: 12) {
                profileAvatar

                VStack(alignment: .leading, spacing: 10) {
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
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailingActions
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                )
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: cardCornerRadius))
        }
        .overlay {
            RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.52),
                            Color.white.opacity(0.14),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
        }
        .shadow(color: .black.opacity(0.10), radius: 18, x: 0, y: 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: UserProfileChromeMeasuredHeightKey.self,
                    value: geometry.size.height
                )
            }
        }
    }

    @ViewBuilder
    private var trailingActions: some View {
        HStack(alignment: .center, spacing: 16) {
            ProfileStatsBar(
                following: info.following,
                follower: info.follower,
                likes: info.likes,
                videoCount: info.videoCount,
                primaryText: primaryText,
                secondaryText: secondaryText,
                style: .borderedChrome,
                onFollowingTap: onFollowingTap,
                onFollowersTap: onFollowersTap
            )

            if info.showFollowButton {
                AuthorFollowButton(
                    isFollowing: info.isFollowing,
                    followerMe: info.followerMe,
                    followerCount: info.followerCount,
                    isLoading: info.followLoading,
                    usesProfileChromeSizing: true,
                    fixedCapsuleHeight: ProfileChromeCapsuleMetrics.height,
                    onFollow: onFollow,
                    onUnfollow: onUnfollow
                )
            }

            GlassMoreButton(webURL: info.webURL)
        }
        .fixedSize(horizontal: false, vertical: true)
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
    enum Style {
        case plain
        case borderedChrome
    }

    let following: Int64?
    let follower: Int64?
    let likes: Int64?
    let videoCount: Int64?
    let primaryText: Color
    let secondaryText: Color
    var style: Style = .plain
    var onFollowingTap: (() -> Void)?
    var onFollowersTap: (() -> Void)?

    private var itemSpacing: CGFloat {
        style == .borderedChrome ? 22 : 24
    }

    var body: some View {
        Group {
            if style == .borderedChrome {
                borderedChromeBody
            } else {
                plainBody
            }
        }
    }

    private var borderedChromeBody: some View {
        GeometryReader { geometry in
            let columnWidth = geometry.size.width / ProfileChromeCapsuleMetrics.statColumnCount

            HStack(spacing: 0) {
                ProfileStatItem(
                    title: "关注",
                    value: following?.compactCount ?? "-",
                    primaryText: primaryText,
                    secondaryText: secondaryText,
                    fixedWidth: columnWidth,
                    fixedHeight: ProfileChromeCapsuleMetrics.height,
                    leadingHoverExtension: ProfileChromeCapsuleMetrics.horizontalPadding,
                    action: onFollowingTap
                )
                ProfileStatItem(
                    title: "粉丝",
                    value: follower?.compactCount ?? "-",
                    primaryText: primaryText,
                    secondaryText: secondaryText,
                    fixedWidth: columnWidth,
                    fixedHeight: ProfileChromeCapsuleMetrics.height,
                    action: onFollowersTap
                )
                ProfileStatItem(
                    title: "获赞",
                    value: likes?.compactCount ?? "-",
                    primaryText: primaryText,
                    secondaryText: secondaryText,
                    fixedWidth: columnWidth,
                    fixedHeight: ProfileChromeCapsuleMetrics.height
                )
                ProfileStatItem(
                    title: "投稿",
                    value: videoCount?.compactCount ?? "-",
                    primaryText: primaryText,
                    secondaryText: secondaryText,
                    fixedWidth: columnWidth,
                    fixedHeight: ProfileChromeCapsuleMetrics.height
                )
            }
        }
        .padding(.horizontal, ProfileChromeCapsuleMetrics.horizontalPadding)
        .frame(width: ProfileChromeCapsuleMetrics.barWidth, height: ProfileChromeCapsuleMetrics.height)
        .background {
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.42))
        }
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.black.opacity(0.10), lineWidth: 0.8)
        }
        .clipShape(Capsule(style: .continuous))
    }

    private var plainBody: some View {
        HStack(spacing: itemSpacing) {
            ProfileStatItem(
                title: "关注",
                value: following?.compactCount ?? "-",
                primaryText: primaryText,
                secondaryText: secondaryText,
                action: onFollowingTap
            )
            ProfileStatItem(
                title: "粉丝",
                value: follower?.compactCount ?? "-",
                primaryText: primaryText,
                secondaryText: secondaryText,
                action: onFollowersTap
            )
            ProfileStatItem(
                title: "获赞",
                value: likes?.compactCount ?? "-",
                primaryText: primaryText,
                secondaryText: secondaryText
            )
            ProfileStatItem(
                title: "投稿",
                value: videoCount?.compactCount ?? "-",
                primaryText: primaryText,
                secondaryText: secondaryText
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ProfileStatItem: View {
    let title: String
    let value: String
    let primaryText: Color
    let secondaryText: Color
    var fixedWidth: CGFloat? = nil
    var fixedHeight: CGFloat? = nil
    var leadingHoverExtension: CGFloat = 0
    var action: (() -> Void)? = nil

    @State private var isHovered = false

    private var hoverWidth: CGFloat? {
        guard let fixedWidth else { return nil }
        let inset = ProfileChromeCapsuleMetrics.selectedInset
        return max(44, fixedWidth - inset * 2 + leadingHoverExtension)
    }

    private var hoverHeight: CGFloat {
        let inset = ProfileChromeCapsuleMetrics.selectedInset
        return fixedHeight.map { max(34, $0 - inset * 2) } ?? 34
    }

    private var hoverXOffset: CGFloat {
        -leadingHoverExtension / 2
    }

    var body: some View {
        Group {
            if let action {
                Button(action: action) {
                    label
                }
                .buttonStyle(.plain)
            } else {
                label
            }
        }
        .onHover { hovering in
            guard action != nil else { return }
            withAnimation(.easeOut(duration: 0.16)) {
                isHovered = hovering
            }
        }
    }

    private var label: some View {
        VStack(alignment: .center, spacing: 3) {
            Text(value)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(primaryText)
                .lineLimit(1)
                .minimumScaleFactor(fixedWidth == nil ? 1 : 0.75)
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(secondaryText)
                .lineLimit(1)
        }
        .offset(x: isHovered ? hoverXOffset : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(width: fixedWidth, height: fixedHeight)
        .background {
            Capsule(style: .continuous)
                .fill(Color(red: 0.92, green: 0.92, blue: 0.93))
                .glassEffect(.regular.interactive(), in: .capsule)
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.6)
                }
                .frame(width: hoverWidth, height: hoverHeight)
                .offset(x: hoverXOffset)
                .opacity(isHovered ? 1 : 0)
        }
        .animation(.easeOut(duration: 0.16), value: isHovered)
        .contentShape(Rectangle())
    }
}

struct UserProfileView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.videoDetailChromeHeight) private var chromeHeight
    @StateObject private var model: UserProfileModel
    @State private var publishesFloatingChrome = false

    private let columnInnerPadding: CGFloat = 14
    private let profileSectionHeaderHeight: CGFloat = 48
    private let profileDynamicColumnWidthRatio: CGFloat = 0.24

    init(
        mid: Int64,
        credential: BilibiliCredential?,
        viewerMid: Int64? = nil
    ) {
        _model = StateObject(
            wrappedValue: UserProfileModel(
                mid: mid,
                credential: credential,
                viewerMid: viewerMid
            )
        )
    }

    var body: some View {
        GeometryReader { geometry in
            let contentWidth = geometry.size.width - AppLayout.videoDetailLeadingInset
            let dividerWidth: CGFloat = 0.5
            let columnGutter = columnInnerPadding * 2 + dividerWidth
            let dynamicColumnWidth = (contentWidth - columnGutter) * profileDynamicColumnWidthRatio
            let videoColumnWidth = contentWidth - columnGutter - dynamicColumnWidth
            let contentTopInset = AppLayout.userProfileContentTopInset(chromeHeight: chromeHeight)

            VStack(alignment: .leading, spacing: 0) {
                Color.clear
                    .frame(height: contentTopInset)

                HStack(alignment: .top, spacing: 0) {
                    profileScrollColumn(width: videoColumnWidth) {
                        videoSectionHeader
                            .padding(.horizontal, AppLayout.feedHorizontalInset)
                    } content: {
                        videosScrollContent
                            .padding(.horizontal, AppLayout.feedHorizontalInset)
                            .environment(\.feedViewportWidth, videoColumnWidth)
                            .environment(\.feedSymmetricHorizontalInsets, true)
                    }
                    .padding(.trailing, columnInnerPadding)

                    Rectangle()
                        .fill(Color.black.opacity(0.08))
                        .frame(width: dividerWidth)

                    profileScrollColumn(width: dynamicColumnWidth) {
                        dynamicSectionHeader
                            .padding(.leading, columnInnerPadding)
                    } content: {
                        dynamicsScrollContent
                            .padding(.leading, columnInnerPadding)
                    }
                }
                .padding(.leading, AppLayout.videoDetailLeadingInset)
                .padding(.bottom, 20)
                .frame(maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .background(AppLayout.videoDetailPageBackground)
            .animation(.easeOut(duration: 0.22), value: contentTopInset)
        }
        .navigationBarBackButtonHidden(true)
        .task { await model.load() }
        .onAppear {
            publishesFloatingChrome = true
            publishProfileFloatingChrome()
            appModel.profilePageHandlers = ProfilePageHandlers(
                follow: { Task { await model.followAuthor() } },
                unfollow: { Task { await model.unfollowAuthor() } },
                openRelationList: { tab in
                    appModel.requestUserRelationList(
                        UserRelationListRequest(
                            hostMid: model.mid,
                            hostName: model.chromeInfo.name,
                            hostFaceURL: model.chromeInfo.faceURL,
                            hostSign: model.chromeInfo.sign,
                            initialTab: tab
                        )
                    )
                },
                reload: { Task { await model.load() } }
            )
            MediaPlaybackCoordinator.shared.notifyObscuringPageVisible()
        }
        .onDisappear {
            publishesFloatingChrome = false
            appModel.popProfileFloatingChrome()
            appModel.restoreRelationListChrome()
            appModel.clearProfilePageHandlers()
            MediaPlaybackCoordinator.shared.notifyObscuringPageHidden()
        }
        .onChange(of: model.profile?.name) { _, _ in updateFloatingProfileChrome() }
        .onChange(of: model.profile?.sign) { _, _ in updateFloatingProfileChrome() }
        .onChange(of: model.profile?.level) { _, _ in updateFloatingProfileChrome() }
        .onChange(of: model.profile?.follower) { _, _ in updateFloatingProfileChrome() }
        .onChange(of: model.relation.following) { _, _ in updateFloatingProfileChrome() }
        .onChange(of: model.followLoading) { _, _ in updateFloatingProfileChrome() }
        .onChange(of: model.loading) { _, _ in updateFloatingProfileChrome() }
    }

    private func updateFloatingProfileChrome() {
        if publishesFloatingChrome {
            publishProfileFloatingChrome()
        } else {
            appModel.refreshProfileFloatingChrome(profileChromePreference)
        }
    }

    private func publishProfileFloatingChrome() {
        appModel.presentProfileFloatingChrome(profileChromePreference)
    }

    private var profileChromePreference: UserProfileChromeInfo? {
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
            followerMe: model.chromeInfo.followerMe,
            followerCount: model.chromeInfo.followerCount,
            followLoading: model.chromeInfo.followLoading
        )
    }

    private func profileScrollColumn<Header: View, Content: View>(
        width: CGFloat,
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header()
                .frame(height: profileSectionHeaderHeight, alignment: .center)
                .frame(maxWidth: .infinity, alignment: .leading)
                .profileSectionHeaderChrome()

            MacOverlayScrollView(usesOverlayScrollers: true, clipsContent: true) {
                content()
            }
        }
        .frame(width: width)
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

            Spacer(minLength: 0)

            ProfileVideoSortControl(
                selection: model.videoSort,
                onChange: { sort in
                    Task { await model.changeSort(sort) }
                }
            )
        }
    }

    private var dynamicSectionHeader: some View {
        HStack(alignment: .center, spacing: 6) {
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
                VideoFeedGrid(videos: model.videos, showsAuthor: false)

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
    @State private var isCoverHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        NavigationLink(value: VideoPlaybackRequest(video)) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottomTrailing) {
                    HoverZoomVideoCover(shape: shape, isHovered: $isCoverHovered) {
                        RemoteCover(
                            url: video.coverURL,
                            aspectRatio: VideoCardLayout.coverAspect,
                            appliesCornerClip: false
                        )
                        .frame(maxWidth: .infinity)
                    }

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
                .zIndex(isCoverHovered ? 1 : 0)

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

private struct ProfileVideoSortControl: View {
    let selection: BiliUserVideoSort
    let onChange: (BiliUserVideoSort) -> Void

    @State private var isPressing = false
    @State private var isHovered = false
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
        .searchHeaderCapsuleChrome(isEmphasized: isPressing, isHovered: isHovered)
        .contentShape(Capsule(style: .continuous))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
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

private struct ProfileSectionHeaderChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(AppLayout.videoDetailPageBackground)
            .zIndex(1)
    }
}

private extension View {
    func profileSectionHeaderChrome() -> some View {
        modifier(ProfileSectionHeaderChrome())
    }
}
