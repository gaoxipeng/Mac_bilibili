import CoreVideo
import Foundation
import Vision

/// Low-resolution, local face analysis for the danmaku compositor.
///
/// Vision work is deliberately kept off the render and main queues. The
/// published result is a smoothed face contour rather than a face rectangle,
/// so the mask follows the visible head shape without blanking a large box.
final class DanmakuFaceMaskAnalyzer: @unchecked Sendable {
    struct Face: Sendable {
        let boundingBox: CGRect
        let contour: [CGPoint]
    }

    struct Snapshot: Sendable {
        let generation: UInt64
        let faces: [Face]
    }

    private struct DetectedFace {
        var boundingBox: CGRect
        var contour: [CGPoint]
    }

    private let queue = DispatchQueue(
        label: "bilibili.danmaku-face-mask",
        qos: .utility
    )
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var inputGeneration: UInt64 = 0
    private var faces: [Face] = []
    private var trackedFaces: [DetectedFace] = []
    private var analysisPending = false
    private var consecutiveMisses = 0
    private var enabled = true

    var isEnabled: Bool {
        lock.lock()
        let value = enabled
        lock.unlock()
        return value
    }

    func setEnabled(_ enabled: Bool) {
        lock.lock()
        self.enabled = enabled
        if !enabled {
            faces.removeAll(keepingCapacity: true)
            trackedFaces.removeAll(keepingCapacity: true)
            consecutiveMisses = 0
            inputGeneration &+= 1
            generation &+= 1
        }
        lock.unlock()
    }

    func submit(data: Data, width: Int, height: Int, bytesPerRow: Int) {
        guard width > 1, height > 1, bytesPerRow >= width * 4 else { return }

        lock.lock()
        guard enabled, !analysisPending else {
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

            let faceRequest = VNDetectFaceRectanglesRequest()
            let personRequest = VNGeneratePersonSegmentationRequest()
            personRequest.qualityLevel = .accurate
            personRequest.outputPixelFormat = kCVPixelFormatType_OneComponent8
            let handler = VNImageRequestHandler(
                cvPixelBuffer: pixelBuffer,
                orientation: .up,
                options: [:]
            )
            try? handler.perform([faceRequest, personRequest])
            let personMask = personRequest.results?.first?.pixelBuffer
            let detected = (faceRequest.results ?? []).compactMap { observation -> DetectedFace? in
                let box = observation.boundingBox
                // Only use the segmented head silhouette. If segmentation
                // cannot provide a reliable contour, leave this face unmasked
                // instead of substituting a coarse landmark/ellipse shape.
                guard let contour = self.headSegmentationContour(around: box, pixelBuffer: personMask) else {
                    return nil
                }
                return DetectedFace(boundingBox: box, contour: contour)
            }
            self.lock.lock()
            let stableDetected: [DetectedFace]
            if detected.isEmpty, !self.trackedFaces.isEmpty, self.consecutiveMisses < 1 {
                // Ignore one transient missed analysis, but at 8 Hz retain the
                // old contour for no more than roughly 125 ms.
                self.consecutiveMisses += 1
                stableDetected = self.trackedFaces
            } else {
                self.consecutiveMisses = 0
                stableDetected = detected
            }
            self.lock.unlock()
            let smoothed = self.smooth(stableDetected)

            self.lock.lock()
            guard self.inputGeneration == inputGeneration, self.enabled else {
                self.lock.unlock()
                return
            }
            self.faces = smoothed.map {
                Face(
                    boundingBox: $0.boundingBox,
                    contour: $0.contour
                )
            }
            self.generation &+= 1
            self.lock.unlock()
        }
    }

    func reset() {
        lock.lock()
        faces.removeAll(keepingCapacity: true)
        trackedFaces.removeAll(keepingCapacity: true)
        consecutiveMisses = 0
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

    /// Traces a head-shaped envelope from the upper-person segmentation mask.
    /// The ROI spans from above the forehead to the lower face and stays narrow
    /// enough to avoid pulling shoulders into the contour.
    private func headSegmentationContour(
        around face: CGRect,
        pixelBuffer: CVPixelBuffer?
    ) -> [CGPoint]? {
        guard let pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let minX = max(0, face.minX - face.width * 0.42)
        let maxX = min(1, face.maxX + face.width * 0.42)
        let minY = max(0, face.minY - face.height * 0.08)
        let maxY = min(1, face.maxY + face.height * 0.82)
        let x0 = max(0, Int((minX * CGFloat(width - 1)).rounded(.down)))
        let x1 = min(width - 1, Int((maxX * CGFloat(width - 1)).rounded(.up)))
        var leftEdge: [CGPoint] = []
        var rightEdge: [CGPoint] = []
        leftEdge.reserveCapacity(96)
        rightEdge.reserveCapacity(96)
        for y in stride(from: 0, to: height, by: 1) {
            let normalizedY = 1 - CGFloat(y) / CGFloat(max(1, height - 1))
            guard normalizedY >= minY, normalizedY <= maxY else { continue }
            let row = baseAddress.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            var first: Int?
            var last: Int?
            var foregroundCount = 0
            for x in stride(from: x0, through: x1, by: 1) where row[x] >= 128 {
                if first == nil { first = x }
                last = x
                foregroundCount += 1
            }
            guard foregroundCount >= 3, let first, let last, last > first else { continue }
            let normalized = 1 - CGFloat(y) / CGFloat(max(1, height - 1))
            leftEdge.append(CGPoint(x: CGFloat(first) / CGFloat(max(1, width - 1)), y: normalized))
            rightEdge.append(CGPoint(x: CGFloat(last) / CGFloat(max(1, width - 1)), y: normalized))
        }
        guard leftEdge.count >= 6 else { return nil }
        // Lightly smooth row-to-row mask noise while preserving the silhouette.
        let left = smoothEdge(leftEdge)
        let right = smoothEdge(rightEdge).reversed()
        return left + right
    }

    private func smoothEdge(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count >= 3 else { return points }
        return points.indices.map { index in
            guard index > 0, index < points.count - 1 else { return points[index] }
            return CGPoint(
                x: (points[index - 1].x + points[index].x * 2 + points[index + 1].x) / 4,
                y: points[index].y
            )
        }
    }

    private func smooth(_ detected: [DetectedFace]) -> [DetectedFace] {
        lock.lock()
        let previous = trackedFaces
        lock.unlock()

        let alpha: CGFloat = 0.34
        var result: [DetectedFace] = []
        result.reserveCapacity(detected.count)
        var used = Set<Int>()
        for face in detected.sorted(by: { $0.boundingBox.midX < $1.boundingBox.midX }) {
            var bestIndex: Int?
            var bestScore: CGFloat = 0
            for (index, old) in previous.enumerated() where !used.contains(index) {
                let score = intersectionOverUnion(face.boundingBox, old.boundingBox)
                if score > bestScore {
                    bestScore = score
                    bestIndex = index
                }
            }
            if let bestIndex, bestScore >= 0.18 {
                used.insert(bestIndex)
                let old = previous[bestIndex]
                let box = blend(old.boundingBox, face.boundingBox, amount: alpha)
                let contour = face.contour.count == old.contour.count
                    ? zip(old.contour, face.contour).map { blend($0.0, $0.1, amount: alpha) }
                    : face.contour
                result.append(DetectedFace(boundingBox: box, contour: contour))
            } else {
                result.append(DetectedFace(boundingBox: face.boundingBox, contour: face.contour))
            }
        }

        lock.lock()
        trackedFaces = result
        lock.unlock()
        return result
    }

    private func blend(_ old: CGRect, _ new: CGRect, amount: CGFloat) -> CGRect {
        CGRect(
            x: old.minX + (new.minX - old.minX) * amount,
            y: old.minY + (new.minY - old.minY) * amount,
            width: old.width + (new.width - old.width) * amount,
            height: old.height + (new.height - old.height) * amount
        )
    }

    private func blend(_ old: CGPoint, _ new: CGPoint, amount: CGFloat) -> CGPoint {
        CGPoint(
            x: old.x + (new.x - old.x) * amount,
            y: old.y + (new.y - old.y) * amount
        )
    }

    private func intersectionOverUnion(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let unionArea = lhs.union(rhs).width * lhs.union(rhs).height
        guard unionArea > 0 else { return 0 }
        return (lhs.intersection(rhs).width * lhs.intersection(rhs).height) / unionArea
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
                memcpy(
                    destination.advanced(by: row * destinationBytesPerRow),
                    sourceBase.advanced(by: sourceOffset),
                    width * 4
                )
            }
        }
        return pixelBuffer
    }
}
