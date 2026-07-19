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
    private var profileIpRefreshTask: Task<Void, Never>?
    private var dynamicsIpEnrichTask: Task<Void, Never>?
    private let api = BilibiliAPI()
    private let spaceStore = ProfileSpaceStore()
    private var hasCachedContent = false
    private let onPersistSpace: ((CachedProfileSpace) -> Void)?

    init(
        mid: Int64,
        credential: BilibiliCredential?,
        viewerMid: Int64?,
        seedSpace: CachedProfileSpace? = nil,
        onPersistSpace: ((CachedProfileSpace) -> Void)? = nil
    ) {
        self.mid = mid
        self.credential = credential
        self.viewerMid = viewerMid
        self.onPersistSpace = onPersistSpace
        if let seedSpace, seedSpace.mid == mid {
            applyCachedSpace(seedSpace)
        } else {
            restoreOwnProfileCacheIfNeeded()
        }
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
            ipLocation: JSONParser.normalizeIpLocation(profile?.ipLocation),
            following: profile?.following,
            follower: profile?.follower,
            likes: profile?.likes,
            videoCount: profile?.videoCount,
            webURL: spaceWebURL,
            showFollowButton: showFollowButton,
            isFollowing: relation.following,
            followerMe: relation.followerMe,
            followerCount: authorFollowerCount,
            followLoading: followLoading,
            showLogoutButton: isOwnProfile
        )
    }

    func load() async {
        profileIpRefreshTask?.cancel()
        dynamicsIpEnrichTask?.cancel()
        let showBlockingLoading = !hasCachedContent
        if showBlockingLoading {
            loading = true
        }
        errorMessage = nil
        defer { loading = false }

        do {
            profile = try await api.userProfile(mid: mid, credential: credential)
            if let credential, !isOwnProfile {
                relation = (try? await api.userRelation(mid: mid, credential: credential)) ?? BiliAuthorRelation()
            }
            async let videosTask: Void = reloadVideos(showLoading: showBlockingLoading)
            async let dynamicsTask: Void = reloadDynamics(showLoading: showBlockingLoading)
            _ = await (videosTask, dynamicsTask)
            scheduleProfileIpRefresh()
            persistOwnProfileCache()
        } catch {
            if !hasCachedContent {
                errorMessage = error.localizedDescription
            }
        }
    }

    func reloadVideos(showLoading: Bool = true) async {
        if showLoading {
            videosLoading = true
        }
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
            hasCachedContent = hasCachedContent || profile != nil || !videos.isEmpty || !dynamics.isEmpty
            persistOwnProfileCache()
        } catch {
            if errorMessage == nil, !hasCachedContent {
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

    func reloadDynamics(showLoading: Bool = true) async {
        if showLoading {
            dynamicsLoading = true
        }
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
            hasCachedContent = hasCachedContent || profile != nil || !videos.isEmpty || !dynamics.isEmpty
            applyProfileIpLocation(Self.resolveProfileIpFromDynamics(page.items))
            scheduleDynamicsIpEnrichment(page.items)
            persistOwnProfileCache()
        } catch {
            if errorMessage == nil, !hasCachedContent {
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
        await reloadVideos(showLoading: videos.isEmpty)
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

    private func applyProfileIpLocation(_ ipLocation: String?) {
        guard let normalized = JSONParser.normalizeIpLocation(ipLocation) else { return }
        guard let current = profile else { return }
        if JSONParser.normalizeIpLocation(current.ipLocation) != nil { return }
        profile = current.withIpLocation(normalized)
    }

    private static func resolveProfileIpFromDynamics(_ dynamics: [BiliDynamicItem]) -> String? {
        dynamics.compactMap { JSONParser.normalizeIpLocation($0.ipLocation) }.first
    }

    private func scheduleDynamicsIpEnrichment(_ baseItems: [BiliDynamicItem]) {
        guard baseItems.contains(where: { JSONParser.normalizeIpLocation($0.ipLocation) == nil }) else {
            return
        }
        dynamicsIpEnrichTask?.cancel()
        dynamicsIpEnrichTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var requestCredential = credential
            if let current = requestCredential {
                let exchanged = await api.exchangeAccessKey(current)
                requestCredential = exchanged
                credential = exchanged
            }
            let enriched = await api.enrichDynamicIpLocations(
                items: baseItems,
                credential: requestCredential
            )
            guard !Task.isCancelled else { return }
            let enrichedByID = Dictionary(uniqueKeysWithValues: enriched.map { ($0.id, $0) })
            dynamics = dynamics.map { dynamic in
                guard let enrichedItem = enrichedByID[dynamic.id] else { return dynamic }
                if let normalized = JSONParser.normalizeIpLocation(enrichedItem.ipLocation) {
                    return dynamic.withIpLocation(normalized)
                }
                if enrichedItem.ipLocation == nil, dynamic.ipLocation != nil {
                    return dynamic.withIpLocation(nil)
                }
                return dynamic
            }
            applyProfileIpLocation(Self.resolveProfileIpFromDynamics(dynamics))
        }
    }

    func syncCredential(_ credential: BilibiliCredential?) {
        self.credential = credential
    }

    private func restoreOwnProfileCacheIfNeeded() {
        guard viewerMid == mid, mid > 0 else { return }
        guard let cached = spaceStore.read(mid: mid) else { return }
        applyCachedSpace(cached)
    }

    private func applyCachedSpace(_ cached: CachedProfileSpace) {
        profile = cached.profile
        videos = cached.videos
        dynamics = cached.dynamics
        videoSort = cached.videoSort
        videosHasMore = cached.videosHasMore
        dynamicsHasMore = cached.dynamicsHasMore
        dynamicsOffset = cached.dynamicsOffset
        hasCachedContent = cached.profile != nil || !cached.videos.isEmpty || !cached.dynamics.isEmpty
        if hasCachedContent {
            loading = false
        }
    }

    private func persistOwnProfileCache() {
        guard isOwnProfile else { return }
        guard profile != nil || !videos.isEmpty || !dynamics.isEmpty else { return }
        let space = CachedProfileSpace(
            mid: mid,
            profile: profile,
            videos: videos,
            dynamics: dynamics,
            videoSort: videoSort,
            videosHasMore: videosHasMore,
            dynamicsHasMore: dynamicsHasMore,
            dynamicsOffset: dynamicsOffset
        )
        spaceStore.save(space)
        onPersistSpace?(space)
        hasCachedContent = true
    }

    func refreshProfileIpLocationIfNeeded() async {
        guard JSONParser.normalizeIpLocation(profile?.ipLocation) == nil else { return }

        var requestCredential = credential
        if let current = requestCredential {
            let exchanged = await api.exchangeAccessKey(current)
            requestCredential = exchanged
            credential = exchanged
        }

        let ipLocation = await api.userSpaceIpLocation(
            mid: mid,
            seedDynamics: dynamics,
            credential: requestCredential
        )
        applyProfileIpLocation(ipLocation)
    }

    private func scheduleProfileIpRefresh() {
        profileIpRefreshTask?.cancel()
        guard JSONParser.normalizeIpLocation(profile?.ipLocation) == nil else {
            profileIpRefreshTask = nil
            return
        }

        profileIpRefreshTask = Task { @MainActor [weak self] in
            await self?.refreshProfileIpLocationIfNeeded()
        }
    }
}

struct UserProfileChromeInfo: Equatable {
    let faceURL: URL?
    let name: String
    let level: Int
    let sign: String
    let ipLocation: String?
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
    let showLogoutButton: Bool
}

struct UserProfileChromeMeasuredHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

enum ProfileChromeCapsuleMetrics {
    static let height: CGFloat = 48
    static let horizontalPadding: CGFloat = 14
    static let selectedInset: CGFloat = 6
    static let statColumnCount: CGFloat = 4
    static let barWidth: CGFloat = 300

    static let fillColor = Color(red: 245 / 255, green: 245 / 255, blue: 245 / 255)
    static let borderColor = Color.black.opacity(0.06)
    static let borderLineWidth: CGFloat = 0.5
    static let shadowColor = Color.black.opacity(0.08)
    static let shadowRadius: CGFloat = 10
    static let shadowX: CGFloat = 0
    static let shadowY: CGFloat = 4
}

struct UserProfileChromeHeaderView: View {
    let info: UserProfileChromeInfo
    var showsBackButton = false
    var onBack: () -> Void = {}
    var onFollow: () -> Void = {}
    var onUnfollow: () -> Void = {}
    var onLogout: () -> Void = {}
    var onFollowingTap: (() -> Void)?
    var onFollowersTap: (() -> Void)?
    var onReload: (() -> Void)? = nil
    var isReloadDisabled = false

    private let primaryText = Color(red: 0.11, green: 0.11, blue: 0.12)
    private let secondaryText = Color(red: 0.39, green: 0.39, blue: 0.4)
    private let cardCornerRadius: CGFloat = 22

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if showsBackButton {
                GlassBackButton(action: onBack)
            }

            HStack(alignment: .top, spacing: 12) {
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

                        if let ipLocation = info.ipLocation, !ipLocation.isEmpty {
                            Text("IP属地：\(ipLocation)")
                                .font(.callout)
                                .foregroundStyle(secondaryText)
                                .lineLimit(1)
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

            if info.showLogoutButton {
                GlassSettingsButton(onLogout: onLogout)
            }

            if let onReload {
                GlassRefreshButton(action: onReload)
                    .disabled(isReloadDisabled)
                    .opacity(isReloadDisabled ? 0.45 : 1)
            }
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

    private var statsColumnWidth: CGFloat {
        let innerWidth = ProfileChromeCapsuleMetrics.barWidth
            - ProfileChromeCapsuleMetrics.horizontalPadding * 2
        return max(0, innerWidth / ProfileChromeCapsuleMetrics.statColumnCount)
    }

    private var borderedChromeBody: some View {
        HStack(spacing: 0) {
            ProfileStatItem(
                title: "关注",
                value: following?.compactCount ?? "-",
                primaryText: primaryText,
                secondaryText: secondaryText,
                fixedWidth: statsColumnWidth,
                fixedHeight: ProfileChromeCapsuleMetrics.height,
                leadingHoverExtension: ProfileChromeCapsuleMetrics.horizontalPadding,
                action: onFollowingTap
            )
            ProfileStatItem(
                title: "粉丝",
                value: follower?.compactCount ?? "-",
                primaryText: primaryText,
                secondaryText: secondaryText,
                fixedWidth: statsColumnWidth,
                fixedHeight: ProfileChromeCapsuleMetrics.height,
                action: onFollowersTap
            )
            ProfileStatItem(
                title: "获赞",
                value: likes?.compactCount ?? "-",
                primaryText: primaryText,
                secondaryText: secondaryText,
                fixedWidth: statsColumnWidth,
                fixedHeight: ProfileChromeCapsuleMetrics.height
            )
            ProfileStatItem(
                title: "投稿",
                value: videoCount?.compactCount ?? "-",
                primaryText: primaryText,
                secondaryText: secondaryText,
                fixedWidth: statsColumnWidth,
                fixedHeight: ProfileChromeCapsuleMetrics.height
            )
        }
        .padding(.horizontal, ProfileChromeCapsuleMetrics.horizontalPadding)
        .frame(width: ProfileChromeCapsuleMetrics.barWidth, height: ProfileChromeCapsuleMetrics.height)
        .background {
            Capsule(style: .continuous)
                .fill(ProfileChromeCapsuleMetrics.fillColor)
        }
        .overlay {
            Capsule(style: .continuous)
                .stroke(
                    ProfileChromeCapsuleMetrics.borderColor,
                    lineWidth: ProfileChromeCapsuleMetrics.borderLineWidth
                )
        }
        .shadow(
            color: ProfileChromeCapsuleMetrics.shadowColor,
            radius: ProfileChromeCapsuleMetrics.shadowRadius,
            x: ProfileChromeCapsuleMetrics.shadowX,
            y: ProfileChromeCapsuleMetrics.shadowY
        )
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
    @Environment(\.profileNavigationDepth) private var navigationDepth
    @StateObject private var model: UserProfileModel
    @State private var publishesFloatingChrome = false
    @State private var chromeNavigationDepth: Int?

    private let columnInnerPadding: CGFloat = 14
    private let profileSectionHeaderHeight: CGFloat = 48
    private let profileDynamicColumnWidthRatio: CGFloat = 0.24

    private var videoColumnTrailingInset: CGFloat {
        columnInnerPadding + AppLayout.feedOverlayScrollbarWidth
    }

    private var dynamicColumnTrailingInset: CGFloat {
        columnInnerPadding
    }

    private func columnContentWidth(for columnWidth: CGFloat, trailingInset: CGFloat) -> CGFloat {
        max(0, columnWidth - columnInnerPadding - trailingInset)
    }

    init(
        mid: Int64,
        credential: BilibiliCredential?,
        viewerMid: Int64? = nil,
        seedSpace: CachedProfileSpace? = nil,
        onPersistSpace: ((CachedProfileSpace) -> Void)? = nil
    ) {
        _model = StateObject(
            wrappedValue: UserProfileModel(
                mid: mid,
                credential: credential,
                viewerMid: viewerMid,
                seedSpace: seedSpace,
                onPersistSpace: onPersistSpace
            )
        )
    }

    var body: some View {
        GeometryReader { geometry in
            let contentWidth = geometry.size.width - AppLayout.videoDetailLeadingInset
            let dividerWidth: CGFloat = 0.5
            let splitWidth = contentWidth - dividerWidth
            let dynamicColumnWidth = splitWidth * profileDynamicColumnWidthRatio
            let videoColumnWidth = splitWidth - dynamicColumnWidth
            let contentTopInset = AppLayout.userProfileContentTopInset(chromeHeight: chromeHeight)
            let videoContentWidth = columnContentWidth(
                for: videoColumnWidth,
                trailingInset: videoColumnTrailingInset
            )

            VStack(alignment: .leading, spacing: 0) {
                Color.clear
                    .frame(height: contentTopInset)

                HStack(alignment: .top, spacing: 0) {
                    profileScrollColumn(width: videoColumnWidth) {
                        videoSectionHeader
                            .padding(.leading, columnInnerPadding)
                            .padding(.trailing, videoColumnTrailingInset)
                    } content: {
                        videosScrollContent
                            .padding(.leading, columnInnerPadding)
                            .padding(.trailing, videoColumnTrailingInset)
                            .environment(\.feedViewportWidth, videoContentWidth)
                            .environment(\.feedUsesDirectViewportWidth, true)
                    }

                    Rectangle()
                        .fill(Color.black.opacity(0.08))
                        .frame(width: dividerWidth)

                    profileScrollColumn(width: dynamicColumnWidth) {
                        dynamicSectionHeader
                            .padding(.leading, columnInnerPadding)
                            .padding(.trailing, dynamicColumnTrailingInset)
                    } content: {
                        dynamicsScrollContent
                            .padding(.leading, columnInnerPadding)
                            .padding(.trailing, dynamicColumnTrailingInset)
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
        .onChange(of: appModel.account?.credential.accessKey) { _, _ in
            model.syncCredential(appModel.account?.credential)
            Task { await model.refreshProfileIpLocationIfNeeded() }
        }
        .onAppear {
            chromeNavigationDepth = navigationDepth
            model.syncCredential(appModel.account?.credential)
            Task { await model.load() }
            syncProfileChromePublishing()
            MediaPlaybackCoordinator.shared.notifyObscuringPageVisible()
        }
        .onDisappear {
            chromeNavigationDepth = nil
            publishesFloatingChrome = false
            appModel.popProfileFloatingChrome(ownerMid: model.mid)
            appModel.restoreRelationListChrome()
            MediaPlaybackCoordinator.shared.notifyObscuringPageHidden()
        }
        .onChange(of: navigationDepth) { _, _ in
            syncProfileChromePublishing()
        }
        .onChange(of: model.profile) { _, _ in updateFloatingProfileChrome() }
        .onChange(of: model.relation.following) { _, _ in updateFloatingProfileChrome() }
        .onChange(of: model.followLoading) { _, _ in updateFloatingProfileChrome() }
        .onChange(of: model.loading) { _, _ in updateFloatingProfileChrome() }
        .onChange(of: appModel.account?.name) { _, _ in updateFloatingProfileChrome() }
        .onChange(of: appModel.account?.faceURLString) { _, _ in updateFloatingProfileChrome() }
        .onChange(of: appModel.activeFloatingChromeKind) { _, kind in
            guard kind == .profile else { return }
            syncProfileChromePublishing()
        }
    }

    private var managesProfileChrome: Bool {
        guard let chromeNavigationDepth else { return false }
        return navigationDepth == chromeNavigationDepth
    }

    private func syncProfileChromePublishing() {
        if managesProfileChrome {
            publishesFloatingChrome = true
            publishProfileFloatingChrome()
            publishProfilePageHandlers()
        } else {
            publishesFloatingChrome = false
        }
    }

    private func updateFloatingProfileChrome() {
        guard managesProfileChrome else { return }
        publishProfileFloatingChrome()
    }

    private func publishProfileFloatingChrome() {
        appModel.presentProfileFloatingChrome(profileChromePreference, ownerMid: model.mid)
    }

    private func publishProfilePageHandlers() {
        appModel.profilePageHandlers = ProfilePageHandlers(
            follow: { Task { await model.followAuthor() } },
            unfollow: { Task { await model.unfollowAuthor() } },
            openRelationList: { tab in
                let chrome = Self.resolvedChromeInfo(model: model, account: appModel.account)
                appModel.requestUserRelationList(
                    UserRelationListRequest(
                        hostMid: model.mid,
                        hostName: chrome.name,
                        hostFaceURL: chrome.faceURL,
                        hostSign: chrome.sign,
                        initialTab: tab
                    )
                )
            },
            reload: {
                Task { @MainActor in
                    await model.load()
                    // Always republish floating header after refresh. Videos/dynamics
                    // update via @Published on the page model; chrome lives in AppModel
                    // and can stay stale when field-level onChange does not fire.
                    appModel.presentProfileFloatingChrome(
                        Self.resolvedChromeInfo(model: model, account: appModel.account),
                        ownerMid: model.mid
                    )
                }
            },
            logout: model.isOwnProfile ? { appModel.logout() } : nil
        )
    }

    private var profileChromePreference: UserProfileChromeInfo? {
        Self.resolvedChromeInfo(model: model, account: appModel.account)
    }

    /// Own-profile chrome falls back to the logged-in account so avatar/ID still
    /// show when space API data has not arrived (or failed to publish).
    private static func resolvedChromeInfo(
        model: UserProfileModel,
        account: BiliAccount?
    ) -> UserProfileChromeInfo {
        let base = model.chromeInfo
        guard model.isOwnProfile, let account else { return base }
        let name = base.name.isEmpty ? account.name : base.name
        let faceURL = base.faceURL ?? account.faceURL
        guard name != base.name || faceURL != base.faceURL else { return base }
        return UserProfileChromeInfo(
            faceURL: faceURL,
            name: name,
            level: base.level,
            sign: base.sign,
            ipLocation: base.ipLocation,
            following: base.following,
            follower: base.follower,
            likes: base.likes,
            videoCount: base.videoCount,
            webURL: base.webURL,
            showFollowButton: base.showFollowButton,
            isFollowing: base.isFollowing,
            followerMe: base.followerMe,
            followerCount: base.followerCount,
            followLoading: base.followLoading,
            showLogoutButton: base.showLogoutButton
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
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .topLeading)
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
        if (model.loading || model.videosLoading) && model.videos.isEmpty {
            loadingPlaceholder(title: "正在加载投稿")
        } else if model.videos.isEmpty {
            ContentUnavailableView("暂无投稿", systemImage: "video.slash")
                .padding(.vertical, 40)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                VideoFeedGrid(
                    videos: model.videos,
                    largeTypography: true,
                    showsAuthor: false,
                    usesCardSurface: false,
                    resolveWatchProgress: appModel.account != nil
                )

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
        if (model.loading || model.dynamicsLoading) && model.dynamics.isEmpty {
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
                DynamicImageGrid(urls: imageURLs, maxCount: 4)
            }
        }
    }
}

private struct DynamicVideoPreview: View {
    let video: BiliVideo
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        VideoPlaybackLink(
            video: video,
            resolveWatchProgress: appModel.account != nil
        ) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottomTrailing) {
                    RemoteCover(
                        url: video.coverURL,
                        aspectRatio: VideoCardLayout.coverAspect,
                        cornerRadius: 8,
                        scalesToFill: false,
                        matchesImageAspectRatio: true
                    )
                    .frame(maxWidth: .infinity)

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

struct DynamicImageGrid: View {
    let urls: [URL]
    var maxCount = 9

    private let spacing: CGFloat = 6
    private let cornerRadius: CGFloat = 8

    private var displayURLs: [URL] {
        Array(urls.prefix(maxCount))
    }

    private var columnCount: Int {
        switch displayURLs.count {
        case 0: return 1
        case 1: return 1
        case 2, 4: return 2
        default: return 3
        }
    }

    private var rowCount: Int {
        guard !displayURLs.isEmpty else { return 0 }
        return (displayURLs.count + columnCount - 1) / columnCount
    }

    var body: some View {
        if displayURLs.isEmpty {
            EmptyView()
        } else if displayURLs.count == 1, let url = displayURLs.first {
            gridCell(url: url, aspectRatio: 16 / 9)
        } else {
            VStack(spacing: spacing) {
                ForEach(0..<rowCount, id: \.self) { row in
                    HStack(spacing: spacing) {
                        ForEach(0..<columnCount, id: \.self) { column in
                            let index = row * columnCount + column
                            if index < displayURLs.count {
                                gridCell(url: displayURLs[index], aspectRatio: 1)
                                    .frame(maxWidth: .infinity)
                            } else {
                                Color.clear
                                    .aspectRatio(1, contentMode: .fit)
                                    .frame(maxWidth: .infinity)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func gridCell(url: URL, aspectRatio: CGFloat) -> some View {
        Color.clear
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        Color.secondary.opacity(0.08)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

private struct DynamicFeedMetaRow: View {
    let item: BiliDynamicItem
    let video: BiliVideo?

    private let metaColor = Color.secondary.opacity(0.58)

    var body: some View {
        let hasPlayStats = video != nil && (video!.viewCount > 0 || video!.danmakuCount > 0)
        let timeText = BiliCommentFormats.formatTime(item.publishDate)
        let ipText = JSONParser.normalizeIpLocation(item.ipLocation).map { "IP属地：\($0)" }
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
