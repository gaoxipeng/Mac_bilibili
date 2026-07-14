import Foundation

actor WatchHistoryReporter {
    private var lastKey: String?
    private var lastProgressSeconds: Int64 = -1
    private var lastReportAtMs: Int64 = 0

    func reportIfNeeded(
        api: BilibiliAPI,
        aid: Int64,
        cid: Int64,
        progressSeconds: Int64,
        credential: BilibiliCredential,
        force: Bool = false
    ) async {
        guard aid > 0, cid > 0 else { return }

        let key = "\(aid):\(cid)"
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let progress = max(0, progressSeconds)
        let sameVideo = key == lastKey
        let progressDelta = abs(progress - lastProgressSeconds)
        if !force, sameVideo, progressDelta < 3, now - lastReportAtMs < 5_000 {
            return
        }

        do {
            _ = try await api.reportWatchHistory(
                aid: aid,
                cid: cid,
                progressSeconds: progress,
                credential: credential
            )
            lastKey = key
            lastProgressSeconds = progress
            lastReportAtMs = now
        } catch {
            // 与安卓端一致：上报失败时静默忽略，等待下次重试。
        }
    }
}
