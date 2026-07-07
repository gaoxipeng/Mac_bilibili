import Combine
import SwiftUI

struct UserRelationChromeInfo: Equatable {
    let hostFaceURL: URL?
    let hostName: String
    let hostSign: String
}

struct UserRelationChromeMeasuredHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct UserRelationHostSummaryView: View {
    let info: UserRelationChromeInfo

    private let primaryText = Color(red: 0.11, green: 0.11, blue: 0.12)
    private let secondaryText = Color(red: 0.39, green: 0.39, blue: 0.4)

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            AsyncImage(url: info.hostFaceURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    Image(systemName: "person.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(secondaryText)
                }
            }
            .frame(width: 48, height: 48)
            .background(Color.black.opacity(0.06), in: Circle())
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(info.hostName.ifEmpty("UP主"))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(primaryText)
                    .lineLimit(1)

                if !info.hostSign.isEmpty {
                    Text(info.hostSign)
                        .font(.callout)
                        .foregroundStyle(secondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private let relationPageSize = 20
private let relationGuestMaxPage = 5

private func relationListHasMore(fetchedCount: Int, page: Int, isSelf: Bool) -> Bool {
    if fetchedCount < relationPageSize { return false }
    if isSelf { return true }
    return page < relationGuestMaxPage
}

@MainActor
final class UserRelationListModel: ObservableObject {
    let hostMid: Int64
    let tab: BiliUserRelationTab
    var credential: BilibiliCredential?
    let viewerMid: Int64?

    @Published private(set) var users: [BiliRelationUser] = []
    @Published private(set) var loading = false
    @Published private(set) var loadingMore = false
    @Published private(set) var hasMore = true
    @Published private(set) var errorMessage: String?

    @Published private(set) var followLoadingMid: Int64?

    private var page = 1
    private let api = BilibiliAPI()
    private var loadTask: Task<Void, Never>?

    init(
        hostMid: Int64,
        tab: BiliUserRelationTab,
        credential: BilibiliCredential?,
        viewerMid: Int64?
    ) {
        self.hostMid = hostMid
        self.tab = tab
        self.credential = credential
        self.viewerMid = viewerMid
    }

    deinit {
        loadTask?.cancel()
    }

    var isSelf: Bool {
        guard let viewerMid, viewerMid > 0 else { return false }
        return viewerMid == hostMid
    }

    func load(reset: Bool) async {
        if reset {
            guard !loading else { return }
        } else {
            guard !loading, !loadingMore, hasMore, errorMessage == nil else { return }
        }

        let targetPage = reset ? 1 : page + 1
        if reset {
            loading = true
            errorMessage = nil
        } else {
            loadingMore = true
        }

        defer {
            if reset {
                loading = false
            } else {
                loadingMore = false
            }
        }

        let result = await api.userRelationListPage(
            hostMid: hostMid,
            tab: tab,
            page: targetPage,
            pageSize: relationPageSize,
            credential: credential
        )

        if reset {
            errorMessage = result.errorMessage
            users = result.users
            page = targetPage
            hasMore = result.errorMessage == nil
                && relationListHasMore(
                    fetchedCount: result.users.count,
                    page: targetPage,
                    isSelf: isSelf
                )
        } else {
            if result.errorMessage != nil {
                return
            }
            let previousCount = users.count
            var merged = users
            let existing = Set(merged.map(\.mid))
            for user in result.users where !existing.contains(user.mid) {
                merged.append(user)
            }
            users = merged
            page = targetPage
            hasMore = relationListHasMore(
                fetchedCount: result.users.count,
                page: targetPage,
                isSelf: isSelf
            ) && merged.count > previousCount
        }
    }

    func reload() {
        loadTask?.cancel()
        loadTask = Task { await load(reset: true) }
    }

    func loadMoreIfNeeded() {
        loadTask?.cancel()
        loadTask = Task { await load(reset: false) }
    }

    func toggleFollow(for user: BiliRelationUser) async {
        guard let credential, user.mid != viewerMid else { return }
        guard followLoadingMid == nil else { return }

        let targetFollow = !user.relation.following
        let previousRelation = user.relation
        followLoadingMid = user.mid
        defer { followLoadingMid = nil }

        updateUser(mid: user.mid) { item in
            item.relation.following = targetFollow
        }

        do {
            try await api.modifyFollow(mid: user.mid, follow: targetFollow, credential: credential)
            if let updated = try? await api.userRelation(mid: user.mid, credential: credential) {
                updateUser(mid: user.mid) { item in
                    item.relation = updated
                }
            }
        } catch {
            updateUser(mid: user.mid) { item in
                item.relation = previousRelation
            }
        }
    }

    private func updateUser(mid: Int64, transform: (inout BiliRelationUser) -> Void) {
        users = users.map { user in
            guard user.mid == mid else { return user }
            var copy = user
            transform(&copy)
            return copy
        }
    }
}

struct UserRelationListView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.videoDetailChromeHeight) private var chromeHeight
    @Binding var navigationPath: NavigationPath

    let request: UserRelationListRequest
    let credential: BilibiliCredential?
    let viewerMid: Int64?

    @State private var selectedTab: BiliUserRelationTab
    @State private var navigationDepthOnAppear = 0

    init(
        request: UserRelationListRequest,
        navigationPath: Binding<NavigationPath>,
        credential: BilibiliCredential?,
        viewerMid: Int64?
    ) {
        self.request = request
        _navigationPath = navigationPath
        self.credential = credential
        self.viewerMid = viewerMid
        _selectedTab = State(initialValue: request.initialTab)
    }

    var body: some View {
        GeometryReader { geometry in
            let contentWidth = AppLayout.feedContentWidthSymmetric(viewportWidth: geometry.size.width)
            let userResultsContentWidth = max(
                0,
                contentWidth - AppLayout.searchUserResultsHorizontalInset * 2
            )
            let layout = AppLayout.searchUserResultLayout(contentWidth: userResultsContentWidth)

            VStack(alignment: .leading, spacing: 0) {
                Color.clear
                    .frame(height: contentTopInset)

                ZStack {
                    ForEach(BiliUserRelationTab.allCases) { tab in
                        UserRelationTabPage(
                            hostMid: request.hostMid,
                            tab: tab,
                            layout: layout,
                            credential: credential,
                            viewerMid: viewerMid
                        )
                        .opacity(selectedTab == tab ? 1 : 0)
                        .allowsHitTesting(selectedTab == tab)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .background(AppLayout.videoDetailPageBackground)
        }
        .navigationBarBackButtonHidden(true)
        .onAppear {
            navigationDepthOnAppear = navigationPath.count
            appModel.resignProfileFloatingChrome()
            appModel.presentRelationListChrome(
                relationChromeInfo,
                selectedTab: selectedTab,
                onTabChange: { selectedTab = $0 }
            )
        }
        .onDisappear {
            if navigationPath.count < navigationDepthOnAppear {
                appModel.dismissRelationListChrome()
                appModel.restoreProfileFloatingChrome()
            } else {
                appModel.suspendRelationListChrome()
            }
        }
    }

    private var relationChromeInfo: UserRelationChromeInfo {
        UserRelationChromeInfo(
            hostFaceURL: request.hostFaceURL,
            hostName: request.hostName,
            hostSign: request.hostSign
        )
    }

    private var contentTopInset: CGFloat {
        AppLayout.userRelationContentTopInset(chromeHeight: chromeHeight)
    }
}

private struct UserRelationTabPage: View {
    let hostMid: Int64
    let tab: BiliUserRelationTab
    let layout: SearchUserResultLayout
    let credential: BilibiliCredential?
    let viewerMid: Int64?

    @StateObject private var model: UserRelationListModel

    init(
        hostMid: Int64,
        tab: BiliUserRelationTab,
        layout: SearchUserResultLayout,
        credential: BilibiliCredential?,
        viewerMid: Int64?
    ) {
        self.hostMid = hostMid
        self.tab = tab
        self.layout = layout
        self.credential = credential
        self.viewerMid = viewerMid
        _model = StateObject(
            wrappedValue: UserRelationListModel(
                hostMid: hostMid,
                tab: tab,
                credential: credential,
                viewerMid: viewerMid
            )
        )
    }

    var body: some View {
        GeometryReader { geometry in
            let columns = Array(
                repeating: GridItem(.flexible(), spacing: AppLayout.searchUserResultColumnSpacing, alignment: .center),
                count: layout.columnCount
            )

            Group {
                if model.loading, model.users.isEmpty {
                    relationListCenteredState(in: geometry.size) {
                        ProgressView("正在加载\(tab.title)列表")
                    }
                } else if let errorMessage = model.errorMessage, model.users.isEmpty {
                    relationListCenteredState(in: geometry.size) {
                        ContentUnavailableView(errorMessage, systemImage: "person.2.slash")
                    }
                } else if model.users.isEmpty {
                    relationListCenteredState(in: geometry.size) {
                        ContentUnavailableView("暂无\(tab.title)", systemImage: "person.crop.circle")
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, alignment: .center, spacing: 10) {
                            ForEach(model.users) { user in
                                BiliRelationUserCapsuleRow(
                                    user: user,
                                    showFollowButton: credential != nil
                                        && viewerMid != nil
                                        && user.mid != viewerMid,
                                    isFollowLoading: model.followLoadingMid == user.mid,
                                    onFollow: {
                                        Task { await model.toggleFollow(for: user) }
                                    },
                                    onUnfollow: {
                                        Task { await model.toggleFollow(for: user) }
                                    }
                                )
                            }

                            if model.hasMore {
                                FeedLoadMoreFooter(
                                    anchorID: model.users.count,
                                    hasMore: model.hasMore,
                                    loadingMore: model.loadingMore,
                                    onLoadMore: {
                                        model.loadMoreIfNeeded()
                                    }
                                )
                                .gridCellColumns(layout.columnCount)
                            }
                        }
                        .frame(width: layout.gridWidth)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, AppLayout.searchUserResultsHorizontalInset)
                        .padding(.top, 16)
                        .padding(.bottom, 24)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .center)
        }
        .task(id: tab) {
            await model.load(reset: true)
        }
    }

    private func relationListCenteredState<Content: View>(
        in size: CGSize,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .multilineTextAlignment(.center)
            .frame(width: size.width, height: size.height, alignment: .center)
    }
}

private struct BiliRelationUserCapsuleRow: View {
    let user: BiliRelationUser
    let showFollowButton: Bool
    let isFollowLoading: Bool
    let onFollow: () -> Void
    let onUnfollow: () -> Void

    @State private var isHovered = false

    private var trimmedSign: String {
        user.sign.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            NavigationLink(value: UserProfileRequest(mid: user.mid)) {
                HStack(alignment: .center, spacing: 14) {
                    AsyncImage(url: user.faceURL) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        default:
                            Image(systemName: "person.fill")
                                .foregroundStyle(Color(red: 0.55, green: 0.55, blue: 0.58))
                        }
                    }
                    .frame(width: 48, height: 48)
                    .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 4) {
                        Text(user.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color(red: 0.12, green: 0.12, blue: 0.14))
                            .lineLimit(1)

                        Text("\(user.fanCount.compactCount) 粉丝")
                            .font(.system(size: 13))
                            .foregroundStyle(Color(red: 0.55, green: 0.55, blue: 0.58))
                            .lineLimit(1)

                        if !trimmedSign.isEmpty {
                            Text(trimmedSign)
                                .font(.system(size: 13))
                                .foregroundStyle(Color(red: 0.55, green: 0.55, blue: 0.58))
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showFollowButton {
                AuthorFollowButton(
                    isFollowing: user.relation.following,
                    followerMe: user.relation.followerMe,
                    followerCount: user.fanCount,
                    isLoading: isFollowLoading,
                    showsFollowerCount: false,
                    usesProfileChromeSizing: true,
                    fixedCapsuleHeight: 48,
                    onFollow: onFollow,
                    onUnfollow: onUnfollow
                )
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, showFollowButton ? 14 : 18)
        .frame(maxWidth: .infinity)
        .frame(height: AppLayout.searchUserResultCapsuleHeight)
        .background(capsuleBackground, in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .stroke(capsuleBorderColor, lineWidth: 0.8)
        }
        .shadow(
            color: .black.opacity(isHovered ? 0.06 : 0.025),
            radius: isHovered ? 10 : 4,
            x: 0,
            y: isHovered ? 4 : 2
        )
        .contentShape(Capsule(style: .continuous))
        .onHover { isHovered = $0 }
    }

    private var capsuleBackground: Color {
        isHovered ? AppLayout.searchChipHoverFill : Color.white
    }

    private var capsuleBorderColor: Color {
        isHovered ? Color.black.opacity(0.10) : AppLayout.searchSurfaceBorder
    }
}
