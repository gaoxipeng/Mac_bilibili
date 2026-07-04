import AppKit
import Combine
import SwiftUI

enum SearchResultTab: String, CaseIterable, Identifiable, Hashable {
    case videos
    case users

    var id: String { rawValue }

    var title: String {
        switch self {
        case .videos: "视频"
        case .users: "UP主"
        }
    }
}

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var queryInput = ""
    @Published var activeQuery: String?
    @Published var suggests: [String] = []
    @Published var hotWords: [BiliHotSearchItem] = []
    @Published var hotLoading = false
    @Published var searchHistory: [String] = []
    @Published var historyExpanded = false

    @Published var selectedTab: SearchResultTab = .videos
    @Published var videos: [BiliVideo] = []
    @Published var users: [BiliSearchUser] = []
    @Published var videoLoading = false
    @Published var userLoading = false
    @Published var videoLoadingMore = false
    @Published var userLoadingMore = false
    @Published var videoHasMore = false
    @Published var userHasMore = false
    @Published var errorMessage: String?
    @Published var previewVideos: [BiliVideo] = []
    @Published var previewLoading = false

    var credential: BilibiliCredential?

    private let api = BilibiliAPI()
    private let historyStore = SearchHistoryStore()
    private var videoPage = 1
    private var userPage = 1
    private var searchGeneration = 0
    private var suggestTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var latestSuggestTerm = ""
    private var previewGeneration = 0

    var isShowingResults: Bool {
        activeQuery != nil
    }

    var visibleHistory: [String] {
        if historyExpanded {
            return searchHistory
        }
        return Array(searchHistory.prefix(SearchHistoryStore.collapsedDisplayCount))
    }

    var canExpandHistory: Bool {
        searchHistory.count > SearchHistoryStore.collapsedDisplayCount
    }

    func prepare() {
        searchHistory = historyStore.read()
    }

    func loadDiscoveryIfNeeded() async {
        guard hotWords.isEmpty, !hotLoading else { return }
        hotLoading = true
        defer { hotLoading = false }
        do {
            hotWords = try await api.hotSearchItems()
        } catch {
            if hotWords.isEmpty {
                errorMessage = error.localizedDescription
            }
        }
    }

    func exitSearchResults() {
        activeQuery = nil
        videos = []
        users = []
        errorMessage = nil
    }

    func handleInputChange(_ text: String) {
        let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let activeQuery, activeQuery != term {
            exitSearchResults()
        }
        scheduleSuggest(for: text)
        schedulePreview(for: text)
    }

    func performSearch(_ keyword: String) {
        let normalized = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }

        suggestTask?.cancel()
        latestSuggestTerm = normalized
        queryInput = normalized
        activeQuery = normalized
        suggests = []
        previewVideos = []
        previewLoading = false
        previewTask?.cancel()
        searchHistory = historyStore.touch(normalized)
        videos = []
        users = []
        videoPage = 1
        userPage = 1
        videoHasMore = false
        userHasMore = false
        videoLoading = false
        userLoading = false
        videoLoadingMore = false
        userLoadingMore = false
        errorMessage = nil
        searchGeneration += 1

        let generation = searchGeneration
        let tab = selectedTab
        Task { @MainActor in
            switch tab {
            case .videos:
                await loadVideos(reset: true, generation: generation)
            case .users:
                await loadUsers(reset: true, generation: generation)
            }
        }
    }

    func loadResultsForSelectedTabIfNeeded() async {
        guard activeQuery != nil else { return }
        switch selectedTab {
        case .videos:
            guard videos.isEmpty, !videoLoading else { return }
            await loadVideos(reset: true)
        case .users:
            guard users.isEmpty, !userLoading else { return }
            await loadUsers(reset: true)
        }
    }

    func resetInput() {
        latestSuggestTerm = ""
        queryInput = ""
        activeQuery = nil
        suggests = []
        previewVideos = []
        previewLoading = false
        videos = []
        users = []
        errorMessage = nil
        videoLoading = false
        userLoading = false
        videoLoadingMore = false
        userLoadingMore = false
        suggestTask?.cancel()
        previewTask?.cancel()
    }

    func clearInput() {
        resetInput()
    }

    func submitQuery(_ raw: String? = nil) {
        performSearch(raw ?? queryInput)
    }

    func onQueryInputChanged() {
        handleInputChange(queryInput)
    }

    func removeHistory(_ query: String) {
        searchHistory = historyStore.remove(query)
    }

    func clearHistory() {
        searchHistory = historyStore.clear()
        historyExpanded = false
    }

    private func scheduleSuggest(for text: String) {
        let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
        latestSuggestTerm = term
        suggestTask?.cancel()

        guard !term.isEmpty else {
            suggests = []
            previewVideos = []
            previewLoading = false
            previewTask?.cancel()
            return
        }

        let capturedTerm = term
        suggestTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled, latestSuggestTerm == capturedTerm else { return }
            do {
                let items = try await api.searchSuggest(term: capturedTerm)
                guard !Task.isCancelled, latestSuggestTerm == capturedTerm, activeQuery == nil else { return }
                suggests = items
            } catch {
                guard !Task.isCancelled else { return }
                suggests = []
            }
        }
    }

    private func schedulePreview(for text: String) {
        let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
        previewTask?.cancel()

        guard !term.isEmpty, activeQuery == nil else {
            previewVideos = []
            previewLoading = false
            return
        }

        previewGeneration += 1
        let generation = previewGeneration
        previewLoading = true
        let capturedTerm = term

        previewTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 320_000_000)
            guard !Task.isCancelled, latestSuggestTerm == capturedTerm, activeQuery == nil else { return }
            do {
                let result = try await api.searchVideos(keyword: capturedTerm, page: 1, credential: credential)
                guard !Task.isCancelled, previewGeneration == generation, activeQuery == nil else { return }
                previewVideos = result.items
            } catch {
                guard !Task.isCancelled, previewGeneration == generation else { return }
                previewVideos = []
            }
            if previewGeneration == generation {
                previewLoading = false
            }
        }
    }

    func loadVideos(reset: Bool, generation: Int? = nil) async {
        let currentGeneration = generation ?? searchGeneration
        guard let query = activeQuery, currentGeneration == searchGeneration else { return }
        if reset {
            guard !videoLoading else { return }
            videoLoading = true
            videoPage = 1
        } else {
            guard videoHasMore, !videoLoadingMore, !videoLoading else { return }
            videoLoadingMore = true
        }
        defer {
            if currentGeneration == searchGeneration {
                videoLoading = false
                videoLoadingMore = false
            }
        }

        do {
            let page = reset ? 1 : videoPage + 1
            let result = try await api.searchVideos(keyword: query, page: page, credential: credential)
            guard currentGeneration == searchGeneration else { return }
            if reset {
                var seen = Set<String>()
                videos = result.items.filter { seen.insert($0.bvid).inserted }
                videoHasMore = result.hasMore
            } else {
                var seen = Set(videos.map(\.bvid))
                let newVideos = result.items.filter { seen.insert($0.bvid).inserted }
                videos.append(contentsOf: newVideos)
                videoHasMore = result.hasMore && !newVideos.isEmpty
            }
            videoPage = result.page
        } catch {
            guard currentGeneration == searchGeneration, reset else { return }
            errorMessage = error.localizedDescription
        }
    }

    func loadUsers(reset: Bool, generation: Int? = nil) async {
        let currentGeneration = generation ?? searchGeneration
        guard let query = activeQuery, currentGeneration == searchGeneration else { return }
        if reset {
            guard !userLoading else { return }
            userLoading = true
            userPage = 1
        } else {
            guard userHasMore, !userLoadingMore, !userLoading else { return }
            userLoadingMore = true
        }
        defer {
            if currentGeneration == searchGeneration {
                userLoading = false
                userLoadingMore = false
            }
        }

        do {
            let page = reset ? 1 : userPage + 1
            let result = try await api.searchUsers(keyword: query, page: page, credential: credential)
            guard currentGeneration == searchGeneration else { return }
            if reset {
                users = result.items
                userHasMore = result.hasMore
            } else {
                var seen = Set(users.map(\.mid))
                let newUsers = result.items.filter { seen.insert($0.mid).inserted }
                users.append(contentsOf: newUsers)
                userHasMore = result.hasMore && !newUsers.isEmpty
            }
            userPage = result.page
        } catch {
            guard currentGeneration == searchGeneration, reset else { return }
            if errorMessage == nil {
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct SearchDashboard: View {
    @ObservedObject var model: AppModel
    @Binding var navigationPath: NavigationPath
    @StateObject private var searchModel = SearchViewModel()
    @State private var queryText = ""
    @State private var isSearchDropdownPresented = false
    @State private var searchDropdownActiveEntryID: String?

    var body: some View {
        GeometryReader { geometry in
            let metrics = SearchPageMetrics(viewportWidth: geometry.size.width)

            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    HStack(spacing: 0) {
                        Spacer(minLength: metrics.horizontalPadding)

                        HStack(alignment: .center, spacing: AppLayout.searchHeaderSpacing) {
                            MacSearchSuggestCombo(
                                text: $queryText,
                                searchModel: searchModel,
                                focusRequest: model.searchFocusRequest,
                                isDropdownPresented: $isSearchDropdownPresented,
                                dropdownActiveEntryID: $searchDropdownActiveEntryID,
                                onSearch: { runSearch($0) },
                                onVideoSelect: { video in
                                    navigationPath.append(VideoPlaybackRequest(video))
                                }
                            )
                            .frame(width: AppLayout.searchBarPreferredWidth, alignment: .leading)

                            SearchTypeSegmentedControl(
                                selection: Binding(
                                    get: { searchModel.selectedTab },
                                    set: { searchModel.selectedTab = $0 }
                                )
                            )
                            .frame(height: AppLayout.searchBarHeight)
                        }
                        .frame(width: AppLayout.searchHeaderGroupWidth, alignment: .leading)

                        Spacer(minLength: metrics.horizontalPadding)
                    }

                    if isSearchDropdownPresented {
                        searchSuggestDropdownPanel(metrics: metrics)
                            .transition(.searchDropdownReveal)
                    }
                }
                .padding(.top, AppLayout.searchBarTopOffset)
                .padding(.bottom, 8)
                .zIndex(10)

                MacOverlayScrollView {
                    ZStack(alignment: .topLeading) {
                        if searchModel.isShowingResults {
                            searchResultsContent(metrics: metrics)
                                .padding(.horizontal, AppLayout.feedHorizontalInset)
                                .padding(.bottom, 32)
                                .transition(.opacity.combined(with: .offset(y: -8)))
                        } else {
                            HStack(spacing: 0) {
                                Spacer(minLength: metrics.horizontalPadding)

                                discoverySection

                                Spacer(minLength: metrics.horizontalPadding)
                            }
                            .padding(.bottom, 32)
                            .transition(.opacity.combined(with: .offset(y: 8)))
                        }
                    }
                    .animation(.easeOut(duration: 0.20), value: searchModel.isShowingResults)
                    .environment(\.feedViewportWidth, geometry.size.width)
                }
                .zIndex(0)
            }
            .animation(.spring(response: 0.30, dampingFraction: 0.86), value: isSearchDropdownPresented)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            searchModel.credential = model.account?.credential
            searchModel.prepare()
            Task { await searchModel.loadDiscoveryIfNeeded() }
            applyPendingSearchQueryIfNeeded()
        }
        .onChange(of: model.account?.credential) { _, credential in
            searchModel.credential = credential
        }
        .onChange(of: model.pendingSearchQuery) { _, _ in
            applyPendingSearchQueryIfNeeded()
        }
        .onChange(of: searchModel.selectedTab) { _, _ in
            Task { await searchModel.loadResultsForSelectedTabIfNeeded() }
        }
        .onChange(of: searchModel.isShowingResults) { _, isShowing in
            model.isSearchShowingResults = isShowing
        }
        .onChange(of: model.exitSearchResultsRequest) { _, _ in
            exitSearchResultsView()
        }
        .onDisappear {
            model.isSearchShowingResults = false
        }
    }

    private func exitSearchResultsView() {
        isSearchDropdownPresented = false
        searchDropdownActiveEntryID = nil
        searchModel.exitSearchResults()
    }

    private func applyPendingSearchQueryIfNeeded() {
        guard let query = model.pendingSearchQuery else { return }
        model.consumePendingSearchQuery()
        searchModel.selectedTab = .videos
        runSearch(query)
    }

    private func runSearch(_ keyword: String) {
        let value = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        DispatchQueue.main.async {
            queryText = value
            searchModel.performSearch(value)
        }
    }

    private var searchDropdownEntries: [SearchDropdownEntry] {
        var entries = searchModel.suggests.map { SearchDropdownEntry.suggest($0) }
        entries.append(contentsOf: searchModel.previewVideos.map { .video($0) })
        return entries
    }

    @ViewBuilder
    private func searchSuggestDropdownPanel(metrics: SearchPageMetrics) -> some View {
        let panelWidth = AppLayout.searchSuggestionPanelWidth(
            for: metrics.resultsContentWidth
        )

        HStack(alignment: .top, spacing: 0) {
            Spacer(minLength: metrics.horizontalPadding)

            SearchSuggestDropdownPanel(
                entries: searchDropdownEntries,
                query: queryText.trimmingCharacters(in: .whitespacesAndNewlines),
                previewLoading: searchModel.previewLoading,
                activeEntryID: searchDropdownActiveEntryID,
                onActivate: handleDropdownActivate,
                onHoverEntry: { searchDropdownActiveEntryID = $0 }
            )
            .frame(width: panelWidth, alignment: .leading)

            Spacer(minLength: metrics.horizontalPadding)
        }
    }

    private func handleDropdownActivate(_ entry: SearchDropdownEntry) {
        searchDropdownActiveEntryID = nil
        switch entry {
        case .suggest(let keyword):
            runSearch(keyword)
        case .video(let video):
            navigationPath.append(VideoPlaybackRequest(video))
        }
    }

    private var discoverySection: some View {
        let hotBlockWidth = AppLayout.searchDiscoveryContentWidth
        let chipWidth = (hotBlockWidth - 10) / 2

        return VStack(alignment: .leading, spacing: 32) {
            searchHistorySection
            hotSearchSection(chipWidth: chipWidth)
        }
        .frame(width: hotBlockWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var searchHistorySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("搜索历史")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color(red: 0.12, green: 0.12, blue: 0.14))

                if !searchModel.searchHistory.isEmpty {
                    SearchTextActionButton(title: "清除") {
                        searchModel.clearHistory()
                    }
                }
            }

            if searchModel.searchHistory.isEmpty {
                Text("暂无搜索记录")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(red: 0.55, green: 0.55, blue: 0.58))
            } else {
                SearchChipFlowLayout(spacing: 8) {
                    ForEach(searchModel.visibleHistory, id: \.self) { query in
                        SearchHistoryChip(
                            title: query,
                            onTap: { runSearch(query) },
                            onDelete: { searchModel.removeHistory(query) }
                        )
                    }
                }

                if searchModel.canExpandHistory {
                    SearchTextActionButton(
                        title: searchModel.historyExpanded ? "收起" : "展开"
                    ) {
                        searchModel.historyExpanded.toggle()
                    }
                }
            }
        }
    }

    private func hotSearchSection(chipWidth: CGFloat) -> some View {
        let columns = hotSearchColumns(searchModel.hotWords)
        return VStack(alignment: .leading, spacing: 12) {
            Text("bilibili热搜")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color(red: 0.12, green: 0.12, blue: 0.14))

            if searchModel.hotLoading, searchModel.hotWords.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Spacer()
                }
                .padding(.vertical, 32)
            } else if searchModel.hotWords.isEmpty {
                Text("暂无热搜")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(red: 0.55, green: 0.55, blue: 0.58))
            } else {
                HStack(alignment: .top, spacing: 10) {
                    hotSearchColumn(columns.left, chipWidth: chipWidth)
                    hotSearchColumn(columns.right, chipWidth: chipWidth)
                }
            }
        }
    }

    private func hotSearchColumns(_ items: [BiliHotSearchItem]) -> (left: [BiliHotSearchItem], right: [BiliHotSearchItem]) {
        let split = (items.count + 1) / 2
        return (Array(items.prefix(split)), Array(items.dropFirst(split)))
    }

    private func hotSearchColumn(_ items: [BiliHotSearchItem], chipWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items) { item in
                SearchHotCapsuleChip(item: item, chipWidth: chipWidth) {
                    runSearch(item.keyword)
                }
            }
        }
    }

    @ViewBuilder
    private func searchResultsContent(metrics: SearchPageMetrics) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if let error = searchModel.errorMessage {
                Text(error)
                    .font(.system(size: 13))
                    .foregroundStyle(.orange)
            }

            Group {
                switch searchModel.selectedTab {
                case .videos:
                    videoResults
                case .users:
                    userResults(metrics: metrics)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var videoResults: some View {
        Group {
            if searchModel.videoLoading, searchModel.videos.isEmpty {
                ProgressView("正在搜索视频")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            } else if searchModel.videos.isEmpty, !searchModel.videoLoading {
                ContentUnavailableView("没有找到相关视频", systemImage: "film")
                    .padding(.vertical, 40)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    VideoFeedGrid(videos: searchModel.videos)

                    if searchModel.videoHasMore {
                        FeedLoadMoreFooter(
                            anchorID: searchModel.videos.count,
                            hasMore: searchModel.videoHasMore,
                            loadingMore: searchModel.videoLoadingMore,
                            onLoadMore: {
                                Task { await searchModel.loadVideos(reset: false) }
                            }
                        )
                    }
                }
            }
        }
    }

    private func userResults(metrics: SearchPageMetrics) -> some View {
        let layout = metrics.userResultLayout
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: AppLayout.searchUserResultColumnSpacing, alignment: .center),
            count: layout.columnCount
        )

        return LazyVGrid(columns: columns, alignment: .center, spacing: 10) {
            if searchModel.userLoading, searchModel.users.isEmpty {
                ProgressView("正在搜索 UP 主")
                    .gridCellColumns(layout.columnCount)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            } else if searchModel.users.isEmpty, !searchModel.userLoading {
                ContentUnavailableView("没有找到相关 UP 主", systemImage: "person.crop.circle")
                    .gridCellColumns(layout.columnCount)
                    .padding(.vertical, 40)
            } else {
                ForEach(searchModel.users) { user in
                    SearchUserRow(user: user)
                }

                if searchModel.userHasMore {
                    FeedLoadMoreFooter(
                        anchorID: searchModel.users.count,
                        hasMore: searchModel.userHasMore,
                        loadingMore: searchModel.userLoadingMore,
                        onLoadMore: {
                            Task { await searchModel.loadUsers(reset: false) }
                        }
                    )
                    .gridCellColumns(layout.columnCount)
                }
            }
        }
        .frame(width: layout.gridWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, AppLayout.searchUserResultsHorizontalInset)
    }
}

private struct SearchPageMetrics {
    let horizontalPadding: CGFloat
    let resultsContentWidth: CGFloat
    let userResultLayout: SearchUserResultLayout

    init(viewportWidth: CGFloat) {
        if viewportWidth < AppLayout.searchPageCompactBreakpoint {
            horizontalPadding = AppLayout.mainContentPaddingCompact
        } else {
            horizontalPadding = max(
                AppLayout.mainContentPaddingCompact,
                (viewportWidth - AppLayout.searchPageMaxWidth) * 0.42
            )
        }
        resultsContentWidth = max(0, viewportWidth - AppLayout.feedHorizontalInset * 2)
        let userResultsContentWidth = max(
            0,
            resultsContentWidth - AppLayout.searchUserResultsHorizontalInset * 2
        )
        userResultLayout = AppLayout.searchUserResultLayout(contentWidth: userResultsContentWidth)
    }
}

private struct SearchChipFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxLineWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxLineWidth = max(maxLineWidth, min(x, maxWidth))
        }

        return CGSize(width: maxLineWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

private struct SearchTextActionButton: View {
    let title: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isHovered ? BiliTheme.pink : Color(red: 0.45, green: 0.45, blue: 0.48))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    isHovered ? BiliTheme.pink.opacity(0.08) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct SearchTypeSegmentedControl: View {
    @Binding var selection: SearchResultTab
    @State private var isPressing = false
    @State private var dragX: CGFloat?
    @State private var animationTrigger = 0

    private let outerPadding: CGFloat = 5
    private let indicatorInset: CGFloat = 3

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let segmentWidth = max(1, (size.width - outerPadding * 2) / CGFloat(SearchResultTab.allCases.count))
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
                SearchTypeLiquidIndicator(isPressing: isPressing, animationTrigger: animationTrigger)
                    .frame(width: indicatorWidth, height: indicatorHeight)
                    .offset(x: indicatorX, y: outerPadding)
                    .animation(
                        isPressing
                        ? .interactiveSpring(response: 0.18, dampingFraction: 0.78, blendDuration: 0.02)
                        : .spring(response: 0.34, dampingFraction: 0.58, blendDuration: 0.04),
                        value: indicatorX
                    )
                    .animation(.spring(response: 0.22, dampingFraction: 0.62, blendDuration: 0.02), value: isPressing)

                HStack(spacing: 0) {
                    ForEach(SearchResultTab.allCases) { tab in
                        Text(tab.title)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Color.black.opacity(selection == tab ? 0.92 : 0.82))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .frame(height: indicatorHeight)
                            .offset(y: outerPadding)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                select(tab)
                            }
                    }
                }
            }
            .contentShape(Capsule(style: .continuous))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isPressing {
                            withAnimation(.spring(response: 0.18, dampingFraction: 0.68, blendDuration: 0.02)) {
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
                        withAnimation(.spring(response: 0.36, dampingFraction: 0.56, blendDuration: 0.04)) {
                            isPressing = false
                        }
                    }
            )
        }
        .frame(width: AppLayout.searchTypeToggleWidth, height: AppLayout.searchBarHeight)
        .background(Color.white.opacity(0.78), in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.035), radius: 6, x: 0, y: 2)
        .contentShape(Capsule(style: .continuous))
    }

    private var selectedIndex: Int {
        SearchResultTab.allCases.firstIndex(of: selection) ?? 0
    }

    private func select(_ tab: SearchResultTab) {
        guard selection != tab else {
            animationTrigger += 1
            return
        }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.58, blendDuration: 0.04)) {
            selection = tab
        }
        animationTrigger += 1
    }

    private func updateSelection(for x: CGFloat, segmentWidth: CGFloat) {
        let adjustedX = x - outerPadding
        let index = min(
            SearchResultTab.allCases.count - 1,
            max(0, Int((adjustedX / segmentWidth).rounded(.down)))
        )
        let tab = SearchResultTab.allCases[index]
        guard selection != tab else { return }
        withAnimation(.interactiveSpring(response: 0.20, dampingFraction: 0.72, blendDuration: 0.02)) {
            selection = tab
        }
    }

    private func clampedIndicatorX(centerX: CGFloat, indicatorWidth: CGFloat, totalWidth: CGFloat) -> CGFloat {
        let expandedOverflow = indicatorWidth * 0.08
        return min(
            totalWidth - outerPadding - indicatorWidth - expandedOverflow,
            max(outerPadding + expandedOverflow, centerX - indicatorWidth / 2)
        )
    }
}

private struct SearchTypeLiquidIndicator: View {
    let isPressing: Bool
    let animationTrigger: Int

    var body: some View {
        Capsule(style: .continuous)
            .fill(Color(red: 0.92, green: 0.92, blue: 0.93))
            .glassEffect(.regular.interactive(), in: .capsule)
            .phaseAnimator(
                SearchTypeSelectionPhase.allCases,
                trigger: animationTrigger
            ) { content, phase in
                content
                    .scaleEffect(
                        x: isPressing ? 1.12 : phase.xScale,
                        y: isPressing ? 1.08 : phase.yScale
                    )
                    .blur(radius: isPressing ? 0.18 : phase.blurRadius)
                    .shadow(
                        color: .black.opacity(isPressing ? 0.08 : 0.025),
                        radius: isPressing ? 8 : 3,
                        x: 0,
                        y: isPressing ? 3 : 1
                    )
            } animation: { phase in
                phase.animation
            }
    }
}

private enum SearchTypeSelectionPhase: CaseIterable {
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
        case .droplet: 0.90
        case .rebound: 1.04
        }
    }

    var blurRadius: CGFloat {
        self == .droplet ? 0.2 : 0
    }

    var animation: Animation {
        switch self {
        case .resting:
            .linear(duration: 0.01)
        case .droplet:
            .smooth(duration: 0.11)
        case .rebound:
            .spring(response: 0.18, dampingFraction: 0.58, blendDuration: 0.02)
        case .settled:
            .spring(response: 0.26, dampingFraction: 0.68, blendDuration: 0.04)
        }
    }
}

private struct SearchHotCapsuleChip: View {
    let item: BiliHotSearchItem
    let chipWidth: CGFloat
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                SearchHotRankBadge(rank: item.rank)
                Text(item.showName)
                    .font(.system(size: 13))
                    .foregroundStyle(Color(red: 0.12, green: 0.12, blue: 0.14))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(width: chipWidth, alignment: .leading)
            .background(chipBackground, in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .stroke(AppLayout.searchSurfaceBorder, lineWidth: 0.6)
            }
            .shadow(
                color: .black.opacity(isHovered ? 0.08 : 0),
                radius: isHovered ? 10 : 0,
                x: 0,
                y: isHovered ? 4 : 0
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }

    private var chipBackground: Color {
        isHovered ? AppLayout.searchChipHoverFill : Color.white
    }
}

private struct MacSearchSuggestCombo: View {
    @Binding var text: String
    @ObservedObject var searchModel: SearchViewModel
    var focusRequest = 0
    @Binding var isDropdownPresented: Bool
    @Binding var dropdownActiveEntryID: String?

    @FocusState private var isFocused: Bool
    @State private var isHovered = false
    @State private var dropdownSuppressed = false
    @State private var isClearingText = false
    @State private var clearTask: Task<Void, Never>?

    let onSearch: (String) -> Void
    let onVideoSelect: (BiliVideo) -> Void

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var shouldShowDropdown: Bool {
        isFocused
            && !searchModel.isShowingResults
            && !dropdownSuppressed
            && !trimmedText.isEmpty
    }

    private var dropdownEntries: [SearchDropdownEntry] {
        var entries = searchModel.suggests.map { SearchDropdownEntry.suggest($0) }
        entries.append(contentsOf: searchModel.previewVideos.map { .video($0) })
        return entries
    }

    var body: some View {
        searchField
            .frame(width: AppLayout.searchBarPreferredWidth, height: AppLayout.searchBarHeight, alignment: .leading)
            .onChange(of: shouldShowDropdown) { _, visible in
                isDropdownPresented = visible
            }
            .onChange(of: isFocused) { _, focused in
                if !focused {
                    dropdownActiveEntryID = nil
                }
            }
        .onChange(of: text) { _, _ in
            guard !isClearingText else { return }
            dropdownSuppressed = false
            dropdownActiveEntryID = nil
            searchModel.handleInputChange(text)
        }
        .onChange(of: dropdownEntries.map(\.id)) { _, ids in
            guard let dropdownActiveEntryID, !ids.contains(dropdownActiveEntryID) else { return }
            self.dropdownActiveEntryID = ids.first
        }
        .onAppear {
            focusSearchField()
        }
        .onChange(of: focusRequest) { _, _ in
            focusSearchField()
        }
        .onDisappear {
            clearTask?.cancel()
        }
    }

    private func focusSearchField() {
        DispatchQueue.main.async {
            isFocused = true
        }
    }

    private func searchFieldKeyHandlers<Content: View>(_ content: Content) -> some View {
        content
            .onKeyPress(.escape) {
                if shouldShowDropdown {
                    dropdownSuppressed = true
                    dropdownActiveEntryID = nil
                    return .handled
                }
                return .ignored
            }
            .onKeyPress(.upArrow) {
                guard shouldShowDropdown, !dropdownEntries.isEmpty else { return .ignored }
                moveActiveEntry(by: -1)
                return .handled
            }
            .onKeyPress(.downArrow) {
                guard shouldShowDropdown, !dropdownEntries.isEmpty else { return .ignored }
                moveActiveEntry(by: 1)
                return .handled
            }
    }

    private var searchField: some View {
        searchFieldKeyHandlers(
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Color(red: 0.55, green: 0.55, blue: 0.58))

                TextField("搜索视频、UP主", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($isFocused)
                    .onSubmit {
                        if let dropdownActiveEntryID,
                           let entry = dropdownEntries.first(where: { $0.id == dropdownActiveEntryID }) {
                            activateEntry(entry)
                        } else {
                            onSearch(text)
                        }
                    }
                    .onKeyPress(.return) {
                        if let dropdownActiveEntryID,
                           let entry = dropdownEntries.first(where: { $0.id == dropdownActiveEntryID }) {
                            activateEntry(entry)
                            return .handled
                        }
                        return .ignored
                    }

                if !text.isEmpty {
                    Button {
                        clearTextWithAnimation()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white.opacity(0.95))
                            .frame(width: 18, height: 18)
                            .background(Color.black.opacity(0.28), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: AppLayout.searchBarHeight)
            .glassEffect(.clear, in: .capsule)
            .overlay {
                Capsule(style: .continuous)
                    .stroke(searchFieldBorderColor, lineWidth: isFocused ? 1.2 : 0.6)
            }
            .shadow(color: .black.opacity(isFocused ? 0.08 : 0.04), radius: isFocused ? 10 : 6, x: 0, y: 3)
            .contentShape(Capsule(style: .continuous))
            .onTapGesture {
                isFocused = true
            }
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) {
                    isHovered = hovering
                }
            }
        )
    }

    private var searchFieldBorderColor: Color {
        if isFocused {
            return BiliTheme.pink.opacity(0.38)
        }
        if isHovered {
            return Color.black.opacity(0.12)
        }
        return AppLayout.searchSurfaceBorder
    }

    private func clearTextWithAnimation() {
        clearTask?.cancel()
        isClearingText = true
        dropdownActiveEntryID = nil
        withAnimation(.easeOut(duration: 0.16)) {
            dropdownSuppressed = true
            text = ""
        }
        isFocused = true

        clearTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.20)) {
                searchModel.resetInput()
            }
            dropdownSuppressed = false
            isClearingText = false
        }
    }

    private func moveActiveEntry(by offset: Int) {
        let entries = dropdownEntries
        guard !entries.isEmpty else { return }
        guard let dropdownActiveEntryID,
              let currentIndex = entries.firstIndex(where: { $0.id == dropdownActiveEntryID }) else {
            self.dropdownActiveEntryID = entries[offset > 0 ? 0 : entries.count - 1].id
            return
        }
        let nextIndex = (currentIndex + offset + entries.count) % entries.count
        self.dropdownActiveEntryID = entries[nextIndex].id
    }

    private func activateEntry(_ entry: SearchDropdownEntry) {
        dropdownSuppressed = true
        dropdownActiveEntryID = nil
        switch entry {
        case .suggest(let keyword):
            text = keyword
            onSearch(keyword)
        case .video(let video):
            dropdownSuppressed = true
            onVideoSelect(video)
        }
    }
}

private struct SearchDropdownRevealModifier: ViewModifier, Animatable {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .scaleEffect(x: 1, y: max(0.001, progress), anchor: .top)
            .opacity(Double(progress))
    }
}

private extension AnyTransition {
    static var searchDropdownReveal: AnyTransition {
        .modifier(
            active: SearchDropdownRevealModifier(progress: 0),
            identity: SearchDropdownRevealModifier(progress: 1)
        )
    }
}

private enum SearchDropdownEntry: Identifiable, Equatable {
    case suggest(String)
    case video(BiliVideo)

    var id: String {
        switch self {
        case .suggest(let value): "suggest-\(value)"
        case .video(let video): "video-\(video.bvid)"
        }
    }
}

private struct SearchSuggestDropdownPanel: View {
    let entries: [SearchDropdownEntry]
    let query: String
    let previewLoading: Bool
    let activeEntryID: String?
    let onActivate: (SearchDropdownEntry) -> Void
    let onHoverEntry: (String?) -> Void

    var body: some View {
        Group {
            if entries.isEmpty, !previewLoading {
                SearchDropdownEmptyHint(text: "暂无联想结果")
            } else {
                HStack(alignment: .top, spacing: 0) {
                    MacOverlayScrollView {
                        suggestionsColumn
                    }
                    .frame(maxWidth: .infinity, maxHeight: AppLayout.searchSuggestionPanelMaxHeight)

                    SearchDropdownVerticalDivider()
                        .padding(.vertical, 14)

                    MacOverlayScrollView {
                        resultsColumn
                    }
                    .frame(maxWidth: .infinity, maxHeight: AppLayout.searchSuggestionPanelMaxHeight)
                }
                .padding(.vertical, 8)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background {
            SearchDropdownBackground(cornerRadius: 20)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.12), radius: 16, x: 0, y: 12)
    }

    @ViewBuilder
    private var suggestionsColumn: some View {
        let suggestEntries = entries.compactMap { entry -> String? in
            if case .suggest(let keyword) = entry { return keyword }
            return nil
        }

        if !suggestEntries.isEmpty {
            dropdownSection(title: "搜索建议") {
                ForEach(Array(suggestEntries.enumerated()), id: \.offset) { index, keyword in
                    let entryID = SearchDropdownEntry.suggest(keyword).id
                    SearchDropdownKeywordRow(
                        icon: "magnifyingglass",
                        title: keyword,
                        highlight: query,
                        isActive: activeEntryID == entryID,
                        onTap: { onActivate(.suggest(keyword)) },
                        onHover: { onHoverEntry(entryID) }
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if index < suggestEntries.count - 1 {
                        SearchDropdownDivider()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        } else {
            dropdownSection(title: "搜索建议") {
                SearchDropdownEmptyHint(text: "暂无联想")
                    .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private var resultsColumn: some View {
        let videoEntries = entries.compactMap { entry -> BiliVideo? in
            if case .video(let video) = entry { return video }
            return nil
        }

        if previewLoading, videoEntries.isEmpty {
            dropdownSection(title: "搜索结果") {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("正在加载结果")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(red: 0.55, green: 0.55, blue: 0.58))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 16)
            }
        }

        if !videoEntries.isEmpty {
            dropdownSection(title: "搜索结果") {
                ForEach(Array(videoEntries.enumerated()), id: \.element.bvid) { index, video in
                    let entryID = SearchDropdownEntry.video(video).id
                    SearchDropdownVideoRow(
                        video: video,
                        highlight: query,
                        isActive: activeEntryID == entryID,
                        onSelect: { onActivate(.video(video)) },
                        onHover: { onHoverEntry(entryID) }
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if index < videoEntries.count - 1 {
                        SearchDropdownDivider()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func dropdownSection(title: String?, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(red: 0.55, green: 0.55, blue: 0.58))
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
            }
            content()
        }
    }
}

private struct SearchDropdownBackground: View {
    let cornerRadius: CGFloat

    var body: some View {
        ZStack {
            SearchDropdownBlur(cornerRadius: cornerRadius)
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.90))
        }
    }
}

private struct SearchDropdownBlur: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .withinWindow
        view.state = .active
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.layer?.cornerRadius = cornerRadius
        nsView.layer?.cornerCurve = .continuous
        nsView.layer?.masksToBounds = true
    }
}

private struct SearchDropdownEmptyHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Color(red: 0.55, green: 0.55, blue: 0.58))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
    }
}

private struct SearchDropdownDivider: View {
    var body: some View {
        Divider()
            .overlay(Color.black.opacity(0.06))
            .padding(.leading, 52)
            .padding(.trailing, 12)
    }
}

private struct SearchDropdownVerticalDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.black.opacity(0.07))
            .frame(width: 0.6)
    }
}

private struct SearchDropdownKeywordRow: View {
    let icon: String
    var iconTint: Color = Color(red: 0.55, green: 0.55, blue: 0.58)
    let title: String
    let highlight: String
    let isActive: Bool
    let onTap: () -> Void
    let onHover: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(iconTint)
                    .frame(width: 20)

                SearchKeywordHighlightText(text: title, keyword: highlight, fontSize: 15)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .frame(height: 44, alignment: .center)
            .background(rowBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { onHover() }
        }
    }

    private var rowBackground: Color {
        isActive ? AppLayout.searchRowHoverFill : Color.clear
    }
}

private struct SearchDropdownVideoRow: View {
    let video: BiliVideo
    let highlight: String
    let isActive: Bool
    let onSelect: () -> Void
    let onHover: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .center, spacing: 12) {
                RemoteCover(
                    url: video.coverURL,
                    aspectRatio: 1,
                    width: 56,
                    height: 56,
                    appliesCornerClip: true
                )

                VStack(alignment: .leading, spacing: 4) {
                    SearchKeywordHighlightText(
                        text: video.title,
                        keyword: highlight,
                        fontSize: 15,
                        fontWeight: .medium
                    )
                        .lineLimit(1)

                    Text(video.authorName)
                        .font(.system(size: 13))
                        .foregroundStyle(Color(red: 0.55, green: 0.55, blue: 0.58))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(isActive ? AppLayout.searchRowHoverFill : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { onHover() }
        }
    }
}

private struct SearchKeywordHighlightText: View {
    let text: String
    let keyword: String
    var fontSize: CGFloat = 15
    var fontWeight: Font.Weight = .regular
    var highlightWeight: Font.Weight = .semibold

    private var defaultTextColor: Color {
        Color(red: 0.12, green: 0.12, blue: 0.14)
    }

    private var baseFont: Font {
        .system(size: fontSize, weight: fontWeight)
    }

    private var highlightFont: Font {
        .system(size: fontSize, weight: highlightWeight)
    }

    var body: some View {
        Text(highlightedAttributedString)
    }

    private var highlightedAttributedString: AttributedString {
        let source = text
        let term = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else {
            var plain = AttributedString(source)
            plain.foregroundColor = defaultTextColor
            plain.font = baseFont
            return plain
        }

        var result = AttributedString()
        var searchStart = source.startIndex
        while searchStart < source.endIndex,
              let range = source.range(of: term, options: [.caseInsensitive], range: searchStart..<source.endIndex) {
            if range.lowerBound > searchStart {
                var prefix = AttributedString(String(source[searchStart..<range.lowerBound]))
                prefix.foregroundColor = defaultTextColor
                prefix.font = baseFont
                result.append(prefix)
            }
            var match = AttributedString(String(source[range]))
            match.foregroundColor = BiliTheme.pink
            match.font = highlightFont
            result.append(match)
            searchStart = range.upperBound
        }
        if searchStart < source.endIndex {
            var suffix = AttributedString(String(source[searchStart...]))
            suffix.foregroundColor = defaultTextColor
            suffix.font = baseFont
            result.append(suffix)
        }
        return result
    }
}

private struct SearchHistoryChip: View {
    let title: String
    let onTap: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onTap) {
                Text(title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .foregroundStyle(Color(red: 0.18, green: 0.18, blue: 0.20))
            }
            .buttonStyle(.plain)

            if isHovered {
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color(red: 0.55, green: 0.55, blue: 0.58))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            isHovered ? AppLayout.searchChipHoverFill : AppLayout.searchChipFill,
            in: Capsule(style: .continuous)
        )
        .overlay {
            Capsule(style: .continuous)
                .stroke(Color.black.opacity(isHovered ? 0.08 : 0.04), lineWidth: 0.5)
        }
        .onHover { isHovered = $0 }
    }
}

private struct SearchHotRankBadge: View {
    let rank: Int

    private var color: Color {
        switch rank {
        case 1: Color(red: 0.996, green: 0.176, blue: 0.275)
        case 2: Color(red: 1.0, green: 0.4, blue: 0.0)
        case 3: Color(red: 1.0, green: 0.667, blue: 0.0)
        default: Color.secondary.opacity(0.55)
        }
    }

    var body: some View {
        Text("\(rank)")
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(color)
            .frame(width: 32, alignment: .leading)
    }
}

private struct SearchUserRow: View {
    let user: BiliSearchUser

    @State private var isHovered = false

    private let signLineHeight: CGFloat = 18

    var body: some View {
        NavigationLink(
            value: UserProfileRequest(
                mid: user.mid,
                seedName: user.name,
                seedFaceURL: user.faceURL
            )
        ) {
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
                    HStack(spacing: 4) {
                        Text(user.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color(red: 0.12, green: 0.12, blue: 0.14))
                            .lineLimit(1)
                        if user.level > 0 {
                            BiliUserLevelIcon(level: user.level, width: 24, height: 15)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 20, maxHeight: 20, alignment: .leading)

                    Text("\(user.fans.compactCount) 粉丝")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(red: 0.55, green: 0.55, blue: 0.58))
                        .frame(maxWidth: .infinity, minHeight: signLineHeight, maxHeight: signLineHeight, alignment: .leading)

                    Text(user.sign.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.system(size: 13))
                        .foregroundStyle(Color(red: 0.55, green: 0.55, blue: 0.58))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(
                            maxWidth: .infinity,
                            minHeight: signLineHeight * 2,
                            maxHeight: signLineHeight * 2,
                            alignment: .topLeading
                        )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 18)
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
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var capsuleBackground: Color {
        isHovered ? AppLayout.searchChipHoverFill : Color.white
    }

    private var capsuleBorderColor: Color {
        isHovered ? Color.black.opacity(0.10) : AppLayout.searchSurfaceBorder
    }
}
