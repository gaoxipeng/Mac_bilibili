import Foundation

struct CachedProfileSpace: Sendable {
    let mid: Int64
    let profile: BiliUserProfile?
    let videos: [BiliVideo]
    let dynamics: [BiliDynamicItem]
    let videoSort: BiliUserVideoSort
    let videosHasMore: Bool
    let dynamicsHasMore: Bool
    let dynamicsOffset: String?
}

struct ProfileSpaceStore: Sendable {
    private let directoryURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDirectory = support.appendingPathComponent("gaoxipeng.bilibili", isDirectory: true)
        let profileDirectory = appDirectory.appendingPathComponent("profile_space", isDirectory: true)
        try? FileManager.default.createDirectory(at: profileDirectory, withIntermediateDirectories: true)
        directoryURL = profileDirectory
    }

    func read(mid: Int64) -> CachedProfileSpace? {
        let fileURL = fileURL(for: mid)
        guard let data = try? Data(contentsOf: fileURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cachedMid = int64(root["mid"]),
              cachedMid == mid else {
            return nil
        }

        let videos = (root["videos"] as? [[String: Any]] ?? []).compactMap(Self.decodeVideo)
        let dynamics = (root["dynamics"] as? [[String: Any]] ?? []).compactMap(Self.decodeDynamic)
        let sortRaw = root["video_sort"] as? String ?? BiliUserVideoSort.latestPublish.rawValue
        let videoSort = BiliUserVideoSort(rawValue: sortRaw) ?? .latestPublish

        guard root["profile"] != nil || !videos.isEmpty || !dynamics.isEmpty else { return nil }

        return CachedProfileSpace(
            mid: mid,
            profile: (root["profile"] as? [String: Any]).flatMap(Self.decodeProfile),
            videos: videos,
            dynamics: dynamics,
            videoSort: videoSort,
            videosHasMore: root["videos_has_more"] as? Bool ?? true,
            dynamicsHasMore: root["dynamics_has_more"] as? Bool ?? true,
            dynamicsOffset: root["dynamics_offset"] as? String
        )
    }

    func save(_ space: CachedProfileSpace) {
        var root: [String: Any] = [
            "mid": NSNumber(value: space.mid),
            "video_sort": space.videoSort.rawValue,
            "videos_has_more": space.videosHasMore,
            "dynamics_has_more": space.dynamicsHasMore,
            "videos": space.videos.map(Self.encodeVideo),
            "dynamics": space.dynamics.map(Self.encodeDynamic)
        ]
        if let profile = space.profile {
            root["profile"] = Self.encodeProfile(profile)
        }
        if let offset = space.dynamicsOffset {
            root["dynamics_offset"] = offset
        }

        guard JSONSerialization.isValidJSONObject(root),
              let data = try? JSONSerialization.data(withJSONObject: root, options: []) else {
            return
        }
        try? data.write(to: fileURL(for: space.mid), options: .atomic)
    }

    func clear(mid: Int64? = nil) {
        if let mid {
            try? FileManager.default.removeItem(at: fileURL(for: mid))
            return
        }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ) else { return }
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func fileURL(for mid: Int64) -> URL {
        directoryURL.appendingPathComponent("profile_\(mid).json")
    }

    private nonisolated static func encodeProfile(_ profile: BiliUserProfile) -> [String: Any] {
        var payload: [String: Any] = [
            "mid": NSNumber(value: profile.mid),
            "name": profile.name,
            "sign": profile.sign,
            "level": profile.level,
            "following": NSNumber(value: profile.following),
            "follower": NSNumber(value: profile.follower),
            "likes": NSNumber(value: profile.likes),
            "coin_count": NSNumber(value: profile.coinCount),
            "bcoin_balance": profile.bcoinBalance,
            "video_count": NSNumber(value: profile.videoCount)
        ]
        if let faceURL = profile.faceURL?.absoluteString {
            payload["face_url"] = faceURL
        }
        if let ipLocation = profile.ipLocation {
            payload["ip_location"] = ipLocation
        }
        return payload
    }

    private nonisolated static func decodeProfile(_ item: [String: Any]) -> BiliUserProfile? {
        guard let mid = int64(item["mid"]), mid > 0 else { return nil }
        let faceRaw = item["face_url"] as? String ?? ""
        return BiliUserProfile(
            mid: mid,
            name: item["name"] as? String ?? "",
            faceURL: faceRaw.isEmpty ? nil : URL(string: faceRaw),
            sign: item["sign"] as? String ?? "",
            level: item["level"] as? Int ?? 0,
            following: int64(item["following"]) ?? 0,
            follower: int64(item["follower"]) ?? 0,
            likes: int64(item["likes"]) ?? 0,
            coinCount: int64(item["coin_count"]) ?? 0,
            bcoinBalance: item["bcoin_balance"] as? Double ?? 0,
            videoCount: int64(item["video_count"]) ?? 0,
            ipLocation: item["ip_location"] as? String
        )
    }

    private nonisolated static func encodeVideo(_ video: BiliVideo) -> [String: Any] {
        var payload: [String: Any] = [
            "bvid": video.bvid,
            "aid": NSNumber(value: video.aid),
            "title": video.title,
            "author_name": video.authorName,
            "author_mid": NSNumber(value: video.authorMid),
            "view_count": NSNumber(value: video.viewCount),
            "danmaku_count": NSNumber(value: video.danmakuCount),
            "like_count": NSNumber(value: video.likeCount),
            "duration_seconds": video.duration,
            "description": video.description,
            "cid": NSNumber(value: video.cid)
        ]
        if video.id != video.bvid {
            payload["id"] = video.id
        }
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

    private nonisolated static func decodeVideo(_ item: [String: Any]) -> BiliVideo? {
        let bvid = item["bvid"] as? String ?? ""
        let id = (item["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? bvid
        guard !id.isEmpty || !bvid.isEmpty else { return nil }

        let coverRaw = item["cover_url"] as? String ?? ""
        let authorFaceRaw = item["author_face"] as? String ?? ""
        let publishTimestamp = item["publish_time"] as? TimeInterval

        return BiliVideo(
            id: id.isEmpty ? bvid : id,
            bvid: bvid,
            aid: int64(item["aid"]) ?? 0,
            title: item["title"] as? String ?? "",
            coverURL: coverRaw.isEmpty ? nil : URL(string: coverRaw),
            authorName: item["author_name"] as? String ?? "",
            authorFaceURL: authorFaceRaw.isEmpty ? nil : URL(string: authorFaceRaw),
            authorMid: int64(item["author_mid"]) ?? 0,
            viewCount: int64(item["view_count"]) ?? 0,
            danmakuCount: int64(item["danmaku_count"]) ?? 0,
            likeCount: int64(item["like_count"]) ?? 0,
            duration: item["duration_seconds"] as? Int ?? 0,
            description: item["description"] as? String ?? "",
            cid: int64(item["cid"]) ?? 0,
            publishTime: publishTimestamp.map { Date(timeIntervalSince1970: $0) }
        )
    }

    private nonisolated static func encodeDynamic(_ item: BiliDynamicItem) -> [String: Any] {
        var payload: [String: Any] = [
            "id": item.id,
            "text": item.text,
            "emoticons": item.emoticons,
            "publish_time_seconds": NSNumber(value: item.publishTimeSeconds),
            "image_urls": item.imageURLs.map(\.absoluteString),
            "author_mid": NSNumber(value: item.authorMid),
            "author_name": item.authorName,
            "author_level": item.authorLevel,
            "comment_oid": NSNumber(value: item.commentOid),
            "comment_type": item.commentType,
            "dynamic_type": item.dynamicType,
            "like_count": NSNumber(value: item.likeCount),
            "comment_count": NSNumber(value: item.commentCount),
            "repost_count": NSNumber(value: item.repostCount)
        ]
        if let authorFaceURL = item.authorFaceURL?.absoluteString {
            payload["author_face"] = authorFaceURL
        }
        if let ipLocation = item.ipLocation {
            payload["ip_location"] = ipLocation
        }
        if let video = item.video {
            payload["video"] = encodeVideo(video)
        }
        if let link = item.link {
            payload["link"] = encodeLink(link)
        }
        if let origin = item.origin {
            payload["origin"] = encodeOrigin(origin)
        }
        return payload
    }

    private nonisolated static func decodeDynamic(_ item: [String: Any]) -> BiliDynamicItem? {
        let id = item["id"] as? String ?? ""
        guard !id.isEmpty else { return nil }

        let authorFaceRaw = item["author_face"] as? String ?? ""
        let imageURLs = (item["image_urls"] as? [String] ?? []).compactMap(URL.init(string:))
        let emoticons = item["emoticons"] as? [String: String] ?? [:]

        return BiliDynamicItem(
            id: id,
            text: item["text"] as? String ?? "",
            emoticons: emoticons,
            publishTimeSeconds: int64(item["publish_time_seconds"]) ?? 0,
            video: (item["video"] as? [String: Any]).flatMap(decodeVideo),
            imageURLs: imageURLs,
            link: (item["link"] as? [String: Any]).flatMap(decodeLink),
            origin: (item["origin"] as? [String: Any]).flatMap(decodeOrigin),
            authorMid: int64(item["author_mid"]) ?? 0,
            authorName: item["author_name"] as? String ?? "",
            authorFaceURL: authorFaceRaw.isEmpty ? nil : URL(string: authorFaceRaw),
            authorLevel: item["author_level"] as? Int ?? 0,
            ipLocation: item["ip_location"] as? String,
            commentOid: int64(item["comment_oid"]) ?? 0,
            commentType: item["comment_type"] as? Int ?? 0,
            dynamicType: item["dynamic_type"] as? String ?? "",
            likeCount: int64(item["like_count"]) ?? 0,
            commentCount: int64(item["comment_count"]) ?? 0,
            repostCount: int64(item["repost_count"]) ?? 0
        )
    }

    private nonisolated static func encodeLink(_ link: BiliDynamicLink) -> [String: Any] {
        var payload: [String: Any] = [
            "title": link.title,
            "url": link.url,
            "desc": link.desc
        ]
        if let coverURL = link.coverURL?.absoluteString {
            payload["cover_url"] = coverURL
        }
        return payload
    }

    private nonisolated static func decodeLink(_ item: [String: Any]) -> BiliDynamicLink? {
        let url = item["url"] as? String ?? ""
        guard !url.isEmpty else { return nil }
        let coverRaw = item["cover_url"] as? String ?? ""
        return BiliDynamicLink(
            title: item["title"] as? String ?? "",
            url: url,
            coverURL: coverRaw.isEmpty ? nil : URL(string: coverRaw),
            desc: item["desc"] as? String ?? ""
        )
    }

    private nonisolated static func encodeOrigin(_ origin: BiliDynamicOrigin) -> [String: Any] {
        var payload: [String: Any] = [
            "author_name": origin.authorName,
            "text": origin.text,
            "emoticons": origin.emoticons,
            "image_urls": origin.imageURLs.map(\.absoluteString)
        ]
        if let video = origin.video {
            payload["video"] = encodeVideo(video)
        }
        if let link = origin.link {
            payload["link"] = encodeLink(link)
        }
        return payload
    }

    private nonisolated static func decodeOrigin(_ item: [String: Any]) -> BiliDynamicOrigin? {
        BiliDynamicOrigin(
            authorName: item["author_name"] as? String ?? "",
            text: item["text"] as? String ?? "",
            emoticons: item["emoticons"] as? [String: String] ?? [:],
            video: (item["video"] as? [String: Any]).flatMap(decodeVideo),
            imageURLs: (item["image_urls"] as? [String] ?? []).compactMap(URL.init(string:)),
            link: (item["link"] as? [String: Any]).flatMap(decodeLink)
        )
    }
}

private nonisolated func int64(_ value: Any?) -> Int64? {
    switch value {
    case let number as Int64:
        return number
    case let number as Int:
        return Int64(number)
    case let number as Double:
        return Int64(number)
    case let number as NSNumber:
        return number.int64Value
    case let text as String:
        return Int64(text)
    default:
        return nil
    }
}
