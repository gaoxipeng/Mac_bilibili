import Foundation

/// Launch arguments for automated scroll profiling (`Scripts/profile-feed-scroll.sh`).
enum PerfLaunchConfiguration {
    static var requestedSection: AppSection? {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-BiliPerfHome") { return .home }
        if args.contains("-BiliPerfScrollTest") { return .scrollTest }
        return nil
    }

    static var suppressPlayURLPrefetch: Bool {
        ProcessInfo.processInfo.arguments.contains("-BiliPerfNoPrefetch")
    }
}
