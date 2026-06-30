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
}

struct BiliCommentText: View {
    let text: String
    let emoticons: [String: String]

    private let emoteSize: CGFloat = 17

    private var segments: [BiliCommentSegment] {
        BiliCommentSegmentBuilder.build(text: text, emoticons: emoticons)
    }

    var body: some View {
        if emoticons.isEmpty, !segments.contains(where: {
            if case .mention = $0 { return true }
            return false
        }) {
            Text(text)
                .font(.body)
                .textSelection(.enabled)
        } else {
            FlowLayout(spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    switch segment {
                    case .text(let value):
                        Text(value)
                            .font(.body)
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
                            .font(.body)
                            .foregroundStyle(.secondary.opacity(0.55))
                    }
                }
            }
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
