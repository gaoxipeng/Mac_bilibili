import SwiftUI

struct ContentView: View {
    @StateObject private var model = AppModel()
    @State private var sidebarSelection: AppSection? = .home
    @State private var navigationPath = NavigationPath()
    @State private var detailChrome: VideoDetailChromeInfo?

    var body: some View {
        HStack(spacing: 0) {
            sidebarPane
            mainPane
        }
        .background(Color.white)
        .configureTransparentWindow()
        .ignoresSafeArea(edges: .top)
        .task {
            await model.loadInitialData()
        }
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
                            initialProgressSeconds: request.progressSeconds
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
                    }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onPreferenceChange(VideoDetailChromePreferenceKey.self) { detailChrome = $0 }

            DetailFloatingChrome(
                model: model,
                navigationPath: $navigationPath,
                canGoBack: !navigationPath.isEmpty,
                detailChrome: detailChrome
            )
        }
        .onChange(of: navigationPath.count) { _, count in
            if count == 0 {
                detailChrome = nil
                VideoFullscreenPresenter.restoreMainWindowAppearance()
                Task { await model.refreshSectionAfterReturningFromDetail() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
    }

    private var sidebarPane: some View {
        GlassSidebar(model: model, selection: $sidebarSelection)
            .frame(width: AppLayout.sidebarWidth)
            .frame(maxHeight: .infinity)
            .background(AppLayout.sidebarBackground)
    }

    @ViewBuilder
    private var content: some View {
        switch model.selectedSection {
        case .search:
            SearchDashboard(model: model, navigationPath: $navigationPath)
        case .home:
            VideoGridView(
                videos: model.homeVideos,
                loading: model.isLoading,
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
                loading: model.isLoading,
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
                title: "排行",
                subtitle: "按播放、互动等指标排序",
                videos: model.hotVideos,
                loading: model.isLoading,
                error: model.errorMessage,
                emptyTitle: "排行榜为空"
            )
        case .history:
            HistoryView(
                items: model.historyItems,
                loading: model.isLoading,
                error: model.errorMessage,
                loggedIn: model.account != nil
            )
        case .favorites:
            FavoritesView(
                videos: model.favoriteVideos,
                loading: model.isLoading,
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
    let detailChrome: VideoDetailChromeInfo?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if canGoBack {
                GlassBackButton {
                    if !navigationPath.isEmpty {
                        navigationPath.removeLast()
                    }
                }
            }

            if let detailChrome {
                VideoDetailChromeHeaderView(info: detailChrome)
            } else if !canGoBack {
                Spacer()
            }

            if !canGoBack {
                GlassRefreshButton {
                    Task { await model.reloadSelected() }
                }
                .disabled(model.isLoading)
                .opacity(model.isLoading ? 0.45 : 1)
            }
        }
        .padding(.horizontal, AppLayout.floatingChromeInset)
        .padding(.top, AppLayout.floatingChromeInset)
        .padding(.trailing, AppLayout.floatingChromeInset)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .animation(.easeOut(duration: 0.26), value: canGoBack)
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
