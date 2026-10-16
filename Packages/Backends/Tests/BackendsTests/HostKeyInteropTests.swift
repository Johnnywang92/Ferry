import FerryCore
import Foundation
import Testing

@testable import FerryBackendsSFTP

/// M1'-3 的对外口径只有一句：**Ferry 查表用的键，必须和 OpenSSH 存取用的键是同一个**。
/// 这句话在 Ferry 自己这侧没有自证的余地——`wireType`、指纹格式、`[host]:port` 形状、
/// 落盘文本，全部要拿真 OpenSSH 当尺子量。这一组就是那把尺子。
///
///     FERRY_LIVE_SERVERS=1 swift test --package-path Packages/Backends
///
/// 只覆盖 2201/2202/2205：本机 OpenSSH_10.3p1 只肯跟这三台握手（2203/2204 连
/// `ssh-keyscan` 都拿不到 key，M1-02 §3.4 记过），对照那两台只能进容器做，
/// 手工结果留在 docs/spike/M1-03。
///
/// 一切外部 `ssh` 都带 `-F /dev/null` 与临时 `HOME`，`UserKnownHostsFile` 一律指到
/// 本测试自己的临时文件——用户的 `~/.ssh` 一个字节都不碰。
private let liveServersEnabled = ProcessInfo.processInfo.environment["FERRY_LIVE_SERVERS"] == "1"
private let openSSHAvailable = liveServersEnabled && FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh")

private struct ToolFailure: Error, CustomStringConvertible {
    let detail: String
    init(_ detail: String) { self.detail = detail }
    var description: String { detail }
}

// MARK: - 外部工具

private struct ToolResult {
    let status: Int32
    let stdout: String
    let stderr: String
    var output: String { stdout + stderr }
}

/// `Process.waitUntilExit()` 会阻塞当前线程，放到 detached 任务里，别占着测试执行器。
private func runProcess(_ path: String, _ arguments: [String], environment: [String: String]?) async throws -> ToolResult {
    try await Task.detached(priority: .userInitiated) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        // 两个管道都得先读干：输出塞满 64 KB 缓冲区时父子双方会互相等死。
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ToolResult(status: process.terminationStatus,
                          stdout: String(decoding: stdoutData, as: UTF8.self),
                          stderr: String(decoding: stderrData, as: UTF8.self))
    }.value
}

private func runTool(_ path: String, _ arguments: [String]) async throws -> ToolResult {
    try await runProcess(path, arguments, environment: nil)
}

/// ssh 的运行环境：临时 HOME + 剥掉 SSH_AUTH_SOCK（不碰用户那个常驻 agent）。
private func sshEnvironment(home: URL) -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    environment["HOME"] = home.path
    environment.removeValue(forKey: "SSH_AUTH_SOCK")
    return environment
}

/// 从 `ssh-keygen -l` / `-F -l` 的输出里取那个 `SHA256:` 段。
/// 按空白切而不是只按空格：`-F -l` 的指纹正好在行尾，按空格切会把换行留在 token 里，
/// 比出来就是"两个一模一样的字符串不相等"。
private func fingerprintFromKeygen(_ text: String) -> String? {
    text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n" })
        .first { $0.hasPrefix("SHA256:") }
        .map(String.init)
}

private func scratchHome() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ferry-ssh-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// 临时 known_hosts 文件：先有父目录，权限照真的 0600 给——`destinationIsSafe`
/// 见到组内/其他可读会拒绝写入，那是被测行为不是测试起点。
private func seedRow(_ text: String, at url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

private func readFile(_ url: URL) -> String {
    String(decoding: (try? Data(contentsOf: url)) ?? Data(), as: UTF8.self)
}

/// 只走到"主机密钥被接受并写进文件"为止：`PreferredAuthentications=none` 让 ssh 在认证
/// 阶段就失败，而 known_hosts 是在认证之前写的——正好绕开凭据，也绝不会等交互输入。
private func sshAcceptNew(port: Int, knownHosts: URL, home: URL, hostKeyAlgorithms: String?) async throws -> ToolResult {
    var arguments = ["-F", "/dev/null", "-p", "\(port)",
                     "-o", "UserKnownHostsFile=\(knownHosts.path)",
                     "-o", "StrictHostKeyChecking=accept-new",
                     "-o", "BatchMode=yes",
                     "-o", "PreferredAuthentications=none",
                     "-o", "IdentityAgent=none",
                     "-o", "ConnectTimeout=10"]
    if let hostKeyAlgorithms { arguments.append(contentsOf: ["-o", "HostKeyAlgorithms=\(hostKeyAlgorithms)"]) }
    arguments.append("tester@127.0.0.1")
    return try await runProcess("/usr/bin/ssh", arguments, environment: sshEnvironment(home: home))
}

// MARK: - 信任判定替身

private actor PromptLog {
    private(set) var questions: [HostKeyQuestion] = []
    func note(_ question: HostKeyQuestion) { questions.append(question) }
    var count: Int { questions.count }
    var first: HostKeyQuestion? { questions.first }
}

private struct LoggingPrompt: HostKeyTrustPrompt {
    let log: PromptLog
    let decision: HostKeyDecision

    func ask(_ question: HostKeyQuestion) async -> HostKeyDecision {
        await log.note(question)
        return decision
    }
}

/// 只用来取协商事实：不进任何存储，判定层由本文件的其它测试负责。
private struct CaptureTrust: HostKeyTrust {
    func evaluate(endpoint: Endpoint, hostKey: HostKey) async throws {}
}

private func request(port: Int, algorithms: AlgorithmPreferences) -> ConnectionRequest {
    ConnectionRequest(endpoint: Endpoint(host: "127.0.0.1", port: port, username: "tester"),
                      authentication: .password("this-test-never-authenticates"),
                      policy: ConnectionPolicy(connectTimeout: .seconds(10),
                                               handshakeTimeout: .seconds(30),
                                               authenticationTimeout: .seconds(30),
                                               algorithms: algorithms))
}

private func storeConfig(store: URL, readOnly: [URL] = [], writable: [URL] = []) -> HostKeyStoreConfig {
    HostKeyStoreConfig(storeURL: store, readOnlyKnownHosts: readOnly, writableKnownHosts: writable)
}

@discardableResult private func handshake(port: Int, algorithms: AlgorithmPreferences = .libraryDefault,
                                          trust: any HostKeyTrust) async throws -> NegotiatedSession {
    let connection = SFTPConnection(request: request(port: port, algorithms: algorithms), hostKeyTrust: trust)
    do {
        let session = try await connection.handshake()
        await connection.close()
        return session
    } catch {
        await connection.close()
        throw error
    }
}

// MARK: - 对照

@Test("Ferry 的 wireType 与指纹 = OpenSSH 从同一台服务器算出来的那两个值", .enabled(if: openSSHAvailable))
func wireTypeAndFingerprintMatchOpenSSH() async throws {
    // 第二格是本轮要钉死的坑：签名算法谈成 rsa-sha2-512，blob 头部与表里存的仍是 ssh-rsa。
    let cases: [(port: Int, hostKey: [String])] = [
        (2201, []),
        (2201, ["rsa-sha2-512"]),
        (2202, []),
        (2205, []),
    ]
    for testCase in cases {
        let session = try await handshake(port: testCase.port,
                                          algorithms: AlgorithmPreferences(hostKey: testCase.hostKey),
                                          trust: CaptureTrust())
        let hostKey = session.hostKey
        let signature = session.algorithms.hostKey

        let scan = try await runTool("/usr/bin/ssh-keyscan", ["-T", "5", "-p", "\(testCase.port)", "127.0.0.1"])
        let fields = try #require(scan.stdout.split(separator: "\n").first { line in
            let parts = line.split(separator: " ")
            return parts.count >= 3 && parts[1] == Substring(hostKey.wireType)
        }, "keyscan 里没有 keytype=\(hostKey.wireType) 的行（本次签名算法 \(signature)）：\(scan.stdout)")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ferry-keyscan-\(UUID().uuidString)")
        try "\(fields)\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let listing = try await runTool("/usr/bin/ssh-keygen", ["-l", "-f", file.path])
        let openSSHFP = try #require(fingerprintFromKeygen(listing.stdout), "ssh-keygen 没给指纹：\(listing.output)")

        #expect(hostKey.fingerprintSHA256 == openSSHFP,
                "\(testCase.port)/\(signature)：Ferry 的 \(hostKey.fingerprintSHA256) ≠ OpenSSH 的 \(openSSHFP)")
        // keyscan 那行的 keytype 字段就是 OpenSSH 往 known_hosts 第三个字段写的名字。
        #expect(hostKey.wireType == fields.split(separator: " ")[1])
        if signature.hasPrefix("rsa-sha2-") {
            #expect(hostKey.wireType == "ssh-rsa",
                    "签名 \(signature) 时 blob 头部必须写 ssh-rsa，实际 \(hostKey.wireType)")
        }
    }
}

@Test("ssh 亲手写的行，keytype 与指纹就是 Ferry 的查表键", .enabled(if: openSSHAvailable))
func sshStoredRowUsesFerryLookupKey() async throws {
    for port in [2201, 2202] {
        let session = try await handshake(port: port, trust: CaptureTrust())
        let home = try scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let knownHosts = home.appendingPathComponent(".ssh/known_hosts")
        try FileManager.default.createDirectory(at: knownHosts.deletingLastPathComponent(), withIntermediateDirectories: true)
        // 让两边谈同一种签名算法，否则比的是两把不同的密钥（OpenSSH 会按自己的偏好挑类型）。
        _ = try await sshAcceptNew(port: port, knownHosts: knownHosts, home: home,
                                   hostKeyAlgorithms: session.algorithms.hostKey)
        let row = try #require(readFile(knownHosts).split(separator: "\n").first, "ssh 没往临时文件里写行")
        let fields = row.split(separator: " ")
        #expect(fields[0] == "[127.0.0.1]:\(port)", "非 22 端口 ssh 该写方括号形状，实际 \(fields[0])")
        #expect(fields[1] == Substring(session.hostKey.wireType),
                "ssh 存的是 \(fields[1])，Ferry 查表用 \(session.hostKey.wireType)")
        let listing = try await runTool("/usr/bin/ssh-keygen", ["-l", "-f", knownHosts.path])
        #expect(try #require(fingerprintFromKeygen(listing.stdout)) == session.hostKey.fingerprintSHA256)

        // 反过来：把 ssh 写的这行交给 Ferry 当只读兼容名单，必须直接可信、且不动那个文件。
        let log = PromptLog()
        let store = HostKeyStore(config: storeConfig(store: home.appendingPathComponent("ferry/known_hosts"),
                                                    readOnly: [knownHosts]),
                                 prompt: LoggingPrompt(log: log, decision: .decline))
        let before = readFile(knownHosts)
        do {
            _ = try await handshake(port: port,
                                    algorithms: AlgorithmPreferences(hostKey: [session.algorithms.hostKey]),
                                    trust: store)
        } catch {
            Issue.record("ssh 写的行没让 Ferry 认下来：\(error)（弹窗 \(await log.count) 次）")
        }
        #expect(await log.count == 0)
        #expect(readFile(knownHosts) == before, "只读兼容名单里的文件被改了")
    }
}

@Test("Ferry 写的行：ssh-keygen 查得到，真 ssh 在 StrictHostKeyChecking=yes 下也认", .enabled(if: openSSHAvailable))
func openSSHTrustsFerryWrittenRow() async throws {
    let home = try scratchHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let ferryStore = home.appendingPathComponent("ferry/known_hosts")
    let log = PromptLog()
    let store = HostKeyStore(config: storeConfig(store: ferryStore),
                             prompt: LoggingPrompt(log: log, decision: .accept))
    // 固定成 ssh-ed25519：本机 ssh 默认也挑这一种，两边才比得上同一把密钥。
    let session = try await handshake(port: 2202, algorithms: AlgorithmPreferences(hostKey: ["ssh-ed25519"]),
                                      trust: store)
    #expect(await log.count == 1, "首次连接该问一次")
    let written = readFile(ferryStore)
    #expect(written.split(separator: " ").first == "[127.0.0.1]:2202", "落盘形状不对：\(written)")

    let found = try await runTool("/usr/bin/ssh-keygen", ["-F", "[127.0.0.1]:2202", "-l", "-f", ferryStore.path])
    #expect(found.status == 0, "ssh-keygen -F 在我们写的文件里找不到这台主机：\(found.output)")
    #expect(try #require(fingerprintFromKeygen(found.stdout)) == session.hostKey.fingerprintSHA256,
            "同一把密钥，OpenSSH 报的指纹与 Ferry 的不同：\(found.stdout)")

    // 换个进程重新读同一个文件（没有缓存可依赖）：第二次连接不该再问。
    let secondLog = PromptLog()
    let reopened = HostKeyStore(config: storeConfig(store: ferryStore),
                               prompt: LoggingPrompt(log: secondLog, decision: .decline))
    _ = try await handshake(port: 2202, algorithms: AlgorithmPreferences(hostKey: ["ssh-ed25519"]), trust: reopened)
    #expect(await secondLog.count == 0)

    // 最强的一条：`StrictHostKeyChecking=yes` 的真 ssh 拿 Ferry 写的文件当唯一信任来源，
    // 必须一路走到认证，且不打任何主机密钥警告。
    let strict = try await runProcess("/usr/bin/ssh",
                                      ["-F", "/dev/null", "-p", "2202",
                                       "-o", "UserKnownHostsFile=\(ferryStore.path)",
                                       "-o", "StrictHostKeyChecking=yes",
                                       "-o", "BatchMode=yes",
                                       "-o", "PreferredAuthentications=none",
                                       "-o", "IdentityAgent=none",
                                       "-o", "ConnectTimeout=10",
                                       "tester@127.0.0.1"],
                                      environment: sshEnvironment(home: home))
    #expect(!strict.output.contains("Permanently added"), "Ferry 写的行没被 ssh 当成已有记录")
    #expect(!strict.output.contains("WARNING"), "ssh 对 Ferry 写的行报警：\(strict.output)")
    #expect(!strict.output.contains("Host key verification failed"),
            "ssh 因为主机密钥拒了 Ferry 写的行：\(strict.output)")
    #expect(strict.output.localizedCaseInsensitiveContains("permission denied"),
            "ssh 没走到认证阶段，主机密钥这一步不算过了：\(strict.output)")
}

@Test("换算法不是密钥变更，换密钥才是——两条都在真服务器上过", .enabled(if: openSSHAvailable))
func otherAlgorithmAndKeyChangeDifferOnLiveServer() async throws {
    // 先拿两把真的：2201 自己的 ed25519，和 2202 的 ed25519（用来冒充 2201）。
    let twoTwelveOne = try await handshake(port: 2201, algorithms: AlgorithmPreferences(hostKey: ["ssh-ed25519"]),
                                           trust: CaptureTrust())
    let twoTwelveTwo = try await handshake(port: 2202, algorithms: AlgorithmPreferences(hostKey: ["ssh-ed25519"]),
                                           trust: CaptureTrust())
    #expect(twoTwelveOne.hostKey.wireType == "ssh-ed25519")
    #expect(twoTwelveOne.hostKey.fingerprintSHA256 != twoTwelveTwo.hostKey.fingerprintSHA256)

    let home = try scratchHome()
    defer { try? FileManager.default.removeItem(at: home) }

    // (1) 表里有 2201 的 ed25519 行，但本次谈成 rsa-sha2-512 → 该问，原因写"只有别的算法"，
    //     绝不能报"密钥已变"：用户看到后者的第一反应是拔网线，而这只是算法换了一下。
    let edRow = home.appendingPathComponent("ferry/ed25519-known_hosts")
    try seedRow("[127.0.0.1]:2201 ssh-ed25519 \(twoTwelveOne.hostKey.blob.base64EncodedString())\n", at: edRow)
    let askLog = PromptLog()
    let askStore = HostKeyStore(config: storeConfig(store: home.appendingPathComponent("ferry/store"), readOnly: [edRow]),
                                prompt: LoggingPrompt(log: askLog, decision: .decline))
    await #expect(throws: CancellationError.self) {
        try await handshake(port: 2201, algorithms: AlgorithmPreferences(hostKey: ["rsa-sha2-512"]), trust: askStore)
    }
    #expect(await askLog.count == 1)
    let question = try #require(await askLog.first)
    #expect(question.reason == .hostKnownWithOtherAlgorithms(knownTypes: ["ssh-ed25519"], source: edRow.path))
    #expect(question.hostKey.algorithm == "rsa-sha2-512")
    #expect(question.hostKey.wireType == "ssh-rsa", "弹窗要按 blob 自己的类型说话，否则用户去表里找不到那一行")

    // (2) 表里同一主机同一类型、密钥却是 2202 那把 → 硬阻断：不询问，文件一字不改。
    let impostorRow = home.appendingPathComponent("ferry/impostor-known_hosts")
    let text = "[127.0.0.1]:2201 ssh-ed25519 \(twoTwelveTwo.hostKey.blob.base64EncodedString())\n"
    try seedRow(text, at: impostorRow)
    let blockLog = PromptLog()
    let blockStore = HostKeyStore(config: storeConfig(store: home.appendingPathComponent("ferry/store2"),
                                                     readOnly: [impostorRow], writable: [impostorRow]),
                                  prompt: LoggingPrompt(log: blockLog, decision: .acceptAndWriteKnownHosts))
    let detail = try await #require(throws: RemoteError.self) {
        try await handshake(port: 2201, algorithms: AlgorithmPreferences(hostKey: ["ssh-ed25519"]), trust: blockStore)
    }
    guard case .hostKeyMismatch(let fingerprint) = detail else {
        Issue.record("该报 hostKeyMismatch，实际 \(detail)")
        return
    }
    #expect(fingerprint == twoTwelveOne.hostKey.fingerprintSHA256, "抛的指纹该是线路上的那把，不是表里的旧值")
    #expect(await blockLog.count == 0, "密钥变更不该给用户任何跳过机会")
    #expect(readFile(impostorRow) == text, "硬阻断不许动任何文件")
}

@Test("策略里写主机证书算法：谈不拢就干净失败，绝不会把证书递到判定层", .enabled(if: openSSHAvailable))
func certificateAlgorithmInPolicyNeverYieldsTrustedSession() async throws {
    // libssh2 1.11.1 的 hostkey_methods[]（hostkey.c:1346）里确实有 `*-cert-v01@openssh.com`
    // 这些名字，但它们的 `init` 与 `sig_verify` 都是 NULL：`method_pref` 认这个名字，
    // 所以它不像 M1-02 §6.2 那些不认识的名称被静默剔掉后回 -33，而是走到 KEX 里才失败。
    // 实测两种落点：普通服务器（没有证书可谈）给 -5 KEX_FAILURE；
    // 呈上证书的服务器（docs/spike/M1-03 §5 的 2299）给 -8 KEY_EXCHANGE_FAILURE（kex.c:4161）。
    // 两边要的不变量只有一个：**判定层一次都不该被调到**——证书进不了信任表，
    // 而一旦哪天 libssh2 改成能把证书交出来，这条会因为它开始弹窗而变红。
    for port in [2201, 2202] {
        let home = try scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let log = PromptLog()
        let store = HostKeyStore(config: storeConfig(store: home.appendingPathComponent("ferry/known_hosts")),
                                 prompt: LoggingPrompt(log: log, decision: .accept))
        var code = "ok"
        do {
            _ = try await handshake(port: port,
                                    algorithms: AlgorithmPreferences(hostKey: ["ssh-ed25519-cert-v01@openssh.com"]),
                                    trust: store)
        } catch let error as RemoteError {
            code = error.diagnosticCode
        }
        #expect(code == "protocolViolation", "\(port)：证书算法本该谈不成，实际 \(code)")
        #expect(await log.count == 0, "\(port)：证书走到了信任判定")
        #expect(readFile(home.appendingPathComponent("ferry/known_hosts")).isEmpty)
    }
}
