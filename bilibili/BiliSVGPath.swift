import SwiftUI

struct BiliSVGPathShape: Shape {
    let pathData: String
    var viewBox: CGFloat = 1024

    func path(in rect: CGRect) -> Path {
        BiliSVGPathParser.makePath(pathData, in: rect, viewBox: viewBox)
    }
}

enum BiliSVGPathParser {
    static func makePath(_ data: String, in rect: CGRect, viewBox: CGFloat = 1024) -> Path {
        let cgPath = parse(data)
        let scale = min(rect.width / viewBox, rect.height / viewBox)
        let fittedWidth = viewBox * scale
        let fittedHeight = viewBox * scale
        let originX = rect.minX + (rect.width - fittedWidth) / 2
        let originY = rect.minY + (rect.height - fittedHeight) / 2
        var transform = CGAffineTransform(translationX: originX, y: originY)
            .scaledBy(x: scale, y: scale)
        guard let scaled = cgPath.copy(using: &transform) else {
            return Path(cgPath)
        }
        return Path(scaled)
    }

    private static func parse(_ data: String) -> CGPath {
        let path = CGMutablePath()
        let tokens = tokenize(data)
        var index = 0
        var current = CGPoint.zero
        var start = CGPoint.zero

        func readDouble() -> CGFloat {
            guard index < tokens.count else { return 0 }
            let value = CGFloat(Double(tokens[index]) ?? 0)
            index += 1
            return value
        }

        func readPoint() -> CGPoint {
            CGPoint(x: readDouble(), y: readDouble())
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
                current = isRelative ? CGPoint(x: current.x + point.x, y: current.y + point.y) : point
                start = current
                path.move(to: current)
                while index < tokens.count, Double(tokens[index]) != nil {
                    let linePoint = readPoint()
                    current = isRelative ? CGPoint(x: current.x + linePoint.x, y: current.y + linePoint.y) : linePoint
                    path.addLine(to: current)
                }
            case "L":
                while index < tokens.count, Double(tokens[index]) != nil {
                    let point = readPoint()
                    current = isRelative ? CGPoint(x: current.x + point.x, y: current.y + point.y) : point
                    path.addLine(to: current)
                }
            case "H":
                while index < tokens.count, Double(tokens[index]) != nil {
                    let x = readDouble()
                    current = CGPoint(x: isRelative ? current.x + x : x, y: current.y)
                    path.addLine(to: current)
                }
            case "V":
                while index < tokens.count, Double(tokens[index]) != nil {
                    let y = readDouble()
                    current = CGPoint(x: current.x, y: isRelative ? current.y + y : y)
                    path.addLine(to: current)
                }
            case "C":
                while index < tokens.count, Double(tokens[index]) != nil {
                    let control1 = readPoint()
                    let control2 = readPoint()
                    let end = readPoint()
                    let absoluteControl1 = isRelative ? CGPoint(x: current.x + control1.x, y: current.y + control1.y) : control1
                    let absoluteControl2 = isRelative ? CGPoint(x: current.x + control2.x, y: current.y + control2.y) : control2
                    current = isRelative ? CGPoint(x: current.x + end.x, y: current.y + end.y) : end
                    path.addCurve(to: current, control1: absoluteControl1, control2: absoluteControl2)
                }
            case "Z":
                path.closeSubpath()
                current = start
            default:
                break
            }
        }

        return path
    }

    private static func tokenize(_ data: String) -> [String] {
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
