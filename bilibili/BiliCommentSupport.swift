import AppKit
import Foundation
import SwiftUI

enum BiliCommentSegment: Hashable {
    case text(String)
    case emote(URL, phrase: String)
    case mention(String)
}

enum BiliCommentSegmentBuilder {
    private static let mentionRegex = /@[^ @:：\n]+/

    static func build(text: String, emoticons: [String: String]) -> [BiliCommentSegment] {
        guard !text.isEmpty else { return [] }

        let phrases = emoticons.keys.sorted { $0.count > $1.count }
        var segments: [BiliCommentSegment] = []
        var index = text.startIndex

        while index < text.endIndex {
            if let phrase = phrases.first(where: { text[index...].hasPrefix($0) }),
               let urlString = emoticons[phrase],
               let url = URL(string: urlString) {
                segments.append(.emote(url, phrase: phrase))
                index = text.index(index, offsetBy: phrase.count)
                continue
            }

            let suffix = text[index...]
            if let match = suffix.prefixMatch(of: mentionRegex) {
                segments.append(.mention(String(match.output)))
                index = match.range.upperBound
                continue
            }

            var end = text.index(after: index)
            while end < text.endIndex {
                let tail = text[end...]
                if phrases.contains(where: { tail.hasPrefix($0) }) { break }
                if tail.prefixMatch(of: mentionRegex) != nil { break }
                end = text.index(after: end)
            }
            segments.append(.text(String(text[index..<end])))
            index = end
        }

        return segments
    }

    static func isEmoteOnly(_ segments: [BiliCommentSegment]) -> Bool {
        var hasEmote = false
        for segment in segments {
            switch segment {
            case .emote:
                hasEmote = true
            case .text(let value), .mention(let value):
                if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return false
                }
            }
        }
        return hasEmote
    }

    static func emoteOnlyURLs(from segments: [BiliCommentSegment]) -> [URL]? {
        guard isEmoteOnly(segments) else { return nil }
        return segments.compactMap { segment in
            if case .emote(let url, _) = segment { return url }
            return nil
        }
    }
}

private struct CommentLineMetrics {
    let fontSize: CGFloat
    let lineSpacing: CGFloat = 3

    var font: NSFont { NSFont.systemFont(ofSize: fontSize) }
    var emoteSize: CGFloat { fontSize + 2 }

    var attachmentYOffset: CGFloat {
        (font.capHeight - emoteSize) / 2 - 1
    }

    var lineHeight: CGFloat {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing
        let sample = NSAttributedString(
            string: "A",
            attributes: [
                .font: font,
                .paragraphStyle: paragraphStyle,
            ]
        )
        let rect = sample.boundingRect(
            with: NSSize(width: 10_000, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return max(ceil(rect.height), ceil(font.ascender - font.descender + font.leading + lineSpacing))
    }

    /// Matches where emote tops land in `CommentRichTextView` when mixed with text.
    var emoteTopInset: CGFloat {
        let emoteTopAboveBaseline = emoteSize + attachmentYOffset
        return max(0, font.ascender - emoteTopAboveBaseline)
    }
}

struct BiliCommentText: View {
    let text: String
    let emoticons: [String: String]
    var fontSize: CGFloat = 15

    private var font: Font { .system(size: fontSize) }

    private var segments: [BiliCommentSegment] {
        BiliCommentSegmentBuilder.build(text: text, emoticons: emoticons)
    }

    private var emoteOnlyURLs: [URL]? {
        BiliCommentSegmentBuilder.emoteOnlyURLs(from: segments)
    }

    private var needsRichText: Bool {
        !emoticons.isEmpty || segments.contains { segment in
            switch segment {
            case .emote, .mention:
                return true
            case .text:
                return false
            }
        }
    }

    var body: some View {
        if let emoteOnlyURLs {
            CommentEmoteOnlyRow(urls: emoteOnlyURLs, fontSize: fontSize)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if needsRichText {
            CommentRichTextView(segments: segments, fontSize: fontSize)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(text)
                .font(font)
                .lineSpacing(3)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }
}

private struct CommentRichTextView: View {
    let segments: [BiliCommentSegment]
    let fontSize: CGFloat
    @State private var contentHeight: CGFloat = 1
    @State private var availableWidth: CGFloat = 1

    var body: some View {
        CommentRichTextRepresentable(
            segments: segments,
            fontSize: fontSize,
            contentHeight: $contentHeight
        )
        .id(widthIdentity)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: contentHeight)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .preference(key: CommentRichTextWidthKey.self, value: proxy.size.width)
            }
        }
        .onPreferenceChange(CommentRichTextWidthKey.self) { width in
            let clamped = max(width, 1)
            guard abs(availableWidth - clamped) > 0.5 else { return }
            availableWidth = clamped
        }
    }

    private var widthIdentity: Int {
        Int(availableWidth.rounded())
    }
}

private struct CommentRichTextWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 1

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct CommentEmoteOnlyRow: View {
    let urls: [URL]
    let fontSize: CGFloat

    private var metrics: CommentLineMetrics { CommentLineMetrics(fontSize: fontSize) }

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(urls, id: \.self) { url in
                CommentEmoteOnlyImage(url: url, size: metrics.emoteSize)
            }
        }
        .padding(.top, metrics.emoteTopInset)
        .frame(height: metrics.lineHeight, alignment: .topLeading)
    }
}

private struct CommentEmoteOnlyImage: View {
    let url: URL
    let size: CGFloat

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
            } else {
                Color.clear
                    .frame(width: size, height: size)
            }
        }
        .task(id: url) {
            image = await CommentEmoteOnlyImageLoader.shared.image(for: url, size: size)
        }
    }
}

@MainActor
private final class CommentEmoteOnlyImageLoader {
    static let shared = CommentEmoteOnlyImageLoader()

    private var cache: [URL: NSImage] = [:]
    private var inflight: Set<URL> = []

    private init() {}

    func image(for url: URL, size: CGFloat) async -> NSImage? {
        if let cached = cache[url] {
            return cached
        }
        guard !inflight.contains(url) else { return nil }
        inflight.insert(url)

        defer { inflight.remove(url) }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let source = NSImage(data: data) else { return nil }
            let side = max(size, 1)
            let scaled = NSImage(size: NSSize(width: side, height: side))
            scaled.lockFocus()
            source.draw(
                in: NSRect(x: 0, y: 0, width: side, height: side),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
            scaled.unlockFocus()
            cache[url] = scaled
            return scaled
        } catch {
            return nil
        }
    }
}

private struct CommentRichTextRepresentable: NSViewRepresentable {
    let segments: [BiliCommentSegment]
    let fontSize: CGFloat
    @Binding var contentHeight: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(contentHeight: $contentHeight)
    }

    func makeNSView(context: Context) -> CommentRichTextContainerView {
        let view = CommentRichTextContainerView()
        context.coordinator.container = view
        view.onLayoutInvalidated = { [weak view, weak coordinator = context.coordinator] in
            guard let view, let coordinator else { return }
            coordinator.syncHeight(from: view)
        }
        return view
    }

    func updateNSView(_ nsView: CommentRichTextContainerView, context: Context) {
        context.coordinator.container = nsView
        nsView.update(
            segments: segments,
            fontSize: fontSize,
            imageLoader: context.coordinator.imageLoader
        )
        context.coordinator.syncHeight(from: nsView)
    }

    @available(macOS 14.0, *)
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CommentRichTextContainerView, context: Context) -> CGSize? {
        let width = max(proposal.width ?? nsView.layoutWidth, 1)
        nsView.layoutWidth = width
        let height = nsView.height(forWidth: width)
        context.coordinator.publishHeight(height)
        return CGSize(width: width, height: height)
    }

    final class Coordinator {
        @Binding var contentHeight: CGFloat
        let imageLoader = CommentEmoteImageLoader()
        weak var container: CommentRichTextContainerView?

        init(contentHeight: Binding<CGFloat>) {
            _contentHeight = contentHeight
        }

        func syncHeight(from view: CommentRichTextContainerView) {
            let width = max(view.bounds.width, view.layoutWidth, 1)
            view.layoutWidth = width
            publishHeight(view.height(forWidth: width))
        }

        func publishHeight(_ height: CGFloat) {
            let clamped = max(ceil(height), 1)
            guard abs(contentHeight - clamped) > 0.5 else { return }
            DispatchQueue.main.async { [self] in
                contentHeight = clamped
            }
        }
    }
}

@MainActor
private final class CommentEmoteImageLoader {
    private var cache: [URL: NSImage] = [:]
    private var inflight: Set<URL> = []

    func cachedImage(for url: URL) -> NSImage? {
        cache[url]
    }

    func loadImage(url: URL, size: CGFloat, onLoaded: @escaping (NSImage) -> Void) {
        if let cached = cache[url] {
            onLoaded(cached)
            return
        }
        guard !inflight.contains(url) else { return }
        inflight.insert(url)

        Task {
            defer { inflight.remove(url) }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let image = NSImage(data: data) else { return }
                let side = max(size, 1)
                let scaled = NSImage(size: NSSize(width: side, height: side))
                scaled.lockFocus()
                image.draw(
                    in: NSRect(x: 0, y: 0, width: side, height: side),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1
                )
                scaled.unlockFocus()
                cache[url] = scaled
                onLoaded(scaled)
            } catch {
                return
            }
        }
    }
}

private final class CommentRichTextContainerView: NSView {
    private let textView = NSTextView(frame: .zero)
    private var segments: [BiliCommentSegment] = []
    private var fontSize: CGFloat = 15
    private weak var imageLoader: CommentEmoteImageLoader?
    var layoutWidth: CGFloat = 1
    private var renderedWidth: CGFloat = 1
    var onLayoutInvalidated: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width, .height]
        addSubview(textView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let width = max(bounds.width, layoutWidth, 1)
        let widthChanged = abs(renderedWidth - width) > 0.5
        layoutWidth = width
        if widthChanged {
            applyAttributedText(width: width)
            renderedWidth = width
        }
        let measuredHeight = height(forWidth: width)
        textView.frame = CGRect(x: 0, y: 0, width: width, height: measuredHeight)
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        let width = max(bounds.width, layoutWidth, 1)
        return NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: width))
    }

    func update(segments: [BiliCommentSegment], fontSize: CGFloat, imageLoader: CommentEmoteImageLoader) {
        let contentChanged = self.segments != segments || abs(self.fontSize - fontSize) > 0.5
        self.segments = segments
        self.fontSize = fontSize
        self.imageLoader = imageLoader
        let width = max(bounds.width, layoutWidth, 1)
        if contentChanged || abs(renderedWidth - width) > 0.5 {
            applyAttributedText(width: width)
            renderedWidth = width
        } else {
            textView.layoutManager?.invalidateLayout(
                forCharacterRange: NSRange(location: 0, length: textView.string.utf16.count),
                actualCharacterRange: nil
            )
            let measuredHeight = height(forWidth: width)
            textView.frame = CGRect(x: 0, y: 0, width: width, height: measuredHeight)
            invalidateIntrinsicContentSize()
            onLayoutInvalidated?()
        }
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            return ceil(fontSize * 1.4)
        }

        let safeWidth = max(width, 1)
        layoutWidth = safeWidth
        textContainer.containerSize = NSSize(width: safeWidth, height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        return max(ceil(layoutManager.usedRect(for: textContainer).height), ceil(fontSize * 1.2))
    }

    private func applyAttributedText(width: CGFloat) {
        let safeWidth = max(width, 1)
        layoutWidth = safeWidth
        renderedWidth = safeWidth
        textView.textContainer?.containerSize = NSSize(width: safeWidth, height: CGFloat.greatestFiniteMagnitude)
        textView.textStorage?.setAttributedString(
            makeAttributedString { [weak self] in
                guard let self else { return }
                self.applyAttributedText(width: safeWidth)
                self.onLayoutInvalidated?()
            }
        )
        let measuredHeight = height(forWidth: safeWidth)
        textView.frame = CGRect(x: 0, y: 0, width: safeWidth, height: measuredHeight)
        invalidateIntrinsicContentSize()
        onLayoutInvalidated?()
    }

    private func makeAttributedString(onImageLoaded: @escaping () -> Void) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: fontSize)
        let emoteSize = fontSize + 2
        let mentionColor = NSColor.secondaryLabelColor.withAlphaComponent(0.55)
        let result = NSMutableAttributedString()
        let isEmoteOnly = BiliCommentSegmentBuilder.isEmoteOnly(segments)

        if isEmoteOnly {
            result.append(
                NSAttributedString(
                    string: " ",
                    attributes: [
                        .font: font,
                        .foregroundColor: NSColor.clear,
                    ]
                )
            )
        }

        for segment in segments {
            switch segment {
            case .text(let value):
                result.append(
                    NSAttributedString(
                        string: value,
                        attributes: [
                            .font: font,
                            .foregroundColor: NSColor.labelColor,
                        ]
                    )
                )
            case .mention(let value):
                result.append(
                    NSAttributedString(
                        string: value,
                        attributes: [
                            .font: font,
                            .foregroundColor: mentionColor,
                        ]
                    )
                )
            case .emote(let url, _):
                let attachment = NSTextAttachment()
                attachment.bounds = CGRect(
                    x: 0,
                    y: (font.capHeight - emoteSize) / 2 - 1,
                    width: emoteSize,
                    height: emoteSize
                )
                if let image = imageLoader?.cachedImage(for: url) {
                    attachment.image = image
                } else {
                    imageLoader?.loadImage(url: url, size: emoteSize) { image in
                        attachment.image = image
                        onImageLoaded()
                    }
                }
                result.append(NSAttributedString(attachment: attachment))
            }
        }

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 3
        result.addAttribute(
            .paragraphStyle,
            value: paragraphStyle,
            range: NSRange(location: 0, length: result.length)
        )
        return result
    }
}

enum BiliCommentFormats {
    nonisolated static func formatTime(_ date: Date?) -> String {
        guard let date else { return "" }
        let delta = Date().timeIntervalSince(date)
        if delta < 60 { return "刚刚" }
        if delta < 3_600 { return "\(Int(delta / 60))分钟前" }
        if delta < 86_400 { return "\(Int(delta / 3_600))小时前" }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

struct BiliUpAuthorBadge: View {
    private let badgeHeight: CGFloat = 14

    var body: some View {
        Text("UP")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(BiliTheme.pink)
            .frame(width: 18, height: badgeHeight)
            .background(BiliTheme.pink.opacity(0.14), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
    }
}

struct BiliPinnedCommentBadge: View {
    private let badgeHeight: CGFloat = 14

    var body: some View {
        Text("置顶")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(BiliTheme.pink)
            .frame(height: badgeHeight)
            .padding(.horizontal, 4)
            .background(BiliTheme.pink.opacity(0.12), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
    }
}

struct BiliCommentSortToggle: View {
    let sort: BiliCommentSort
    let action: () -> Void

    @State private var isHovered = false

    private let labelColor = Color.primary.opacity(0.52)
    private var backgroundFill: Color {
        Color.primary.opacity(isHovered ? 0.11 : 0.05)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                BiliCommentSortLinesIcon(color: labelColor)
                Text(sort.title)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(labelColor)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background {
                Capsule()
                    .fill(backgroundFill)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.16)) {
                isHovered = hovering
            }
        }
    }
}

private struct BiliCommentSortLinesIcon: View {
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { _ in
                Capsule()
                    .fill(color)
                    .frame(width: 10, height: 1.2)
            }
        }
    }
}

struct CommentFullscreenPicture: Equatable {
    let url: URL
    let sourceFrame: CGRect
    let aspectRatio: CGFloat
}

private enum CommentPictureCoordinateSpace {
    static let name = "CommentPictureCoordinateSpace"
}

private struct CommentThumbnailFrameRegistryKey: PreferenceKey {
    static var defaultValue: [URL: CGRect] = [:]

    static func reduce(value: inout [URL: CGRect], nextValue: () -> [URL: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct CommentPictureAttachments: View {
    let pictures: [BiliCommentPicture]
    var onSelect: (CommentFullscreenPicture) -> Void

    var body: some View {
        if !pictures.isEmpty {
            FlowLayout(spacing: 8) {
                ForEach(pictures, id: \.self) { picture in
                    CommentPictureThumbnail(picture: picture, onTap: onSelect)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
        }
    }
}

private struct CommentPictureThumbnail: View {
    let picture: BiliCommentPicture
    let onTap: (CommentFullscreenPicture) -> Void

    @State private var isHovered = false
    @State private var sourceFrame: CGRect = .zero

    private var size: CGSize {
        picture.thumbnailSize()
    }

    var body: some View {
        RemoteCover(
            url: picture.url,
            fallbackURLs: BiliImageURLResolver.commentThumbnailFallbackURLs(for: picture.url),
            aspectRatio: picture.aspectRatio,
            width: size.width,
            height: size.height,
            appliesCornerClip: true,
            placeholderSystemImage: "photo"
        )
        .allowsHitTesting(false)
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.black.opacity(isHovered ? 0.14 : 0.08), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(isHovered ? 0.08 : 0.04), radius: isHovered ? 6 : 3, y: 2)
        .scaleEffect(isHovered ? 1.02 : 1)
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .background {
            GeometryReader { geometry in
                let frame = geometry.frame(in: .global)
                Color.clear
                    .preference(
                        key: CommentThumbnailFrameRegistryKey.self,
                        value: [picture.url: frame]
                    )
                    .task(id: frame) {
                        sourceFrame = frame
                    }
            }
        }
        .highPriorityGesture(TapGesture().onEnded { selectPicture() })
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.16), value: isHovered)
    }

    private func selectPicture() {
        onTap(
            CommentFullscreenPicture(
                url: picture.url,
                sourceFrame: sourceFrame == .zero
                    ? CGRect(origin: .zero, size: size)
                    : sourceFrame,
                aspectRatio: picture.aspectRatio
            )
        )
    }
}

private extension CommentFullscreenPicture {
    func resolvedSourceFrame(using registry: [URL: CGRect]) -> CommentFullscreenPicture {
        let latest = registry[url] ?? sourceFrame
        guard latest != .zero else { return self }
        return CommentFullscreenPicture(url: url, sourceFrame: latest, aspectRatio: aspectRatio)
    }
}

struct CommentImageFullscreenOverlay: ViewModifier {
    @Binding var selection: CommentFullscreenPicture?
    @State private var thumbnailFrames: [URL: CGRect] = [:]

    func body(content: Content) -> some View {
        ZStack {
            content
                .onPreferenceChange(CommentThumbnailFrameRegistryKey.self) { thumbnailFrames = $0 }

            CommentImageZoomPresenter(
                selection: $selection,
                thumbnailFrames: thumbnailFrames
            )
        }
        .coordinateSpace(name: CommentPictureCoordinateSpace.name)
    }
}

extension View {
    func commentImageFullscreenOverlay(selection: Binding<CommentFullscreenPicture?>) -> some View {
        modifier(CommentImageFullscreenOverlay(selection: selection))
    }
}

private struct CommentImageZoomPresenter: View {
    @Binding var selection: CommentFullscreenPicture?
    let thumbnailFrames: [URL: CGRect]
    @State private var displayed: CommentFullscreenPicture?
    @State private var progress: CGFloat = 0
    @State private var dismissTask: Task<Void, Never>?

    private let padding: CGFloat = 32
    private let presentAnimation = Animation.spring(response: 0.38, dampingFraction: 0.86)
    private let dismissAnimation = Animation.spring(response: 0.34, dampingFraction: 0.9)

    var body: some View {
        ZStack {
            if let displayed {
                GeometryReader { geometry in
                    let containerFrame = geometry.frame(in: .global)
                    let sourceFrame = localFrame(displayed.sourceFrame, in: containerFrame)
                    let destination = destinationFrame(
                        in: geometry.size,
                        aspectRatio: displayed.aspectRatio,
                        padding: padding
                    )
                    let frame = interpolatedFrame(
                        from: sourceFrame,
                        to: destination,
                        progress: progress
                    )
                    let cornerRadius = 8 * (1 - progress)

                    ZStack {
                        Color.black
                            .opacity(0.96 * Double(progress))
                            .ignoresSafeArea()
                            .contentShape(Rectangle())
                            .onTapGesture(perform: dismiss)

                        CommentFullscreenImage(url: displayed.url, contentMode: .fill)
                            .clipShape(
                                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            )
                            .frame(width: max(frame.width, 1), height: max(frame.height, 1))
                            .position(x: frame.midX, y: frame.midY)
                            .contentShape(Rectangle())
                            .onTapGesture(perform: dismiss)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .zIndex(1000)
                .background(CommentImageFullscreenEscapeHandler(onDismiss: dismiss))
                .onExitCommand(perform: dismiss)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(displayed != nil && progress > 0.01)
        .onChange(of: selection) { _, new in
            handleSelectionChange(new)
        }
        .task(id: selection?.url) {
            guard let selection else { return }
            handleSelectionChange(selection)
        }
    }

    private func handleSelectionChange(_ new: CommentFullscreenPicture?) {
        dismissTask?.cancel()
        guard let new else {
            if displayed != nil {
                dismiss()
            }
            return
        }
        present(new.resolvedSourceFrame(using: thumbnailFrames))
    }

    private func present(_ picture: CommentFullscreenPicture) {
        displayed = picture
        progress = 0
        withAnimation(presentAnimation) {
            progress = 1
        }
    }

    private func dismiss() {
        guard var current = displayed else {
            selection = nil
            return
        }
        guard progress > 0.01 else { return }

        current = current.resolvedSourceFrame(using: thumbnailFrames)
        displayed = current

        dismissTask?.cancel()
        withAnimation(dismissAnimation) {
            progress = 0
        }
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(340))
            guard !Task.isCancelled, progress == 0 else { return }
            selection = nil
            displayed = nil
        }
    }

    private func localFrame(_ globalFrame: CGRect, in containerFrame: CGRect) -> CGRect {
        CGRect(
            x: globalFrame.minX - containerFrame.minX,
            y: globalFrame.minY - containerFrame.minY,
            width: globalFrame.width,
            height: globalFrame.height
        )
    }

    private func destinationFrame(in containerSize: CGSize, aspectRatio: CGFloat, padding: CGFloat) -> CGRect {
        let availableWidth = max(containerSize.width - padding * 2, 1)
        let availableHeight = max(containerSize.height - padding * 2, 1)
        let safeAspect = max(aspectRatio, 0.01)

        var width = availableWidth
        var height = width / safeAspect
        if height > availableHeight {
            height = availableHeight
            width = height * safeAspect
        }

        return CGRect(
            x: (containerSize.width - width) / 2,
            y: (containerSize.height - height) / 2,
            width: width,
            height: height
        )
    }

    private func interpolatedFrame(from source: CGRect, to destination: CGRect, progress: CGFloat) -> CGRect {
        let clamped = min(max(progress, 0), 1)
        return CGRect(
            x: lerp(source.minX, destination.minX, clamped),
            y: lerp(source.minY, destination.minY, clamped),
            width: lerp(source.width, destination.width, clamped),
            height: lerp(source.height, destination.height, clamped)
        )
    }

    private func lerp(_ start: CGFloat, _ end: CGFloat, _ progress: CGFloat) -> CGFloat {
        start + (end - start) * progress
    }
}

private struct CommentFullscreenImage: View {
    let url: URL
    var contentMode: ContentMode = .fit
    @StateObject private var imageLoader = RemoteCoverImageLoader()

    var body: some View {
        Group {
            if let image = imageLoader.image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if imageLoader.failed {
                ContentUnavailableView("无法加载图片", systemImage: "photo")
                    .foregroundStyle(.white.opacity(0.86))
            } else {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }
        }
        .onAppear {
            let candidates = BiliImageURLResolver.fullscreenCandidates(from: url)
            imageLoader.primeFromMemoryCache(
                url: candidates.first ?? url,
                maxPixelLength: RemoteCoverImageLoader.fullscreenMaxPixelLength,
                pixelCap: RemoteCoverImageLoader.fullscreenMaxPixelLength
            )
        }
        .task(id: url.absoluteString) {
            let candidates = BiliImageURLResolver.fullscreenCandidates(from: url)
            imageLoader.load(
                url: candidates.first ?? url,
                fallbackURLs: Array(candidates.dropFirst()),
                maxPixelLength: RemoteCoverImageLoader.fullscreenMaxPixelLength,
                pixelCap: RemoteCoverImageLoader.fullscreenMaxPixelLength
            )
        }
    }
}

private struct CommentImageFullscreenEscapeHandler: NSViewRepresentable {
    let onDismiss: () -> Void

    func makeNSView(context: Context) -> CommentImageFullscreenEscapeView {
        let view = CommentImageFullscreenEscapeView()
        view.onDismiss = onDismiss
        return view
    }

    func updateNSView(_ nsView: CommentImageFullscreenEscapeView, context: Context) {
        nsView.onDismiss = onDismiss
    }
}

private final class CommentImageFullscreenEscapeView: NSView {
    var onDismiss: (() -> Void)?
    private var keyMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            installMonitorIfNeeded()
            window?.makeFirstResponder(self)
        } else {
            tearDownMonitor()
        }
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onDismiss?()
            return
        }
        super.keyDown(with: event)
    }

    private func installMonitorIfNeeded() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.onDismiss?()
            return nil
        }
    }

    private func tearDownMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }
}

private struct FlowLayout: Layout {
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
