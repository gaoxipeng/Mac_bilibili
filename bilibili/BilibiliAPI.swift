import CryptoKit
import Foundation

actor BilibiliAPI {
    private var mixinKey: String?
    private var guestBuvid3: String?
    private var guestBuvid4: String?
    private var warmUpTask: Task<Void, Never>?

    func httpCookieHeader(credential: BilibiliCredential?) async -> String {
        await buildCookieHeader(credential: credential) ?? ""
    }

    func invalidateWBICache() {
        mixinKey = nil
        warmUpTask?.cancel()
        warmUpTask = nil
    }

    func warmUp(credential: BilibiliCredential? = nil) async {
        loadPersistedGuestBuvid()
        if mixinKey != nil, guestBuvid3 != nil { return }

        if let warmUpTask {
            await warmUpTask.value
            return
        }

        let task = Task { await self.performWarmUp(credential: credential) }
        warmUpTask = task
        await task.value
    }

    private func performWarmUp(credential: BilibiliCredential?) async {
        loadPersistedGuestBuvid()
        if mixinKey != nil, guestBuvid3 != nil { return }

        let needsBuvid = guestBuvid3 == nil
        let needsMixin = mixinKey == nil

        switch (needsBuvid, needsMixin) {
        case (true, true):
            async let buvid = Self.fetchGuestBuvid()
            async let mixin = Self.fetchMixinKey(credential: credential)
            let (b3, b4) = await buvid
            if let b3 {
                guestBuvid3 = b3
            }
            if let b4 {
                guestBuvid4 = b4
            }
            persistGuestBuvid()
            if let key = await mixin {
                mixinKey = key
            }
        case (true, false):
            let (b3, b4) = await Self.fetchGuestBuvid()
            if let b3 {
                guestBuvid3 = b3
            }
            if let b4 {
                guestBuvid4 = b4
            }
            persistGuestBuvid()
        case (false, true):
            if let key = await Self.fetchMixinKey(credential: credential) {
                mixinKey = key
            }
        case (false, false):
            break
        }
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

    func searchPGCMedia(
        keyword: String,
        searchType: String,
        page: Int = 1,
        credential: BilibiliCredential? = nil
    ) async throws -> BiliSearchPage<BiliSearchBangumi> {
        let refererPath = searchType == "media_ft" ? "movie" : "bangumi"
        let params: [String: String] = [
            "search_type": searchType,
            "keyword": keyword,
            "page": "\(max(1, page))"
        ]
        let json = try await wbiJSON(
            url: "https://api.bilibili.com/x/web-interface/wbi/search/type",
            params: params,
            credential: credential,
            referer: "https://search.bilibili.com/\(refererPath)?keyword=\(keyword.urlQueryEscaped)"
        )
        return JSONParser.parseSearchBangumiPage(from: json)
    }

    func searchAllPGCMedia(
        keyword: String,
        credential: BilibiliCredential? = nil
    ) async throws -> [BiliSearchBangumi] {
        let json = try await wbiJSON(
            url: "https://api.bilibili.com/x/web-interface/wbi/search/all/v2",
            params: ["keyword": keyword],
            credential: credential,
            referer: "https://search.bilibili.com/all?keyword=\(keyword.urlQueryEscaped)"
        )
        return JSONParser.parseSearchAllPGCMedia(from: json)
    }

    func pgcSeasonFirstEpid(
        seasonId: Int64,
        credential: BilibiliCredential? = nil
    ) async throws -> Int64 {
        guard seasonId > 0 else { return 0 }
        let json = try await json(
            url: "https://api.bilibili.com/pgc/view/web/season",
            params: ["season_id": "\(seasonId)"],
            credential: credential,
            referer: "https://www.bilibili.com/bangumi/play/ss\(seasonId)"
        )
        return JSONParser.parsePGCSeasonFirstEpid(from: json)
    }

    func enrichPinnedMediaItems(
        _ items: [BiliSearchBangumi],
        credential: BilibiliCredential? = nil
    ) async -> [BiliSearchBangumi] {
        var enriched = items
        let pending = items.enumerated().filter { $0.element.firstEpid == 0 && $0.element.seasonId > 0 }.prefix(16)
        await withTaskGroup(of: (Int, Int64).self) { group in
            for (index, item) in pending {
                let seasonId = item.seasonId
                group.addTask {
                    let epid = (try? await self.pgcSeasonFirstEpid(seasonId: seasonId, credential: credential)) ?? 0
                    return (index, epid)
                }
            }
            for await (index, epid) in group where epid > 0 {
                enriched[index] = enriched[index].withFirstEpid(epid)
            }
        }
        return enriched
    }

    private func fetchPGCSearchPage(
        keyword: String,
        searchType: String,
        page: Int,
        credential: BilibiliCredential?
    ) async -> BiliSearchPage<BiliSearchBangumi> {
        if let result = try? await searchPGCMedia(
            keyword: keyword,
            searchType: searchType,
            page: page,
            credential: credential
        ) {
            return result
        }

        try? await Task.sleep(nanoseconds: 250_000_000)
        if let result = try? await searchPGCMedia(
            keyword: keyword,
            searchType: searchType,
            page: page,
            credential: credential
        ) {
            return result
        }

        return BiliSearchPage(items: [], page: page, hasMore: false)
    }

    func searchPinnedMedia(
        keyword: String,
        page: Int = 1,
        credential: BilibiliCredential? = nil
    ) async throws -> BiliSearchPage<BiliSearchBangumi> {
        let resolvedPage = max(1, page)

        let allTask = Task { [resolvedPage, keyword, credential] () -> [BiliSearchBangumi] in
            guard resolvedPage == 1 else { return [] }
            return (try? await self.searchAllPGCMedia(keyword: keyword, credential: credential)) ?? []
        }
        let bangumiTask = Task {
            await self.fetchPGCSearchPage(
                keyword: keyword,
                searchType: "media_bangumi",
                page: resolvedPage,
                credential: credential
            )
        }
        let ftTask = Task {
            await self.fetchPGCSearchPage(
                keyword: keyword,
                searchType: "media_ft",
                page: resolvedPage,
                credential: credential
            )
        }

        let allResults = await allTask.value
        let bangumiPage = await bangumiTask.value
        let ftPage = await ftTask.value

        var merged: [BiliSearchBangumi] = []
        var seen = Set<Int64>()
        for item in allResults + bangumiPage.items + ftPage.items where seen.insert(item.seasonId).inserted {
            merged.append(item)
        }

        merged = BiliSearchBangumi.sortedForDisplay(merged)
        merged = await enrichPinnedMediaItems(merged, credential: credential)

        return BiliSearchPage(
            items: merged,
            page: resolvedPage,
            hasMore: bangumiPage.hasMore || ftPage.hasMore
        )
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
        if let snapshot = await userCardSnapshot(mid: mid, credential: credential) {
            let sign = snapshot.sign.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sign.isEmpty { return sign }
        }
        let referer = "https://space.bilibili.com/\(mid)"
        let accJSON = try? await wbiJSON(
            url: "https://api.bilibili.com/x/space/wbi/acc/info",
            params: ["mid": "\(mid)"],
            credential: credential,
            referer: referer
        )
        return accJSON.flatMap { JSONParser.parseUserAccInfo(from: $0) }?.sign ?? ""
    }

    func userCardSnapshot(mid: Int64, credential: BilibiliCredential? = nil) async -> BiliUserCardSnapshot? {
        let referer = "https://space.bilibili.com/\(mid)"
        guard let json = try? await self.json(
            url: "https://api.bilibili.com/x/web-interface/card",
            params: ["mid": "\(mid)", "photo": "true"],
            credential: credential,
            referer: referer
        ), var snapshot = JSONParser.parseUserCardSnapshot(from: json) else {
            return nil
        }

        if let credential,
           let relation = try? await userRelation(mid: mid, credential: credential) {
            snapshot.relation = relation
        }
        return snapshot
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

        let acc = accJSON.flatMap { JSONParser.parseUserAccInfo(from: $0) }
        let card = cardJSON.flatMap { JSONParser.parseUserCardProfile(from: $0) }
        let likes = upstatJSON.map { JSONParser.parseUserUpstatLikes(from: $0) } ?? 0
        let videoCount = navnumJSON.map { JSONParser.parseUserNavnum(from: $0) } ?? 0

        guard let profile = JSONParser.mergeSpaceProfile(
            acc: acc,
            card: card,
            mid: mid,
            likes: likes,
            videoCount: videoCount
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

    func userSpaceDynamics(
        mid: Int64,
        offset: String? = nil,
        credential: BilibiliCredential? = nil
    ) async throws -> BiliDynamicFeedPage {
        var params: [String: String] = [
            "host_mid": "\(mid)",
            "timezone_offset": "-480",
            "platform": "web",
            "gaia_source": "main_web",
            "features": "itemOpusStyle,listOnlyfans,opusBigCover,onlyfansVote,forwardListHidden,decorationCard,commentsNewVersion,onlyfansAssetsV2,ugcDelete,onlyfansQaCard,endFooterHidden",
            "web_location": "333.1365"
        ]
        if let offset, !offset.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            params["offset"] = offset
        }
        let json = try await json(
            url: "https://api.bilibili.com/x/polymer/web-dynamic/v1/feed/space",
            params: params,
            credential: credential,
            referer: "https://space.bilibili.com/\(mid)/dynamic",
            extraHeaders: dynamicRequestHeaders()
        )
        return JSONParser.parseSpaceDynamicFeed(from: json)
    }

    func dynamicDetail(
        dynamicId: String,
        credential: BilibiliCredential? = nil
    ) async throws -> BiliDynamicItem? {
        guard !dynamicId.isEmpty else { return nil }
        let json = try await wbiJSON(
            url: "https://api.bilibili.com/x/polymer/web-dynamic/v1/detail",
            params: [
                "id": dynamicId,
                "timezone_offset": "-480",
                "platform": "web",
                "gaia_source": "main_web",
                "features": "itemOpusStyle,opusBigCover,onlyfansVote,endFooterHidden,decorationCard,onlyfansAssetsV2,ugcDelete,onlyfansQaCard,commentsNewVersion",
                "web_location": "333.1368"
            ],
            credential: credential,
            referer: "https://t.bilibili.com/\(dynamicId)",
            extraHeaders: dynamicRequestHeaders()
        )
        return JSONParser.parseDynamicDetail(from: json)
    }

    func exchangeAccessKey(_ credential: BilibiliCredential) async -> BilibiliCredential {
        if !credential.accessKey.isEmpty { return credential }
        let prepared = await preparedCredentialForExchange(credential)
        let result = await BiliAccessKeyExchange.exchangeWithStatus(credential: prepared)
        if let exchanged = result.credential, !exchanged.accessKey.isEmpty {
            return exchanged
        }
        return prepared
    }

    func preparedCredentialForExchange(_ credential: BilibiliCredential) async -> BilibiliCredential {
        await warmUp(credential: credential)
        var prepared = credential
        if prepared.buvid3.isEmpty, let guestBuvid3 {
            prepared.buvid3 = guestBuvid3
        }
        if prepared.buvid4.isEmpty, let guestBuvid4 {
            prepared.buvid4 = guestBuvid4
        }
        return prepared
    }

    func dynamicAuthorIpLocation(
        dynamicId: String,
        credential: BilibiliCredential?
    ) async -> String? {
        guard let credential else { return nil }
        let resolved = await exchangeAccessKey(credential)
        guard !resolved.accessKey.isEmpty else { return nil }
        return await BiliDynamicGrpcClient.fetchAuthorIpLocation(
            dynamicId: dynamicId,
            credential: resolved
        )
    }

    func userSpaceIpLocation(
        mid: Int64,
        seedDynamics: [BiliDynamicItem] = [],
        credential: BilibiliCredential? = nil
    ) async -> String? {
        let resolvedCredential: BilibiliCredential?
        if let credential {
            resolvedCredential = await exchangeAccessKey(credential)
        } else {
            resolvedCredential = nil
        }

        if let ipLocation = seedDynamics.compactMap({ JSONParser.normalizeIpLocation($0.ipLocation) }).first {
            return ipLocation
        }

        var candidates = seedDynamics
        if candidates.isEmpty {
            candidates = (try? await userSpaceDynamics(
                mid: mid,
                offset: nil,
                credential: resolvedCredential ?? credential
            ).items) ?? []
        }

        let canUseGrpc = !(resolvedCredential?.accessKey.isEmpty ?? true)
        for dynamic in candidates.prefix(5) {
            if let ipLocation = JSONParser.normalizeIpLocation(dynamic.ipLocation) {
                return ipLocation
            }
            if canUseGrpc,
               let resolvedCredential,
               let grpcIpLocation = await BiliDynamicGrpcClient.fetchAuthorIpLocation(
                   dynamicId: dynamic.id,
                   credential: resolvedCredential
               ),
               let ipLocation = JSONParser.normalizeIpLocation(grpcIpLocation) {
                return ipLocation
            }
        }

        return nil
    }

    func enrichDynamicIpLocations(
        items: [BiliDynamicItem],
        credential: BilibiliCredential? = nil
    ) async -> [BiliDynamicItem] {
        guard items.contains(where: { JSONParser.normalizeIpLocation($0.ipLocation) == nil }) else {
            return items
        }

        var result = items
        for (index, item) in items.enumerated() {
            if JSONParser.normalizeIpLocation(item.ipLocation) != nil {
                if let normalized = JSONParser.normalizeIpLocation(item.ipLocation),
                   item.ipLocation != normalized {
                    result[index] = item.withIpLocation(normalized)
                }
                continue
            }

            guard let credential else { continue }
            let requestCredential = await exchangeAccessKey(credential)
            guard let resolved = await dynamicAuthorIpLocation(
                dynamicId: item.id,
                credential: requestCredential
            ) else {
                continue
            }
            result[index] = item.withIpLocation(resolved)
        }
        return result
    }

    func subjectComments(
        oid: Int64,
        type: Int,
        sort: BiliCommentSort,
        cursor: String? = nil,
        referer: String,
        credential: BilibiliCredential? = nil
    ) async throws -> BiliCommentPage {
        var params: [String: String] = [
            "oid": "\(oid)",
            "type": "\(type)",
            "mode": "\(sort.mode)",
            "plat": "1",
            "web_location": "1315875"
        ]
        params["pagination_str"] = buildCommentPaginationStr(cursor: cursor)
        let json = try await wbiJSON(
            url: "https://api.bilibili.com/x/v2/reply/wbi/main",
            params: params,
            credential: credential,
            referer: referer
        )
        return JSONParser.parseCommentPage(from: json, includePinned: cursor == nil)
    }

    func subjectCommentReplies(
        oid: Int64,
        type: Int,
        rootID: Int64,
        referer: String,
        page: Int,
        credential: BilibiliCredential? = nil
    ) async throws -> BiliCommentReplyPage {
        let json = try await json(
            url: "https://api.bilibili.com/x/v2/reply/reply",
            params: [
                "type": "\(type)",
                "oid": "\(oid)",
                "root": "\(rootID)",
                "pn": "\(page)",
                "ps": "20",
                "web_location": "1315875"
            ],
            credential: credential,
            referer: referer
        )
        return JSONParser.parseCommentReplyPage(from: json)
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

    func userRelationListPage(
        hostMid: Int64,
        tab: BiliUserRelationTab,
        page: Int,
        pageSize: Int = 20,
        credential: BilibiliCredential? = nil
    ) async -> BiliRelationUserPage {
        let url: String
        var params: [String: String] = [
            "vmid": "\(hostMid)",
            "pn": "\(max(1, page))",
            "ps": "\(pageSize)",
        ]
        switch tab {
        case .following:
            url = "https://api.bilibili.com/x/relation/followings"
            params["order_type"] = ""
        case .followers:
            url = "https://api.bilibili.com/x/relation/followers"
        }

        do {
            let json = try await jsonAllowNonZero(
                url: url,
                params: params,
                credential: credential,
                referer: "https://space.bilibili.com/\(hostMid)"
            )
            let result = JSONParser.parseRelationUserPage(from: json, pageSize: pageSize)
            guard result.errorMessage == nil, !result.users.isEmpty else { return result }
            let users = await enrichRelationUsersFanCounts(
                result.users,
                hostMid: hostMid,
                credential: credential
            )
            return BiliRelationUserPage(
                users: users,
                hasMore: result.hasMore,
                total: result.total,
                errorMessage: nil
            )
        } catch {
            return BiliRelationUserPage(
                users: [],
                hasMore: false,
                total: 0,
                errorMessage: error.localizedDescription
            )
        }
    }

    func enrichRelationUsersFanCounts(
        _ users: [BiliRelationUser],
        hostMid: Int64,
        credential: BilibiliCredential? = nil
    ) async -> [BiliRelationUser] {
        let pending = users.enumerated().filter { $0.element.fanCount == 0 && $0.element.mid > 0 }
        guard !pending.isEmpty else { return users }

        var enriched = users
        let referer = "https://space.bilibili.com/\(hostMid)"
        let concurrency = 6
        var start = 0
        while start < pending.count {
            let chunk = Array(pending[start..<min(start + concurrency, pending.count)])
            start += concurrency
            await withTaskGroup(of: (Int, Int64).self) { group in
                for (index, user) in chunk {
                    let mid = user.mid
                    group.addTask {
                        let count = await self.relationStatFollower(
                            mid: mid,
                            credential: credential,
                            referer: referer
                        )
                        return (index, count)
                    }
                }
                for await (index, count) in group {
                    guard count > 0, enriched.indices.contains(index) else { continue }
                    let user = enriched[index]
                    enriched[index] = BiliRelationUser(
                        mid: user.mid,
                        name: user.name,
                        faceURL: user.faceURL,
                        sign: user.sign,
                        relation: user.relation,
                        fanCount: count,
                        ipLocation: user.ipLocation
                    )
                }
            }
        }
        return enriched
    }

    private func relationStatFollower(
        mid: Int64,
        credential: BilibiliCredential?,
        referer: String
    ) async -> Int64 {
        guard mid > 0 else { return 0 }
        guard let json = try? await jsonAllowNonZero(
            url: "https://api.bilibili.com/x/relation/stat",
            params: ["vmid": "\(mid)"],
            credential: credential,
            referer: referer
        ) else {
            return 0
        }
        return JSONParser.parseUserRelationStatFollower(from: json)
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

    func videoShot(
        bvid: String,
        aid: Int64,
        cid: Int64,
        credential: BilibiliCredential?
    ) async throws -> BiliVideoShot? {
        guard cid > 0 else { return nil }
        let referer = bvid.isEmpty ? BilibiliEndpoints.home : "https://www.bilibili.com/video/\(bvid)"

        for index in ["1", "", "2"] {
            var params = ["cid": "\(cid)"]
            if !bvid.isEmpty { params["bvid"] = bvid }
            if aid > 0 { params["aid"] = "\(aid)" }
            if !index.isEmpty { params["index"] = index }
            guard let root = try? await json(
                url: BilibiliEndpoints.videoShot,
                params: params,
                credential: credential,
                referer: referer
            ) as? [String: Any],
            let data = root["data"] as? [String: Any],
            let imageValues = data["image"] as? [Any] else { continue }

            let images = imageValues.compactMap { rawValue -> URL? in
                guard let value = rawValue as? String else { return nil }
                let normalized = value.hasPrefix("//") ? "https:\(value)" : value
                return URL(string: normalized)
            }
            guard !images.isEmpty else { continue }
            var indices: [Int] = (data["index"] as? [Any])?.compactMap { value -> Int? in
                if let value = value as? Int { return value }
                if let value = value as? NSNumber { return value.intValue }
                if let value = value as? String { return Int(value) }
                return nil
            } ?? []
            if indices.isEmpty, let rawPVData = data["pvdata"] as? String {
                let normalized = rawPVData.hasPrefix("//") ? "https:\(rawPVData)" : rawPVData
                if let url = URL(string: normalized) {
                    indices = await videoShotIndexData(url: url, referer: referer)
                }
            }
            func intValue(_ key: String, fallback: Int) -> Int {
                if let value = data[key] as? NSNumber { return max(1, value.intValue) }
                if let value = data[key] as? String, let parsed = Int(value) { return max(1, parsed) }
                return fallback
            }
            return BiliVideoShot(
                images: images,
                indexSeconds: indices,
                tileColumns: intValue("img_x_len", fallback: 10),
                tileRows: intValue("img_y_len", fallback: 10),
                tileWidth: intValue("img_x_size", fallback: 160),
                tileHeight: intValue("img_y_size", fallback: 90)
            )
        }
        return nil
    }

    private func videoShotIndexData(url: URL, referer: String) async -> [Int] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(BilibiliEndpoints.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        guard let (payload, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              payload.count >= 2 else { return [] }

        var values: [Int] = []
        values.reserveCapacity(payload.count / 2)
        payload.withUnsafeBytes { bytes in
            let raw = bytes.bindMemory(to: UInt8.self)
            var offset = 0
            while offset + 1 < raw.count {
                values.append(Int(UInt16(raw[offset]) << 8 | UInt16(raw[offset + 1])))
                offset += 2
            }
        }
        return values
    }

    func history(
        credential: BilibiliCredential,
        cursorMax: Int64 = 0,
        viewAt: Int64 = 0,
        business: String = "",
        pageSize: Int = 30,
        type: String = "all"
    ) async throws -> BiliHistoryPage {
        let json = try await json(
            url: "https://api.bilibili.com/x/web-interface/history/cursor",
            params: [
                "max": "\(cursorMax)",
                "view_at": "\(viewAt)",
                "business": business,
                "type": type,
                "ps": "\(min(max(pageSize, 1), 30))"
            ],
            credential: credential,
            referer: "https://www.bilibili.com/account/history"
        )
        return JSONParser.parseHistoryPage(from: json)
    }

    func pgcPlayURL(
        epid: Int64,
        cid: Int64,
        credential: BilibiliCredential? = nil,
        referer: String = "https://www.bilibili.com"
    ) async throws -> BiliPlayStream {
        guard epid > 0 || cid > 0 else {
            throw APIError.message("无法确定番剧分集")
        }

        let primary = try await requestPGCPlayURL(
            epid: epid,
            cid: cid,
            fnval: "4048",
            credential: credential,
            referer: referer,
            useV2: true
        )
        if primary.isAVPlayerCompatible {
            return primary
        }

        for fnval in ["16", "1"] {
            if let fallback = try? await requestPGCPlayURL(
                epid: epid,
                cid: cid,
                fnval: fnval,
                credential: credential,
                referer: referer,
                useV2: false
            ), fallback.isAVPlayerCompatible {
                return fallback
            }
        }

        throw APIError.message("当前番剧格式暂不支持播放，请稍后重试")
    }

    private func requestPGCPlayURL(
        epid: Int64,
        cid: Int64,
        fnval: String,
        credential: BilibiliCredential?,
        referer: String,
        useV2: Bool
    ) async throws -> BiliPlayStream {
        var params: [String: String] = [
            "qn": "80",
            "fnval": fnval,
            "fnver": "0",
            "fourk": "1",
            "drm_tech_type": "2",
            "from_client": "BROWSER"
        ]
        if epid > 0 {
            params["ep_id"] = "\(epid)"
        }
        if cid > 0 {
            params["cid"] = "\(cid)"
        }

        let url = useV2
            ? "https://api.bilibili.com/pgc/player/web/v2/playurl"
            : "https://api.bilibili.com/pgc/player/web/playurl"
        let json = try await json(
            url: url,
            params: params,
            credential: credential,
            referer: referer
        )
        guard var stream = JSONParser.parsePlayStream(from: json) else {
            throw APIError.message("无法获取番剧播放地址")
        }
        stream = BiliPlayStream(
            videoURL: stream.videoURL,
            videoFallbackURLs: stream.videoFallbackURLs,
            audioURL: stream.audioURL,
            aid: stream.aid,
            cid: cid > 0 ? cid : stream.cid,
            lastPlayTimeMilliseconds: stream.lastPlayTimeMilliseconds,
            lastPlayCID: stream.lastPlayCID
        )
        return stream
    }

    func pgcVideoDetail(
        epid: Int64,
        credential: BilibiliCredential? = nil
    ) async throws -> BiliVideoDetail {
        let context = try await pgcEpisodeContext(epid: epid, credential: credential)
        let loaded = try await videoDetail(bvid: context.bvid, credential: credential)
        let mergedVideo = mergePgcContextToVideo(context: context, base: loaded.video)
        return BiliVideoDetail(
            video: mergedVideo,
            publishTime: loaded.publishTime,
            replyCount: loaded.replyCount,
            coinCount: loaded.coinCount,
            favoriteCount: loaded.favoriteCount,
            shareCount: loaded.shareCount,
            pages: context.pages.isEmpty ? loaded.pages : context.pages
        )
    }

    func pgcEpisodeContext(
        epid: Int64,
        credential: BilibiliCredential? = nil
    ) async throws -> BiliPGCEpisodeContext {
        guard epid > 0 else {
            throw APIError.message("无法确定番剧分集")
        }
        let json = try await json(
            url: "https://api.bilibili.com/pgc/view/web/season",
            params: ["ep_id": "\(epid)"],
            credential: credential,
            referer: "https://www.bilibili.com/bangumi/play/ep\(epid)"
        )
        guard let context = JSONParser.parsePGCEpisodeContext(from: json, epid: epid) else {
            throw APIError.message("无法读取番剧详情")
        }
        return context
    }

    func resolveHistoryPlaybackRequest(
        item: BiliHistoryItem,
        credential: BilibiliCredential? = nil
    ) async -> VideoPlaybackRequest {
        let epid = await resolvedHistoryEpid(for: item, credential: credential)
        let isPgc = item.business == .pgc || item.video.isPgcPlayback || epid > 0

        if isPgc, epid > 0 {
            if let context = try? await pgcEpisodeContext(epid: epid, credential: credential) {
                let video = mergePgcContextToVideo(context: context, base: item.video)
                let referer = item.webURI
                    ?? URL(string: "https://www.bilibili.com/bangumi/play/ep\(epid)")
                return VideoPlaybackRequest(
                    video,
                    progressSeconds: 0,
                    epid: epid,
                    refererURL: referer
                )
            }

            let video = normalizedPgcHistoryVideo(item.video, epid: epid)
            return VideoPlaybackRequest(
                video,
                progressSeconds: 0,
                epid: epid,
                refererURL: item.webURI
                    ?? URL(string: "https://www.bilibili.com/bangumi/play/ep\(epid)")
            )
        }

        return VideoPlaybackRequest(
            item.video,
            progressSeconds: 0,
            epid: item.epid,
            refererURL: item.webURI
        )
    }

    private func resolvedHistoryEpid(
        for item: BiliHistoryItem,
        credential: BilibiliCredential?
    ) async -> Int64 {
        if item.epid > 0 { return item.epid }
        if let uri = item.webURI?.absoluteString,
           let parsed = JSONParser.parsePgcEpidFromUri(uri) {
            return parsed
        }
        let fromVideo = item.video.pgcEpid
        if fromVideo > 0 { return fromVideo }
        if item.business == .pgc,
           let uri = item.webURI?.absoluteString,
           let seasonId = JSONParser.parsePgcSeasonIdFromUri(uri),
           seasonId > 0 {
            return (try? await pgcSeasonFirstEpid(seasonId: seasonId, credential: credential)) ?? 0
        }
        return 0
    }

    private func normalizedPgcHistoryVideo(_ video: BiliVideo, epid: Int64) -> BiliVideo {
        guard epid > 0 else { return video }
        let syntheticBvid = video.bvid.isEmpty ? "pgc:\(epid)" : video.bvid
        return BiliVideo(
            id: "pgc:\(epid)",
            bvid: syntheticBvid,
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
            cid: video.cid,
            publishTime: video.publishTime
        )
    }

    private func mergePgcContextToVideo(
        context: BiliPGCEpisodeContext,
        base: BiliVideo
    ) -> BiliVideo {
        let title = context.seasonTitle.ifEmpty(base.title)
        let metadata = [context.styles, context.areas]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        return BiliVideo(
            id: "pgc:\(context.epid)",
            bvid: context.bvid,
            aid: context.aid,
            title: title,
            coverURL: context.coverURL ?? base.coverURL,
            authorName: metadata.ifEmpty(base.authorName),
            authorFaceURL: base.authorFaceURL,
            authorMid: base.authorMid,
            viewCount: base.viewCount,
            danmakuCount: base.danmakuCount,
            likeCount: base.likeCount,
            duration: context.duration > 0 ? context.duration : base.duration,
            description: context.evaluate.ifEmpty(base.description),
            cid: context.cid,
            publishTime: base.publishTime
        )
    }

    func deleteWatchHistory(kid: String, credential: BilibiliCredential) async throws -> Bool {
        guard !kid.isEmpty, !credential.biliJct.isEmpty else { return false }
        _ = try await postForm(
            url: BilibiliEndpoints.historyDelete,
            form: [
                "kid": kid,
                "csrf": credential.biliJct
            ],
            credential: credential,
            referer: "https://www.bilibili.com/account/history"
        )
        return true
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

    func dashPlayURL(bvid: String, cid: Int64, credential: BilibiliCredential? = nil) async throws -> BiliPlayStream {
        try await requestPlayURL(bvid: bvid, cid: cid, fnval: "4048", credential: credential)
    }

    func pgcDASHPlayURL(
        epid: Int64,
        cid: Int64,
        credential: BilibiliCredential? = nil,
        referer: String = "https://www.bilibili.com"
    ) async throws -> BiliPlayStream {
        try await requestPGCPlayURL(
            epid: epid,
            cid: cid,
            fnval: "4048",
            credential: credential,
            referer: referer,
            useV2: true
        )
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
            videoFallbackURLs: stream.videoFallbackURLs,
            audioURL: stream.audioURL,
            aid: stream.aid,
            cid: cid,
            lastPlayTimeMilliseconds: stream.lastPlayTimeMilliseconds,
            lastPlayCID: stream.lastPlayCID
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
        return JSONParser.parseCommentPage(from: json, includePinned: cursor == nil)
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
        referer: String = BilibiliEndpoints.home,
        extraHeaders: [String: String] = [:]
    ) async throws -> Any {
        await warmUp(credential: credential)

        var signed = params
        signed.removeValue(forKey: "w_rid")
        signed["wts"] = "\(Int(Date().timeIntervalSince1970))"
        if signed["web_location"] == nil {
            signed["web_location"] = "1550101"
        }
        signed["w_rid"] = WbiSigner.signature(params: signed, mixinKey: try await ensureMixinKey(credential: credential))
        return try await json(
            url: url,
            params: signed,
            credential: credential,
            referer: referer,
            extraHeaders: extraHeaders,
            wbiEncoded: true,
            skipWarmUp: true
        )
    }

    private func ensureMixinKey(credential: BilibiliCredential? = nil) async throws -> String {
        if let mixinKey {
            return mixinKey
        }

        if let key = await Self.fetchMixinKey(credential: credential) {
            mixinKey = key
            return key
        }

            throw APIError.message("无法获取 WBI 密钥")
        }

    private func loadPersistedGuestBuvid() {
        guard guestBuvid3 == nil, guestBuvid4 == nil else { return }
        guard let session = GuestSessionStore.load() else { return }
        guestBuvid3 = session.buvid3.nilIfEmpty
        guestBuvid4 = session.buvid4.nilIfEmpty
    }

    private func persistGuestBuvid() {
        guard let guestBuvid3, let guestBuvid4 else { return }
        GuestSessionStore.save(buvid3: guestBuvid3, buvid4: guestBuvid4)
    }

    nonisolated private static func fetchMixinKey(credential: BilibiliCredential?) async -> String? {
        guard let url = URL(string: "https://api.bilibili.com/x/web-interface/nav") else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(BilibiliEndpoints.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(BilibiliEndpoints.home, forHTTPHeaderField: "Referer")
        if let credential {
            request.setValue(credential.cookieHeader, forHTTPHeaderField: "Cookie")
        }

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = root["code"] as? Int, code == 0,
              let payload = root["data"] as? [String: Any],
              let wbi = payload["wbi_img"] as? [String: Any],
              let img = wbi["img_url"] as? String,
              let sub = wbi["sub_url"] as? String else {
            return nil
        }

        return WbiSigner.mixinKey(imgURL: img, subURL: sub)
    }

    nonisolated private static func fetchGuestBuvid() async -> (String?, String?) {
        guard let url = URL(string: "https://api.bilibili.com/x/frontend/finger/spi") else {
            return (nil, nil)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(BilibiliEndpoints.userAgent, forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any] else {
            return (nil, nil)
        }

        return (
            (payload["b_3"] as? String)?.nilIfEmpty,
            (payload["b_4"] as? String)?.nilIfEmpty
        )
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
        wbiEncoded: Bool = false,
        skipWarmUp: Bool = false
    ) async throws -> Any {
        if !skipWarmUp {
            await warmUp(credential: credential)
        }

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
        loadPersistedGuestBuvid()
        if guestBuvid3 != nil || guestBuvid4 != nil { return }

        let (b3, b4) = await Self.fetchGuestBuvid()
        guestBuvid3 = b3
        guestBuvid4 = b4
        persistGuestBuvid()
    }

    private func dynamicRequestHeaders() -> [String: String] {
        [
            "x-bili-device-req-json": #"{"platform":"android","device":"phone","mobi_app":"android","build":8510300}"#,
            "x-bili-web-req-json": #"{"spm_id":"333.1365"}"#
        ]
    }
}

private enum GuestSessionStore {
    nonisolated struct Session: Codable, Sendable {
        var buvid3: String
        var buvid4: String
    }

    nonisolated private static var fileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDirectory = support.appendingPathComponent("gaoxipeng.bilibili", isDirectory: true)
        return appDirectory.appendingPathComponent("guest-session.json")
    }

    nonisolated static func load() -> Session? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }

    nonisolated static func save(buvid3: String, buvid4: String) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDirectory = support.appendingPathComponent("gaoxipeng.bilibili", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(Session(buvid3: buvid3, buvid4: buvid4)) else { return }
        try? data.write(to: fileURL, options: .atomic)
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

private extension String {
    nonisolated var urlQueryEscaped: String {
        BiliURLEncoder.queryComponent(self)
    }
}
