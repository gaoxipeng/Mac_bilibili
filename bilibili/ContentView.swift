import SwiftUI

struct ContentView: View {
    @StateObject private var model = AppModel()
    @State private var sidebarSelection: AppSection? = .home
    @State private var navigationPath = NavigationPath()

    var body: some View {
        ZStack(alignment: .leading) {
            mainPane
            sidebarPane
        }
        .background(Color.white)
        .ignoresSafeArea(edges: .top)
        .task {
            await model.loadInitialData()
        }
        .onChange(of: sidebarSelection) { _, newValue in
            guard let newValue else {
                sidebarSelection = model.selectedSection
                return
            }
            model.selectedSection = newValue
        }
        .onChange(of: model.selectedSection) { _, _ in
            sidebarSelection = model.selectedSection
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
                    .navigationDestination(for: BiliVideo.self) { video in
                        VideoDetailView(video: video, credential: model.account?.credential)
                    }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.leading, AppLayout.sidebarWidth)

            DetailFloatingChrome(
                model: model,
                navigationPath: $navigationPath,
                canGoBack: !navigationPath.isEmpty
            )
            .padding(.leading, AppLayout.sidebarWidth)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            SearchDashboard(model: model)
        case .home:
            VideoGridView(
                title: "首页",
                subtitle: "来自 B 站首页推荐接口",
                videos: model.homeVideos,
                loading: model.isLoading,
                error: model.errorMessage,
                emptyTitle: "暂无推荐内容"
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
            .background(Color(white: 0.955))
    }
}

private struct DetailFloatingChrome: View {
    @ObservedObject var model: AppModel
    @Binding var navigationPath: NavigationPath
    let canGoBack: Bool

    var body: some View {
        HStack(spacing: 12) {
            if canGoBack {
                GlassBackButton {
                    if !navigationPath.isEmpty {
                        navigationPath.removeLast()
                    }
                }
            }

            Spacer()

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
        .frame(maxWidth: .infinity, alignment: .top)
        .animation(.smooth(duration: 0.32), value: canGoBack)
    }
}

private struct Sidebar: View {
    @ObservedObject var model: AppModel
    @Binding var selection: AppSection?

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
            .padding(.horizontal, 8)

            Spacer()

            Button {
                selection = .mine
            } label: {
                HStack(spacing: 8) {
                    AsyncImage(url: model.account?.faceURL) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        default:
                            Image(systemName: "person.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 30, height: 30)
                    .background(Color.white.opacity(0.55), in: Circle())
                    .clipShape(Circle())

                    Text(model.account?.name ?? "我的")
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                        .foregroundStyle(.primary)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                .background(selection == .mine ? Color.white.opacity(0.65) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
    }
}

private struct SidebarButton: View {
    let section: AppSection
    let selected: Bool
    let action: () -> Void

    private var iconColor: Color {
        selected ? BiliTheme.pink : BiliTheme.actionInactive
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                BiliSidebarIcon(section: section, color: iconColor, size: 20)
                Text(section.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(iconColor)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                selected ? Color.white.opacity(0.65) : Color.clear,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.5), lineWidth: 0.5)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ContentView()
}
