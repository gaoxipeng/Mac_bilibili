import CoreGraphics
import SwiftUI

nonisolated struct BiliSVGPathShape: Shape {
    let pathData: String
    var viewBox: CGFloat = 1024
    var viewBoxRect: CGRect?

    nonisolated func path(in rect: CGRect) -> Path {
        if let viewBoxRect {
            BiliSVGPathParser.makePath(pathData, in: rect, viewBoxRect: viewBoxRect)
        } else {
            BiliSVGPathParser.makePath(pathData, in: rect, viewBox: viewBox)
        }
    }
}

nonisolated enum BiliSVGPathParser {
    nonisolated static func makePath(_ data: String, in rect: CGRect, viewBox: CGFloat = 1024) -> Path {
        makePath(
            data,
            in: rect,
            viewBoxRect: CGRect(x: 0, y: 0, width: viewBox, height: viewBox)
        )
    }

    nonisolated static func makePath(_ data: String, in rect: CGRect, viewBoxRect: CGRect) -> Path {
        let cgPath = parse(data)
        let scale = min(rect.width / viewBoxRect.width, rect.height / viewBoxRect.height)
        let fittedWidth = viewBoxRect.width * scale
        let fittedHeight = viewBoxRect.height * scale
        let originX = rect.minX + (rect.width - fittedWidth) / 2
        let originY = rect.minY + (rect.height - fittedHeight) / 2
        var transform = CGAffineTransform(translationX: originX, y: originY)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -viewBoxRect.minX, y: -viewBoxRect.minY)
        guard let scaled = cgPath.copy(using: &transform) else {
            return Path(cgPath)
        }
        return Path(scaled)
    }

    private nonisolated(unsafe) static let parsedPathCache: NSCache<NSString, CGPath> = {
        let cache = NSCache<NSString, CGPath>()
        cache.countLimit = 96
        return cache
    }()

    private nonisolated static func parse(_ data: String) -> CGPath {
        let key = data as NSString
        if let cached = parsedPathCache.object(forKey: key) {
            return cached
        }
        let path = parseUncached(data)
        parsedPathCache.setObject(path, forKey: key)
        return path
    }

    private nonisolated static func parseUncached(_ data: String) -> CGPath {
        let path = CGMutablePath()
        let tokens = tokenize(data)
        var index = 0
        var current = CGPoint.zero
        var start = CGPoint.zero
        var lastControl2: CGPoint?
        var lastQuadraticControl: CGPoint?
        var lastCommand: Character?

        func readDouble() -> CGFloat {
            guard index < tokens.count else { return 0 }
            let value = CGFloat(Double(tokens[index]) ?? 0)
            index += 1
            return value
        }

        func readPoint() -> CGPoint {
            CGPoint(x: readDouble(), y: readDouble())
        }

        func readFlag() -> Bool {
            readDouble() != 0
        }

        func absolutePoint(_ point: CGPoint, relative: Bool) -> CGPoint {
            relative ? CGPoint(x: current.x + point.x, y: current.y + point.y) : point
        }

        func reflectedControl(_ control: CGPoint) -> CGPoint {
            CGPoint(x: 2 * current.x - control.x, y: 2 * current.y - control.y)
        }

        func canReflectCubic() -> Bool {
            guard let lastCommand else { return false }
            return "CcSs".contains(lastCommand)
        }

        func canReflectQuadratic() -> Bool {
            guard let lastCommand else { return false }
            return "QqTt".contains(lastCommand)
        }

        func noteCurveCommand(_ command: Character) {
            lastCommand = command
        }

        func noteNonCurveCommand(_ command: Character) {
            lastCommand = command
            lastControl2 = nil
            lastQuadraticControl = nil
        }

        while index < tokens.count {
            let token = tokens[index]
            index += 1
            guard let command = token.first else { continue }
            let isRelative = command.isLowercase
            let cmd = String(command).uppercased()

            switch cmd {
            case "M":
                let point = readPoint()
                current = absolutePoint(point, relative: isRelative)
                start = current
                path.move(to: current)
                noteNonCurveCommand(command)
                while index < tokens.count, Double(tokens[index]) != nil {
                    let linePoint = readPoint()
                    current = absolutePoint(linePoint, relative: isRelative)
                    path.addLine(to: current)
                    noteNonCurveCommand("L")
                }
            case "L":
                while index < tokens.count, Double(tokens[index]) != nil {
                    let point = readPoint()
                    current = absolutePoint(point, relative: isRelative)
                    path.addLine(to: current)
                }
                noteNonCurveCommand(command)
            case "H":
                while index < tokens.count, Double(tokens[index]) != nil {
                    let x = readDouble()
                    current = CGPoint(x: isRelative ? current.x + x : x, y: current.y)
                    path.addLine(to: current)
                }
                noteNonCurveCommand(command)
            case "V":
                while index < tokens.count, Double(tokens[index]) != nil {
                    let y = readDouble()
                    current = CGPoint(x: current.x, y: isRelative ? current.y + y : y)
                    path.addLine(to: current)
                }
                noteNonCurveCommand(command)
            case "C":
                while index < tokens.count, Double(tokens[index]) != nil {
                    let control1 = readPoint()
                    let control2 = readPoint()
                    let end = readPoint()
                    let absoluteControl1 = absolutePoint(control1, relative: isRelative)
                    let absoluteControl2 = absolutePoint(control2, relative: isRelative)
                    current = absolutePoint(end, relative: isRelative)
                    path.addCurve(to: current, control1: absoluteControl1, control2: absoluteControl2)
                    lastControl2 = absoluteControl2
                    lastQuadraticControl = nil
                }
                noteCurveCommand(command)
            case "S":
                while index < tokens.count, Double(tokens[index]) != nil {
                    let control2 = readPoint()
                    let end = readPoint()
                    let absoluteControl1 = canReflectCubic() && lastControl2 != nil
                        ? reflectedControl(lastControl2!)
                        : current
                    let absoluteControl2 = absolutePoint(control2, relative: isRelative)
                    current = absolutePoint(end, relative: isRelative)
                    path.addCurve(to: current, control1: absoluteControl1, control2: absoluteControl2)
                    lastControl2 = absoluteControl2
                    lastQuadraticControl = nil
                }
                noteCurveCommand(command)
            case "Q":
                while index < tokens.count, Double(tokens[index]) != nil {
                    let control = readPoint()
                    let end = readPoint()
                    let absoluteControl = absolutePoint(control, relative: isRelative)
                    current = absolutePoint(end, relative: isRelative)
                    path.addQuadCurve(to: current, control: absoluteControl)
                    lastQuadraticControl = absoluteControl
                    lastControl2 = nil
                }
                noteCurveCommand(command)
            case "T":
                while index < tokens.count, Double(tokens[index]) != nil {
                    let end = readPoint()
                    let absoluteControl = canReflectQuadratic() && lastQuadraticControl != nil
                        ? reflectedControl(lastQuadraticControl!)
                        : current
                    current = absolutePoint(end, relative: isRelative)
                    path.addQuadCurve(to: current, control: absoluteControl)
                    lastQuadraticControl = absoluteControl
                    lastControl2 = nil
                }
                noteCurveCommand(command)
            case "A":
                while index < tokens.count, Double(tokens[index]) != nil {
                    let rx = readDouble()
                    let ry = readDouble()
                    let rotation = readDouble()
                    let largeArc = readFlag()
                    let sweep = readFlag()
                    let end = readPoint()
                    current = addArc(
                        to: path,
                        from: current,
                        rx: rx,
                        ry: ry,
                        xAxisRotation: rotation,
                        largeArc: largeArc,
                        sweep: sweep,
                        to: absolutePoint(end, relative: isRelative)
                    )
                    lastControl2 = nil
                    lastQuadraticControl = nil
                }
                noteCurveCommand(command)
            case "Z":
                path.closeSubpath()
                current = start
                noteNonCurveCommand(command)
            default:
                break
            }
        }

        return path
    }

    private nonisolated static func addArc(
        to path: CGMutablePath,
        from start: CGPoint,
        rx: CGFloat,
        ry: CGFloat,
        xAxisRotation: CGFloat,
        largeArc: Bool,
        sweep: Bool,
        to end: CGPoint
    ) -> CGPoint {
        guard start != end else { return end }

        var rx = abs(rx)
        var ry = abs(ry)
        if rx == 0 || ry == 0 {
            path.addLine(to: end)
            return end
        }

        let phi = xAxisRotation * .pi / 180
        let cosPhi = cos(phi)
        let sinPhi = sin(phi)

        let dx = (start.x - end.x) / 2
        let dy = (start.y - end.y) / 2
        let x1p = cosPhi * dx + sinPhi * dy
        let y1p = -sinPhi * dx + cosPhi * dy

        let rxSq = rx * rx
        let rySq = ry * ry
        let x1pSq = x1p * x1p
        let y1pSq = y1p * y1p

        var radiiScale = x1pSq / rxSq + y1pSq / rySq
        if radiiScale > 1 {
            let scale = sqrt(radiiScale)
            rx *= scale
            ry *= scale
            radiiScale = x1pSq / (rx * rx) + y1pSq / (ry * ry)
        }

        let sign: CGFloat = (largeArc == sweep) ? -1 : 1
        let numerator = rxSq * rySq - rxSq * y1pSq - rySq * x1pSq
        let denominator = rxSq * y1pSq + rySq * x1pSq
        let coef = denominator == 0 ? 0 : sign * sqrt(max(0, numerator / denominator))
        let cxp = coef * (rx * y1p / ry)
        let cyp = coef * (-ry * x1p / rx)

        let cx = cosPhi * cxp - sinPhi * cyp + (start.x + end.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (start.y + end.y) / 2

        func angle(u: CGPoint, v: CGPoint) -> CGFloat {
            let dot = u.x * v.x + u.y * v.y
            let len = sqrt((u.x * u.x + u.y * u.y) * (v.x * v.x + v.y * v.y))
            let base = acos(min(1, max(-1, dot / max(len, .leastNonzeroMagnitude))))
            return u.x * v.y - u.y * v.x < 0 ? -base : base
        }

        let v1 = CGPoint(x: (x1p - cxp) / rx, y: (y1p - cyp) / ry)
        let v2 = CGPoint(x: (-x1p - cxp) / rx, y: (-y1p - cyp) / ry)
        let theta = angle(u: CGPoint(x: 1, y: 0), v: v1)
        let delta: CGFloat = {
            var value = angle(u: v1, v: v2)
            if !sweep, value > 0 {
                value -= 2 * .pi
            } else if sweep, value < 0 {
                value += 2 * .pi
            }
            return value
        }()

        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let deltaPerSegment = delta / CGFloat(segments)

        var previous = start
        for segment in 0..<segments {
            let startAngle = theta + CGFloat(segment) * deltaPerSegment
            let endAngle = startAngle + deltaPerSegment
            let alpha = sin(deltaPerSegment) * (sqrt(4 + 3 * tan(deltaPerSegment / 2) * tan(deltaPerSegment / 2)) - 1) / 3

            func point(angle: CGFloat) -> CGPoint {
                let cosAngle = cos(angle)
                let sinAngle = sin(angle)
                let x = rx * cosAngle
                let y = ry * sinAngle
                return CGPoint(
                    x: cosPhi * x - sinPhi * y + cx,
                    y: sinPhi * x + cosPhi * y + cy
                )
            }

            func derivative(angle: CGFloat) -> CGPoint {
                let cosAngle = cos(angle)
                let sinAngle = sin(angle)
                let x = -rx * sinAngle
                let y = ry * cosAngle
                return CGPoint(
                    x: cosPhi * x - sinPhi * y,
                    y: sinPhi * x + cosPhi * y
                )
            }

            let p1 = point(angle: startAngle)
            let p2 = point(angle: endAngle)
            let q1 = derivative(angle: startAngle)
            let q2 = derivative(angle: endAngle)

            let control1 = CGPoint(x: p1.x + alpha * q1.x, y: p1.y + alpha * q1.y)
            let control2 = CGPoint(x: p2.x - alpha * q2.x, y: p2.y - alpha * q2.y)

            if segment == 0, previous == start {
                path.addCurve(to: p2, control1: control1, control2: control2)
            } else {
                path.addCurve(to: p2, control1: control1, control2: control2)
            }
            previous = p2
        }

        return end
    }

    private nonisolated static func tokenize(_ data: String) -> [String] {
        var tokens: [String] = []
        var current = ""

        func flush() {
            if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }

        for character in data {
            if character.isLetter {
                flush()
                tokens.append(String(character))
            } else if character == "," {
                flush()
            } else if character == "-" {
                if !current.isEmpty, let last = current.last, last.isNumber || last == "." {
                    flush()
                }
                current.append(character)
            } else if character.isWhitespace {
                flush()
            } else {
                current.append(character)
            }
        }
        flush()
        return tokens
    }
}
