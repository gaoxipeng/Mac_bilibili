import CoreML
import CoreVideo
import Foundation
import OSLog
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

    // Different players can overlap briefly while navigating. Keep Vision's
    // model work serialized across analyzers as well as across video frames.
    private static let queue = DispatchQueue(
        label: "bilibili.danmaku-face-mask",
        qos: .utility
    )
    private static let logger = Logger(subsystem: "gaoxipeng.bilibili", category: "DanmakuVision")
    // Accessed only on the shared analysis queue.
    private var requests: (generation: UInt64, face: VNDetectFaceRectanglesRequest, person: VNGeneratePersonSegmentationRequest)?
    private var reportedAnalysisError = false
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var inputGeneration: UInt64 = 0
    private var faces: [Face] = []
    private var trackedFaces: [DetectedFace] = []
    private var analysisPending = false
    private var consecutiveMisses = 0
    private var enabled = true
    private var mode: DanmakuAvoidanceMode = .face

    var isEnabled: Bool {
        lock.lock()
        let value = enabled
        lock.unlock()
        return value
    }

    func setMode(_ mode: DanmakuAvoidanceMode) {
        lock.lock()
        guard self.mode != mode else {
            lock.unlock()
            return
        }
        self.mode = mode
        enabled = mode != .off
        faces.removeAll(keepingCapacity: true)
        trackedFaces.removeAll(keepingCapacity: true)
        consecutiveMisses = 0
        inputGeneration &+= 1
        generation &+= 1
        lock.unlock()
    }

    func submit(data: Data, width: Int, height: Int, bytesPerRow: Int) {
        guard width > 1, height > 1,
              width <= Int.max / 4,
              bytesPerRow >= width * 4,
              height <= Int.max / bytesPerRow,
              data.count >= height * bytesPerRow else { return }

        lock.lock()
        guard enabled, !analysisPending else {
            lock.unlock()
            return
        }
        analysisPending = true
        let inputGeneration = self.inputGeneration
        let mode = self.mode
        lock.unlock()

        Self.queue.async { [weak self] in
            guard let self else { return }
            defer {
                self.lock.lock()
                self.analysisPending = false
                self.lock.unlock()
            }

            // Bound Objective-C / Vision temporaries to one frame rather than
            // letting them accumulate during a long playback session.
            autoreleasepool {
                self.lock.lock()
                let isCurrent = self.enabled && self.inputGeneration == inputGeneration
                self.lock.unlock()
                guard isCurrent else { return }

                guard let pixelBuffer = self.makePixelBuffer(
                    data: data,
                    width: width,
                    height: height,
                    bytesPerRow: bytesPerRow
                ) else { return }

                let faceRequest: VNDetectFaceRectanglesRequest
                let personRequest: VNGeneratePersonSegmentationRequest
                let handler = VNImageRequestHandler(
                    cvPixelBuffer: pixelBuffer,
                    orientation: .up,
                    options: [:]
                )
                do {
                    let requests = try self.analysisRequests(for: inputGeneration)
                    faceRequest = requests.face
                    personRequest = requests.person
                    // Hold the input, requests and handler through synchronous
                    // completion of Vision's internally dispatched detector work.
                    try withExtendedLifetime((pixelBuffer, handler, faceRequest, personRequest)) {
                        try handler.perform(mode == .face ? [faceRequest, personRequest] : [personRequest])
                    }
                    self.reportedAnalysisError = false
                } catch {
                    if !self.reportedAnalysisError {
                        Self.logger.error("Danmaku analysis skipped: \(error.localizedDescription, privacy: .public)")
                        self.reportedAnalysisError = true
                    }
                    return
                }
                let personMask = personRequest.results?.first?.pixelBuffer
                let detected: [DetectedFace]
                switch mode {
                case .off:
                    detected = []
                case .face:
                    detected = (faceRequest.results ?? []).compactMap { observation in
                            let box = observation.boundingBox
                            guard let contour = self.headSegmentationContour(around: box, pixelBuffer: personMask) else {
                                return nil
                            }
                            return DetectedFace(boundingBox: box, contour: contour)
                        }
                case .person:
                    detected = self.personSegmentationShapes(pixelBuffer: personMask)
                }
                self.lock.lock()
                defer { self.lock.unlock() }
                // Check before modifying *any* tracking state. Reset/mode changes
                // may happen while Vision is processing an older frame.
                guard self.inputGeneration == inputGeneration, self.enabled else { return }
                let stableDetected: [DetectedFace]
                if detected.isEmpty, !self.trackedFaces.isEmpty, self.consecutiveMisses < 1 {
                    // Ignore one transient missed analysis (one 12 Hz sample).
                    self.consecutiveMisses += 1
                    stableDetected = self.trackedFaces
                } else {
                    self.consecutiveMisses = 0
                    stableDetected = detected
                }
                let smoothed = self.smooth(stableDetected, previous: self.trackedFaces)
                self.trackedFaces = smoothed
                self.faces = smoothed.map {
                    Face(
                        boundingBox: $0.boundingBox,
                        contour: $0.contour
                    )
                }
                self.generation &+= 1
            }
        }
    }

    /// Select only devices advertised by Vision, without entering the ANE
    /// pixel-buffer copy path implicated in the macOS 27.2 crash report.
    private func analysisRequests(for generation: UInt64) throws -> (face: VNDetectFaceRectanglesRequest, person: VNGeneratePersonSegmentationRequest) {
        if let requests, requests.generation == generation {
            return (requests.face, requests.person)
        }
        let person = VNGeneratePersonSegmentationRequest()
        person.qualityLevel = .accurate
        person.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let stages = try person.supportedComputeStageDevices
        guard stages[.main] != nil else {
            throw NSError(domain: "DanmakuVision", code: 1, userInfo: [NSLocalizedDescriptionKey: "No supported segmentation compute stage"])
        }
        for (stage, devices) in stages {
            let gpu = devices.first { if case .gpu = $0 { return true }; return false }
            let cpu = devices.first { if case .cpu = $0 { return true }; return false }
            guard let device = gpu ?? cpu else {
                throw NSError(domain: "DanmakuVision", code: 2, userInfo: [NSLocalizedDescriptionKey: "No supported GPU/CPU device for segmentation"])
            }
            person.setComputeDevice(device, for: stage)
        }
        let face = VNDetectFaceRectanglesRequest()
        requests = (generation, face, person)
        return (face, person)
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

    /// Finds each foreground person component and traces its full-height
    /// silhouette for the person-avoidance mode.
    private func personSegmentationShapes(pixelBuffer: CVPixelBuffer?) -> [DetectedFace] {
        guard let pixelBuffer else { return [] }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return [] }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 1, height > 1 else { return [] }

        let pixelCount = width * height
        var foreground = [Bool](repeating: false, count: pixelCount)
        for y in 0..<height {
            let row = baseAddress.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            let rowStart = y * width
            for x in 0..<width {
                foreground[rowStart + x] = row[x] >= 96
            }
        }

        let minimumComponentSize = max(24, pixelCount / 12_000)
        var visited = [Bool](repeating: false, count: pixelCount)
        var shapes: [DetectedFace] = []
        for seed in 0..<pixelCount where foreground[seed] && !visited[seed] {
            var component = [seed]
            component.reserveCapacity(256)
            visited[seed] = true
            var cursor = 0
            while cursor < component.count {
                let current = component[cursor]
                cursor += 1
                let x = current % width
                let y = current / width
                for offsetY in -1...1 {
                    let nextY = y + offsetY
                    guard nextY >= 0, nextY < height else { continue }
                    for offsetX in -1...1 where offsetX != 0 || offsetY != 0 {
                        let nextX = x + offsetX
                        guard nextX >= 0, nextX < width else { continue }
                        let next = nextY * width + nextX
                        guard foreground[next], !visited[next] else { continue }
                        visited[next] = true
                        component.append(next)
                    }
                }
            }
            guard component.count >= minimumComponentSize else { continue }

            var leftByRow = [Int](repeating: width, count: height)
            var rightByRow = [Int](repeating: -1, count: height)
            var minX = width
            var maxX = 0
            var minY = height
            var maxY = 0
            for index in component {
                let x = index % width
                let y = index / width
                leftByRow[y] = min(leftByRow[y], x)
                rightByRow[y] = max(rightByRow[y], x)
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }

            var leftEdge: [CGPoint] = []
            var rightEdge: [CGPoint] = []
            for y in minY...maxY where rightByRow[y] >= leftByRow[y] {
                let normalizedY = 1 - CGFloat(y) / CGFloat(height - 1)
                leftEdge.append(CGPoint(x: CGFloat(leftByRow[y]) / CGFloat(width - 1), y: normalizedY))
                rightEdge.append(CGPoint(x: CGFloat(rightByRow[y]) / CGFloat(width - 1), y: normalizedY))
            }
            guard leftEdge.count >= 2 else { continue }
            let contour = smoothEdge(leftEdge) + smoothEdge(rightEdge).reversed()
            let box = CGRect(
                x: CGFloat(minX) / CGFloat(width - 1),
                y: 1 - CGFloat(maxY) / CGFloat(height - 1),
                width: CGFloat(maxX - minX) / CGFloat(width - 1),
                height: CGFloat(maxY - minY) / CGFloat(height - 1)
            )
            shapes.append(DetectedFace(boundingBox: box, contour: contour))
        }
        return shapes
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
        // Face rectangles omit hair by design, especially behind a profile.
        // Use a wider ROI, then keep only the connected person-mask component
        // containing this face so nearby people/background aren't swept in.
        let minX = max(0, face.minX - face.width * 1.6)
        let maxX = min(1, face.maxX + face.width * 1.6)
        // Extend below the detected face box so a low-confidence jaw/chin is
        // not cut off at the detector's rectangle boundary.
        let minY = max(0, face.minY - face.height * 0.28)
        let maxY = min(1, face.maxY + face.height * 1.10)
        let x0 = max(0, Int((minX * CGFloat(width - 1)).rounded(.down)))
        let x1 = min(width - 1, Int((maxX * CGFloat(width - 1)).rounded(.up)))
        let y0 = max(0, Int(((1 - maxY) * CGFloat(height - 1)).rounded(.down)))
        let y1 = min(height - 1, Int(((1 - minY) * CGFloat(height - 1)).rounded(.up)))
        guard x1 > x0, y1 > y0 else { return nil }

        let roiWidth = x1 - x0 + 1
        let roiHeight = y1 - y0 + 1
        var foreground = [Bool](repeating: false, count: roiWidth * roiHeight)
        for localY in 0..<roiHeight {
            let pixelY = y0 + localY
            let row = baseAddress.advanced(by: pixelY * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            let normalizedY = 1 - CGFloat(pixelY) / CGFloat(max(1, height - 1))
            let distanceBelowFace = face.minY - normalizedY
            let threshold: UInt8 = (-face.height * 0.12...face.height * 0.35).contains(distanceBelowFace)
                ? 64
                : 96
            for localX in 0..<roiWidth {
                foreground[localY * roiWidth + localX] = row[x0 + localX] >= threshold
            }
        }

        // Anchor the flood fill inside the detected face. This prevents a
        // neighboring person's mask from extending the back-of-head edge.
        let faceX0 = max(x0, Int((face.minX * CGFloat(width - 1)).rounded(.down)))
        let faceX1 = min(x1, Int((face.maxX * CGFloat(width - 1)).rounded(.up)))
        let faceY0 = max(y0, Int(((1 - face.maxY) * CGFloat(height - 1)).rounded(.down)))
        let faceY1 = min(y1, Int(((1 - face.minY) * CGFloat(height - 1)).rounded(.up)))
        let anchorX = min(x1, max(x0, Int((face.midX * CGFloat(width - 1)).rounded())))
        let anchorY = min(y1, max(y0, Int(((1 - face.midY) * CGFloat(height - 1)).rounded())))
        var seed: Int?
        var nearestDistance = Int.max
        if faceX0 <= faceX1, faceY0 <= faceY1 {
            for pixelY in faceY0...faceY1 {
                for pixelX in faceX0...faceX1 {
                    let localX = pixelX - x0
                    let localY = pixelY - y0
                    let index = localY * roiWidth + localX
                    guard foreground[index] else { continue }
                    let dx = pixelX - anchorX
                    let dy = pixelY - anchorY
                    let distance = dx * dx + dy * dy
                    if distance < nearestDistance {
                        seed = index
                        nearestDistance = distance
                    }
                }
            }
        }
        guard let seed else { return nil }

        var component = [Bool](repeating: false, count: foreground.count)
        var queue = [seed]
        component[seed] = true
        var queueIndex = 0
        while queueIndex < queue.count {
            let current = queue[queueIndex]
            queueIndex += 1
            let currentX = current % roiWidth
            let currentY = current / roiWidth
            for offsetY in -1...1 {
                let nextY = currentY + offsetY
                guard nextY >= 0, nextY < roiHeight else { continue }
                for offsetX in -1...1 where offsetX != 0 || offsetY != 0 {
                    let nextX = currentX + offsetX
                    guard nextX >= 0, nextX < roiWidth else { continue }
                    let next = nextY * roiWidth + nextX
                    guard foreground[next], !component[next] else { continue }
                    component[next] = true
                    queue.append(next)
                }
            }
        }

        var leftEdge: [CGPoint] = []
        var rightEdge: [CGPoint] = []
        leftEdge.reserveCapacity(roiHeight)
        rightEdge.reserveCapacity(roiHeight)
        for localY in 0..<roiHeight {
            var first: Int?
            var last: Int?
            for localX in 0..<roiWidth where component[localY * roiWidth + localX] {
                if first == nil { first = localX }
                last = localX
            }
            guard let first, let last else { continue }
            let pixelY = y0 + localY
            let normalizedY = 1 - CGFloat(pixelY) / CGFloat(max(1, height - 1))
            leftEdge.append(CGPoint(
                x: CGFloat(x0 + first) / CGFloat(max(1, width - 1)),
                y: normalizedY
            ))
            rightEdge.append(CGPoint(
                x: CGFloat(x0 + last) / CGFloat(max(1, width - 1)),
                y: normalizedY
            ))
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

    private func smooth(_ detected: [DetectedFace], previous: [DetectedFace]) -> [DetectedFace] {

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
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            ] as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else { return nil }

        guard CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let destination = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let destinationBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard destinationBytesPerRow >= width * 4 else { return nil }
        data.withUnsafeBytes { source in
            guard let sourceBase = source.baseAddress else { return }
            for row in 0..<height {
                let sourceOffset = row * bytesPerRow
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
