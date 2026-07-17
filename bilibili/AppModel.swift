import Combine
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var selectedSection: AppSection = .home
    @Published var homeVideos: [BiliVideo] = []
    @Published var homeHasMore = false
    @Published var homeLoadingMore = false
    @Published private(set) var playURLs: [String: BiliPlayStream] = [:]
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
    @Published private(set) var needsFreshWebLogin = false
    @Published private(set) var searchFocusRequest = 0
    @Published private(set) var pendingSearchQuery: String?
    @Published var isSearchShowingResults = false
    @Published private(set) var exitSearchResultsRequest = 0
    @Published private(set) var searchRefreshRequest = 0
    @Published private(set) var homeScrollToTopRequest = 0

    private struct SearchReturnContext {
        let section: AppSection
        let playbackRequest: VideoPlaybackRequest
    }

    private var searchReturnContext: SearchReturnContext?
    private var isRestoringSearchReturn = false

    var profilePageHandlers: ProfilePageHandlers?
    @Published var pendingUserRelationListRequest: UserRelationListRequest?
    @Published var pendingPlaybackRequest: VideoPlaybackRequest?

    @Published private(set) var floatingVideoChrome: VideoDetailChromeInfo?
    @Published private(set) var floatingProfileChrome: UserProfileChromeInfo?
    @Published private(set) var floatingRelationChrome: UserRelationChromeInfo?
    @Published private(set) var activeFloatingChromeKind: AppFloatingChromeKind?
    @Published private(set) var suppressesFloatingChrome = false
    @Published private(set) var relationListSelectedTab: BiliUserRelationTab = .following

    private var relationListTabChangeHandler: ((BiliUserRelationTab) -> Void)?
    private struct ProfileChromeStackEntry {
        let mid: Int64
        let chrome: UserProfileChromeInfo
    }

    private var profileChromeStack: [ProfileChromeStackEntry] = []
    private var profileChromeOwnerMid: Int64?

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

    func presentProfileFloatingChrome(_ info: UserProfileChromeInfo?, ownerMid: Int64) {
        if let info {
            if profileChromeOwnerMid != ownerMid {
                if let currentMid = profileChromeOwnerMid, let current = floatingProfileChrome {
                    profileChromeStack.append(ProfileChromeStackEntry(mid: currentMid, chrome: current))
                }
                profileChromeOwnerMid = ownerMid
                floatingProfileChrome = info
            } else {
                floatingProfileChrome = info
            }
        }
        activeFloatingChromeKind = .profile
    }

    func refreshProfileFloatingChrome(_ info: UserProfileChromeInfo?, ownerMid: Int64) {
        guard profileChromeOwnerMid == ownerMid, let info else { return }
        floatingProfileChrome = info
    }

    func resignProfileFloatingChrome() {
        guard activeFloatingChromeKind == .profile else { return }
        activeFloatingChromeKind = floatingVideoChrome != nil ? .video : nil
    }

    func restoreProfileFloatingChrome() {
        guard floatingProfileChrome != nil else { return }
        activeFloatingChromeKind = .profile
    }

    func popProfileFloatingChrome(ownerMid: Int64) {
        guard profileChromeOwnerMid == ownerMid else { return }
        let wasActiveProfile = activeFloatingChromeKind == .profile
        profileChromeOwnerMid = nil
        floatingProfileChrome = nil
        if let restored = profileChromeStack.popLast() {
            profileChromeOwnerMid = restored.mid
            floatingProfileChrome = restored.chrome
        }
        // NavigationStack may call the returning video's onAppear before the
        // outgoing profile's onDisappear. Do not erase a video chrome that has
        // already taken ownership during that ordering.
        if wasActiveProfile {
            if floatingProfileChrome != nil {
                activeFloatingChromeKind = .profile
            } else {
                activeFloatingChromeKind = floatingVideoChrome != nil ? .video : nil
            }
        }
    }

    func presentRelationListChrome(
        _ info: UserRelationChromeInfo,
        selectedTab: BiliUserRelationTab,
        onTabChange: @escaping (BiliUserRelationTab) -> Void
    ) {
        floatingRelationChrome = info
        relationListSelectedTab = selectedTab
        relationListTabChangeHandler = onTabChange
        activeFloatingChromeKind = .relationList
    }

    func setRelationListTab(_ tab: BiliUserRelationTab) {
        guard relationListSelectedTab != tab else { return }
        relationListSelectedTab = tab
        relationListTabChangeHandler?(tab)
    }

    func suspendRelationListChrome() {
        guard activeFloatingChromeKind == .relationList else { return }
        activeFloatingChromeKind = nil
    }

    func restoreRelationListChrome() {
        guard floatingRelationChrome != nil else { return }
        activeFloatingChromeKind = .relationList
    }

    func dismissRelationListChrome() {
        relationListTabChangeHandler = nil
        floatingRelationChrome = nil
        if activeFloatingChromeKind == .relationList {
            activeFloatingChromeKind = nil
        }
    }

    func resignRelationListChrome() {
        dismissRelationListChrome()
    }

    func resignVideoFloatingChrome() {
        guard activeFloatingChromeKind == .video else { return }
        activeFloatingChromeKind = floatingProfileChrome != nil ? .profile : nil
    }

    func setFloatingChromeSuppressed(_ suppressed: Bool) {
        guard suppressesFloatingChrome != suppressed else { return }
        suppressesFloatingChrome = suppressed
    }

    func clearFloatingChrome() {
        floatingVideoChrome = nil
        floatingProfileChrome = nil
        floatingRelationChrome = nil
        relationListTabChangeHandler = nil
        profileChromeStack.removeAll()
        profileChromeOwnerMid = nil
        activeFloatingChromeKind = nil
        suppressesFloatingChrome = false
    }

    func handleReturnedToRootNavigation() {
        floatingVideoChrome = nil
        floatingRelationChrome = nil
        relationListTabChangeHandler = nil
        profileChromeStack.removeAll()
        profileChromeOwnerMid = nil
        if selectedSection == .mine, floatingProfileChrome != nil {
            activeFloatingChromeKind = .profile
        } else {
            floatingProfileChrome = nil
            activeFloatingChromeKind = nil
        }
    }

    private static let homeMaxFetchCount = 3
    private static let homePageSize = 30

    private var followingOffset: String?
    private var homeFreshIdx = 1
    private var homeFetchRow = 1
    private var homeLastShowList = ""
    private var homeFetchCount = 0
    private var favoritePage = 1
    private var historyCursor: BiliHistoryCursor?

    private let api = BilibiliAPI()
    private let accountStore = AccountStore()
    private let homeFeedStore = HomeFeedStore()
    private var didLoadInitialData = false
    private var reloadGeneration = 0
    private var didRestoreHomeFeedCache = false
    private var homePrefetchTask: Task<Void, Never>?

    func isSectionLoading(_ section: AppSection) -> Bool {
        loadingSections.contains(section)
    }

    func loadInitialData() async {
        guard !didLoadInitialData else { return }
        didLoadInitialData = true
        account = accountStore.load()
        restoreHomeFeedFromCacheIfNeeded()
        Task { await api.warmUp(credential: account?.credential) }
        if let account {
            await ensureAccessKey(for: account)
        }

        if account != nil {
            if homeVideos.isEmpty {
                await refreshHome()
            }
            await refreshFollowingOnLaunch()
            await prefetchHistory()
        } else {
            resetHomeForLoggedOut()
        }

        if selectedSection != .home {
            await reloadSelectedIfNeeded()
        }
    }

    func reloadSelectedIfNeeded() async {
        switch selectedSection {
        case .home where homeVideos.isEmpty:
            guard account != nil else { return }
            await reloadSelected()
        case .following where followingVideos.isEmpty:
            await reloadSelected()
        case .hot where hotVideos.isEmpty:
            await reloadSelected()
        case .history:
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

    func requestHomeScrollToTop() {
        homeScrollToTopRequest += 1
    }

    func openSearch(for keyword: String, returningTo playbackRequest: VideoPlaybackRequest? = nil) {
        let normalized = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        if let playbackRequest {
            searchReturnContext = SearchReturnContext(
                section: selectedSection,
                playbackRequest: playbackRequest
            )
        }
        pendingSearchQuery = normalized
        selectedSection = .search
    }

    func consumePendingSearchQuery() {
        pendingSearchQuery = nil
    }

    func handleExitSearchResults() {
        if restoreSearchReturnContext() { return }
        requestExitSearchResults()
    }

    func requestExitSearchResults() {
        exitSearchResultsRequest += 1
    }

    func clearSearchReturnContext() {
        searchReturnContext = nil
    }

    func consumeSearchReturnRestoreFlag() -> Bool {
        defer { isRestoringSearchReturn = false }
        return isRestoringSearchReturn
    }

    @discardableResult
    private func restoreSearchReturnContext() -> Bool {
        guard let context = searchReturnContext else { return false }
        searchReturnContext = nil
        exitSearchResultsRequest += 1
        isRestoringSearchReturn = true
        pendingPlaybackRequest = context.playbackRequest
        selectedSection = context.section
        return true
    }

    func clearProfilePageHandlers() {
        profilePageHandlers = nil
    }

    func requestUserRelationList(_ request: UserRelationListRequest) {
        pendingUserRelationListRequest = request
    }

    func openVideo(_ video: BiliVideo, resolveWatchProgress: Bool = false) {
        guard resolveWatchProgress else {
            pendingPlaybackRequest = VideoPlaybackRequest(video)
            return
        }

        Task {
            pendingPlaybackRequest = await resolvePlaybackRequest(for: video)
        }
    }

    func openHistoryVideo(_ item: BiliHistoryItem) {
        Task {
            pendingPlaybackRequest = await api.resolveHistoryPlaybackRequest(
                item: item,
                credential: account?.credential
            )
        }
    }

    func resolvePlaybackRequest(for video: BiliVideo) async -> VideoPlaybackRequest {
        guard let credential = account?.credential else {
            if video.pgcEpid > 0 {
                return VideoPlaybackRequest(
                    video,
                    epid: video.pgcEpid,
                    refererURL: URL(string: "https://www.bilibili.com/bangumi/play/ep\(video.pgcEpid)")
                )
            }
            return VideoPlaybackRequest(video)
        }

        if let progress = try? await api.watchProgress(
            bvid: video.bvid,
            aid: video.aid,
            credential: credential
        ) {
            return playbackRequest(for: video, progress: progress)
        }

        if video.pgcEpid > 0 {
            return VideoPlaybackRequest(
                video,
                epid: video.pgcEpid,
                refererURL: URL(string: "https://www.bilibili.com/bangumi/play/ep\(video.pgcEpid)")
            )
        }

        return VideoPlaybackRequest(video)
    }

    private func playbackRequest(for video: BiliVideo, progress: BiliWatchProgress) -> VideoPlaybackRequest {
        VideoPlaybackRequest(
            video,
            progressSeconds: progress.progressSeconds,
            epid: progress.epid,
            refererURL: progress.refererURL
        )
    }

    private func prefetchHistory() async {
        guard let credential = account?.credential else { return }
        do {
            let page = try await api.history(credential: credential, pageSize: 30)
            if historyItems.isEmpty {
                historyItems = page.items
                historyCursor = page.cursor
                historyHasMore = page.hasMore
            }
        } catch {}
    }

    func reloadSelected() async {
        if selectedSection == .home {
            await refreshHome()
            return
        }

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
                searchRefreshRequest += 1
                return
            case .home:
                break
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

    private func refreshHistoryQuietly() async {
        guard let credential = account?.credential else { return }
        do {
            // Give the detail page's final cloud progress report time to commit
            // before reading the authoritative history page back.
            try await Task.sleep(nanoseconds: 600_000_000)
            let page = try await api.history(credential: credential)
            historyItems = page.items
            historyCursor = page.cursor
            historyHasMore = page.hasMore
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
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

    func deleteHistoryItem(_ item: BiliHistoryItem) async {
        guard let credential = account?.credential, !item.kid.isEmpty else { return }

        let identity = item.listIdentity
        let rollbackItems = historyItems

        withAnimation(AppLayout.listRemovalAnimation) {
            historyItems.removeAll { $0.listIdentity == identity }
        }

        do {
            let deleted = try await api.deleteWatchHistory(kid: item.kid, credential: credential)
            guard deleted else {
                withAnimation(AppLayout.listRemovalAnimation) {
                    historyItems = rollbackItems
                }
                return
            }
            errorMessage = nil
        } catch {
            withAnimation(AppLayout.listRemovalAnimation) {
                historyItems = rollbackItems
            }
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
                business: cursor.business,
                pageSize: cursor.ps > 0 ? cursor.ps : 30
            )
            let merged = JSONParser.deduplicatedHistoryItems(historyItems + page.items)
            let addedCount = merged.count - historyItems.count
            let cursorAdvanced = page.cursor.map { next in
                next.max != cursor.max
                    || next.viewAt != cursor.viewAt
                    || next.business != cursor.business
            } ?? false
            historyItems = merged
            historyCursor = page.cursor
            if !page.hasMore || page.items.isEmpty {
                historyHasMore = false
            } else if addedCount > 0 || cursorAdvanced {
                historyHasMore = true
            } else {
                historyHasMore = false
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshHome() async {
        guard account != nil else {
            resetHomeForLoggedOut()
            return
        }

        requestHomeScrollToTop()

        reloadGeneration += 1
        let generation = reloadGeneration

        errorMessage = nil
        loadingSections.insert(.home)
        defer {
            if generation == reloadGeneration {
                loadingSections.remove(.home)
            }
        }

        homeFreshIdx = 1
        homeFetchRow = 1
        homeLastShowList = ""
        homeFetchCount = 0

        do {
            let page = try await api.homeRecommend(
                credential: account?.credential,
                pageSize: Self.homePageSize
            )
            guard generation == reloadGeneration else { return }
            homeVideos = page.videos
            homeFreshIdx = page.nextFreshIdx
            homeFetchRow = page.nextFetchRow
            homeLastShowList = page.lastShowList
            homeFetchCount = 1
            homeHasMore = canLoadMoreHome(after: page, appendedNewItems: !page.videos.isEmpty)
            persistHomeFeedCache()
            prefetchHomePlayURLs()
        } catch {
            guard generation == reloadGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    func loadMoreHome() async {
        guard account != nil,
              selectedSection == .home,
              homeHasMore,
              homeFetchCount < Self.homeMaxFetchCount,
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
                lastShowList: homeLastShowList,
                pageSize: Self.homePageSize
            )
            var seen = Set(homeVideos.map(\.bvid))
            let newVideos = page.videos.filter { seen.insert($0.bvid).inserted }
            homeVideos.append(contentsOf: newVideos)
            homeFreshIdx = page.nextFreshIdx
            homeFetchRow = page.nextFetchRow
            homeLastShowList = page.lastShowList
            homeFetchCount += 1
            homeHasMore = canLoadMoreHome(after: page, appendedNewItems: !newVideos.isEmpty)
            persistHomeFeedCache()
            prefetchHomePlayURLs()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cachedPlayStream(for video: BiliVideo) -> BiliPlayStream? {
        let playbackID = video.playbackID()
        guard let cached = playURLs[playbackID] else { return nil }
        let targetCID = video.cid > 0 ? video.cid : nil
        let cacheValid = cached.aid > 0
            && cached.cid > 0
            && (targetCID == nil || cached.cid == targetCID)
        return cacheValid ? cached : nil
    }

    func ensurePlayStream(for video: BiliVideo) {
        Task { await resolvePlayURL(for: video) }
    }

    @discardableResult
    func resolvePlayURL(for video: BiliVideo) async -> BiliPlayStream? {
        let playbackID = video.playbackID()
        if let cached = cachedPlayStream(for: video) {
            return cached
        }

        guard let credential = account?.credential, !video.bvid.isEmpty else { return nil }

        do {
            let detail = try await api.videoDetail(bvid: video.bvid, credential: credential)
            let cid = video.cid > 0 ? video.cid : detail.video.cid
            guard cid > 0 else { return nil }
            let aid = video.aid > 0 ? video.aid : detail.video.aid
            let stream = try await api.playURL(bvid: video.bvid, cid: cid, credential: credential)
            let resolved = BiliPlayStream(
                videoURL: stream.videoURL,
                videoFallbackURLs: stream.videoFallbackURLs,
                audioURL: stream.audioURL,
                aid: aid,
                cid: cid
            )
            playURLs[playbackID] = resolved
            return resolved
        } catch {
            return nil
        }
    }

    func ensureHomePlayStreamsPrefetched() {
        prefetchHomePlayURLs()
    }

    private func prefetchHomePlayURLs() {
        homePrefetchTask?.cancel()
        homePrefetchTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            await FeedScrollActivity.waitUntilIdle()
            guard !Task.isCancelled else { return }
            for video in homeVideos.prefix(10) {
                if Task.isCancelled { return }
                if playURLs[video.playbackID()] != nil { continue }
                await resolvePlayURL(for: video)
            }
        }
    }

    private func restoreHomeFeedFromCacheIfNeeded() {
        guard !didRestoreHomeFeedCache else { return }
        didRestoreHomeFeedCache = true
        guard let cached = homeFeedStore.read() else { return }
        homeVideos = cached.videos
        homeFreshIdx = cached.freshIdx
        homeFetchRow = cached.fetchRow
        homeLastShowList = cached.lastShowList
        homeHasMore = cached.hasMore
        homeFetchCount = max(1, Int(ceil(Double(cached.videos.count) / Double(Self.homePageSize))))
        prefetchHomePlayURLs()
    }

    private func persistHomeFeedCache() {
        homeFeedStore.save(
            CachedHomeFeed(
                videos: homeVideos,
                freshIdx: homeFreshIdx,
                fetchRow: homeFetchRow,
                lastShowList: homeLastShowList,
                hasMore: homeHasMore
            )
        )
    }

    private func resetHomeForLoggedOut() {
        homeVideos = []
        homeHasMore = false
        homeFreshIdx = 1
        homeFetchRow = 1
        homeLastShowList = ""
        homeFetchCount = 0
        homeLoadingMore = false
    }

    private func refreshFollowingOnLaunch() async {
        guard account?.credential != nil else { return }
        do {
            let page = try await api.followingFeed(credential: account!.credential)
            followingVideos = page.videos
            followingOffset = page.nextOffset
            followingHasMore = page.hasMore
        } catch {
            // Keep launch quiet; the following tab can retry on demand.
        }
    }

    private func canLoadMoreHome(after page: BiliHomeRecommendPage, appendedNewItems: Bool) -> Bool {
        homeFetchCount < Self.homeMaxFetchCount
            && page.hasMore
            && appendedNewItems
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
            await api.warmUp(credential: credential)
            var credential = await api.preparedCredentialForExchange(credential)
            guard credential.hasLoginSession else {
                loginMessage = "登录 Cookie 不完整，请清除网页登录后重新登录"
                return false
            }
            let exchangeResult = await BiliAccessKeyExchange.exchangeWithStatus(credential: credential)
            if let exchanged = exchangeResult.credential, !exchanged.accessKey.isEmpty {
                credential = exchanged
            }
            let account = try await api.validate(credential: credential)
            let savedAccount = BiliAccount(
                uid: account.uid,
                name: account.name,
                faceURLString: account.faceURLString,
                credential: credential
            )
            self.account = savedAccount
            accountStore.save(savedAccount)
            await api.invalidateWBICache()
            await api.warmUp(credential: savedAccount.credential)
            if credential.accessKey.isEmpty {
                loginMessage = "已登录 \(savedAccount.name)，accessKey 交换失败：\(exchangeResult.status.summary)"
            } else {
                loginMessage = "已登录 \(savedAccount.name)"
            }
            await loadProfile(account: savedAccount)
            await refreshHome()
            await refreshFollowingOnLaunch()
            await prefetchHistory()
            await reloadSelectedIfNeeded()
            return true
        } catch {
            loginMessage = error.localizedDescription
            return false
        }
    }

    func updateAccountCredential(_ credential: BilibiliCredential) {
        guard var account else { return }
        guard account.credential != credential else { return }
        account.credential = credential
        self.account = account
        accountStore.save(account)
    }

    func ensureAccessKey(for account: BiliAccount) async {
        guard account.credential.accessKey.isEmpty else { return }
        let prepared = await api.preparedCredentialForExchange(account.credential)
        let result = await BiliAccessKeyExchange.exchangeWithStatus(credential: prepared)
        guard let exchanged = result.credential, !exchanged.accessKey.isEmpty else { return }
        let updated = BiliAccount(
            uid: account.uid,
            name: account.name,
            faceURLString: account.faceURLString,
            credential: exchanged
        )
        self.account = updated
        accountStore.save(updated)
    }

    private func refreshStoredAccessKey(for account: BiliAccount) async {
        await ensureAccessKey(for: account)
    }

    func logout() {
        account = nil
        profile = nil
        clearFloatingChrome()
        clearProfilePageHandlers()
        needsFreshWebLogin = true
        homeFeedStore.clear()
        resetHomeForLoggedOut()
        playURLs = [:]
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
        Task { await BilibiliWebSession.clearDefaultWebsiteData() }
    }

    func consumeFreshWebLoginFlag() -> Bool {
        let shouldPrepare = needsFreshWebLogin
        needsFreshWebLogin = false
        return shouldPrepare
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
    case relationList
}

@MainActor
struct ProfilePageHandlers {
    let follow: () -> Void
    let unfollow: () -> Void
    let openRelationList: (BiliUserRelationTab) -> Void
    let reload: () -> Void
    var logout: (() -> Void)? = nil
}
