import Foundation

struct BiliFollowingFeedPage: Sendable {
    let videos: [BiliVideo]
    let nextOffset: String?
    let hasMore: Bool
}

struct BiliHomeRecommendPage: Sendable {
    let videos: [BiliVideo]
    let nextFreshIdx: Int
    let nextFetchRow: Int
    let lastShowList: String
    let hasMore: Bool
}

struct BiliFavoriteVideoPage: Sendable {
    let videos: [BiliVideo]
    let page: Int
    let hasMore: Bool
}

struct BiliHistoryCursor: Sendable {
    let max: Int64
    let viewAt: Int64
    let business: String
    let ps: Int

    var hasMore: Bool {
        ps > 0 && max > 0
    }
}

struct BiliHistoryPage: Sendable {
    let items: [BiliHistoryItem]
    let cursor: BiliHistoryCursor?

    var hasMore: Bool {
        cursor?.hasMore ?? false
    }
}

struct BiliVideo: Identifiable, Hashable, Sendable {
    let id: String
    let bvid: String
    let aid: Int64
    let title: String
    let coverURL: URL?
    let authorName: String
    let authorFaceURL: URL?
    let authorMid: Int64
    let viewCount: Int64
    let danmakuCount: Int64
    let likeCount: Int64
    let duration: Int
    let description: String
    let cid: Int64

    var webURL: URL? {
        URL(string: "https://www.bilibili.com/video/\(bvid)")
    }
}

struct BiliLiveRoom: Identifiable, Hashable, Sendable {
    let id: Int64
    let title: String
    let coverURL: URL?
    let userName: String
    let userFaceURL: URL?
    let online: Int64
    let areaName: String

    var webURL: URL? {
        URL(string: "https://live.bilibili.com/\(id)")
    }
}

struct BiliHotSearchItem: Identifiable, Hashable, Sendable {
    let keyword: String
    let showName: String
    let rank: Int

    var id: String { "\(rank)-\(keyword)" }
}

struct BiliSearchUser: Identifiable, Hashable, Sendable {
    let mid: Int64
    let name: String
    let faceURL: URL?
    let sign: String
    let fans: Int64
    let level: Int

    var id: Int64 { mid }
}

struct BiliSearchPage<Item: Sendable>: Sendable {
    let items: [Item]
    let page: Int
    let hasMore: Bool
}

struct BilibiliCredential: Codable, Hashable, Sendable {
    var dedeUserId: String
    var sessdata: String
    var biliJct: String
    var buvid3: String
    var buvid4: String

    nonisolated var cookieHeader: String {
        var parts = [
            "SESSDATA=\(sessdata)",
            "bili_jct=\(biliJct)",
            "DedeUserID=\(dedeUserId)",
            "DedeUserID__ckMd5="
        ]
        if !buvid3.isEmpty { parts.append("buvid3=\(buvid3)") }
        if !buvid4.isEmpty { parts.append("buvid4=\(buvid4)") }
        return parts.joined(separator: "; ")
    }
}

struct BiliAccount: Codable, Hashable, Sendable {
    var uid: String
    var name: String
    var faceURLString: String
    var credential: BilibiliCredential

    var faceURL: URL? {
        URL(string: faceURLString)
    }
}

struct BiliUserProfile: Hashable, Sendable {
    let mid: Int64
    let name: String
    let faceURL: URL?
    let sign: String
    let level: Int
    let following: Int64
    let follower: Int64
    let likes: Int64
    let coinCount: Int64
    let bcoinBalance: Double
    let videoCount: Int64
    let topPhotoURLs: [URL]
    let ipLocation: String?

    var displayTopPhotoURLs: [URL] {
        topPhotoURLs
    }
}

struct BiliAuthorRelation: Hashable, Sendable {
    var following = false
    var followerMe = false
}

enum BiliUserVideoSort: String, CaseIterable, Sendable {
    case latestPublish
    case mostPlayed

    nonisolated var orderValue: String {
        switch self {
        case .latestPublish: "pubdate"
        case .mostPlayed: "click"
        }
    }

    nonisolated var title: String {
        switch self {
        case .latestPublish: "最新发布"
        case .mostPlayed: "播放最多"
        }
    }
}

struct BiliUserVideoPage: Sendable {
    let videos: [BiliVideo]
    let hasMore: Bool
}

struct UserProfileRequest: Hashable, Sendable {
    let mid: Int64
    let seedName: String
    let seedFaceURL: URL?

    init(mid: Int64, seedName: String = "", seedFaceURL: URL? = nil) {
        self.mid = mid
        self.seedName = seedName
        self.seedFaceURL = seedFaceURL
    }
}

struct BiliHistoryItem: Identifiable, Hashable, Sendable {
    let id: String
    let kid: String
    let video: BiliVideo
    let viewedAt: Date?
    let progressSeconds: Int
    let durationSeconds: Int
}

struct VideoPlaybackRequest: Hashable, Sendable {
    let video: BiliVideo
    let progressSeconds: Int

    init(_ video: BiliVideo, progressSeconds: Int = 0) {
        self.video = video
        self.progressSeconds = max(0, progressSeconds)
    }
}

struct BiliVideoPage: Identifiable, Hashable, Sendable {
    let page: Int
    let cid: Int64
    let title: String
    let duration: Int

    var id: Int64 { cid }
}

struct BiliVideoDetail: Hashable, Sendable {
    let video: BiliVideo
    let publishTime: Date?
    let replyCount: Int64
    let coinCount: Int64
    let favoriteCount: Int64
    let shareCount: Int64
    let pages: [BiliVideoPage]
}

nonisolated struct BiliVideoRelation: Sendable, Equatable {
    var liked = false
    var favorited = false
    var coinCount = 0
}

nonisolated struct BiliVideoTripleResult: Sendable, Equatable {
    var liked = false
    var coined = false
    var favorited = false
}

struct BiliPlayStream: Hashable, Sendable {
    let videoURL: String
    let audioURL: String?
    let aid: Int64
    let cid: Int64

    nonisolated var isAVPlayerCompatible: Bool {
        Self.isAVPlayerNativeURL(videoURL)
    }

    nonisolated static func isAVPlayerNativeURL(_ url: String) -> Bool {
        let path = url.lowercased().split(separator: "?").first.map(String.init) ?? url.lowercased()
        if path.contains(".m4s") || path.contains(".mpd") || path.hasSuffix(".flv") {
            return false
        }
        if path.contains(".m3u8") || path.contains(".mp4") || path.contains(".mov") {
            return true
        }
        return !path.contains("m4s")
    }
}

enum BiliCommentSort: String, CaseIterable, Sendable {
    case hot
    case time

    nonisolated var title: String {
        switch self {
        case .hot: "按热度"
        case .time: "按时间"
        }
    }

    nonisolated var mode: Int {
        switch self {
        case .hot: 3
        case .time: 2
        }
    }
}

struct BiliCommentItem: Identifiable, Hashable, Sendable {
    let id: Int64
    let authorMid: Int64
    let authorName: String
    let authorFaceURL: URL?
    let level: Int
    let content: String
    let likeCount: Int64
    let replyCount: Int64
    let publishTime: Date?
    let ipLocation: String?
    let emoticons: [String: String]
    let replies: [BiliCommentItem]
    var loadedReplies: [BiliCommentItem]
    var repliesEnd: Bool

    nonisolated init(
        id: Int64,
        authorMid: Int64,
        authorName: String,
        authorFaceURL: URL?,
        level: Int,
        content: String,
        likeCount: Int64,
        replyCount: Int64,
        publishTime: Date?,
        ipLocation: String?,
        emoticons: [String: String] = [:],
        replies: [BiliCommentItem] = [],
        loadedReplies: [BiliCommentItem]? = nil,
        repliesEnd: Bool = false
    ) {
        self.id = id
        self.authorMid = authorMid
        self.authorName = authorName
        self.authorFaceURL = authorFaceURL
        self.level = level
        self.content = content
        self.likeCount = likeCount
        self.replyCount = replyCount
        self.publishTime = publishTime
        self.ipLocation = ipLocation
        self.emoticons = emoticons
        self.replies = replies
        self.loadedReplies = loadedReplies ?? replies
        self.repliesEnd = repliesEnd
    }
}

struct BiliCommentPage: Sendable {
    let comments: [BiliCommentItem]
    let nextCursor: String?
    let isEnd: Bool
    let totalCount: Int64
}

struct BiliCommentReplyPage: Sendable {
    let replies: [BiliCommentItem]
    let totalCount: Int64
    let page: Int
    let isEnd: Bool
}

nonisolated struct BiliDanmakuItem: Hashable, Sendable {
    let timeMs: Int64
    let mode: Int
    let fontSize: Int
    let colorArgb: Int
    let content: String

    nonisolated var id: Int {
        Int(timeMs ^ Int64(content.stableHashValue) ^ Int64(mode))
    }
}

enum BiliDanmakuMode: Int, Sendable {
    case scroll = 1
    case bottom = 4
    case top = 5
    case reverseScroll = 6

    static func from(_ value: Int) -> BiliDanmakuMode? {
        BiliDanmakuMode(rawValue: value)
    }
}

nonisolated enum DanmakuSpeedLevel: Int, CaseIterable, Sendable {
    case verySlow
    case slow
    case medium
    case fast
    case veryFast

    var label: String {
        switch self {
        case .verySlow: "极慢"
        case .slow: "较慢"
        case .medium: "适中"
        case .fast: "较快"
        case .veryFast: "极快"
        }
    }

    var durationMultiplier: Float {
        switch self {
        case .verySlow: 1.85
        case .slow: 1.35
        case .medium: 1
        case .fast: 0.72
        case .veryFast: 0.5
        }
    }

    static func fromIndex(_ index: Int) -> DanmakuSpeedLevel {
        let clamped = index.clamped(to: 0...(DanmakuSpeedLevel.allCases.count - 1))
        return DanmakuSpeedLevel.allCases[clamped]
    }
}

nonisolated struct DanmakuSettings: Equatable, Sendable {
    var displayAreaPercent: Int
    var opacityPercent: Int
    var fontSizePercent: Int
    var speedLevel: DanmakuSpeedLevel

    static let displayAreaOptions = [10, 25, 50, 75, 100]

    init(
        displayAreaPercent: Int = 100,
        opacityPercent: Int = 100,
        fontSizePercent: Int = 100,
        speedLevel: DanmakuSpeedLevel = .medium
    ) {
        self.displayAreaPercent = displayAreaPercent
        self.opacityPercent = opacityPercent
        self.fontSizePercent = fontSizePercent
        self.speedLevel = speedLevel
    }

    var displayAreaIndex: Int {
        Self.displayAreaOptions.firstIndex(of: displayAreaPercent) ?? (Self.displayAreaOptions.count - 1)
    }

    func withDisplayAreaIndex(_ index: Int) -> DanmakuSettings {
        let clamped = index.clamped(to: 0...(Self.displayAreaOptions.count - 1))
        var copy = self
        copy.displayAreaPercent = Self.displayAreaOptions[clamped]
        return copy
    }

    static func displayAreaLabel(_ percent: Int) -> String {
        "\(percent)%"
    }
}

private extension Int {
    nonisolated func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

extension Int64 {
    nonisolated var compactCount: String {
        if self >= 100_000_000 {
            return String(format: "%.1f亿", Double(self) / 100_000_000)
        }
        if self >= 10_000 {
            return String(format: "%.1f万", Double(self) / 10_000)
        }
        return "\(self)"
    }
}

extension String {
    nonisolated var stableHashValue: Int {
        var hasher = Hasher()
        hasher.combine(self)
        return hasher.finalize()
    }

    nonisolated func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}
