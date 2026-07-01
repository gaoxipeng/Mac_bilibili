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
    private static let maxPixelLength = 720
    private static let loadGate = ImageLoadGate(limit: 4)

    func load(url: URL?, targetSize: CGSize, scale: CGFloat) {
        let maxPixel = Self.targetPixelLength(for: targetSize, scale: scale)
        load(url: url, maxPixelLength: maxPixel)
    }

    func load(url: URL?, maxPixelLength: Int) {
        guard let url else {
            resetForMissingURL()
            return
        }

        let maxPixel = Self.normalizedPixelLength(maxPixelLength)
        let key = Self.cacheKey(url: url, maxPixelLength: maxPixel)
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

            guard let loaded = await Self.fetchImage(url: url, maxPixelLength: maxPixel) else {
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

    static func cachedImage(url: URL?, maxPixelLength: Int) -> NSImage? {
        guard let url else { return nil }
        let maxPixel = normalizedPixelLength(maxPixelLength)
        return cache.object(forKey: cacheKey(url: url, maxPixelLength: maxPixel) as NSString)
    }

    private static func normalizedPixelLength(_ pixelLength: Int) -> Int {
        min(maxPixelLength, max(120, pixelLength))
    }

    private static func cacheKey(url: URL, maxPixelLength: Int) -> String {
        "\(url.absoluteString)#\(maxPixelLength)"
    }

    private nonisolated static func fetchImage(url: URL, maxPixelLength: Int) async -> NSImage? {
        await Task.detached(priority: .utility) {
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
                guard !Task.isCancelled else { return nil }
                return downsample(data: data, maxPixelLength: maxPixelLength)
            } catch {
                return nil
            }
        }.value
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
