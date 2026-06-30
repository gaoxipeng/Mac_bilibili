import Foundation

struct BiliFollowingFeedPage: Sendable {
    let videos: [BiliVideo]
    let nextOffset: String?
    let hasMore: Bool
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

struct BiliHotWord: Identifiable, Hashable, Sendable {
    let id = UUID()
    let keyword: String
    let icon: String?
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
}

struct BiliHistoryItem: Identifiable, Hashable, Sendable {
    let id: String
    let video: BiliVideo
    let viewedAt: Date?
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

struct BiliDanmakuItem: Hashable, Sendable {
    let timeMs: Int64
    let mode: Int
    let fontSize: Int
    let colorArgb: Int
    let content: String

    var id: Int {
        Int(timeMs ^ Int64(content.hashValue) ^ Int64(mode))
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

enum DanmakuSpeedLevel: Int, CaseIterable, Sendable {
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

struct DanmakuSettings: Equatable, Sendable {
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
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
