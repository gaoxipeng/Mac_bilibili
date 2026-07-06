import os

/// Signposts for Instruments → Points of Interest / Time Profiler filtering.
enum BiliScrollSignpost: Sendable {
    private static let log = OSLog(subsystem: "gaoxipeng.bilibili", category: "FeedScroll")

    nonisolated static func beginHoverSync() -> OSSignpostID {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: "HoverSync", signpostID: id)
        return id
    }

    nonisolated static func endHoverSync(_ id: OSSignpostID, tracked: Int, candidates: Int) {
        os_signpost(
            .end,
            log: log,
            name: "HoverSync",
            signpostID: id,
            "tracked=%{public}d candidates=%{public}d",
            tracked,
            candidates
        )
    }

    nonisolated static func imageDecodeBegin(url: String) -> OSSignpostID {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: "CoverDecode", signpostID: id, "url=%{public}s", url)
        return id
    }

    nonisolated static func imageDecodeEnd(_ id: OSSignpostID) {
        os_signpost(.end, log: log, name: "CoverDecode", signpostID: id)
    }
}
