import Foundation

enum JSONParser {
    nonisolated static func parseVideos(from object: Any, preferredArrayKeys: [String]) -> [BiliVideo] {
        let data = dictionary(object)["data"] as? [String: Any] ?? dictionary(object)
        let arrays = preferredArrayKeys.compactMap { data[$0] as? [[String: Any]] }
        let items = arrays.first(where: { !$0.isEmpty }) ?? findFirstArray(in: data)
        return items.compactMap(parseVideo)
    }

    nonisolated static func parseFollowingVideoFeed(from object: Any) -> BiliFollowingFeedPage {
        let data = dictionary(object)["data"] as? [String: Any] ?? dictionary(object)
        let items = data["items"] as? [[String: Any]] ?? []
        var seen = Set<String>()
        let videos = items.compactMap { item -> BiliVideo? in
            guard let video = parseDynamicVideoItem(item), seen.insert(video.bvid).inserted else {
                return nil
            }
            return video
        }
        let offsetRaw = string(data, "offset")
        let nextOffset = offsetRaw.isEmpty ? nil : offsetRaw
        let hasMore = (data["has_more"] as? Bool) ?? (nextOffset != nil && !videos.isEmpty)
        return BiliFollowingFeedPage(videos: videos, nextOffset: nextOffset, hasMore: hasMore)
    }

    nonisolated static func parseHotWords(from object: Any) -> [BiliHotWord] {
        let data = dictionary(object)["data"] as? [String: Any] ?? dictionary(object)
        let list = (data["list"] as? [[String: Any]]) ?? findFirstArray(in: data)
        return list.compactMap { item in
            let keyword = string(item, "keyword", "show_name", "word", "name")
            guard !keyword.isEmpty else { return nil }
            return BiliHotWord(keyword: keyword, icon: optionalString(item, "icon"))
        }
    }

    nonisolated static func parseLiveRooms(from object: Any) -> [BiliLiveRoom] {
        let data = dictionary(object)["data"] as? [String: Any] ?? dictionary(object)
        let list = (data["list"] as? [[String: Any]])
            ?? ((data["data"] as? [String: Any])?["list"] as? [[String: Any]])
            ?? findFirstArray(in: data)

        return list.compactMap { item in
            let roomId = int64(item, "roomid", "room_id", "roomId", "uid")
            guard roomId > 0 else { return nil }
            let title = string(item, "title")
            let cover = normalizedURL(string(item, "cover", "cover_from_user", "keyframe", "system_cover"))
            let face = normalizedURL(string(item, "face", "uface"))
            return BiliLiveRoom(
                id: roomId,
                title: title.isEmpty ? "直播间" : title,
                coverURL: cover,
                userName: string(item, "uname", "user_name", "name"),
                userFaceURL: face,
                online: int64(item, "online", "watched_show_num", "popularity_count"),
                areaName: string(item, "area_name", "parent_area_name")
            )
        }
    }

    nonisolated static func parseAccount(from object: Any, credential: BilibiliCredential) -> BiliAccount? {
        let data = dictionary(object)["data"] as? [String: Any] ?? dictionary(object)
        let uid = string(data, "mid").ifEmpty(credential.dedeUserId)
        guard !uid.isEmpty else { return nil }
        return BiliAccount(
            uid: uid,
            name: string(data, "uname", "name").ifEmpty("哔哩哔哩用户"),
            faceURLString: string(data, "face"),
            credential: credential
        )
    }

    nonisolated static func parseProfile(from object: Any, fallback account: BiliAccount?) -> BiliUserProfile? {
        let data = dictionary(object)["data"] as? [String: Any] ?? dictionary(object)
        let levelValue: Int = {
            if let levelInfo = data["level_info"] as? [String: Any] {
                return Int(int64(levelInfo, "current_level"))
            }
            return Int(int64(data, "level"))
        }()
        let wallet = data["wallet"] as? [String: Any]
        let mid = int64(data, "mid").ifZero(Int64(account?.uid ?? "") ?? 0)
        guard mid > 0 || account != nil else { return nil }
        return BiliUserProfile(
            mid: mid,
            name: string(data, "name", "uname").ifEmpty(account?.name ?? "哔哩哔哩用户"),
            faceURL: normalizedURL(string(data, "face").ifEmpty(account?.faceURLString ?? "")),
            sign: string(data, "sign"),
            level: levelValue,
            following: int64(data, "following"),
            follower: int64(data, "follower"),
            likes: int64(data, "likes"),
            coinCount: int64(data, "money"),
            bcoinBalance: double(wallet ?? data, "bcoin_balance")
        )
    }

    nonisolated static func parseWallet(from object: Any, profile: BiliUserProfile?) -> BiliUserProfile? {
        let data = dictionary(object)["data"] as? [String: Any] ?? dictionary(object)
        let wallet = data["wallet"] as? [String: Any]
        guard let profile else { return nil }
        return BiliUserProfile(
            mid: profile.mid,
            name: profile.name,
            faceURL: profile.faceURL,
            sign: profile.sign,
            level: profile.level,
            following: profile.following,
            follower: profile.follower,
            likes: profile.likes,
            coinCount: int64(data, "money").ifZero(profile.coinCount),
            bcoinBalance: double(wallet ?? data, "bcoin_balance")
        )
    }

    nonisolated static func parseHistory(from object: Any) -> [BiliHistoryItem] {
        let data = dictionary(object)["data"] as? [String: Any] ?? dictionary(object)
        let list = (data["list"] as? [[String: Any]]) ?? findFirstArray(in: data)
        return list.compactMap { item in
            let history = item["history"] as? [String: Any]
            let bvid = string(item, "bvid").ifEmpty(history.map { string($0, "bvid") } ?? "")
            guard !bvid.isEmpty else { return nil }
            let video = BiliVideo(
                id: bvid,
                bvid: bvid,
                aid: int64(item, "aid").ifZero(history.map { int64($0, "oid", "aid") } ?? 0),
                title: string(item, "title").htmlStripped,
                coverURL: normalizedURL(string(item, "cover", "pic")),
                authorName: string(item, "author_name", "name"),
                authorFaceURL: nil,
                authorMid: int64(item, "author_mid", "mid"),
                viewCount: int64(item, "view"),
                danmakuCount: int64(item, "danmaku"),
                likeCount: 0,
                duration: duration(from: item),
                description: string(item, "desc"),
                cid: int64(item, "cid")
            )
            let viewedAtSeconds = int64(item, "view_at")
            return BiliHistoryItem(
                id: "\(bvid)-\(viewedAtSeconds)",
                video: video,
                viewedAt: viewedAtSeconds > 0 ? Date(timeIntervalSince1970: TimeInterval(viewedAtSeconds)) : nil
            )
        }
    }

    nonisolated static func parseVideoDetail(from object: Any) -> BiliVideoDetail? {
        let data = dictionary(object)["data"] as? [String: Any] ?? dictionary(object)
        let rawPages = data["pages"] as? [[String: Any]] ?? []
        let pages = parseVideoPages(from: data["pages"])
        let firstCid = pages.first?.cid
            ?? rawPages.first.map { int64($0, "cid") }
            ?? int64(data, "cid")
        guard var video = parseVideo(data) else { return nil }
        if video.cid == 0, firstCid > 0 {
            video = BiliVideo(
                id: video.id,
                bvid: video.bvid,
                aid: video.aid,
                title: video.title,
                coverURL: video.coverURL,
                authorName: video.authorName,
                authorFaceURL: video.authorFaceURL,
                authorMid: video.authorMid,
                viewCount: video.viewCount,
                danmakuCount: video.danmakuCount,
                likeCount: video.likeCount,
                duration: video.duration,
                description: video.description,
                cid: firstCid
            )
        }
        let stat = data["stat"] as? [String: Any] ?? [:]
        let pubdate = int64(data, "pubdate")
        return BiliVideoDetail(
            video: video,
            publishTime: pubdate > 0 ? Date(timeIntervalSince1970: TimeInterval(pubdate)) : nil,
            replyCount: int64(stat, "reply"),
            coinCount: int64(stat, "coin"),
            favoriteCount: int64(stat, "favorite"),
            shareCount: int64(stat, "share"),
            pages: pages
        )
    }

    nonisolated static func parsePlayStream(from object: Any) -> BiliPlayStream? {
        let data = dictionary(object)["data"] as? [String: Any] ?? dictionary(object)

        if let durlStream = parseDurlStream(from: data), durlStream.isAVPlayerCompatible {
            return durlStream
        }

        if let dash = data["dash"] as? [String: Any],
           let videoURL = pickStreamURL(from: dash, type: "video") {
            let audioURL = pickStreamURL(from: dash, type: "audio")
            let dashStream = BiliPlayStream(videoURL: videoURL, audioURL: audioURL, aid: 0, cid: 0)
            if dashStream.isAVPlayerCompatible {
                return dashStream
            }
        }

        if let durlStream = parseDurlStream(from: data) {
            return durlStream
        }

        if let dash = data["dash"] as? [String: Any],
           let videoURL = pickStreamURL(from: dash, type: "video") {
            let audioURL = pickStreamURL(from: dash, type: "audio")
            return BiliPlayStream(videoURL: videoURL, audioURL: audioURL, aid: 0, cid: 0)
        }

        return nil
    }

    private nonisolated static func parseDurlStream(from data: [String: Any]) -> BiliPlayStream? {
        guard let durl = data["durl"] as? [[String: Any]], !durl.isEmpty else { return nil }
        let url = string(durl[0], "url")
        guard !url.isEmpty else { return nil }
        return BiliPlayStream(videoURL: url, audioURL: nil, aid: 0, cid: 0)
    }

    nonisolated static func parseCommentPage(from object: Any) -> BiliCommentPage {
        let data = dictionary(object)["data"] as? [String: Any] ?? dictionary(object)
        let cursor = data["cursor"] as? [String: Any]
        let replies = data["replies"] as? [[String: Any]] ?? []
        let comments = replies.compactMap { parseCommentItem($0, includeInlineReplies: true) }
        let paginationReply = parseCommentPaginationReply(cursor)
        let nextCursor = parseCommentNextCursor(cursor: cursor, paginationReply: paginationReply)
        let totalCount = int64(cursor ?? [:], "all_count").ifZero(
            int64((data["page"] as? [String: Any]) ?? [:], "acount")
        )
        let isEnd = resolveCommentPageIsEnd(
            cursor: cursor,
            nextCursor: nextCursor,
            pageCommentCount: comments.count,
            totalCount: totalCount
        )
        return BiliCommentPage(
            comments: comments,
            nextCursor: nextCursor,
            isEnd: isEnd,
            totalCount: totalCount
        )
    }

    nonisolated static func parseCommentReplyPage(from object: Any) -> BiliCommentReplyPage {
        let data = dictionary(object)["data"] as? [String: Any] ?? dictionary(object)
        let replies = data["replies"] as? [[String: Any]] ?? []
        let pageInfo = data["page"] as? [String: Any] ?? [:]
        let totalCount = int64(pageInfo, "count")
        let currentPage = Int(int64(pageInfo, "num")).ifZero(1)
        let pageSize = Int(int64(pageInfo, "size")).ifZero(20)
        let items = replies.compactMap { parseCommentItem($0, includeInlineReplies: false) }
        let isEnd = items.isEmpty || currentPage * pageSize >= Int(totalCount)
        return BiliCommentReplyPage(
            replies: items,
            totalCount: totalCount,
            page: currentPage,
            isEnd: isEnd
        )
    }

    private nonisolated static func parseVideoPages(from value: Any?) -> [BiliVideoPage] {
        guard let pages = value as? [[String: Any]], pages.count > 1 else { return [] }
        return pages.compactMap { page in
            let cid = int64(page, "cid")
            guard cid > 0 else { return nil }
            return BiliVideoPage(
                page: Int(int64(page, "page")).ifZero(1),
                cid: cid,
                title: string(page, "part"),
                duration: duration(from: page)
            )
        }
    }

    private nonisolated static func pickStreamURL(from dash: [String: Any], type: String) -> String? {
        guard let streams = dash[type] as? [[String: Any]], !streams.isEmpty else { return nil }
        let candidates = streams.flatMap { streamURLs(from: $0) }
        if let native = candidates.first(where: { BiliPlayStream.isAVPlayerNativeURL($0) }) {
            return native
        }
        return candidates.first
    }

    private nonisolated static func streamURLs(from stream: [String: Any]) -> [String] {
        var urls: [String] = []
        if let backups = stream["backup_url"] as? [String] {
            urls.append(contentsOf: backups.filter { !$0.isEmpty })
        }
        if let backups = stream["backupUrl"] as? [String] {
            urls.append(contentsOf: backups.filter { !$0.isEmpty })
        }
        let base = string(stream, "baseUrl", "base_url")
        if !base.isEmpty {
            urls.append(base)
        }
        return urls
    }

    private nonisolated static func parseCommentPaginationReply(_ cursor: [String: Any]?) -> [String: Any]? {
        guard let cursor else { return nil }
        if let reply = cursor["pagination_reply"] as? [String: Any] { return reply }
        if let raw = cursor["pagination_reply"] as? String,
           let data = raw.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }
        return nil
    }

    private nonisolated static func parseCommentNextCursor(cursor: [String: Any]?, paginationReply: [String: Any]?) -> String? {
        if let next = paginationReply?["next_offset"] as? String, !next.isEmpty { return next }
        if let nextObject = paginationReply?["next_offset"] as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: nextObject),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        let legacyNext = int64(cursor ?? [:], "next")
        guard legacyNext > 0 else { return nil }
        let mode = Int(int64(cursor ?? [:], "mode")).ifZero(3)
        let payload: [String: Any]
        switch mode {
        case 2:
            payload = ["type": 1, "direction": 1, "data": ["cursor": legacyNext]]
        case 3:
            payload = ["type": 3, "direction": 1, "Data": ["cursor": legacyNext]]
        default:
            payload = ["type": 1, "direction": 1, "data": ["cursor": legacyNext]]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    private nonisolated static func resolveCommentPageIsEnd(
        cursor: [String: Any]?,
        nextCursor: String?,
        pageCommentCount: Int,
        totalCount: Int64
    ) -> Bool {
        if let nextCursor, !nextCursor.isEmpty {
            if totalCount > 0, Int64(pageCommentCount) >= totalCount { return true }
            if cursor?["is_end"] as? Bool == true {
                if totalCount > 0, Int64(pageCommentCount) < totalCount { return false }
                return true
            }
            return false
        }
        if totalCount > 0, Int64(pageCommentCount) < totalCount { return false }
        if let isEnd = cursor?["is_end"] as? Bool { return isEnd }
        return pageCommentCount == 0
    }

    private nonisolated static func parseCommentItem(_ item: [String: Any], includeInlineReplies: Bool) -> BiliCommentItem? {
        guard let member = item["member"] as? [String: Any] else { return nil }
        let content = item["content"] as? [String: Any] ?? [:]
        let message = string(content, "message")
        let emoticons = parseEmoteMap(content)
        if message.isEmpty, emoticons.isEmpty, !includeInlineReplies { return nil }
        let nested = (item["replies"] as? [[String: Any]] ?? []).compactMap {
            parseCommentItem($0, includeInlineReplies: false)
        }
        let ctime = int64(item, "ctime")
        return BiliCommentItem(
            id: int64(item, "rpid"),
            authorMid: int64(member, "mid"),
            authorName: string(member, "uname"),
            authorFaceURL: normalizedURL(string(member, "avatar")),
            level: Int(int64((member["level_info"] as? [String: Any]) ?? [:], "current_level")),
            content: message,
            likeCount: int64(item, "like"),
            replyCount: int64(item, "count"),
            publishTime: ctime > 0 ? Date(timeIntervalSince1970: TimeInterval(ctime)) : nil,
            ipLocation: normalizeIPLocation((item["reply_control"] as? [String: Any])?["location"] as? String),
            emoticons: emoticons,
            replies: includeInlineReplies ? nested : []
        )
    }

    private nonisolated static func normalizeIPLocation(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return raw.replacingOccurrences(of: "IP属地：", with: "")
    }

    private nonisolated static func parseEmoteMap(_ content: [String: Any]) -> [String: String] {
        guard let emoteObject = content["emote"] as? [String: Any] else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in emoteObject {
            guard let dict = value as? [String: Any] else { continue }
            let url = string(dict, "url")
            guard !url.isEmpty, let normalized = normalizedURL(url)?.absoluteString else { continue }
            result[key] = normalized
        }
        return result
    }

    private nonisolated static func parseDynamicVideoItem(_ item: [String: Any]) -> BiliVideo? {
        guard let modules = item["modules"] as? [String: Any] else { return nil }
        let author = modules["module_author"] as? [String: Any]
        guard
            let moduleDynamic = modules["module_dynamic"] as? [String: Any],
            let major = moduleDynamic["major"] as? [String: Any],
            string(major, "type") == "MAJOR_TYPE_ARCHIVE",
            let archive = major["archive"] as? [String: Any]
        else {
            return nil
        }

        let bvid = string(archive, "bvid")
        guard !bvid.isEmpty else { return nil }

        let stat = archive["stat"] as? [String: Any] ?? [:]
        let aid = int64(archive, "aid")

        return BiliVideo(
            id: bvid,
            bvid: bvid,
            aid: aid,
            title: string(archive, "title"),
            coverURL: normalizedURL(string(archive, "cover")),
            authorName: author.map { string($0, "name") } ?? "",
            authorFaceURL: normalizedURL(author.map { string($0, "face") } ?? ""),
            authorMid: author.map { int64($0, "mid") } ?? 0,
            viewCount: looseCount(string(stat, "play")),
            danmakuCount: looseCount(string(stat, "danmaku")),
            likeCount: 0,
            duration: parseDurationText(string(archive, "duration_text")),
            description: string(archive, "desc"),
            cid: 0
        )
    }

    private nonisolated static func parseVideo(_ item: [String: Any]) -> BiliVideo? {
        let bvid = string(item, "bvid")
        let aid = int64(item, "aid", "id")
        guard !bvid.isEmpty || aid > 0 else { return nil }

        let owner = item["owner"] as? [String: Any]
        let authorName = string(item, "author", "up_name")
            .ifEmpty(owner.map { string($0, "name") } ?? "")
        let authorFace = normalizedURL(
            string(item, "author_face", "upic").ifEmpty(owner.map { string($0, "face") } ?? "")
        )
        let stat = item["stat"] as? [String: Any]

        return BiliVideo(
            id: bvid.ifEmpty(String(aid)),
            bvid: bvid,
            aid: aid,
            title: string(item, "title").htmlStripped,
            coverURL: normalizedURL(string(item, "pic", "cover")),
            authorName: authorName,
            authorFaceURL: authorFace,
            authorMid: int64(item, "mid", "author_mid").ifZero(owner.map { int64($0, "mid") } ?? 0),
            viewCount: int64(item, "play", "view").ifZero(stat.map { int64($0, "view") } ?? 0),
            danmakuCount: int64(item, "video_review", "danmaku").ifZero(stat.map { int64($0, "danmaku") } ?? 0),
            likeCount: int64(item, "like").ifZero(stat.map { int64($0, "like") } ?? 0),
            duration: duration(from: item),
            description: string(item, "desc", "description").htmlStripped,
            cid: int64(item, "cid")
        )
    }

    private nonisolated static func findFirstArray(in dictionary: [String: Any]) -> [[String: Any]] {
        for value in dictionary.values {
            if let array = value as? [[String: Any]], !array.isEmpty {
                return array
            }
            if let child = value as? [String: Any] {
                let nested = findFirstArray(in: child)
                if !nested.isEmpty { return nested }
            }
        }
        return []
    }

    private nonisolated static func dictionary(_ object: Any) -> [String: Any] {
        object as? [String: Any] ?? [:]
    }

    private nonisolated static func string(_ dictionary: [String: Any], _ keys: String...) -> String {
        for key in keys {
            if let value = dictionary[key] as? String, !value.isEmpty {
                return value
            }
            if let value = dictionary[key] as? NSNumber {
                return value.stringValue
            }
        }
        return ""
    }

    private nonisolated static func optionalString(_ dictionary: [String: Any], _ key: String) -> String? {
        let value = string(dictionary, key)
        return value.isEmpty ? nil : value
    }

    private nonisolated static func int64(_ dictionary: [String: Any], _ keys: String...) -> Int64 {
        for key in keys {
            if let value = dictionary[key] as? Int64 { return value }
            if let value = dictionary[key] as? Int { return Int64(value) }
            if let value = dictionary[key] as? Double { return Int64(value) }
            if let value = dictionary[key] as? NSNumber { return value.int64Value }
            if let value = dictionary[key] as? String, let parsed = Int64(value) { return parsed }
        }
        return 0
    }

    private nonisolated static func double(_ dictionary: [String: Any], _ keys: String...) -> Double {
        for key in keys {
            if let value = dictionary[key] as? Double { return value }
            if let value = dictionary[key] as? Int { return Double(value) }
            if let value = dictionary[key] as? NSNumber { return value.doubleValue }
            if let value = dictionary[key] as? String, let parsed = Double(value) { return parsed }
        }
        return 0
    }

    private nonisolated static func duration(from dictionary: [String: Any]) -> Int {
        if let value = dictionary["duration"] as? Int { return value }
        if let value = dictionary["duration"] as? NSNumber { return value.intValue }
        if let text = dictionary["duration"] as? String {
            return parseDurationText(text)
        }
        return 0
    }

    private nonisolated static func parseDurationText(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let parts = text.split(separator: ":").compactMap { Int($0) }
        switch parts.count {
        case 3:
            return parts[0] * 3600 + parts[1] * 60 + parts[2]
        case 2:
            return parts[0] * 60 + parts[1]
        case 1:
            return parts[0]
        default:
            return 0
        }
    }

    private nonisolated static func looseCount(_ raw: String) -> Int64 {
        let digits = raw.filter(\.isNumber)
        guard !digits.isEmpty else { return 0 }
        return Int64(digits) ?? 0
    }

    private nonisolated static func normalizedURL(_ raw: String) -> URL? {
        guard !raw.isEmpty else { return nil }
        if raw.hasPrefix("//") {
            return URL(string: "https:\(raw)")
        }
        if raw.hasPrefix("http://") {
            return URL(string: raw.replacingOccurrences(of: "http://", with: "https://"))
        }
        return URL(string: raw)
    }
}

private extension String {
    nonisolated var htmlStripped: String {
        replacingOccurrences(of: "<em class=\"keyword\">", with: "")
            .replacingOccurrences(of: "</em>", with: "")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
    }
}

private extension Int64 {
    nonisolated func ifZero(_ fallback: Int64) -> Int64 {
        self == 0 ? fallback : self
    }
}

private extension Int {
    nonisolated func ifZero(_ fallback: Int) -> Int {
        self == 0 ? fallback : self
    }
}
