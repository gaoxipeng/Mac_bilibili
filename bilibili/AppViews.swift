import AppKit
import SwiftUI

enum VideoCardLayout {
    static let minWidth: CGFloat = 280
    static let gridSpacing: CGFloat = 22
    static let maxColumnCount = 5
    static let coverAspect: CGFloat = 16.0 / 9.0
    static let cornerRadius: CGFloat = 10
    static let coverHoverScale: CGFloat = 1.04
    static let coverHoverEnterAnimation = Animation.easeOut(duration: 0.09)
    static let coverHoverExitAnimation = Animation.easeOut(duration: 0.07)
    static let statsAuthorSpacing: CGFloat = 4
    static let metadataPadding = EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)

    static func columnCount(for width: CGFloat) -> Int {
        guard width > 0 else { return 1 }
        let natural = max(1, Int((width + gridSpacing) / (minWidth + gridSpacing)))
        return min(maxColumnCount, natural)
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

    static func rowStartIndices(itemCount: Int, columnCount: Int) -> [Int] {
        guard itemCount > 0, columnCount > 0 else { return [] }
        return Array(stride(from: 0, to: itemCount, by: columnCount))
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
    static let titleMaxLineCount = 2

    static func titleLineHeight(for metrics: RowLayoutMetrics) -> CGFloat {
        let font = titleNSFont(for: metrics)
        let appKitLineHeight = ceil(font.ascender - font.descender + font.leading)
        return ceil(appKitLineHeight * titleLineHeightScale)
    }

    static func titleAreaHeight(
        for _: String,
        columnWidth _: CGFloat,
        metrics: RowLayoutMetrics
    ) -> CGFloat {
        CGFloat(titleMaxLineCount) * titleLineHeight(for: metrics)
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

}

private enum FeedCardHoverStyle {
    static let colorAnimation = Animation.easeInOut(duration: 0.2)
}

private struct FeedScrollAwareHover: ViewModifier {
    @Environment(\.feedIsScrolling) private var feedIsScrolling
    @Binding var isHovered: Bool
    let animation: Animation

    func body(content: Content) -> some View {
        if feedIsScrolling {
            content
                .onChange(of: feedIsScrolling) { _, scrolling in
                    if scrolling {
                        isHovered = false
                    }
                }
        } else {
            content
                .onHover { hovering in
                    withAnimation(animation) {
                        isHovered = hovering
                    }
                }
        }
    }
}

struct HoverZoomVideoCover<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VideoCoverHoverScaleRepresentable(content: content())
    }
}

/// Feed card cover with GPU hover scale; image layer is embedded directly (no `NSHostingView`).
struct FeedVideoCoverHover: View {
    let url: URL?
    var fallbackURLs: [URL] = []
    var maxDecodePixelLength: Int?
    var cornerRadius: CGFloat = 0
    var placeholderSystemImage = "play.rectangle"

    @StateObject private var imageLoader = RemoteCoverImageLoader()

    var body: some View {
        Color.clear
            .aspectRatio(VideoCardLayout.coverAspect, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                FeedVideoCoverHoverRepresentable(
                    image: imageLoader.image ?? cachedImage,
                    failed: imageLoader.failed,
                    cornerRadius: cornerRadius,
                    placeholderSystemImage: placeholderSystemImage
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                imageLoader.primeFromMemoryCache(
                    url: url,
                    maxPixelLength: maxDecodePixelLength
                )
            }
            .task(id: loadTaskID) {
                imageLoader.load(
                    url: url,
                    fallbackURLs: fallbackURLs,
                    maxPixelLength: maxDecodePixelLength
                )
            }
            .onDisappear {
                imageLoader.cancel()
            }
    }

    private var loadTaskID: String {
        let fallbackKey = fallbackURLs.map(\.absoluteString).joined(separator: "|")
        let decodeKey = maxDecodePixelLength.map(String.init) ?? "source"
        return "\(url?.absoluteString ?? "")|\(fallbackKey)#feed#\(decodeKey)"
    }

    private var cachedImage: NSImage? {
        RemoteCoverImageLoader.cachedImage(
            url: url,
            maxPixelLength: maxDecodePixelLength
        )
    }
}

private struct FeedCardTitle: View {
    let title: String
    var usesLargeFont = false
    let textWidth: CGFloat
    let areaHeight: CGFloat
    let video: BiliVideo
    var resolveWatchProgress = false
    var progressSeconds = 0
    var epid: Int64 = 0
    var refererURL: URL? = nil
    var onOpen: (() -> Void)? = nil

    var body: some View {
        FeedCardTitleRepresentable(
            title: title,
            usesLargeFont: usesLargeFont,
            textWidth: textWidth,
            areaHeight: areaHeight
        )
        .frame(width: textWidth, height: areaHeight, alignment: .topLeading)
        .overlay {
            if let onOpen {
                Button(action: onOpen) {
                    Color.clear
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                VideoPlaybackLink(
                    video: video,
                    resolveWatchProgress: resolveWatchProgress,
                    progressSeconds: progressSeconds,
                    epid: epid,
                    refererURL: refererURL
                ) {
                    Color.clear
                        .contentShape(Rectangle())
                }
            }
        }
    }
}

struct VideoPlaybackLink<Label: View>: View {
    let video: BiliVideo
    var resolveWatchProgress = false
    var progressSeconds = 0
    var epid: Int64 = 0
    var refererURL: URL? = nil
    @ViewBuilder let label: () -> Label
    @EnvironmentObject private var model: AppModel

    private var destination: VideoPlaybackRequest {
        VideoPlaybackRequest(
            video,
            progressSeconds: progressSeconds,
            epid: epid,
            refererURL: refererURL
        )
    }

    var body: some View {
        Group {
            if resolveWatchProgress {
                Button {
                    model.openVideo(video, resolveWatchProgress: true)
                } label: {
                    label()
                }
                .buttonStyle(.plain)
            } else {
                NavigationLink(value: destination) {
                    label()
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct FeedCardAuthorLabel: View {
    let name: String
    var usesLargeFont = false
    let avatarURL: URL?
    let avatarSize: CGFloat
    let textWidth: CGFloat
    var trailingText: String? = nil
    var trailingFontSize: CGFloat? = nil
    @Environment(\.displayScale) private var displayScale

    private var nameFontSize: CGFloat {
        usesLargeFont
            ? NSFont.preferredFont(forTextStyle: .title3).pointSize
            : NSFont.preferredFont(forTextStyle: .body).pointSize
    }

    private var resolvedTrailingFontSize: CGFloat {
        trailingFontSize ?? NSFont.preferredFont(forTextStyle: .subheadline).pointSize
    }

    private var avatarPixelLength: Int {
        max(48, Int((avatarSize * max(1, displayScale) * 1.25).rounded(.up)))
    }

    var body: some View {
        FeedCardAuthorRowRepresentable(
            name: name,
            avatarURL: avatarURL,
            avatarSize: avatarSize,
            avatarPixelLength: avatarPixelLength,
            nameFontSize: nameFontSize,
            trailingText: trailingText,
            trailingFontSize: resolvedTrailingFontSize,
            rowWidth: textWidth
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct FeedLoadMoreFooter: View {
    let anchorID: Int
    let hasMore: Bool
    let loadingMore: Bool
    let onLoadMore: () -> Void

    @State private var requestedWhileVisible = false

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
        .onAppear {
            guard hasMore, !loadingMore, !requestedWhileVisible else { return }
            requestedWhileVisible = true
            onLoadMore()
        }
        .onDisappear {
            requestedWhileVisible = false
        }
    }
}

struct VideoFeedGrid<Trailing: View>: View {
    let videos: [BiliVideo]
    var largeTypography = false
    var showsLikeCount = true
    var showsAuthor = true
    var resolveWatchProgress = false
    var maxColumnCount: Int? = nil
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.feedViewportWidth) private var feedViewportWidth
    @Environment(\.feedSymmetricHorizontalInsets) private var feedSymmetricHorizontalInsets
    @Environment(\.feedUsesDirectViewportWidth) private var feedUsesDirectViewportWidth

    init(
        videos: [BiliVideo],
        largeTypography: Bool = false,
        showsLikeCount: Bool = true,
        showsAuthor: Bool = true,
        resolveWatchProgress: Bool = false,
        maxColumnCount: Int? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.videos = videos
        self.largeTypography = largeTypography
        self.showsLikeCount = showsLikeCount
        self.showsAuthor = showsAuthor
        self.resolveWatchProgress = resolveWatchProgress
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
        let rowStarts = VideoCardLayout.rowStartIndices(itemCount: videos.count, columnCount: columnCount)
        let titleAreaHeight = VideoCardLayout.titleAreaHeight(
            for: "",
            columnWidth: columnWidth,
            metrics: metrics
        )
        let cardHeight = VideoCardLayout.cardHeight(
            columnWidth: columnWidth,
            titleAreaHeight: titleAreaHeight,
            metrics: metrics
        )

        LazyVStack(alignment: .leading, spacing: VideoCardLayout.gridSpacing) {
            ForEach(rowStarts, id: \.self) { rowStart in
                let rowEnd = min(rowStart + columnCount, videos.count)

                HStack(alignment: .top, spacing: VideoCardLayout.gridSpacing) {
                    ForEach(videos[rowStart..<rowEnd]) { video in
                        VideoCard(
                            video: video,
                            largeTypography: largeTypography,
                            showsLikeCount: showsLikeCount,
                            showsAuthor: showsAuthor,
                            resolveWatchProgress: resolveWatchProgress,
                            columnWidth: columnWidth,
                            titleAreaHeight: titleAreaHeight
                        )
                        .equatable()
                        .frame(width: columnWidth, height: cardHeight, alignment: .top)
                    }
                }
            }

            trailing()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var resolvedLayoutWidth: CGFloat {
        let width: CGFloat
        if feedUsesDirectViewportWidth {
            width = feedViewportWidth
        } else if feedSymmetricHorizontalInsets {
            width = AppLayout.feedContentWidthSymmetric(viewportWidth: feedViewportWidth)
        } else {
            width = AppLayout.feedContentWidth(viewportWidth: feedViewportWidth)
        }
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

                    VideoFeedGrid(
                        videos: videos,
                        largeTypography: true,
                        showsLikeCount: false,
                        resolveWatchProgress: loggedIn
                    )
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

struct HomeView: View {
    let videos: [BiliVideo]
    let loading: Bool
    let loadingMore: Bool
    let hasMore: Bool
    let error: String?
    let loggedIn: Bool
    let scrollToTopTrigger: Int
    let onLoadMore: () -> Void

    var body: some View {
        AppScrollView(scrollToTopTrigger: scrollToTopTrigger) {
            LazyVStack(alignment: .leading, spacing: 10) {
                if !loggedIn {
                    ContentUnavailableView(
                        "登录后查看个人主页",
                        systemImage: "house",
                        description: Text("在「我的」页面完成登录，即可同步首页推荐")
                    )
                    .padding(.vertical, 40)
                    .frame(maxWidth: .infinity)
                    .materialPanel()
                } else {
                    StateBanner(
                        loading: loading,
                        error: error,
                        isEmpty: videos.isEmpty,
                        emptyTitle: "暂无推荐内容"
                    )

                    VideoFeedGrid(videos: videos)
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

private enum HistoryCardLayout {
    static let metrics = VideoCardLayout.RowLayoutMetrics.history

    static func titleAreaHeight(columnWidth: CGFloat) -> CGFloat {
        VideoCardLayout.titleAreaHeight(
            for: "",
            columnWidth: columnWidth,
            metrics: metrics
        )
    }

    static func cardHeight(columnWidth: CGFloat, titleAreaHeight: CGFloat) -> CGFloat {
        VideoCardLayout.cardHeight(columnWidth: columnWidth, titleAreaHeight: titleAreaHeight, metrics: metrics)
    }
}

private enum HistoryLayout {
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
                        LazyVStack(alignment: .leading, spacing: HistoryLayout.sectionSpacing) {
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
        let columnCount = VideoCardLayout.columnCount(for: layoutWidth)
        let columnWidth = VideoCardLayout.columnWidth(for: layoutWidth, columnCount: columnCount)
        let rowStarts = VideoCardLayout.rowStartIndices(itemCount: items.count, columnCount: columnCount)
        let titleAreaHeight = HistoryCardLayout.titleAreaHeight(columnWidth: columnWidth)
        let cardHeight = HistoryCardLayout.cardHeight(columnWidth: columnWidth, titleAreaHeight: titleAreaHeight)

        LazyVStack(alignment: .leading, spacing: VideoCardLayout.gridSpacing) {
            ForEach(rowStarts, id: \.self) { rowStart in
                let rowEnd = min(rowStart + columnCount, items.count)

                HStack(alignment: .top, spacing: VideoCardLayout.gridSpacing) {
                    ForEach(items[rowStart..<rowEnd]) { item in
                        HistoryVideoCard(
                            item: item,
                            columnWidth: columnWidth,
                            titleAreaHeight: titleAreaHeight,
                            onDelete: { onDelete(item) }
                        )
                        .equatable()
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

private struct HistoryVideoCard: View, Equatable {
    let item: BiliHistoryItem
    let columnWidth: CGFloat
    let titleAreaHeight: CGFloat
    let onDelete: () -> Void
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.displayScale) private var displayScale
    @State private var isDeleteHovered = false

    static func == (lhs: HistoryVideoCard, rhs: HistoryVideoCard) -> Bool {
        lhs.item == rhs.item
            && lhs.columnWidth == rhs.columnWidth
            && lhs.titleAreaHeight == rhs.titleAreaHeight
    }

    private var video: BiliVideo { item.video }

    private var coverHeight: CGFloat {
        VideoCardLayout.coverHeight(columnWidth: columnWidth)
    }

    private var coverDecodePixelLength: Int {
        let displayMax = max(columnWidth, coverHeight)
        return Int((displayMax * max(1, displayScale) * 1.05).rounded(.up))
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
        VStack(alignment: .leading, spacing: 0) {
            coverSection
                .frame(height: coverHeight)
            metadataSection
                .frame(height: metadataHeight)
        }
        .frame(height: coverHeight + metadataHeight)
        .background(FeedCardSurfaceRepresentable(cornerRadius: VideoCardLayout.cornerRadius))
    }

    private var coverSection: some View {
        Button {
            appModel.openHistoryVideo(item)
        } label: {
            ZStack(alignment: .bottomTrailing) {
                FeedVideoCoverHover(
                    url: video.coverURL,
                    maxDecodePixelLength: coverDecodePixelLength,
                    cornerRadius: VideoCardLayout.cornerRadius
                )

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
            .contentShape(RoundedRectangle(cornerRadius: VideoCardLayout.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var metadataTextWidth: CGFloat {
        columnWidth
            - HistoryCardLayout.metrics.metadataPadding.leading
            - HistoryCardLayout.metrics.metadataPadding.trailing
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            FeedCardTitle(
                title: video.title,
                textWidth: metadataTextWidth,
                areaHeight: titleAreaHeight,
                video: video,
                progressSeconds: item.progressSeconds,
                epid: item.epid,
                refererURL: item.webURI,
                onOpen: { appModel.openHistoryVideo(item) }
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
            avatarURL: video.authorFaceURL,
            avatarSize: 26,
            textWidth: metadataTextWidth
        )
    }
}

struct MineView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showLogin = false
    @StateObject private var webSession = BilibiliWebSession()

    var body: some View {
        Group {
            if let account = model.account,
               let mid = Int64(account.uid),
               mid > 0 {
                UserProfileView(
                    mid: mid,
                    credential: account.credential,
                    viewerMid: mid
                )
                .id(mid)
            } else {
                loginContent
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
            .environmentObject(model)
        }
    }

    private var loginContent: some View {
        AppScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "我的", subtitle: "登录后查看个人主页、关注和历史")
                LoginCard {
                    showLogin = true
                }

                if let message = model.loginMessage {
                    Label(message, systemImage: message.hasPrefix("已") ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(message.hasPrefix("已") ? .green : .orange)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .materialPanel()
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

struct VideoCard: View, Equatable {
    let video: BiliVideo
    var largeTypography = false
    var showsLikeCount = true
    var showsAuthor = true
    var resolveWatchProgress = false
    let columnWidth: CGFloat
    let titleAreaHeight: CGFloat
    @Environment(\.displayScale) private var displayScale

    static func == (lhs: VideoCard, rhs: VideoCard) -> Bool {
        lhs.video == rhs.video
            && lhs.largeTypography == rhs.largeTypography
            && lhs.showsLikeCount == rhs.showsLikeCount
            && lhs.showsAuthor == rhs.showsAuthor
            && lhs.resolveWatchProgress == rhs.resolveWatchProgress
            && lhs.columnWidth == rhs.columnWidth
            && lhs.titleAreaHeight == rhs.titleAreaHeight
    }

    private var metrics: VideoCardLayout.RowLayoutMetrics {
        .feed(largeTypography: largeTypography, showsAuthor: showsAuthor)
    }

    private var coverHeight: CGFloat {
        VideoCardLayout.coverHeight(columnWidth: columnWidth)
    }

    private var coverDecodePixelLength: Int {
        let displayMax = max(columnWidth, coverHeight)
        return Int((displayMax * max(1, displayScale) * 1.05).rounded(.up))
    }

    private var metadataHeight: CGFloat {
        metrics.metadataHeight(titleAreaHeight: titleAreaHeight)
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
        VStack(alignment: .leading, spacing: 0) {
            coverSection
                .frame(height: coverHeight)
            metadataSection
                .frame(height: metadataHeight)
        }
        .background(FeedCardSurfaceRepresentable(cornerRadius: cornerRadius))
    }

    private var coverSection: some View {
        VideoPlaybackLink(video: video, resolveWatchProgress: resolveWatchProgress) {
            ZStack(alignment: .bottomTrailing) {
                FeedVideoCoverHover(
                    url: video.coverURL,
                    maxDecodePixelLength: coverDecodePixelLength,
                    cornerRadius: cornerRadius
                )

                if video.duration > 0 {
                    VideoCoverDurationBadge(text: video.durationText)
                        .padding(8)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    private var metadataTextWidth: CGFloat {
        columnWidth - metrics.metadataPadding.leading - metrics.metadataPadding.trailing
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            FeedCardTitle(
                title: video.title,
                usesLargeFont: largeTypography,
                textWidth: metadataTextWidth,
                areaHeight: titleAreaHeight,
                video: video,
                resolveWatchProgress: resolveWatchProgress
            )

            if metrics.includesStats {
                VideoPlaybackLink(video: video, resolveWatchProgress: resolveWatchProgress) {
                    statsRow
                        .frame(height: metrics.statsHeight, alignment: .leading)
                }
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
        HStack(alignment: .center, spacing: 0) {
            authorIdentity
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
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
            name: video.authorName,
            usesLargeFont: largeTypography,
            avatarURL: video.authorFaceURL,
            avatarSize: avatarSize,
            textWidth: metadataTextWidth,
            trailingText: video.publishTime.map { BiliCommentFormats.formatTime($0) },
            trailingFontSize: statsFontSize
        )
    }

    private var statsFontSize: CGFloat {
        largeTypography
            ? NSFont.preferredFont(forTextStyle: .body).pointSize
            : NSFont.preferredFont(forTextStyle: .subheadline).pointSize
    }

    private var statsRow: some View {
        FeedCardStatsRowRepresentable(
            playCount: video.viewCount.compactCount,
            danmakuCount: video.danmakuCount.compactCount,
            likeCount: showsLikeCount ? video.likeCount.compactCount : nil,
            iconSize: statIconSize,
            likeIconSize: likeStatIconSize,
            fontSize: statsFontSize,
            itemSpacing: 12
        )
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private func buildHistorySections(from items: [BiliHistoryItem]) -> [HistorySection] {
    let sortedItems = JSONParser.sortHistoryItems(items)
    let calendar = Calendar.current

    var sections: [HistorySection] = []
    var currentDay: Date?
    var currentItems: [BiliHistoryItem] = []

    func appendCurrentSection() {
        guard let currentDay, !currentItems.isEmpty else { return }
        let label = historySectionLabel(from: currentItems.first?.viewedAt)
        sections.append(
            HistorySection(
                id: "\(Int(currentDay.timeIntervalSince1970))",
                label: label,
                items: currentItems
            )
        )
    }

    for item in sortedItems {
        let itemDay = item.viewedAt.map { calendar.startOfDay(for: $0) }
        if itemDay != currentDay {
            appendCurrentSection()
            currentDay = itemDay
            currentItems = [item]
        } else {
            currentItems.append(item)
        }
    }

    appendCurrentSection()
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

struct WebLoginSheet: View {
    @EnvironmentObject private var appModel: AppModel
    @ObservedObject var session: BilibiliWebSession
    let onCompleteLogin: () -> Void
    @Environment(\.dismiss) private var dismiss

    private let sheetMinWidth: CGFloat = 1080
    private let sheetMinHeight: CGFloat = 780

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            BilibiliWebView(webView: session.webView)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(
            minWidth: sheetMinWidth,
            idealWidth: sheetMinWidth,
            minHeight: sheetMinHeight,
            idealHeight: sheetMinHeight
        )
        .background(.regularMaterial)
        .task {
            if appModel.consumeFreshWebLoginFlag() {
                await session.prepareFreshLogin()
            } else {
                session.openLogin(forceReload: true)
                await session.refreshLoginState()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("哔哩哔哩登录")
                    .font(.title2.weight(.bold))
                Text("在下方页面完成登录。若要切换账号，请先点「清除网页登录」。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 10) {
                Button("清除网页登录") {
                    Task { await session.prepareFreshLogin() }
                }
                .buttonStyle(.bordered)

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

struct RemoteCover: View {
    let url: URL?
    var fallbackURLs: [URL] = []
    let aspectRatio: CGFloat
    var width: CGFloat?
    var height: CGFloat?
    var maxDecodePixelLength: Int?
    var cornerRadius: CGFloat = 0
    var appliesCornerClip = true
    var placeholderSystemImage = "play.rectangle"
    @StateObject private var imageLoader = RemoteCoverImageLoader()
    @Environment(\.displayScale) private var displayScale

    private var resolvedCornerRadius: CGFloat {
        if cornerRadius > 0 {
            return cornerRadius
        }
        return appliesCornerClip ? 8 : 0
    }

    var body: some View {
        Group {
            if let width, let height {
                coverImageLayer
                    .frame(width: width, height: height)
            } else {
                Color.clear
                    .aspectRatio(aspectRatio, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .overlay {
                        coverImageLayer
                    }
            }
        }
        .onAppear {
            imageLoader.primeFromMemoryCache(
                url: url,
                maxPixelLength: coverDecodePixelLength
            )
        }
        .task(id: loadTaskID) {
            imageLoader.load(
                url: url,
                fallbackURLs: fallbackURLs,
                maxPixelLength: coverDecodePixelLength
            )
        }
        .onDisappear {
            imageLoader.cancel()
        }
    }

    private var coverImageLayer: some View {
        RemoteCoverImageRepresentable(
            image: imageLoader.image ?? cachedImage,
            failed: imageLoader.failed,
            cornerRadius: resolvedCornerRadius,
            placeholderSystemImage: placeholderSystemImage
        )
    }

    private var loadTaskID: String {
        let fallbackKey = fallbackURLs.map(\.absoluteString).joined(separator: "|")
        let decodeKey = coverDecodePixelLength.map(String.init) ?? "source"
        if let width, let height {
            return "\(url?.absoluteString ?? "")|\(fallbackKey)#\(Int(width))x\(Int(height))#\(displayScale)#\(decodeKey)"
        }
        return "\(url?.absoluteString ?? "")|\(fallbackKey)#feed#\(decodeKey)"
    }

    private var coverDecodePixelLength: Int? {
        if let maxDecodePixelLength {
            return maxDecodePixelLength
        }
        if let width, let height {
            let displayMax = max(width, height)
            return Int((displayMax * max(1, displayScale)).rounded(.up))
        }
        return nil
    }

    private var cachedImage: NSImage? {
        RemoteCoverImageLoader.cachedImage(
            url: url,
            maxPixelLength: coverDecodePixelLength
        )
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
        RemoteAvatarImageRepresentable(
            image: imageLoader.image ?? cachedImage,
            size: size,
            foreground: foreground.nsColor,
            background: background.nsColor,
            border: border.nsColor
        )
        .frame(width: size, height: size)
        .onAppear {
            imageLoader.primeFromMemoryCache(url: url, maxPixelLength: avatarPixelLength)
        }
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
