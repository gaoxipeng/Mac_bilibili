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
    static let coverOverlayPadding: CGFloat = 6
    static let coverOverlayBottomPadding: CGFloat = 5
    static let coverOverlayIconSize: CGFloat = 14
    static let coverOverlayFontSize: CGFloat = 12
    static let coverOverlayItemSpacing: CGFloat = 8
    static let feedMetadataHorizontalPadding: CGFloat = 8
    static let metadataPadding = EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
    static let feedMetadataPadding = EdgeInsets(
        top: 10,
        leading: feedMetadataHorizontalPadding,
        bottom: 10,
        trailing: feedMetadataHorizontalPadding
    )

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

        static func feed(largeTypography: Bool, showsAuthor: Bool = true, showsPublishTime: Bool = false) -> RowLayoutMetrics {
            let bottomRowHeight: CGFloat = {
                if showsAuthor || showsPublishTime {
                    return largeTypography ? 30 : 26
                }
                return 0
            }()
            return RowLayoutMetrics(
                metadataPadding: VideoCardLayout.feedMetadataPadding,
                usesLargeTitleFont: largeTypography,
                statsHeight: 0,
                authorRowHeight: bottomRowHeight,
                includesStats: false,
                statsAuthorSpacing: 0
            )
        }

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
        metrics: RowLayoutMetrics,
        usesCardSurface: Bool = true,
        showsAuthor: Bool = true,
        showsPublishTime: Bool = false
    ) -> CGFloat {
        coverHeight(columnWidth: columnWidth) + metadataHeight(
            titleAreaHeight: titleAreaHeight,
            metrics: metrics,
            usesCardSurface: usesCardSurface,
            showsAuthor: showsAuthor,
            showsPublishTime: showsPublishTime
        )
    }

    static func metadataHeight(
        titleAreaHeight: CGFloat,
        metrics: RowLayoutMetrics,
        usesCardSurface: Bool = true,
        showsAuthor: Bool = true,
        showsPublishTime: Bool = false
    ) -> CGFloat {
        var height = metrics.metadataHeight(titleAreaHeight: titleAreaHeight)
        if !usesCardSurface, !showsAuthor, !showsPublishTime {
            height -= metrics.metadataPadding.bottom
        }
        return height
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
            areaHeight: areaHeight
        )
        .frame(maxWidth: .infinity, minHeight: areaHeight, maxHeight: areaHeight, alignment: .topLeading)
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
                .buttonStyle(VideoCardOpenButtonStyle())
            } else {
                Button {
                    model.openPlayback(destination)
                } label: {
                    label()
                }
                .buttonStyle(VideoCardOpenButtonStyle())
            }
        }
    }
}

struct VideoCardOpenButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
            .animation(
                .spring(response: 0.20, dampingFraction: 0.72, blendDuration: 0.02),
                value: configuration.isPressed
            )
    }
}

private struct FeedCardAuthorLabel: View {
    let name: String
    var authorMid: Int64 = 0
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
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .init(horizontal: .leading, vertical: .center)
        )
        .overlay {
            if authorMid > 0 {
                NavigationLink(value: UserProfileRequest(mid: authorMid)) {
                    Color.clear
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct FeedLoadMoreFooter: View {
    private static let prefetchDistance: CGFloat = 320

    let anchorID: Int
    let hasMore: Bool
    let loadingMore: Bool
    var automaticallyContinueWhileVisible = false
    let onLoadMore: () -> Void

    @State private var isVisible = false
    @State private var requestedWhileVisible = false
    @State private var showLoadingIndicator = false

    private func requestNextPageIfNeeded() {
        guard hasMore, !loadingMore, !requestedWhileVisible else { return }
        requestedWhileVisible = true
        onLoadMore()
    }

    var body: some View {
        ZStack {
            Color.clear
            if showLoadingIndicator {
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
        .task(id: loadingMore) {
            guard loadingMore else {
                showLoadingIndicator = false
                return
            }
            // Publishing a page is followed by a card-layer render commit. Keep
            // that normal work invisible and only indicate a sustained wait.
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled, loadingMore else { return }
            showLoadingIndicator = true
        }
        .overlay(alignment: .top) {
            Color.clear
                .frame(height: 1)
                .offset(y: -Self.prefetchDistance)
                .onScrollVisibilityChange(threshold: 0.01) { visible in
                    isVisible = visible
                    if visible {
                        requestNextPageIfNeeded()
                    } else {
                        // Appending a page moves this marker below the viewport;
                        // it can request again only when scrolling near the new end.
                        requestedWhileVisible = false
                    }
                }
        }
        .onDisappear {
            isVisible = false
            requestedWhileVisible = false
        }
        .onChange(of: anchorID) { _, _ in
            if automaticallyContinueWhileVisible {
                // Search results may fill a large viewport with more than one
                // page, so keep paging until the new end leaves the viewport.
                requestedWhileVisible = false
                if isVisible {
                    requestNextPageIfNeeded()
                }
            } else if !isVisible {
                // Other feeds require the user to leave the old end and scroll
                // to the newly appended end before another request is allowed.
                requestedWhileVisible = false
            }
        }
        .onChange(of: loadingMore) { _, isLoading in
            // The sentinel can become visible while the initial page is still
            // loading. Give it its one request when that initial load completes.
            if !isLoading, isVisible, !requestedWhileVisible {
                requestNextPageIfNeeded()
            }
        }
    }
}

struct VideoFeedGrid<Trailing: View>: View {
    let videos: [BiliVideo]
    var largeTypography = false
    var showsLikeCount = true
    var showsAuthor = true
    var usesCardSurface = true
    var resolveWatchProgress = true
    var maxColumnCount: Int? = nil
    var onApproachingEnd: (() -> Void)? = nil
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.feedViewportWidth) private var feedViewportWidth
    @Environment(\.feedSymmetricHorizontalInsets) private var feedSymmetricHorizontalInsets
    @Environment(\.feedUsesDirectViewportWidth) private var feedUsesDirectViewportWidth

    init(
        videos: [BiliVideo],
        largeTypography: Bool = false,
        showsLikeCount: Bool = true,
        showsAuthor: Bool = true,
        usesCardSurface: Bool = true,
        resolveWatchProgress: Bool = true,
        maxColumnCount: Int? = nil,
        onApproachingEnd: (() -> Void)? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.videos = videos
        self.largeTypography = largeTypography
        self.showsLikeCount = showsLikeCount
        self.showsAuthor = showsAuthor
        self.usesCardSurface = usesCardSurface
        self.resolveWatchProgress = resolveWatchProgress
        self.maxColumnCount = maxColumnCount
        self.onApproachingEnd = onApproachingEnd
        self.trailing = trailing
    }

    var body: some View {
        let layoutWidth = resolvedLayoutWidth
        let baseColumnCount = VideoCardLayout.columnCount(for: layoutWidth)
        let columnCount = maxColumnCount.map { min($0, baseColumnCount) } ?? baseColumnCount
        let columnWidth = VideoCardLayout.columnWidth(for: layoutWidth, columnCount: columnCount)
        let showsPublishTime = !showsAuthor
        let metrics = VideoCardLayout.RowLayoutMetrics.feed(
            largeTypography: largeTypography,
            showsAuthor: showsAuthor,
            showsPublishTime: showsPublishTime
        )
        let rowStarts = VideoCardLayout.rowStartIndices(itemCount: videos.count, columnCount: columnCount)
        let prefetchRowStart = rowStarts.count >= 2 ? rowStarts[rowStarts.count - 2] : rowStarts.first
        let titleAreaHeight = VideoCardLayout.titleAreaHeight(
            for: "",
            columnWidth: columnWidth,
            metrics: metrics
        )
        let cardHeight = VideoCardLayout.cardHeight(
            columnWidth: columnWidth,
            titleAreaHeight: titleAreaHeight,
            metrics: metrics,
            usesCardSurface: usesCardSurface,
            showsAuthor: showsAuthor,
            showsPublishTime: showsPublishTime
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
                            showsPublishTime: showsPublishTime,
                            usesCardSurface: usesCardSurface,
                            resolveWatchProgress: resolveWatchProgress,
                            columnWidth: columnWidth,
                            titleAreaHeight: titleAreaHeight
                        )
                        .equatable()
                        .frame(width: columnWidth, height: cardHeight, alignment: .top)
                    }
                }
                .onScrollVisibilityChange(threshold: 0.01) { visible in
                    if visible, rowStart == prefetchRowStart {
                        onApproachingEnd?()
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

                VideoFeedGrid(videos: videos, largeTypography: true)
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

private enum HistoryCardTransition {
    static let removal = AnyTransition.asymmetric(
        insertion: .opacity,
        removal: .opacity.combined(with: .scale(scale: 0.94))
    )

    static let sectionRemoval = AnyTransition.asymmetric(
        insertion: .opacity,
        removal: .opacity.combined(with: .move(edge: .top))
    )
}

private enum HistoryCardLayout {
    static let metrics = VideoCardLayout.RowLayoutMetrics.feed(largeTypography: true, showsAuthor: true)
    static let deleteButtonSize: CGFloat = 18
    static let deleteButtonSpacing: CGFloat = 8

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
    static let pageLeadingInset: CGFloat = 24
    static let lineWidth: CGFloat = 1
    static let lineX: CGFloat = 104
    static let labelTrailingGap: CGFloat = 10
    static let contentSpacingFromLine: CGFloat = 22
    static let sectionSpacing: CGFloat = 28
    static let sectionScrollTopInset: CGFloat = AppLayout.feedVerticalInset
    static let topLabelHeight: CGFloat = 44
    static let labelFontSize: CGFloat = 20
    static let labelColor = Color(red: 0.38, green: 0.40, blue: 0.43)
    static let lineColor = Color(red: 0.788, green: 0.804, blue: 0.816)
    static let lineTopOverscan: CGFloat = 32

    static var labelAreaWidth: CGFloat {
        max(0, lineX - labelTrailingGap - lineWidth / 2)
    }

    static var contentLeadingInset: CGFloat {
        lineX + lineWidth / 2 + contentSpacingFromLine
    }

    static var stickyPinLine: CGFloat {
        sectionScrollTopInset
    }

    static var stickyHeaderWidth: CGFloat {
        lineX + lineWidth / 2
    }

    static func contentWidth(viewportWidth: CGFloat) -> CGFloat {
        max(0, viewportWidth - pageLeadingInset - AppLayout.feedTrailingInset)
    }
}

private struct HistoryVerticalLine: View {
    let height: CGFloat

    var body: some View {
        Rectangle()
            .fill(HistoryLayout.lineColor)
            .frame(width: HistoryLayout.lineWidth, height: max(height, 1))
            .offset(x: HistoryLayout.lineX - HistoryLayout.lineWidth / 2)
    }
}

private struct HistorySectionDateLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: HistoryLayout.labelFontSize, weight: .medium))
            .foregroundStyle(HistoryLayout.labelColor)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .allowsTightening(true)
            .frame(
                width: HistoryLayout.labelAreaWidth,
                height: HistoryLayout.topLabelHeight,
                alignment: .trailing
            )
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

    private var sections: [HistorySection] {
        buildHistorySections(from: items)
    }

    private var stickySection: HistorySection? {
        var pinned: HistorySection?
        for section in sections {
            guard let y = sectionHeaderViewportY[section.id] else { continue }
            if y <= HistoryLayout.stickyPinLine {
                pinned = section
            }
        }

        if pinned == nil,
           let first = sections.first,
           let y = sectionHeaderViewportY[first.id],
           y > HistoryLayout.stickyPinLine {
            return first
        }

        return pinned
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        StateBanner(
                            loading: loading,
                            error: error,
                            isEmpty: items.isEmpty,
                            emptyTitle: loggedIn ? "暂无观看历史" : "登录后查看观看历史"
                        )

                        ForEach(sections) { section in
                            HistorySectionView(
                                section: section,
                                hidesInlineDate: stickySection?.id == section.id,
                                onDelete: onDelete
                            )
                            .id(section.id)
                            .padding(.bottom, HistoryLayout.sectionSpacing)
                            .transition(HistoryCardTransition.sectionRemoval)
                        }
                        .animation(AppLayout.listRemovalAnimation, value: sections.map(\.id))

                        if hasMore, !items.isEmpty {
                            FeedLoadMoreFooter(
                                anchorID: items.count,
                                hasMore: hasMore,
                                loadingMore: loadingMore,
                                onLoadMore: onLoadMore
                            )
                        }
                    }
                    .padding(.leading, HistoryLayout.pageLeadingInset)
                    .padding(.trailing, AppLayout.feedTrailingInset)
                    .padding(.bottom, AppLayout.feedVerticalInset)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .environment(\.feedViewportWidth, geometry.size.width)
                }
                .contentMargins(.top, HistoryLayout.sectionScrollTopInset, for: .scrollContent)
                .contentMargins(.bottom, AppLayout.feedVerticalInset, for: .scrollContent)
                .background(MacOverlayScrollConfigurator())
                .onPreferenceChange(HistorySectionViewportKey.self) { updates in
                    sectionHeaderViewportY = updates
                }

                HistoryVerticalLine(height: geometry.size.height + HistoryLayout.lineTopOverscan)
                    .offset(
                        x: HistoryLayout.pageLeadingInset,
                        y: -HistoryLayout.lineTopOverscan
                    )
                    .allowsHitTesting(false)
                    .zIndex(1)

                if let stickySection {
                    HistorySectionDateLabel(title: stickySection.label)
                        .frame(width: HistoryLayout.stickyHeaderWidth, alignment: .leading)
                        .offset(x: HistoryLayout.pageLeadingInset, y: HistoryLayout.stickyPinLine)
                        .animation(.easeOut(duration: 0.2), value: stickySection.id)
                        .zIndex(2)
                }
            }
        }
    }
}

private struct HistorySectionView: View {
    let section: HistorySection
    var hidesInlineDate = false
    let onDelete: (BiliHistoryItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HistorySectionDateLabel(title: section.label)
                .opacity(hidesInlineDate ? 0 : 1)

            HistoryItemsGrid(items: section.items, onDelete: onDelete)
                .padding(.leading, HistoryLayout.contentLeadingInset)
        }
        .background(alignment: .topLeading) {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: HistorySectionViewportKey.self,
                    value: [
                        section.id: geometry.frame(in: .scrollView(axis: .vertical)).minY,
                    ]
                )
            }
        }
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

        VStack(alignment: .leading, spacing: VideoCardLayout.gridSpacing) {
            ForEach(rowStarts, id: \.self) { rowStart in
                let rowEnd = min(rowStart + columnCount, items.count)

                HStack(alignment: .top, spacing: VideoCardLayout.gridSpacing) {
                    ForEach(items[rowStart..<rowEnd], id: \.listIdentity) { item in
                        HistoryVideoCard(
                            item: item,
                            columnWidth: columnWidth,
                            titleAreaHeight: titleAreaHeight,
                            onDelete: { onDelete(item) }
                        )
                        .equatable()
                        .frame(width: columnWidth, height: cardHeight, alignment: .top)
                        .transition(HistoryCardTransition.removal)
                    }
                }
            }
        }
        .animation(AppLayout.listRemovalAnimation, value: items.map(\.listIdentity))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var resolvedLayoutWidth: CGFloat {
        let contentWidth = HistoryLayout.contentWidth(viewportWidth: feedViewportWidth)
        let historyWidth = max(0, contentWidth - HistoryLayout.contentLeadingInset)
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

    private var metrics: VideoCardLayout.RowLayoutMetrics {
        HistoryCardLayout.metrics
    }

    private var metadataHeight: CGFloat {
        metrics.metadataHeight(titleAreaHeight: titleAreaHeight)
    }

    private var avatarSize: CGFloat {
        30
    }

    private var statsFontSize: CGFloat {
        NSFont.preferredFont(forTextStyle: .body).pointSize
    }

    private var authorRowContentWidth: CGFloat {
        let trashReserve = item.kid.isEmpty
            ? 0
            : HistoryCardLayout.deleteButtonSize + HistoryCardLayout.deleteButtonSpacing
        return max(0, columnWidth - trashReserve)
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
            ZStack(alignment: .bottom) {
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
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: VideoCardLayout.cornerRadius,
                            style: .continuous
                        )
                    )
                }

                VideoCoverFeedMetaOverlay(durationText: durationBadgeText)
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: VideoCardLayout.cornerRadius,
                            style: .continuous
                        )
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: VideoCardLayout.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            FeedCardTitle(
                title: video.title,
                usesLargeFont: true,
                areaHeight: titleAreaHeight,
                video: video,
                progressSeconds: item.progressSeconds,
                epid: item.epid,
                refererURL: item.webURI,
                onOpen: { appModel.openHistoryVideo(item) }
            )
            .padding(.top, metrics.metadataPadding.top)

            authorRow
                .frame(height: metrics.authorRowHeight, alignment: .center)
                .padding(.bottom, metrics.metadataPadding.bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var authorRow: some View {
        HStack(alignment: .center, spacing: HistoryCardLayout.deleteButtonSpacing) {
            FeedCardAuthorLabel(
                name: authorDisplayName,
                authorMid: video.authorMid,
                usesLargeFont: true,
                avatarURL: video.authorFaceURL,
                avatarSize: avatarSize,
                textWidth: authorRowContentWidth,
                trailingText: item.viewedAt.map { historyViewTimeText(from: $0) },
                trailingFontSize: statsFontSize
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            if !item.kid.isEmpty {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(
                            isDeleteHovered ? AnyShapeStyle(Color.red) : AnyShapeStyle(.tertiary)
                        )
                        .animation(FeedCardHoverStyle.colorAnimation, value: isDeleteHovered)
                        .frame(
                            width: HistoryCardLayout.deleteButtonSize,
                            height: HistoryCardLayout.deleteButtonSize
                        )
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
                    viewerMid: mid,
                    seedSpace: model.mineSpaceCache(for: mid),
                    onPersistSpace: { model.adoptMineSpaceCache($0) }
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
    var showsPublishTime = false
    var usesCardSurface = true
    var resolveWatchProgress = false
    let columnWidth: CGFloat
    let titleAreaHeight: CGFloat
    @Environment(\.displayScale) private var displayScale

    static func == (lhs: VideoCard, rhs: VideoCard) -> Bool {
        lhs.video == rhs.video
            && lhs.largeTypography == rhs.largeTypography
            && lhs.showsLikeCount == rhs.showsLikeCount
            && lhs.showsAuthor == rhs.showsAuthor
            && lhs.showsPublishTime == rhs.showsPublishTime
            && lhs.usesCardSurface == rhs.usesCardSurface
            && lhs.resolveWatchProgress == rhs.resolveWatchProgress
            && lhs.columnWidth == rhs.columnWidth
            && lhs.titleAreaHeight == rhs.titleAreaHeight
    }

    private var metrics: VideoCardLayout.RowLayoutMetrics {
        .feed(
            largeTypography: largeTypography,
            showsAuthor: showsAuthor,
            showsPublishTime: showsPublishTime
        )
    }

    private var coverHeight: CGFloat {
        VideoCardLayout.coverHeight(columnWidth: columnWidth)
    }

    private var coverDecodePixelLength: Int {
        let displayMax = max(columnWidth, coverHeight)
        return Int((displayMax * max(1, displayScale) * 1.05).rounded(.up))
    }

    private var metadataHeight: CGFloat {
        VideoCardLayout.metadataHeight(
            titleAreaHeight: titleAreaHeight,
            metrics: metrics,
            usesCardSurface: usesCardSurface,
            showsAuthor: showsAuthor,
            showsPublishTime: showsPublishTime
        )
    }

    private var avatarSize: CGFloat {
        largeTypography ? 30 : 26
    }

    private var cornerRadius: CGFloat {
        VideoCardLayout.cornerRadius
    }

    var body: some View {
        mosaicCard
            .frame(width: columnWidth, height: coverHeight + metadataHeight, alignment: .topLeading)
    }

    private var mosaicCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            coverSection
                .frame(height: coverHeight)
            metadataSection
                .frame(height: metadataHeight)
        }
        .background {
            if usesCardSurface {
                FeedCardSurfaceRepresentable(cornerRadius: cornerRadius)
            }
        }
    }

    private var coverSection: some View {
        VideoPlaybackLink(video: video, resolveWatchProgress: resolveWatchProgress) {
            ZStack(alignment: .bottom) {
                FeedVideoCoverHover(
                    url: video.coverURL,
                    maxDecodePixelLength: coverDecodePixelLength,
                    cornerRadius: cornerRadius
                )

                VideoCoverFeedMetaOverlay(
                    playCount: video.viewCount.compactCount,
                    danmakuCount: video.danmakuCount.compactCount,
                    likeCount: showsLikeCount ? video.likeCount.compactCount : nil,
                    durationText: video.duration > 0 ? video.durationText : ""
                )
                .clipShape(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
            }
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    private var metadataTextWidth: CGFloat {
        columnWidth
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            FeedCardTitle(
                title: video.title,
                usesLargeFont: largeTypography,
                areaHeight: titleAreaHeight,
                video: video,
                resolveWatchProgress: resolveWatchProgress
            )
            .padding(.top, metrics.metadataPadding.top)
            .padding(.bottom, metadataBottomPadding)

            if showsAuthor {
                authorRow
                    .frame(height: metrics.authorRowHeight, alignment: .center)
                    .padding(.bottom, metrics.metadataPadding.bottom)
            } else if showsPublishTime, let publishTime = video.publishTime {
                publishTimeRow(publishTime)
                    .frame(height: metrics.authorRowHeight, alignment: .center)
                    .padding(.bottom, metrics.metadataPadding.bottom)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func publishTimeRow(_ publishTime: Date) -> some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            Text(BiliCommentFormats.formatTime(publishTime))
                .font(.system(size: statsFontSize))
                .foregroundStyle(.secondary)
        }
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
        authorIdentityContent
            .frame(height: metrics.authorRowHeight, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var authorIdentityContent: some View {
        FeedCardAuthorLabel(
            name: video.authorName,
            authorMid: video.authorMid,
            usesLargeFont: largeTypography,
            avatarURL: video.authorFaceURL,
            avatarSize: avatarSize,
            textWidth: metadataTextWidth,
            trailingText: video.publishTime.map { BiliCommentFormats.formatTime($0) },
            trailingFontSize: statsFontSize
        )
    }

    private var metadataBottomPadding: CGFloat {
        if showsAuthor {
            return 0
        }
        return usesCardSurface ? metrics.metadataPadding.bottom : 0
    }

    private var statsFontSize: CGFloat {
        largeTypography
            ? NSFont.preferredFont(forTextStyle: .body).pointSize
            : NSFont.preferredFont(forTextStyle: .subheadline).pointSize
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
    var scalesToFill = true
    var matchesImageAspectRatio = false
    var placeholderSystemImage = "play.rectangle"
    @StateObject private var imageLoader = RemoteCoverImageLoader()
    @Environment(\.displayScale) private var displayScale

    private var resolvedCornerRadius: CGFloat {
        if cornerRadius > 0 {
            return cornerRadius
        }
        return appliesCornerClip ? 8 : 0
    }

    private var resolvedAspectRatio: CGFloat {
        if matchesImageAspectRatio,
           let image = imageLoader.image ?? cachedImage,
           image.size.width > 0,
           image.size.height > 0 {
            return image.size.width / image.size.height
        }
        return aspectRatio
    }

    var body: some View {
        Group {
            if let width, let height {
                coverImageLayer
                    .frame(width: width, height: height)
            } else {
                Color.clear
                    .aspectRatio(resolvedAspectRatio, contentMode: .fit)
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
            scalesToFill: scalesToFill,
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
