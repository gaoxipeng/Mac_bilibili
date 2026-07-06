import Foundation

struct CachedHomeFeed: Sendable {
    let videos: [BiliVideo]
    let freshIdx: Int
    let fetchRow: Int
    let lastShowList: String
    let hasMore: Bool
}

struct HomeFeedStore: Sendable {
    private let fileURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDirectory = support.appendingPathComponent("gaoxipeng.bilibili", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        fileURL = appDirectory.appendingPathComponent("home_feed_cache.json")
    }

    func read() -> CachedHomeFeed? {
        guard let data = try? Data(contentsOf: fileURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let videos = (root["videos"] as? [[String: Any]] ?? []).compactMap(decodeVideo)
        guard !videos.isEmpty || root["fresh_idx"] != nil else { return nil }

        return CachedHomeFeed(
            videos: videos,
            freshIdx: root["fresh_idx"] as? Int ?? 1,
            fetchRow: root["fetch_row"] as? Int ?? 1,
            lastShowList: root["last_show_list"] as? String ?? "",
            hasMore: root["has_more"] as? Bool ?? true
        )
    }

    func save(_ feed: CachedHomeFeed) {
        let videos = feed.videos.map(encodeVideo)
        let root: [String: Any] = [
            "fresh_idx": feed.freshIdx,
            "fetch_row": feed.fetchRow,
            "last_show_list": feed.lastShowList,
            "has_more": feed.hasMore,
            "videos": videos
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: []) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func encodeVideo(_ video: BiliVideo) -> [String: Any] {
        var payload: [String: Any] = [
            "bvid": video.bvid,
            "aid": video.aid,
            "title": video.title,
            "author_name": video.authorName,
            "author_mid": video.authorMid,
            "view_count": video.viewCount,
            "danmaku_count": video.danmakuCount,
            "like_count": video.likeCount,
            "duration_seconds": video.duration,
            "description": video.description,
            "cid": video.cid
        ]
        if let coverURL = video.coverURL?.absoluteString {
            payload["cover_url"] = coverURL
        }
        if let authorFaceURL = video.authorFaceURL?.absoluteString {
            payload["author_face"] = authorFaceURL
        }
        if let publishTime = video.publishTime {
            payload["publish_time"] = publishTime.timeIntervalSince1970
        }
        return payload
    }

    private func decodeVideo(_ item: [String: Any]) -> BiliVideo? {
        let bvid = item["bvid"] as? String ?? ""
        guard !bvid.isEmpty else { return nil }

        let coverRaw = item["cover_url"] as? String ?? ""
        let authorFaceRaw = item["author_face"] as? String ?? ""
        let publishTimestamp = item["publish_time"] as? TimeInterval

        return BiliVideo(
            id: bvid,
            bvid: bvid,
            aid: item["aid"] as? Int64 ?? 0,
            title: item["title"] as? String ?? "",
            coverURL: coverRaw.isEmpty ? nil : URL(string: coverRaw),
            authorName: item["author_name"] as? String ?? "",
            authorFaceURL: authorFaceRaw.isEmpty ? nil : URL(string: authorFaceRaw),
            authorMid: item["author_mid"] as? Int64 ?? 0,
            viewCount: item["view_count"] as? Int64 ?? 0,
            danmakuCount: item["danmaku_count"] as? Int64 ?? 0,
            likeCount: item["like_count"] as? Int64 ?? 0,
            duration: item["duration_seconds"] as? Int ?? 0,
            description: item["description"] as? String ?? "",
            cid: item["cid"] as? Int64 ?? 0,
            publishTime: publishTimestamp.map { Date(timeIntervalSince1970: $0) }
        )
    }
}
