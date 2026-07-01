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

    /// Groups segments so reply prefixes like `回复 @user:` stay on one line.
    static func layoutUnits(from segments: [BiliCommentSegment]) -> [[BiliCommentSegment]] {
        var units: [[BiliCommentSegment]] = []
        var index = 0

        while index < segments.count {
            if let replyUnit = takeReplyPrefixUnit(from: segments, at: index) {
                units.append(replyUnit.segments)
                index = replyUnit.nextIndex
                continue
            }
            if let mentionUnit = takeMentionColonUnit(from: segments, at: index) {
                units.append(mentionUnit.segments)
                index = mentionUnit.nextIndex
                continue
            }
            units.append([segments[index]])
            index += 1
        }

        return units
    }

    private static func takeReplyPrefixUnit(
        from segments: [BiliCommentSegment],
        at index: Int
    ) -> (segments: [BiliCommentSegment], nextIndex: Int)? {
        guard index + 2 < segments.count,
              case .text(let prefix) = segments[index],
              prefix == "回复 ",
              case .mention(let mention) = segments[index + 1],
              case .text(let tail) = segments[index + 2],
              let first = tail.first,
              first == ":" || first == "："
        else { return nil }

        let colon = String(first)
        let rest = String(tail.dropFirst())
        var unit: [BiliCommentSegment] = [.text(prefix), .mention(mention), .text(colon)]
        if !rest.isEmpty {
            unit.append(.text(rest))
        }
        return (unit, index + 3)
    }

    private static func takeMentionColonUnit(
        from segments: [BiliCommentSegment],
        at index: Int
    ) -> (segments: [BiliCommentSegment], nextIndex: Int)? {
        guard index + 1 < segments.count,
              case .mention(let mention) = segments[index],
              case .text(let tail) = segments[index + 1],
              let first = tail.first,
              first == ":" || first == "："
        else { return nil }

        let colon = String(first)
        let rest = String(tail.dropFirst())
        var unit: [BiliCommentSegment] = [.mention(mention), .text(colon)]
        if !rest.isEmpty {
            unit.append(.text(rest))
        }
        return (unit, index + 2)
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
        if needsRichText {
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

    var body: some View {
        CommentRichTextRepresentable(
            segments: segments,
            fontSize: fontSize,
            contentHeight: $contentHeight
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: contentHeight)
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
        layoutWidth = width
        let measuredHeight = height(forWidth: width)
        textView.frame = CGRect(x: 0, y: 0, width: width, height: measuredHeight)
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        let width = max(bounds.width, layoutWidth, 1)
        return NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: width))
    }

    func update(segments: [BiliCommentSegment], fontSize: CGFloat, imageLoader: CommentEmoteImageLoader) {
        self.segments = segments
        self.fontSize = fontSize
        self.imageLoader = imageLoader
        applyAttributedText(width: max(bounds.width, layoutWidth, 1))
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

    nonisolated static func metaLine(time: Date?, ipLocation: String?, likeCount: Int64) -> String {
        var parts: [String] = [formatTime(time)]
        if let ipLocation, !ipLocation.isEmpty {
            parts.append("来自\(ipLocation)")
        }
        parts.append("赞 \(likeCount.compactCount)")
        return parts.filter { !$0.isEmpty }.joined(separator: "  ")
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
