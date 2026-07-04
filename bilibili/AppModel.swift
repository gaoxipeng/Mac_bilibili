import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var selectedSection: AppSection = .home
    @Published var homeVideos: [BiliVideo] = []
    @Published var homeHasMore = false
    @Published var homeLoadingMore = false
    @Published var followingVideos: [BiliVideo] = []
    @Published var followingHasMore = false
    @Published var followingLoadingMore = false
    @Published var hotVideos: [BiliVideo] = []
    @Published var historyItems: [BiliHistoryItem] = []
    @Published var historyHasMore = false
    @Published var historyLoadingMore = false
    @Published var favoriteVideos: [BiliVideo] = []
    @Published var favoriteHasMore = false
    @Published var favoriteLoadingMore = false
    @Published var account: BiliAccount?
    @Published var profile: BiliUserProfile?
    @Published private(set) var loadingSections = Set<AppSection>()
    @Published var errorMessage: String?
    @Published var loginMessage: String?
    @Published private(set) var searchFocusRequest = 0
    @Published private(set) var pendingSearchQuery: String?
    @Published var isSearchShowingResults = false
    @Published private(set) var exitSearchResultsRequest = 0

    var profilePageHandlers: ProfilePageHandlers?

    @Published private(set) var floatingVideoChrome: VideoDetailChromeInfo?
    @Published private(set) var floatingProfileChrome: UserProfileChromeInfo?
    @Published private(set) var activeFloatingChromeKind: AppFloatingChromeKind?

    func presentVideoFloatingChrome(_ info: VideoDetailChromeInfo?) {
        if let info {
            floatingVideoChrome = info
        }
        activeFloatingChromeKind = .video
    }

    func refreshVideoFloatingChrome(_ info: VideoDetailChromeInfo?) {
        if let info {
            floatingVideoChrome = info
        }
    }

    func presentProfileFloatingChrome(_ info: UserProfileChromeInfo?) {
        if let info {
            floatingProfileChrome = info
        }
        activeFloatingChromeKind = .profile
    }

    func refreshProfileFloatingChrome(_ info: UserProfileChromeInfo?) {
        if let info {
            floatingProfileChrome = info
        }
    }

    func resignProfileFloatingChrome() {
        guard activeFloatingChromeKind == .profile else { return }
        activeFloatingChromeKind = floatingVideoChrome != nil ? .video : nil
    }

    func resignVideoFloatingChrome() {
        guard activeFloatingChromeKind == .video else { return }
        activeFloatingChromeKind = floatingProfileChrome != nil ? .profile : nil
    }

    func clearFloatingChrome() {
        floatingVideoChrome = nil
        floatingProfileChrome = nil
        activeFloatingChromeKind = nil
    }

    private var followingOffset: String?
    private var homeFreshIdx = 1
    private var homeFetchRow = 1
    private var homeLastShowList = ""
    private var favoritePage = 1
    private var historyCursor: BiliHistoryCursor?

    private let api = BilibiliAPI()
    private let accountStore = AccountStore()
    private var didLoadInitialData = false
    private var reloadGeneration = 0

    func isSectionLoading(_ section: AppSection) -> Bool {
        loadingSections.contains(section)
    }

    func loadInitialData() async {
        guard !didLoadInitialData else { return }
        didLoadInitialData = true
        account = accountStore.load()
        Task { await api.warmUp(credential: account?.credential) }
        await reloadSelected()
    }

    func reloadSelectedIfNeeded() async {
        switch selectedSection {
        case .home where homeVideos.isEmpty:
            await reloadSelected()
        case .following where followingVideos.isEmpty:
            await reloadSelected()
        case .hot where hotVideos.isEmpty:
            await reloadSelected()
        case .history where historyItems.isEmpty:
            await reloadSelected()
        case .favorites where favoriteVideos.isEmpty:
            await reloadSelected()
        case .mine where profile == nil && account != nil:
            await reloadSelected()
        default:
            break
        }
    }

    func requestSearchFocus() {
        searchFocusRequest += 1
    }

    func openSearch(for keyword: String) {
        let normalized = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        pendingSearchQuery = normalized
        selectedSection = .search
    }

    func consumePendingSearchQuery() {
        pendingSearchQuery = nil
    }

    func requestExitSearchResults() {
        exitSearchResultsRequest += 1
    }

    func clearProfilePageHandlers() {
        profilePageHandlers = nil
    }

    func reloadSelected() async {
        reloadGeneration += 1
        let generation = reloadGeneration
        let section = selectedSection

        errorMessage = nil
        loadingSections.insert(section)
        defer {
            if generation == reloadGeneration {
                loadingSections.remove(section)
            }
        }

        do {
            switch section {
            case .search:
                break
            case .home:
                homeFreshIdx = 1
                homeFetchRow = 1
                homeLastShowList = ""
                let page = try await api.homeRecommend(credential: account?.credential)
                guard generation == reloadGeneration, selectedSection == section else { return }
                homeVideos = page.videos
                homeFreshIdx = page.nextFreshIdx
                homeFetchRow = page.nextFetchRow
                homeLastShowList = page.lastShowList
                homeHasMore = page.hasMore
            case .following:
                guard let credential = account?.credential else {
                    guard generation == reloadGeneration else { return }
                    followingVideos = []
                    followingOffset = nil
                    followingHasMore = false
                    throw APIError.message("登录后查看关注内容")
                }
                let page = try await api.followingFeed(credential: credential)
                guard generation == reloadGeneration, selectedSection == section else { return }
                followingVideos = page.videos
                followingOffset = page.nextOffset
                followingHasMore = page.hasMore
            case .hot:
                let videos = try await api.ranking(credential: account?.credential)
                guard generation == reloadGeneration, selectedSection == section else { return }
                hotVideos = videos
            case .history:
                guard let credential = account?.credential else {
                    guard generation == reloadGeneration else { return }
                    historyCursor = nil
                    historyHasMore = false
                    throw APIError.message("登录后查看观看历史")
                }
                historyCursor = nil
                let page = try await api.history(credential: credential)
                guard generation == reloadGeneration, selectedSection == section else { return }
                historyItems = page.items
                historyCursor = page.cursor
                historyHasMore = page.hasMore
            case .favorites:
                guard let credential = account?.credential else {
                    guard generation == reloadGeneration else { return }
                    favoritePage = 1
                    favoriteHasMore = false
                    throw APIError.message("登录后查看收藏")
                }
                favoritePage = 1
                let page = try await api.favoriteVideos(page: 1, credential: credential)
                guard generation == reloadGeneration, selectedSection == section else { return }
                favoriteVideos = page.videos
                favoritePage = page.page
                favoriteHasMore = page.hasMore
            case .mine:
                if let account {
                    await loadProfile(account: account)
                }
            }
        } catch {
            guard generation == reloadGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    func refreshSectionAfterReturningFromDetail() async {
        switch selectedSection {
        case .favorites:
            await refreshFavoritesQuietly()
        case .history:
            await refreshHistoryQuietly()
        default:
            break
        }
    }

    private func refreshFavoritesQuietly() async {
        guard let credential = account?.credential else { return }
        do {
            let page = try await api.favoriteVideos(page: 1, credential: credential)
            favoriteVideos = page.videos
            favoritePage = page.page
            favoriteHasMore = page.hasMore
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshHistoryQuietly() async {
        guard let credential = account?.credential else { return }
        do {
            let page = try await api.history(credential: credential)
            historyItems = page.items
            historyCursor = page.cursor
            historyHasMore = page.hasMore
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteHistoryItem(_ item: BiliHistoryItem) async {
        guard let credential = account?.credential, !item.kid.isEmpty else { return }
        do {
            let deleted = try await api.deleteWatchHistory(kid: item.kid, credential: credential)
            guard deleted else { return }
            historyItems.removeAll { $0.id == item.id }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadMoreHistory() async {
        guard selectedSection == .history,
              let credential = account?.credential,
              let cursor = historyCursor,
              historyHasMore,
              !isSectionLoading(.history),
              !historyLoadingMore else {
            return
        }

        historyLoadingMore = true
        errorMessage = nil
        defer { historyLoadingMore = false }

        do {
            let page = try await api.history(
                credential: credential,
                cursorMax: cursor.max,
                viewAt: cursor.viewAt,
                business: cursor.business
            )
            let merged = JSONParser.deduplicatedHistoryItems(historyItems + page.items)
            let addedCount = merged.count - historyItems.count
            historyItems = merged
            historyCursor = page.cursor
            historyHasMore = page.hasMore && addedCount > 0
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadMoreHome() async {
        guard selectedSection == .home,
              homeHasMore,
              !isSectionLoading(.home),
              !homeLoadingMore else {
            return
        }

        homeLoadingMore = true
        errorMessage = nil
        defer { homeLoadingMore = false }

        do {
            let page = try await api.homeRecommend(
                credential: account?.credential,
                freshIdx: homeFreshIdx,
                fetchRow: homeFetchRow,
                lastShowList: homeLastShowList
            )
            var seen = Set(homeVideos.map(\.bvid))
            let newVideos = page.videos.filter { seen.insert($0.bvid).inserted }
            homeVideos.append(contentsOf: newVideos)
            homeFreshIdx = page.nextFreshIdx
            homeFetchRow = page.nextFetchRow
            homeLastShowList = page.lastShowList
            homeHasMore = page.hasMore && !newVideos.isEmpty
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadMoreFollowing() async {
        guard selectedSection == .following,
              let credential = account?.credential,
              followingHasMore,
              !isSectionLoading(.following),
              !followingLoadingMore else {
            return
        }

        followingLoadingMore = true
        errorMessage = nil
        defer { followingLoadingMore = false }

        do {
            let page = try await api.followingFeed(credential: credential, offset: followingOffset)
            var seen = Set(followingVideos.map(\.bvid))
            let newVideos = page.videos.filter { seen.insert($0.bvid).inserted }
            followingVideos.append(contentsOf: newVideos)
            followingOffset = page.nextOffset
            followingHasMore = page.hasMore && !newVideos.isEmpty
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadMoreFavorites() async {
        guard selectedSection == .favorites,
              let credential = account?.credential,
              favoriteHasMore,
              !isSectionLoading(.favorites),
              !favoriteLoadingMore else {
            return
        }

        favoriteLoadingMore = true
        errorMessage = nil
        defer { favoriteLoadingMore = false }

        do {
            let nextPage = favoritePage + 1
            let page = try await api.favoriteVideos(page: nextPage, credential: credential)
            var seen = Set(favoriteVideos.map(\.bvid))
            let newVideos = page.videos.filter { seen.insert($0.bvid).inserted }
            favoriteVideos.append(contentsOf: newVideos)
            favoritePage = page.page
            favoriteHasMore = page.hasMore && !newVideos.isEmpty
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func login(credential: BilibiliCredential) async -> Bool {
        loginMessage = nil
        errorMessage = nil
        loadingSections.insert(.mine)
        defer { loadingSections.remove(.mine) }

        do {
            let account = try await api.validate(credential: credential)
            self.account = account
            accountStore.save(account)
            loginMessage = "已登录 \(account.name)"
            await loadProfile(account: account)
            await reloadSelectedIfNeeded()
            return true
        } catch {
            loginMessage = error.localizedDescription
            return false
        }
    }

    func logout() {
        account = nil
        profile = nil
        followingVideos = []
        followingOffset = nil
        followingHasMore = false
        followingLoadingMore = false
        historyItems = []
        historyCursor = nil
        historyHasMore = false
        historyLoadingMore = false
        favoriteVideos = []
        favoritePage = 1
        favoriteHasMore = false
        favoriteLoadingMore = false
        accountStore.clear()
        loginMessage = "已退出登录"
    }

    private func loadProfile(account: BiliAccount) async {
        do {
            profile = try await api.myProfile(account: account)
        } catch {
            if selectedSection == .mine {
                errorMessage = error.localizedDescription
            }
        }
    }
}

enum AppSection: String, CaseIterable, Hashable, Identifiable {
    case search
    case home
    case following
    case hot
    case history
    case favorites
    case mine

    static var primaryCases: [AppSection] {
        [.search, .home, .following, .hot, .history, .favorites]
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .search: "搜索"
        case .home: "首页"
        case .following: "关注"
        case .hot: "排行"
        case .history: "历史"
        case .favorites: "收藏"
        case .mine: "我的"
        }
    }

    var symbol: String {
        switch self {
        case .search: "magnifyingglass"
        case .home: "house"
        case .following: "person.2"
        case .hot: "chart.bar"
        case .history: "clock.arrow.circlepath"
        case .favorites: "star"
        case .mine: "person.crop.circle"
        }
    }
}

private struct AccountStore {
    private let fileURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDirectory = support.appendingPathComponent("gaoxipeng.bilibili", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        fileURL = appDirectory.appendingPathComponent("account.json")
    }

    func load() -> BiliAccount? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(BiliAccount.self, from: data)
    }

    func save(_ account: BiliAccount) {
        guard let data = try? JSONEncoder().encode(account) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

@MainActor
enum AppFloatingChromeKind: Equatable {
    case video
    case profile
}

@MainActor
struct ProfilePageHandlers {
    let follow: () -> Void
    let unfollow: () -> Void
}
