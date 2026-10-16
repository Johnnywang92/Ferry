import Darwin
import Foundation

/// 用户对一次信任询问的回答。
///
/// 三个而不是两个值，是因为 ADR-0000 §9 N3 定了"known_hosts 默认只读，
/// 写入要用户显式同意"——"同意连接"和"同意顺手写进 OpenSSH 的文件"是两次同意。
public enum HostKeyDecision: String, Sendable, Hashable {
    /// 接受，只写 Ferry 自己的存储。
    case accept
    /// 接受，并同时追加到 `writableKnownHosts` 里的第一个文件（用户显式勾选才会走到这里）。
    case acceptAndWriteKnownHosts
    /// 拒绝。
    case decline
}

/// 为什么要问用户。文案由 UI 决定，但原因必须是后端给的事实，
/// 不能统一写成"未知主机"——"这台在表里只有 ed25519，这次谈成了 rsa"和
/// "从没见过这台"该长得完全不一样。
public enum HostKeyQuestionReason: Sendable, Hashable {
    case unknownHost
    case hostKnownWithOtherAlgorithms(knownTypes: [String], source: String)
    case certificateOnly(source: String)
}

public struct HostKeyQuestion: Sendable, Hashable {
    public let endpoint: Endpoint
    public let hostKey: HostKey
    public let reason: HostKeyQuestionReason

    public init(endpoint: Endpoint, hostKey: HostKey, reason: HostKeyQuestionReason) {
        self.endpoint = endpoint
        self.hostKey = hostKey
        self.reason = reason
    }
}

public protocol HostKeyTrustPrompt: Sendable {
    /// 返回 `.decline` 时 `HostKeyStore` 抛 `CancellationError`——用户主动中止，
    /// 不是主机的密钥变了，UI 不该因此显示中间人警告。
    func ask(_ question: HostKeyQuestion) async -> HostKeyDecision
}

public struct HostKeyStoreConfig: Sendable, Hashable {
    /// Ferry 自己的存储，known_hosts 同格式。
    public var storeURL: URL
    /// 只读兼容的 OpenSSH 文件，按优先级排列；不存在的跳过。
    public var readOnlyKnownHosts: [URL]
    /// 用户显式同意后可以写入的文件。默认指向用户的 `known_hosts`，
    /// 但只有 `.acceptAndWriteKnownHosts` 才会真的动它。
    public var writableKnownHosts: [URL]
    /// 写进自己存储的行是否哈希主机名。默认关：明文行能用 `ssh-keygen -F` 直接查，
    /// 用户随时可以 `ssh-keygen -H -f` 把整个文件哈希掉，而读侧本来就支持哈希行
    /// （有 `ssh-keygen -H` 产出的实测向量盯着这条）。
    public var hashStoredHostNames: Bool

    public init(storeURL: URL, readOnlyKnownHosts: [URL], writableKnownHosts: [URL],
                hashStoredHostNames: Bool = false) {
        self.storeURL = storeURL
        self.readOnlyKnownHosts = readOnlyKnownHosts
        self.writableKnownHosts = writableKnownHosts
        self.hashStoredHostNames = hashStoredHostNames
    }

    /// 照抄本机 `ssh -G` 给出的默认文件顺序（OpenSSH_10.3p1 实测：
    /// `userknownhostsfile ~/.ssh/known_hosts ~/.ssh/known_hosts2`，
    /// `globalskownhostsfile /etc/ssh/ssh_known_hosts /etc/ssh/ssh_known_hosts2`）。
    public static func standard(storeURL: URL) -> HostKeyStoreConfig {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return HostKeyStoreConfig(
            storeURL: storeURL,
            readOnlyKnownHosts: [
                home.appendingPathComponent(".ssh/known_hosts"),
                home.appendingPathComponent(".ssh/known_hosts2"),
                URL(fileURLWithPath: "/etc/ssh/ssh_known_hosts"),
                URL(fileURLWithPath: "/etc/ssh/ssh_known_hosts2"),
            ],
            writableKnownHosts: [home.appendingPathComponent(".ssh/known_hosts")])
    }
}

/// known_hosts 的读写与信任判定，挂在握手与认证之间的 `HostKeyTrust` 接缝上。
///
/// 处置表，每格都有实测依据（docs/spike/M1-03）：
/// - 精确命中 → 直接放行；
/// - 同主机同类型不同密钥 → **硬阻断**：不询问、不改文件、没有跳过；
/// - 命中 `@revoked` → 硬阻断，撤销优先于任何合法行；
/// - 主机有记录但没有本次类型 / 只有证书行 → 问用户，接受才落盘；
/// - 从没见过 → 问用户（TOFU）。
///
/// actor 而不是纯函数：写盘是"重新读 → 合并 → 原子替换"，必须串行，
/// 否则两个并发连接会互相盖掉对方刚加的那一行。
public actor HostKeyStore: HostKeyTrust {
    private let config: HostKeyStoreConfig
    private let prompt: any HostKeyTrustPrompt
    private let fileManager: FileManager

    /// 每个文件上次读到的磁盘形状，变了就重读。用户在 Ferry 运行期间手改
    /// known_hosts 或被 `ssh` 追加了一行，下一次连接必须看见。
    private var cache: [String: (signature: String, file: KnownHostsFile)] = [:]

    public init(config: HostKeyStoreConfig, prompt: any HostKeyTrustPrompt, fileManager: FileManager = .default) {
        self.config = config
        self.prompt = prompt
        self.fileManager = fileManager
    }

    /// 当前所有已知行（自己的存储 + 只读文件），顺序即信任优先级。
    public func knownHostsFiles() throws -> [KnownHostsFile] {
        var files: [KnownHostsFile?] = [try read(config.storeURL)]
        for url in config.readOnlyKnownHosts where url != config.storeURL {
            files.append(try read(url))
        }
        return files.compactMap { $0 }
    }

    /// 只查不判。UI 在拿到 `.hostKeyMismatch` 之后用它把"哪一行、哪个文件、什么类型"
    /// 显示出来——错误本身只带指纹，细节留在这一格，免得 `RemoteError` 的形状被 UI 需求拖着改。
    public func verdict(for endpoint: Endpoint, hostKey: HostKey) throws -> HostKeyVerdict {
        lookupHostKey(host: endpoint.host, port: endpoint.port,
                      key: KnownHostKey(keyType: hostKey.wireType, blob: hostKey.blob),
                      in: try knownHostsFiles())
    }

    public func evaluate(endpoint: Endpoint, hostKey: HostKey) async throws {
        // 服务器直接呈上证书：本期不做证书链校验，也没有可比对的叶子密钥记录。
        // 实测（docs/spike/M1-03 §5，带 HostCertificate 的那台 2299）：libssh2 的 KEXINIT
        // 里没有任何 `*-cert-v01@openssh.com`，服务器于是改发普通密钥，这条走不到；
        // 策略里强写证书名时它在 KEX 里就失败（-5/-8），也不会把证书交出来。
        // "交不出来"是 libssh2 1.11.1 的实现细节而不是协议保证，所以判定层保留这条硬拒绝，
        // 而不是假设上面一定挡得住。
        if hostKey.isCertificate {
            throw RemoteError.protocolViolation("主机以证书形式呈上密钥（\(hostKey.wireType)），本期不支持证书校验")
        }

        let key = KnownHostKey(keyType: hostKey.wireType, blob: hostKey.blob)
        switch lookupHostKey(host: endpoint.host, port: endpoint.port, key: key, in: try knownHostsFiles()) {
        case .trusted:
            return
        case .keyChanged:
            throw RemoteError.hostKeyMismatch(fingerprint: hostKey.fingerprintSHA256)
        case .revoked:
            throw RemoteError.hostKeyMismatch(fingerprint: hostKey.fingerprintSHA256)
        case .otherAlgorithm(let sources, let knownTypes):
            try await askAndRecord(endpoint: endpoint, hostKey: hostKey,
                                   reason: .hostKnownWithOtherAlgorithms(knownTypes: knownTypes,
                                                                         source: sources.joined(separator: ", ")))
        case .certificateOnly(let sources):
            // 表里只有 CA 行或证书行——本次呈上是普通密钥，所以按"没有可用记录"处理，
            // 但要把原因说清，否则用户会以为自己已经信过这台主机。
            try await askAndRecord(endpoint: endpoint, hostKey: hostKey,
                                   reason: .certificateOnly(source: sources.joined(separator: ", ")))
        case .unknown:
            try await askAndRecord(endpoint: endpoint, hostKey: hostKey, reason: .unknownHost)
        }
    }

    /// 删掉某台主机在自己存储里的记录（可按类型过滤）。密钥正常轮换后这是唯一的恢复路径；
    /// 它和"跳过本次警告"是两回事——删除是用户的主动动作，跳过是无条件放行。
    @discardableResult
    public func removeRecords(host: String, port: Int? = nil, keyType: String? = nil) throws -> Int {
        let candidates = port.map { hostCandidates(host: host, port: $0) } ?? [host.lowercased()]
        let existing = try read(config.storeURL)?.lines ?? []
        let survivors = existing.filter { line in
            if let keyType, line.key.keyType != keyType { return true }
            return !hostLineMatches(line, candidates: candidates)
        }
        let removed = existing.count - survivors.count
        if removed > 0 {
            try write(lines: survivors, to: config.storeURL)
            cache[config.storeURL.path] = nil
        }
        return removed
    }

    private func askAndRecord(endpoint: Endpoint, hostKey: HostKey, reason: HostKeyQuestionReason) async throws {
        let decision = await prompt.ask(HostKeyQuestion(endpoint: endpoint, hostKey: hostKey, reason: reason))
        let key = KnownHostKey(keyType: hostKey.wireType, blob: hostKey.blob)
        switch decision {
        case .decline:
            throw CancellationError()
        case .accept:
            try record(endpoint: endpoint, key: key, to: config.storeURL)
        case .acceptAndWriteKnownHosts:
            try record(endpoint: endpoint, key: key, to: config.storeURL)
            if let target = config.writableKnownHosts.first, target != config.storeURL {
                try record(endpoint: endpoint, key: key, to: target)
            }
        }
    }

    // MARK: - 读写

    /// 幂等追加：同一主机、同一类型、同一把密钥不重复写。
    ///
    /// 刻意"每次写都重新读"：缓存只服务查表，落盘前必须以磁盘上的内容为准，
    /// 否则会把 `ssh` 或用户刚加的行连同自己的旧行一起盖掉。
    private func record(endpoint: Endpoint, key: KnownHostKey, to url: URL) throws {
        var lines = try read(url, fresh: true)?.lines ?? []
        let candidates = hostCandidates(host: endpoint.host, port: endpoint.port)
        let already = lines.contains { line in
            line.marker == nil && line.key == key && hostLineMatches(line, candidates: candidates)
        }
        guard !already else { return }
        lines.append(try renderLine(host: endpoint.host, port: endpoint.port, key: key))
        try write(lines: lines, to: url)
        cache[url.path] = nil
    }

    /// 写成 known_hosts 的一行。主机字段：端口 22 写字面主机名，其余写 `[host]:port`，
    /// 与 `ssh` 自己追加时的形状一致（实测 `[127.0.0.1]:2201`）。
    private func renderLine(host: String, port: Int, key: KnownHostKey) throws -> KnownHostLine {
        let lowered = host.lowercased()
        // 方括号只包住主机名，端口在外面：`[127.0.0.1]:2201`。
        // 写反了（`[127.0.0.1:2201]`）这行永远匹配不上，而 `hostCandidates` 用的就是前一种形状。
        let field = port == 22 ? lowered : "[\(lowered)]:\(port)"
        if config.hashStoredHostNames {
            return KnownHostLine(lineNumber: 0, marker: nil, patterns: nil,
                                 hashed: HashedHostName.make(host: field, salt: HashedHostName.randomSalt()),
                                 key: key, comment: nil)
        }
        return KnownHostLine(lineNumber: 0, marker: nil, patterns: [field], hashed: nil, key: key, comment: nil)
    }

    private func read(_ url: URL, fresh: Bool = false) throws -> KnownHostsFile? {
        let path = url.path
        guard fileManager.fileExists(atPath: path) else { return nil }
        let signature = fileSignature(at: path)
        if !fresh, let cached = cache[path], cached.signature == signature { return cached.file }
        guard let data = fileManager.contents(atPath: path) else {
            throw RemoteError.localIO(.readFailed)
        }
        let file = KnownHostsFile.parse(String(decoding: data, as: UTF8.self), source: path)
        cache[path] = (signature, file)
        return file
    }

    private func fileSignature(at path: String) -> String {
        let attributes = (try? fileManager.attributesOfItem(atPath: path)) ?? [:]
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = attributes[.size] as? NSNumber ?? 0
        return "\(modified)|\(size)"
    }

    private func write(lines: [KnownHostLine], to url: URL) throws {
        let text = lines.map { $0.rendered + "\n" }.joined()
        try write(text: text, to: url)
    }

    /// 临时文件 + `chmod 0600` + `rename`。
    ///
    /// 顺序有讲究：先设权限再改名，否则新文件存在一段"别人可读"的窗口；
    /// `rename` 保证读者要么看到旧内容、要么看到完整的新内容，不会看到半截文件。
    /// 写之前还要确认目标是自己的、非组内/其他可写的普通文件——known_hosts 一旦
    /// 能被别人改，"密钥变了"的判定就失去意义。
    private func write(text: String, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw RemoteError.localIO(.writeFailed) }
        } else {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
        }
        try destinationIsSafe(url)

        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        guard fileManager.createFile(atPath: temporary.path, contents: Data(text.utf8),
                                     attributes: [.posixPermissions: 0o600]) else {
            throw RemoteError.localIO(.writeFailed)
        }
        guard rename(temporary.path, url.path) == 0 else {
            try? fileManager.removeItem(at: temporary)
            throw RemoteError.localIO(.writeFailed)
        }
    }

    private func destinationIsSafe(_ url: URL) throws {
        let path = url.path
        guard fileManager.fileExists(atPath: path) else { return }
        guard let attributes = try? fileManager.attributesOfItem(atPath: path) else {
            throw RemoteError.localIO(.writeFailed)
        }
        guard (attributes[.type] as? FileAttributeType) != .typeSymbolicLink,
              let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.uint16Value & 0o077 == 0,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid() else {
            throw RemoteError.localIO(.writeFailed)
        }
    }
}

extension KnownHostLine {
    /// 落盘文本，与 known_hosts 同格式：`ssh-keygen -F/-l/-H` 都能直接作用于我们的存储。
    public var rendered: String {
        let hostField = hashed?.encoded ?? (patterns ?? []).joined(separator: ",")
        let keyField = "\(key.keyType) \(key.blob.base64EncodedString())"
        if let marker { return "\(marker.rawValue) \(hostField) \(keyField)" }
        return "\(hostField) \(keyField)"
    }
}
