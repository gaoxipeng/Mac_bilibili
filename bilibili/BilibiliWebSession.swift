import Combine
import Foundation
import SwiftUI
import WebKit

enum BilibiliEndpoints: Sendable {
    nonisolated static let home = "https://www.bilibili.com"
    nonisolated static let homeURL = URL(string: home)!
    nonisolated static let danmakuList = "https://api.bilibili.com/x/v1/dm/list.so"
    nonisolated static let danmakuSeg = "https://api.bilibili.com/x/v2/dm/web/seg.so"
    nonisolated static let danmakuXML = "https://comment.bilibili.com"
    nonisolated static let historyReport = "https://api.bilibili.com/x/v2/history/report"
    nonisolated static let passportLogin = URL(string: "https://passport.bilibili.com/login")!
    nonisolated static let userAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    nonisolated static func playbackHeaders(cookie: String) -> [String: String] {
        var headers: [String: String] = [
            "Accept": "*/*",
            "Referer": home,
            "Origin": home,
            "User-Agent": userAgent
        ]
        if !cookie.isEmpty {
            headers["Cookie"] = cookie
        }
        return headers
    }
}

@MainActor
final class BilibiliWebSession: NSObject, ObservableObject {
    let webView: WKWebView
    @Published private(set) var hasLoginCookie = false

    private var cookieObserverRegistered = false

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        configureWebView()
        webView.load(URLRequest(url: BilibiliEndpoints.homeURL))
    }

    func openLogin(forceReload: Bool = false) {
        let activeURL = webView.url?.absoluteString ?? ""
        if !forceReload, activeURL.contains("passport.bilibili.com") {
            return
        }
        webView.load(URLRequest(url: BilibiliEndpoints.passportLogin))
    }

    func refreshLoginState() async {
        hasLoginCookie = await readCredential() != nil
    }

    func readCredential() async -> BilibiliCredential? {
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        return Self.credential(from: cookies)
    }

    private func configureWebView() {
        webView.customUserAgent = BilibiliEndpoints.userAgent
        webView.allowsBackForwardNavigationGestures = true
        registerCookieObserverIfNeeded()
    }

    private func registerCookieObserverIfNeeded() {
        guard !cookieObserverRegistered else { return }
        cookieObserverRegistered = true
        webView.configuration.websiteDataStore.httpCookieStore.add(self)
    }

    private static func credential(from cookies: [HTTPCookie]) -> BilibiliCredential? {
        let bilibiliCookies = cookies.filter {
            $0.domain.contains("bilibili.com")
        }
        let values = Dictionary(
            bilibiliCookies.map { ($0.name, $0.value) },
            uniquingKeysWith: { current, _ in current }
        )

        guard
            let sessdata = values["SESSDATA"], !sessdata.isEmpty,
            let dedeUserId = values["DedeUserID"], !dedeUserId.isEmpty
        else {
            return nil
        }

        return BilibiliCredential(
            dedeUserId: dedeUserId,
            sessdata: sessdata,
            biliJct: values["bili_jct"] ?? "",
            buvid3: values["buvid3"] ?? "",
            buvid4: values["buvid4"] ?? ""
        )
    }
}

extension BilibiliWebSession: WKHTTPCookieStoreObserver {
    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor in
            await refreshLoginState()
        }
    }
}

private extension WKHTTPCookieStore {
    func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }
}

struct BilibiliWebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView {
        webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
