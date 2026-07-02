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
    @Published var relation = BiliAuthorRelation()
    @Published var loading = true
    @Published var videosLoading = false
    @Published var videosLoadingMore = false
    @Published var errorMessage: String?
    @Published var videoSort: BiliUserVideoSort = .latestPublish
    @Published var followLoading = false

    @Published private(set) var videosHasMore = true
    private var videoPage = 1
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

    var isOwnProfile: Bool {
        guard let viewerMid, viewerMid > 0 else { return false }
        return viewerMid == mid
    }

    var showFollowButton: Bool {
        !isOwnProfile && credential != nil
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
            await reloadVideos()
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

    func changeSort(_ sort: BiliUserVideoSort) async {
        guard videoSort != sort else { return }
        videoSort = sort
        await reloadVideos()
    }

    func toggleFollow() async {
        guard let credential, !followLoading else { return }
        followLoading = true
        defer { followLoading = false }

        let target = !relation.following
        do {
            try await api.modifyFollow(mid: mid, follow: target, credential: credential)
            relation.following = target
            relation.followerMe = relation.followerMe && target
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct UserProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: UserProfileModel

    private let coverHeight: CGFloat = 280
    private let avatarSize: CGFloat = 96
    private let avatarOverlap: CGFloat = 54

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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                profileHeader

                Section {
                    videosSection
                        .padding(.horizontal, AppLayout.feedHorizontalInset)
                        .padding(.bottom, 28)
                } header: {
                    tabHeader
                        .padding(.horizontal, AppLayout.feedHorizontalInset)
                        .padding(.vertical, 12)
                        .background(Color.white)
                }
            }
        }
        .background(Color.white)
        .navigationBarBackButtonHidden(true)
        .task { await model.load() }
        .onAppear {
            MediaPlaybackCoordinator.shared.notifyObscuringPageVisible()
        }
        .onDisappear {
            MediaPlaybackCoordinator.shared.notifyObscuringPageHidden()
        }
    }

    private var profileHeader: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                ProfileCoverCarousel(urls: model.displayCoverURLs, height: coverHeight)

                HStack {
                    GlassBackButton { dismiss() }
                    Spacer()
                    if model.showFollowButton {
                        followButton
                    }
                }
                .padding(.top, AppLayout.floatingChromeReservedHeight + 10)
                .padding(.horizontal, AppLayout.floatingChromeInset)
            }

            profileIdentitySection
                .padding(.horizontal, AppLayout.feedHorizontalInset)
                .offset(y: -avatarOverlap)
                .padding(.bottom, -avatarOverlap)

            statsSection
                .padding(.horizontal, AppLayout.feedHorizontalInset)
                .padding(.top, 10)

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, AppLayout.feedHorizontalInset)
                    .padding(.top, 10)
            }
        }
    }

    private var profileIdentitySection: some View {
        HStack(alignment: .top, spacing: 18) {
            AsyncImage(url: model.displayFaceURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    Image(systemName: "person.fill")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: avatarSize, height: avatarSize)
            .background(Color.secondary.opacity(0.12), in: Circle())
            .clipShape(Circle())
            .overlay {
                Circle().stroke(Color.white, lineWidth: 4)
            }
            .shadow(color: .black.opacity(0.14), radius: 10, y: 4)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(model.displayName)
                        .font(.system(size: 30, weight: .bold))
                        .lineLimit(2)
                    if let level = model.profile?.level, level > 0 {
                        BiliUserLevelIcon(level: level, width: 30, height: 19)
                    }
                }

                if let ip = model.profile?.ipLocation, !ip.isEmpty {
                    Text("IP属地：\(ip)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Text(profileSign)
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 6)

            Spacer(minLength: 0)
        }
    }

    private var profileSign: String {
        let sign = model.profile?.sign ?? ""
        return sign.isEmpty ? "这个人很神秘，什么都没有写" : sign
    }

    private var statsSection: some View {
        HStack(spacing: 0) {
            spaceMetric(title: "关注", value: model.profile?.following.compactCount ?? "-")
            spaceMetric(title: "粉丝", value: model.profile?.follower.compactCount ?? "-")
            spaceMetric(title: "获赞", value: model.profile?.likes.compactCount ?? "-")
            spaceMetric(title: "投稿", value: model.profile?.videoCount.compactCount ?? "-")
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 8)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 0.5)
        }
    }

    private func spaceMetric(title: String, value: String) -> some View {
        VStack(spacing: 5) {
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var followButton: some View {
        Button {
            Task { await model.toggleFollow() }
        } label: {
            HStack(spacing: 6) {
                if model.followLoading {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(followTitle)
                    .font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay {
                Capsule().stroke(Color.white.opacity(0.35), lineWidth: 0.6)
            }
            .foregroundStyle(followForeground)
        }
        .buttonStyle(.plain)
        .disabled(model.followLoading)
    }

    private var followTitle: String {
        if model.relation.following {
            return model.relation.followerMe ? "已互粉" : "已关注"
        }
        return "+ 关注"
    }

    private var followForeground: Color {
        model.relation.following ? Color.primary : BiliTheme.pink
    }

    private var tabHeader: some View {
        HStack(spacing: 16) {
            Text("投稿")
                .font(.headline.weight(.semibold))
                .foregroundStyle(BiliTheme.pink)

            Spacer()

            Menu {
                ForEach(BiliUserVideoSort.allCases, id: \.self) { sort in
                    Button {
                        Task { await model.changeSort(sort) }
                    } label: {
                        if model.videoSort == sort {
                            Label(sort.title, systemImage: "checkmark")
                        } else {
                            Text(sort.title)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(model.videoSort.title)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.secondary.opacity(0.08), in: Capsule())
            }
            .menuStyle(.borderlessButton)
        }
    }

    private var videosSection: some View {
        Group {
            if model.loading || model.videosLoading {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("正在加载投稿")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 24)
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
    }
}

private struct ProfileCoverCarousel: View {
    let urls: [URL]
    let height: CGFloat

    private let interval: TimeInterval = 5.5
    private let transitionDuration: TimeInterval = 1.15

    @State private var currentIndex = 0
    @State private var revealProgress: CGFloat = 0
    @State private var isAnimating = false
    @State private var autoplayTask: Task<Void, Never>?

    private var hasMultiple: Bool { urls.count > 1 }

    private var nextIndex: Int {
        guard !urls.isEmpty else { return 0 }
        return (currentIndex + 1) % urls.count
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if urls.isEmpty {
                    coverPlaceholder
                } else if hasMultiple {
                    coverImage(urls[currentIndex])
                        .scaleEffect(isAnimating ? 1.04 : 1)
                        .animation(.easeInOut(duration: transitionDuration), value: isAnimating)

                    coverImage(urls[nextIndex])
                        .offset(x: geo.size.width * (1 - revealProgress))
                        .opacity(0.9 + revealProgress * 0.1)
                } else {
                    coverImage(urls[0])
                }

                if hasMultiple {
                    VStack {
                        Spacer()
                        pageIndicators
                            .padding(.bottom, 14)
                    }
                }
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipped()
        .onAppear { restartAutoplay() }
        .onDisappear { autoplayTask?.cancel() }
        .onChange(of: urls.map(\.absoluteString)) { _, _ in
            currentIndex = 0
            revealProgress = 0
            isAnimating = false
            restartAutoplay()
        }
    }

    private var pageIndicators: some View {
        HStack(spacing: 6) {
            ForEach(urls.indices, id: \.self) { index in
                Capsule()
                    .fill(Color.white.opacity(index == currentIndex ? 0.95 : 0.42))
                    .frame(width: index == currentIndex ? 18 : 6, height: 6)
                    .animation(.easeOut(duration: 0.24), value: currentIndex)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.18), in: Capsule())
    }

    @ViewBuilder
    private func coverImage(_ url: URL) -> some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFill()
            default:
                coverPlaceholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private var coverPlaceholder: some View {
        LinearGradient(
            colors: [
                BiliTheme.pink.opacity(0.28),
                BiliTheme.pink.opacity(0.12),
                Color.secondary.opacity(0.08)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
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
