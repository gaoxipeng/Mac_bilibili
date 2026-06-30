import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var selectedSection: AppSection = .home
    @Published var homeVideos: [BiliVideo] = []
    @Published var followingVideos: [BiliVideo] = []
    @Published var followingHasMore = false
    @Published var followingLoadingMore = false
    @Published var hotVideos: [BiliVideo] = []
    @Published var historyItems: [BiliHistoryItem] = []
    @Published var searchResults: [BiliVideo] = []
    @Published var hotWords: [BiliHotWord] = []
    @Published var account: BiliAccount?
    @Published var profile: BiliUserProfile?
    @Published var searchQuery = ""
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var loginMessage: String?

    private var followingOffset: String?

    private let api = BilibiliAPI()
    private let accountStore = AccountStore()
    private var didLoadInitialData = false

    func loadInitialData() async {
        guard !didLoadInitialData else { return }
        didLoadInitialData = true
        account = accountStore.load()
        if let account {
            await loadProfile(account: account)
        }
        await reloadSelected()
        await loadHotWords()
    }

    func reloadSelectedIfNeeded() async {
        switch selectedSection {
        case .search where hotWords.isEmpty:
            await loadHotWords()
        case .home where homeVideos.isEmpty:
            await reloadSelected()
        case .following where followingVideos.isEmpty:
            await reloadSelected()
        case .hot where hotVideos.isEmpty:
            await reloadSelected()
        case .history where historyItems.isEmpty:
            await reloadSelected()
        case .mine where profile == nil && account != nil:
            await reloadSelected()
        default:
            break
        }
    }

    func reloadSelected() async {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }

        do {
            switch selectedSection {
            case .search:
                if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    await loadHotWords()
                } else {
                    searchResults = try await api.searchVideos(keyword: searchQuery, credential: account?.credential)
                }
            case .home:
                homeVideos = try await api.homeRecommend(credential: account?.credential)
            case .following:
                guard let credential = account?.credential else {
                    followingVideos = []
                    followingOffset = nil
                    followingHasMore = false
                    throw APIError.message("登录后查看关注内容")
                }
                let page = try await api.followingFeed(credential: credential)
                followingVideos = page.videos
                followingOffset = page.nextOffset
                followingHasMore = page.hasMore
            case .hot:
                hotVideos = try await api.ranking(credential: account?.credential)
            case .history:
                guard let credential = account?.credential else {
                    throw APIError.message("登录后查看观看历史")
                }
                historyItems = try await api.history(credential: credential)
            case .mine:
                if let account {
                    await loadProfile(account: account)
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadMoreFollowing() async {
        guard selectedSection == .following,
              let credential = account?.credential,
              followingHasMore,
              !isLoading,
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
            followingHasMore = page.hasMore
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func search(keyword: String? = nil) async {
        if let keyword {
            searchQuery = keyword
        }
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            return
        }

        selectedSection = .search
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }

        do {
            searchResults = try await api.searchVideos(keyword: trimmed, credential: account?.credential)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func login(credential: BilibiliCredential) async -> Bool {
        loginMessage = nil
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }

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
        accountStore.clear()
        loginMessage = "已退出登录"
    }

    private func loadHotWords() async {
        do {
            hotWords = try await api.hotWords()
        } catch {
            if selectedSection == .search {
                errorMessage = error.localizedDescription
            }
        }
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
    case mine

    static var primaryCases: [AppSection] {
        [.search, .home, .following, .hot, .history]
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .search: "搜索"
        case .home: "首页"
        case .following: "关注"
        case .hot: "排行"
        case .history: "历史"
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
