import Foundation

struct BiliAccessKeyExchangeStatus: Sendable {
    let succeeded: Bool
    let failedStep: String
    let apiCode: Int?
    let apiMessage: String?

    static let success = BiliAccessKeyExchangeStatus(succeeded: true, failedStep: "", apiCode: 0, apiMessage: nil)

    static func failure(step: String, code: Int? = nil, message: String? = nil) -> BiliAccessKeyExchangeStatus {
        BiliAccessKeyExchangeStatus(succeeded: false, failedStep: step, apiCode: code, apiMessage: message)
    }

    nonisolated var summary: String {
        if succeeded { return "成功" }
        var parts = [failedStep]
        if let apiCode { parts.append("code=\(apiCode)") }
        if let apiMessage, !apiMessage.isEmpty { parts.append(apiMessage) }
        return parts.joined(separator: " · ")
    }
}

enum BiliAccessKeyExchange {
    private static let pinkAppKey = "783bbb7264451d82"
    private static let androidUA =
        "Mozilla/5.0 BiliDroid/8.51.0 (bbcallen@gmail.com) os/android model/Mi 11 mobi_app/android build/8510300 channel/master innerVer/8510310 osVer/13 network/2"
    private static let pollWaitingCodes: Set<Int> = [86039, 86090]

    static func exchange(credential: BilibiliCredential) async -> BilibiliCredential? {
        let result = await exchangeWithStatus(credential: credential)
        return result.credential
    }

    static func exchangeWithStatus(credential: BilibiliCredential) async -> (credential: BilibiliCredential?, status: BiliAccessKeyExchangeStatus) {
        if !credential.accessKey.isEmpty {
            return (credential, .success)
        }
        return await performExchange(credential: credential)
    }

    private static func performExchange(
        credential: BilibiliCredential
    ) async -> (credential: BilibiliCredential?, status: BiliAccessKeyExchangeStatus) {
        guard credential.hasLoginSession else {
            return (nil, .failure(step: "session", message: "缺少 SESSDATA 或 DedeUserID"))
        }

        await syncPassportSession(credential: credential)

        let cookie2TokenResult = await exchangeViaCookie2Token(credential: credential)
        if cookie2TokenResult.credential != nil {
            return cookie2TokenResult
        }
        let cookie2TokenSummary = cookie2TokenResult.status.summary

        let authResult = await requestAuthCode(credential: credential)
        guard let authCode = authResult.value else {
            return (nil, .failure(
                step: "auth_code",
                code: authResult.code,
                message: [authResult.message, cookie2TokenSummary].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " | ")
            ))
        }

        let confirmResult = await confirmAuthCode(authCode: authCode, credential: credential)
        guard confirmResult.value != nil else {
            let message = [confirmResult.message, cookie2TokenSummary]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " | ")
            return (nil, .failure(step: "confirm", code: confirmResult.code, message: message.isEmpty ? nil : message))
        }

        for attempt in 0..<20 {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            let pollResult = await pollAuthCode(authCode: authCode, credential: credential)
            if pollResult.shouldRetry {
                continue
            }
            guard let tokenData = pollResult.data else {
                return (nil, .failure(step: "poll", code: pollResult.code, message: pollResult.message))
            }

            let accessKey = string(tokenData, "access_token")
                .ifEmpty(string((tokenData["token_info"] as? [String: Any]) ?? [:], "access_token"))
            guard !accessKey.isEmpty else {
                continue
            }

            let refreshToken = string(tokenData, "refresh_token")
                .ifEmpty(string((tokenData["token_info"] as? [String: Any]) ?? [:], "refresh_token"))

            var updated = credential
            updated.accessKey = accessKey
            updated.refreshToken = refreshToken
            return (updated, .success)
        }

        return (nil, .failure(step: "poll_timeout", message: "确认后长时间未拿到 access_token"))
    }

    private struct APIResult<T> {
        let value: T?
        let code: Int?
        let message: String?
    }

    private struct PollResult {
        let data: [String: Any]?
        let code: Int?
        let message: String?
        let shouldRetry: Bool
    }

    private static func syncPassportSession(credential: BilibiliCredential) async {
        var request = URLRequest(url: URL(string: "https://passport.bilibili.com/x/passport-login/web/sso/list")!)
        request.httpMethod = "GET"
        request.setValue(BilibiliEndpoints.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(credential.cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        _ = try? await URLSession.shared.data(for: request)
    }

    private static func exchangeViaCookie2Token(
        credential: BilibiliCredential
    ) async -> (credential: BilibiliCredential?, status: BiliAccessKeyExchangeStatus) {
        let params = BiliAppSign.signQuery(baseParams: [
            "appkey": pinkAppKey
        ])

        var request = URLRequest(url: URL(string: "https://passport.bilibili.com/x/passport-login/oauth2/cookie2token")!)
        request.httpMethod = "POST"
        request.httpBody = formBody(params)
        request.setValue(BilibiliEndpoints.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(credential.cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")

        let response = await executeJSON(request)
        guard response.code == 0,
              let data = response.json?["data"] as? [String: Any] else {
            return (nil, .failure(step: "cookie2token", code: response.code, message: response.message))
        }

        let accessKey = string(data, "access_token")
            .ifEmpty(string((data["token_info"] as? [String: Any]) ?? [:], "access_token"))
        guard !accessKey.isEmpty else {
            return (nil, .failure(step: "cookie2token", code: response.code, message: "access_token 为空"))
        }

        let refreshToken = string(data, "refresh_token")
            .ifEmpty(string((data["token_info"] as? [String: Any]) ?? [:], "refresh_token"))

        var updated = credential
        updated.accessKey = accessKey
        updated.refreshToken = refreshToken
        return (updated, .success)
    }

    private static func requestAuthCode(credential: BilibiliCredential) async -> APIResult<String> {
        let buvid = resolveBuvid(credential)
        let params = BiliAppSign.signQuery(baseParams: [
            "appkey": pinkAppKey,
            "build": "8510300",
            "c_locale": "zh-Hans_CN",
            "channel": "master",
            "local_id": buvid,
            "mobi_app": "android",
            "platform": "android",
            "s_locale": "zh-Hans_CN"
        ])

        var request = URLRequest(url: URL(string: "https://passport.bilibili.com/x/passport-tv-login/qrcode/auth_code")!)
        request.httpMethod = "POST"
        request.httpBody = formBody(params)
        request.setValue(androidUA, forHTTPHeaderField: "User-Agent")
        request.setValue(buvid, forHTTPHeaderField: "buvid")
        request.setValue(credential.cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("https://passport.bilibili.com/", forHTTPHeaderField: "Referer")

        let response = await executeJSON(request)
        guard response.code == 0,
              let data = response.json?["data"] as? [String: Any] else {
            return APIResult(value: nil, code: response.code, message: response.message)
        }
        let authCode = string(data, "auth_code")
        guard !authCode.isEmpty else {
            return APIResult(value: nil, code: response.code, message: "auth_code 为空")
        }
        return APIResult(value: authCode, code: response.code, message: response.message)
    }

    private static func confirmAuthCode(authCode: String, credential: BilibiliCredential) async -> APIResult<[String: Any]> {
        guard !credential.biliJct.isEmpty else {
            return APIResult(value: nil, code: nil, message: "缺少 bili_jct")
        }

        var request = URLRequest(url: URL(string: "https://passport.bilibili.com/x/passport-tv-login/h5/qrcode/confirm")!)
        request.httpMethod = "POST"
        request.httpBody = formBody([
            "auth_code": authCode,
            "csrf": credential.biliJct,
            "scanning_type": "1"
        ])
        request.setValue(BilibiliEndpoints.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(resolveBuvid(credential), forHTTPHeaderField: "buvid")
        request.setValue(credential.cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("https://passport.bilibili.com/", forHTTPHeaderField: "Referer")

        let response = await executeJSON(request)
        guard response.code == 0 else {
            return APIResult(value: nil, code: response.code, message: response.message)
        }
        return APIResult(value: response.json, code: response.code, message: response.message)
    }

    private static func pollAuthCode(authCode: String, credential: BilibiliCredential) async -> PollResult {
        let params = BiliAppSign.signQuery(baseParams: [
            "appkey": pinkAppKey,
            "auth_code": authCode,
            "build": "8510300",
            "c_locale": "zh-Hans_CN",
            "channel": "master",
            "local_id": "0",
            "mobi_app": "android",
            "platform": "android",
            "s_locale": "zh-Hans_CN"
        ])

        var request = URLRequest(url: URL(string: "https://passport.bilibili.com/x/passport-tv-login/qrcode/poll")!)
        request.httpMethod = "POST"
        request.httpBody = formBody(params)
        request.setValue(androidUA, forHTTPHeaderField: "User-Agent")
        request.setValue(resolveBuvid(credential), forHTTPHeaderField: "buvid")
        request.setValue(credential.cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("https://passport.bilibili.com/", forHTTPHeaderField: "Referer")

        let response = await executeJSON(request)
        let code = response.code ?? -1
        if code == 0, let data = response.json?["data"] as? [String: Any] {
            return PollResult(data: data, code: code, message: response.message, shouldRetry: false)
        }
        if pollWaitingCodes.contains(code) {
            return PollResult(data: nil, code: code, message: response.message, shouldRetry: true)
        }
        return PollResult(data: nil, code: code, message: response.message, shouldRetry: false)
    }

    private struct JSONResponse {
        let json: [String: Any]?
        let code: Int?
        let message: String?
    }

    private static func executeJSON(_ request: URLRequest) async -> JSONResponse {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return JSONResponse(json: nil, code: nil, message: "HTTP 错误")
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return JSONResponse(json: nil, code: nil, message: "JSON 解析失败")
            }
            let code: Int? = {
                if let value = json["code"] as? Int { return value }
                if let value = json["code"] as? String, let intValue = Int(value) { return intValue }
                return nil
            }()
            let message = json["message"] as? String
            return JSONResponse(json: json, code: code, message: message)
        } catch {
            return JSONResponse(json: nil, code: nil, message: error.localizedDescription)
        }
    }

    private static func formBody(_ params: [String: String]) -> Data {
        params.sorted { $0.key < $1.key }.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }.joined(separator: "&").data(using: .utf8) ?? Data()
    }

    private static func resolveBuvid(_ credential: BilibiliCredential) -> String {
        credential.buvid3.isEmpty ? "XY0000000000000000000000000000infoc" : credential.buvid3
    }

    private static func string(_ object: [String: Any], _ keys: String...) -> String {
        for key in keys {
            if let value = object[key] as? String, !value.isEmpty { return value }
            if let value = object[key] as? Int { return String(value) }
            if let value = object[key] as? Int64 { return String(value) }
        }
        return ""
    }
}
