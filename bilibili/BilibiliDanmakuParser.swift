import Foundation

enum BilibiliDanmakuParser: Sendable {
    nonisolated static func parseProtobufSeg(_ bytes: Data) -> [BiliDanmakuItem] {
        guard !bytes.isEmpty else { return [] }
        var items: [BiliDanmakuItem] = []
        var offset = 0
        while offset < bytes.count {
            guard let tag = readTag(bytes, offset: offset) else { break }
            offset = tag.offset
            let fieldNumber = tag.value >> 3
            let wireType = tag.value & 0x7
            switch (fieldNumber, wireType) {
            case (1, 2):
                guard let lengthInfo = readVarint(bytes, offset: offset) else { break }
                offset = lengthInfo.offset
                let length = Int(lengthInfo.value)
                let end = offset + length
                guard end <= bytes.count else { break }
                if let item = parseDanmakuElem(bytes, start: offset, end: end) {
                    items.append(item)
                }
                offset = end
            case (_, 0):
                guard let skipped = readVarint(bytes, offset: offset) else { break }
                offset = skipped.offset
            case (_, 2):
                guard let lengthInfo = readVarint(bytes, offset: offset) else { break }
                offset = lengthInfo.offset + Int(lengthInfo.value)
            case (_, 1):
                offset += 8
            case (_, 5):
                offset += 4
            default:
                break
            }
        }
        return items
    }

    nonisolated static func parseListSo(_ bytes: Data) -> [BiliDanmakuItem] {
        guard !bytes.isEmpty else { return [] }
        if bytes.first == 0x0A {
            return parseProtobufSeg(bytes)
        }
        if bytes.first == UInt8(ascii: "<") {
            return parseXml(String(data: bytes, encoding: .utf8) ?? "")
        }
        return parseLegacyBinary(bytes)
    }

    nonisolated static func parseXml(_ xml: String) -> [BiliDanmakuItem] {
        guard !xml.isEmpty else { return [] }
        let parser = DanmakuXMLParser()
        parser.parse(xml)
        return parser.items
    }

    private nonisolated static func parseLegacyBinary(_ bytes: Data) -> [BiliDanmakuItem] {
        var items: [BiliDanmakuItem] = []
        var offset = 0
        while offset + 21 <= bytes.count {
            let timeSec = bytes.withUnsafeBytes { ptr in
                ptr.loadUnaligned(fromByteOffset: offset, as: Float.self)
            }
            let mode = bytes.withUnsafeBytes { ptr in
                Int32(bitPattern: ptr.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self))
            }
            let fontSize = bytes.withUnsafeBytes { ptr in
                Int32(bitPattern: ptr.loadUnaligned(fromByteOffset: offset + 8, as: UInt32.self))
            }
            let color = bytes.withUnsafeBytes { ptr in
                Int32(bitPattern: ptr.loadUnaligned(fromByteOffset: offset + 12, as: UInt32.self))
            }
            offset += 21
            guard let hashEnd = bytes[offset...].firstIndex(of: 0) else { break }
            offset = hashEnd + 1
            guard let contentEnd = bytes[offset...].firstIndex(of: 0) else { break }
            let content = String(bytes: bytes[offset..<contentEnd], encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            offset = contentEnd + 1
            guard !content.isEmpty else { continue }
            items.append(
                BiliDanmakuItem(
                    timeMs: max(0, Int64(timeSec * 1000)),
                    mode: Int(mode),
                    fontSize: max(18, Int(fontSize)),
                    colorArgb: Int(color),
                    content: content
                )
            )
        }
        return items
    }

    private nonisolated static func parseDanmakuElem(_ bytes: Data, start: Int, end: Int) -> BiliDanmakuItem? {
        var offset = start
        var progressMs: Int64 = 0
        var mode = 1
        var fontSize = 25
        var color = 0xFFFFFF
        var content = ""
        while offset < end {
            guard let tag = readTag(bytes, offset: offset) else { break }
            offset = tag.offset
            let fieldNumber = tag.value >> 3
            let wireType = tag.value & 0x7
            switch wireType {
            case 0:
                guard let value = readVarint(bytes, offset: offset) else { break }
                offset = value.offset
                switch fieldNumber {
                case 2: progressMs = value.value
                case 3: mode = Int(value.value)
                case 4: fontSize = max(18, Int(value.value))
                case 5: color = Int(value.value) & 0xFFFFFF
                default: break
                }
            case 2:
                guard let lengthInfo = readVarint(bytes, offset: offset) else { break }
                offset = lengthInfo.offset
                let length = Int(lengthInfo.value)
                let chunkEnd = offset + length
                guard chunkEnd <= end else { break }
                if fieldNumber == 7 {
                    content = String(bytes: bytes[offset..<chunkEnd], encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                }
                offset = chunkEnd
            case 1:
                offset += 8
            case 5:
                offset += 4
            default:
                break
            }
        }
        guard !content.isEmpty else { return nil }
        return BiliDanmakuItem(
            timeMs: max(0, progressMs),
            mode: mode,
            fontSize: fontSize,
            colorArgb: color,
            content: content
        )
    }

    private nonisolated static func readTag(_ bytes: Data, offset: Int) -> (value: Int, offset: Int)? {
        guard let value = readVarint(bytes, offset: offset) else { return nil }
        return (Int(value.value), value.offset)
    }

    private nonisolated static func readVarint(_ bytes: Data, offset: Int) -> (value: Int64, offset: Int)? {
        guard offset < bytes.count else { return nil }
        var result: Int64 = 0
        var shift = 0
        var index = offset
        while index < bytes.count, shift <= 63 {
            let byte = Int(bytes[index])
            index += 1
            result |= Int64(byte & 0x7F) << shift
            if byte & 0x80 == 0 {
                return (result, index)
            }
            shift += 7
        }
        return nil
    }
}

private final class DanmakuXMLParser: NSObject, XMLParserDelegate {
    var items: [BiliDanmakuItem] = []
    private var pendingParams: (Float, Int, Int, Int)?
    private var currentText = ""

    func parse(_ xml: String) {
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = self
        parser.parse()
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard elementName == "d" else { return }
        let params = attributeDict["p"] ?? ""
        let parts = params.split(separator: ",").map(String.init)
        guard parts.count >= 4,
              let timeSec = Float(parts[0]),
              let mode = Int(parts[1]),
              let fontSize = Int(parts[2]),
              let color = Int(parts[3]) else { return }
        currentText = ""
        pendingParams = (timeSec, mode, fontSize, color)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard elementName == "d", let pending = pendingParams else { return }
        let content = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingParams = nil
        currentText = ""
        guard !content.isEmpty else { return }
        items.append(
            BiliDanmakuItem(
                timeMs: max(0, Int64(pending.0 * 1000)),
                mode: pending.1,
                fontSize: max(18, pending.2),
                colorArgb: pending.3,
                content: content
            )
        )
    }
}
