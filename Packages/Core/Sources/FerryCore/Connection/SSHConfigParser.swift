import Foundation

/// 从 `~/.ssh/config` 解析出的单条具体主机配置（M2 交付，v2.3 §520 / §526）。
public struct SSHHostEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: String { alias }

    /// `Host` 声明里的具体别名（不含 `*`/`?`/`!` 通配符）。
    public let alias: String
    /// 实际连接目标主机名（未配 `HostName` 时回退为 `alias`）。
    public let hostName: String
    /// 端口（默认 22）。
    public let port: Int
    /// 用户名（未配时为 nil，由导入方回退当前系统用户名）。
    public let user: String?
    /// 按优先级排列的私钥路径（已将开头的 `~` 展开为 `homeDirectory`）。
    public let identityFiles: [String]
    /// 是否显式声明 `IdentitiesOnly yes`。
    public let identitiesOnly: Bool
    /// `ProxyJump` 或 `ProxyCommand` 原始配置（v2.3 §526：保留导入项并标注 v1.1+ 暂不支持实际跳转）。
    public let proxyJump: String?
    /// 配置里是否显式开启了 `ssh-rsa` / `cbc` / `sha1` 等老设备弱算法。
    public let prefersWeakAlgorithms: Bool

    public init(
        alias: String,
        hostName: String,
        port: Int = 22,
        user: String? = nil,
        identityFiles: [String] = [],
        identitiesOnly: Bool = false,
        proxyJump: String? = nil,
        prefersWeakAlgorithms: Bool = false
    ) {
        self.alias = alias
        self.hostName = hostName
        self.port = port
        self.user = user
        self.identityFiles = identityFiles
        self.identitiesOnly = identitiesOnly
        self.proxyJump = proxyJump
        self.prefersWeakAlgorithms = prefersWeakAlgorithms
    }
}

/// 纯 Swift OpenSSH 客户端配置（`~/.ssh/config`）解析器。
///
/// 零 C 依赖，可在 Core 单测里直接针对各种复杂语料秒级运行：
/// - 支持 `Key Value` 与 `Key = Value`、双引号包裹参数（含空格路径）、`#` 行内注释；
/// - 支持同行多别名（`Host web1 web2 *.corp !bad.corp`），只将具体别名提取为可导入站点，
///   同时让通配段（如 `Host *.corp`、`Host *`）按规则向匹配的站点提供默认属性；
/// - 具体 `Host` 块的单值指令优先于含通配符的默认块，同级块之间遵循 OpenSSH first-match-wins；
/// - 展开 `IdentityFile` 的 `~/` 前缀与 `HostName` 的 `%h` 占位符。
public enum SSHConfigParser {
    private struct RawBlock {
        let patterns: [String]
        let directives: [(key: String, value: String)]

        var isWildcardBlock: Bool {
            patterns.allSatisfy { Self.containsWildcard($0) }
        }

        static func containsWildcard(_ pattern: String) -> Bool {
            pattern.contains("*") || pattern.contains("?") || pattern.hasPrefix("!")
        }
    }

    /// 从配置文件文本解析所有可导入的具体主机条目。
    public static func parse(
        _ content: String,
        homeDirectory: String = NSHomeDirectory()
    ) -> [SSHHostEntry] {
        let blocks = parseBlocks(content)

        // 按出现顺序收集去重后的具体 Host 别名（不含 * / ? / !）
        var aliases: [String] = []
        var seen = Set<String>()
        for block in blocks {
            for pattern in block.patterns where !RawBlock.containsWildcard(pattern) && !pattern.isEmpty {
                if seen.insert(pattern).inserted {
                    aliases.append(pattern)
                }
            }
        }

        return aliases.map { alias in
            resolveEntry(for: alias, in: blocks, homeDirectory: homeDirectory)
        }
    }

    /// 从磁盘文件解析（默认 `~/.ssh/config`）。
    public static func parseFile(
        at url: URL,
        homeDirectory: String = NSHomeDirectory()
    ) throws -> [SSHHostEntry] {
        let content = try String(contentsOf: url, encoding: .utf8)
        return parse(content, homeDirectory: homeDirectory)
    }

    // MARK: - 内部解析

    private static func parseBlocks(_ content: String) -> [RawBlock] {
        var blocks: [RawBlock] = []
        // 在第一个 `Host` 之前的顶层指令视作隐式 `Host *`
        var currentPatterns: [String] = ["*"]
        var currentDirectives: [(key: String, value: String)] = []
        var encounteredHost = false

        for rawLine in content.components(separatedBy: .newlines) {
            let stripped = stripComment(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if stripped.isEmpty { continue }

            guard let (rawKey, rawValue) = splitDirective(stripped) else { continue }
            let key = rawKey.lowercased()

            if key == "host" {
                if encounteredHost || !currentDirectives.isEmpty {
                    blocks.append(RawBlock(patterns: currentPatterns, directives: currentDirectives))
                }
                encounteredHost = true
                currentPatterns = tokenizeArgs(rawValue)
                currentDirectives = []
            } else if key == "match" {
                // `Match` 条件块依赖运行时上下文（exec/localnetwork 等），先归档当前块并将其视作不与静态别名匹配的块
                if encounteredHost || !currentDirectives.isEmpty {
                    blocks.append(RawBlock(patterns: currentPatterns, directives: currentDirectives))
                }
                encounteredHost = true
                currentPatterns = []
                currentDirectives = []
            } else {
                currentDirectives.append((key: key, value: unquote(rawValue)))
            }
        }

        if encounteredHost || !currentDirectives.isEmpty {
            blocks.append(RawBlock(patterns: currentPatterns, directives: currentDirectives))
        }

        return blocks
    }

    private static func resolveEntry(
        for alias: String,
        in blocks: [RawBlock],
        homeDirectory: String
    ) -> SSHHostEntry {
        // 先排含具体名命中的块，再排纯通配块（如 `Host *` 或 `Host *.example.com`），
        // 这样无论用户把 `Host *` 写在文件开头还是末尾，具体块里的配置都不会被全局默认覆盖，
        // 而同级块内严格遵守 OpenSSH first-match-wins。
        let matchingBlocks = blocks.filter { matches(alias: alias, patterns: $0.patterns) }
        let specificBlocks = matchingBlocks.filter { $0.patterns.contains(where: { !RawBlock.containsWildcard($0) && $0 == alias }) }
        let wildcardBlocks = matchingBlocks.filter { !$0.patterns.contains(where: { !RawBlock.containsWildcard($0) && $0 == alias }) }
        let orderedBlocks = specificBlocks + wildcardBlocks

        var hostName: String?
        var port: Int?
        var user: String?
        var identityFiles: [String] = []
        var seenIdentities = Set<String>()
        var identitiesOnly: Bool?
        var proxyJump: String?
        var prefersWeak = false

        for block in orderedBlocks {
            for (key, value) in block.directives {
                switch key {
                case "hostname":
                    if hostName == nil, !value.isEmpty {
                        hostName = value.replacingOccurrences(of: "%h", with: alias)
                    }
                case "user":
                    if user == nil, !value.isEmpty {
                        user = value
                    }
                case "port":
                    if port == nil, let parsed = Int(value), (1...65535).contains(parsed) {
                        port = parsed
                    }
                case "identityfile":
                    let expanded = expandPath(value, alias: alias, hostName: hostName ?? alias, user: user, homeDirectory: homeDirectory)
                    if !expanded.isEmpty, seenIdentities.insert(expanded).inserted {
                        identityFiles.append(expanded)
                    }
                case "identitiesonly":
                    if identitiesOnly == nil {
                        let lower = value.lowercased()
                        if lower == "yes" || lower == "true" {
                            identitiesOnly = true
                        } else if lower == "no" || lower == "false" {
                            identitiesOnly = false
                        }
                    }
                case "proxyjump", "proxycommand":
                    if proxyJump == nil, !value.isEmpty, value.lowercased() != "none" {
                        proxyJump = value
                    }
                case "hostkeyalgorithms", "pubkeyacceptedalgorithms", "pubkeyacceptedkeytypes",
                     "kexalgorithms", "ciphers", "macs":
                    if containsWeakAlgorithmToken(value) {
                        prefersWeak = true
                    }
                default:
                    break
                }
            }
        }

        return SSHHostEntry(
            alias: alias,
            hostName: hostName ?? alias,
            port: port ?? 22,
            user: user,
            identityFiles: identityFiles,
            identitiesOnly: identitiesOnly ?? false,
            proxyJump: proxyJump,
            prefersWeakAlgorithms: prefersWeak
        )
    }

    private static func containsWeakAlgorithmToken(_ value: String) -> Bool {
        let lower = value.lowercased()
        let weakTokens = [
            "ssh-rsa",
            "ssh-dss",
            "diffie-hellman-group1-sha1",
            "diffie-hellman-group14-sha1",
            "diffie-hellman-group-exchange-sha1",
            "aes128-cbc",
            "aes192-cbc",
            "aes256-cbc",
            "3des-cbc",
            "hmac-sha1"
        ]
        return weakTokens.contains { lower.contains($0) }
    }

    private static func expandPath(
        _ raw: String,
        alias: String,
        hostName: String,
        user: String?,
        homeDirectory: String
    ) -> String {
        var result = raw
        if result == "~" {
            result = homeDirectory
        } else if result.hasPrefix("~/") {
            let trimmedHome = homeDirectory.hasSuffix("/") ? String(homeDirectory.dropLast()) : homeDirectory
            result = trimmedHome + String(result.dropFirst(1))
        }
        result = result
            .replacingOccurrences(of: "%d", with: homeDirectory)
            .replacingOccurrences(of: "%h", with: hostName)
            .replacingOccurrences(of: "%n", with: alias)
        if let user {
            result = result.replacingOccurrences(of: "%r", with: user)
        }
        return result
    }

    /// OpenSSH `Host` 模式列表匹配：任一正向模式命中且没有任何 `!negated` 模式命中即算匹配。
    private static func matches(alias: String, patterns: [String]) -> Bool {
        guard !patterns.isEmpty else { return false }
        var matchedPositive = false
        for pattern in patterns {
            if pattern.hasPrefix("!") {
                let inner = String(pattern.dropFirst())
                if globMatch(text: alias, pattern: inner) {
                    return false
                }
            } else if globMatch(text: alias, pattern: pattern) {
                matchedPositive = true
            }
        }
        return matchedPositive
    }

    /// 支持 `*`（任意长度字符）与 `?`（单个字符）的通配匹配。
    private static func globMatch(text: String, pattern: String) -> Bool {
        let t = Array(text)
        let p = Array(pattern)
        var ti = 0
        var pi = 0
        var starIdx = -1
        var matchIdx = 0

        while ti < t.count {
            if pi < p.count && (p[pi] == "?" || p[pi] == t[ti]) {
                ti += 1
                pi += 1
            } else if pi < p.count && p[pi] == "*" {
                starIdx = pi
                matchIdx = ti
                pi += 1
            } else if starIdx != -1 {
                pi = starIdx + 1
                matchIdx += 1
                ti = matchIdx
            } else {
                return false
            }
        }
        while pi < p.count && p[pi] == "*" {
            pi += 1
        }
        return pi == p.count
    }

    /// 剥离不在引号内的 `#` 注释。
    private static func stripComment(_ line: String) -> String {
        var inQuotes = false
        var result = ""
        for ch in line {
            if ch == "\"" {
                inQuotes.toggle()
                result.append(ch)
            } else if ch == "#" && !inQuotes {
                break
            } else {
                result.append(ch)
            }
        }
        return result
    }

    /// 拆分 `Key Value` 或 `Key = Value`。
    private static func splitDirective(_ line: String) -> (String, String)? {
        var key = ""
        var index = line.startIndex
        while index < line.endIndex {
            let ch = line[index]
            if ch.isWhitespace || ch == "=" {
                break
            }
            key.append(ch)
            index = line.index(after: index)
        }
        guard !key.isEmpty, index < line.endIndex else { return nil }

        // 跳过空白与最多一个 `=`
        while index < line.endIndex && line[index].isWhitespace {
            index = line.index(after: index)
        }
        if index < line.endIndex && line[index] == "=" {
            index = line.index(after: index)
        }
        while index < line.endIndex && line[index].isWhitespace {
            index = line.index(after: index)
        }
        let value = String(line[index...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return (key, value)
    }

    private static func tokenizeArgs(_ raw: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for ch in raw {
            if ch == "\"" {
                inQuotes.toggle()
            } else if ch.isWhitespace && !inQuotes {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    private static func unquote(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= 2 && trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"") {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }
}
