import CryptoKit
import Foundation

/// OpenSSH `known_hosts` 的一行密钥记录（也用于 Ferry 自己的存储，两者同格式）。
///
/// 格式与匹配语义按 `man 8 sshd` 的 SSH_KNOWN_HOSTS FILE FORMAT 一节，
/// 分歧点全部以本机 OpenSSH_10.3p1 与容器 OpenSSH_9.7p1 的实测为准，见各条注释。

/// 行首的可选标记。除这两个之外没有其他标记，出现别的 `@xxx` 算解析失败。
public enum KnownHostMarker: String, Sendable, Hashable {
    case certAuthority = "@cert-authority"
    case revoked = "@revoked"
}

/// 主机名以哈希形式存放：`|1|base64(salt)|base64(HMAC-SHA1(key=salt, msg=主机串))`。
///
/// 实测两条不能靠猜的规则（`ssh-keygen -H` 在 /tmp 的副本上跑出来的四个向量，
/// 逐条用独立实现的 HMAC-SHA1 反算对上，见 CoreTests/KnownHostsTests）：
/// - salt 长度不固定，本机 `ssh-keygen -H` 生成的是 **20 字节**，不能按 16 硬编码；
/// - 被哈希的"主机串"就是查询用的那个字符串：默认端口是 `host`，
///   非默认端口是 `[host]:port`，方括号和端口号都在哈希输入里。
public struct HashedHostName: Sendable, Hashable {
    public let salt: Data
    public let hash: Data

    public init(salt: Data, hash: Data) {
        self.salt = salt
        self.hash = hash
    }

    /// `ssh-keygen -H` 的输出形状（标准 base64，带填充）。
    public var encoded: String {
        "|1|\(salt.base64EncodedString())|\(hash.base64EncodedString())"
    }

    public static func make(host: String, salt: Data) -> HashedHostName {
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data(host.utf8), using: SymmetricKey(data: salt))
        return HashedHostName(salt: salt, hash: Data(mac))
    }

    /// 新加一条哈希记录时用随机 salt。20 字节与 OpenSSH 一致，
    /// 免得我们的存储被 `ssh-keygen -H` 处理前后形状不一样。
    public static func randomSalt() -> Data {
        var bytes = [UInt8](repeating: 0, count: 20)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...UInt8.max) }
        return Data(bytes)
    }

    public func matches(host: String) -> Bool {
        constantTimeEquals(HashedHostName.make(host: host, salt: salt).hash, hash)
    }
}

func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
    guard lhs.count == rhs.count else { return false }
    var difference: UInt8 = 0
    for index in 0..<lhs.count { difference |= lhs[index] ^ rhs[index] }
    return difference == 0
}

/// 一行的密钥部分。
public struct KnownHostKey: Sendable, Hashable {
    /// known_hosts 里的 keytype 字段，等于 `HostKey.wireType`（不是协商名，见那里的注释）。
    public let keyType: String
    public let blob: Data

    public init(keyType: String, blob: Data) {
        self.keyType = keyType
        self.blob = blob
    }

    /// 主机密钥证书类型（`*-cert-v01@openssh.com`）。本期不支持校验证书，
    /// 不能把它当普通主机密钥比——证书里裹着 CA 签名的普通密钥，
    /// 直接拿 blob 比会在"CA 换了、叶子没换"这类情况下给出错误结论。
    public var isCertificate: Bool { keyType.contains("-cert-") }
}

public struct KnownHostLine: Sendable, Hashable {
    public let lineNumber: Int
    public let marker: KnownHostMarker?
    /// 明文模式列表，已按逗号拆开；`hashed` 非空时这里是 nil（OpenSSH：一行只允许一个哈希名，
    /// 且哈希名不许带通配或否证）。
    public let patterns: [String]?
    public let hashed: HashedHostName?
    public let key: KnownHostKey
    public let comment: String?

    public init(lineNumber: Int, marker: KnownHostMarker?, patterns: [String]?,
                hashed: HashedHostName?, key: KnownHostKey, comment: String?) {
        self.lineNumber = lineNumber
        self.marker = marker
        self.patterns = patterns
        self.hashed = hashed
        self.key = key
        self.comment = comment
    }
}

/// 解析失败的一行。刻意不静默丢弃：整行读不懂和被跳过在信任判定里是两件事，
/// 必须能在诊断报告里看到"这个文件里有 N 行我们没能理解"。
public struct KnownHostParseFailure: Sendable, Hashable {
    public let lineNumber: Int
    public let reason: String
}

/// 一个 known_hosts 文件（或其中一段）。
public struct KnownHostsFile: Sendable, Hashable {
    /// 写进诊断报告与"命中来源"的来源标识，通常是路径。
    public let source: String
    public let lines: [KnownHostLine]
    public let failures: [KnownHostParseFailure]

    public init(source: String, lines: [KnownHostLine], failures: [KnownHostParseFailure]) {
        self.source = source
        self.lines = lines
        self.failures = failures
    }

    /// 解析整个文件。注释行与空行按 man 的说法跳过，不计入 failures。
    public static func parse(_ text: String, source: String) -> KnownHostsFile {
        var lines: [KnownHostLine] = []
        var failures: [KnownHostParseFailure] = []

        // 不能写 `split(separator: "\n")`：Swift 的 Character 是字素簇，
        // `\r\n` 算**一个** Character，于是 CRLF 文件里 `split(separator: "\n")` 一次都不切，
        // 整行留着结尾的 `\r\n` 去做 base64 解码，每行都判成坏行（本条是写测试时踩到的）。
        // 三种结尾都按行分隔处理，切完的元素里不再含有换行符。
        let pieces = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\r\n" || $0 == "\n" || $0 == "\r" })
        for (offset, raw) in pieces.enumerated() {
            let number = offset + 1
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            guard let parsed = parseLine(line, lineNumber: number) else {
                failures.append(KnownHostParseFailure(lineNumber: number, reason: "字段不足或 base64/标记不合法"))
                continue
            }
            lines.append(parsed)
        }
        return KnownHostsFile(source: source, lines: lines, failures: failures)
    }

    private static func parseLine(_ line: String, lineNumber: Int) -> KnownHostLine? {
        var cursor = Substring(line)

        var marker: KnownHostMarker?
        if cursor.hasPrefix("@") {
            let (head, rest) = splitField(cursor)
            guard let known = KnownHostMarker(rawValue: head) else { return nil }
            marker = known
            cursor = rest
        }

        var patterns: [String]?
        var hashed: HashedHostName?
        guard !cursor.isEmpty else { return nil }
        let (hostField, afterHost) = splitField(cursor)
        cursor = afterHost

        if hostField.hasPrefix("|") {
            let parts = hostField.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count == 4, parts[1] == "1",
                  let salt = Data(base64Encoded: String(parts[2])),
                  let hash = Data(base64Encoded: String(parts[3])) else { return nil }
            hashed = HashedHostName(salt: salt, hash: hash)
        } else {
            // 逗号拆开，但 OpenSSH 允许 `\,` 转义——先按未转义的逗号切。
            patterns = splitPatterns(hostField)
            guard let patterns, !patterns.isEmpty else { return nil }
        }

        guard !cursor.isEmpty else { return nil }
        let (keyType, afterType) = splitField(cursor)
        cursor = afterType
        guard !cursor.isEmpty else { return nil }
        let (keyField, afterKey) = splitField(cursor)
        guard let blob = decodeBase64(keyField) else { return nil }

        let comment = afterKey.trimmingCharacters(in: .whitespaces)
        return KnownHostLine(lineNumber: lineNumber, marker: marker, patterns: patterns,
                             hashed: hashed, key: KnownHostKey(keyType: keyType, blob: blob),
                             comment: comment.isEmpty ? nil : comment)
    }

    /// 取出行首以空格/Tab 分隔的第一个字段，返回内容和余下部分（前导空白已去掉）。
    private static func splitField(_ input: Substring) -> (String, Substring) {
        var index = input.startIndex
        while index < input.endIndex, input[index] != " ", input[index] != "\t" { index = input.index(after: index) }
        let head = String(input[input.startIndex..<index])
        var rest = input[index...]
        while let first = rest.first, first == " " || first == "\t" { rest = rest.dropFirst() }
        return (head, rest)
    }

    /// 逗号分隔的主机模式列表，认 `\,` 转义。
    private static func splitPatterns(_ field: String) -> [String]? {
        var patterns: [String] = []
        var current = ""
        var escaped = false
        for character in field {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                current.append(character)
                escaped = true
            } else if character == "," {
                if !current.isEmpty { patterns.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { patterns.append(current) }
        return patterns
    }

    /// 容忍少了填充的 base64：`ssh-keyscan` 与 `ssh` 都写带填充的形式，
    /// 但手改过的行去掉 `=` 是真实存在的形状，去掉填充后长度不足就该判解析失败而不是当成空 blob。
    private static func decodeBase64(_ text: String) -> Data? {
        if let direct = Data(base64Encoded: text) { return direct }
        let padding = (4 - text.count % 4) % 4
        return Data(base64Encoded: text + String(repeating: "=", count: padding))
    }
}

/// 一次查表的结果。**每个 case 都对应一条不同的处置**，所以不把"不匹配"做成一个笼统值：
/// `.keyChanged` 必须硬阻断，`.otherAlgorithm` 只是提示级别的分歧，
/// `.certAuthorityOnly` 要说清"本期不校验证书"。
public enum HostKeyVerdict: Sendable, Hashable {
    /// 某个文件里有一行主机匹配、类型相同且 blob 逐字节相等。
    case trusted(source: String, line: Int, keyType: String)
    /// 同一主机、同一 keytype 存在另一把密钥。OpenSSH 在这里打
    /// `WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED` 并拒绝（容器实测三种
    /// StrictHostKeyChecking 都不给过），Ferry 同样硬阻断且不提供跳过。
    case keyChanged(source: String, line: Int, keyType: String, knownFingerprint: String)
    /// 命中的行带 `@revoked`。即使别处有同一把密钥的合法行，撤销优先。
    case revoked(source: String, line: Int)
    /// 主机在表里有行，但没有一行的类型与本次一致。
    ///
    /// 这一格是 Ferry 与 OpenSSH 行为差异最大的地方，也是必须存在的一格：
    /// OpenSSH 会把已知类型的算法挪到 KEXINIT 的主机密钥偏好最前面，从而**避免**出现
    /// "表里有 ed25519 却谈成 rsa"（容器实测：表里只有 `ssh-rsa` 行时它谈的是
    /// `rsa-sha2-512`，只有 `ssh-ed25519` 行时谈的是 `ssh-ed25519`）；
    /// libssh2 不看 known_hosts，谈成哪个就哪个。对 OpenSSH 来说这种形状是攻击信号，
    /// 对我们多半只是算法换了一下——所以这里交给用户确认，不静默接受也不硬阻断。
    case otherAlgorithm(sources: [String], knownTypes: [String])
    /// 主机的记录全是主机密钥证书 / `@cert-authority` 行，本期不支持，按未知主机处理但要说明白。
    case certificateOnly(sources: [String])
    /// 表里根本没有这台主机。
    case unknown
}

/// 在一组 known_hosts 文件里查一台主机。
///
/// 顺序即优先级：Ferry 自己的存储放最前，然后是用户的 `~/.ssh/known_hosts`，
/// 最后是系统级 `/etc/ssh/ssh_known_hosts`。man 明确"任一文件里有有效信息即接受"，
/// 所以精确命中优先于分歧；但撤销永远优先。
public func lookupHostKey(host: String, port: Int, key: KnownHostKey,
                          in files: [KnownHostsFile]) -> HostKeyVerdict {
    let candidates = hostCandidates(host: host, port: port)
    var trusted: (source: String, line: Int)?
    var revoked: (source: String, line: Int)?
    var changed: (source: String, line: Int, fingerprint: String)?
    var otherTypes: [String] = []
    var otherSources: [String] = []
    var certificateSources: [String] = []

    for file in files {
        for line in file.lines where hostLineMatches(line, candidates: candidates) {
            let sameKey = line.key == key
            if sameKey, line.marker == .revoked {
                if revoked == nil { revoked = (file.source, line.lineNumber) }
                continue
            }
            if sameKey, line.marker == nil, !line.key.isCertificate {
                if trusted == nil { trusted = (file.source, line.lineNumber) }
                continue
            }
            if line.marker == .certAuthority || line.key.isCertificate {
                // CA 行即使 blob 与本次一致也不算命中：它表达的是"这行是 CA"，
                // 拿它当主机密钥接受等于把 CA 的密钥当成这台的密钥。
                if !certificateSources.contains(file.source) { certificateSources.append(file.source) }
                continue
            }
            if line.key.keyType == key.keyType {
                if changed == nil {
                    changed = (file.source, line.lineNumber, HostKey.fingerprint(of: line.key.blob))
                }
                continue
            }
            if !otherTypes.contains(line.key.keyType) {
                otherTypes.append(line.key.keyType)
                if !otherSources.contains(file.source) { otherSources.append(file.source) }
            }
        }
    }

    // 撤销优先于任何合法行：man 的原话是 revoked key "must not ever be accepted"，
    // 而"任一文件里有有效信息即接受"说的是没有撤销标记的情况。
    // 实测（容器 9.7）：`@revoked` 行的密钥与呈上的完全一致时，
    // ask / accept-new / yes 三种 StrictHostKeyChecking 全部拒连。
    if let revoked { return .revoked(source: revoked.source, line: revoked.line) }
    if let trusted { return .trusted(source: trusted.source, line: trusted.line, keyType: key.keyType) }
    if let changed {
        return .keyChanged(source: changed.source, line: changed.line, keyType: key.keyType,
                           knownFingerprint: changed.fingerprint)
    }
    if !otherTypes.isEmpty { return .otherAlgorithm(sources: otherSources, knownTypes: otherTypes) }
    if !certificateSources.isEmpty { return .certificateOnly(sources: certificateSources) }
    return .unknown
}

/// 查询一台主机时要用哪几个字符串去比。
///
/// 实测（本机 OpenSSH 10.3，连 `127.0.0.1:2201`）：明文行 `127.0.0.1` 与
/// 方括号行 `[127.0.0.1]:2201` **都算匹配**，所以两个候选都得试；
/// 端口永远来自连接本身，表里写的端口不参与比较（`[h]:9999` 不会因为我们连 2201 而命中，
/// 因为比的是 `[127.0.0.1]:2201`）。
public func hostCandidates(host: String, port: Int) -> [String] {
    let lower = host.lowercased()
    // 端口在方括号**外面**：`[127.0.0.1]:2201`。写成 `[127.0.0.1:2201]` 的行
    // `ssh-keygen -F` 不认，`ssh` 也永远不会往文件里写那种形状。
    return [lower, "[\(lower)]:\(port)"]
}

/// 一行的主机字段是否指到这台主机：明文模式列表或哈希名，两种都按 OpenSSH 的
/// `match_pattern_list` 语义（先否证后肯定；只有否证的列表永不命中）。
public func hostLineMatches(_ line: KnownHostLine, candidates: [String]) -> Bool {
    if let hashed = line.hashed {
        return candidates.contains { hashed.matches(host: $0) }
    }
    guard let patterns = line.patterns else { return false }
    var matchedPositive = false
    for pattern in patterns {
        let negated = pattern.hasPrefix("!")
        let body = negated ? String(pattern.dropFirst()) : pattern
        let hit = candidates.contains { candidate in matchPattern(body, against: candidate) }
        if negated, hit { return false }      // 否证命中：整行不算匹配
        if hit { matchedPositive = true }
    }
    return matchedPositive
}

/// OpenSSH 的 `match_pattern`：`*` 与 `?` 是通配，`\` 转义下一个字符。
///
/// 大小写：OpenSSH 把被查的主机名转小写后再与模式**按字节**比，所以模式里写
/// `GitHub.COM` 在它那儿永不命中。我们连模式一起转小写——多认一些行只会让
/// 判定更常落在"命中/同类型不同密钥"这两条有解释的路径上，
/// 而按字面比会把用户手写的行降成"这台主机没有记录"，凭空多一次首次询问。
public func matchPattern(_ pattern: String, against text: String) -> Bool {
    enum Token {
        case literal(Character)
        case anyCharacter
        case anyString
    }
    var tokens: [Token] = []
    var iterator = pattern.lowercased().makeIterator()
    while let character = iterator.next() {
        switch character {
        case "*": tokens.append(.anyString)
        case "?": tokens.append(.anyCharacter)
        case "\\":
            guard let escaped = iterator.next() else { return false }   // 结尾孤零零的反斜杠：OpenSSH 也当不合法
            tokens.append(.literal(escaped))
        default: tokens.append(.literal(character))
        }
    }

    let input = Array(text.lowercased())
    var inputIndex = 0
    var tokenIndex = 0
    var lastStarToken = -1
    var inputAfterStar = 0

    while inputIndex < input.count {
        if tokenIndex < tokens.count {
            switch tokens[tokenIndex] {
            case .literal(let expected) where input[inputIndex] == expected:
                inputIndex += 1
                tokenIndex += 1
                continue
            case .anyCharacter:
                inputIndex += 1
                tokenIndex += 1
                continue
            case .anyString:
                lastStarToken = tokenIndex
                inputAfterStar = inputIndex
                tokenIndex += 1
                continue
            default:
                break
            }
        }
        if lastStarToken >= 0 {
            tokenIndex = lastStarToken + 1
            inputAfterStar += 1
            inputIndex = inputAfterStar
            continue
        }
        return false
    }
    while tokenIndex < tokens.count, case .anyString = tokens[tokenIndex] { tokenIndex += 1 }
    return tokenIndex == tokens.count
}
