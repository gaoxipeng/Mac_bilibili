import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = AppModel()
    @State private var sidebarSelection: AppSection? = .home
    @State private var navigationPath = NavigationPath()
    @State private var detailChrome: VideoDetailChromeInfo?
    @State private var detailChromeHeight: CGFloat = 0
    @State private var profileChrome: UserProfileChromeInfo?

    var body: some View {
        HStack(spacing: 0) {
            sidebarPane
            mainPane
        }
        .configureTransparentWindow()
        .ignoresSafeArea(edges: .top)
        .task {
            await model.loadInitialData()
        }
        .environmentObject(model)
        .onChange(of: sidebarSelection) { _, newValue in
            guard let newValue else {
                sidebarSelection = model.selectedSection
                return
            }
            guard newValue != model.selectedSection else { return }
            model.selectedSection = newValue
        }
        .onChange(of: model.selectedSection) { oldValue, newValue in
            guard oldValue != newValue else { return }
            sidebarSelection = newValue
            navigationPath = NavigationPath()
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
                            seedName: request.seedName,
                            seedFaceURL: request.seedFaceURL,
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
                    }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onPreferenceChange(VideoDetailChromePreferenceKey.self) { detailChrome = $0 }
            .onPreferenceChange(VideoDetailChromeMeasuredHeightKey.self) { detailChromeHeight = $0 }
            .onPreferenceChange(UserProfileChromePreferenceKey.self) { profileChrome = $0 }
            .environment(\.videoDetailChromeHeight, detailChromeHeight)

            DetailFloatingChrome(
                model: model,
                navigationPath: $navigationPath,
                canGoBack: !navigationPath.isEmpty,
                canExitSearchResults: model.isSearchShowingResults
                    && navigationPath.isEmpty
                    && model.selectedSection == .search,
                detailChrome: detailChrome,
                profileChrome: profileChrome,
                onExitSearchResults: {
                    model.requestExitSearchResults()
                }
            )
        }
        .onChange(of: navigationPath.count) { _, count in
            if count == 0 {
                detailChrome = nil
                detailChromeHeight = 0
                profileChrome = nil
                model.clearProfilePageHandlers()
                VideoFullscreenPresenter.restoreMainWindowAppearance()
                MediaPlaybackCoordinator.shared.stopAll()
                Task { await model.refreshSectionAfterReturningFromDetail() }
            }
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
        GlassSidebar(model: model, selection: $sidebarSelection)
            .frame(width: AppLayout.sidebarWidth)
            .frame(maxHeight: .infinity)
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
        case .mine:
            MineView(model: model)
        }
    }
}

private struct GlassSidebar: View {
    @ObservedObject var model: AppModel
    @Binding var selection: AppSection?

    var body: some View {
        Sidebar(model: model, selection: $selection)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .desktopBlurSidebarBackground()
    }
}

private struct DetailFloatingChrome: View {
    @ObservedObject var model: AppModel
    @Binding var navigationPath: NavigationPath
    let canGoBack: Bool
    let canExitSearchResults: Bool
    let detailChrome: VideoDetailChromeInfo?
    let profileChrome: UserProfileChromeInfo?
    let onExitSearchResults: () -> Void

    private var showsFloatingBackButton: Bool {
        canExitSearchResults || (canGoBack && (detailChrome != nil || profileChrome != nil))
    }

    var body: some View {
        Group {
            if let detailChrome {
                detailChromeRow(detailChrome)
            } else if let profileChrome {
                profileChromeRow(profileChrome)
            } else {
                defaultChromeRow
            }
        }
        .padding(.horizontal, AppLayout.floatingChromeInset)
        .padding(.top, AppLayout.floatingChromeInset)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: VideoDetailChromeMeasuredHeightKey.self,
                    value: (detailChrome == nil && profileChrome == nil) ? 0 : geometry.size.height
                )
            }
        }
        .animation(.easeOut(duration: 0.26), value: showsFloatingBackButton)
        .animation(.easeOut(duration: 0.26), value: canGoBack)
        .animation(.easeOut(duration: 0.26), value: detailChrome?.title)
        .animation(.easeOut(duration: 0.26), value: profileChrome?.coverIsLight)
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
        HStack(alignment: .top, spacing: 14) {
            if showsFloatingBackButton {
                profileBackButton
                    .padding(.top, 10)
            }

            UserProfileChromeHeaderView(info: profileChrome)
                .frame(maxWidth: .infinity, alignment: .leading)

            profileChromeActions(profileChrome)
                .padding(.top, 10)
        }
    }

    @ViewBuilder
    private func profileChromeActions(_ profileChrome: UserProfileChromeInfo) -> some View {
        HStack(alignment: .center, spacing: 10) {
            if profileChrome.showFollowButton {
                AuthorFollowButton(
                    isFollowing: profileChrome.isFollowing,
                    followerCount: profileChrome.followerCount,
                    isLoading: profileChrome.followLoading,
                    onFollow: { model.profilePageHandlers?.follow() },
                    onUnfollow: { model.profilePageHandlers?.unfollow() }
                )
            }

            GlassMoreButton(webURL: profileChrome.webURL)
        }
    }

    @ViewBuilder
    private var defaultChromeRow: some View {
        HStack(alignment: .top, spacing: 12) {
            if !showsFloatingBackButton {
                Spacer()
            }

            if !showsFloatingBackButton {
                GlassRefreshButton {
                    Task { await model.reloadSelected() }
                }
                .disabled(model.isSectionLoading(model.selectedSection))
                .opacity(model.isSectionLoading(model.selectedSection) ? 0.45 : 1)
            }
        }
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
    @Binding var selection: AppSection?
    @State private var isMineHovered = false

    private var isMineSelected: Bool {
        selection == .mine
    }

    private var mineBackgroundFill: Color {
        if isMineSelected {
            return AppLayout.sidebarSelectionFill
        }
        if isMineHovered {
            return AppLayout.sidebarHoverFill
        }
        return .clear
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                ForEach(AppSection.primaryCases) { section in
                    SidebarButton(
                        section: section,
                        selected: selection == section
                    ) {
                        if section == .search {
                            model.requestSearchFocus()
                        }
                        selection = section
                    }
                }
            }
            .padding(.top, AppLayout.sidebarNavTopInset)
            .padding(.horizontal, 10)

            Spacer()

            Button {
                selection = .mine
            } label: {
                HStack(spacing: 10) {
                    RemoteAvatar(
                        url: model.account?.faceURL,
                        size: 30,
                        foreground: Color(red: 0.45, green: 0.45, blue: 0.48),
                        background: Color.white.opacity(0.72),
                        border: Color.black.opacity(0.06)
                    )

                    Text(model.account?.name ?? "我的")
                        .font(.system(size: 14, weight: isMineSelected ? .semibold : .regular))
                        .lineLimit(1)
                        .foregroundStyle(isMineSelected ? BiliTheme.pink : Color(red: 0.22, green: 0.22, blue: 0.24))

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .frame(height: AppLayout.sidebarNavItemHeight)
                .background(
                    mineBackgroundFill,
                    in: RoundedRectangle(cornerRadius: AppLayout.sidebarSelectionCornerRadius, style: .continuous)
                )
            }
            .buttonStyle(SidebarPressButtonStyle())
            .onHover { isMineHovered = $0 }
            .padding(.horizontal, 10)
            .padding(.bottom, 16)
        }
    }
}

private struct SidebarButton: View {
    let section: AppSection
    let selected: Bool
    let action: () -> Void

    @State private var isHovered = false

    private var iconColor: Color {
        selected ? BiliTheme.pink : BiliTheme.actionInactive
    }

    private var backgroundFill: Color {
        if selected {
            return AppLayout.sidebarSelectionFill
        }
        if isHovered {
            return AppLayout.sidebarHoverFill
        }
        return .clear
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                BiliSidebarIcon(section: section, color: iconColor, size: 18)
                Text(section.title)
                    .font(.system(size: 14, weight: selected ? .semibold : .regular))
                    .foregroundStyle(iconColor)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: AppLayout.sidebarNavItemHeight)
            .background(
                backgroundFill,
                in: RoundedRectangle(cornerRadius: AppLayout.sidebarSelectionCornerRadius, style: .continuous)
            )
        }
        .buttonStyle(SidebarPressButtonStyle())
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

private struct SidebarPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

#Preview {
    ContentView()
}
