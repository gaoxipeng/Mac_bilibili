import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = AppModel()
    @State private var navigationPath = NavigationPath()
    @State private var detailChromeHeight: CGFloat = 0
    @State private var profileChromeHeaderHeight: CGFloat = 0
    @State private var relationChromeHeaderHeight: CGFloat = 0

    private var effectiveChromeHeight: CGFloat {
        switch model.activeFloatingChromeKind {
        case .profile:
            return AppLayout.userProfileFloatingChromeHeight(headerHeight: profileChromeHeaderHeight)
        case .video:
            let measured = detailChromeHeight > 0 ? min(detailChromeHeight, 220) : 0
            return AppLayout.videoDetailPlayerTopInset(chromeHeight: measured)
        case .relationList:
            return AppLayout.userRelationFloatingChromeHeight(headerHeight: relationChromeHeaderHeight)
        case nil:
            if !navigationPath.isEmpty {
                return AppLayout.floatingChromeBackOnlyHeight
            }
            return 0
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebarPane
            mainPane
                .ignoresSafeArea(edges: .top)
        }
        .configureTransparentWindow()
        .task {
            await model.loadInitialData()
        }
        .environmentObject(model)
        .onChange(of: model.selectedSection) { oldValue, newValue in
            guard oldValue != newValue else { return }
            navigationPath = NavigationPath()
            model.clearFloatingChrome()
            model.clearProfilePageHandlers()
            VideoFullscreenPresenter.restoreMainWindowAppearance()
            MediaPlaybackCoordinator.shared.stopAll()
            if newValue != .search {
                model.isSearchShowingResults = false
            }
            Task { await model.reloadSelectedIfNeeded() }
        }
        .frame(minWidth: 1040, minHeight: 680)
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbarBackgroundVisibility(.hidden, for: .automatic)
    }

    private var mainPane: some View {
        ZStack(alignment: .top) {
            NavigationStack(path: $navigationPath) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .navigationDestination(for: VideoPlaybackRequest.self) { request in
                        VideoDetailView(
                            video: request.video,
                            credential: model.account?.credential,
                            initialProgressSeconds: request.progressSeconds,
                            playbackEpid: request.epid,
                            playbackRefererURL: request.refererURL
                        )
                    }
                    .navigationDestination(for: UserProfileRequest.self) { request in
                        UserProfileView(
                            mid: request.mid,
                            credential: model.account?.credential,
                            viewerMid: model.account.flatMap { Int64($0.uid) }
                        )
                        .environmentObject(model)
                    }
                    .navigationDestination(for: DynamicDetailRequest.self) { request in
                        DynamicDetailView(
                            item: request.item,
                            credential: model.account?.credential
                        )
                        .environmentObject(model)
                    }
                    .navigationDestination(for: UserRelationListRequest.self) { request in
                        UserRelationListView(
                            request: request,
                            navigationPath: $navigationPath,
                            credential: model.account?.credential,
                            viewerMid: model.account.flatMap { Int64($0.uid) }
                        )
                        .environmentObject(model)
                    }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.videoDetailChromeHeight, effectiveChromeHeight)

            DetailFloatingChrome(
                model: model,
                navigationPath: $navigationPath,
                canGoBack: !navigationPath.isEmpty,
                canExitSearchResults: model.isSearchShowingResults
                    && navigationPath.isEmpty
                    && model.selectedSection == .search,
                onExitSearchResults: {
                    model.requestExitSearchResults()
                }
            )
        }
        .onPreferenceChange(UserProfileChromeMeasuredHeightKey.self) { profileChromeHeaderHeight = $0 }
        .onPreferenceChange(VideoDetailChromeMeasuredHeightKey.self) { detailChromeHeight = $0 }
        .onPreferenceChange(UserRelationChromeMeasuredHeightKey.self) { relationChromeHeaderHeight = $0 }
        .onChange(of: model.selectedSection) { _, _ in
            detailChromeHeight = 0
            profileChromeHeaderHeight = 0
            relationChromeHeaderHeight = 0
        }
        .onChange(of: model.floatingVideoChrome) { _, chrome in
            if chrome == nil {
                detailChromeHeight = 0
            }
        }
        .onChange(of: model.activeFloatingChromeKind) { _, kind in
            if kind != .video {
                detailChromeHeight = 0
            }
            if kind != .relationList {
                relationChromeHeaderHeight = 0
            }
        }
        .onChange(of: navigationPath.count) { _, count in
            if count == 0 {
                detailChromeHeight = 0
                profileChromeHeaderHeight = 0
                relationChromeHeaderHeight = 0
                model.handleReturnedToRootNavigation()
                if model.selectedSection != .mine {
                    model.clearProfilePageHandlers()
                }
                VideoFullscreenPresenter.restoreMainWindowAppearance()
                MediaPlaybackCoordinator.shared.stopAll()
                Task { await model.refreshSectionAfterReturningFromDetail() }
            }
        }
        .onChange(of: model.pendingUserRelationListRequest) { _, request in
            guard let request else { return }
            navigationPath.append(request)
            model.pendingUserRelationListRequest = nil
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                MediaPlaybackCoordinator.shared.handleSceneBecameActive()
            default:
                MediaPlaybackCoordinator.shared.suspendAll()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
    }

    private var sidebarPane: some View {
        Sidebar(model: model, selection: $model.selectedSection)
            .frame(width: AppLayout.sidebarWidth)
            .frame(maxHeight: .infinity)
            .background(AppLayout.sidebarBackgroundColor)
            .background(SidebarWindowDragExclusionView())
    }

    @ViewBuilder
    private var content: some View {
        switch model.selectedSection {
        case .search:
            SearchDashboard(model: model, navigationPath: $navigationPath)
        case .home:
            VideoGridView(
                videos: model.homeVideos,
                loading: model.isSectionLoading(.home),
                error: model.errorMessage,
                emptyTitle: "暂无推荐内容",
                compactHeader: true,
                showsPageHeader: false,
                loadingMore: model.homeLoadingMore,
                hasMore: model.homeHasMore,
                onLoadMore: {
                    Task { await model.loadMoreHome() }
                }
            )
        case .following:
            FollowingView(
                videos: model.followingVideos,
                loading: model.isSectionLoading(.following),
                loadingMore: model.followingLoadingMore,
                hasMore: model.followingHasMore,
                error: model.errorMessage,
                loggedIn: model.account != nil,
                onLoadMore: {
                    Task { await model.loadMoreFollowing() }
                }
            )
        case .hot:
            VideoGridView(
                videos: model.hotVideos,
                loading: model.isSectionLoading(.hot),
                error: model.errorMessage,
                emptyTitle: "排行榜为空",
                showsPageHeader: false
            )
        case .history:
            HistoryView(
                items: model.historyItems,
                loading: model.isSectionLoading(.history),
                loadingMore: model.historyLoadingMore,
                hasMore: model.historyHasMore,
                error: model.errorMessage,
                loggedIn: model.account != nil,
                onLoadMore: {
                    Task { await model.loadMoreHistory() }
                },
                onDelete: { item in
                    Task { await model.deleteHistoryItem(item) }
                }
            )
        case .favorites:
            FavoritesView(
                videos: model.favoriteVideos,
                loading: model.isSectionLoading(.favorites),
                loadingMore: model.favoriteLoadingMore,
                hasMore: model.favoriteHasMore,
                error: model.errorMessage,
                loggedIn: model.account != nil,
                onLoadMore: {
                    Task { await model.loadMoreFavorites() }
                }
            )
        case .scrollTest:
            ScrollPerformanceTestView()
        case .mine:
            MineView()
        }
    }
}

private struct DetailFloatingChrome: View {
    @ObservedObject var model: AppModel
    @Binding var navigationPath: NavigationPath
    let canGoBack: Bool
    let canExitSearchResults: Bool
    let onExitSearchResults: () -> Void

    private var detailChrome: VideoDetailChromeInfo? {
        model.activeFloatingChromeKind == .video ? model.floatingVideoChrome : nil
    }

    private var profileChrome: UserProfileChromeInfo? {
        model.activeFloatingChromeKind == .profile ? model.floatingProfileChrome : nil
    }

    private var relationChrome: UserRelationChromeInfo? {
        model.activeFloatingChromeKind == .relationList ? model.floatingRelationChrome : nil
    }

    private var showsFloatingBackButton: Bool {
        canExitSearchResults || canGoBack
    }

    private var showsDefaultChrome: Bool {
        detailChrome == nil && profileChrome == nil && relationChrome == nil
    }

    private var showsDefaultRefreshChrome: Bool {
        showsDefaultChrome && !showsFloatingBackButton
    }

    private var showsActiveChrome: Bool {
        detailChrome != nil || profileChrome != nil || relationChrome != nil
    }

    private var reportsFloatingChromeHeight: Bool {
        showsActiveChrome || (canGoBack && !canExitSearchResults)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            chromeContent
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, AppLayout.floatingChromeInset)
        .padding(.top, AppLayout.floatingChromeInset)
        .reportMeasuredHeight(
            to: VideoDetailChromeMeasuredHeightKey.self,
            when: reportsFloatingChromeHeight
        )
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .allowsHitTesting(showsActiveChrome || showsFloatingBackButton || canExitSearchResults || showsDefaultRefreshChrome)
        .animation(.easeOut(duration: 0.26), value: showsFloatingBackButton)
        .animation(.easeOut(duration: 0.26), value: canGoBack)
        .animation(.easeOut(duration: 0.26), value: detailChrome?.title)
        .animation(.easeOut(duration: 0.26), value: profileChrome?.name)
        .animation(.easeOut(duration: 0.26), value: relationChrome?.hostName)
        .animation(.easeOut(duration: 0.26), value: model.activeFloatingChromeKind)
    }

    @ViewBuilder
    private var chromeContent: some View {
        if let detailChrome {
            detailChromeRow(detailChrome)
        } else if let profileChrome {
            profileChromeRow(profileChrome)
        } else if let relationChrome {
            relationChromeRow(relationChrome)
        } else {
            defaultChromeRow
        }
    }

    @ViewBuilder
    private func detailChromeRow(_ detailChrome: VideoDetailChromeInfo) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if showsFloatingBackButton {
                profileBackButton
            }

            VideoDetailChromeHeaderView(info: detailChrome)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let webURL = detailChrome.webURL {
                GlassMoreButton(webURL: webURL)
            }
        }
    }

    @ViewBuilder
    private func profileChromeRow(_ profileChrome: UserProfileChromeInfo) -> some View {
        HStack(alignment: .top, spacing: 12) {
            UserProfileChromeHeaderView(
                info: profileChrome,
                showsBackButton: showsFloatingBackButton,
                onBack: {
                    if canGoBack {
                        if !navigationPath.isEmpty {
                            navigationPath.removeLast()
                        }
                    } else {
                        onExitSearchResults()
                    }
                },
                onFollow: { model.profilePageHandlers?.follow() },
                onUnfollow: { model.profilePageHandlers?.unfollow() },
                onFollowingTap: { model.profilePageHandlers?.openRelationList(.following) },
                onFollowersTap: { model.profilePageHandlers?.openRelationList(.followers) }
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            floatingRefreshButton
        }
    }

    @ViewBuilder
    private func relationChromeRow(_ relationChrome: UserRelationChromeInfo) -> some View {
        HStack(alignment: .center, spacing: 12) {
            if showsFloatingBackButton {
                profileBackButton
            }

            UserRelationHostSummaryView(info: relationChrome)
                .layoutPriority(1)

            Spacer(minLength: 16)

            BiliLiquidSegmentedControl(
                selection: Binding(
                    get: { model.relationListSelectedTab },
                    set: { model.setRelationListTab($0) }
                ),
                title: { $0.title }
            )
            .padding(.trailing, AppLayout.userRelationToggleTrailingInset)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: UserRelationChromeMeasuredHeightKey.self,
                    value: geometry.size.height
                )
            }
        }
    }

    @ViewBuilder
    private var defaultChromeRow: some View {
        HStack(alignment: .top, spacing: 12) {
            if showsFloatingBackButton {
                profileBackButton
            }

            Spacer(minLength: 0)

            floatingRefreshButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var floatingRefreshButton: some View {
        GlassRefreshButton {
            performRefresh()
        }
        .disabled(isRefreshDisabled)
        .opacity(isRefreshDisabled ? 0.45 : 1)
    }

    private var isRefreshDisabled: Bool {
        if model.profilePageHandlers != nil {
            return false
        }
        return model.isSectionLoading(model.selectedSection)
    }

    private func performRefresh() {
        if let reload = model.profilePageHandlers?.reload {
            reload()
            return
        }
        Task { await model.reloadSelected() }
    }

    @ViewBuilder
    private var profileBackButton: some View {
        GlassBackButton {
            if canGoBack {
                if !navigationPath.isEmpty {
                    navigationPath.removeLast()
                }
            } else {
                onExitSearchResults()
            }
        }
    }
}

private struct Sidebar: View {
    @ObservedObject var model: AppModel
    @Binding var selection: AppSection

    private var isMineSelected: Bool {
        selection == .mine
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: AppLayout.sidebarNavItemSpacing) {
                ForEach(AppSection.primaryCases) { section in
                    SidebarButton(
                        section: section,
                        selected: selection == section
                    ) {
                        select(section)
                    }
                }
            }
            .padding(.top, AppLayout.sidebarNavTopInset)

            Spacer(minLength: 0)

            Button {
                select(.mine)
            } label: {
                RemoteAvatar(
                    url: model.account?.faceURL,
                    size: 34,
                    foreground: Color(red: 0.45, green: 0.45, blue: 0.48),
                    background: Color.white.opacity(0.72),
                    border: isMineSelected ? BiliTheme.pink.opacity(0.55) : Color.black.opacity(0.08)
                )
                .overlay {
                    if isMineSelected {
                        Circle()
                            .stroke(BiliTheme.pink, lineWidth: 1.5)
                            .padding(-2)
                    }
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.bottom, AppLayout.sidebarBottomInset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func select(_ section: AppSection) {
        if section == .search {
            model.requestSearchFocus()
        }
        selection = section
    }
}

private struct SidebarButton: View {
    let section: AppSection
    let selected: Bool
    let action: () -> Void

    @State private var isHovered = false

    private var iconColor: Color {
        (selected || isHovered) ? BiliTheme.pink : BiliTheme.actionInactive
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                BiliSidebarIcon(section: section, color: iconColor, size: 22)
                Text(section.title)
                    .font(.system(size: AppLayout.sidebarNavLabelSize, weight: selected ? .semibold : .regular))
                    .foregroundStyle(iconColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity)
            .frame(height: AppLayout.sidebarNavItemHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct SidebarWindowDragExclusionView: NSViewRepresentable {
    func makeNSView(context: Context) -> SidebarWindowDragExclusionNSView {
        SidebarWindowDragExclusionNSView()
    }

    func updateNSView(_ nsView: SidebarWindowDragExclusionNSView, context: Context) {}
}

private final class SidebarWindowDragExclusionNSView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
}

#Preview {
    ContentView()
}
