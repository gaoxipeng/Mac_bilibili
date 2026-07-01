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
    private var emoteSize: CGFloat { fontSize + 2 }

    private var segments: [BiliCommentSegment] {
        BiliCommentSegmentBuilder.build(text: text, emoticons: emoticons)
    }

    private var layoutUnits: [[BiliCommentSegment]] {
        BiliCommentSegmentBuilder.layoutUnits(from: segments)
    }

    var body: some View {
        if emoticons.isEmpty, !segments.contains(where: {
            if case .mention = $0 { return true }
            return false
        }) {
            Text(text)
                .font(font)
                .lineSpacing(3)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        } else {
            FlowLayout(spacing: 0) {
                ForEach(Array(layoutUnits.enumerated()), id: \.offset) { _, unit in
                    HStack(spacing: 0) {
                        ForEach(Array(unit.enumerated()), id: \.offset) { _, segment in
                            segmentView(segment)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func segmentView(_ segment: BiliCommentSegment) -> some View {
        switch segment {
        case .text(let value):
            Text(value)
                .font(font)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case .emote(let url, _):
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit()
                default:
                    Color.clear
                }
            }
            .frame(width: emoteSize, height: emoteSize)
        case .mention(let value):
            Text(value)
                .font(font)
                .foregroundStyle(.secondary.opacity(0.55))
        }
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
