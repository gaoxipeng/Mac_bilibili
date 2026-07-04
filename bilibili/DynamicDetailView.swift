import Combine
import SwiftUI

@MainActor
final class DynamicDetailModel: ObservableObject {
    let item: BiliDynamicItem
    private let api = BilibiliAPI()
    private var credential: BilibiliCredential?

    @Published var commentSort: BiliCommentSort = .hot
    @Published var comments: [BiliCommentItem] = []
    @Published var commentsLoading = false
    @Published var commentsLoadingMore = false
    @Published var commentsError: String?
    @Published var commentsEnd = false
    @Published private(set) var commentsScrollToTopToken = 0

    private var commentsCursor: String?
    private var commentsLoadInFlight = false
    private var loadedCommentsKey: String?

    init(item: BiliDynamicItem, credential: BilibiliCredential?) {
        self.item = item
        self.credential = credential
    }

    var referer: String {
        "https://t.bilibili.com/\(item.id)"
    }

    var commentCountLabel: String {
        let count = item.commentCount
        return count > 0 ? count.compactCount : ""
    }

    var commentsHaveLoaded: Bool {
        loadedCommentsKey != nil
    }

    var canLoadComments: Bool {
        item.commentOid > 0 && item.commentType > 0
    }

    func load() async {
        guard canLoadComments else { return }
        await loadComments(reset: true)
    }

    func loadComments(reset: Bool) async {
        guard canLoadComments else { return }
        guard !commentsLoadInFlight else { return }

        if reset {
            commentsCursor = nil
            commentsEnd = false
            commentsError = nil
            commentsLoading = true
        } else {
            if commentsEnd || commentsLoadingMore || commentsLoading || comments.isEmpty {
                return
            }
            if commentsCursor?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                commentsEnd = true
                return
            }
            commentsLoadingMore = true
        }

        commentsLoadInFlight = true
        let previousCount = comments.count
        defer {
            commentsLoading = false
            commentsLoadingMore = false
            commentsLoadInFlight = false
        }

        do {
            let page = try await api.subjectComments(
                oid: item.commentOid,
                type: item.commentType,
                sort: commentSort,
                cursor: reset ? nil : commentsCursor,
                referer: referer,
                credential: credential
            )
            if reset {
                comments = page.comments
            } else {
                let existing = Set(comments.map(\.id))
                comments.append(contentsOf: page.comments.filter { !existing.contains($0.id) })
            }
            commentsCursor = page.nextCursor
            commentsEnd = resolveCommentsEnd(
                page: page,
                mergedCount: comments.count,
                previousCount: previousCount
            )
            commentsError = nil
            loadedCommentsKey = "\(item.commentOid):\(item.commentType):\(commentSort.rawValue)"
        } catch {
            if reset {
                comments = []
                commentsEnd = true
                commentsError = error.localizedDescription
            }
        }
    }

    private func resolveCommentsEnd(page: BiliCommentPage, mergedCount: Int, previousCount: Int) -> Bool {
        if page.isEnd { return true }
        if page.nextCursor?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { return true }
        if page.comments.isEmpty { return true }
        if mergedCount == previousCount { return true }
        return false
    }

    func toggleCommentSort() async {
        let newSort: BiliCommentSort = commentSort == .hot ? .time : .hot
        guard newSort != commentSort else { return }
        commentSort = newSort
        loadedCommentsKey = nil
        await loadComments(reset: true)
        loadedCommentsKey = "\(item.commentOid):\(item.commentType):\(commentSort.rawValue)"
        commentsScrollToTopToken += 1
    }

    func loadMoreReplies(for commentID: Int64) async {
        guard let index = comments.firstIndex(where: { $0.id == commentID }) else { return }
        var comment = comments[index]
        guard !comment.repliesEnd else { return }

        let nextPage = (comment.loadedReplies.count / 20) + 1
        do {
            let page = try await api.subjectCommentReplies(
                oid: item.commentOid,
                type: item.commentType,
                rootID: commentID,
                referer: referer,
                page: nextPage,
                credential: credential
            )
            let merged = comment.loadedReplies + page.replies.filter { reply in
                !comment.loadedReplies.contains(where: { $0.id == reply.id })
            }
            comment = BiliCommentItem(
                id: comment.id,
                authorMid: comment.authorMid,
                authorName: comment.authorName,
                authorFaceURL: comment.authorFaceURL,
                level: comment.level,
                content: comment.content,
                likeCount: comment.likeCount,
                replyCount: comment.replyCount,
                publishTime: comment.publishTime,
                ipLocation: comment.ipLocation,
                emoticons: comment.emoticons,
                pictures: comment.pictures,
                replies: comment.replies,
                loadedReplies: merged,
                repliesEnd: page.isEnd
            )
            comments[index] = comment
        } catch {
            commentsError = error.localizedDescription
        }
    }
}

struct DynamicDetailView: View {
    @Environment(\.videoDetailChromeHeight) private var chromeHeight
    @EnvironmentObject private var appModel: AppModel
    @StateObject private var model: DynamicDetailModel
    @State private var publishesFloatingChrome = false
    @State private var commentFullscreenPictureURL: URL?

    init(item: BiliDynamicItem, credential: BilibiliCredential?) {
        _model = StateObject(wrappedValue: DynamicDetailModel(item: item, credential: credential))
    }

    private var dynamicChromeInfo: VideoDetailChromeInfo {
        VideoDetailChromeInfo(
            title: "",
            viewCount: 0,
            danmakuCount: 0,
            publishTime: model.item.publishDate,
            onlineCount: 0,
            webURL: URL(string: model.referer),
            authorFaceURL: model.item.authorFaceURL,
            authorName: model.item.authorName.ifEmpty("用户"),
            authorLevel: model.item.authorLevel
        )
    }

    var body: some View {
        GeometryReader { geometry in
            let topInset = AppLayout.videoDetailPlayerTopInset(chromeHeight: chromeHeight)
            let contentHeight = max(0, geometry.size.height - topInset - 24)
            let leftWidth = geometry.size.width * 0.62
            let rightWidth = geometry.size.width * 0.34

            HStack(alignment: .top, spacing: AppLayout.videoDetailSectionSpacing) {
                MacOverlayScrollView(usesOverlayScrollers: false, clipsContent: true) {
                    dynamicBodyCard
                }
                .frame(width: leftWidth, height: contentHeight, alignment: .topLeading)

                commentsCard
                    .frame(width: rightWidth, height: contentHeight, alignment: .topLeading)
            }
            .padding(.leading, AppLayout.videoDetailLeadingInset)
            .padding(.trailing, AppLayout.videoDetailTrailingInset)
            .padding(.top, topInset)
            .padding(.bottom, 24)
            .frame(width: geometry.size.width, alignment: .topLeading)
        }
        .background(AppLayout.videoDetailPageBackground)
        .navigationBarBackButtonHidden(true)
        .task { await model.load() }
        .onAppear {
            publishesFloatingChrome = true
            appModel.presentVideoFloatingChrome(dynamicChromeInfo)
            MediaPlaybackCoordinator.shared.notifyObscuringPageVisible()
        }
        .onDisappear {
            publishesFloatingChrome = false
            appModel.resignVideoFloatingChrome()
            MediaPlaybackCoordinator.shared.notifyObscuringPageHidden()
        }
        .commentImageFullscreenOverlay(imageURL: $commentFullscreenPictureURL)
    }

    private var dynamicBodyCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !model.item.text.isEmpty {
                BiliCommentText(
                    text: model.item.text,
                    emoticons: model.item.emoticons,
                    fontSize: 17
                )
            }

            if let origin = model.item.origin {
                dynamicOriginBlock(origin)
            }

            if !model.item.imageURLs.isEmpty {
                dynamicImageGrid(model.item.imageURLs)
            }

            if let ip = model.item.ipLocation, !ip.isEmpty {
                Text("IP属地：\(ip)")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .videoDetailCard()
    }

    @ViewBuilder
    private func dynamicOriginBlock(_ origin: BiliDynamicOrigin) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !origin.authorName.isEmpty {
                Text("@\(origin.authorName)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            if !origin.text.isEmpty {
                BiliCommentText(text: origin.text, emoticons: origin.emoticons, fontSize: 16)
            }
            if !origin.imageURLs.isEmpty {
                dynamicImageGrid(origin.imageURLs)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private func dynamicImageGrid(_ urls: [URL]) -> some View {
        let columns = urls.count == 1 ? 1 : 2
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns),
            spacing: 6
        ) {
            ForEach(urls, id: \.absoluteString) { url in
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        Color.secondary.opacity(0.08)
                    }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(urls.count == 1 ? 16 / 9 : 1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private var commentsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("评论 \(model.commentCountLabel)")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                BiliCommentSortToggle(sort: model.commentSort) {
                    Task { await model.toggleCommentSort() }
                }
            }
            .padding(.horizontal, AppLayout.videoDetailCardPadding)
            .padding(.top, AppLayout.videoDetailCardPadding)
            .padding(.bottom, 12)

            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    MacOverlayScrollView(usesOverlayScrollers: false, clipsContent: true) {
                        Color.clear
                            .frame(height: 0)
                            .id(DynamicCommentsScrollAnchor.top)

                        DynamicCommentsPanel(
                            model: model,
                            contentMinHeight: geometry.size.height,
                            onPictureSelect: { commentFullscreenPictureURL = $0 }
                        )
                        .padding(.horizontal, AppLayout.videoDetailCardPadding)
                        .padding(.bottom, AppLayout.videoDetailCardPadding)
                    }
                    .onChange(of: model.commentsScrollToTopToken) { _, _ in
                        proxy.scrollTo(DynamicCommentsScrollAnchor.top, anchor: .top)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .videoDetailCard(padding: 0)
    }
}

private enum DynamicCommentsScrollAnchor {
    static let top = "dynamic-comments-scroll-top"
}

private struct DynamicCommentsPanel: View {
    @ObservedObject var model: DynamicDetailModel
    var contentMinHeight: CGFloat = 0
    var onPictureSelect: (URL) -> Void = { _ in }

    var body: some View {
        Group {
            if !model.canLoadComments {
                centeredPlaceholder {
                    ContentUnavailableView("该动态暂不支持评论", systemImage: "bubble.left")
                }
            } else {
                switch panelState {
                case .notLoaded:
                    centeredPlaceholder {
                        ContentUnavailableView("评论还未加载", systemImage: "bubble.left")
                    }
                case .loading:
                    centeredPlaceholder {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在加载评论")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                    }
                case .failed(let error):
                    centeredPlaceholder {
                        ContentUnavailableView(
                            "评论加载失败",
                            systemImage: "bubble.left.and.exclamationmark",
                            description: Text(error)
                        )
                    }
                case .empty:
                    centeredPlaceholder {
                        ContentUnavailableView("还没有评论", systemImage: "bubble.left")
                    }
                case .content:
                    commentList
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: usesCenteredPlaceholder ? contentMinHeight : 0, alignment: .topLeading)
    }

    private enum PanelState: Equatable {
        case notLoaded
        case loading
        case failed(String)
        case empty
        case content
    }

    private var panelState: PanelState {
        if model.commentsLoading, model.comments.isEmpty {
            return .loading
        }
        if !model.commentsHaveLoaded, model.comments.isEmpty, model.commentsError == nil {
            return .notLoaded
        }
        if let error = model.commentsError, model.comments.isEmpty {
            return .failed(error)
        }
        if model.comments.isEmpty {
            return .empty
        }
        return .content
    }

    private var usesCenteredPlaceholder: Bool {
        panelState != .content
    }

    private var commentList: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(model.comments) { comment in
                DynamicCommentRow(
                    comment: comment,
                    nested: false,
                    onPictureSelect: onPictureSelect
                )
                ForEach(comment.loadedReplies) { reply in
                    DynamicCommentRow(
                        comment: reply,
                        nested: true,
                        onPictureSelect: onPictureSelect
                    )
                }
                if comment.replyCount > Int64(comment.loadedReplies.count), !comment.repliesEnd {
                    Button {
                        Task { await model.loadMoreReplies(for: comment.id) }
                    } label: {
                        Text("查看 \(max(0, comment.replyCount - Int64(comment.loadedReplies.count))) 条回复")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(BiliTheme.blue)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 44)
                            .padding(.top, 2)
                            .padding(.bottom, 2)
                    }
                    .buttonStyle(.plain)
                }
            }

            if model.commentsLoadingMore && !model.comments.isEmpty {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("正在加载更多")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
            } else if !model.commentsEnd, !model.comments.isEmpty, !model.commentsLoading, !model.commentsLoadingMore {
                Color.clear
                    .frame(height: 1)
                    .onAppear {
                        Task { await model.loadComments(reset: false) }
                    }
            }
        }
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func centeredPlaceholder<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DynamicCommentRow: View {
    let comment: BiliCommentItem
    let nested: Bool
    let onPictureSelect: (URL) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if nested {
                Spacer().frame(width: 16)
            }

            AsyncImage(url: comment.authorFaceURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    Image(systemName: "person.fill")
                        .font(.system(size: nested ? 12 : 14))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: nested ? 28 : 34, height: nested ? 28 : 34)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(comment.authorName.ifEmpty("用户"))
                        .font(.system(size: nested ? 14 : 15, weight: .semibold))
                        .foregroundStyle(Color(red: 0.14, green: 0.14, blue: 0.16))
                        .lineLimit(1)

                    if comment.level > 0 {
                        BiliUserLevelIcon(level: comment.level, width: 22, height: 14)
                    }
                }

                if !comment.content.isEmpty {
                    BiliCommentText(
                        text: comment.content,
                        emoticons: comment.emoticons,
                        fontSize: nested ? 14 : 15
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !comment.pictures.isEmpty {
                    CommentPictureAttachments(pictures: comment.pictures, onSelect: onPictureSelect)
                }

                HStack(spacing: 10) {
                    let timeText = BiliCommentFormats.formatTime(comment.publishTime)
                    if !timeText.isEmpty {
                        Text(timeText)
                    }
                    if let ip = comment.ipLocation, !ip.isEmpty {
                        Text(ip)
                    }
                    Text("赞 \(comment.likeCount.compactCount)")
                }
                .font(.system(size: 12))
                .foregroundStyle(Color(red: 0.55, green: 0.55, blue: 0.58))
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, nested ? 4 : 6)
    }
}
