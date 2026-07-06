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
        cache.countLimit = 480
        cache.totalCostLimit = 256 * 1024 * 1024
        return cache
    }()
    private nonisolated static let maxPixelLength = 720
    nonisolated static let fullscreenMaxPixelLength = 4096
    private static let loadGate = ImageLoadGate(limit: 4)

    func load(url: URL?, targetSize: CGSize, scale: CGFloat) {
        let maxPixel = Self.targetPixelLength(for: targetSize, scale: scale)
        let pixelSize = CGSize(
            width: targetSize.width * max(1, scale),
            height: targetSize.height * max(1, scale)
        )
        load(url: url, maxPixelLength: maxPixel, thumbnailPixelSize: pixelSize)
    }

    func load(
        url: URL?,
        maxPixelLength: Int,
        pixelCap: Int = RemoteCoverImageLoader.maxPixelLength,
        thumbnailPixelSize: CGSize? = nil
    ) {
        guard let url else {
            resetForMissingURL()
            return
        }

        let maxPixel = Self.normalizedPixelLength(maxPixelLength, cap: pixelCap)
        let key = Self.cacheKey(
            url: url,
            maxPixelLength: maxPixel,
            thumbnailPixelSize: thumbnailPixelSize
        )
        guard key != currentKey else { return }
        currentKey = key
        failed = false

        if let cached = Self.cache.object(forKey: key as NSString) {
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
                url: url,
                maxPixelLength: maxPixel,
                thumbnailPixelSize: thumbnailPixelSize
            ) else {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self?.currentKey == key else { return }
                    self?.failed = true
                }
                return
            }

            guard !Task.isCancelled else { return }
            Self.cache.setObject(loaded, forKey: key as NSString, cost: loaded.estimatedPixelCost)
            await MainActor.run {
                guard self?.currentKey == key else { return }
                self?.image = loaded
            }
        }
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

    private static func targetPixelLength(for targetSize: CGSize, scale: CGFloat) -> Int {
        let displayMax = max(targetSize.width, targetSize.height)
        let pixels = Int((displayMax * max(1, scale)).rounded(.up))
        return normalizedPixelLength(max(240, pixels))
    }

    static func cachedImage(
        url: URL?,
        maxPixelLength: Int,
        pixelCap: Int = maxPixelLength,
        thumbnailPixelSize: CGSize? = nil
    ) -> NSImage? {
        guard let url else { return nil }
        let maxPixel = normalizedPixelLength(maxPixelLength, cap: pixelCap)
        return cache.object(
            forKey: cacheKey(
                url: url,
                maxPixelLength: maxPixel,
                thumbnailPixelSize: thumbnailPixelSize
            ) as NSString
        )
    }

    private static func normalizedPixelLength(_ pixelLength: Int, cap: Int = maxPixelLength) -> Int {
        min(cap, max(120, pixelLength))
    }

    private static func cacheKey(url: URL, maxPixelLength: Int, thumbnailPixelSize: CGSize?) -> String {
        let thumbnailSize = thumbnailDimensions(
            maxPixelLength: maxPixelLength,
            thumbnailPixelSize: thumbnailPixelSize
        )
        if thumbnailSize.width == 0 || thumbnailSize.height == 0 {
            return "\(url.absoluteString)#\(maxPixelLength)#source"
        }
        return "\(url.absoluteString)#\(maxPixelLength)#\(thumbnailSize.width)x\(thumbnailSize.height)"
    }

    private nonisolated static func fetchImage(
        url: URL,
        maxPixelLength: Int,
        thumbnailPixelSize: CGSize?
    ) async -> NSImage? {
        let primaryURL = thumbnailURL(for: url, maxPixelLength: maxPixelLength, thumbnailPixelSize: thumbnailPixelSize)

        if let image = await fetchAndDownsample(url: primaryURL, maxPixelLength: maxPixelLength) {
            return image
        }

        guard primaryURL.absoluteString != url.absoluteString else { return nil }
        return await fetchAndDownsample(url: url, maxPixelLength: maxPixelLength)
    }

    private nonisolated static func fetchAndDownsample(url: URL, maxPixelLength: Int) async -> NSImage? {
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
            return downsample(data: data, maxPixelLength: maxPixelLength)
        } catch {
            return nil
        }
    }

    private nonisolated static func thumbnailURL(
        for url: URL,
        maxPixelLength: Int,
        thumbnailPixelSize: CGSize?
    ) -> URL {
        guard let host = url.host(percentEncoded: false)?.lowercased(),
              host.hasSuffix("hdslb.com"),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }

        let path = components.percentEncodedPath
        let lowercasePath = path.lowercased()
        guard path.contains("/bfs/"),
              !path.contains("@"),
              lowercasePath.hasSuffix(".jpg")
                || lowercasePath.hasSuffix(".jpeg")
                || lowercasePath.hasSuffix(".png")
                || lowercasePath.hasSuffix(".webp") else {
            return url
        }

        let size = thumbnailDimensions(maxPixelLength: maxPixelLength, thumbnailPixelSize: thumbnailPixelSize)
        guard size.width > 0, size.height > 0 else { return url }

        components.percentEncodedPath = "\(path)@\(size.width)w_\(size.height)h_1c.webp"
        return components.url ?? url
    }

    private nonisolated static func thumbnailDimensions(
        maxPixelLength: Int,
        thumbnailPixelSize: CGSize?
    ) -> (width: Int, height: Int) {
        let maxPixel = min(2048, max(48, maxPixelLength))
        guard maxPixel <= 1200 else {
            return (0, 0)
        }

        let fallbackSize: CGSize
        if maxPixel <= 180 {
            fallbackSize = CGSize(width: CGFloat(maxPixel), height: CGFloat(maxPixel))
        } else {
            fallbackSize = CGSize(width: CGFloat(maxPixel), height: CGFloat(maxPixel) / (16.0 / 9.0))
        }

        let rawSize = thumbnailPixelSize ?? fallbackSize
        let width = min(2048, max(48, Int(rawSize.width.rounded(.up))))
        let height = min(2048, max(48, Int(rawSize.height.rounded(.up))))
        return (width, height)
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
