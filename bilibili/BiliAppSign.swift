import CryptoKit
import Foundation

enum BiliAppSign {
    private static let pinkAppSecret = "2653583c8873dea268ab9386918b1d65"

    static func sign(params: [String: String], appSecret: String = pinkAppSecret) -> String {
        let query = params.keys.sorted().map { key in
            "\(key)=\(params[key] ?? "")"
        }.joined(separator: "&")
        let digest = Insecure.MD5.hash(data: Data((query + appSecret).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func signQuery(
        baseParams: [String: String],
        appSecret: String = pinkAppSecret,
        includeTimestamp: Bool = true
    ) -> [String: String] {
        var params = baseParams
        if includeTimestamp, params["ts"] == nil {
            params["ts"] = String(Int(Date().timeIntervalSince1970))
        }
        params["sign"] = sign(params: params, appSecret: appSecret)
        return params
    }
}
