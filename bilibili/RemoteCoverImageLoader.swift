import AppKit
import Combine
import Foundation
import ImageIO

@MainActor
final class RemoteCoverImageLoader: ObservableObject {
    @Published private(set) var image: NSImage?
    @Published private(set) var failed = false

    private var task: Task<Void, Never>?
    private var currentKey = ""

    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 800
        cache.totalCostLimit = 512 * 1024 * 1024
        return cache
    }()
    nonisolated static let maxPixelLength = 720
    nonisolated static let fullscreenMaxPixelLength = 4096
    private static let loadGate = ImageLoadGate(limit: 4)

    func primeFromMemoryCache(
        url: URL?,
        maxPixelLength: Int? = nil,
        pixelCap: Int = RemoteCoverImageLoader.maxPixelLength
    ) {
        guard let url, let cached = Self.cachedImage(
            url: url,
            maxPixelLength: maxPixelLength,
            pixelCap: pixelCap
        ) else {
            return
        }

        let maxPixel = maxPixelLength.map { Self.normalizedPixelLength($0, cap: pixelCap) }
        currentKey = Self.cacheKey(primaryURL: url, maxPixelLength: maxPixel)
        failed = false
        image = cached
    }

    func load(
        url: URL?,
        fallbackURLs: [URL] = [],
        maxPixelLength: Int? = RemoteCoverImageLoader.maxPixelLength,
        pixelCap: Int = RemoteCoverImageLoader.maxPixelLength
    ) {
        guard let url else {
            resetForMissingURL()
            return
        }

        let candidates = BiliImageURLResolver.remoteImageCandidates(
            primary: url,
            fallbackURLs: fallbackURLs
        )
        let maxPixel = maxPixelLength.map { Self.normalizedPixelLength($0, cap: pixelCap) }
        let key = Self.cacheKey(primaryURL: url, maxPixelLength: maxPixel)
        if key == currentKey, image != nil {
            return
        }
        currentKey = key
        failed = false

        if let cached = Self.cachedImage(
            url: url,
            maxPixelLength: maxPixelLength,
            pixelCap: pixelCap
        ) {
            task?.cancel()
            task = nil
            image = cached
            return
        }

        if image != nil {
            image = nil
        }
        task?.cancel()
        task = Task { [weak self] in
            await Self.loadGate.acquire()
            defer { Task { await Self.loadGate.release() } }
            guard !Task.isCancelled else { return }

            guard let loaded = await Self.fetchImage(
                candidates: candidates,
                maxPixelLength: maxPixel
            ) else {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self?.currentKey == key else { return }
                    self?.failed = true
                }
                return
            }

            guard !Task.isCancelled else { return }
            Self.store(loaded, forKey: key)
            await MainActor.run {
                guard self?.currentKey == key else { return }
                self?.image = loaded
            }
        }
    }

    func load(url: URL?, targetSize: CGSize, scale: CGFloat, fallbackURLs: [URL] = []) {
        let displayMax = max(targetSize.width, targetSize.height)
        let maxPixel = Self.normalizedPixelLength(
            Int((displayMax * max(1, scale)).rounded(.up))
        )
        load(url: url, fallbackURLs: fallbackURLs, maxPixelLength: maxPixel)
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    private func resetForMissingURL() {
        cancel()
        image = nil
        failed = true
        currentKey = ""
    }

    static func cachedImage(
        url: URL?,
        maxPixelLength: Int?,
        pixelCap: Int = RemoteCoverImageLoader.maxPixelLength
    ) -> NSImage? {
        guard let url else { return nil }
        let maxPixel = maxPixelLength.map { normalizedPixelLength($0, cap: pixelCap) }
        return cache.object(forKey: cacheKey(primaryURL: url, maxPixelLength: maxPixel) as NSString)
    }

    private static func store(_ image: NSImage, forKey key: String) {
        cache.setObject(image, forKey: key as NSString, cost: image.estimatedPixelCost)
    }

    private static func normalizedPixelLength(_ pixelLength: Int, cap: Int = maxPixelLength) -> Int {
        min(cap, max(120, pixelLength))
    }

    private static func cacheKey(primaryURL: URL, maxPixelLength: Int?) -> String {
        if let maxPixelLength {
            return "\(primaryURL.absoluteString)#\(maxPixelLength)"
        }
        return "\(primaryURL.absoluteString)#source"
    }

    private nonisolated static func decodeCachedData(_ data: Data?, maxPixelLength: Int?) -> NSImage? {
        guard let data else { return nil }
        if let maxPixelLength {
            return downsample(data: data, maxPixelLength: maxPixelLength)
        }
        return decodeFull(data: data)
    }

    private nonisolated static func fetchImage(
        candidates: [URL],
        maxPixelLength: Int?
    ) async -> NSImage? {
        for url in candidates {
            if let image = await fetchAndDecode(url: url, maxPixelLength: maxPixelLength) {
                return image
            }
        }
        return nil
    }

    private nonisolated static func fetchAndDecode(url: URL, maxPixelLength: Int?) async -> NSImage? {
        if let data = CoverImageDiskCache.data(for: url),
           let decoded = decodeCachedData(data, maxPixelLength: maxPixelLength) {
            return decoded
        }

        do {
            var request = URLRequest(url: url)
            request.cachePolicy = .returnCacheDataElseLoad
            request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                forHTTPHeaderField: "User-Agent"
            )
            request.setValue("image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")

            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse,
               !(200..<300).contains(httpResponse.statusCode) {
                return nil
            }
            try Task.checkCancellation()
            CoverImageDiskCache.save(data, for: url)
            if let maxPixelLength {
                return downsample(data: data, maxPixelLength: maxPixelLength)
            }
            return decodeFull(data: data)
        } catch {
            return nil
        }
    }

    private nonisolated static func decodeFull(data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary) else {
            return NSImage(data: data)
        }

        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return NSImage(data: data)
        }

        let size = NSSize(width: image.width, height: image.height)
        return NSImage(cgImage: image, size: size)
    }

    private nonisolated static func downsample(data: Data, maxPixelLength: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelLength,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        let size = NSSize(width: image.width, height: image.height)
        return NSImage(cgImage: image, size: size)
    }

    deinit {
        task?.cancel()
    }
}

private extension NSImage {
    var estimatedPixelCost: Int {
        guard let representation = representations.max(by: {
            ($0.pixelsWide * $0.pixelsHigh) < ($1.pixelsWide * $1.pixelsHigh)
        }) else {
            let width = Int(size.width.rounded(.up))
            let height = Int(size.height.rounded(.up))
            return max(1, width * height * 4)
        }
        return max(1, representation.pixelsWide * representation.pixelsHigh * 4)
    }
}

private actor ImageLoadGate {
    private let limit: Int
    private var inFlight = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = limit
    }

    func acquire() async {
        if inFlight < limit {
            inFlight += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
        inFlight += 1
    }

    func release() {
        inFlight = max(0, inFlight - 1)
        guard !waiters.isEmpty else { return }
        let next = waiters.removeFirst()
        next.resume()
    }
}
