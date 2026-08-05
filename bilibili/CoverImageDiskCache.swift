import CryptoKit
import Foundation

enum CoverImageDiskCache: Sendable {
    nonisolated private static let maxCacheBytes: Int64 = 200 * 1024 * 1024
    nonisolated private static let expirationInterval: TimeInterval = 30 * 24 * 60 * 60
    nonisolated private static let lock = NSLock()
    // Accessed only while `lock` is held. Keeping the running byte count avoids
    // scanning the whole cache directory after every homepage cover download.
    nonisolated(unsafe) private static var cachedTotalBytes: Int64?

    /// Prepares the cache at app launch and removes stale/oversized entries.
    nonisolated static func prepare() {
        lock.lock()
        defer { lock.unlock() }

        let fileManager = FileManager.default
        let directory = cacheDirectoryURL()
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        // The old implementation stored images in Application Support. Since these
        // files are disposable cache data, remove that legacy location on upgrade.
        try? fileManager.removeItem(at: legacyCacheDirectoryURL())

        removeExpiredFiles(in: directory, fileManager: fileManager)
        trimToMaximumSize(in: directory, fileManager: fileManager)
        cachedTotalBytes = cacheByteCount(in: directory, fileManager: fileManager)
    }

    nonisolated static func data(for url: URL) -> Data? {
        let fileURL = fileURL(for: url)
        guard let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]) else {
            return nil
        }
        // Treat reads as use so the size cap evicts least-recently-used files.
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: fileURL.path
        )
        return data
    }

    nonisolated static func save(_ data: Data, for url: URL) {
        let fileURL = fileURL(for: url)
        lock.lock()
        defer { lock.unlock() }

        do {
            let fileManager = FileManager.default
            let directory = cacheDirectoryURL()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let previousSize = Int64(
                (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            )
            try data.write(to: fileURL, options: .atomic)
            let totalBeforeWrite = cachedTotalBytes
                ?? cacheByteCount(in: directory, fileManager: fileManager)
            cachedTotalBytes = max(
                0,
                totalBeforeWrite - previousSize + Int64(data.count)
            )
            if cachedTotalBytes ?? 0 > maxCacheBytes {
                trimToMaximumSize(in: directory, fileManager: fileManager)
                cachedTotalBytes = cacheByteCount(in: directory, fileManager: fileManager)
            }
        } catch {
            // Best-effort cache; ignore write failures.
        }
    }

    nonisolated private static func cacheDirectoryURL() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches
            .appendingPathComponent("gaoxipeng.bilibili", isDirectory: true)
            .appendingPathComponent("cover-image-cache", isDirectory: true)
    }

    nonisolated private static func legacyCacheDirectoryURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support
            .appendingPathComponent("gaoxipeng.bilibili", isDirectory: true)
            .appendingPathComponent("cover-image-cache", isDirectory: true)
    }

    nonisolated private static func fileURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return cacheDirectoryURL().appendingPathComponent(name, isDirectory: false)
    }

    nonisolated private static func removeExpiredFiles(in directory: URL, fileManager: FileManager) {
        let cutoff = Date().addingTimeInterval(-expirationInterval)
        for file in cacheFiles(in: directory, fileManager: fileManager) {
            guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  modified < cutoff else {
                continue
            }
            try? fileManager.removeItem(at: file)
        }
    }

    nonisolated private static func trimToMaximumSize(in directory: URL, fileManager: FileManager) {
        var files = cacheFiles(in: directory, fileManager: fileManager)
        var totalBytes = files.reduce(Int64(0)) { total, file in
            total + Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        guard totalBytes > maxCacheBytes else { return }

        files.sort {
            let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
            let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
            return (lhs ?? .distantPast) < (rhs ?? .distantPast)
        }

        for file in files where totalBytes > maxCacheBytes {
            let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            try? fileManager.removeItem(at: file)
            totalBytes -= size
        }
    }

    nonisolated private static func cacheFiles(in directory: URL, fileManager: FileManager) -> [URL] {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return files.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    nonisolated private static func cacheByteCount(in directory: URL, fileManager: FileManager) -> Int64 {
        cacheFiles(in: directory, fileManager: fileManager).reduce(Int64(0)) { total, file in
            total + Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
}
