import Foundation

enum BiliDynamicGrpcClient {
    private static let androidUA =
        "Dalvik/2.1.0 (Linux; U; Android 13; Mi 11 Build/TKQ1.221114.001) 8.51.0 os/android model/Mi 11 mobi_app/android build/8510300 channel/master innerVer/8510310 osVer/13 network/2"

    static func fetchAuthorIpLocation(
        dynamicId: String,
        credential: BilibiliCredential
    ) async -> String? {
        guard !dynamicId.isEmpty, !credential.accessKey.isEmpty else { return nil }

        let buvid = credential.buvid3.isEmpty ? "XY0000000000000000000000000000infoc" : credential.buvid3
        let payload = BiliProtobufCodec.buildDynDetailReq(dynamicId: dynamicId)
        var grpcBody = Data(count: 5 + payload.count)
        grpcBody[0] = 0
        grpcBody[1] = UInt8((payload.count >> 24) & 0xFF)
        grpcBody[2] = UInt8((payload.count >> 16) & 0xFF)
        grpcBody[3] = UInt8((payload.count >> 8) & 0xFF)
        grpcBody[4] = UInt8(payload.count & 0xFF)
        grpcBody.replaceSubrange(5..<(5 + payload.count), with: payload)

        var request = URLRequest(url: URL(string: "https://grpc.biliapi.net/bilibili.app.dynamic.v2.Dynamic/DynDetail")!)
        request.httpMethod = "POST"
        request.httpBody = grpcBody
        request.timeoutInterval = 12
        request.setValue("trailers", forHTTPHeaderField: "te")
        request.setValue("identity", forHTTPHeaderField: "grpc-accept-encoding")
        request.setValue(androidUA, forHTTPHeaderField: "user-agent")
        request.setValue("identify_v1 \(credential.accessKey)", forHTTPHeaderField: "authorization")
        request.setValue(buvid, forHTTPHeaderField: "buvid")
        request.setValue(credential.dedeUserId, forHTTPHeaderField: "x-bili-mid")
        request.setValue(buildTraceId(), forHTTPHeaderField: "x-bili-trace-id")
        request.setValue(BiliProtobufCodec.buildMetadata(accessKey: credential.accessKey, buvid: buvid).grpcHeader, forHTTPHeaderField: "x-bili-metadata-bin")
        request.setValue(BiliProtobufCodec.buildDevice(buvid: buvid).grpcHeader, forHTTPHeaderField: "x-bili-device-bin")
        request.setValue(BiliProtobufCodec.buildFawkesReq().grpcHeader, forHTTPHeaderField: "x-bili-fawkes-req-bin")
        request.setValue(BiliProtobufCodec.buildNetwork().grpcHeader, forHTTPHeaderField: "x-bili-network-bin")
        request.setValue(BiliProtobufCodec.buildLocale().grpcHeader, forHTTPHeaderField: "x-bili-locale-bin")
        request.setValue(Data().grpcHeader, forHTTPHeaderField: "x-bili-restriction-bin")
        request.setValue(Data().grpcHeader, forHTTPHeaderField: "x-bili-exps-bin")
        request.setValue("application/grpc", forHTTPHeaderField: "Content-Type")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  data.count > 5 else {
                return nil
            }
            let message = data.subdata(in: 5..<data.count)
            return BiliProtobufCodec.findField14Strings(in: message)
                .compactMap(JSONParser.normalizeIpLocation)
                .first
        } catch {
            return nil
        }
    }

    private static func buildTraceId() -> String {
        let left = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(26)
        let right = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)
        return "\(left):\(right):0:0"
    }
}

private enum BiliProtobufCodec {
    static func buildDynDetailReq(dynamicId: String) -> Data {
        var output = Data()
        writeStringField(fieldNumber: 2, value: dynamicId, into: &output)
        writeVarintField(fieldNumber: 10, value: 8, into: &output)
        return output
    }

    static func findField14Strings(in data: Data) -> [String] {
        var result: [String] = []
        collectField14Strings(data: data, start: 0, end: data.count, out: &result)
        return result
    }

    private static func collectField14Strings(data: Data, start: Int, end: Int, out: inout [String]) {
        var index = start
        while index < end {
            guard let tag = readVarint(data: data, start: index) else { return }
            index = tag.nextIndex
            let fieldNumber = Int(tag.value >> 3)
            switch tag.value & 7 {
            case 0:
                index = skipVarint(data: data, start: index)
            case 1:
                index += 8
            case 2:
                guard let length = readVarint(data: data, start: index) else { return }
                index = length.nextIndex
                let chunkEnd = index + Int(length.value)
                guard chunkEnd <= end else { return }
                let chunk = data.subdata(in: index..<chunkEnd)
                index = chunkEnd
                if fieldNumber == 14,
                   let text = String(data: chunk, encoding: .utf8),
                   !text.isEmpty {
                    out.append(text)
                } else {
                    collectField14Strings(data: chunk, start: 0, end: chunk.count, out: &out)
                }
            case 5:
                index += 4
            default:
                return
            }
        }
    }

    static func buildMetadata(accessKey: String, buvid: String) -> Data {
        var output = Data()
        writeStringField(fieldNumber: 1, value: accessKey, into: &output)
        writeStringField(fieldNumber: 2, value: "android", into: &output)
        writeStringField(fieldNumber: 3, value: "phone", into: &output)
        writeVarintField(fieldNumber: 4, value: 8_510_300, into: &output)
        writeStringField(fieldNumber: 5, value: "master", into: &output)
        writeStringField(fieldNumber: 6, value: buvid, into: &output)
        writeStringField(fieldNumber: 7, value: "android", into: &output)
        return output
    }

    static func buildFawkesReq() -> Data {
        var output = Data()
        writeStringField(fieldNumber: 1, value: "android64", into: &output)
        writeStringField(fieldNumber: 2, value: "prod", into: &output)
        writeStringField(fieldNumber: 3, value: "bili-dynamic-ip", into: &output)
        return output
    }

    static func buildDevice(buvid: String) -> Data {
        var output = Data()
        writeVarintField(fieldNumber: 1, value: 1, into: &output)
        writeVarintField(fieldNumber: 2, value: 8_510_300, into: &output)
        writeStringField(fieldNumber: 3, value: buvid, into: &output)
        writeStringField(fieldNumber: 4, value: "android", into: &output)
        writeStringField(fieldNumber: 5, value: "android", into: &output)
        writeStringField(fieldNumber: 6, value: "phone", into: &output)
        writeStringField(fieldNumber: 7, value: "master", into: &output)
        writeStringField(fieldNumber: 8, value: "Xiaomi", into: &output)
        writeStringField(fieldNumber: 9, value: "Mi 11", into: &output)
        writeStringField(fieldNumber: 10, value: "Android 13", into: &output)
        writeStringField(fieldNumber: 13, value: "8.51.0", into: &output)
        return output
    }

    static func buildNetwork() -> Data {
        var output = Data()
        writeVarintField(fieldNumber: 1, value: 2, into: &output)
        writeVarintField(fieldNumber: 2, value: 0, into: &output)
        writeStringField(fieldNumber: 3, value: "46000", into: &output)
        return output
    }

    static func buildLocale() -> Data {
        var output = Data()
        writeMessageField(fieldNumber: 1, value: buildLocaleIds(language: "zh", script: "Hans", region: "CN"), into: &output)
        writeMessageField(fieldNumber: 2, value: buildLocaleIds(language: "zh", script: "Hans", region: "CN"), into: &output)
        writeStringField(fieldNumber: 3, value: "46000", into: &output)
        writeStringField(fieldNumber: 4, value: "Asia/Shanghai", into: &output)
        return output
    }

    private static func buildLocaleIds(language: String, script: String, region: String) -> Data {
        var output = Data()
        writeStringField(fieldNumber: 1, value: language, into: &output)
        writeStringField(fieldNumber: 2, value: script, into: &output)
        writeStringField(fieldNumber: 3, value: region, into: &output)
        return output
    }

    private static func writeTag(fieldNumber: Int, wireType: Int, into output: inout Data) {
        writeVarint(value: Int64((fieldNumber << 3) | wireType), into: &output)
    }

    private static func writeStringField(fieldNumber: Int, value: String, into output: inout Data) {
        let bytes = Data(value.utf8)
        writeTag(fieldNumber: fieldNumber, wireType: 2, into: &output)
        writeVarint(value: Int64(bytes.count), into: &output)
        output.append(bytes)
    }

    private static func writeVarintField(fieldNumber: Int, value: Int, into output: inout Data) {
        writeTag(fieldNumber: fieldNumber, wireType: 0, into: &output)
        writeVarint(value: Int64(value), into: &output)
    }

    private static func writeMessageField(fieldNumber: Int, value: Data, into output: inout Data) {
        writeTag(fieldNumber: fieldNumber, wireType: 2, into: &output)
        writeVarint(value: Int64(value.count), into: &output)
        output.append(value)
    }

    private static func writeVarint(value: Int64, into output: inout Data) {
        var current = value
        while current & ~0x7F != 0 {
            output.append(UInt8(truncatingIfNeeded: (current & 0x7F) | 0x80))
            current >>= 7
        }
        output.append(UInt8(truncatingIfNeeded: current))
    }

    private static func readVarint(data: Data, start: Int) -> (value: Int64, nextIndex: Int)? {
        var result: Int64 = 0
        var shift = 0
        var index = start
        while index < data.count, shift < 64 {
            let byte = Int64(data[index])
            index += 1
            result |= (byte & 0x7F) << shift
            if byte & 0x80 == 0 {
                return (result, index)
            }
            shift += 7
        }
        return nil
    }

    private static func skipVarint(data: Data, start: Int) -> Int {
        var index = start
        while index < data.count {
            if data[index] & 0x80 == 0 { return index + 1 }
            index += 1
        }
        return index
    }
}

private extension Data {
    var grpcHeader: String {
        base64EncodedString()
    }
}
