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

            let faceRequest = VNDetectFaceLandmarksRequest()
            let segmentationRequest = VNGeneratePersonSegmentationRequest()
            segmentationRequest.qualityLevel = .fast
            segmentationRequest.outputPixelFormat = kCVPixelFormatType_OneComponent8
            let handler = VNImageRequestHandler(
                cvPixelBuffer: pixelBuffer,
                orientation: .up,
                options: [:]
            )
            try? handler.perform([faceRequest, segmentationRequest])

            let segmentation = (segmentationRequest.results ?? []).first?.pixelBuffer
            let detected = (faceRequest.results ?? []).compactMap { observation -> DetectedFace? in
                let box = observation.boundingBox
                let contour = self.landmarkContour(for: observation)
                    ?? self.segmentationContour(
                        in: box,
                        pixelBuffer: segmentation
                    )
                    ?? self.ellipseContour(for: box)
                return DetectedFace(boundingBox: box, contour: contour)
            }
            let smoothed = self.smooth(detected)

            self.lock.lock()
            guard self.inputGeneration == inputGeneration, self.enabled else {
                self.lock.unlock()
                return
            }
            self.faces = smoothed.map { Face(boundingBox: $0.boundingBox, contour: $0.contour) }
            self.generation &+= 1
            self.lock.unlock()
        }
    }

    func reset() {
        lock.lock()
        faces.removeAll(keepingCapacity: true)
        trackedFaces.removeAll(keepingCapacity: true)
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

    private func landmarkContour(for observation: VNFaceObservation) -> [CGPoint]? {
        guard let points = observation.landmarks?.faceContour?.normalizedPoints,
              points.count >= 3 else { return nil }
        let box = observation.boundingBox
        return points.map { point in
            CGPoint(
                x: box.minX + point.x * box.width,
                y: box.minY + point.y * box.height
            )
        }
    }

    /// Uses the person mask only as a fallback when landmarks are unavailable.
    /// The convex hull keeps the result contour-shaped while remaining cheap at
    /// the low analysis resolution.
    private func segmentationContour(
        in face: CGRect,
        pixelBuffer: CVPixelBuffer?
    ) -> [CGPoint]? {
        guard let pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        var points: [CGPoint] = []
        points.reserveCapacity(128)
        for y in stride(from: 0, to: height, by: 2) {
            let row = baseAddress.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in stride(from: 0, to: width, by: 2) {
                guard row[x] >= 150 else { continue }
                let normalized = CGPoint(
                    x: CGFloat(x) / CGFloat(max(1, width - 1)),
                    y: 1 - CGFloat(y) / CGFloat(max(1, height - 1))
                )
                if face.insetBy(dx: -face.width * 0.25, dy: -face.height * 0.25).contains(normalized) {
                    points.append(normalized)
                }
            }
        }
        return convexHull(points)
    }

    private func ellipseContour(for box: CGRect) -> [CGPoint] {
        let center = CGPoint(x: box.midX, y: box.midY)
        let radiusX = box.width * 0.48
        let radiusY = box.height * 0.52
        return (0..<20).map { index in
            let angle = (CGFloat(index) / 20) * 2 * .pi
            return CGPoint(
                x: center.x + cos(angle) * radiusX,
                y: center.y + sin(angle) * radiusY
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
                result.append(face)
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

    private func convexHull(_ points: [CGPoint]) -> [CGPoint]? {
        guard points.count >= 3 else { return nil }
        let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        func cross(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }
        var lower: [CGPoint] = []
        for point in sorted {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], point) <= 0 {
                lower.removeLast()
            }
            lower.append(point)
        }
        var upper: [CGPoint] = []
        for point in sorted.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], point) <= 0 {
                upper.removeLast()
            }
            upper.append(point)
        }
        lower.removeLast()
        upper.removeLast()
        let hull = lower + upper
        return hull.count >= 3 ? hull : nil
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
