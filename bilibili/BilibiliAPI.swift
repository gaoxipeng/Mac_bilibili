import CryptoKit
import Foundation

actor BilibiliAPI {
    private var mixinKey: String?
    private var guestBuvid3: String?
    private var guestBuvid4: String?

    func httpCookieHeader(credential: BilibiliCredential?) async -> String {
        await buildCookieHeader(credential: credential) ?? ""
    }

    func homeRecommend(credential: BilibiliCredential? = nil) async throws -> [BiliVideo] {
        let params: [String: String] = [
            "fresh_type": "4",
            "ps": "24",
            "fresh_idx": "1",
            "fresh_idx_1h": "1",
            "brush": "1",
            "fetch_row": "1",
            "web_location": "1430650"
        ]
        let json = try await wbiJSON(
            url: "https://api.bilibili.com/x/web-interface/wbi/index/top/feed/rcmd",
            params: params,
            credential: credential
        )
        return JSONParser.parseVideos(from: json, preferredArrayKeys: ["item"])
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

    func searchVideos(keyword: String, credential: BilibiliCredential? = nil) async throws -> [BiliVideo] {
        let params: [String: String] = [
            "search_type": "video",
            "keyword": keyword,
            "page": "1",
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
        return JSONParser.parseVideos(from: json, preferredArrayKeys: ["result"])
    }

    func hotWords() async throws -> [BiliHotWord] {
        let json = try await json(
            url: "https://s.search.bilibili.com/main/hotword",
            params: ["limit": "18"]
        )
        return JSONParser.parseHotWords(from: json)
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
        let json = try await json(
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
        return try await json(url: url, params: signed, credential: credential, referer: referer)
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

    private func json(
        url: String,
        params: [String: String],
        credential: BilibiliCredential? = nil,
        referer: String = BilibiliEndpoints.home,
        extraHeaders: [String: String] = [:]
    ) async throws -> Any {
        var components = URLComponents(string: url)
        components?.percentEncodedQuery = params
            .sorted { $0.key < $1.key }
            .map { "\(BiliURLEncoder.queryComponent($0.key))=\(BiliURLEncoder.queryComponent($0.value))" }
            .joined(separator: "&")
        guard let requestURL = components?.url else {
            throw APIError.message("接口地址无效")
        }

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
        var components = URLComponents(string: url)
        if !params.isEmpty {
            components?.percentEncodedQuery = params
                .sorted { $0.key < $1.key }
                .map { "\(BiliURLEncoder.queryComponent($0.key))=\(BiliURLEncoder.queryComponent($0.value))" }
                .joined(separator: "&")
        }
        guard let requestURL = components?.url else {
            throw APIError.message("接口地址无效")
        }

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
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.*"))
        var result = ""
        for scalar in value.unicodeScalars {
            if allowed.contains(scalar) {
                result.unicodeScalars.append(scalar)
            } else if scalar == " " {
                result += "%20"
            } else {
                result += String(format: "%%%02X", scalar.value)
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
