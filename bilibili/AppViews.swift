import AppKit
import SwiftUI

enum VideoCardLayout {
    static let minWidth: CGFloat = 288
    static let gridSpacing: CGFloat = 14
    static let coverAspect: CGFloat = 16.0 / 9.0
    static let cornerRadius: CGFloat = 10
    static let cardBorderColor = Color(red: 232 / 255, green: 232 / 255, blue: 232 / 255)
    static let coverHoverScale: CGFloat = 1.035
    static let coverHoverAnimation = Animation.interactiveSpring(response: 0.18, dampingFraction: 0.82, blendDuration: 0.04)
    static let coverHoverExitAnimation = Animation.easeOut(duration: 0.14)
    static let statsAuthorSpacing: CGFloat = 4
    static let metadataPadding = EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
    /// Feed 封面解码目标像素，避免滚动时为每个 cell 做 GeometryReader 测量。
    static func feedCoverPixelLength(displayScale: CGFloat) -> Int {
        Int((minWidth * max(1, displayScale) * 1.05).rounded(.up))
    }

    static func columnCount(for width: CGFloat) -> Int {
        guard width > 0 else { return 1 }
        return max(1, Int((width + gridSpacing) / (minWidth + gridSpacing)))
    }

    static func columnWidth(for totalWidth: CGFloat, columnCount: Int) -> CGFloat {
        let spacingTotal = CGFloat(max(columnCount - 1, 0)) * gridSpacing
        return max((totalWidth - spacingTotal) / CGFloat(columnCount), 1)
    }

    struct RowLayoutMetrics {
        let metadataPadding: EdgeInsets
        let usesLargeTitleFont: Bool
        let statsHeight: CGFloat
        let authorRowHeight: CGFloat
        let includesStats: Bool
        let statsAuthorSpacing: CGFloat

        static func feed(largeTypography: Bool, showsAuthor: Bool = true) -> RowLayoutMetrics {
            RowLayoutMetrics(
                metadataPadding: EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12),
                usesLargeTitleFont: largeTypography,
                statsHeight: largeTypography ? 24 : 20,
                authorRowHeight: showsAuthor ? (largeTypography ? 30 : 26) : 0,
                includesStats: true,
                statsAuthorSpacing: showsAuthor ? VideoCardLayout.statsAuthorSpacing : 0
            )
        }

        static let history = RowLayoutMetrics(
            metadataPadding: EdgeInsets(top: 8, leading: 12, bottom: 6, trailing: 12),
            usesLargeTitleFont: false,
            statsHeight: 0,
            authorRowHeight: 26,
            includesStats: false,
            statsAuthorSpacing: 0
        )

        func metadataHeight(titleAreaHeight: CGFloat) -> CGFloat {
            var height = metadataPadding.top + titleAreaHeight + metadataPadding.bottom + authorRowHeight
            if includesStats {
                height += statsHeight + statsAuthorSpacing
            }
            return height
        }
    }

    static func rowChunks<T>(_ items: [T], columnCount: Int) -> [[T]] {
        guard columnCount > 0 else { return items.isEmpty ? [] : [items] }
        return stride(from: 0, to: items.count, by: columnCount).map { start in
            Array(items[start..<min(start + columnCount, items.count)])
        }
    }

    static func titleNSFont(for metrics: RowLayoutMetrics) -> NSFont {
        if metrics.usesLargeTitleFont {
            let size = NSFont.preferredFont(forTextStyle: .title2).pointSize
            return NSFont.systemFont(ofSize: size, weight: .semibold)
        }
        let size = NSFont.preferredFont(forTextStyle: .title3).pointSize
        return NSFont.systemFont(ofSize: size, weight: .medium)
    }

    /// SwiftUI `Text` 实际行高略高于 AppKit `NSLayoutManager` 测量值。
    static let titleLineHeightScale: CGFloat = 1.14

    static func titleLineHeight(for metrics: RowLayoutMetrics) -> CGFloat {
        let font = titleNSFont(for: metrics)
        let appKitLineHeight = ceil(font.ascender - font.descender + font.leading)
        return ceil(appKitLineHeight * titleLineHeightScale)
    }

    static func titleMeasureWidth(columnWidth: CGFloat, metrics: RowLayoutMetrics) -> CGFloat {
        max(
            columnWidth - metrics.metadataPadding.leading - metrics.metadataPadding.trailing - 6,
            1
        )
    }

    static func titleLineCount(for title: String, columnWidth: CGFloat, metrics: RowLayoutMetrics) -> Int {
        let font = titleNSFont(for: metrics)
        let textWidth = titleMeasureWidth(columnWidth: columnWidth, metrics: metrics)
        guard !title.isEmpty else { return 1 }

        let storage = NSTextStorage(string: title, attributes: [.font: font])
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)

        let container = NSTextContainer(size: CGSize(width: textWidth, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.lineBreakMode = .byWordWrapping
        layoutManager.addTextContainer(container)
        layoutManager.ensureLayout(for: container)

        var lineCount = 0
        var glyphIndex = 0
        let glyphCount = layoutManager.numberOfGlyphs
        while glyphIndex < glyphCount {
            var lineRange = NSRange()
            _ = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &lineRange)
            lineCount += 1
            glyphIndex = NSMaxRange(lineRange)
        }
        return max(lineCount, 1)
    }

    static func titleAreaHeight(
        for title: String,
        columnWidth: CGFloat,
        metrics: RowLayoutMetrics
    ) -> CGFloat {
        let lineCount = titleLineCount(for: title, columnWidth: columnWidth, metrics: metrics)
        return CGFloat(lineCount) * titleLineHeight(for: metrics)
    }

    static func rowTitleAreaHeight(
        titles: [String],
        columnWidth: CGFloat,
        metrics: RowLayoutMetrics
    ) -> CGFloat {
        titleLineHeight(for: metrics) * 2
    }

    static func coverHeight(columnWidth: CGFloat) -> CGFloat {
        columnWidth / coverAspect
    }

    static func cardHeight(
        columnWidth: CGFloat,
        titleAreaHeight: CGFloat,
        metrics: RowLayoutMetrics
    ) -> CGFloat {
        coverHeight(columnWidth: columnWidth) + metrics.metadataHeight(titleAreaHeight: titleAreaHeight)
    }

    static let gridColumns = [
        GridItem(.adaptive(minimum: minWidth), spacing: gridSpacing, alignment: .top)
    ]
}

private enum FeedCardHoverStyle {
    static let colorAnimation = Animation.easeInOut(duration: 0.2)
}

private struct FeedCardTitle: View {
    let title: String
    let font: Font
    let areaHeight: CGFloat
    let destination: VideoPlaybackRequest
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(font)
                .foregroundStyle(isHovered ? BiliTheme.blue : .primary)
                .contentTransition(.interpolate)
                .animation(FeedCardHoverStyle.colorAnimation, value: isHovered)
                .lineLimit(nil)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .allowsHitTesting(false)

            Spacer(minLength: 0)
        }
        .frame(height: areaHeight, alignment: .top)
        .overlay {
            NavigationLink(value: destination) {
                Color.clear
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .onHover { hovering in
            withAnimation(FeedCardHoverStyle.colorAnimation) {
                isHovered = hovering
            }
        }
    }
}

private struct FeedCardAuthorLabel: View {
    let name: String
    let font: Font
    let avatarURL: URL?
    let avatarSize: CGFloat
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            RemoteAvatar(
                url: avatarURL,
                size: avatarSize,
                foreground: .secondary,
                background: Color.secondary.opacity(0.11),
                border: Color.black.opacity(0.05)
            )

            Text(name.ifEmpty("未知 UP 主"))
                .font(font)
                .foregroundStyle(isHovered ? BiliTheme.blue : .secondary)
                .contentTransition(.interpolate)
                .animation(FeedCardHoverStyle.colorAnimation, value: isHovered)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { hovering in
            withAnimation(FeedCardHoverStyle.colorAnimation) {
                isHovered = hovering
            }
        }
    }
}

struct FeedLoadMoreFooter: View {
    let anchorID: Int
    let hasMore: Bool
    let loadingMore: Bool
    let onLoadMore: () -> Void

    var body: some View {
        ZStack {
            Color.clear
            if loadingMore {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在加载更多")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 24)
        .padding(.vertical, 8)
        .id("feed-load-more-\(anchorID)")
        .onAppear {
            guard hasMore, !loadingMore else { return }
            onLoadMore()
        }
    }
}

struct VideoFeedGrid<Trailing: View>: View {
    let videos: [BiliVideo]
    var largeTypography = false
    var showsLikeCount = true
    var showsAuthor = true
    var maxColumnCount: Int? = nil
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.feedViewportWidth) private var feedViewportWidth
    @Environment(\.feedSymmetricHorizontalInsets) private var feedSymmetricHorizontalInsets

    init(
        videos: [BiliVideo],
        largeTypography: Bool = false,
        showsLikeCount: Bool = true,
        showsAuthor: Bool = true,
        maxColumnCount: Int? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.videos = videos
        self.largeTypography = largeTypography
        self.showsLikeCount = showsLikeCount
        self.showsAuthor = showsAuthor
        self.maxColumnCount = maxColumnCount
        self.trailing = trailing
    }

    var body: some View {
        let layoutWidth = resolvedLayoutWidth
        let baseColumnCount = VideoCardLayout.columnCount(for: layoutWidth)
        let columnCount = maxColumnCount.map { min($0, baseColumnCount) } ?? baseColumnCount
        let columnWidth = VideoCardLayout.columnWidth(for: layoutWidth, columnCount: columnCount)
        let metrics = VideoCardLayout.RowLayoutMetrics.feed(
            largeTypography: largeTypography,
            showsAuthor: showsAuthor
        )
        let rows = VideoCardLayout.rowChunks(videos, columnCount: columnCount)

        LazyVStack(alignment: .leading, spacing: VideoCardLayout.gridSpacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                let titleAreaHeight = VideoCardLayout.rowTitleAreaHeight(
                    titles: row.map(\.title),
                    columnWidth: columnWidth,
                    metrics: metrics
                )
                let cardHeight = VideoCardLayout.cardHeight(
                    columnWidth: columnWidth,
                    titleAreaHeight: titleAreaHeight,
                    metrics: metrics
                )

                HStack(alignment: .top, spacing: VideoCardLayout.gridSpacing) {
                    ForEach(row) { video in
                        VideoCard(
                            video: video,
                            largeTypography: largeTypography,
                            showsLikeCount: showsLikeCount,
                            showsAuthor: showsAuthor,
                            columnWidth: columnWidth,
                            titleAreaHeight: titleAreaHeight
                        )
                        .frame(width: columnWidth, height: cardHeight, alignment: .top)
                    }
                }
            }

            trailing()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var resolvedLayoutWidth: CGFloat {
        let width = feedSymmetricHorizontalInsets
            ? AppLayout.feedContentWidthSymmetric(viewportWidth: feedViewportWidth)
            : AppLayout.feedContentWidth(viewportWidth: feedViewportWidth)
        if width > 0 {
            return width
        }
        return VideoCardLayout.minWidth * 2 + VideoCardLayout.gridSpacing
    }
}

struct FollowingView: View {
    let videos: [BiliVideo]
    let loading: Bool
    let loadingMore: Bool
    let hasMore: Bool
    let error: String?
    let loggedIn: Bool
    let onLoadMore: () -> Void

    var body: some View {
        AppScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                if !loggedIn {
                    ContentUnavailableView(
                        "登录后查看关注内容",
                        systemImage: "person.2",
                        description: Text("在「我的」页面完成登录，即可同步关注动态")
                    )
                    .padding(.vertical, 40)
                    .frame(maxWidth: .infinity)
                    .materialPanel()
                } else {
                    StateBanner(
                        loading: loading,
                        error: error,
                        isEmpty: videos.isEmpty,
                        emptyTitle: "暂无关注视频，先去关注几个 UP 主吧"
                    )

                    VideoFeedGrid(videos: videos, largeTypography: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if hasMore, !videos.isEmpty {
                        FeedLoadMoreFooter(
                            anchorID: videos.count,
                            hasMore: hasMore,
                            loadingMore: loadingMore,
                            onLoadMore: onLoadMore
                        )
                    }
                }
            }
        }
    }
}

struct FavoritesView: View {
    let videos: [BiliVideo]
    let loading: Bool
    let loadingMore: Bool
    let hasMore: Bool
    let error: String?
    let loggedIn: Bool
    let onLoadMore: () -> Void

    var body: some View {
        AppScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                if !loggedIn {
                    ContentUnavailableView(
                        "登录后查看收藏",
                        systemImage: "star",
                        description: Text("在「我的」页面完成登录，即可同步收藏内容")
                    )
                    .padding(.vertical, 40)
                    .frame(maxWidth: .infinity)
                    .materialPanel()
                } else {
                    StateBanner(
                        loading: loading,
                        error: error,
                        isEmpty: videos.isEmpty,
                        emptyTitle: "暂无收藏视频"
                    )

                    VideoFeedGrid(videos: videos, largeTypography: true, showsLikeCount: false)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if hasMore, !videos.isEmpty {
                        FeedLoadMoreFooter(
                            anchorID: videos.count,
                            hasMore: hasMore,
                            loadingMore: loadingMore,
                            onLoadMore: onLoadMore
                        )
                    }
                }
            }
        }
    }
}

struct VideoGridView: View {
    var title: String? = nil
    var subtitle: String? = nil
    let videos: [BiliVideo]
    let loading: Bool
    let error: String?
    let emptyTitle: String
    var compactHeader = false
    var showsPageHeader = true
    var loadingMore = false
    var hasMore = false
    var onLoadMore: (() -> Void)? = nil

    var body: some View {
        AppScrollView {
            LazyVStack(alignment: .leading, spacing: compactHeader ? 10 : 20) {
                if showsPageHeader, let title, !title.isEmpty {
                    PageHeader(title: title, subtitle: subtitle, compact: compactHeader)
                }
                StateBanner(loading: loading, error: error, isEmpty: videos.isEmpty, emptyTitle: emptyTitle)

                VideoFeedGrid(videos: videos)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if hasMore, !videos.isEmpty {
                    FeedLoadMoreFooter(
                        anchorID: videos.count,
                        hasMore: hasMore,
                        loadingMore: loadingMore,
                        onLoadMore: { onLoadMore?() }
                    )
                }
            }
        }
    }
}

struct LiveRoomGridView: View {
    let rooms: [BiliLiveRoom]
    let loading: Bool
    let error: String?

    private let columns = VideoCardLayout.gridColumns

    var body: some View {
        AppScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "直播", subtitle: "热门直播间")
                StateBanner(loading: loading, error: error, isEmpty: rooms.isEmpty, emptyTitle: "暂时没有直播内容")

                LazyVGrid(columns: columns, alignment: .leading, spacing: VideoCardLayout.gridSpacing) {
                    ForEach(rooms) { room in
                        LiveRoomCard(room: room)
                    }
                }
            }
        }
    }
}

private enum HistoryCardLayout {
    static let metrics = VideoCardLayout.RowLayoutMetrics.history

    static func rowTitleAreaHeight(items: [BiliHistoryItem], columnWidth: CGFloat) -> CGFloat {
        VideoCardLayout.rowTitleAreaHeight(
            titles: items.map(\.video.title),
            columnWidth: columnWidth,
            metrics: metrics
        )
    }

    static func cardHeight(columnWidth: CGFloat, titleAreaHeight: CGFloat) -> CGFloat {
        VideoCardLayout.cardHeight(columnWidth: columnWidth, titleAreaHeight: titleAreaHeight, metrics: metrics)
    }
}

private enum HistoryLayout {
    static let maxColumnCount = 5
    static let sectionSpacing: CGFloat = 28
    static let timelineGutterWidth: CGFloat = 68
    static let timelineTrackColumnWidth: CGFloat = 16
    static let labelLeadingOverflow: CGFloat = 24
    static let trackToContentSpacing: CGFloat = 28
    static let labelFontSize: CGFloat = 16
    static let dotSize: CGFloat = 12
    static let dotShrunkSize: CGFloat = 4
    static let dotBorderWidth: CGFloat = 2
    static let dotShrunkBorderWidth: CGFloat = 1.5
    static let lineWidth: CGFloat = 1
    static let labelToTrackSpacing: CGFloat = 10
    static let pinnedRowPitch: CGFloat = 36
    static let sectionScrollTopInset: CGFloat = AppLayout.feedVerticalInset
    static let labelColor = Color(red: 0.38, green: 0.40, blue: 0.43)
    static let labelHoverColor = BiliTheme.blue
    static let lineColor = Color(red: 0.788, green: 0.804, blue: 0.816)

    static var timelineTrackCenterX: CGFloat {
        timelineGutterWidth - timelineTrackColumnWidth / 2
    }

    static var labelTrailingX: CGFloat {
        timelineTrackCenterX - labelToTrackSpacing - dotSize / 2
    }
}

private struct HistorySectionViewportKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct HistorySection: Identifiable {
    let id: String
    let label: String
    let items: [BiliHistoryItem]
}

struct HistoryView: View {
    let items: [BiliHistoryItem]
    let loading: Bool
    let loadingMore: Bool
    let hasMore: Bool
    let error: String?
    let loggedIn: Bool
    let onLoadMore: () -> Void
    let onDelete: (BiliHistoryItem) -> Void

    @State private var sectionHeaderViewportY: [String: CGFloat] = [:]
    @State private var deepestReachedSectionIndex: Int = -1

    private var sections: [HistorySection] {
        buildHistorySections(from: items)
    }

    private var stickyPinLine: CGFloat {
        AppLayout.feedVerticalInset
    }

    private func stickySlotY(for index: Int) -> CGFloat {
        stickyPinLine + CGFloat(index) * HistoryLayout.pinnedRowPitch
    }

    private func isBottomPinnedSection(at index: Int) -> Bool {
        isViewingEarlierSections
            && index == deepestReachedSectionIndex
            && deepestReachedSectionIndex > 0
    }

    private func viewingSectionIndexAtTop() -> Int? {
        sections.indices.compactMap { index in
            guard let y = sectionHeaderViewportY[sections[index].id] else { return nil }
            if y >= stickyPinLine - 12 && y < stickyPinLine + HistoryLayout.pinnedRowPitch * 2.5 {
                return index
            }
            return nil
        }.min()
    }

    private var isViewingEarlierSections: Bool {
        guard deepestReachedSectionIndex > 0,
              let viewingIndex = viewingSectionIndexAtTop() else {
            return false
        }
        return viewingIndex < deepestReachedSectionIndex
    }

    private func stickyHeaderY(for index: Int, viewportHeight: CGFloat) -> CGFloat {
        if isBottomPinnedSection(at: index) {
            return viewportHeight - AppLayout.feedVerticalInset - HistoryLayout.pinnedRowPitch
        }
        return stickySlotY(for: index)
    }

    private func reconcileScrollDepth(with viewportY: [String: CGFloat]) {
        var deepest = deepestReachedSectionIndex
        for (index, section) in sections.enumerated() {
            guard let y = viewportY[section.id] else { continue }
            if y < stickySlotY(for: index) {
                deepest = max(deepest, index)
            }
        }
        if deepest != deepestReachedSectionIndex {
            deepestReachedSectionIndex = deepest
        }
    }

    private func isSectionPinned(_ section: HistorySection, index: Int) -> Bool {
        if isViewingEarlierSections, let viewingIndex = viewingSectionIndexAtTop() {
            if index == viewingIndex {
                return false
            }
            return index <= deepestReachedSectionIndex
        }

        let slotY = stickySlotY(for: index)
        let y = sectionHeaderViewportY[section.id]

        if let y, y < slotY {
            return true
        }

        return false
    }

    private func isActivePinnedSection(at index: Int) -> Bool {
        if isViewingEarlierSections {
            return index == deepestReachedSectionIndex
        }

        guard sections.indices.contains(index),
              let y = sectionHeaderViewportY[sections[index].id],
              y < stickySlotY(for: index) else {
            return false
        }

        let highestScrolledPastIndex = sections.enumerated().compactMap { candidateIndex, candidate in
            guard let candidateY = sectionHeaderViewportY[candidate.id],
                  candidateY < stickySlotY(for: candidateIndex) else {
                return nil
            }
            return candidateIndex
        }.max() ?? -1

        return index == highestScrolledPastIndex
    }

    private func timelineDotSpec(at index: Int, isPinned: Bool) -> (size: CGFloat, style: HistoryTimelineDotStyle) {
        if isPinned {
            if isActivePinnedSection(at: index) {
                return (HistoryLayout.dotSize, .hollow)
            }
            return (HistoryLayout.dotShrunkSize, .solid)
        }
        return (HistoryLayout.dotSize, .hollow)
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(HistoryLayout.lineColor)
                        .frame(width: HistoryLayout.lineWidth)
                        .frame(maxHeight: .infinity)
                        .position(
                            x: AppLayout.feedHorizontalInset + HistoryLayout.timelineTrackCenterX,
                            y: geometry.size.height / 2
                        )
                        .allowsHitTesting(false)
                        .zIndex(0)

                    ScrollView {
                        VStack(alignment: .leading, spacing: HistoryLayout.sectionSpacing) {
                            StateBanner(
                                loading: loading,
                                error: error,
                                isEmpty: items.isEmpty,
                                emptyTitle: loggedIn ? "暂无观看历史" : "登录后查看观看历史"
                            )

                            ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                                let isPinned = isSectionPinned(section, index: index)
                                let dotSpec = timelineDotSpec(at: index, isPinned: isPinned)

                                HistoryDateSection(
                                    section: section,
                                    hidesInlineHeader: isPinned,
                                    dotSize: dotSpec.size,
                                    dotStyle: dotSpec.style,
                                    onLabelTap: {
                                        scrollToSection(section.id, proxy: proxy)
                                    },
                                    onDelete: onDelete
                                )
                                .id(section.id)
                            }

                            if hasMore, !items.isEmpty {
                                FeedLoadMoreFooter(
                                    anchorID: items.count,
                                    hasMore: hasMore,
                                    loadingMore: loadingMore,
                                    onLoadMore: onLoadMore
                                )
                            }
                        }
                        .padding(.leading, AppLayout.feedHorizontalInset)
                        .padding(.trailing, AppLayout.feedTrailingInset)
                        .padding(.bottom, AppLayout.feedVerticalInset)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .environment(\.feedViewportWidth, geometry.size.width)
                    }
                    .contentMargins(.top, HistoryLayout.sectionScrollTopInset, for: .scrollContent)
                    .contentMargins(.bottom, AppLayout.feedVerticalInset, for: .scrollContent)
                    .scrollClipDisabled()
                    .zIndex(1)
                    .onPreferenceChange(HistorySectionViewportKey.self) { updates in
                        var merged = sectionHeaderViewportY
                        merged.merge(updates) { _, new in new }
                        sectionHeaderViewportY = merged
                        reconcileScrollDepth(with: merged)
                    }
                    .onChange(of: sections.map(\.id)) { _, _ in
                        deepestReachedSectionIndex = -1
                    }

                    ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                        if isSectionPinned(section, index: index) {
                            let dotSpec = timelineDotSpec(at: index, isPinned: true)
                            HistoryTimelineStickyHeader(
                                title: section.label,
                                dotSize: dotSpec.size,
                                dotStyle: dotSpec.style,
                                onTap: {
                                    scrollToSection(section.id, proxy: proxy)
                                }
                            )
                            .offset(
                                x: AppLayout.feedHorizontalInset,
                                y: stickyHeaderY(for: index, viewportHeight: geometry.size.height)
                            )
                            .zIndex(2)
                            .animation(.easeOut(duration: 0.2), value: deepestReachedSectionIndex)
                        }
                    }
                }
            }
        }
    }

    private func scrollToSection(_ sectionID: String, proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.28)) {
            proxy.scrollTo(sectionID, anchor: .top)
        }
    }
}

private struct HistoryTimelineStickyHeader: View {
    let title: String
    var dotSize: CGFloat = HistoryLayout.dotSize
    var dotStyle: HistoryTimelineDotStyle = .hollow
    let onTap: () -> Void

    var body: some View {
        HistoryTimelineSectionHeader(
            title: title,
            dotSize: dotSize,
            dotStyle: dotStyle,
            showsLabel: true,
            onTap: onTap
        )
        .frame(width: HistoryLayout.timelineGutterWidth, height: HistoryLayout.pinnedRowPitch, alignment: .leading)
    }
}

private struct HistoryDateSection: View {
    let section: HistorySection
    var hidesInlineHeader = false
    var dotSize: CGFloat
    var dotStyle: HistoryTimelineDotStyle = .hollow
    let onLabelTap: () -> Void
    let onDelete: (BiliHistoryItem) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: HistoryLayout.trackToContentSpacing) {
            HistoryTimelineSectionHeader(
                title: section.label,
                dotSize: dotSize,
                dotStyle: dotStyle,
                showsLabel: true,
                onTap: onLabelTap
            )
            .frame(width: HistoryLayout.timelineGutterWidth, height: HistoryLayout.pinnedRowPitch, alignment: .leading)
            .opacity(hidesInlineHeader ? 0 : 1)
            .allowsHitTesting(!hidesInlineHeader)
            .zIndex(1)

            HistoryItemsGrid(items: section.items, onDelete: onDelete)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(alignment: .topTrailing) {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: HistorySectionViewportKey.self,
                    value: [
                        section.id: geometry.frame(in: .scrollView(axis: .vertical)).minY,
                    ]
                )
            }
            .frame(width: HistoryLayout.timelineGutterWidth, height: 1)
        }
    }
}

private enum HistoryTimelineDotStyle {
    case hollow
    case solid
}

private struct HistoryTimelineSectionHeader: View {
    let title: String
    var dotSize: CGFloat = HistoryLayout.dotSize
    var dotStyle: HistoryTimelineDotStyle = .hollow
    var showsLabel: Bool = true
    var onTap: () -> Void = {}

    @State private var isHovered = false

    private var labelColor: Color {
        isHovered ? HistoryLayout.labelHoverColor : HistoryLayout.labelColor
    }

    private var dotBorderWidth: CGFloat {
        dotSize <= HistoryLayout.dotShrunkSize + 0.5
            ? HistoryLayout.dotShrunkBorderWidth
            : HistoryLayout.dotBorderWidth
    }

    var body: some View {
        ZStack(alignment: .leading) {
            if showsLabel {
                Text(title)
                    .font(.system(size: HistoryLayout.labelFontSize, weight: .medium))
                    .foregroundStyle(labelColor)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(
                        width: HistoryLayout.labelTrailingX + HistoryLayout.labelLeadingOverflow,
                        alignment: .trailing
                    )
                    .offset(x: -HistoryLayout.labelLeadingOverflow)
                    .padding(.vertical, 4)
                    .background(Color.white)
            }

            HistoryTimelineDot(
                size: dotSize,
                style: dotStyle,
                borderWidth: dotBorderWidth,
                color: labelColor
            )
            .position(
                x: HistoryLayout.timelineTrackCenterX,
                y: HistoryLayout.pinnedRowPitch / 2
            )
        }
        .frame(width: HistoryLayout.timelineGutterWidth, height: HistoryLayout.pinnedRowPitch, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.18)) {
                isHovered = hovering
            }
        }
        .animation(.easeOut(duration: 0.24), value: dotSize)
        .animation(.easeOut(duration: 0.24), value: dotStyle)
        .animation(.easeOut(duration: 0.18), value: showsLabel)
    }
}

private struct HistoryTimelineDot: View {
    let size: CGFloat
    var style: HistoryTimelineDotStyle = .hollow
    let borderWidth: CGFloat
    let color: Color

    var body: some View {
        Group {
            switch style {
            case .solid:
                Circle()
                    .fill(color)
            case .hollow:
                ZStack {
                    Circle()
                        .fill(Color.white)
                        .frame(width: size + 4, height: size + 4)
                    Circle()
                        .fill(Color.white)
                        .overlay {
                            Circle()
                                .strokeBorder(color, lineWidth: borderWidth)
                        }
                        .frame(width: size, height: size)
                }
            }
        }
        .frame(width: max(size, size + 4), height: max(size, size + 4))
        .animation(.easeOut(duration: 0.24), value: size)
        .animation(.easeOut(duration: 0.24), value: style)
    }
}

private struct HistoryItemsGrid: View {
    let items: [BiliHistoryItem]
    let onDelete: (BiliHistoryItem) -> Void
    @Environment(\.feedViewportWidth) private var feedViewportWidth

    var body: some View {
        let layoutWidth = resolvedLayoutWidth
        let columnCount = min(HistoryLayout.maxColumnCount, VideoCardLayout.columnCount(for: layoutWidth))
        let columnWidth = VideoCardLayout.columnWidth(for: layoutWidth, columnCount: columnCount)
        let rows = VideoCardLayout.rowChunks(items, columnCount: columnCount)

        VStack(alignment: .leading, spacing: VideoCardLayout.gridSpacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                let titleAreaHeight = HistoryCardLayout.rowTitleAreaHeight(items: row, columnWidth: columnWidth)
                let cardHeight = HistoryCardLayout.cardHeight(columnWidth: columnWidth, titleAreaHeight: titleAreaHeight)

                HStack(alignment: .top, spacing: VideoCardLayout.gridSpacing) {
                    ForEach(row) { item in
                        HistoryVideoCard(
                            item: item,
                            columnWidth: columnWidth,
                            titleAreaHeight: titleAreaHeight,
                            onDelete: { onDelete(item) }
                        )
                            .frame(width: columnWidth, height: cardHeight, alignment: .top)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var resolvedLayoutWidth: CGFloat {
        let contentWidth = AppLayout.feedContentWidth(viewportWidth: feedViewportWidth)
        let historyWidth = max(
            0,
            contentWidth - HistoryLayout.timelineGutterWidth - HistoryLayout.trackToContentSpacing
        )
        if historyWidth > 0 {
            return historyWidth
        }
        return VideoCardLayout.minWidth * 2 + VideoCardLayout.gridSpacing
    }
}

private struct HistoryVideoCard: View {
    let item: BiliHistoryItem
    let columnWidth: CGFloat
    let titleAreaHeight: CGFloat
    let onDelete: () -> Void
    @State private var isCardHovered = false
    @State private var isCoverHovered = false
    @State private var isDeleteHovered = false

    private var video: BiliVideo { item.video }

    private var coverHeight: CGFloat {
        VideoCardLayout.coverHeight(columnWidth: columnWidth)
    }

    private var metadataHeight: CGFloat {
        HistoryCardLayout.metrics.metadataHeight(titleAreaHeight: titleAreaHeight)
    }

    private var durationBadgeText: String {
        historyDurationBadgeText(
            progressSeconds: item.progressSeconds,
            durationSeconds: item.durationSeconds > 0 ? item.durationSeconds : video.duration
        )
    }

    private var watchProgress: Double {
        let duration = max(item.durationSeconds, video.duration)
        guard duration > 0, item.progressSeconds > 0 else { return 0 }
        return min(1, Double(item.progressSeconds) / Double(duration))
    }

    private var playbackRequest: VideoPlaybackRequest {
        VideoPlaybackRequest(
            video,
            progressSeconds: item.progressSeconds,
            epid: item.epid,
            refererURL: item.webURI
        )
    }

    private var authorDisplayName: String {
        if !video.authorName.isEmpty {
            return video.authorName
        }
        if !item.badge.isEmpty {
            return item.badge
        }
        if item.business == .pgc {
            return "番剧"
        }
        return video.authorName
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: VideoCardLayout.cornerRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            coverSection(shape: shape)
                .frame(height: coverHeight)
            metadataSection
                .frame(height: metadataHeight)
        }
        .frame(height: coverHeight + metadataHeight)
        .background {
            ZStack {
                shape.fill(Color.white)
                shape.stroke(VideoCardLayout.cardBorderColor, lineWidth: 0.5)
            }
        }
        .shadow(color: .black.opacity(isCardHovered ? 0.07 : 0), radius: isCardHovered ? 8 : 0, x: 0, y: isCardHovered ? 4 : 0)
        .zIndex(isCardHovered ? 2 : 0)
        .videoCoverHover(isHovered: $isCardHovered)
    }

    private var coverHoverAnimation: Animation {
        isCoverHovered ? VideoCardLayout.coverHoverAnimation : VideoCardLayout.coverHoverExitAnimation
    }

    private func coverSection(shape: RoundedRectangle) -> some View {
        NavigationLink(value: playbackRequest) {
            ZStack(alignment: .bottomTrailing) {
                RemoteCover(
                    url: video.coverURL,
                    aspectRatio: VideoCardLayout.coverAspect,
                    appliesCornerClip: false,
                    allowsOverflow: true
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(shape)
                .scaleEffect(isCoverHovered ? VideoCardLayout.coverHoverScale : 1)
                .animation(coverHoverAnimation, value: isCoverHovered)

                if watchProgress > 0.001, watchProgress < 0.999 {
                    GeometryReader { geometry in
                        VStack(spacing: 0) {
                            Spacer()
                            ZStack(alignment: .leading) {
                                Rectangle()
                                    .fill(Color.black.opacity(0.35))
                                Rectangle()
                                    .fill(Color(red: 0, green: 174 / 255, blue: 236 / 255))
                                    .frame(width: geometry.size.width * watchProgress)
                            }
                            .frame(height: 3)
                        }
                    }
                    .allowsHitTesting(false)
                }

                if !durationBadgeText.isEmpty {
                    VideoCoverDurationBadge(text: durationBadgeText)
                        .padding(8)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .videoCoverHover(isHovered: $isCoverHovered)
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            FeedCardTitle(
                title: video.title,
                font: .title3.weight(.medium),
                areaHeight: titleAreaHeight,
                destination: playbackRequest
            )

            authorRow
                .frame(height: HistoryCardLayout.metrics.authorRowHeight, alignment: .center)
        }
        .padding(HistoryCardLayout.metrics.metadataPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var authorRow: some View {
        HStack(alignment: .center, spacing: 8) {
            authorIdentity
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            if let viewedAt = item.viewedAt {
                Text(historyViewTimeText(from: viewedAt))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }

            if !item.kid.isEmpty {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(
                            isDeleteHovered ? AnyShapeStyle(Color.red) : AnyShapeStyle(.tertiary)
                        )
                        .contentTransition(.interpolate)
                        .animation(FeedCardHoverStyle.colorAnimation, value: isDeleteHovered)
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help("删除历史")
                .onHover { hovering in
                    withAnimation(FeedCardHoverStyle.colorAnimation) {
                        isDeleteHovered = hovering
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var authorIdentity: some View {
        if video.authorMid > 0 {
            NavigationLink(
                value: UserProfileRequest(mid: video.authorMid)
            ) {
                authorIdentityContent
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            authorIdentityContent
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var authorIdentityContent: some View {
        FeedCardAuthorLabel(
            name: authorDisplayName,
            font: .body,
            avatarURL: video.authorFaceURL,
            avatarSize: 26
        )
    }
}

struct MineView: View {
    @ObservedObject var model: AppModel
    @State private var showLogin = false
    @StateObject private var webSession = BilibiliWebSession()

    var body: some View {
        AppScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "我的", subtitle: model.account == nil ? "登录后同步个人资料、关注和历史" : "账号与资料")
                if let account = model.account {
                    if let mid = Int64(account.uid), mid > 0 {
                        NavigationLink(
                            value: UserProfileRequest(mid: mid)
                        ) {
                            ProfileCard(account: account, profile: model.profile)
                        }
                        .buttonStyle(.plain)
                    } else {
                        ProfileCard(account: account, profile: model.profile)
                    }
                } else {
                    LoginCard {
                        showLogin = true
                    }
                }

                if let message = model.loginMessage {
                    Label(message, systemImage: message.hasPrefix("已") ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(message.hasPrefix("已") ? .green : .orange)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .materialPanel()
                }

                AccountActionGrid(
                    loggedIn: model.account != nil,
                    onFollowing: { model.selectedSection = .following },
                    onHistory: { model.selectedSection = .history },
                    onHome: { model.selectedSection = .home },
                    onLogout: { model.logout() }
                )

            }
        }
        .sheet(isPresented: $showLogin) {
            WebLoginSheet(session: webSession) {
                Task {
                    guard let credential = await webSession.readCredential() else { return }
                    let success = await model.login(credential: credential)
                    if success {
                        showLogin = false
                    }
                }
            }
        }
    }
}

struct PageHeader: View {
    let title: String
    var subtitle: String? = nil
    var largeTypography = false
    var compact = false

    var body: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: compact ? 0 : 6) {
                Text(title)
                    .font(largeTypography ? .system(size: 40, weight: .bold) : .largeTitle.weight(.bold))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(largeTypography ? .body : .callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.bottom, compact ? -4 : 0)
    }
}

struct StateBanner: View {
    let loading: Bool
    let error: String?
    let isEmpty: Bool
    let emptyTitle: String

    var body: some View {
        if let error {
            Label(error, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .materialPanel()
        } else if isEmpty, !loading {
            ContentUnavailableView(emptyTitle, systemImage: "tray")
                .padding(40)
                .materialPanel()
        }
    }
}

struct VideoCard: View {
    let video: BiliVideo
    var largeTypography = false
    var showsLikeCount = true
    var showsAuthor = true
    let columnWidth: CGFloat
    let titleAreaHeight: CGFloat
    @State private var isCardHovered = false
    @State private var isCoverHovered = false

    private var metrics: VideoCardLayout.RowLayoutMetrics {
        .feed(largeTypography: largeTypography, showsAuthor: showsAuthor)
    }

    private var coverHeight: CGFloat {
        VideoCardLayout.coverHeight(columnWidth: columnWidth)
    }

    private var metadataHeight: CGFloat {
        metrics.metadataHeight(titleAreaHeight: titleAreaHeight)
    }

    private var titleFont: Font {
        largeTypography ? .title2.weight(.semibold) : .title3.weight(.medium)
    }

    private var authorFont: Font {
        largeTypography ? .title3.weight(.regular) : .body
    }

    private var statsFont: Font {
        largeTypography ? .body : .subheadline
    }

    private var avatarSize: CGFloat {
        largeTypography ? 30 : 26
    }

    private var statIconSize: CGFloat {
        largeTypography ? 20 : 18
    }

    private var likeStatIconSize: CGFloat {
        statIconSize - 2
    }

    private var cornerRadius: CGFloat {
        VideoCardLayout.cornerRadius
    }

    var body: some View {
        mosaicCard
            .frame(height: coverHeight + metadataHeight)
    }

    private var mosaicCard: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            coverSection(shape: shape)
                .frame(height: coverHeight)
            metadataSection
                .frame(height: metadataHeight)
        }
        .background {
            ZStack {
                shape.fill(Color.white)
                shape.stroke(VideoCardLayout.cardBorderColor, lineWidth: 0.5)
            }
        }
        .shadow(color: .black.opacity(isCardHovered ? 0.07 : 0), radius: isCardHovered ? 8 : 0, x: 0, y: isCardHovered ? 4 : 0)
        .zIndex(isCardHovered ? 2 : 0)
        .videoCoverHover(isHovered: $isCardHovered)
    }

    private var coverHoverAnimation: Animation {
        isCoverHovered ? VideoCardLayout.coverHoverAnimation : VideoCardLayout.coverHoverExitAnimation
    }

    private func coverSection(shape: RoundedRectangle) -> some View {
        NavigationLink(value: VideoPlaybackRequest(video)) {
            ZStack(alignment: .bottomTrailing) {
                RemoteCover(
                    url: video.coverURL,
                    aspectRatio: VideoCardLayout.coverAspect,
                    appliesCornerClip: false,
                    allowsOverflow: true
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(shape)
                .scaleEffect(isCoverHovered ? VideoCardLayout.coverHoverScale : 1)
                .animation(coverHoverAnimation, value: isCoverHovered)

                if video.duration > 0 {
                    VideoCoverDurationBadge(text: video.durationText)
                        .padding(8)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .videoCoverHover(isHovered: $isCoverHovered)
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            FeedCardTitle(
                title: video.title,
                font: titleFont,
                areaHeight: titleAreaHeight,
                destination: VideoPlaybackRequest(video)
            )

            if metrics.includesStats {
                NavigationLink(value: VideoPlaybackRequest(video)) {
                    statsRow
                        .frame(height: metrics.statsHeight, alignment: .leading)
                }
                .buttonStyle(.plain)
            }

            if showsAuthor {
                authorRow
                    .frame(height: metrics.authorRowHeight, alignment: .center)
                    .padding(.top, metrics.includesStats ? metrics.statsAuthorSpacing : 0)
            }
        }
        .padding(metrics.metadataPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var authorRow: some View {
        if video.authorMid > 0 {
            NavigationLink(
                value: UserProfileRequest(mid: video.authorMid)
            ) {
                authorRowContent
            }
            .buttonStyle(.plain)
        } else {
            authorRowContent
        }
    }

    private var authorRowContent: some View {
        FeedCardAuthorLabel(
            name: video.authorName,
            font: authorFont,
            avatarURL: video.authorFaceURL,
            avatarSize: avatarSize
        )
    }

    private var statsRow: some View {
        HStack(spacing: 12) {
            BiliStatLabel(
                icon: .play,
                value: video.viewCount.compactCount,
                iconSize: statIconSize,
                font: statsFont
            )
            BiliStatLabel(
                icon: .danmaku,
                value: video.danmakuCount.compactCount,
                iconSize: statIconSize,
                font: statsFont
            )
            if showsLikeCount {
                BiliStatLabel(
                    icon: .like,
                    value: video.likeCount.compactCount,
                    iconSize: likeStatIconSize,
                    font: statsFont
                )
            }
        }
        .foregroundStyle(.secondary)
    }
}

private func buildHistorySections(from items: [BiliHistoryItem]) -> [HistorySection] {
    var sections: [HistorySection] = []
    var currentLabel: String?
    var currentItems: [BiliHistoryItem] = []

    for item in items {
        let label = historySectionLabel(from: item.viewedAt)
        if label != currentLabel {
            if let currentLabel, !currentItems.isEmpty {
                let anchor = currentItems.first?.viewedAt?.timeIntervalSince1970 ?? 0
                sections.append(HistorySection(id: "\(currentLabel)-\(Int(anchor))", label: currentLabel, items: currentItems))
            }
            currentLabel = label
            currentItems = [item]
        } else {
            currentItems.append(item)
        }
    }

    if let currentLabel, !currentItems.isEmpty {
        let anchor = currentItems.first?.viewedAt?.timeIntervalSince1970 ?? 0
        sections.append(HistorySection(id: "\(currentLabel)-\(Int(anchor))", label: currentLabel, items: currentItems))
    }

    return sections
}

private func historySectionLabel(from date: Date?) -> String {
    guard let date else { return "更早" }
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    let itemDay = calendar.startOfDay(for: date)
    guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else { return "更早" }

    if itemDay == today { return "今天" }
    if itemDay == yesterday { return "昨天" }

    let daysAgo = calendar.dateComponents([.day], from: itemDay, to: today).day ?? 0
    if daysAgo >= 7 && daysAgo < 14 { return "一周前" }
    if daysAgo >= 14 && daysAgo < 30 { return "一个月前" }

    return historySectionDateText(from: date)
}

private func historySectionDateText(from date: Date) -> String {
    let calendar = Calendar.current
    let year = calendar.component(.year, from: date)
    let month = calendar.component(.month, from: date)
    let day = calendar.component(.day, from: date)
    let currentYear = calendar.component(.year, from: Date())

    if year == currentYear {
        return "\(month)月\(day)日"
    }
    return "\(year)年\(month)月\(day)日"
}

private func historyViewTimeText(from date: Date) -> String {
    let calendar = Calendar.current
    let year = calendar.component(.year, from: date)
    let month = calendar.component(.month, from: date)
    let day = calendar.component(.day, from: date)
    let hour = calendar.component(.hour, from: date)
    let minute = calendar.component(.minute, from: date)
    return String(format: "%d年%d月%d日 %02d:%02d", year, month, day, hour, minute)
}

private func historyDurationBadgeText(progressSeconds: Int, durationSeconds: Int) -> String {
    if progressSeconds > 0, durationSeconds > 0, progressSeconds < durationSeconds {
        return "\(formatClockDuration(progressSeconds)) / \(formatClockDuration(durationSeconds))"
    }
    guard durationSeconds > 0 else { return "" }
    return formatClockDuration(durationSeconds)
}

private func formatClockDuration(_ seconds: Int) -> String {
    let safe = max(0, seconds)
    let hours = safe / 3600
    let minutes = (safe % 3600) / 60
    let remaining = safe % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, remaining)
    }
    return String(format: "%d:%02d", minutes, remaining)
}

struct ProfileCard: View {
    let account: BiliAccount
    let profile: BiliUserProfile?

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            RemoteAvatar(
                url: profile?.faceURL ?? account.faceURL,
                size: 86,
                foreground: .secondary,
                background: Color.secondary.opacity(0.14),
                border: Color.black.opacity(0.06)
            )

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(profile?.name ?? account.name)
                        .font(.title.weight(.bold))
                    if let level = profile?.level, level > 0 {
                        Text("Lv.\(level)")
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.pink.opacity(0.14), in: Capsule())
                            .foregroundStyle(.pink)
                    }
                }

                Text(profile?.sign.isEmpty == false ? profile?.sign ?? "" : "这个人还没有写签名")
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                HStack(spacing: 20) {
                    ProfileMetric(title: "关注", value: profile?.following.compactCount ?? "-")
                    ProfileMetric(title: "粉丝", value: profile?.follower.compactCount ?? "-")
                    ProfileMetric(title: "获赞", value: profile?.likes.compactCount ?? "-")
                    ProfileMetric(title: "硬币", value: profile?.coinCount.compactCount ?? "-")
                    ProfileMetric(title: "B币", value: profile.map { String(format: "%.1f", $0.bcoinBalance) } ?? "-")
                }
                .padding(.top, 4)
            }
            Spacer()
        }
        .padding(20)
        .materialPanel()
    }
}

struct ProfileMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.headline.monospacedDigit())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct LoginCard: View {
    let onLogin: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(.pink)
                VStack(alignment: .leading, spacing: 5) {
                    Text("登录哔哩哔哩")
                        .font(.title2.weight(.bold))
                    Text("在应用内完成登录，即可同步关注、历史、个人资料、硬币和 B 币余额。")
                        .foregroundStyle(.secondary)
                }
            }
            Button(action: onLogin) {
                Label("登录", systemImage: "arrow.right.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.pink)
            .controlSize(.large)
        }
        .padding(20)
        .materialPanel()
    }
}

struct AccountActionGrid: View {
    let loggedIn: Bool
    let onFollowing: () -> Void
    let onHistory: () -> Void
    let onHome: () -> Void
    let onLogout: () -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 14)], spacing: 14) {
            ActionCard(title: "首页推荐", subtitle: "刷新推荐流", symbol: "house", action: onHome)
            ActionCard(title: "关注", subtitle: loggedIn ? "查看关注更新" : "需要登录", symbol: "person.2", action: onFollowing)
            ActionCard(title: "历史", subtitle: loggedIn ? "查看观看记录" : "需要登录", symbol: "clock.arrow.circlepath", action: onHistory)
            if loggedIn {
                ActionCard(title: "退出登录", subtitle: "清除本地账号", symbol: "rectangle.portrait.and.arrow.right", action: onLogout)
            }
        }
    }
}

struct ActionCard: View {
    let title: String
    let subtitle: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.title3.weight(.semibold))
                    .frame(width: 32, height: 32)
                    .foregroundStyle(.pink)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(16)
        }
        .buttonStyle(.plain)
        .materialPanel()
    }
}

struct WebLoginSheet: View {
    @ObservedObject var session: BilibiliWebSession
    let onCompleteLogin: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            BilibiliWebView(webView: session.webView)
                .clipShape(RoundedRectangle(cornerRadius: 0))
        }
        .frame(minWidth: 720, minHeight: 560)
        .background(.regularMaterial)
        .task {
            session.openLogin()
            await session.refreshLoginState()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("哔哩哔哩登录")
                    .font(.title2.weight(.bold))
                Text("在下方页面完成登录。登录成功后点击「完成登录」返回应用。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 10) {
                Button("重新打开") {
                    session.openLogin(forceReload: true)
                }
                .buttonStyle(.bordered)

                if session.hasLoginCookie {
                    Button("完成登录", action: onCompleteLogin)
                        .buttonStyle(.borderedProminent)
                        .tint(.pink)
                } else {
                    Button("关闭") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .background(.ultraThinMaterial)
    }
}

struct LiveRoomCard: View {
    let room: BiliLiveRoom
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            if let url = room.webURL {
                openURL(url)
            }
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                RemoteCover(url: room.coverURL, aspectRatio: 16.0 / 9.0)
                    .overlay(alignment: .topLeading) {
                        Text("LIVE")
                            .font(.caption2.weight(.black))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(.pink, in: Capsule())
                            .foregroundStyle(.white)
                            .padding(8)
                    }

                VStack(alignment: .leading, spacing: 8) {
                    Text(room.title)
                        .font(.headline)
                        .lineLimit(2)
                    Text(room.userName.ifEmpty("主播"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        MetricLabel(systemImage: "person.2", value: room.online.compactCount)
                        if !room.areaName.isEmpty {
                            MetricLabel(systemImage: "tag", value: room.areaName)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding([.horizontal, .bottom], 14)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .materialPanel()
    }
}

struct RemoteCover: View {
    let url: URL?
    let aspectRatio: CGFloat
    var width: CGFloat?
    var height: CGFloat?
    var appliesCornerClip = true
    var allowsOverflow = false
    @StateObject private var imageLoader = RemoteCoverImageLoader()
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            if let width, let height {
                coverImageLayer
                    .frame(width: width, height: height)
                    .modifier(RemoteCoverOverflowClip(enabled: !allowsOverflow))
            } else {
                Color.clear
                    .aspectRatio(aspectRatio, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .overlay {
                        coverImageLayer
                    }
                    .modifier(RemoteCoverOverflowClip(enabled: !allowsOverflow))
            }
        }
        .background(Color.white)
        .modifier(RemoteCoverCornerClip(enabled: appliesCornerClip))
        .task(id: loadTaskID) {
            if let width, let height {
                imageLoader.load(url: url, targetSize: CGSize(width: width, height: height), scale: displayScale)
            } else {
                imageLoader.load(url: url, maxPixelLength: VideoCardLayout.feedCoverPixelLength(displayScale: displayScale))
            }
        }
        .onDisappear {
            imageLoader.cancel()
        }
    }

    @ViewBuilder
    private var coverImageLayer: some View {
        ZStack {
            if let image = imageLoader.image ?? cachedImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else if imageLoader.failed {
                placeholder(systemImage: "photo")
            } else {
                placeholder(systemImage: "play.rectangle")
            }
        }
    }

    private var loadTaskID: String {
        if let width, let height {
            return "\(url?.absoluteString ?? "")#\(Int(width))x\(Int(height))#\(displayScale)"
        }
        let pixel = VideoCardLayout.feedCoverPixelLength(displayScale: displayScale)
        return "\(url?.absoluteString ?? "")#feed#\(pixel)"
    }

    private var coverPixelLength: Int {
        if let width, let height {
            let displayMax = max(width, height)
            return Int((displayMax * max(1, displayScale)).rounded(.up))
        }
        return VideoCardLayout.feedCoverPixelLength(displayScale: displayScale)
    }

    private var cachedImage: NSImage? {
        RemoteCoverImageLoader.cachedImage(url: url, maxPixelLength: coverPixelLength)
    }

    private func placeholder(systemImage: String) -> some View {
        ZStack {
            Color.white
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(Color.secondary.opacity(0.42))
        }
    }
}

struct RemoteAvatar: View {
    let url: URL?
    let size: CGFloat
    var foreground: Color = .secondary
    var background: Color = Color.secondary.opacity(0.12)
    var border: Color = Color.black.opacity(0.06)

    @StateObject private var imageLoader = RemoteCoverImageLoader()
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack {
            if let image = imageLoader.image ?? cachedImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.54, weight: .semibold))
                    .foregroundStyle(foreground)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: size, height: size)
        .background(background, in: Circle())
        .overlay {
            Circle().stroke(border, lineWidth: 0.5)
        }
        .clipShape(Circle())
        .task(id: loadTaskID) {
            imageLoader.load(url: url, maxPixelLength: avatarPixelLength)
        }
        .onDisappear {
            imageLoader.cancel()
        }
    }

    private var avatarPixelLength: Int {
        max(48, Int((size * max(1, displayScale) * 1.25).rounded(.up)))
    }

    private var loadTaskID: String {
        "\(url?.absoluteString ?? "")#avatar#\(avatarPixelLength)"
    }

    private var cachedImage: NSImage? {
        RemoteCoverImageLoader.cachedImage(url: url, maxPixelLength: avatarPixelLength)
    }
}

private struct RemoteCoverCornerClip: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            content
        }
    }
}

private struct RemoteCoverOverflowClip: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.clipped()
        } else {
            content
        }
    }
}

struct MetricLabel: View {
    let systemImage: String
    let value: String

    var body: some View {
        Label(value, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for item in arrange(proposal: ProposedViewSize(width: bounds.width, height: bounds.height), subviews: subviews).items {
            subviews[item.index].place(
                at: CGPoint(x: bounds.minX + item.frame.minX, y: bounds.minY + item.frame.minY),
                proposal: ProposedViewSize(width: item.frame.width, height: item.frame.height)
            )
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (items: [(index: Int, frame: CGRect)], size: CGSize) {
        let maxWidth = max(proposal.width ?? 600, 1)
        var items: [(Int, CGRect)] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for index in subviews.indices {
            var lineWidth = max(maxWidth - x, 1)
            var size = subviews[index].sizeThatFits(ProposedViewSize(width: lineWidth, height: nil))

            if x > 0, size.width > lineWidth + 0.5 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
                lineWidth = maxWidth
                size = subviews[index].sizeThatFits(ProposedViewSize(width: lineWidth, height: nil))
            }

            let placedWidth = min(size.width, lineWidth)
            items.append((index, CGRect(x: x, y: y, width: placedWidth, height: size.height)))
            x += placedWidth + spacing
            rowHeight = max(rowHeight, size.height)

            if x >= maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
        }

        return (items, CGSize(width: maxWidth, height: y + rowHeight))
    }
}
