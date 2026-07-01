import CryptoKit
import Foundation

actor BilibiliAPI {
    private var mixinKey: String?
    private var guestBuvid3: String?
    private var guestBuvid4: String?

    func httpCookieHeader(credential: BilibiliCredential?) async -> String {
        await buildCookieHeader(credential: credential) ?? ""
    }

    func homeRecommend(
        credential: BilibiliCredential? = nil,
        freshIdx: Int = 1,
        fetchRow: Int = 1,
        lastShowList: String = "",
        pageSize: Int = 30
    ) async throws -> BiliHomeRecommendPage {
        var params: [String: String] = [
            "fresh_type": "4",
            "ps": "\(min(max(pageSize, 1), 30))",
            "fresh_idx": "\(freshIdx)",
            "fresh_idx_1h": "\(freshIdx)",
            "brush": "\(freshIdx)",
            "fetch_row": "\(fetchRow)",
            "web_location": "1430650"
        ]
        if !lastShowList.isEmpty {
            params["last_showlist"] = lastShowList
        }
        let json = try await wbiJSON(
            url: "https://api.bilibili.com/x/web-interface/wbi/index/top/feed/rcmd",
            params: params,
            credential: credential
        )
        return JSONParser.parseHomeRecommendPage(from: json, freshIdx: freshIdx, fetchRow: fetchRow)
    }

    func popular(credential: BilibiliCredential? = nil) async throws -> [BiliVideo] {
        let json = try await json(
            url: "https://api.bilibili.com/x/web-interface/popular",
            params: ["ps": "30", "pn": "1"],
            credential: credential
        )
        return JSONParser.parseVideos(from: json, preferredArrayKeys: ["list"])
    }

    func ranking(credential: BilibiliCredential? = nil) async throws -> [BiliVideo] {
        let json = try await wbiJSON(
            url: "https://api.bilibili.com/x/web-interface/ranking/v2",
            params: ["rid": "0", "type": "all", "web_location": "333.934"],
            credential: credential
        )
        return JSONParser.parseVideos(from: json, preferredArrayKeys: ["list"])
    }

    func searchVideos(
        keyword: String,
        page: Int = 1,
        credential: BilibiliCredential? = nil
    ) async throws -> BiliSearchPage<BiliVideo> {
        let params: [String: String] = [
            "search_type": "video",
            "keyword": keyword,
            "page": "\(max(1, page))",
            "order": "totalrank",
            "duration": "0",
            "tids": "0"
        ]
        let json = try await wbiJSON(
            url: "https://api.bilibili.com/x/web-interface/wbi/search/type",
            params: params,
            credential: credential,
            referer: "https://search.bilibili.com/video?keyword=\(keyword.urlQueryEscaped)"
        )
        return JSONParser.parseSearchVideoPage(from: json)
    }

    func searchUsers(
        keyword: String,
        page: Int = 1,
        credential: BilibiliCredential? = nil
    ) async throws -> BiliSearchPage<BiliSearchUser> {
        let params: [String: String] = [
            "search_type": "bili_user",
            "keyword": keyword,
            "page": "\(max(1, page))",
            "order": "0",
            "user_type": "0"
        ]
        let json = try await wbiJSON(
            url: "https://api.bilibili.com/x/web-interface/wbi/search/type",
            params: params,
            credential: credential,
            referer: "https://search.bilibili.com/upuser?keyword=\(keyword.urlQueryEscaped)"
        )
        return JSONParser.parseSearchUserPage(from: json)
    }

    func hotSearchItems(limit: Int = 30) async throws -> [BiliHotSearchItem] {
        let json = try await json(
            url: "https://s.search.bilibili.com/main/hotword",
            params: ["limit": "\(max(1, limit))"],
            referer: BilibiliEndpoints.home
        )
        return JSONParser.parseHotSearchItems(from: json)
    }

    func searchSuggest(term: String) async throws -> [String] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let json = try await jsonAllowNonZero(
            url: "https://s.search.bilibili.com/main/suggest",
            params: [
                "term": trimmed,
                "main_ver": "v1",
                "func": "suggest",
                "highlight": "",
                "suggest_type": "accurate",
                "sub_type": "tag",
                "userid": "-1"
            ],
            referer: "https://search.bilibili.com"
        )
        return JSONParser.parseSearchSuggest(from: json)
    }

    func liveRooms(credential: BilibiliCredential? = nil) async throws -> [BiliLiveRoom] {
        let json = try await wbiJSON(
            url: "https://api.live.bilibili.com/xlive/web-interface/v1/second/getList",
            params: [
                "platform": "web",
                "parent_area_id": "0",
                "area_id": "0",
                "page": "1"
            ],
            credential: credential
        )
        return JSONParser.parseLiveRooms(from: json)
    }

    func validate(credential: BilibiliCredential) async throws -> BiliAccount {
        let nav = try await json(
            url: "https://api.bilibili.com/x/web-interface/nav",
            params: [:],
            credential: credential
        )
        guard let account = JSONParser.parseAccount(from: nav, credential: credential) else {
            throw APIError.message("登录信息无效，请重新登录")
        }
        return account
    }

    func validate(cookieText: String) async throws -> BiliAccount {
        try await validate(credential: BilibiliCredential(cookieText: cookieText))
    }

    func myProfile(account: BiliAccount) async throws -> BiliUserProfile {
        let info = try await json(
            url: "https://api.bilibili.com/x/space/myinfo",
            params: [:],
            credential: account.credential
        )
        var profile = JSONParser.parseProfile(from: info, fallback: account)
        let nav = try? await json(
            url: "https://api.bilibili.com/x/web-interface/nav",
            params: [:],
            credential: account.credential
        )
        if let nav {
            profile = JSONParser.parseWallet(from: nav, profile: profile)
        }
        guard let profile else {
            throw APIError.message("无法读取用户资料")
        }
        return profile
    }

    func userSign(mid: Int64, credential: BilibiliCredential? = nil) async -> String {
        let referer = "https://space.bilibili.com/\(mid)"
        let cardJSON = try? await json(
            url: "https://api.bilibili.com/x/web-interface/card",
            params: ["mid": "\(mid)", "photo": "true"],
            credential: credential,
            referer: referer
        )
        if let sign = cardJSON.flatMap({ JSONParser.parseUserCardProfile(from: $0) })?.sign
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !sign.isEmpty {
            return sign
        }
        let accJSON = try? await wbiJSON(
            url: "https://api.bilibili.com/x/space/wbi/acc/info",
            params: ["mid": "\(mid)"],
            credential: credential,
            referer: referer
        )
        return accJSON.flatMap { JSONParser.parseUserAccInfo(from: $0) }?.sign ?? ""
    }

    func userProfile(mid: Int64, credential: BilibiliCredential? = nil) async throws -> BiliUserProfile {
        let referer = "https://space.bilibili.com/\(mid)"
        let accJSON = try? await wbiJSON(
            url: "https://api.bilibili.com/x/space/wbi/acc/info",
            params: ["mid": "\(mid)"],
            credential: credential,
            referer: referer
        )
        let cardJSON = try? await json(
            url: "https://api.bilibili.com/x/web-interface/card",
            params: ["mid": "\(mid)", "photo": "true"],
            credential: credential,
            referer: referer
        )
        let upstatJSON = try? await json(
            url: "https://api.bilibili.com/x/space/upstat",
            params: ["mid": "\(mid)"],
            credential: credential,
            referer: referer
        )
        let navnumJSON = try? await json(
            url: "https://api.bilibili.com/x/space/navnum",
            params: ["mid": "\(mid)"],
            credential: credential,
            referer: referer
        )
        let topPhotoJSON = try? await jsonAllowNonZero(
            url: "https://space.bilibili.com/ajax/topphoto/getlist",
            params: ["mid": "\(mid)"],
            credential: credential,
            referer: referer
        )

        let acc = accJSON.flatMap { JSONParser.parseUserAccInfo(from: $0) }
        let card = cardJSON.flatMap { JSONParser.parseUserCardProfile(from: $0) }
        let likes = upstatJSON.map { JSONParser.parseUserUpstatLikes(from: $0) } ?? 0
        let videoCount = navnumJSON.map { JSONParser.parseUserNavnum(from: $0) } ?? 0
        let topPhotos = topPhotoJSON.map { JSONParser.parseUserTopPhotoList(from: $0) } ?? []

        guard let profile = JSONParser.mergeSpaceProfile(
            acc: acc,
            card: card,
            mid: mid,
            likes: likes,
            videoCount: videoCount,
            extraTopPhotoURLs: topPhotos
        ) else {
            throw APIError.message("无法加载用户资料")
        }
        return profile
    }

    func userVideos(
        mid: Int64,
        page: Int = 1,
        order: BiliUserVideoSort = .latestPublish,
        credential: BilibiliCredential? = nil
    ) async throws -> BiliUserVideoPage {
        let params: [String: String] = [
            "mid": "\(mid)",
            "ps": "30",
            "tid": "0",
            "pn": "\(max(1, page))",
            "keyword": "",
            "order": order.orderValue,
            "order_avoided": "true",
            "platform": "web"
        ]
        let json = try await wbiJSON(
            url: "https://api.bilibili.com/x/space/wbi/arc/search",
            params: params,
            credential: credential,
            referer: "https://space.bilibili.com/\(mid)"
        )
        return JSONParser.parseUserVideoPage(from: json)
    }

    func userRelation(mid: Int64, credential: BilibiliCredential) async throws -> BiliAuthorRelation {
        let json = try await json(
            url: "https://api.bilibili.com/x/relation",
            params: ["fid": "\(mid)"],
            credential: credential,
            referer: "https://space.bilibili.com/\(mid)"
        )
        return JSONParser.parseUserRelation(from: json)
    }

    func modifyFollow(mid: Int64, follow: Bool, credential: BilibiliCredential) async throws {
        _ = try await postForm(
            url: "https://api.bilibili.com/x/relation/modify",
            form: [
                "fid": "\(mid)",
                "act": follow ? "1" : "2",
                "re_src": "11",
                "csrf": credential.biliJct
            ],
            credential: credential,
            referer: "https://space.bilibili.com/\(mid)"
        )
    }

    func followingFeed(credential: BilibiliCredential, offset: String? = nil) async throws -> BiliFollowingFeedPage {
        var params: [String: String] = [
            "timezone_offset": "-480",
            "type": "video",
            "platform": "web",
            "gaia_source": "main_web",
            "web_location": "333.1365",
            "features": "itemOpusStyle,listOnlyfans,opusBigCover,onlyfansVote,forwardListHidden,decorationCard,commentsNewVersion,onlyfansAssetsV2,ugcDelete,onlyfansQaCard,endFooterHidden"
        ]
        if let offset, !offset.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            params["offset"] = offset
        }
        let json = try await json(
            url: "https://api.bilibili.com/x/polymer/web-dynamic/v1/feed/all",
            params: params,
            credential: credential,
            referer: "https://t.bilibili.com/",
            extraHeaders: dynamicRequestHeaders()
        )
        return JSONParser.parseFollowingVideoFeed(from: json)
    }

    func reportWatchHistory(
        aid: Int64,
        cid: Int64,
        progressSeconds: Int64,
        credential: BilibiliCredential
    ) async throws -> Bool {
        guard aid > 0, cid > 0 else { return false }
        _ = try await postForm(
            url: BilibiliEndpoints.historyReport,
            form: [
                "aid": "\(aid)",
                "cid": "\(cid)",
                "progress": "\(max(0, progressSeconds))",
                "platform": "web",
                "csrf": credential.biliJct
            ],
            credential: credential
        )
        return true
    }

    func history(credential: BilibiliCredential) async throws -> [BiliHistoryItem] {
        let json = try await json(
            url: "https://api.bilibili.com/x/web-interface/history/cursor",
            params: [
                "max": "0",
                "view_at": "0",
                "business": "",
                "type": "archive",
                "ps": "30"
            ],
            credential: credential,
            referer: "https://www.bilibili.com/account/history"
        )
        return JSONParser.parseHistory(from: json)
    }

    func videoDetail(bvid: String, credential: BilibiliCredential? = nil) async throws -> BiliVideoDetail {
        let referer = "https://www.bilibili.com/video/\(bvid)"
        let json = try await self.json(
            url: "https://api.bilibili.com/x/web-interface/view",
            params: ["bvid": bvid],
            credential: credential,
            referer: referer
        )
        guard let detail = JSONParser.parseVideoDetail(from: json) else {
            throw APIError.message("无法读取视频详情")
        }
        return detail
    }

    func videoTags(aid: Int64, credential: BilibiliCredential? = nil) async throws -> [String] {
        guard aid > 0 else { return [] }
        let json = try await self.json(
            url: "https://api.bilibili.com/x/tag/archive/tags",
            params: ["aid": "\(aid)"],
            credential: credential,
            referer: BilibiliEndpoints.home
        )
        return JSONParser.parseVideoTags(from: json)
    }

    func videoOnlineCount(
        bvid: String,
        aid: Int64,
        cid: Int64,
        credential: BilibiliCredential? = nil
    ) async -> Int64 {
        guard !bvid.isEmpty, cid > 0 else { return 0 }
        let referer = "https://www.bilibili.com/video/\(bvid)"
        guard let json = try? await self.json(
            url: "https://api.bilibili.com/x/player/online/total",
            params: [
                "bvid": bvid,
                "aid": "\(aid)",
                "cid": "\(cid)"
            ],
            credential: credential,
            referer: referer
        ) else {
            return 0
        }
        return JSONParser.parseOnlineCount(from: json)
    }

    func videoRelation(
        bvid: String,
        aid: Int64,
        credential: BilibiliCredential? = nil
    ) async throws -> BiliVideoRelation {
        guard !bvid.isEmpty || aid > 0 else { return BiliVideoRelation() }

        var builtParams: [String: String] = [:]
        if !bvid.isEmpty { builtParams["bvid"] = bvid }
        if aid > 0 { builtParams["aid"] = "\(aid)" }
        let params = builtParams
        let referer = "https://www.bilibili.com/video/\(bvid)"

        async let relation = fetchArchiveRelation(
            params: params,
            credential: credential,
            referer: referer
        )

        guard let credential else {
            return try await relation
        }

        async let liked = fetchHasLike(
            params: params,
            credential: credential,
            referer: referer
        )
        async let favored = fetchFavoured(
            bvid: bvid,
            aid: aid,
            credential: credential,
            referer: referer
        )

        return JSONParser.mergeVideoRelations([
            try await relation,
            BiliVideoRelation(liked: try await liked, favorited: try await favored)
        ])
    }

    private func fetchArchiveRelation(
        params: [String: String],
        credential: BilibiliCredential?,
        referer: String
    ) async throws -> BiliVideoRelation {
        let json = try await json(
            url: "https://api.bilibili.com/x/web-interface/archive/relation",
            params: params,
            credential: credential,
            referer: referer
        )
        return JSONParser.parseVideoArchiveRelation(from: json)
    }

    private func fetchHasLike(
        params: [String: String],
        credential: BilibiliCredential,
        referer: String
    ) async throws -> Bool {
        let json = try await json(
            url: "https://api.bilibili.com/x/web-interface/archive/has/like",
            params: params,
            credential: credential,
            referer: referer
        )
        return JSONParser.parseHasLike(from: json)
    }

    private func fetchFavoured(
        bvid: String,
        aid: Int64,
        credential: BilibiliCredential,
        referer: String
    ) async throws -> Bool {
        var favoredParams: [String: String] = [:]
        if aid > 0 {
            favoredParams["aid"] = "\(aid)"
        } else if !bvid.isEmpty {
            favoredParams["aid"] = bvid
        }
        guard !favoredParams.isEmpty else { return false }
        let json = try await json(
            url: "https://api.bilibili.com/x/v2/fav/video/favoured",
            params: favoredParams,
            credential: credential,
            referer: referer
        )
        return JSONParser.parseVideoFavoured(from: json)
    }

    func likeVideo(
        bvid: String,
        aid: Int64,
        like: Bool,
        credential: BilibiliCredential
    ) async throws {
        guard !credential.biliJct.isEmpty else {
            throw APIError.message("登录凭证无效，请重新登录")
        }
        var form = videoActionForm(bvid: bvid, aid: aid, csrf: credential.biliJct)
        form["like"] = like ? "1" : "2"
        _ = try await postForm(
            url: "https://api.bilibili.com/x/web-interface/archive/like",
            form: form,
            credential: credential,
            referer: "https://www.bilibili.com/video/\(bvid)"
        )
    }

    func coinVideo(
        bvid: String,
        aid: Int64,
        multiply: Int,
        credential: BilibiliCredential
    ) async throws {
        guard !credential.biliJct.isEmpty else {
            throw APIError.message("登录凭证无效，请重新登录")
        }
        var form = videoActionForm(bvid: bvid, aid: aid, csrf: credential.biliJct)
        form["multiply"] = "\(min(max(multiply, 1), 2))"
        form["select_like"] = "0"
        _ = try await postForm(
            url: "https://api.bilibili.com/x/web-interface/coin/add",
            form: form,
            credential: credential,
            referer: "https://www.bilibili.com/video/\(bvid)"
        )
    }

    func tripleVideo(
        bvid: String,
        aid: Int64,
        credential: BilibiliCredential
    ) async throws -> BiliVideoTripleResult {
        guard !credential.biliJct.isEmpty else {
            throw APIError.message("登录凭证无效，请重新登录")
        }
        let form = videoActionForm(bvid: bvid, aid: aid, csrf: credential.biliJct)
        let json = try await postForm(
            url: "https://api.bilibili.com/x/web-interface/archive/like/triple",
            form: form,
            credential: credential,
            referer: "https://www.bilibili.com/video/\(bvid)"
        )
        return JSONParser.parseVideoTripleResult(from: json)
    }

    func shareVideo(
        bvid: String,
        aid: Int64,
        credential: BilibiliCredential?
    ) async throws {
        guard let credential, !credential.biliJct.isEmpty else { return }
        let form = videoActionForm(bvid: bvid, aid: aid, csrf: credential.biliJct)
        _ = try await postForm(
            url: "https://api.bilibili.com/x/web-interface/share/add",
            form: form,
            credential: credential,
            referer: "https://www.bilibili.com/video/\(bvid)"
        )
    }

    func modifyVideoFavorite(
        bvid: String,
        aid: Int64,
        add: Bool,
        credential: BilibiliCredential
    ) async throws {
        guard !credential.biliJct.isEmpty else {
            throw APIError.message("登录凭证无效，请重新登录")
        }
        guard let folderID = try await defaultFavoriteFolderId(credential: credential) else {
            throw APIError.message("未找到收藏夹")
        }
        let form: [String: String] = [
            "rid": "\(aid)",
            "type": "2",
            "add_media_ids": add ? "\(folderID)" : "",
            "del_media_ids": add ? "" : "\(folderID)",
            "csrf": credential.biliJct
        ]
        _ = try await postForm(
            url: "https://api.bilibili.com/x/v3/fav/resource/deal",
            form: form,
            credential: credential,
            referer: "https://www.bilibili.com/video/\(bvid)"
        )
    }

    private func defaultFavoriteFolderId(credential: BilibiliCredential) async throws -> Int64? {
        let json = try await json(
            url: "https://api.bilibili.com/x/v3/fav/folder/created/list-all",
            params: [
                "up_mid": credential.dedeUserId,
                "type": "2"
            ],
            credential: credential,
            referer: BilibiliEndpoints.home
        )
        return JSONParser.parseDefaultFavoriteFolderId(from: json)
    }

    func favoriteVideos(
        page: Int = 1,
        pageSize: Int = 20,
        credential: BilibiliCredential
    ) async throws -> BiliFavoriteVideoPage {
        guard let folderID = try await defaultFavoriteFolderId(credential: credential) else {
            throw APIError.message("未找到收藏夹")
        }

        let safePage = max(1, page)
        let safePageSize = min(20, max(1, pageSize))
        let json = try await json(
            url: "https://api.bilibili.com/x/v3/fav/resource/list",
            params: [
                "media_id": "\(folderID)",
                "platform": "web",
                "type": "0",
                "order": "mtime",
                "pn": "\(safePage)",
                "ps": "\(safePageSize)"
            ],
            credential: credential,
            referer: BilibiliEndpoints.home
        )
        return JSONParser.parseFavoriteVideoPage(from: json, page: safePage, pageSize: safePageSize)
    }

    private func videoActionForm(bvid: String, aid: Int64, csrf: String) -> [String: String] {
        var form: [String: String] = [
            "csrf": csrf,
            "eab_x": "2",
            "ramval": "0",
            "source": "web_normal",
            "ga": "1",
            "dyn": "2"
        ]
        if !bvid.isEmpty { form["bvid"] = bvid }
        if aid > 0 { form["aid"] = "\(aid)" }
        return form
    }

    func playURL(bvid: String, cid: Int64, credential: BilibiliCredential? = nil) async throws -> BiliPlayStream {
        let primary = try await requestPlayURL(
            bvid: bvid,
            cid: cid,
            fnval: "4048",
            credential: credential
        )
        if primary.isAVPlayerCompatible {
            return primary
        }

        for fnval in ["1", "16"] {
            if let fallback = try? await requestPlayURL(
                bvid: bvid,
                cid: cid,
                fnval: fnval,
                credential: credential
            ), fallback.isAVPlayerCompatible {
                return fallback
            }
        }

        throw APIError.message("当前视频格式暂不支持播放，请稍后重试")
    }

    private func requestPlayURL(
        bvid: String,
        cid: Int64,
        fnval: String,
        credential: BilibiliCredential?
    ) async throws -> BiliPlayStream {
        let params: [String: String] = [
            "bvid": bvid,
            "cid": "\(cid)",
            "qn": "80",
            "fnval": fnval,
            "fnver": "0",
            "fourk": "1",
            "otype": "json",
            "platform": "pc"
        ]
        let json = try await wbiJSON(
            url: "https://api.bilibili.com/x/player/wbi/playurl",
            params: params,
            credential: credential,
            referer: BilibiliEndpoints.home
        )
        guard var stream = JSONParser.parsePlayStream(from: json) else {
            throw APIError.message("无法获取播放地址")
        }
        stream = BiliPlayStream(
            videoURL: stream.videoURL,
            audioURL: stream.audioURL,
            aid: stream.aid,
            cid: cid
        )
        return stream
    }

    func videoComments(
        aid: Int64,
        bvid: String,
        sort: BiliCommentSort,
        cursor: String? = nil,
        credential: BilibiliCredential? = nil
    ) async throws -> BiliCommentPage {
        var params: [String: String] = [
            "oid": "\(aid)",
            "type": "1",
            "mode": "\(sort.mode)",
            "plat": "1",
            "web_location": "1315875"
        ]
        params["pagination_str"] = buildCommentPaginationStr(cursor: cursor)
        let json = try await wbiJSON(
            url: "https://api.bilibili.com/x/v2/reply/wbi/main",
            params: params,
            credential: credential,
            referer: videoCommentReferer(bvid: bvid, aid: aid)
        )
        return JSONParser.parseCommentPage(from: json)
    }

    func commentReplies(
        aid: Int64,
        rootID: Int64,
        bvid: String,
        page: Int,
        credential: BilibiliCredential? = nil
    ) async throws -> BiliCommentReplyPage {
        let json = try await json(
            url: "https://api.bilibili.com/x/v2/reply/reply",
            params: [
                "type": "1",
                "oid": "\(aid)",
                "root": "\(rootID)",
                "pn": "\(page)",
                "ps": "20",
                "web_location": "1315875"
            ],
            credential: credential,
            referer: videoPageReferer(bvid: bvid, aid: aid)
        )
        return JSONParser.parseCommentReplyPage(from: json)
    }

    func danmakuList(
        cid: Int64,
        durationSeconds: Int = 0,
        credential: BilibiliCredential? = nil,
        referer: String = BilibiliEndpoints.home
    ) async throws -> [BiliDanmakuItem] {
        guard cid > 0 else { return [] }
        let segmentCount: Int = {
            if durationSeconds > 0 {
                return min(40, max(1, (durationSeconds + 359) / 360))
            }
            return 12
        }()
        var all: [BiliDanmakuItem] = []
        for segment in 1...segmentCount {
            let parsed = (try? await bytes(
                url: BilibiliEndpoints.danmakuSeg,
                params: [
                    "type": "1",
                    "oid": "\(cid)",
                    "segment_index": "\(segment)"
                ],
                credential: credential,
                referer: referer
            )).map(BilibiliDanmakuParser.parseProtobufSeg) ?? []
            if parsed.isEmpty { break }
            all.append(contentsOf: parsed)
        }
        if !all.isEmpty {
            return all.sorted { $0.timeMs < $1.timeMs }
        }
        let fallback = (try? await bytes(
            url: BilibiliEndpoints.danmakuList,
            params: ["oid": "\(cid)", "type": "1"],
            credential: credential,
            referer: referer
        )).map(BilibiliDanmakuParser.parseListSo) ?? []
        if !fallback.isEmpty {
            return fallback.sorted { $0.timeMs < $1.timeMs }
        }
        let xmlFallback = (try? await bytes(
            url: "\(BilibiliEndpoints.danmakuXML)/\(cid).xml",
            params: [:],
            credential: credential,
            referer: referer
        )).map(BilibiliDanmakuParser.parseListSo) ?? []
        return xmlFallback.sorted { $0.timeMs < $1.timeMs }
    }

    private func videoCommentReferer(bvid: String, aid: Int64) -> String {
        if aid > 0 {
            return "https://www.bilibili.com/video/av\(aid)"
        }
        return videoPageReferer(bvid: bvid, aid: aid)
    }

    private func videoPageReferer(bvid: String, aid: Int64) -> String {
        if !bvid.isEmpty {
            return "https://www.bilibili.com/video/\(bvid)"
        }
        if aid > 0 {
            return "https://www.bilibili.com/video/av\(aid)"
        }
        return BilibiliEndpoints.home
    }

    private func buildCommentPaginationStr(cursor: String?) -> String {
        let offset = cursor?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let data = try? JSONSerialization.data(withJSONObject: ["offset": offset]),
              let text = String(data: data, encoding: .utf8) else {
            return #"{"offset":""}"#
        }
        return text
    }

    private func wbiJSON(
        url: String,
        params: [String: String],
        credential: BilibiliCredential? = nil,
        referer: String = BilibiliEndpoints.home
    ) async throws -> Any {
        var signed = params
        signed.removeValue(forKey: "w_rid")
        signed["wts"] = "\(Int(Date().timeIntervalSince1970))"
        if signed["web_location"] == nil {
            signed["web_location"] = "1550101"
        }
        signed["w_rid"] = WbiSigner.signature(params: signed, mixinKey: try await ensureMixinKey(credential: credential))
        return try await json(url: url, params: signed, credential: credential, referer: referer, wbiEncoded: true)
    }

    private func ensureMixinKey(credential: BilibiliCredential? = nil) async throws -> String {
        if let mixinKey {
            return mixinKey
        }

        let nav = try await json(url: "https://api.bilibili.com/x/web-interface/nav", params: [:], credential: credential)
        guard
            let root = nav as? [String: Any],
            let data = root["data"] as? [String: Any],
            let wbi = data["wbi_img"] as? [String: Any],
            let img = wbi["img_url"] as? String,
            let sub = wbi["sub_url"] as? String
        else {
            throw APIError.message("无法获取 WBI 密钥")
        }

        let key = WbiSigner.mixinKey(imgURL: img, subURL: sub)
        mixinKey = key
        return key
    }

    private func postForm(
        url: String,
        form: [String: String],
        credential: BilibiliCredential,
        referer: String = BilibiliEndpoints.home
    ) async throws -> Any {
        guard let requestURL = URL(string: url) else {
            throw APIError.message("接口地址无效")
        }

        let body = form
            .sorted { $0.key < $1.key }
            .map { "\(BiliURLEncoder.queryComponent($0.key))=\(BiliURLEncoder.queryComponent($0.value))" }
            .joined(separator: "&")

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(BilibiliEndpoints.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue(BilibiliEndpoints.home, forHTTPHeaderField: "Origin")
        if let cookie = await buildCookieHeader(credential: credential) {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.message("网络响应异常")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.message(http.statusCode == 412 ? "请求被 B 站风控拦截，请稍后重试" : "HTTP \(http.statusCode)")
        }

        let object = try JSONSerialization.jsonObject(with: data)
        if let dict = object as? [String: Any], let code = dict["code"] as? Int, code != 0 {
            let message = dict["message"] as? String ?? "请求失败"
            throw APIError.message(message)
        }
        return object
    }

    private func requestURL(base url: String, params: [String: String], wbiEncoded: Bool = false) throws -> URL {
        guard var components = URLComponents(string: url) else {
            throw APIError.message("接口地址无效")
        }
        if !params.isEmpty {
            components.percentEncodedQuery = params
                .sorted { $0.key < $1.key }
                .map {
                    let encode = wbiEncoded ? BiliURLEncoder.wbiComponent : BiliURLEncoder.queryComponent
                    return "\(encode($0.key))=\(encode($0.value))"
                }
                .joined(separator: "&")
        }
        guard let requestURL = components.url else {
            throw APIError.message("接口地址无效")
        }
        return requestURL
    }

    private func jsonAllowNonZero(
        url: String,
        params: [String: String],
        credential: BilibiliCredential? = nil,
        referer: String = BilibiliEndpoints.home
    ) async throws -> Any {
        let requestURL = try requestURL(base: url, params: params)

        var request = URLRequest(url: requestURL)
        request.timeoutInterval = 20
        request.setValue(BilibiliEndpoints.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        if let cookie = await buildCookieHeader(credential: credential) {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.message("网络响应异常")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.message(http.statusCode == 412 ? "请求被 B 站风控拦截，请稍后重试" : "HTTP \(http.statusCode)")
        }

        return try JSONSerialization.jsonObject(with: data)
    }

    private func json(
        url: String,
        params: [String: String],
        credential: BilibiliCredential? = nil,
        referer: String = BilibiliEndpoints.home,
        extraHeaders: [String: String] = [:],
        wbiEncoded: Bool = false
    ) async throws -> Any {
        let requestURL = try requestURL(base: url, params: params, wbiEncoded: wbiEncoded)

        var request = URLRequest(url: requestURL)
        request.timeoutInterval = 20
        request.setValue(BilibiliEndpoints.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        extraHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        if let cookie = await buildCookieHeader(credential: credential) {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.message("网络响应异常")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.message(http.statusCode == 412 ? "请求被 B 站风控拦截，请稍后重试" : "HTTP \(http.statusCode)")
        }

        let object = try JSONSerialization.jsonObject(with: data)
        if let dict = object as? [String: Any], let code = dict["code"] as? Int, code != 0 {
            let message = dict["message"] as? String ?? "请求失败"
            throw APIError.message(message)
        }
        return object
    }

    private func bytes(
        url: String,
        params: [String: String],
        credential: BilibiliCredential? = nil,
        referer: String = BilibiliEndpoints.home,
        extraHeaders: [String: String] = [:]
    ) async throws -> Data {
        let requestURL = try requestURL(base: url, params: params)

        var request = URLRequest(url: requestURL)
        request.timeoutInterval = 20
        request.setValue(BilibiliEndpoints.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        extraHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        if let cookie = await buildCookieHeader(credential: credential) {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.message("网络响应异常")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.message(http.statusCode == 412 ? "请求被 B 站风控拦截，请稍后重试" : "HTTP \(http.statusCode)")
        }
        return data
    }

    private func buildCookieHeader(credential: BilibiliCredential?) async -> String? {
        await ensureGuestBuvid()
        var parts: [String] = []
        if let credential {
            parts.append(credential.cookieHeader)
            if credential.buvid3.isEmpty, let guestBuvid3 {
                parts.append("buvid3=\(guestBuvid3)")
            }
            if credential.buvid4.isEmpty, let guestBuvid4 {
                parts.append("buvid4=\(guestBuvid4)")
            }
        } else {
            if let guestBuvid3 { parts.append("buvid3=\(guestBuvid3)") }
            if let guestBuvid4 { parts.append("buvid4=\(guestBuvid4)") }
        }
        let cookie = parts.joined(separator: "; ")
        return cookie.isEmpty ? nil : cookie
    }

    private func ensureGuestBuvid() async {
        if guestBuvid3 != nil || guestBuvid4 != nil { return }
        guard let url = URL(string: "https://api.bilibili.com/x/frontend/finger/spi") else { return }
        var request = URLRequest(url: url)
        request.setValue(BilibiliEndpoints.userAgent, forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any] else {
            return
        }
        guestBuvid3 = (payload["b_3"] as? String)?.nilIfEmpty
        guestBuvid4 = (payload["b_4"] as? String)?.nilIfEmpty
    }

    private func dynamicRequestHeaders() -> [String: String] {
        [
            "x-bili-device-req-json": #"{"platform":"android","device":"phone","mobi_app":"android","build":8510300}"#,
            "x-bili-web-req-json": #"{"spm_id":"333.1365"}"#
        ]
    }
}

enum BiliURLEncoder: Sendable {
    nonisolated static func queryComponent(_ value: String) -> String {
        javaStyleEncode(value)
    }

    nonisolated static func wbiComponent(_ value: String) -> String {
        javaStyleEncode(value)
            .replacingOccurrences(of: "%21", with: "!")
            .replacingOccurrences(of: "%27", with: "'")
            .replacingOccurrences(of: "%28", with: "(")
            .replacingOccurrences(of: "%29", with: ")")
            .replacingOccurrences(of: "%7E", with: "~")
    }

    private nonisolated static func javaStyleEncode(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.utf8.count * 3)

        for byte in value.utf8 {
            switch byte {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D, 0x5F, 0x2E, 0x7E:
                result.append(Character(UnicodeScalar(byte)))
            default:
                result += String(format: "%%%02X", byte)
            }
        }
        return result
    }
}

private extension String {
    nonisolated var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

enum APIError: LocalizedError, Sendable {
    case message(String)

    nonisolated var errorDescription: String? {
        switch self {
        case .message(let message):
            message
        }
    }
}

private enum WbiSigner: Sendable {
    private nonisolated static let order: [Int] = [
        46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49,
        33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40, 61,
        26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 52, 11, 36, 20, 34, 44, 6
    ]

    nonisolated static func mixinKey(imgURL: String, subURL: String) -> String {
        let raw = token(from: imgURL) + token(from: subURL)
        let chars = Array(raw)
        return String(order.compactMap { $0 < chars.count ? chars[$0] : nil }.prefix(32))
    }

    nonisolated static func signature(params: [String: String], mixinKey: String) -> String {
        let query = params
            .filter { $0.key != "w_rid" }
            .sorted { $0.key < $1.key }
            .map { "\(BiliURLEncoder.wbiComponent($0.key))=\(BiliURLEncoder.wbiComponent($0.value))" }
            .joined(separator: "&")
        let digest = Insecure.MD5.hash(data: Data((query + mixinKey).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func token(from url: String) -> String {
        url.split(separator: "/").last?.split(separator: ".").first.map(String.init) ?? ""
    }
}

extension BilibiliCredential {
    init(cookieText: String) throws {
        var values: [String: String] = [:]
        cookieText
            .replacingOccurrences(of: "\n", with: ";")
            .split(separator: ";")
            .forEach { part in
                let pieces = part.split(separator: "=", maxSplits: 1).map {
                    String($0).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if pieces.count == 2 {
                    values[pieces[0]] = pieces[1]
                }
            }

        let uid = values["DedeUserID"] ?? values["dedeuserid"] ?? ""
        let sessdata = values["SESSDATA"] ?? values["sessdata"] ?? ""
        let biliJct = values["bili_jct"] ?? values["biliJct"] ?? ""
        guard !uid.isEmpty, !sessdata.isEmpty, !biliJct.isEmpty else {
            throw APIError.message("Cookie 缺少 SESSDATA、bili_jct 或 DedeUserID")
        }

        self.init(
            dedeUserId: uid,
            sessdata: sessdata,
            biliJct: biliJct,
            buvid3: values["buvid3"] ?? "",
            buvid4: values["buvid4"] ?? ""
        )
    }
}

private extension String {
    nonisolated var urlQueryEscaped: String {
        BiliURLEncoder.queryComponent(self)
    }
}
