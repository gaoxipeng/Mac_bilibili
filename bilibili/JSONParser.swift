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

    nonisolated static func parseHomeRecommendPage(
        from object: Any,
        freshIdx: Int,
        fetchRow: Int
    ) -> BiliHomeRecommendPage {
        let videos = parseVideos(from: object, preferredArrayKeys: ["item"])
        return BiliHomeRecommendPage(
            videos: videos,
            nextFreshIdx: freshIdx + 1,
            nextFetchRow: videos.isEmpty ? fetchRow : fetchRow + videos.count,
            lastShowList: homeRecommendShowList(from: videos),
            hasMore: !videos.isEmpty
        )
    }

    private nonisolated static func homeRecommendShowList(from videos: [BiliVideo]) -> String {
        videos.compactMap { video in
            video.aid > 0 ? "\(video.aid)" : nil
        }.joined(separator: "_")
    }

    nonisolated static func parseHotSearchItems(from object: Any) -> [BiliHotSearchItem] {
        let root = dictionary(object)
        let list = (root["list"] as? [[String: Any]])
            ?? (root["data"] as? [String: Any]).flatMap { $0["list"] as? [[String: Any]] }
            ?? findFirstArray(in: root)
        return list.enumerated().compactMap { index, item in
            let keyword = string(item, "keyword").ifEmpty(string(item, "show_name", "word", "name"))
            guard !keyword.isEmpty else { return nil }
            let showName = string(item, "show_name").ifEmpty(keyword).htmlStripped
            let rankRaw = Int(int64(item, "pos", "rank"))
            let rank = rankRaw == 0 ? index + 1 : rankRaw
            return BiliHotSearchItem(keyword: keyword, showName: showName, rank: rank)
        }
    }

    nonisolated static func parseSearchVideoPage(from object: Any) -> BiliSearchPage<BiliVideo> {
        let data = dictionary(object)["data"] as? [String: Any] ?? dictionary(object)
        let page = max(1, Int(int64(data, "page")))
        let numPages = max(page, Int(int64(data, "numPages", "numpages")))
        let items = parseVideos(from: object, preferredArrayKeys: ["result"])
        return BiliSearchPage(items: items, page: page, hasMore: page < numPages)
    }

    nonisolated static func parseSearchUserPage(from object: Any) -> BiliSearchPage<BiliSearchUser> {
        let data = dictionary(object)["data"] as? [String: Any] ?? dictionary(object)
        let page = max(1, Int(int64(data, "page")))
        let numPages = max(page, Int(int64(data, "numPages", "numpages")))
        let list = (data["result"] as? [[String: Any]]) ?? []
        let items = list.compactMap { item -> BiliSearchUser? in
            let mid = int64(item, "mid")
            guard mid > 0 else { return nil }
            return BiliSearchUser(
                mid: mid,
                name: string(item, "uname", "name").htmlStripped.ifEmpty("UP主"),
                faceURL: normalizedURL(string(item, "upic", "face")),
                sign: string(item, "usign", "sign"),
                fans: int64(item, "fans"),
                level: Int(int64(item, "level"))
            )
        }
        return BiliSearchPage(items: items, page: page, hasMore: page < numPages)
    }

    nonisolated static func parseSearchSuggest(from object: Any) -> [String] {
        let root = dictionary(object)
        let tags = (root["result"] as? [String: Any])?["tag"] as? [[String: Any]] ?? []
        var seen = Set<String>()
        return tags.compactMap { item -> String? in
            let term = string(item, "term", "value").htmlStripped
            guard !term.isEmpty, seen.insert(term).inserted else { return nil }
            return term
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
            bcoinBalance: double(wallet ?? data, "bcoin_balance"),
            videoCount: 0,
            topPhotoURLs: [],
            ipLocation: nil
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
            bcoinBalance: double(wallet ?? data, "bcoin_balance"),
            videoCount: profile.videoCount,
            topPhotoURLs: profile.topPhotoURLs,
            ipLocation: profile.ipLocation
        )
    }

    nonisolated static func parseUserAccInfo(from object: Any) -> BiliUserProfile? {
        let data = dictionary(object)["data"] as? [String: Any] ?? [:]
        let mid = int64(data, "mid")
        guard mid > 0 else { return nil }
        let levelInfo = data["level_info"] as? [String: Any]
        let relation = data["relation"] as? [String: Any]
        let relationStat = relation?["stat"] as? [String: Any]
        let likesInfo = data["likes"] as? [String: Any]
        let follower: Int64 = [int64(data, "follower"), int64(data, "fans"), int64(relationStat ?? [:], "follower")]
            .first(where: { $0 > 0 }) ?? 0
        let following: Int64 = [int64(data, "following"), int64(data, "attention"), int64(data, "friend")]
            .first(where: { $0 > 0 }) ?? 0
        let likes: Int64 = [int64(likesInfo ?? [:], "total_liked"), int64(data, "like_num")]
            .first(where: { $0 > 0 }) ?? 0
        let level = Int(int64(data, "level")).ifZero(Int(int64(levelInfo ?? [:], "current_level")))
        return BiliUserProfile(
            mid: mid,
            name: string(data, "name"),
            faceURL: normalizedURL(string(data, "face")),
            sign: string(data, "sign"),
            level: level,
            following: following,
            follower: follower,
            likes: likes,
            coinCount: 0,
            bcoinBalance: 0,
            videoCount: 0,
            topPhotoURLs: parseUserTopPhotoURLs(from: data),
            ipLocation: normalizeIpLocation(string(data, "location", "ip_location"))
        )
    }

    nonisolated static func parseUserCardProfile(from object: Any) -> BiliUserProfile? {
        let data = dictionary(object)["data"] as? [String: Any] ?? [:]
        let card = data["card"] as? [String: Any] ?? [:]
        let mid = int64(card, "mid")
        guard mid > 0 else { return nil }
        let levelInfo = card["level_info"] as? [String: Any]
        return BiliUserProfile(
            mid: mid,
            name: string(card, "name"),
            faceURL: normalizedURL(string(card, "face")),
            sign: string(card, "sign", "Sign"),
            level: Int(int64(levelInfo ?? [:], "current_level")),
            following: int64(card, "attention"),
            follower: int64(card, "fans"),
            likes: 0,
            coinCount: 0,
            bcoinBalance: 0,
            videoCount: 0,
            topPhotoURLs: parseUserTopPhotoURLs(from: card),
            ipLocation: normalizeIpLocation(string(card, "location"))
        )
    }

    nonisolated static func parseUserUpstatLikes(from object: Any) -> Int64 {
        let data = dictionary(object)["data"] as? [String: Any] ?? [:]
        return int64(data, "likes")
    }

    nonisolated static func parseUserNavnum(from object: Any) -> Int64 {
        let data = dictionary(object)["data"] as? [String: Any] ?? [:]
        let archive = data["archive"] as? [String: Any]
        return [int64(data, "video"), int64(archive ?? [:], "count")].first(where: { $0 > 0 }) ?? 0
    }

    nonisolated static func parseUserRelation(from object: Any) -> BiliAuthorRelation {
        let data = dictionary(object)["data"] as? [String: Any] ?? [:]
        return relationFromAttribute(Int(int64(data, "attribute")))
    }

    nonisolated static func relationFromAttribute(_ attribute: Int) -> BiliAuthorRelation {
        BiliAuthorRelation(
            following: attribute == 2 || attribute == 6,
            followerMe: attribute == 6
        )
    }

    nonisolated static func mergeSpaceProfile(
        acc: BiliUserProfile?,
        card: BiliUserProfile?,
        mid: Int64,
        likes: Int64,
        videoCount: Int64,
        extraTopPhotoURLs: [URL] = []
    ) -> BiliUserProfile? {
        guard let base = acc ?? card else { return nil }
        let enriched = card
        return BiliUserProfile(
            mid: mid,
            name: base.name.ifEmpty(enriched?.name ?? ""),
            faceURL: base.faceURL ?? enriched?.faceURL,
            sign: base.sign.ifEmpty(enriched?.sign ?? ""),
            level: base.level > 0 ? base.level : (enriched?.level ?? 0),
            following: base.following > 0 ? base.following : (enriched?.following ?? 0),
            follower: base.follower > 0 ? base.follower : (enriched?.follower ?? 0),
            likes: base.likes > 0 ? base.likes : likes,
            coinCount: 0,
            bcoinBalance: 0,
            videoCount: videoCount > 0 ? videoCount : base.videoCount,
            topPhotoURLs: mergeTopPhotoURLs(
                base.topPhotoURLs,
                enriched?.topPhotoURLs ?? [],
                extraTopPhotoURLs
            ),
            ipLocation: base.ipLocation ?? enriched?.ipLocation
        )
    }

    nonisolated static func parseUserTopPhotoList(from object: Any) -> [URL] {
        let root = dictionary(object)
        guard (root["status"] as? Bool) == true || (root["status"] as? NSNumber)?.boolValue == true else {
            return []
        }
        let items = root["data"] as? [[String: Any]] ?? []
        var owned: [(url: URL, sort: Int)] = []
        for item in items {
            if Int(int64(item, "is_disable")) == 1 { continue }
            guard let url = normalizedURL(normalizeSpaceImageURL(string(item, "l_img"))) else { continue }
            let had = Int(int64(item, "had"))
            let sort = Int(int64(item, "sort_num"))
            if had == 1 {
                owned.append((url, sort))
            }
        }
        return owned
            .sorted { $0.sort > $1.sort }
            .map(\.url)
    }

    nonisolated static func parseUserVideoPage(from object: Any) -> BiliUserVideoPage {
        let data = dictionary(object)["data"] as? [String: Any] ?? [:]
        let list = data["list"] as? [String: Any] ?? [:]
        let vlist = list["vlist"] as? [[String: Any]] ?? []
        let videos = vlist.compactMap(parseVideo)
        return BiliUserVideoPage(videos: videos, hasMore: videos.count >= 30)
    }

    nonisolated static func parseHistoryPage(from object: Any) -> BiliHistoryPage {
        let data = dictionary(object)["data"] as? [String: Any] ?? dictionary(object)
        let list = (data["list"] as? [[String: Any]]) ?? findFirstArray(in: data)
        let items = list.compactMap(parseHistoryItem)
        let cursorData = data["cursor"] as? [String: Any]
        let cursor = cursorData.map { cursorDict in
            BiliHistoryCursor(
                max: int64(cursorDict, "max"),
                viewAt: int64(cursorDict, "view_at"),
                business: string(cursorDict, "business"),
                ps: Int(int64(cursorDict, "ps"))
            )
        }
        return BiliHistoryPage(items: items, cursor: cursor)
    }

    nonisolated static func parseHistory(from object: Any) -> [BiliHistoryItem] {
        parseHistoryPage(from: object).items
    }

    nonisolated private static func parseHistoryItem(_ item: [String: Any]) -> BiliHistoryItem? {
        let history = item["history"] as? [String: Any]
        if let history, string(history, "business") != "archive", !string(history, "business").isEmpty {
            return nil
        }
        let bvid = string(item, "bvid").ifEmpty(history.map { string($0, "bvid") } ?? "")
        guard !bvid.isEmpty else { return nil }
        let historyCid = history.map { int64($0, "cid") } ?? 0
        let author = item["author"] as? [String: Any]
            ?? item["owner"] as? [String: Any]
            ?? item["upper"] as? [String: Any]
        let authorFaceRaw = string(item, "author_face", "author_icon")
            .ifEmpty(author.map { string($0, "face", "avatar") } ?? "")
        let authorName = string(item, "author_name", "name")
            .ifEmpty(author.map { string($0, "name", "uname") } ?? "")
        let authorMid = int64(item, "author_mid", "mid")
            .ifZero(author.map { int64($0, "mid") } ?? 0)
        let coverRaw = string(item, "cover", "pic")
            .ifEmpty((item["covers"] as? [String])?.first ?? "")
        let video = BiliVideo(
            id: bvid,
            bvid: bvid,
            aid: int64(item, "aid").ifZero(history.map { int64($0, "oid", "aid") } ?? 0),
            title: string(item, "title", "show_title").htmlStripped,
            coverURL: normalizedURL(coverRaw),
            authorName: authorName,
            authorFaceURL: normalizedURL(authorFaceRaw),
            authorMid: authorMid,
            viewCount: int64(item, "view"),
            danmakuCount: int64(item, "danmaku"),
            likeCount: 0,
            duration: duration(from: item),
            description: string(item, "desc"),
            cid: int64(item, "cid").ifZero(historyCid)
        )
        let viewedAtSeconds = int64(item, "view_at")
        let progressSeconds = max(0, Int(int64(item, "progress")))
        let durationSeconds = max(0, duration(from: item))
        let aid = video.aid
        return BiliHistoryItem(
            id: "\(bvid)-\(viewedAtSeconds)",
            kid: aid > 0 ? "archive_\(aid)" : "",
            video: video,
            viewedAt: viewedAtSeconds > 0 ? Date(timeIntervalSince1970: TimeInterval(viewedAtSeconds)) : nil,
            progressSeconds: progressSeconds,
            durationSeconds: durationSeconds
        )
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

    nonisolated static func parseVideoTags(from object: Any) -> [String] {
        let data = dictionary(object)["data"] as? [[String: Any]] ?? []
        var seen = Set<String>()
        return data.compactMap { item -> String? in
            let name = string(item, "tag_name", "name").htmlStripped
            guard !name.isEmpty, seen.insert(name).inserted else { return nil }
            return name
        }
    }

    nonisolated static func parseOnlineCount(from object: Any) -> Int64 {
        let data = dictionary(object)["data"] as? [String: Any] ?? [:]
        let total = data["total"] as? [String: Any] ?? data
        let count = int64(total, "total").ifZero(int64(total, "count"))
        return max(0, count)
    }

    nonisolated static func parseVideoReqUser(from data: [String: Any]) -> BiliVideoRelation {
        guard let reqUser = data["req_user"] as? [String: Any] else { return BiliVideoRelation() }
        return BiliVideoRelation(
            liked: boolish(reqUser["like"]),
            favorited: boolish(reqUser["favorite"]),
            coinCount: max(0, Int(int64(reqUser, "coin")))
        )
    }

    nonisolated static func parseVideoArchiveRelation(from object: Any) -> BiliVideoRelation {
        let data = dictionary(object)["data"] as? [String: Any] ?? dictionary(object)
        return BiliVideoRelation(
            liked: boolish(data["like"]),
            favorited: boolish(data["favorite"]),
            coinCount: max(0, Int(int64(data, "coin")))
        )
    }

    nonisolated static func parseHasLike(from object: Any) -> Bool {
        let data = dictionary(object)["data"]
        switch data {
        case let number as NSNumber:
            return number.intValue == 1
        case let flag as Bool:
            return flag
        case let dict as [String: Any]:
            return boolish(dict["like"])
        default:
            return false
        }
    }

    nonisolated static func parseVideoFavoured(from object: Any) -> Bool {
        guard let data = dictionary(object)["data"] as? [String: Any] else { return false }
        return boolish(data["favoured"])
    }

    nonisolated static func mergeVideoRelations(_ relations: [BiliVideoRelation]) -> BiliVideoRelation {
        guard !relations.isEmpty else { return BiliVideoRelation() }
        return BiliVideoRelation(
            liked: relations.contains(where: \.liked),
            favorited: relations.contains(where: \.favorited),
            coinCount: relations.map(\.coinCount).max() ?? 0
        )
    }

    nonisolated static func parseVideoTripleResult(from object: Any) -> BiliVideoTripleResult {
        guard let data = dictionary(object)["data"] as? [String: Any] else { return BiliVideoTripleResult() }
        return BiliVideoTripleResult(
            liked: boolish(data["like"]),
            coined: boolish(data["coin"]),
            favorited: boolish(data["fav"])
        )
    }

    nonisolated static func parseDefaultFavoriteFolderId(from object: Any) -> Int64? {
        guard let data = dictionary(object)["data"] as? [String: Any],
              let folders = data["list"] as? [[String: Any]],
              !folders.isEmpty else { return nil }

        struct FolderItem {
            let title: String
            let id: Int64
            let mediaCount: Int
        }

        let parsed: [FolderItem] = folders.compactMap { item in
            let id = int64(item, "id").ifZero(int64(item, "media_id"))
            guard id > 0 else { return nil }
            return FolderItem(
                title: string(item, "title"),
                id: id,
                mediaCount: Int(int64(item, "media_count"))
            )
        }
        guard !parsed.isEmpty else { return nil }
        return parsed.first(where: { $0.title == "默认收藏夹" })?.id
            ?? parsed.max(by: { $0.mediaCount < $1.mediaCount })?.id
            ?? parsed.first?.id
    }

    nonisolated static func parseFavoriteVideoPage(
        from object: Any,
        page: Int,
        pageSize: Int
    ) -> BiliFavoriteVideoPage {
        guard let data = dictionary(object)["data"] as? [String: Any] else {
            return BiliFavoriteVideoPage(videos: [], page: page, hasMore: false)
        }

        let medias = data["medias"] as? [[String: Any]] ?? []
        let videos = medias.compactMap(parseFavoriteMedia)
        let totalCount = Int(int64(data["info"] as? [String: Any] ?? [:], "media_count"))
        let hasMore = boolish(data["has_more"])
            || (totalCount > 0 && page * pageSize < totalCount)

        return BiliFavoriteVideoPage(
            videos: videos,
            page: page,
            hasMore: hasMore
        )
    }

    private nonisolated static func parseFavoriteMedia(_ item: [String: Any]) -> BiliVideo? {
        let mediaType = Int(int64(item, "type"))
        guard mediaType == 0 || mediaType == 2 else { return nil }

        var bvid = string(item, "bvid", "bv_id")
        if bvid.isEmpty {
            bvid = extractBvidFromURL(string(item, "link"))
        }
        guard !bvid.isEmpty else { return nil }

        let upper = item["upper"] as? [String: Any] ?? [:]
        let cntInfo = item["cnt_info"] as? [String: Any] ?? [:]

        return BiliVideo(
            id: bvid,
            bvid: bvid,
            aid: int64(item, "id"),
            title: string(item, "title").htmlStripped,
            coverURL: normalizedURL(string(item, "cover")),
            authorName: string(upper, "name"),
            authorFaceURL: normalizedURL(string(upper, "face")),
            authorMid: int64(upper, "mid"),
            viewCount: int64(cntInfo, "play"),
            danmakuCount: int64(cntInfo, "danmaku"),
            likeCount: int64(cntInfo, "thumb_up", "like"),
            duration: Int(int64(item, "duration")),
            description: "",
            cid: 0
        )
    }

    private nonisolated static func extractBvidFromURL(_ raw: String) -> String {
        guard let range = raw.range(of: #"BV[0-9A-Za-z]+"#, options: .regularExpression) else {
            return ""
        }
        return String(raw[range])
    }

    nonisolated static func boolish(_ value: Any?) -> Bool {
        switch value {
        case let number as NSNumber:
            return number.intValue == 1
        case let flag as Bool:
            return flag
        default:
            return false
        }
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
        let like = (modules["module_stat"] as? [String: Any])?["like"] as? [String: Any] ?? [:]
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
            likeCount: int64(like, "count"),
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
        if let text = dictionary["length"] as? String {
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

    private nonisolated static func parseUserTopPhotoURLs(from data: [String: Any]) -> [URL] {
        var values: [String] = []
        values.append(contentsOf: parseDelimitedTopPhotos(string(data, "top_photo")))
        if let array = data["top_photos"] as? [Any] {
            for entry in array {
                let raw = (entry as? String) ?? "\(entry)"
                let normalized = normalizeSpaceImageURL(raw)
                if !normalized.isEmpty {
                    values.append(normalized)
                }
            }
        }
        if let space = data["space"] as? [String: Any] {
            let large = normalizeSpaceImageURL(string(space, "l_img"))
            if !large.isEmpty { values.append(large) }
            let small = normalizeSpaceImageURL(string(space, "s_img"))
            if !small.isEmpty { values.append(small) }
        }
        return mergeTopPhotoURLs(values.compactMap(normalizedURL))
    }

    private nonisolated static func parseDelimitedTopPhotos(_ raw: String) -> [String] {
        raw.split { $0 == "," || $0 == ";" }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map(normalizeSpaceImageURL)
            .filter { !$0.isEmpty }
    }

    private nonisolated static func mergeTopPhotoURLs(_ groups: [URL]...) -> [URL] {
        var seen = Set<String>()
        var merged: [URL] = []
        for group in groups {
            for url in group {
                let key = url.absoluteString
                if seen.insert(key).inserted {
                    merged.append(url)
                }
            }
        }
        return merged
    }

    private nonisolated static func normalizeSpaceImageURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.hasPrefix("bfs/") {
            return "https://i0.hdslb.com/\(trimmed)"
        }
        if trimmed.hasPrefix("//") {
            return "https:\(trimmed)"
        }
        return trimmed
    }

    private nonisolated static func normalizeIpLocation(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("IP属地：") {
            let value = String(trimmed.dropFirst("IP属地：".count))
            return value.isEmpty ? nil : value
        }
        return trimmed
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
