import Foundation
import Testing

@testable import FerryCore

/// M1'-3 的处置表测试。每格对应 ADR-0000 §9 N3 与 docs/spike/M1-03 的一条实测行为，
/// 断言的都是"用户会据此做出安全决定"的那件事：有没有弹窗、弹窗说什么、文件动没动。
///
/// 密钥一律用 `wireBlob(type:payload:)` 造的合成 blob，只有形状是真的——
/// 指纹比对、类型挑选、权限与并发这些行为跟密钥内容无关，
/// 而把容器里那把 ed25519 抄进测试会让"同一主机两条不同类型"这种用例写不出来。

private actor StubPrompt: HostKeyTrustPrompt {
    private var recorded: [HostKeyQuestion] = []
    private var answered = 0
    private let decisions: [HostKeyDecision]

    /// 决策不够用时一律按 `.decline`：测试忘了准备决策应当表现为"没写盘"，
    /// 而不是崩溃或误放行。
    init(_ decisions: [HostKeyDecision] = [.accept]) {
        self.decisions = decisions
    }

    func ask(_ question: HostKeyQuestion) async -> HostKeyDecision {
        recorded.append(question)
        defer { answered += 1 }
        guard answered < decisions.count else { return .decline }
        return decisions[answered]
    }

    var questions: [HostKeyQuestion] { recorded }
    var askCount: Int { recorded.count }
}

private func scratchDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ferry-hostkey-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func readFile(_ url: URL) -> String {
    String(decoding: (try? Data(contentsOf: url)) ?? Data(), as: UTF8.self)
}

private func permissions(_ path: String) -> Int {
    let attributes = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]
    return Int((attributes[.posixPermissions] as? NSNumber)?.int32Value ?? -1)
}

private func endpoint(_ host: String, port: Int = 22) -> Endpoint {
    Endpoint(host: host, port: port, username: "tester")
}

/// 预置一个 known_hosts 形状的文件。权限必须照真的来：`write(atomically:)` 落出来是 0644，
/// 而 `destinationIsSafe` 见到"组内/其他可读"就拒绝写入——那是被测代码想要的行为，
/// 不是这几个测试想要的起点。
private func seed(_ text: String, at url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

@Test("TOFU：没见过 → 问一次 → 接受才落盘 → 第二次不再问")
func tofuFirstContact() async throws {
    let scratch = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let storeURL = scratch.appendingPathComponent("store/known_hosts")
    let prompt = StubPrompt([.accept])
    let store = HostKeyStore(config: HostKeyStoreConfig(storeURL: storeURL, readOnlyKnownHosts: [],
                                                        writableKnownHosts: []),
                             prompt: prompt)
    let key = try hostKeyFor("ssh-ed25519")

    try await store.evaluate(endpoint: endpoint("tofu.example.com"), hostKey: key)
    #expect(await prompt.askCount == 1)
    let question = try #require(await prompt.questions.first)
    #expect(question.reason == .unknownHost)
    #expect(question.hostKey.fingerprintSHA256 == key.fingerprintSHA256)

    // 落盘是 known_hosts 同格式的一行，端口 22 所以主机名字面写。
    let written = readFile(storeURL)
    #expect(written == "tofu.example.com ssh-ed25519 \(key.blob.base64EncodedString())\n")

    // 第二次同一把密钥：直接放行，一次都不问。
    try await store.evaluate(endpoint: endpoint("TOFU.example.com"), hostKey: key)
    #expect(await prompt.askCount == 1)
}

@Test("TOFU：拒绝 = CancellationError，不是 hostKeyMismatch，且不留文件")
func tofuDecline() async throws {
    let scratch = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let storeURL = scratch.appendingPathComponent("store/known_hosts")
    let prompt = StubPrompt([.decline])
    let store = HostKeyStore(config: HostKeyStoreConfig(storeURL: storeURL, readOnlyKnownHosts: [],
                                                        writableKnownHosts: []),
                             prompt: prompt)
    try await #expect(throws: CancellationError.self) {
        try await store.evaluate(endpoint: endpoint("decline.example.com"),
                                hostKey: try hostKeyFor("ssh-ed25519"))
    }
    #expect(FileManager.default.fileExists(atPath: storeURL.path) == false)
}

@Test("只读兼容：用户 known_hosts 里的行直接放行，且一个字节都不改")
func readOnlyKnownHostsIsHonored() async throws {
    let scratch = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let key = try hostKeyFor("ssh-ed25519")
    let sshFile = scratch.appendingPathComponent("ssh/known_hosts")
    let original = "already.example.com ssh-ed25519 \(key.blob.base64EncodedString())\n"
    try seed(original, at: sshFile)

    let storeURL = scratch.appendingPathComponent("store/known_hosts")
    let prompt = StubPrompt([.acceptAndWriteKnownHosts])
    let store = HostKeyStore(config: HostKeyStoreConfig(storeURL: storeURL,
                                                        readOnlyKnownHosts: [sshFile],
                                                        // 就算用户勾了"写进 known_hosts"，命中已有行也不该走写入分支
                                                        writableKnownHosts: [sshFile]),
                             prompt: prompt)

    try await store.evaluate(endpoint: endpoint("already.example.com"), hostKey: key)
    #expect(await prompt.askCount == 0)
    #expect(readFile(sshFile) == original)
    #expect(FileManager.default.fileExists(atPath: storeURL.path) == false)

    let verdict = try await store.verdict(for: endpoint("already.example.com"), hostKey: key)
    #expect(verdict == .trusted(source: sshFile.path, line: 1, keyType: "ssh-ed25519"))
}

@Test("哈希主机名：ssh-keygen -H 产出的 |1| 行命中，一次都不问")
func hashedReadOnlyRowIsTrusted() async throws {
    let scratch = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let sshFile = scratch.appendingPathComponent("ssh/known_hosts")
    try FileManager.default.createDirectory(at: sshFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    // 这一行是 2026-10-16 对 `192.0.2.1 ssh-ed25519 <vectorBlob>` 跑
    // `ssh-keygen -H -f`（本机 OpenSSH_10.3p1）得到的原文，盐与哈希都在
    // KnownHostsTests 里独立反算对过；blob 必须与向量配套，否则换密钥就测不出命中。
    let hashed = "|1|gQtnD1Zub4HKvYHdWStCUd0gpbs=|LRxNFX9lI5qTH3W0y/qnOp/BOAM="
    try "\(hashed) ssh-ed25519 \(vectorBlob.base64EncodedString())\n"
        .write(to: sshFile, atomically: true, encoding: .utf8)

    let prompt = StubPrompt([.accept])
    let store = HostKeyStore(config: HostKeyStoreConfig(storeURL: scratch.appendingPathComponent("store/known_hosts"),
                                                        readOnlyKnownHosts: [sshFile], writableKnownHosts: []),
                             prompt: prompt)
    let key = try HostKey(algorithm: "ssh-ed25519", blob: vectorBlob)
    try await store.evaluate(endpoint: endpoint("192.0.2.1"), hostKey: key)
    #expect(await prompt.askCount == 0)

    // 哈希行只认哈希输入里那个字符串：同一把密钥换个 IP 必须重新问。
    try await store.evaluate(endpoint: endpoint("192.0.2.53"), hostKey: key)
    #expect(await prompt.askCount == 1)
}

@Test("运行期间外部改了 known_hosts，下一次判定要看见")
func externalEditInvalidatesTheCache() async throws {
    let scratch = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let sshFile = scratch.appendingPathComponent("ssh/known_hosts")
    try FileManager.default.createDirectory(at: sshFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    let key = try hostKeyFor("ssh-ed25519")
    let other = try hostKeyFor("ssh-ed25519", payload: [4, 5])
    try "was-here.example.org ssh-ed25519 \(key.blob.base64EncodedString())\n"
        .write(to: sshFile, atomically: true, encoding: .utf8)

    let prompt = StubPrompt([.accept])
    let store = HostKeyStore(config: HostKeyStoreConfig(storeURL: scratch.appendingPathComponent("store/known_hosts"),
                                                        readOnlyKnownHosts: [sshFile], writableKnownHosts: []),
                             prompt: prompt)
    try await store.evaluate(endpoint: endpoint("was-here.example.org"), hostKey: key)
    #expect(await prompt.askCount == 0)

    // 用户在 Ferry 运行期间删掉这行、换成另一台（`ssh` 自己追加也是这个形状）。
    try "a-different-host.example.net ssh-ed25519 \(other.blob.base64EncodedString())\n"
        .write(to: sshFile, atomically: true, encoding: .utf8)
    // 用缓存的话这里仍然"可信"——那正是"文件里已经没有了还在放行"的 bug。
    try await store.evaluate(endpoint: endpoint("was-here.example.org"), hostKey: key)
    #expect(await prompt.askCount == 1)
    try await store.evaluate(endpoint: endpoint("a-different-host.example.net"), hostKey: other)
    #expect(await prompt.askCount == 1)
}

@Test("多算法：已记 ed25519，本次谈成 ecdsa → 提示原因是'只有别的算法'，不是密钥变更")
func otherAlgorithmIsNotKeyChange() async throws {
    let scratch = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let storeURL = scratch.appendingPathComponent("store/known_hosts")
    let ed = try hostKeyFor("ssh-ed25519")
    try seed("multi.example.com ssh-ed25519 \(ed.blob.base64EncodedString())\n", at: storeURL)

    let prompt = StubPrompt([.accept])
    let store = HostKeyStore(config: HostKeyStoreConfig(storeURL: storeURL, readOnlyKnownHosts: [], writableKnownHosts: []),
                             prompt: prompt)
    let ecdsa = try hostKeyFor("ecdsa-sha2-nistp256")
    try await store.evaluate(endpoint: endpoint("multi.example.com"), hostKey: ecdsa)
    let question = try #require(await prompt.questions.first)
    #expect(question.reason == .hostKnownWithOtherAlgorithms(knownTypes: ["ssh-ed25519"], source: storeURL.path))
    #expect(readFile(storeURL).split(separator: "\n").count == 2)

    // 两条都在表里之后，再谈成 ed25519 或 ecdsa 都不该问。
    try await store.evaluate(endpoint: endpoint("multi.example.com"), hostKey: ed)
    try await store.evaluate(endpoint: endpoint("multi.example.com"), hostKey: ecdsa)
    #expect(await prompt.askCount == 1)
}

@Test("只有证书行的主机按'没有可用记录'处理，问的时候要说清")
func certificateOnlyRowsPrompt() async throws {
    let scratch = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let caFile = scratch.appendingPathComponent("ssh/ssh_known_hosts")
    try FileManager.default.createDirectory(at: caFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    let certKey = try hostKeyFor("ssh-ed25519-cert-v01@openssh.com")
    try "@cert-authority *.example.com \(certKey.wireType) \(certKey.blob.base64EncodedString())\n"
        .write(to: caFile, atomically: true, encoding: .utf8)

    let prompt = StubPrompt([.accept])
    let store = HostKeyStore(config: HostKeyStoreConfig(storeURL: scratch.appendingPathComponent("store/known_hosts"),
                                                        readOnlyKnownHosts: [caFile], writableKnownHosts: []),
                             prompt: prompt)
    let key = try hostKeyFor("ssh-ed25519")
    try await store.evaluate(endpoint: endpoint("host.example.com"), hostKey: key)
    let question = try #require(await prompt.questions.first)
    #expect(question.reason == .certificateOnly(source: caFile.path))
}

@Test("呈上证书本身就拒：不询问、不写盘")
func presentedCertificateIsRefused() async throws {
    let scratch = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let storeURL = scratch.appendingPathComponent("store/known_hosts")
    let prompt = StubPrompt([.accept])
    let store = HostKeyStore(config: HostKeyStoreConfig(storeURL: storeURL, readOnlyKnownHosts: [], writableKnownHosts: []),
                             prompt: prompt)
    let cert = try hostKeyFor("rsa-sha2-512-cert-v01@openssh.com")
    #expect(cert.isCertificate)
    do {
        try await store.evaluate(endpoint: endpoint("cert.example.com"), hostKey: cert)
        Issue.record("证书必须被拒")
    } catch let error as RemoteError {
        guard case .protocolViolation(let detail) = error else {
            Issue.record("应该是 protocolViolation，实际 \(error)")
            return
        }
        #expect(detail.contains("本期不支持证书校验"))
    }
    #expect(await prompt.askCount == 0)
    #expect(FileManager.default.fileExists(atPath: storeURL.path) == false)
}

@Test("密钥已变：硬阻断——不问、不改文件、抛的错带新指纹")
func keyChangeIsHardBlock() async throws {
    let scratch = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let storeURL = scratch.appendingPathComponent("store/known_hosts")
    let old = try hostKeyFor("ssh-ed25519", payload: [1])
    let fresh = "changed.example.com ssh-ed25519 \(old.blob.base64EncodedString())\n"
    try seed(fresh, at: storeURL)

    let prompt = StubPrompt([.accept, .acceptAndWriteKnownHosts])
    let store = HostKeyStore(config: HostKeyStoreConfig(storeURL: storeURL, readOnlyKnownHosts: [],
                                                        writableKnownHosts: [storeURL]),
                             prompt: prompt)
    let new = try hostKeyFor("ssh-ed25519", payload: [2])
    try await #expect(throws: RemoteError.hostKeyMismatch(fingerprint: new.fingerprintSHA256)) {
        try await store.evaluate(endpoint: endpoint("changed.example.com"), hostKey: new)
    }
    // "不可一键跳过"的可证伪版本：压根没给 UI 机会，文件也一个字节没动。
    #expect(await prompt.askCount == 0)
    #expect(readFile(storeURL) == fresh)

    // 唯一的恢复路径是用户主动删记录，删完退回 TOFU。
    let removed = try await store.removeRecords(host: "changed.example.com", port: 22)
    #expect(removed == 1)
    #expect(readFile(storeURL) == "")
    try await store.evaluate(endpoint: endpoint("changed.example.com"), hostKey: new)
    #expect(await prompt.askCount == 1)
}

@Test("撤销行优先：别处有同一把密钥的合法行也照样阻断")
func revokedRowOutranksValidRow() async throws {
    let scratch = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let key = try hostKeyFor("ssh-ed25519")
    let systemFile = scratch.appendingPathComponent("ssh/ssh_known_hosts")
    try FileManager.default.createDirectory(at: systemFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try """
        revoked.example.com ssh-ed25519 \(key.blob.base64EncodedString())
        @revoked revoked.example.com ssh-ed25519 \(key.blob.base64EncodedString())
        """.write(to: systemFile, atomically: true, encoding: .utf8)

    let prompt = StubPrompt([.accept])
    let store = HostKeyStore(config: HostKeyStoreConfig(storeURL: scratch.appendingPathComponent("store/known_hosts"),
                                                        readOnlyKnownHosts: [systemFile], writableKnownHosts: []),
                             prompt: prompt)
    try await #expect(throws: RemoteError.hostKeyMismatch(fingerprint: key.fingerprintSHA256)) {
        try await store.evaluate(endpoint: endpoint("revoked.example.com"), hostKey: key)
    }
    #expect(await prompt.askCount == 0)
}

@Test("信任按端口隔离：2201 的记录不覆盖 22，写成 [host]:port 与 ssh 同形")
func portScopedTrust() async throws {
    let scratch = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let storeURL = scratch.appendingPathComponent("store/known_hosts")
    try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let prompt = StubPrompt([.accept, .accept])
    let store = HostKeyStore(config: HostKeyStoreConfig(storeURL: storeURL, readOnlyKnownHosts: [], writableKnownHosts: []),
                             prompt: prompt)
    let key = try hostKeyFor("ssh-ed25519")
    try await store.evaluate(endpoint: endpoint("127.0.0.1", port: 2201), hostKey: key)
    #expect(readFile(storeURL) == "[127.0.0.1]:2201 ssh-ed25519 \(key.blob.base64EncodedString())\n")
    // 同一地址换个端口 = 另一台主机，还得再问一次。
    try await store.evaluate(endpoint: endpoint("127.0.0.1", port: 22), hostKey: key)
    #expect(await prompt.askCount == 2)
    // 回到 2201 则命中已有行。
    try await store.evaluate(endpoint: endpoint("127.0.0.1", port: 2201), hostKey: key)
    #expect(await prompt.askCount == 2)
}

@Test("权限：目录 0700、文件 0600；目标不可信就拒写而不是悄悄改")
func writesSetPermissionsAndRefuseUnsafeTargets() async throws {
    let scratch = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: scratch) }

    // (1) 新建路径上的权限位
    let storeURL = scratch.appendingPathComponent("fresh/nested/known_hosts")
    let prompt = StubPrompt([.accept])
    let store = HostKeyStore(config: HostKeyStoreConfig(storeURL: storeURL, readOnlyKnownHosts: [], writableKnownHosts: []),
                             prompt: prompt)
    let key = try hostKeyFor("ssh-ed25519")
    try await store.evaluate(endpoint: endpoint("perm.example.com"), hostKey: key)
    #expect(permissions(storeURL.path) == 0o600)
    #expect(permissions(storeURL.deletingLastPathComponent().path) == 0o700)

    // (2) 别人可写的 known_hosts：谁能改它，"密钥变了"的判定就归谁说了算
    let worldWritable = scratch.appendingPathComponent("loose/known_hosts")
    try FileManager.default.createDirectory(at: worldWritable.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: worldWritable)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: worldWritable.path)
    let looseStore = HostKeyStore(config: HostKeyStoreConfig(storeURL: worldWritable, readOnlyKnownHosts: [], writableKnownHosts: []),
                                  prompt: StubPrompt([.accept]))
    try await #expect(throws: RemoteError.localIO(.writeFailed)) {
        try await looseStore.evaluate(endpoint: endpoint("loose.example.com"), hostKey: key)
    }
    #expect(readFile(worldWritable).isEmpty)

    // (3) 符号链接目标：写下去等于让第三方文件顶包
    let link = scratch.appendingPathComponent("link/known_hosts")
    try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: worldWritable)
    let linkStore = HostKeyStore(config: HostKeyStoreConfig(storeURL: link, readOnlyKnownHosts: [], writableKnownHosts: []),
                                 prompt: StubPrompt([.accept]))
    try await #expect(throws: RemoteError.localIO(.writeFailed)) {
        try await linkStore.evaluate(endpoint: endpoint("link.example.com"), hostKey: key)
    }
}

@Test("并发：两条不同主机的连接各自落一行，不互相盖掉")
func concurrentAcceptsDoNotClobberEachOther() async throws {
    let scratch = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let storeURL = scratch.appendingPathComponent("store/known_hosts")
    let existing = "first.example.com ssh-ed25519 \(try hostKeyFor("ssh-ed25519", payload: [7]).blob.base64EncodedString())\n"
    try seed(existing, at: storeURL)

    let store = HostKeyStore(config: HostKeyStoreConfig(storeURL: storeURL, readOnlyKnownHosts: [], writableKnownHosts: []),
                             prompt: StubPrompt([.accept, .accept, .accept]))
    let keys = try (0..<3).map { try hostKeyFor("ssh-ed25519", payload: [UInt8($0)]) }
    try await withThrowingTaskGroup(of: Void.self) { group in
        for (index, key) in keys.enumerated() {
            group.addTask {
                try await store.evaluate(endpoint: endpoint("host\(index).example.com", port: 22), hostKey: key)
            }
        }
        try await group.waitForAll()
    }
    let lines = readFile(storeURL).split(separator: "\n").filter { !$0.isEmpty }
    // 3 条新行 + 1 条原有行。少了任何一条就是"用缓存里的旧内容原子替换"把别人的写入盖掉了。
    #expect(lines.count == 4)
    #expect(lines.contains { $0.hasPrefix("first.example.com ") })
    for index in 0..<3 {
        #expect(lines.contains { $0.hasPrefix("host\(index).example.com ") })
    }
}

@Test("幂等与写入同意：同一把密钥不重复写；勾了才动用户的文件")
func idempotentWritesAndExplicitKnownHostsConsent() async throws {
    let scratch = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let storeURL = scratch.appendingPathComponent("store/known_hosts")
    let userFile = scratch.appendingPathComponent("ssh/known_hosts")
    try FileManager.default.createDirectory(at: userFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: userFile)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: userFile.path)

    let key = try hostKeyFor("ssh-ed25519")
    let prompt = StubPrompt([.acceptAndWriteKnownHosts, .accept])
    let store = HostKeyStore(config: HostKeyStoreConfig(storeURL: storeURL, readOnlyKnownHosts: [userFile],
                                                        writableKnownHosts: [userFile]),
                             prompt: prompt)
    try await store.evaluate(endpoint: endpoint("consent.example.com"), hostKey: key)
    let line = "consent.example.com ssh-ed25519 \(key.blob.base64EncodedString())\n"
    #expect(readFile(storeURL) == line)
    #expect(readFile(userFile) == line)

    // 只读侧现在能看见自己刚写的那行；勾与不勾的差别只体现在"要不要动 userFile"。
    try await store.evaluate(endpoint: endpoint("consent.example.com"), hostKey: key)
    #expect(await prompt.askCount == 1)
    #expect(readFile(userFile) == line)

    // 只接受、不勾写入：自己的存储加一行，用户的文件不动。
    let other = try hostKeyFor("ssh-ed25519", payload: [9])
    try await store.evaluate(endpoint: endpoint("other.example.com"), hostKey: other)
    #expect(readFile(storeURL).split(separator: "\n").filter { !$0.isEmpty }.count == 2)
    #expect(readFile(userFile) == line)
}

@Test("哈希存储：勾了 hashStoredHostNames 之后写出的行只认那一台，且能自己读回")
func hashedStorageRoundTrip() async throws {
    let scratch = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let storeURL = scratch.appendingPathComponent("store/known_hosts")
    let prompt = StubPrompt([.accept])
    let store = HostKeyStore(config: HostKeyStoreConfig(storeURL: storeURL, readOnlyKnownHosts: [],
                                                        writableKnownHosts: [], hashStoredHostNames: true),
                             prompt: prompt)
    let key = try hostKeyFor("ssh-ed25519")
    try await store.evaluate(endpoint: endpoint("secret.example.com", port: 2222), hostKey: key)
    let written = readFile(storeURL)
    #expect(written.hasPrefix("|1|"))
    // 非 22 端口的哈希输入含方括号，与 ssh-keygen -H 实测一致（M1-03）。
    #expect(lookupHostKey(host: "secret.example.com", port: 2222,
                         key: KnownHostKey(keyType: key.wireType, blob: key.blob),
                         in: [KnownHostsFile.parse(written, source: "written")])
            == .trusted(source: "written", line: 1, keyType: "ssh-ed25519"))
    #expect(lookupHostKey(host: "secret.example.com", port: 22,
                          key: KnownHostKey(keyType: key.wireType, blob: key.blob),
                          in: [KnownHostsFile.parse(written, source: "written")]) == .unknown)

    // 同一台重连不再问；换主机名绝不命中。
    try await store.evaluate(endpoint: endpoint("secret.example.com", port: 2222), hostKey: key)
    #expect(await prompt.askCount == 1)
}

@Test("坏行不静默：解析失败要在诊断里看得见，且不影响正常行")
func parseFailuresSurviveAlongsideGoodRows() async throws {
    let scratch = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let key = try hostKeyFor("ssh-ed25519")
    let sshFile = scratch.appendingPathComponent("ssh/known_hosts")
    try FileManager.default.createDirectory(at: sshFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try """
        # comment
        oops ssh-ed25519
        good.example.com ssh-ed25519 \(key.blob.base64EncodedString())
        """.write(to: sshFile, atomically: true, encoding: .utf8)

    let store = HostKeyStore(config: HostKeyStoreConfig(storeURL: scratch.appendingPathComponent("store/known_hosts"),
                                                        readOnlyKnownHosts: [sshFile], writableKnownHosts: []),
                             prompt: StubPrompt([.accept]))
    try await store.evaluate(endpoint: endpoint("good.example.com"), hostKey: key)
    let files = try await store.knownHostsFiles()
    let file = try #require(files.first { $0.source == sshFile.path })
    #expect(file.failures.map(\.lineNumber) == [2])
    #expect(file.lines.count == 1)
}
