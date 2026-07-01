import AppKit
import Combine
import SwiftUI

enum SearchResultTab: String, CaseIterable, Identifiable {
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
        selectedTab = .videos
        searchGeneration += 1

        let generation = searchGeneration
        Task { @MainActor in
            await loadVideos(reset: true, generation: generation)
            await loadUsers(reset: true, generation: generation)
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
                previewVideos = Array(result.items.prefix(6))
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
            } else {
                var seen = Set(videos.map(\.bvid))
                videos.append(contentsOf: result.items.filter { seen.insert($0.bvid).inserted })
            }
            videoPage = result.page
            videoHasMore = result.hasMore
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
            } else {
                var seen = Set(users.map(\.mid))
                users.append(contentsOf: result.items.filter { seen.insert($0.mid).inserted })
            }
            userPage = result.page
            userHasMore = result.hasMore
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
    @State private var isSearchDropdownOpen = false

    var body: some View {
        GeometryReader { geometry in
            let metrics = SearchPageMetrics(viewportWidth: geometry.size.width)

            ZStack(alignment: .topLeading) {
                MacOverlayScrollView {
                    HStack(spacing: 0) {
                        Spacer(minLength: metrics.horizontalPadding)

                        VStack(alignment: .leading, spacing: 32) {
                            Color.clear
                                .frame(height: searchComboReservedHeight)

                            if searchModel.isShowingResults {
                                searchResultsContent(metrics: metrics)
                            } else if !isSearchDropdownOpen {
                                discoverySection
                            }
                        }
                        .frame(maxWidth: metrics.containerWidth, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Spacer(minLength: metrics.horizontalPadding)
                    }
                    .padding(.top, AppLayout.floatingChromeReservedHeight + AppLayout.searchPageTopInset)
                    .padding(.bottom, 32)
                }

                if isSearchDropdownOpen {
                    Color.black.opacity(0.001)
                        .ignoresSafeArea()
                        .onTapGesture {
                            isSearchDropdownOpen = false
                        }
                        .zIndex(8)
                }

                HStack(spacing: 0) {
                    Spacer(minLength: metrics.horizontalPadding)

                    MacSearchSuggestCombo(
                        text: $queryText,
                        searchModel: searchModel,
                        isDropdownOpen: $isSearchDropdownOpen,
                        onSearch: { runSearch($0) },
                        onVideoSelect: { video in
                            isSearchDropdownOpen = false
                            navigationPath.append(VideoPlaybackRequest(video))
                        }
                    )
                    .frame(width: metrics.searchBarWidth, alignment: .leading)

                    Spacer(minLength: metrics.horizontalPadding)
                }
                .padding(.top, AppLayout.floatingChromeReservedHeight + AppLayout.searchPageTopInset)
                .zIndex(10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            searchModel.credential = model.account?.credential
            searchModel.prepare()
            Task { await searchModel.loadDiscoveryIfNeeded() }
        }
        .onChange(of: model.account?.credential) { _, credential in
            searchModel.credential = credential
        }
    }

    private var searchComboReservedHeight: CGFloat {
        52 + 8
    }

    private func runSearch(_ keyword: String) {
        let value = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        isSearchDropdownOpen = false
        DispatchQueue.main.async {
            queryText = value
            searchModel.performSearch(value)
        }
    }

    private var discoverySection: some View {
        VStack(alignment: .leading, spacing: 32) {
            searchHistorySection
            hotSearchSection
        }
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

                Spacer(minLength: 0)
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

    private var hotSearchSection: some View {
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
                    hotSearchColumn(columns.left)
                    hotSearchColumn(columns.right)
                }
            }
        }
    }

    private func hotSearchColumns(_ items: [BiliHotSearchItem]) -> (left: [BiliHotSearchItem], right: [BiliHotSearchItem]) {
        let split = (items.count + 1) / 2
        return (Array(items.prefix(split)), Array(items.dropFirst(split)))
    }

    private func hotSearchColumn(_ items: [BiliHotSearchItem]) -> some View {
        VStack(spacing: 8) {
            ForEach(items) { item in
                SearchHotCapsuleChip(item: item) {
                    runSearch(item.keyword)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func searchResultsContent(metrics: SearchPageMetrics) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 24) {
                ForEach(SearchResultTab.allCases) { tab in
                    Button {
                        searchModel.selectedTab = tab
                    } label: {
                        Text(tab.title)
                            .font(.system(size: 15, weight: searchModel.selectedTab == tab ? .semibold : .regular))
                            .foregroundStyle(searchModel.selectedTab == tab ? BiliTheme.pink : Color(red: 0.45, green: 0.45, blue: 0.48))
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(SearchTabButtonStyle(isSelected: searchModel.selectedTab == tab))
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: metrics.searchBarWidth, alignment: .leading)

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
                    userResults
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: metrics.containerWidth, alignment: .leading)
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
                VideoFeedGrid(
                    videos: searchModel.videos,
                    trailing: {
                        if searchModel.videoHasMore {
                            searchLoadMoreFooter(
                                loading: searchModel.videoLoadingMore,
                                onLoadMore: {
                                    Task { await searchModel.loadVideos(reset: false) }
                                }
                            )
                        }
                    }
                )
            }
        }
    }

    private var userResults: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            if searchModel.userLoading, searchModel.users.isEmpty {
                ProgressView("正在搜索 UP 主")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            } else if searchModel.users.isEmpty, !searchModel.userLoading {
                ContentUnavailableView("没有找到相关 UP 主", systemImage: "person.crop.circle")
                    .padding(.vertical, 40)
            } else {
                ForEach(searchModel.users) { user in
                    SearchUserRow(user: user)
                    Divider()
                        .overlay(Color.black.opacity(0.06))
                        .padding(.leading, 88)
                }

                if searchModel.userHasMore {
                    searchLoadMoreFooter(
                        loading: searchModel.userLoadingMore,
                        onLoadMore: {
                            Task { await searchModel.loadUsers(reset: false) }
                        }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func searchLoadMoreFooter(loading: Bool, onLoadMore: @escaping () -> Void) -> some View {
        Group {
            if loading {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("正在加载更多")
                        .foregroundStyle(.secondary)
                }
            } else {
                Color.clear
                    .frame(height: 1)
                    .onAppear(perform: onLoadMore)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}

private struct SearchPageMetrics {
    let containerWidth: CGFloat
    let searchBarWidth: CGFloat
    let horizontalPadding: CGFloat

    init(viewportWidth: CGFloat) {
        if viewportWidth < AppLayout.searchPageCompactBreakpoint {
            horizontalPadding = AppLayout.mainContentPaddingCompact
            containerWidth = max(0, viewportWidth - horizontalPadding * 2)
            searchBarWidth = containerWidth
        } else {
            horizontalPadding = max(
                AppLayout.mainContentPaddingCompact,
                (viewportWidth - AppLayout.searchPageMaxWidth) * 0.42
            )
            containerWidth = min(AppLayout.searchPageMaxWidth, viewportWidth - horizontalPadding * 2)
            searchBarWidth = min(
                max(AppLayout.searchBarMinWidth, AppLayout.searchBarPreferredWidth),
                containerWidth
            )
        }
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

private struct SearchTabButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
            .background(
                configuration.isPressed ? BiliTheme.pink.opacity(isSelected ? 0.10 : 0.05) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
    }
}

private struct SearchHotCapsuleChip: View {
    let item: BiliHotSearchItem
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
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white, in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .stroke(borderColor, lineWidth: 0.6)
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }

    private var borderColor: Color {
        if isHovered {
            return BiliTheme.pink.opacity(0.35)
        }
        return AppLayout.searchSurfaceBorder
    }
}

private struct MacSearchSuggestCombo: View {
    @Binding var text: String
    @ObservedObject var searchModel: SearchViewModel
    @Binding var isDropdownOpen: Bool

    @FocusState private var isFocused: Bool
    @State private var isHovered = false
    @State private var activeEntryID: String?
    @State private var dropdownSuppressed = false

    let onSearch: (String) -> Void
    let onVideoSelect: (BiliVideo) -> Void

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var shouldShowDropdown: Bool {
        isFocused
            && !searchModel.isShowingResults
            && !dropdownSuppressed
            && isDropdownOpen
    }

    private var dropdownEntries: [SearchDropdownEntry] {
        if trimmedText.isEmpty {
            var entries: [SearchDropdownEntry] = searchModel.visibleHistory.map { .history($0) }
            entries.append(contentsOf: searchModel.hotWords.prefix(10).map { .hot($0) })
            return entries
        }
        var entries = searchModel.suggests.map { SearchDropdownEntry.suggest($0) }
        entries.append(contentsOf: searchModel.previewVideos.map { .video($0) })
        return entries
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            searchField

            if shouldShowDropdown {
                SearchSuggestDropdownPanel(
                    entries: dropdownEntries,
                    query: trimmedText,
                    previewLoading: searchModel.previewLoading,
                    activeEntryID: activeEntryID,
                    onActivate: activateEntry,
                    onHoverEntry: { activeEntryID = $0 }
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeOut(duration: 0.16), value: shouldShowDropdown)
        .onChange(of: isFocused) { _, focused in
            if focused {
                dropdownSuppressed = false
                isDropdownOpen = true
            } else {
                isDropdownOpen = false
                activeEntryID = nil
            }
        }
        .onChange(of: text) { _, _ in
            dropdownSuppressed = false
            if isFocused {
                isDropdownOpen = true
            }
            activeEntryID = nil
            searchModel.handleInputChange(text)
        }
        .onChange(of: dropdownEntries.map(\.id)) { _, ids in
            guard let activeEntryID, !ids.contains(activeEntryID) else { return }
            self.activeEntryID = ids.first
        }
    }

    private func searchFieldKeyHandlers<Content: View>(_ content: Content) -> some View {
        content
            .onKeyPress(.escape) {
                if shouldShowDropdown {
                    dropdownSuppressed = true
                    isDropdownOpen = false
                    activeEntryID = nil
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
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(Color(red: 0.55, green: 0.55, blue: 0.58))

                TextField("搜索视频、UP主", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($isFocused)
                    .onSubmit {
                        if let activeEntryID,
                           let entry = dropdownEntries.first(where: { $0.id == activeEntryID }) {
                            activateEntry(entry)
                        } else {
                            onSearch(text)
                        }
                    }
                    .onKeyPress(.return) {
                        if let activeEntryID,
                           let entry = dropdownEntries.first(where: { $0.id == activeEntryID }) {
                            activateEntry(entry)
                            return .handled
                        }
                        return .ignored
                    }

                if !text.isEmpty {
                    Button {
                        text = ""
                        searchModel.resetInput()
                        isDropdownOpen = true
                        dropdownSuppressed = false
                        isFocused = true
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
            .padding(.horizontal, 18)
            .frame(height: 52)
            .background {
                Capsule(style: .continuous)
                    .fill(isHovered && !isFocused ? Color.black.opacity(0.02) : Color.white)
            }
            .overlay {
                Capsule(style: .continuous)
                    .stroke(searchFieldBorderColor, lineWidth: isFocused ? 1.4 : 0.8)
            }
            .shadow(color: .black.opacity(isFocused ? 0.08 : 0.04), radius: isFocused ? 12 : 8, x: 0, y: 4)
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

    private func moveActiveEntry(by offset: Int) {
        let entries = dropdownEntries
        guard !entries.isEmpty else { return }
        guard let activeEntryID,
              let currentIndex = entries.firstIndex(where: { $0.id == activeEntryID }) else {
            self.activeEntryID = entries[offset > 0 ? 0 : entries.count - 1].id
            return
        }
        let nextIndex = (currentIndex + offset + entries.count) % entries.count
        self.activeEntryID = entries[nextIndex].id
    }

    private func activateEntry(_ entry: SearchDropdownEntry) {
        isDropdownOpen = false
        dropdownSuppressed = true
        activeEntryID = nil
        switch entry {
        case .history(let keyword), .suggest(let keyword):
            text = keyword
            onSearch(keyword)
        case .hot(let item):
            text = item.keyword
            onSearch(item.keyword)
        case .video(let video):
            isDropdownOpen = false
            dropdownSuppressed = true
            onVideoSelect(video)
        }
    }
}

private enum SearchDropdownEntry: Identifiable, Equatable {
    case history(String)
    case hot(BiliHotSearchItem)
    case suggest(String)
    case video(BiliVideo)

    var id: String {
        switch self {
        case .history(let value): "history-\(value)"
        case .hot(let item): "hot-\(item.id)"
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
        MacOverlayScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if entries.isEmpty, !previewLoading {
                    SearchDropdownEmptyHint(text: query.isEmpty ? "输入关键词开始搜索" : "暂无联想结果")
                } else {
                    if query.isEmpty {
                        discoveryContent
                    } else {
                        typedQueryContent
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .frame(maxHeight: 420)
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
    private var discoveryContent: some View {
        let historyEntries = entries.compactMap { entry -> String? in
            if case .history(let keyword) = entry { return keyword }
            return nil
        }
        let hotEntries = entries.compactMap { entry -> BiliHotSearchItem? in
            if case .hot(let item) = entry { return item }
            return nil
        }

        if !historyEntries.isEmpty {
            dropdownSection(title: "搜索历史") {
                ForEach(Array(historyEntries.enumerated()), id: \.offset) { index, keyword in
                    let entryID = SearchDropdownEntry.history(keyword).id
                    SearchDropdownKeywordRow(
                        icon: "clock.arrow.circlepath",
                        title: keyword,
                        highlight: query,
                        isActive: activeEntryID == entryID,
                        onTap: { onActivate(.history(keyword)) },
                        onHover: { onHoverEntry(entryID) }
                    )
                    if index < historyEntries.count - 1 || !hotEntries.isEmpty {
                        SearchDropdownDivider()
                    }
                }
            }
        }

        if !hotEntries.isEmpty {
            dropdownSection(title: "bilibili热搜") {
                ForEach(Array(hotEntries.enumerated()), id: \.element.id) { index, item in
                    let entryID = SearchDropdownEntry.hot(item).id
                    SearchDropdownKeywordRow(
                        icon: "flame.fill",
                        iconTint: hotIconColor(for: item.rank),
                        title: item.showName,
                        highlight: query,
                        isActive: activeEntryID == entryID,
                        onTap: { onActivate(.hot(item)) },
                        onHover: { onHoverEntry(entryID) }
                    )
                    if index < hotEntries.count - 1 {
                        SearchDropdownDivider()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var typedQueryContent: some View {
        let suggestEntries = entries.compactMap { entry -> String? in
            if case .suggest(let keyword) = entry { return keyword }
            return nil
        }
        let videoEntries = entries.compactMap { entry -> BiliVideo? in
            if case .video(let video) = entry { return video }
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
                    if index < suggestEntries.count - 1 || !videoEntries.isEmpty || previewLoading {
                        SearchDropdownDivider()
                    }
                }
            }
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
                    if index < videoEntries.count - 1 {
                        SearchDropdownDivider()
                    }
                }
            }
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

    private func hotIconColor(for rank: Int) -> Color {
        switch rank {
        case 1: Color(red: 0.996, green: 0.176, blue: 0.275)
        case 2: Color(red: 1.0, green: 0.4, blue: 0.0)
        case 3: Color(red: 1.0, green: 0.667, blue: 0.0)
        default: Color(red: 0.55, green: 0.55, blue: 0.58)
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

                SearchKeywordHighlightText(text: title, keyword: highlight)
                    .font(.system(size: 15))
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
                    SearchKeywordHighlightText(text: video.title, keyword: highlight)
                        .font(.system(size: 15, weight: .medium))
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

    private var defaultTextColor: Color {
        Color(red: 0.12, green: 0.12, blue: 0.14)
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
            return plain
        }

        var result = AttributedString()
        var searchStart = source.startIndex
        while searchStart < source.endIndex,
              let range = source.range(of: term, options: [.caseInsensitive], range: searchStart..<source.endIndex) {
            if range.lowerBound > searchStart {
                var prefix = AttributedString(String(source[searchStart..<range.lowerBound]))
                prefix.foregroundColor = defaultTextColor
                result.append(prefix)
            }
            var match = AttributedString(String(source[range]))
            match.foregroundColor = BiliTheme.pink
            match.font = .body.weight(.semibold)
            result.append(match)
            searchStart = range.upperBound
        }
        if searchStart < source.endIndex {
            var suffix = AttributedString(String(source[searchStart...]))
            suffix.foregroundColor = defaultTextColor
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

    var body: some View {
        NavigationLink(
            value: UserProfileRequest(
                mid: user.mid,
                seedName: user.name,
                seedFaceURL: user.faceURL
            )
        ) {
            HStack(alignment: .top, spacing: 12) {
                AsyncImage(url: user.faceURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        Image(systemName: "person.fill")
                            .foregroundStyle(Color(red: 0.55, green: 0.55, blue: 0.58))
                    }
                }
                .frame(width: 52, height: 52)
                .clipShape(Circle())

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text(user.name)
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                        if user.level > 0 {
                            BiliUserLevelIcon(level: user.level, width: 30, height: 19)
                        }
                    }
                    Text("\(user.fans.compactCount) 粉丝")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(red: 0.55, green: 0.55, blue: 0.58))
                    if !user.sign.isEmpty {
                        Text(user.sign)
                            .font(.system(size: 13))
                            .foregroundStyle(Color(red: 0.55, green: 0.55, blue: 0.58))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 4)
            .background(isHovered ? AppLayout.searchRowHoverFill : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
