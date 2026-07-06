import Foundation

enum BiliImageURLResolver: Sendable {
    private static let hdslbSizeSuffixPattern = try? NSRegularExpression(
        pattern: #"@[^/?#]+(?=$|[?#])"#
    )

    static func stripSizeSuffix(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased().contains("hdslb.com") else { return trimmed }
        guard let pattern = hdslbSizeSuffixPattern else { return trimmed }

        var normalized = trimmed
        while let match = pattern.firstMatch(
            in: normalized,
            range: NSRange(normalized.startIndex..., in: normalized)
        ) {
            guard let range = Range(match.range, in: normalized) else { break }
            normalized.removeSubrange(range)
        }
        return normalized
    }

    static func url(from raw: String) -> URL? {
        guard !raw.isEmpty else { return nil }
        if raw.hasPrefix("//") {
            return URL(string: "https:\(raw)")
        }
        if raw.hasPrefix("http://") {
            return URL(string: raw.replacingOccurrences(of: "http://", with: "https://"))
        }
        return URL(string: raw)
    }

    static func remoteImageCandidates(primary: URL?, fallbackURLs: [URL] = []) -> [URL] {
        guard let primary else { return [] }
        var urls = [primary]
        for candidate in fallbackURLs where !urls.contains(candidate) {
            urls.append(candidate)
        }
        return urls
    }

    static func fullscreenCandidates(from url: URL) -> [URL] {
        let stripped = stripSizeSuffix(from: url.absoluteString)
        guard let strippedURL = URL(string: stripped) else { return [url] }
        if strippedURL == url {
            return [url]
        }
        return [strippedURL, url]
    }

    static func commentThumbnailFallbackURLs(for url: URL) -> [URL] {
        let raw = url.absoluteString
        let stripped = stripSizeSuffix(from: raw)
        var fallbacks: [URL] = []
        if raw != stripped, let strippedURL = URL(string: stripped) {
            fallbacks.append(strippedURL)
        }
        return fallbacks
    }
}
