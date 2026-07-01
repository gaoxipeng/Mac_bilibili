import Foundation

/// Coordinates video playback across navigation transitions so audio never
/// continues after the user leaves a page.
@MainActor
final class MediaPlaybackCoordinator {
    static let shared = MediaPlaybackCoordinator()

    private weak var visibleDetail: VideoDetailModel?
    private var obscuringPageCount = 0

    private init() {}

    func notifyDetailVisible(_ model: VideoDetailModel) {
        if let current = visibleDetail, current !== model {
            current.teardown()
        }
        model.reactivateIfNeeded()
        visibleDetail = model
        applyPlaybackPolicy(for: model)
    }

    func notifyDetailHidden(_ model: VideoDetailModel) {
        model.suspendPlayback()
        if visibleDetail === model {
            visibleDetail = nil
        }
    }

    func notifyObscuringPageVisible() {
        obscuringPageCount += 1
        visibleDetail?.suspendPlayback()
    }

    func notifyObscuringPageHidden() {
        obscuringPageCount = max(0, obscuringPageCount - 1)
        if let detail = visibleDetail, obscuringPageCount == 0 {
            applyPlaybackPolicy(for: detail)
        }
    }

    func stopAll() {
        visibleDetail?.teardown()
        visibleDetail = nil
        obscuringPageCount = 0
    }

    func suspendAll() {
        visibleDetail?.suspendPlayback()
    }

    func handleSceneBecameActive() {
        guard let detail = visibleDetail else { return }
        applyPlaybackPolicy(for: detail)
    }

    private func applyPlaybackPolicy(for model: VideoDetailModel) {
        if obscuringPageCount == 0 {
            model.resumePlaybackIfNeeded()
        } else {
            model.suspendPlayback()
        }
    }
}
