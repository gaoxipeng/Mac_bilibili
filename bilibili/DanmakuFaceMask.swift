import CoreVideo
import Foundation
import Vision

/// Runs low-resolution face detection off the main thread and publishes a
/// small, thread-safe set of normalized face rectangles for the danmaku layer.
/// The detector is deliberately sampled at a low rate; Core Animation still
/// composites the scrolling comments at the display's refresh rate.
final class DanmakuFaceMaskAnalyzer: @unchecked Sendable {
    struct Snapshot: Sendable {
        let generation: UInt64
        let faces: [CGRect]
    }

    private let queue = DispatchQueue(
        label: "bilibili.danmaku-face-mask",
        qos: .utility
    )
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var inputGeneration: UInt64 = 0
    private var faces: [CGRect] = []
    private var analysisPending = false

    func submit(data: Data, width: Int, height: Int, bytesPerRow: Int) {
        guard width > 1, height > 1, bytesPerRow >= width * 4 else { return }

        lock.lock()
        guard !analysisPending else {
            lock.unlock()
            return
        }
        analysisPending = true
        let inputGeneration = self.inputGeneration
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            defer {
                self.lock.lock()
                self.analysisPending = false
                self.lock.unlock()
            }
            guard let pixelBuffer = self.makePixelBuffer(
                data: data,
                width: width,
                height: height,
                bytesPerRow: bytesPerRow
            ) else { return }

            let request = VNDetectFaceRectanglesRequest()
            let handler = VNImageRequestHandler(
                cvPixelBuffer: pixelBuffer,
                orientation: .up,
                options: [:]
            )
            try? handler.perform([request])
            let detectedFaces = (request.results ?? []).map(\.boundingBox)

            self.lock.lock()
            guard self.inputGeneration == inputGeneration else {
                self.lock.unlock()
                return
            }
            self.faces = detectedFaces
            self.generation &+= 1
            self.lock.unlock()
        }
    }

    func reset() {
        lock.lock()
        faces.removeAll(keepingCapacity: true)
        inputGeneration &+= 1
        generation &+= 1
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        let result = Snapshot(generation: generation, faces: faces)
        lock.unlock()
        return result
    }

    private func makePixelBuffer(
        data: Data,
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            ] as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let destination = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let destinationBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        data.withUnsafeBytes { source in
            guard let sourceBase = source.baseAddress else { return }
            for row in 0..<height {
                let sourceOffset = row * bytesPerRow
                guard sourceOffset + width * 4 <= data.count else { return }
                let sourceRow = sourceBase.advanced(by: sourceOffset)
                let destinationRow = destination.advanced(by: row * destinationBytesPerRow)
                memcpy(destinationRow, sourceRow, width * 4)
            }
        }
        return pixelBuffer
    }
}
