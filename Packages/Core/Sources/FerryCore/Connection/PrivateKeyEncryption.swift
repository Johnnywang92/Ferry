import Foundation

/// 私钥在**存储形态**下是不是加密的。
///
/// 只要头部事实，不做任何解密，也不声称能解（"不做 Swift 层预解密"这条约束不变，
/// ADR-0000 §12 H12）。它存在的理由只有一条：`libssh2_userauth_publickey_frommemory`
/// 对"口令错""私钥是加密的但你没给口令""这字节压根不是私钥"回的都是
/// `-16 LIBSSH2_ERROR_FILE`（M0a-05 结论 6），而这三件事对用户的下一步完全不同。
/// 头部能确认的那一格就确认下来，确认不了的老实说 `.unrecognized`。
public enum PrivateKeyEncryption: Sendable, Hashable {
    /// 头部明确写出不加密（`openssh-key-v1` 的 cipher 是 `none`，或已知的明文 PEM 且没有 `DEK-Info`）。
    case plain
    /// 头部明确写出加密：非 `none` 的 cipher、`ENCRYPTED` 标签、`DEK-Info` / `Proc-Type: 4,ENCRYPTED`。
    case encrypted
    /// 读不出名堂（PuTTY 的 `.ppk`、截断的文件、看不懂的封装都落这里）。
    ///
    /// 这一格**不许当成 `.plain`**：判成"不需要口令"之后，`-16` 会被分类成
    /// `keyRejected`，用户去查服务器上的 `authorized_keys`，而真正的原因是他没填口令。
    case unrecognized

    public static func probe(_ data: Data) -> PrivateKeyEncryption {
        let bytes = [UInt8](data)
        if let encryption = opensshFormat(bytes) { return encryption }
        return pemFormat(bytes)
    }

    // `openssh-key-v1\0` 之后第一个字段就是 cipher 名（长度前缀 + ASCII）。
    private static let opensshMagic: [UInt8] = Array("openssh-key-v1".utf8) + [0]

    private static func opensshFormat(_ bytes: [UInt8]) -> PrivateKeyEncryption? {
        guard bytes.count >= opensshMagic.count, Array(bytes[0..<opensshMagic.count]) == opensshMagic else {
            return nil
        }
        let head = opensshMagic.count
        guard bytes.count >= head + 4 else { return .unrecognized }
        let length = Int(UInt32(bytes[head]) << 24) | Int(UInt32(bytes[head + 1]) << 16)
            | Int(UInt32(bytes[head + 2]) << 8) | Int(UInt32(bytes[head + 3]))
        // cipher 名不可能是空的；超出这个长度就说明头部不是我们要读的形状。
        guard length > 0, length <= 64, bytes.count >= head + 4 + length else { return .unrecognized }
        let cipher = String(decoding: bytes[(head + 4)..<(head + 4 + length)], as: UTF8.self)
        return cipher == "none" ? .plain : .encrypted
    }

    private static let plaintextLabels: Set<String> = [
        "PRIVATE KEY", "RSA PRIVATE KEY", "EC PRIVATE KEY", "DSA PRIVATE KEY",
    ]

    private static func pemFormat(_ bytes: [UInt8]) -> PrivateKeyEncryption {
        guard let label = beginLabel(of: bytes) else { return .unrecognized }
        if label.contains("ENCRYPTED") { return .encrypted }
        if label == "OPENSSH PRIVATE KEY" {
            // 新格式套在 PEM 里：真正的头部在 base64 解出来的字节里
            guard let body = opensshBody(of: bytes) else { return .unrecognized }
            return opensshFormat(body) ?? .unrecognized
        }
        if hasRFC1421EncryptionHeader(of: bytes) { return .encrypted }
        return plaintextLabels.contains(label) ? .plain : .unrecognized
    }

    /// `-----BEGIN <label>-----` 里的 label。没有 BEGIN 行就不是 PEM。
    private static func beginLabel(of bytes: [UInt8]) -> String? {
        let text = String(decoding: bytes.prefix(4096), as: UTF8.self)
        guard let marker = text.range(of: "-----BEGIN ") else { return nil }
        let tail = text[marker.upperBound...]
        guard let end = tail.range(of: "-----") else { return nil }
        return String(tail[..<end.lowerBound])
    }

    /// RFC 1421 的口令加密只在 BEGIN 之后那段头部块里留痕，
    /// 头部块以空行（或紧接着就是 base64）结束。
    private static func hasRFC1421EncryptionHeader(of bytes: [UInt8]) -> Bool {
        let text = String(decoding: bytes.prefix(8192), as: UTF8.self)
        guard let marker = text.range(of: "-----BEGIN ") else { return false }
        let after = text[marker.lowerBound...]
        var pastBeginLine = false
        for raw in after.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if !pastBeginLine {
                if line.hasPrefix("-----") && line.hasSuffix("-----") { pastBeginLine = true }
                continue
            }
            if line.isEmpty || line.hasPrefix("-----") { break }
            if line.hasPrefix("DEK-Info:") { return true }
            if line.hasPrefix("Proc-Type:") && line.uppercased().contains("ENCRYPTED") { return true }
        }
        return false
    }

    /// BEGIN 之后第一段 base64。只取前 4 的整数倍个字符——`Data(base64Encoded:)`
    /// 要求整块长度对齐，而我们要的只是头部那几十字节。
    private static func opensshBody(of bytes: [UInt8]) -> [UInt8]? {
        let text = String(decoding: bytes, as: UTF8.self)
        guard let marker = text.range(of: "-----BEGIN ") else { return nil }
        var body = ""
        var pastBeginLine = false
        for raw in text[marker.lowerBound...].split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if !pastBeginLine {
                if line.hasSuffix("-----") { pastBeginLine = true }
                continue
            }
            if line.hasPrefix("-----END") { break }
            body += line
            if body.count >= 120 { break }
        }
        guard body.count >= 4 else { return nil }
        let aligned = body.prefix(body.count - body.count % 4)
        return Array(Data(base64Encoded: String(aligned), options: [.ignoreUnknownCharacters]) ?? Data())
    }
}

extension PrivateKeyMaterial {
    /// 这份密钥材料在存储里是不是加密的。见 `PrivateKeyEncryption` 为什么需要这一格。
    public var encryption: PrivateKeyEncryption { PrivateKeyEncryption.probe(keyData) }
}
