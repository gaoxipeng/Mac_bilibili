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

    nonisolated static func parseSearchBangumiPage(from object: Any) -> BiliSearchPage<BiliSearchBangumi> {
        let data = dictionary(object)["data"] as? [String: Any] ?? dictionary(object)
        let page = max(1, Int(int64(data, "page")))
        let numPages = max(page, Int(int64(data, "numPages", "numpages")))
        let list = (data["result"] as? [[String: Any]]) ?? []
        let items = list.compactMap(parseSearchBangumiItem)
        return BiliSearchPage(items: items, page: page, hasMore: page < numPages)
    }

    nonisolated private static func parseSearchBangumiItem(_ item: [String: Any]) -> BiliSearchBangumi? {
        let itemType = string(item, "type")
        if !itemType.isEmpty, itemType != "media_bangumi", itemType != "media_ft" {
            return nil
        }

        let seasonId = int64(item, "season_id", "pgc_season_id")
        guard seasonId > 0 else { return nil }

        let title = string(item, "title").htmlStripped
        guard !title.isEmpty else { return nil }

        let eps = item["eps"] as? [[String: Any]] ?? []
        var firstEpid = eps.compactMap { ep -> Int64? in
            let epid = int64(ep, "id", "epid")
            return epid > 0 ? epid : nil
        }.first ?? 0
        if firstEpid == 0, let firstEp = item["first_ep"] as? [String: Any] {
            firstEpid = int64(firstEp, "id", "ep_id", "epid")
        }
        if firstEpid == 0 {
            firstEpid = epidFromBangumiSearchItem(item, eps: eps)
        }

        let badge = membershipBadge(from: item)
        let categoryName = pgcCategoryName(from: item)

        return BiliSearchBangumi(
            seasonId: seasonId,
            mediaId: int64(item, "media_id"),
            title: title,
            subtitle: string(item, "org_title").htmlStripped,
            coverURL: normalizedURL(string(item, "cover")),
            areas: string(item, "areas").htmlStripped,
            styles: string(item, "styles").htmlStripped,
            badge: badge,
            categoryName: categoryName,
            indexShow: string(item, "index_show", "fix_pubtime_str").htmlStripped,
            webURL: normalizedURL(string(item, "goto_url", "url")),
            firstEpid: firstEpid
        )
    }

    nonisolated private static func membershipBadge(from item: [String: Any]) -> String {
        let angleTitle = string(item, "angle_title").htmlStripped
        if !angleTitle.isEmpty {
            return angleTitle
        }
        let displayInfo = item["display_info"] as? [[String: Any]] ?? []
        if let text = displayInfo.compactMap({ string($0, "text").htmlStripped }).first(where: { !$0.isEmpty }) {
            return text
        }
        let badges = item["badges"] as? [[String: Any]] ?? []
        return badges.compactMap { string($0, "text").htmlStripped }.first { !$0.isEmpty } ?? ""
    }

    nonisolated static func parseSearchAllPGCMedia(from object: Any) -> [BiliSearchBangumi] {
        let data = dictionary(object)["data"] as? [String: Any] ?? dictionary(object)
        let groups = data["result"] as? [[String: Any]] ?? []
        var items: [BiliSearchBangumi] = []
        for group in groups {
            let resultType = string(group, "result_type")
            guard resultType == "media_bangumi" || resultType == "media_ft" else { continue }
            let list = group["data"] as? [[String: Any]] ?? []
            items.append(contentsOf: list.compactMap(parseSearchBangumiItem))
        }
        return items
    }

    nonisolated static func parsePGCSeasonFirstEpid(from object: Any) -> Int64 {
        let result = dictionary(object)["result"] as? [String: Any] ?? dictionary(object)["data"] as? [String: Any] ?? [:]
        let episodes = result["episodes"] as? [[String: Any]] ?? []
        for episode in episodes {
            let epid = int64(episode, "ep_id", "id", "epid")
            if epid > 0 {
                return epid
            }
        }
        return 0
    }

    nonisolated private static func pgcCategoryName(from item: [String: Any]) -> String {
        let seasonTypeName = string(item, "season_type_name").htmlStripped
        if !seasonTypeName.isEmpty {
            return seasonTypeName
        }
        let mediaType = Int(int64(item, "media_type", "season_type"))
        switch mediaType {
        case 1: return "番剧"
        case 2: return "电影"
        case 3: return "纪录片"
        case 4: return "国创"
        case 5: return "电视剧"
        case 7: return "综艺"
        default: return "影视"
        }
    }

    nonisolated private static func epidFromBangumiSearchItem(
        _ item: [String: Any],
        eps: [[String: Any]]
    ) -> Int64 {
        let hitEpids = string(item, "hit_epids")
        if let first = hitEpids.split(separator: ",").first {
            let epid = Int64(first.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            if epid > 0 { return epid }
        }

        var urlCandidates = [
            string(item, "goto_url"),
            string(item, "url")
        ]
        urlCandidates.append(contentsOf: eps.map { string($0, "url") })

        for candidate in urlCandidates where !candidate.isEmpty {
            if let epid = epidFromBangumiPlayURL(candidate), epid > 0 {
                return epid
            }
        }
        return 0
    }

    nonisolated private static func epidFromBangumiPlayURL(_ url: String) -> Int64? {
        guard let range = url.range(of: #"/ep(\d+)"#, options: .regularExpression) else { return nil }
        let token = url[range].dropFirst(3)
        return Int64(token)
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
            ipLocation: normalizeIpLocation(string(card, "location"))
        )
    }

    nonisolated static func parseUserCardSnapshot(from object: Any) -> BiliUserCardSnapshot? {
        let data = dictionary(object)["data"] as? [String: Any] ?? [:]
        guard let profile = parseUserCardProfile(from: object) else { return nil }
        let followerCount = int64(data, "follower").ifZero(profile.follower)
        return BiliUserCardSnapshot(
            sign: profile.sign,
            level: profile.level,
            followerCount: followerCount,
            relation: BiliAuthorRelation(following: boolish(data["following"]))
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

    nonisolated static func parseRelationUserPage(from object: Any, pageSize: Int) -> BiliRelationUserPage {
        let root = dictionary(object)
        let code = Int(int64(root, "code"))
        if code != 0 {
            let message = string(root, "message")
            let errorMessage: String = {
                if !message.isEmpty, message != "0" { return message }
                switch code {
                case 22115, 22118: return "由于该用户隐私设置，列表不可见"
                case -101: return "登录后查看"
                default: return "加载失败"
                }
            }()
            return BiliRelationUserPage(users: [], hasMore: false, total: 0, errorMessage: errorMessage)
        }

        let data = root["data"] as? [String: Any] ?? [:]
        let list = data["list"] as? [[String: Any]] ?? []
        let users = list.compactMap(parseRelationUser)
        return BiliRelationUserPage(
            users: users,
            hasMore: users.count >= pageSize,
            total: int64(data, "total"),
            errorMessage: nil
        )
    }

    nonisolated private static func parseRelationUser(_ item: [String: Any]) -> BiliRelationUser? {
        let mid = int64(item, "mid")
        guard mid > 0 else { return nil }

        let ipRaw = string(item, "location")
            .ifEmpty((item["res"] as? [String: Any]).map { string($0, "location") } ?? "")
            .ifEmpty((item["user"] as? [String: Any]).map { string($0, "location") } ?? "")

        let fanCandidates = [
            int64(item, "fans"),
            int64(item, "follower"),
            int64(item["official"] as? [String: Any] ?? [:], "fans"),
        ]
        let fanCount = fanCandidates.first(where: { $0 > 0 }) ?? Int64(0)

        return BiliRelationUser(
            mid: mid,
            name: string(item, "uname").ifEmpty("用户"),
            faceURL: normalizedURL(string(item, "face")),
            sign: string(item, "sign"),
            relation: relationFromAttribute(Int(int64(item, "attribute"))),
            fanCount: fanCount,
            ipLocation: normalizeIpLocation(ipRaw)
        )
    }

    nonisolated static func mergeSpaceProfile(
        acc: BiliUserProfile?,
        card: BiliUserProfile?,
        mid: Int64,
        likes: Int64,
        videoCount: Int64
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
            ipLocation: base.ipLocation ?? enriched?.ipLocation
        )
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
        let items = deduplicatedHistoryItems(list.compactMap(parseHistoryItem))
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

    nonisolated static func deduplicatedHistoryItems(_ items: [BiliHistoryItem]) -> [BiliHistoryItem] {
        var result: [BiliHistoryItem] = []
        var indexByKey: [String: Int] = [:]

        for item in items {
            let key = historyDedupKey(for: item)
            if let index = indexByKey[key] {
                let preferred = preferredHistoryItem(result[index], item)
                if preferred.id != result[index].id {
                    result[index] = preferred
                }
            } else {
                indexByKey[key] = result.count
                result.append(item)
            }
        }

        return result
    }

    nonisolated private static func historyDedupKey(for item: BiliHistoryItem) -> String {
        if item.video.cid > 0 {
            return "cid:\(item.video.cid)"
        }
        if item.epid > 0 {
            return "ep:\(item.epid)"
        }
        if !item.video.bvid.isEmpty {
            return "bv:\(item.video.bvid)"
        }
        if item.video.aid > 0 {
            return "aid:\(item.video.aid)"
        }
        return "id:\(item.id)"
    }

    nonisolated private static func preferredHistoryItem(
        _ existing: BiliHistoryItem,
        _ candidate: BiliHistoryItem
    ) -> BiliHistoryItem {
        let existingHasFace = existing.video.authorFaceURL != nil
        let candidateHasFace = candidate.video.authorFaceURL != nil
        if existingHasFace != candidateHasFace {
            return candidateHasFace ? candidate : existing
        }

        let existingDate = existing.viewedAt ?? .distantPast
        let candidateDate = candidate.viewedAt ?? .distantPast
        return candidateDate >= existingDate ? candidate : existing
    }

    nonisolated static func parseHistory(from object: Any) -> [BiliHistoryItem] {
        parseHistoryPage(from: object).items
    }

    nonisolated private static func parseHistoryItem(_ item: [String: Any]) -> BiliHistoryItem? {
        let history = item["history"] as? [String: Any]
        let businessRaw = string(history ?? item, "business")
        guard businessRaw == "archive" || businessRaw == "pgc" else { return nil }

        let business = BiliHistoryBusiness(rawValue: businessRaw) ?? .unknown
        let bvid = string(item, "bvid").ifEmpty(history.map { string($0, "bvid") } ?? "")
        let epid = history.map { int64($0, "epid") } ?? 0
        let historyCid = history.map { int64($0, "cid") } ?? 0
        let aid = int64(item, "aid").ifZero(history.map { int64($0, "oid", "aid") } ?? 0)
        let cid = int64(item, "cid").ifZero(historyCid)

        if business == .archive {
            guard !bvid.isEmpty else { return nil }
        } else if epid <= 0, cid <= 0 {
            return nil
        }

        let primaryTitle = string(item, "title", "show_title").htmlStripped
        let episodeTitle = string(item, "show_title", "long_title").htmlStripped
        let displayTitle: String = {
            if business == .pgc, !episodeTitle.isEmpty, episodeTitle != primaryTitle {
                return primaryTitle.isEmpty ? episodeTitle : "\(primaryTitle) · \(episodeTitle)"
            }
            return primaryTitle.ifEmpty(episodeTitle)
        }()
        guard !displayTitle.isEmpty else { return nil }

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
        let badge = string(item, "badge").htmlStripped
        let uriRaw = string(item, "uri")
        let webURI = normalizedURL(uriRaw)
        let videoID: String = {
            if !bvid.isEmpty { return bvid }
            if epid > 0 { return "pgc:\(epid)" }
            if cid > 0 { return "pgc-cid:\(cid)" }
            return "pgc-aid:\(aid)"
        }()

        let video = BiliVideo(
            id: videoID,
            bvid: bvid,
            aid: aid,
            title: displayTitle,
            coverURL: normalizedURL(coverRaw),
            authorName: authorName,
            authorFaceURL: normalizedURL(authorFaceRaw),
            authorMid: authorMid,
            viewCount: int64(item, "view"),
            danmakuCount: int64(item, "danmaku"),
            likeCount: 0,
            duration: duration(from: item),
            description: string(item, "desc"),
            cid: cid
        )
        let viewedAtSeconds = int64(item, "view_at")
        let progressSeconds = max(0, Int(int64(item, "progress")))
        let durationSeconds = max(0, duration(from: item))
        let kidValue = int64(item, "kid")
        let kid: String = {
            guard kidValue > 0 else { return "" }
            switch business {
            case .archive:
                return "archive_\(kidValue)"
            case .pgc:
                return "pgc_\(kidValue)"
            case .unknown:
                return ""
            }
        }()
        let itemID: String = {
            if business == .pgc {
                let anchor = epid > 0 ? epid : (cid > 0 ? cid : aid)
                return "pgc-\(anchor)-\(viewedAtSeconds)"
            }
            return "\(bvid)-\(viewedAtSeconds)"
        }()

        return BiliHistoryItem(
            id: itemID,
            kid: kid,
            business: business,
            video: video,
            viewedAt: viewedAtSeconds > 0 ? Date(timeIntervalSince1970: TimeInterval(viewedAtSeconds)) : nil,
            progressSeconds: progressSeconds,
            durationSeconds: durationSeconds,
            epid: epid,
            webURI: webURI,
            badge: badge
        )
    }

    nonisolated static func parsePGCEpisodeContext(from object: Any, epid: Int64) -> BiliPGCEpisodeContext? {
        let result = dictionary(object)["result"] as? [String: Any] ?? dictionary(object)
        guard epid > 0 else { return nil }

        let episodes = result["episodes"] as? [[String: Any]] ?? []
        guard let episode = episodes.first(where: { int64($0, "id", "ep_id") == epid }) else {
            return nil
        }

        let seasonId = int64(result, "season_id")
        let seasonTitle = string(result, "title", "season_title").htmlStripped
        let episodeTitle = string(episode, "title").htmlStripped
        let longTitle = string(episode, "long_title").htmlStripped
        let aid = int64(episode, "aid")
        let bvid = string(episode, "bvid")
        let cid = int64(episode, "cid")
        guard aid > 0, !bvid.isEmpty, cid > 0 else { return nil }

        let styles = (result["styles"] as? [String])?.joined(separator: " / ")
            ?? string(result, "styles").htmlStripped
        let areas = (result["areas"] as? [[String: Any]])?
            .compactMap { string($0, "name").htmlStripped }
            .filter { !$0.isEmpty }
            .joined(separator: " / ")
            ?? string(result, "areas").htmlStripped

        let pages = episodes.enumerated().compactMap { index, item -> BiliVideoPage? in
            let pageEpid = int64(item, "id", "ep_id")
            let pageCid = int64(item, "cid")
            guard pageEpid > 0, pageCid > 0 else { return nil }
            let pageLongTitle = string(item, "long_title").htmlStripped
            let pageShortTitle = string(item, "title").htmlStripped
            let title = pageLongTitle.ifEmpty(pageShortTitle).ifEmpty("第\(index + 1)话")
            let durationMs = int64(item, "duration")
            let duration = durationMs > 0 ? Int(durationMs / 1000) : 0
            return BiliVideoPage(
                page: index + 1,
                cid: pageCid,
                title: title,
                duration: duration,
                epid: pageEpid
            )
        }

        let durationMs = int64(episode, "duration")
        let duration = durationMs > 0 ? Int(durationMs / 1000) : 0

        return BiliPGCEpisodeContext(
            epid: epid,
            seasonId: seasonId,
            seasonTitle: seasonTitle,
            episodeTitle: episodeTitle,
            longTitle: longTitle,
            aid: aid,
            bvid: bvid,
            cid: cid,
            coverURL: normalizedURL(string(episode, "cover").ifEmpty(string(result, "cover"))),
            duration: duration,
            evaluate: string(result, "evaluate").htmlStripped,
            styles: styles,
            areas: areas,
            pages: pages
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
        let root = dictionary(object)
        if let result = root["result"] as? [String: Any] {
            if let videoInfo = result["video_info"] as? [String: Any],
               let stream = parsePlayStreamPayload(from: videoInfo) {
                return stream
            }
            if let stream = parsePlayStreamPayload(from: result) {
                return stream
            }
        }
        if let data = root["data"] as? [String: Any],
           let stream = parsePlayStreamPayload(from: data) {
            return stream
        }
        return parsePlayStreamPayload(from: root)
    }

    private nonisolated static func parsePlayStreamPayload(from data: [String: Any]) -> BiliPlayStream? {
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

    nonisolated static func parseCommentPage(from object: Any, includePinned: Bool = true) -> BiliCommentPage {
        let data = dictionary(object)["data"] as? [String: Any] ?? dictionary(object)
        let cursor = data["cursor"] as? [String: Any]
        let pinned = includePinned ? parsePinnedCommentItems(from: data) : []
        let pinnedIDs = Set(pinned.map(\.id))
        let replies = data["replies"] as? [[String: Any]] ?? []
        let regular = replies.compactMap { parseCommentItem($0, includeInlineReplies: true) }
            .filter { !pinnedIDs.contains($0.id) }
        let comments = pinned + regular
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

    private nonisolated static func parsePinnedCommentItems(from data: [String: Any]) -> [BiliCommentItem] {
        var result: [BiliCommentItem] = []
        var seen = Set<Int64>()

        func append(_ raw: Any?) {
            guard let dictionary = raw as? [String: Any],
                  let item = parseCommentItem(dictionary, includeInlineReplies: true, isPinned: true),
                  seen.insert(item.id).inserted else {
                return
            }
            result.append(item)
        }

        if let top = data["top"] as? [String: Any] {
            append(top["upper"])
            append(top["admin"])
            append(top["vote"])
        }

        if let upper = data["upper"] as? [String: Any] {
            append(upper["top"])
        }

        if let topReplies = data["top_replies"] as? [[String: Any]] {
            for reply in topReplies {
                append(reply)
            }
        }

        return result
    }

    private nonisolated static func parseCommentItem(
        _ item: [String: Any],
        includeInlineReplies: Bool,
        isPinned: Bool = false
    ) -> BiliCommentItem? {
        guard let member = item["member"] as? [String: Any] else { return nil }
        let content = item["content"] as? [String: Any] ?? [:]
        let message = string(content, "message")
        let emoticons = parseEmoteMap(content)
        let pictures = parseCommentPictures(content: content, item: item)
        if message.isEmpty, emoticons.isEmpty, pictures.isEmpty, !includeInlineReplies { return nil }
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
            pictures: pictures,
            replies: includeInlineReplies ? nested : [],
            isPinned: isPinned
        )
    }

    private nonisolated static func normalizeIPLocation(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return raw.replacingOccurrences(of: "IP属地：", with: "")
    }

    private nonisolated static func parseCommentPictures(content: [String: Any], item: [String: Any]) -> [BiliCommentPicture] {
        var rawPictures = content["pictures"] as? [[String: Any]] ?? []
        if rawPictures.isEmpty {
            rawPictures = item["pictures"] as? [[String: Any]] ?? []
        }
        return rawPictures.compactMap(parseCommentPicture)
    }

    private nonisolated static func parseCommentPicture(_ picture: [String: Any]) -> BiliCommentPicture? {
        let src = string(picture, "img_src", "src", "url", "imgSrc")
        guard !src.isEmpty, let url = normalizedURL(src) else { return nil }
        let width = Int(int64(picture, "img_width", "width"))
        let height = Int(int64(picture, "img_height", "height"))
        return BiliCommentPicture(url: url, width: width, height: height)
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
        let cntInfo = archive["cnt_info"] as? [String: Any] ?? [:]
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
            viewCount: parseArchiveStatCount(stat, "play", "view")
                .ifZero(parseArchiveStatCount(cntInfo, "play", "view")),
            danmakuCount: parseArchiveStatCount(stat, "danmaku", "video_review", "dm")
                .ifZero(parseArchiveStatCount(cntInfo, "danmaku", "video_review", "dm")),
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
        parseLooseOrCompactCount(raw)
    }

    private nonisolated static func parseArchiveStatCount(
        _ dictionary: [String: Any],
        _ keys: String...
    ) -> Int64 {
        for key in keys {
            guard let raw = dictionary[key] else { continue }
            let parsed = parseStatCountValue(raw)
            if parsed > 0 {
                return parsed
            }
        }
        return 0
    }

    private nonisolated static func parseStatCountValue(_ raw: Any) -> Int64 {
        if let dictionary = raw as? [String: Any] {
            let numeric = int64(dictionary, "count", "value", "num", "number")
            if numeric > 0 {
                return numeric
            }
            let text = string(dictionary, "count", "value", "text", "num", "number")
            if !text.isEmpty {
                return parseLooseOrCompactCount(text)
            }
            return 0
        }

        if let number = raw as? NSNumber {
            return number.int64Value
        }
        if let value = raw as? Int {
            return Int64(value)
        }
        if let value = raw as? Int64 {
            return value
        }
        if let value = raw as? Double {
            return Int64(value)
        }
        if let value = raw as? String {
            return parseLooseOrCompactCount(value)
        }
        return 0
    }

    private nonisolated static func parseLooseOrCompactCount(_ raw: String) -> Int64 {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "-" else { return 0 }

        if trimmed.contains("亿") {
            let numeric = trimmed
                .replacingOccurrences(of: "亿", with: "")
                .filter { $0.isNumber || $0 == "." }
            if let value = Double(numeric), value > 0 {
                return Int64(value * 100_000_000)
            }
        }

        if trimmed.contains("万") {
            let numeric = trimmed
                .replacingOccurrences(of: "万", with: "")
                .filter { $0.isNumber || $0 == "." }
            if let value = Double(numeric), value > 0 {
                return Int64(value * 10_000)
            }
        }

        let digits = trimmed.filter(\.isNumber)
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

    private nonisolated static func normalizeIpLocation(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("IP属地：") {
            let value = String(trimmed.dropFirst("IP属地：".count))
            return value.isEmpty ? nil : value
        }
        return trimmed
    }

    nonisolated static func parseSpaceDynamicFeed(from object: Any) -> BiliDynamicFeedPage {
        let data = dictionary(object)["data"] as? [String: Any] ?? [:]
        let items = data["items"] as? [[String: Any]] ?? []
        let parsed = items.compactMap(parseSpaceDynamicItem)
        let offsetRaw = string(data, "offset")
        let nextOffset = offsetRaw.isEmpty ? nil : offsetRaw
        let hasMore = (data["has_more"] as? Bool) ?? (nextOffset != nil && !parsed.isEmpty)
        return BiliDynamicFeedPage(items: parsed, nextOffset: nextOffset, hasMore: hasMore)
    }

    private nonisolated static func parseSpaceDynamicItem(_ item: [String: Any]) -> BiliDynamicItem? {
        let id = string(item, "id_str").ifEmpty(string(item, "id"))
        guard !id.isEmpty else { return nil }
        guard let modules = item["modules"] as? [String: Any] else { return nil }

        let origItem = (item["orig"] as? [String: Any]).flatMap { orig in
            (orig["modules"] as? [String: Any]) != nil ? orig : nil
        }
        let dynamicType = string(item, "type")
        let isForward = dynamicType == "DYNAMIC_TYPE_FORWARD" || origItem != nil
        let stat = modules["module_stat"] as? [String: Any]
        let meta = parseDynamicItemMeta(item: item, modules: modules, dynamicType: dynamicType)
        let publishTime = int64(
            (modules["module_author"] as? [String: Any]) ?? [:],
            "pub_ts"
        ).ifZero(int64(item, "pub_ts"))

        if isForward, let origItem, let origModules = origItem["modules"] as? [String: Any] {
            let forwardRich = parseDynamicDesc(modules)
            let originBody = parseDynamicBody(item: origItem, modules: origModules)
            let origin = BiliDynamicOrigin(
                authorName: parseModuleAuthorName(origModules),
                text: originBody.text,
                emoticons: originBody.emoticons,
                video: originBody.video,
                imageURLs: originBody.imageURLs,
                link: originBody.link
            )
            return BiliDynamicItem(
                id: id,
                text: forwardRich.text,
                emoticons: forwardRich.emoticons,
                publishTimeSeconds: publishTime,
                video: nil,
                imageURLs: [],
                link: nil,
                origin: origin,
                authorMid: meta.authorMid,
                authorName: meta.authorName,
                authorFaceURL: meta.authorFaceURL,
                authorLevel: meta.authorLevel,
                ipLocation: meta.ipLocation,
                commentOid: meta.commentOid,
                commentType: meta.commentType,
                dynamicType: meta.dynamicType,
                likeCount: parseDynamicStatCount(stat, key: "like"),
                commentCount: parseDynamicStatCount(stat, key: "comment"),
                repostCount: parseDynamicStatCount(stat, key: "forward")
            )
        }

        let body = parseDynamicBody(item: item, modules: modules)
        return BiliDynamicItem(
            id: id,
            text: body.text,
            emoticons: body.emoticons,
            publishTimeSeconds: publishTime,
            video: body.video,
            imageURLs: body.imageURLs,
            link: body.link,
            origin: nil,
            authorMid: meta.authorMid,
            authorName: meta.authorName,
            authorFaceURL: meta.authorFaceURL,
            authorLevel: meta.authorLevel,
            ipLocation: meta.ipLocation,
            commentOid: meta.commentOid,
            commentType: meta.commentType,
            dynamicType: meta.dynamicType,
            likeCount: parseDynamicStatCount(stat, key: "like"),
            commentCount: parseDynamicStatCount(stat, key: "comment"),
            repostCount: parseDynamicStatCount(stat, key: "forward")
        )
    }

    private nonisolated struct DynamicRichText: Sendable {
        var text = ""
        var emoticons: [String: String] = [:]
    }

    private struct DynamicBody: Sendable {
        var text = ""
        var emoticons: [String: String] = [:]
        var video: BiliVideo?
        var imageURLs: [URL] = []
        var link: BiliDynamicLink?
    }

    private struct DynamicItemMeta: Sendable {
        var authorMid: Int64 = 0
        var authorName = ""
        var authorFaceURL: URL?
        var authorLevel = 0
        var ipLocation: String?
        var commentOid: Int64 = 0
        var commentType = 0
        var dynamicType = ""
    }

    private nonisolated static func parseDynamicItemMeta(
        item: [String: Any],
        modules: [String: Any],
        dynamicType: String
    ) -> DynamicItemMeta {
        let author = modules["module_author"] as? [String: Any]
        let basic = item["basic"] as? [String: Any]
        var commentType = Int(int64(basic ?? [:], "comment_type"))
        var commentOid = int64(basic ?? [:], "comment_id_str").ifZero(int64(basic ?? [:], "rid_str"))
        if commentType <= 0 {
            commentType = fallbackDynamicCommentType(dynamicType)
        }
        if commentOid <= 0 {
            commentOid = fallbackDynamicCommentOid(item: item, dynamicType: dynamicType)
        }
        let badge = author?["badge"] as? [String: Any]
        let level = Int(int64(badge ?? [:], "level")).ifZero(Int(int64(author ?? [:], "level")))
        return DynamicItemMeta(
            authorMid: int64(author ?? [:], "mid"),
            authorName: parseModuleAuthorName(modules),
            authorFaceURL: normalizedURL(author.map { string($0, "face") } ?? ""),
            authorLevel: level,
            ipLocation: normalizeIpLocation(string(author ?? [:], "pub_location", "location")),
            commentOid: commentOid,
            commentType: commentType,
            dynamicType: dynamicType
        )
    }

    private nonisolated static func fallbackDynamicCommentType(_ dynamicType: String) -> Int {
        switch dynamicType {
        case "DYNAMIC_TYPE_WORD", "DYNAMIC_TYPE_FORWARD", "DYNAMIC_TYPE_LIVE_RCMD", "DYNAMIC_TYPE_OPUS":
            return 17
        case "DYNAMIC_TYPE_DRAW":
            return 11
        case "DYNAMIC_TYPE_AV", "DYNAMIC_TYPE_UGC_SEASON":
            return 1
        case "DYNAMIC_TYPE_ARTICLE":
            return 12
        default:
            return 0
        }
    }

    private nonisolated static func fallbackDynamicCommentOid(item: [String: Any], dynamicType: String) -> Int64 {
        let id = Int64(string(item, "id_str").ifEmpty(string(item, "id"))) ?? 0
        let basic = item["basic"] as? [String: Any]
        let rid = int64(basic ?? [:], "rid_str")
        switch dynamicType {
        case "DYNAMIC_TYPE_WORD", "DYNAMIC_TYPE_FORWARD", "DYNAMIC_TYPE_LIVE_RCMD", "DYNAMIC_TYPE_OPUS":
            return id
        case "DYNAMIC_TYPE_DRAW":
            return rid > 0 ? rid : id
        default:
            return rid > 0 ? rid : id
        }
    }

    private nonisolated static func parseDynamicBody(item: [String: Any], modules: [String: Any]) -> DynamicBody {
        let moduleDynamic = modules["module_dynamic"] as? [String: Any]
        let descRich = parseDynamicDesc(modules)
        var text = descRich.text
        var emoticons = descRich.emoticons
        var video: BiliVideo?
        var imageURLs = parseRichTextImages(moduleDynamic?["desc"] as? [String: Any])
        var link: BiliDynamicLink?

        if let major = moduleDynamic?["major"] as? [String: Any] {
            let parsed = parseDynamicMajor(major, modules: modules)
            if !parsed.text.isEmpty, !isDuplicateDynamicText(text, parsed.text) {
                text = mergeDynamicText(text, parsed.text)
            }
            emoticons.merge(parsed.emoticons) { _, new in new }
            video = parsed.video
            if !parsed.imageURLs.isEmpty { imageURLs = parsed.imageURLs }
            link = parsed.link
        }

        if let additional = parseDynamicAdditional(moduleDynamic: moduleDynamic, modules: modules) {
            if !additional.text.isEmpty, !isDuplicateDynamicText(text, additional.text) {
                text = mergeDynamicText(text, additional.text)
            }
            emoticons.merge(additional.emoticons) { _, new in new }
            if video == nil { video = additional.video }
            if link == nil { link = additional.link }
            if imageURLs.isEmpty { imageURLs = additional.imageURLs }
        }

        if video == nil, imageURLs.isEmpty, link == nil {
            if let fallback = parseDynamicItemFallback(item: item, modules: modules) {
                if !fallback.text.isEmpty, !isDuplicateDynamicText(text, fallback.text) {
                    text = mergeDynamicText(text, fallback.text)
                }
                emoticons.merge(fallback.emoticons) { _, new in new }
                if imageURLs.isEmpty { imageURLs = fallback.imageURLs }
                if link == nil { link = fallback.link }
            }
        }

        if video == nil {
            video = parseDynamicVideoItem(item)
        }

        if video != nil {
            link = nil
        } else if let currentLink = link, !shouldShowDynamicLink(text: text, link: currentLink, imageURLs: imageURLs) {
            link = nil
        }

        return DynamicBody(
            text: text,
            emoticons: emoticons,
            video: video,
            imageURLs: imageURLs,
            link: link
        )
    }

    private nonisolated static func parseDynamicAdditional(
        moduleDynamic: [String: Any]?,
        modules: [String: Any]
    ) -> DynamicBody? {
        guard let additional = moduleDynamic?["additional"] as? [String: Any] else { return nil }

        if let ugc = additional["ugc"] as? [String: Any],
           let video = parseAdditionalUgcVideo(ugc, modules: modules) {
            return DynamicBody(video: video)
        }

        switch string(additional, "type") {
        case "ADDITIONAL_TYPE_UGC":
            guard let ugc = additional["ugc"] as? [String: Any],
                  let video = parseAdditionalUgcVideo(ugc, modules: modules) else { return nil }
            return DynamicBody(video: video)
        case "ADDITIONAL_TYPE_COMMON":
            guard let common = additional["common"] as? [String: Any] else { return nil }
            let desc = [string(common, "desc1"), string(common, "desc2")]
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
            let jumpURL = normalizeJumpURL(string(common, "jump_url"))
            guard !jumpURL.isEmpty else { return nil }
            return DynamicBody(
                link: BiliDynamicLink(
                    title: string(common, "title"),
                    url: jumpURL,
                    coverURL: normalizedURL(string(common, "cover")),
                    desc: desc
                )
            )
        default:
            return nil
        }
    }

    private nonisolated static func parseAdditionalUgcVideo(
        _ ugc: [String: Any],
        modules: [String: Any]
    ) -> BiliVideo? {
        let bvid = string(ugc, "bvid")
        guard !bvid.isEmpty else { return nil }
        let author = modules["module_author"] as? [String: Any]
        return BiliVideo(
            id: bvid,
            bvid: bvid,
            aid: int64(ugc, "aid"),
            title: string(ugc, "title"),
            coverURL: normalizedURL(string(ugc, "cover")),
            authorName: author.map { string($0, "name") } ?? "",
            authorFaceURL: normalizedURL(author.map { string($0, "face") } ?? ""),
            authorMid: author.map { int64($0, "mid") } ?? 0,
            viewCount: looseCount(string(ugc, "play")),
            danmakuCount: 0,
            likeCount: 0,
            duration: parseDurationText(string(ugc, "duration_text")),
            description: "",
            cid: 0
        )
    }

    private nonisolated static func parseDynamicItemFallback(
        item: [String: Any],
        modules: [String: Any]
    ) -> DynamicBody? {
        if let moduleDynamic = modules["module_dynamic"] as? [String: Any],
           let ugc = moduleDynamic["additional"] as? [String: Any],
           let ugcBody = ugc["ugc"] as? [String: Any],
           let video = parseAdditionalUgcVideo(ugcBody, modules: modules) {
            return DynamicBody(video: video)
        }

        if let moduleDynamic = modules["module_dynamic"] as? [String: Any],
           let major = moduleDynamic["major"] as? [String: Any], !major.isEmpty {
            let inferred = parseDynamicMajor(major, modules: modules)
            if inferred.video != nil || !inferred.imageURLs.isEmpty || inferred.link != nil {
                return inferred
            }
        }

        return nil
    }

    private nonisolated static func shouldShowDynamicLink(
        text: String,
        link: BiliDynamicLink,
        imageURLs: [URL]
    ) -> Bool {
        let linkText = [link.title, link.desc].filter { !$0.isEmpty }.joined(separator: "\n")
        if linkText.isEmpty, link.coverURL == nil { return false }
        if !imageURLs.isEmpty {
            if !text.isEmpty {
                if !link.desc.isEmpty, isDuplicateDynamicText(text, link.desc) { return false }
                if !linkText.isEmpty, isDuplicateDynamicText(text, linkText) { return false }
            }
            if link.coverURL != nil, link.title.isEmpty { return false }
        }
        if text.isEmpty { return true }
        if linkText.isEmpty { return link.coverURL != nil && imageURLs.isEmpty }
        return !isDuplicateDynamicText(text, linkText)
    }

    private nonisolated static func normalizeJumpURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.hasPrefix("//") { return "https:\(trimmed)" }
        return trimmed
    }

    private nonisolated static func parseDynamicDesc(_ modules: [String: Any]) -> DynamicRichText {
        let moduleDynamic = modules["module_dynamic"] as? [String: Any]
        let descRich = parseDynamicRichText(moduleDynamic?["desc"] as? [String: Any])
        if !descRich.text.isEmpty || !descRich.emoticons.isEmpty {
            return descRich
        }
        if let moduleDesc = modules["module_desc"] as? [String: Any] {
            let rich = parseDynamicRichText(moduleDesc["text"] as? [String: Any])
            if !rich.text.isEmpty || !rich.emoticons.isEmpty {
                return rich
            }
        }
        return DynamicRichText()
    }

    private nonisolated static func parseDynamicRichText(_ obj: [String: Any]?) -> DynamicRichText {
        guard let obj else { return DynamicRichText() }
        var emoticons = parseEmoteMap(obj)
        if let nodes = obj["rich_text_nodes"] as? [[String: Any]], !nodes.isEmpty {
            var textBuilder = ""
            for node in nodes {
                let nodeType = string(node, "type")
                if nodeType == "RICH_TEXT_NODE_TYPE_EMOJI" {
                    let phrase = string(node, "text")
                        .ifEmpty(string(node, "orig_text"))
                        .ifEmpty(string((node["emoji"] as? [String: Any]) ?? [:], "text"))
                    let url = normalizedURL(string((node["emoji"] as? [String: Any]) ?? [:], "icon_url"))?.absoluteString ?? ""
                    if !phrase.isEmpty, !url.isEmpty {
                        emoticons[phrase] = url
                    }
                    if !phrase.isEmpty {
                        textBuilder += phrase
                    }
                } else if nodeType != "RICH_TEXT_NODE_TYPE_IMAGE" {
                    textBuilder += string(node, "text").ifEmpty(string(node, "orig_text"))
                }
            }
            return DynamicRichText(text: textBuilder.trimmingCharacters(in: .whitespacesAndNewlines), emoticons: emoticons)
        }
        return DynamicRichText(text: string(obj, "text").trimmingCharacters(in: .whitespacesAndNewlines), emoticons: emoticons)
    }

    private nonisolated static func parseRichTextImages(_ obj: [String: Any]?) -> [URL] {
        guard let nodes = obj?["rich_text_nodes"] as? [[String: Any]] else { return [] }
        return nodes.compactMap { node -> URL? in
            guard string(node, "type") == "RICH_TEXT_NODE_TYPE_IMAGE" else { return nil }
            return normalizedURL(string(node, "url").ifEmpty(string(node, "src")))
        }
    }

    private nonisolated static func parseDynamicMajor(_ major: [String: Any], modules: [String: Any]) -> DynamicBody {
        let majorType = inferDynamicMajorType(major)
        var text = ""
        var emoticons: [String: String] = [:]
        var video: BiliVideo?
        var imageURLs: [URL] = []
        var link: BiliDynamicLink?

        switch majorType {
        case "MAJOR_TYPE_ARCHIVE":
            video = parseDynamicArchiveVideo(major, modules: modules)
            if video == nil {
                link = parseDynamicArchiveLink(major)
            }
        case "MAJOR_TYPE_DRAW":
            imageURLs = parseDynamicDrawImages(major)
        case "MAJOR_TYPE_OPUS":
            let opus = major["opus"] as? [String: Any]
            let summaryRich = parseDynamicRichText(opus?["summary"] as? [String: Any])
            text = summaryRich.text
            emoticons = summaryRich.emoticons
            imageURLs = parseDynamicOpusImages(major)
            if imageURLs.isEmpty {
                imageURLs = parseRichTextImages(opus?["summary"] as? [String: Any])
            }
            let opusTitle = string(opus ?? [:], "title")
            if text.isEmpty, !opusTitle.isEmpty {
                text = opusTitle
            }
            if imageURLs.isEmpty {
                link = parseDynamicGenericLink(major, majorType: majorType)
            }
            let jumpURL = normalizeJumpURL(string(opus ?? [:], "jump_url"))
            if let bvid = extractBvid(from: jumpURL), !bvid.isEmpty {
                let author = modules["module_author"] as? [String: Any]
                video = BiliVideo(
                    id: bvid,
                    bvid: bvid,
                    aid: 0,
                    title: opusTitle,
                    coverURL: imageURLs.first,
                    authorName: author.map { string($0, "name") } ?? "",
                    authorFaceURL: normalizedURL(author.map { string($0, "face") } ?? ""),
                    authorMid: author.map { int64($0, "mid") } ?? 0,
                    viewCount: 0,
                    danmakuCount: 0,
                    likeCount: 0,
                    duration: 0,
                    description: "",
                    cid: 0
                )
                link = nil
            }
        case "MAJOR_TYPE_LIVE_RCMD":
            let liveContent = string((major["live_rcmd"] as? [String: Any]) ?? [:], "content")
            if let liveJSON = liveContent.data(using: .utf8),
               let live = try? JSONSerialization.jsonObject(with: liveJSON) as? [String: Any] {
                link = parseDynamicLiveLink(live)
            }
        case "MAJOR_TYPE_LIVE":
            link = parseDynamicLiveLink(major["live"] as? [String: Any])
        case "MAJOR_TYPE_MUSIC":
            link = parseDynamicMusicLink(major["music"] as? [String: Any])
        case "MAJOR_TYPE_NONE":
            text = string((major["none"] as? [String: Any]) ?? [:], "tips")
        default:
            link = parseDynamicGenericLink(major, majorType: majorType)
        }

        return DynamicBody(text: text, emoticons: emoticons, video: video, imageURLs: imageURLs, link: link)
    }

    private nonisolated static func inferDynamicMajorType(_ major: [String: Any]) -> String {
        let explicit = string(major, "type")
        if !explicit.isEmpty { return explicit }
        if major["archive"] != nil { return "MAJOR_TYPE_ARCHIVE" }
        if major["draw"] != nil { return "MAJOR_TYPE_DRAW" }
        if major["opus"] != nil { return "MAJOR_TYPE_OPUS" }
        if major["article"] != nil { return "MAJOR_TYPE_ARTICLE" }
        if major["live"] != nil { return "MAJOR_TYPE_LIVE" }
        return "MAJOR_TYPE_NONE"
    }

    private nonisolated static func parseDynamicArchiveVideo(_ major: [String: Any], modules: [String: Any]) -> BiliVideo? {
        guard let archive = major["archive"] as? [String: Any] else { return nil }
        let bvid = string(archive, "bvid")
        guard !bvid.isEmpty else { return nil }
        let author = modules["module_author"] as? [String: Any]
        let stat = archive["stat"] as? [String: Any] ?? [:]
        let cntInfo = archive["cnt_info"] as? [String: Any] ?? [:]
        let like = (modules["module_stat"] as? [String: Any])?["like"] as? [String: Any] ?? [:]
        return BiliVideo(
            id: bvid,
            bvid: bvid,
            aid: int64(archive, "aid"),
            title: string(archive, "title"),
            coverURL: normalizedURL(string(archive, "cover")),
            authorName: author.map { string($0, "name") } ?? "",
            authorFaceURL: normalizedURL(author.map { string($0, "face") } ?? ""),
            authorMid: author.map { int64($0, "mid") } ?? 0,
            viewCount: parseArchiveStatCount(stat, "play", "view")
                .ifZero(parseArchiveStatCount(cntInfo, "play", "view")),
            danmakuCount: parseArchiveStatCount(stat, "danmaku", "video_review", "dm")
                .ifZero(parseArchiveStatCount(cntInfo, "danmaku", "video_review", "dm")),
            likeCount: int64(like, "count"),
            duration: parseDurationText(string(archive, "duration_text")),
            description: string(archive, "desc"),
            cid: 0
        )
    }

    private nonisolated static func parseDynamicArchiveLink(_ major: [String: Any]) -> BiliDynamicLink? {
        guard let archive = major["archive"] as? [String: Any] else { return nil }
        let jumpURL = string(archive, "jump_url")
        guard !jumpURL.isEmpty else { return nil }
        return BiliDynamicLink(
            title: string(archive, "title"),
            url: jumpURL,
            coverURL: normalizedURL(string(archive, "cover")),
            desc: string(archive, "desc")
        )
    }

    private nonisolated static func parseDynamicDrawImages(_ major: [String: Any]) -> [URL] {
        guard let items = (major["draw"] as? [String: Any])?["items"] as? [[String: Any]] else { return [] }
        return items.compactMap { normalizedURL(string($0, "src").ifEmpty(string($0, "url"))) }
    }

    private nonisolated static func parseDynamicOpusImages(_ major: [String: Any]) -> [URL] {
        guard let pics = (major["opus"] as? [String: Any])?["pics"] as? [[String: Any]] else { return [] }
        return pics.compactMap { normalizedURL(string($0, "url").ifEmpty(string($0, "src"))) }
    }

    private nonisolated static func parseDynamicLiveLink(_ live: [String: Any]?) -> BiliDynamicLink? {
        guard let live else { return nil }
        let url = normalizeJumpURL(string(live, "jump_url"))
        guard !url.isEmpty else { return nil }
        return BiliDynamicLink(
            title: string(live, "title"),
            url: url,
            coverURL: normalizedURL(string(live, "cover")),
            desc: ""
        )
    }

    private nonisolated static func parseDynamicMusicLink(_ music: [String: Any]?) -> BiliDynamicLink? {
        guard let music else { return nil }
        let url = normalizeJumpURL(string(music, "jump_url"))
        guard !url.isEmpty else { return nil }
        return BiliDynamicLink(
            title: string(music, "title"),
            url: url,
            coverURL: normalizedURL(string(music, "cover")),
            desc: string(music, "desc")
        )
    }

    private nonisolated static func extractBvid(from url: String) -> String? {
        guard !url.isEmpty else { return nil }
        if let range = url.range(of: #"BV[0-9A-Za-z]+"#, options: .regularExpression) {
            return String(url[range])
        }
        return nil
    }

    private nonisolated static func parseDynamicGenericLink(_ major: [String: Any], majorType: String) -> BiliDynamicLink? {
        switch majorType {
        case "MAJOR_TYPE_ARTICLE":
            guard let article = major["article"] as? [String: Any] else { return nil }
            let url = string(article, "jump_url")
            guard !url.isEmpty else { return nil }
            return BiliDynamicLink(
                title: string(article, "title"),
                url: url,
                coverURL: normalizedURL(string(article, "covers").split(separator: ",").first.map(String.init) ?? ""),
                desc: string(article, "desc")
            )
        case "MAJOR_TYPE_LIVE":
            guard let live = major["live"] as? [String: Any] else { return nil }
            let url = string(live, "jump_url")
            guard !url.isEmpty else { return nil }
            return BiliDynamicLink(
                title: string(live, "title"),
                url: url,
                coverURL: normalizedURL(string(live, "cover")),
                desc: ""
            )
        default:
            return nil
        }
    }

    private nonisolated static func parseModuleAuthorName(_ modules: [String: Any]) -> String {
        let author = modules["module_author"] as? [String: Any] ?? [:]
        return string(author, "name").ifEmpty(string(author, "uname"))
    }

    private nonisolated static func parseDynamicStatCount(_ stat: [String: Any]?, key: String) -> Int64 {
        guard let bucket = stat?[key] as? [String: Any] else { return 0 }
        return int64(bucket, "count").ifZero(looseCount(string(bucket, "count")))
    }

    private nonisolated static func mergeDynamicText(_ parts: String...) -> String {
        parts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func isDuplicateDynamicText(_ primary: String, _ secondary: String) -> Bool {
        let a = primary.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = secondary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        let compactA = a.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        let compactB = b.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        if compactA == compactB { return true }
        return compactA.contains(compactB) || compactB.contains(compactA)
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
