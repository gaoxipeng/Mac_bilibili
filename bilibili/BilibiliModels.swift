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

    nonisolated var hasMore: Bool {
        ps > 0
    }
}

struct BiliHistoryPage: Sendable {
    let items: [BiliHistoryItem]
    let cursor: BiliHistoryCursor?

    nonisolated var hasMore: Bool {
        cursor?.hasMore ?? false
    }
}

nonisolated struct BiliVideo: Identifiable, Hashable, Sendable {
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
    let publishTime: Date?

    var webURL: URL? {
        URL(string: "https://www.bilibili.com/video/\(bvid)")
    }

    nonisolated var pgcEpid: Int64 {
        if id.hasPrefix("pgc:") {
            let token = id.dropFirst(4).split(separator: "-", maxSplits: 1).first.map(String.init)
                ?? String(id.dropFirst(4))
            return Int64(token) ?? 0
        }
        if bvid.hasPrefix("pgc:") {
            let token = bvid.dropFirst(4).split(separator: "-", maxSplits: 1).first.map(String.init)
                ?? String(bvid.dropFirst(4))
            return Int64(token) ?? 0
        }
        return 0
    }

    nonisolated var isPgcPlayback: Bool {
        pgcEpid > 0
    }

    nonisolated func playbackID() -> String {
        if !bvid.isEmpty, cid > 0 {
            return "\(bvid):cid:\(cid)"
        }
        if !bvid.isEmpty {
            return bvid
        }
        if aid > 0 {
            return "av:\(aid)"
        }
        return id
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

nonisolated struct BiliSearchBangumi: Identifiable, Hashable, Sendable {
    let seasonId: Int64
    let mediaId: Int64
    let title: String
    let subtitle: String
    let coverURL: URL?
    let areas: String
    let styles: String
    let badge: String
    let categoryName: String
    let indexShow: String
    let webURL: URL?
    let firstEpid: Int64

    var id: Int64 { seasonId }

    var metadataLine: String {
        let parts = [styles, areas, indexShow].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !parts.isEmpty {
            return parts.joined(separator: " · ")
        }
        if !categoryName.isEmpty {
            return categoryName
        }
        return "影视"
    }

    nonisolated func withFirstEpid(_ epid: Int64) -> BiliSearchBangumi {
        BiliSearchBangumi(
            seasonId: seasonId,
            mediaId: mediaId,
            title: title,
            subtitle: subtitle,
            coverURL: coverURL,
            areas: areas,
            styles: styles,
            badge: badge,
            categoryName: categoryName,
            indexShow: indexShow,
            webURL: webURL,
            firstEpid: epid
        )
    }

    var canPlayInApp: Bool {
        firstEpid > 0
    }

    func playbackVideo() -> BiliVideo {
        let videoID = firstEpid > 0 ? "pgc:\(firstEpid)" : "pgc-season:\(seasonId)"
        return BiliVideo(
            id: videoID,
            bvid: "",
            aid: 0,
            title: title,
            coverURL: coverURL,
            authorName: metadataLine,
            authorFaceURL: nil,
            authorMid: 0,
            viewCount: 0,
            danmakuCount: 0,
            likeCount: 0,
            duration: 0,
            description: subtitle,
            cid: 0,
            publishTime: nil
        )
    }

    func playbackRequest() -> VideoPlaybackRequest {
        VideoPlaybackRequest(
            playbackVideo(),
            epid: firstEpid,
            refererURL: webURL
        )
    }

    static func categoryDisplayPriority(_ categoryName: String) -> Int {
        switch categoryName {
        case "番剧": 0
        case "国创": 1
        case "纪录片": 2
        case "电影": 3
        case "电视剧": 4
        case "综艺": 5
        case "影视": 6
        default: 99
        }
    }

    nonisolated static func sortedForDisplay(_ items: [BiliSearchBangumi]) -> [BiliSearchBangumi] {
        items.enumerated().sorted { lhs, rhs in
            let leftPriority = categoryDisplayPriority(lhs.element.categoryName)
            let rightPriority = categoryDisplayPriority(rhs.element.categoryName)
            if leftPriority != rightPriority {
                return leftPriority < rightPriority
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    static func availableCategories(in items: [BiliSearchBangumi]) -> [String] {
        let categories = Set(items.map(\.categoryName).filter { !$0.isEmpty })
        return categories.sorted {
            categoryDisplayPriority($0) < categoryDisplayPriority($1)
        }
    }
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
    var dedeUserIDCkMd5: String = ""
    var sid: String = ""
    var accessKey: String = ""
    var refreshToken: String = ""

    enum CodingKeys: String, CodingKey {
        case dedeUserId
        case sessdata
        case biliJct
        case buvid3
        case buvid4
        case dedeUserIDCkMd5
        case sid
        case accessKey
        case refreshToken
    }

    init(
        dedeUserId: String,
        sessdata: String,
        biliJct: String,
        buvid3: String,
        buvid4: String,
        dedeUserIDCkMd5: String = "",
        sid: String = "",
        accessKey: String = "",
        refreshToken: String = ""
    ) {
        self.dedeUserId = dedeUserId
        self.sessdata = sessdata
        self.biliJct = biliJct
        self.buvid3 = buvid3
        self.buvid4 = buvid4
        self.dedeUserIDCkMd5 = dedeUserIDCkMd5
        self.sid = sid
        self.accessKey = accessKey
        self.refreshToken = refreshToken
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dedeUserId = try container.decode(String.self, forKey: .dedeUserId)
        sessdata = try container.decode(String.self, forKey: .sessdata)
        biliJct = try container.decodeIfPresent(String.self, forKey: .biliJct) ?? ""
        buvid3 = try container.decodeIfPresent(String.self, forKey: .buvid3) ?? ""
        buvid4 = try container.decodeIfPresent(String.self, forKey: .buvid4) ?? ""
        dedeUserIDCkMd5 = try container.decodeIfPresent(String.self, forKey: .dedeUserIDCkMd5) ?? ""
        sid = try container.decodeIfPresent(String.self, forKey: .sid) ?? ""
        accessKey = try container.decodeIfPresent(String.self, forKey: .accessKey) ?? ""
        refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken) ?? ""
    }

    nonisolated var cookieHeader: String {
        var parts = [
            "SESSDATA=\(sessdata)",
            "bili_jct=\(biliJct)",
            "DedeUserID=\(dedeUserId)",
            "DedeUserID__ckMd5=\(dedeUserIDCkMd5)"
        ]
        if !sid.isEmpty { parts.append("sid=\(sid)") }
        if !buvid3.isEmpty { parts.append("buvid3=\(buvid3)") }
        if !buvid4.isEmpty { parts.append("buvid4=\(buvid4)") }
        return parts.joined(separator: "; ")
    }

    nonisolated var hasLoginSession: Bool {
        !sessdata.isEmpty && !dedeUserId.isEmpty
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
    let ipLocation: String?

    nonisolated func withIpLocation(_ ipLocation: String?) -> BiliUserProfile {
        BiliUserProfile(
            mid: mid,
            name: name,
            faceURL: faceURL,
            sign: sign,
            level: level,
            following: following,
            follower: follower,
            likes: likes,
            coinCount: coinCount,
            bcoinBalance: bcoinBalance,
            videoCount: videoCount,
            ipLocation: ipLocation
        )
    }
}

struct BiliAuthorRelation: Hashable, Sendable {
    var following = false
    var followerMe = false
}

struct BiliUserCardSnapshot: Sendable, Equatable {
    let sign: String
    let level: Int
    let followerCount: Int64
    var relation: BiliAuthorRelation
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
}

enum BiliUserRelationTab: String, Hashable, Sendable, CaseIterable, Identifiable {
    case following
    case followers

    var id: String { rawValue }

    var title: String {
        switch self {
        case .following: "关注"
        case .followers: "粉丝"
        }
    }
}

struct UserRelationListRequest: Hashable, Sendable {
    let hostMid: Int64
    let hostName: String
    let hostFaceURL: URL?
    let hostSign: String
    let initialTab: BiliUserRelationTab
}

struct BiliRelationUser: Identifiable, Hashable, Sendable {
    let mid: Int64
    let name: String
    let faceURL: URL?
    let sign: String
    var relation: BiliAuthorRelation
    let fanCount: Int64
    let ipLocation: String?

    var id: Int64 { mid }
}

struct BiliRelationUserPage: Sendable {
    let users: [BiliRelationUser]
    let hasMore: Bool
    let total: Int64
    let errorMessage: String?
}

nonisolated struct BiliDynamicLink: Hashable, Sendable {
    let title: String
    let url: String
    let coverURL: URL?
    let desc: String
}

struct BiliDynamicOrigin: Hashable, Sendable {
    let authorName: String
    let text: String
    let emoticons: [String: String]
    let video: BiliVideo?
    let imageURLs: [URL]
    let link: BiliDynamicLink?
}

struct BiliDynamicItem: Identifiable, Hashable, Sendable {
    let id: String
    let text: String
    let emoticons: [String: String]
    let publishTimeSeconds: Int64
    let video: BiliVideo?
    let imageURLs: [URL]
    let link: BiliDynamicLink?
    let origin: BiliDynamicOrigin?
    let authorMid: Int64
    let authorName: String
    let authorFaceURL: URL?
    let authorLevel: Int
    let ipLocation: String?
    let commentOid: Int64
    let commentType: Int
    let dynamicType: String
    let likeCount: Int64
    let commentCount: Int64
    let repostCount: Int64

    var canOpenDetail: Bool {
        commentOid > 0 && commentType > 0 && video == nil
    }

    var publishDate: Date? {
        publishTimeSeconds > 0 ? Date(timeIntervalSince1970: TimeInterval(publishTimeSeconds)) : nil
    }

    nonisolated func withIpLocation(_ ipLocation: String?) -> BiliDynamicItem {
        BiliDynamicItem(
            id: id,
            text: text,
            emoticons: emoticons,
            publishTimeSeconds: publishTimeSeconds,
            video: video,
            imageURLs: imageURLs,
            link: link,
            origin: origin,
            authorMid: authorMid,
            authorName: authorName,
            authorFaceURL: authorFaceURL,
            authorLevel: authorLevel,
            ipLocation: ipLocation,
            commentOid: commentOid,
            commentType: commentType,
            dynamicType: dynamicType,
            likeCount: likeCount,
            commentCount: commentCount,
            repostCount: repostCount
        )
    }
}

struct BiliDynamicFeedPage: Sendable {
    let items: [BiliDynamicItem]
    let nextOffset: String?
    let hasMore: Bool
}

struct DynamicDetailRequest: Hashable, Sendable {
    let item: BiliDynamicItem
}

struct BiliHistoryItem: Identifiable, Hashable, Sendable {
    let id: String
    let kid: String
    let business: BiliHistoryBusiness
    let video: BiliVideo
    let viewedAt: Date?
    let progressSeconds: Int
    let durationSeconds: Int
    let epid: Int64
    let webURI: URL?
    let badge: String

    /// Stable identity supplied by the cloud history record.
    var listIdentity: String { kid.isEmpty ? id : kid }
}

enum BiliHistoryBusiness: String, Sendable, Hashable {
    case archive
    case pgc
    case unknown
}

nonisolated struct VideoPlaybackRequest: Hashable, Sendable {
    let video: BiliVideo
    let progressSeconds: Int
    let epid: Int64
    let refererURL: URL?

    nonisolated init(
        _ video: BiliVideo,
        progressSeconds: Int = 0,
        epid: Int64 = 0,
        refererURL: URL? = nil
    ) {
        self.video = video
        self.progressSeconds = max(0, progressSeconds)
        self.epid = max(0, epid)
        self.refererURL = refererURL
    }
}

nonisolated struct BiliVideoPage: Identifiable, Hashable, Sendable {
    let page: Int
    let cid: Int64
    let title: String
    let duration: Int
    let epid: Int64
    let bvid: String

    nonisolated init(
        page: Int,
        cid: Int64,
        title: String,
        duration: Int,
        epid: Int64 = 0,
        bvid: String = ""
    ) {
        self.page = page
        self.cid = cid
        self.title = title
        self.duration = duration
        self.epid = epid
        self.bvid = bvid
    }

    var id: String {
        if epid > 0 { return "ep:\(epid)" }
        if !bvid.isEmpty { return "bv:\(bvid)" }
        return "cid:\(cid)"
    }
}

nonisolated struct BiliPGCEpisodeContext: Sendable {
    let epid: Int64
    let seasonId: Int64
    let seasonTitle: String
    let episodeTitle: String
    let longTitle: String
    let aid: Int64
    let bvid: String
    let cid: Int64
    let coverURL: URL?
    let duration: Int
    let evaluate: String
    let styles: String
    let areas: String
    let pages: [BiliVideoPage]
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
    let videoFallbackURLs: [String]
    let audioURL: String?
    let aid: Int64
    let cid: Int64
    let lastPlayTimeMilliseconds: Int64
    let lastPlayCID: Int64

    nonisolated init(
        videoURL: String,
        videoFallbackURLs: [String] = [],
        audioURL: String?,
        aid: Int64,
        cid: Int64,
        lastPlayTimeMilliseconds: Int64 = 0,
        lastPlayCID: Int64 = 0
    ) {
        self.videoURL = videoURL
        self.videoFallbackURLs = videoFallbackURLs.filter { !$0.isEmpty && $0 != videoURL }
        self.audioURL = audioURL
        self.aid = aid
        self.cid = cid
        self.lastPlayTimeMilliseconds = max(0, lastPlayTimeMilliseconds)
        self.lastPlayCID = max(0, lastPlayCID)
    }

    nonisolated func resumeSeconds(for targetCID: Int64, durationSeconds: Int) -> Int {
        guard targetCID > 0,
              lastPlayCID == targetCID,
              lastPlayTimeMilliseconds > 0 else { return 0 }
        let seconds = Int(lastPlayTimeMilliseconds / 1_000)
        guard seconds > 0 else { return 0 }
        guard durationSeconds <= 0 || seconds < durationSeconds else { return 0 }
        return seconds
    }

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

nonisolated struct BiliVideoShot: Hashable, Sendable {
    let images: [URL]
    let indexSeconds: [Int]
    let tileColumns: Int
    let tileRows: Int
    let tileWidth: Int
    let tileHeight: Int

    var tilesPerImage: Int { tileColumns * tileRows }
    var totalTiles: Int { images.count * tilesPerImage }

    func tile(at seconds: Double, duration: Double) -> BiliVideoShotTile? {
        guard !images.isEmpty, totalTiles > 0 else { return nil }
        let thumbnailIndex: Int
        if !indexSeconds.isEmpty {
            let second = max(0, Int(seconds.rounded(.down)))
            let indexedFrame = indexSeconds.lastIndex(where: { $0 <= second }) ?? 0
            // Some videos expose one or more trailing timestamps without a
            // matching sprite tile. Clamp them to the last real frame so the
            // latter half/end of the timeline still has a preview.
            thumbnailIndex = min(totalTiles - 1, max(0, indexedFrame))
        } else if duration > 0 {
            thumbnailIndex = min(totalTiles - 1, max(0, Int((seconds / duration * Double(totalTiles)).rounded())))
        } else {
            thumbnailIndex = 0
        }
        let imageIndex = thumbnailIndex / tilesPerImage
        let tileIndex = thumbnailIndex % tilesPerImage
        guard images.indices.contains(imageIndex) else { return nil }
        return BiliVideoShotTile(
            imageURL: images[imageIndex],
            column: tileIndex % tileColumns,
            row: tileIndex / tileColumns
        )
    }
}

nonisolated struct BiliVideoShotTile: Hashable, Sendable {
    let imageURL: URL
    let column: Int
    let row: Int
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

struct BiliCommentPicture: Hashable, Sendable {
    let url: URL
    let width: Int
    let height: Int

    var aspectRatio: CGFloat {
        guard width > 0, height > 0 else { return 1 }
        return CGFloat(width) / CGFloat(height)
    }

    func thumbnailSize(maxWidth: CGFloat = 168, maxHeight: CGFloat = 126) -> CGSize {
        guard width > 0, height > 0 else {
            return CGSize(width: min(maxWidth, 120), height: min(maxWidth, 120))
        }
        var fittedWidth = min(maxWidth, CGFloat(width))
        var fittedHeight = fittedWidth / aspectRatio
        if fittedHeight > maxHeight {
            fittedHeight = maxHeight
            fittedWidth = fittedHeight * aspectRatio
        }
        return CGSize(width: max(1, fittedWidth), height: max(1, fittedHeight))
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
    let pictures: [BiliCommentPicture]
    let replies: [BiliCommentItem]
    var loadedReplies: [BiliCommentItem]
    var repliesEnd: Bool
    let isPinned: Bool

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
        pictures: [BiliCommentPicture] = [],
        replies: [BiliCommentItem] = [],
        loadedReplies: [BiliCommentItem]? = nil,
        repliesEnd: Bool = false,
        isPinned: Bool = false
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
        self.pictures = pictures
        self.replies = replies
        self.loadedReplies = loadedReplies ?? replies
        self.repliesEnd = repliesEnd
        self.isPinned = isPinned
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
