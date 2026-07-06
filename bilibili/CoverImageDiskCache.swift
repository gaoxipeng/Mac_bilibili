import CryptoKit
import Foundation

enum CoverImageDiskCache: Sendable {
    nonisolated static func data(for url: URL) -> Data? {
        let fileURL = fileURL(for: url)
        return try? Data(contentsOf: fileURL, options: [.mappedIfSafe])
    }

    nonisolated static func save(_ data: Data, for url: URL) {
        let fileURL = fileURL(for: url)
        do {
            try FileManager.default.createDirectory(at: cacheDirectoryURL(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Best-effort cache; ignore write failures.
        }
    }

    nonisolated private static func cacheDirectoryURL() -> URL {
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
}
