import Darwin
import FerryCore
import Foundation
import Testing

@testable import FerryBackendsSFTP

/// M1'-2 的验收：握手用**正式实现**打通五台，取消与超时落在 ADR-0001 的边界上，
/// 主机密钥判定发生在返回之前，协商值不许越过策略。
///
/// 两组跑法：
///
///     swift test --package-path Packages/Backends                        # 只用本地回环
///     FERRY_LIVE_SERVERS=1 swift test --package-path Packages/Backends   # 再加五台真机
///
/// 真机组默认跳过：CI 上没有这五台容器。回环组不依赖 docker，覆盖的是取消延迟、
/// 超时预算、错误分类这些与服务器无关的性质。
private let liveServersEnabled = ProcessInfo.processInfo.environment["FERRY_LIVE_SERVERS"] == "1"

private struct TestFailure: Error, CustomStringConvertible {
    let detail: String
    init(_ detail: String) { self.detail = detail }
    var description: String { detail }
}

// MARK: - 测试用信任判定

private struct AcceptAllTrust: HostKeyTrust {
    func evaluate(endpoint: Endpoint, hostKey: HostKey) async throws {}
}

/// 拒绝的同时记下"我确实被调到了"——否则这条测试在实现根本不做信任判定时也会通过。
private actor TrustLog {
    private(set) var entries: [String] = []
    func note(_ fingerprint: String) { entries.append(fingerprint) }
    var count: Int { entries.count }
}

private struct RefusingTrust: HostKeyTrust {
    let log: TrustLog

    func evaluate(endpoint: Endpoint, hostKey: HostKey) async throws {
        await log.note(hostKey.fingerprintSHA256)
        throw RemoteError.hostKeyMismatch(fingerprint: hostKey.fingerprintSHA256)
    }
}

// MARK: - 本地回环夹具

/// 只 accept、一个字节都不回、也故意不关的监听端口。
///
/// 回环上真服务器几十毫秒就握完手，量不到 poll 切片；把"服务器连 banner 都不发"
/// 在本地复现一次，才能测建阶段的取消与超时。
private func startStallListener() throws -> Int {
    let fd = try listeningSocket()
    let port = try portOf(fd)
    Thread.detachNewThread { while true { _ = accept(fd, nil, nil) } }
    return port
}

/// 起一个确定没人听的本地端口（拿到端口号后立刻关掉监听），用来测拒连分类。
private func startRefusedPort() throws -> Int {
    let fd = try listeningSocket()
    let port = try portOf(fd)
    close(fd)
    return port
}

private func listeningSocket() throws -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw TestFailure("socket errno=\(errno)") }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0 else { throw TestFailure("bind errno=\(errno)") }
    guard listen(fd, 8) == 0 else { throw TestFailure("listen errno=\(errno)") }
    return fd
}

private func portOf(_ fd: Int32) throws -> Int {
    var name = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let rc = withUnsafeMutablePointer(to: &name) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    guard rc == 0 else { throw TestFailure("getsockname errno=\(errno)") }
    return Int(UInt16(bigEndian: name.sin_port))
}

// MARK: - 公共构造

private func request(port: Int, policy: ConnectionPolicy = .standard,
                     authentication: AuthenticationMethod = .sshAgent) -> ConnectionRequest {
    ConnectionRequest(endpoint: Endpoint(host: "127.0.0.1", port: port, username: "tester"),
                      authentication: authentication,
                      policy: policy)
}

private func policy(handshakeTimeout: Duration, algorithms: AlgorithmPreferences = .libraryDefault) -> ConnectionPolicy {
    ConnectionPolicy(connectTimeout: .seconds(5), handshakeTimeout: handshakeTimeout,
                     authenticationTimeout: .seconds(30), algorithms: algorithms)
}

private func elapsed(_ start: DispatchTime, _ end: DispatchTime = DispatchTime.now()) -> Int {
    Int(end.uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000
}

/// 握手结果压成可断言的稳定 token；`CancellationError` 与 `RemoteError` 要分得开。
private func outcome(_ body: () async throws -> some Any) async -> String {
    do { _ = try await body(); return "ok" }
    catch is CancellationError { return "cancelled" }
    catch let error as RemoteError { return error.diagnosticCode }
    catch { return "other(\(error))" }
}

// MARK: - 回环组

@Test("建阶段的取消在一个 poll 切片内生效，且 session 判为 aborted")
func cancelDuringHandshake() async throws {
    let port = try startStallListener()
    let connection = SFTPConnection(request: request(port: port, policy: policy(handshakeTimeout: .seconds(30))),
                                    hostKeyTrust: AcceptAllTrust())

    // 先睡 300 ms，确保握手确实停在等 banner 的 poll 里，而不是一进来就撞上顶部检查
    let task = Task { await outcome { try await connection.handshake() } }
    try? await Task.sleep(nanoseconds: 300_000_000)
    let cancelAt = DispatchTime.now()
    connection.cancel()                       // nonisolated：UI 线程直接置位（D3）
    let result = await task.value
    let latency = elapsed(cancelAt)

    #expect(result == "cancelled")
    // ADR-0001 的出口标准是 200 ms，切片定在 50 ms。留到 120 ms 是"一个半切片 + 调度余量"，
    // 再宽就分不出实现是好是坏了。
    #expect(latency <= 120, "取消延迟 \(latency) ms 超出一个半切片")

    let measure = await connection.measure
    #expect(measure.pollTimeoutCount >= 1, "300 ms 里一次都没睡满切片，说明没进 poll 循环")
    #expect(measure.pollCount >= measure.pollTimeoutCount)
    // D7：一条 session 的全部 C 调用只落在自己那条串行执行器上
    #expect(measure.executorThreads.count == 1)
    let phase = await connection.phase
    #expect(phase == .aborted)
}

@Test("握手预算烧完抛 network/timeout，不会睡死到内核默认超时")
func handshakeTimeoutFires() async throws {
    let port = try startStallListener()
    let connection = SFTPConnection(request: request(port: port, policy: policy(handshakeTimeout: .milliseconds(300))),
                                    hostKeyTrust: AcceptAllTrust())

    let start = DispatchTime.now()
    let result = await outcome { try await connection.handshake() }
    let ms = elapsed(start)

    #expect(result == "network/timeout")
    #expect(ms >= 300 && ms < 900, "300 ms 预算实际用了 \(ms) ms")
    let phase = await connection.phase
    #expect(phase == .aborted)
}

@Test("端口拒连分类成 connectionRefused，失败即硬拆")
func refusedPort() async throws {
    let port = try startRefusedPort()
    let connection = SFTPConnection(request: request(port: port), hostKeyTrust: AcceptAllTrust())

    let result = await outcome { try await connection.handshake() }
    #expect(result == "network/connectionRefused")
    // D6：aborted 只能丢弃，连接池不许把它发回去
    let phase = await connection.phase
    #expect(phase == .aborted)
}

@Test("协商值越出策略时判协议违规")
func negotiatedOutsidePolicyIsRejected() throws {
    let inPolicy = NegotiatedAlgorithms(keyExchange: "curve25519-sha256", hostKey: "ssh-ed25519",
                                        encryptionClientToServer: "aes256-ctr",
                                        encryptionServerToClient: "aes256-ctr",
                                        macClientToServer: "hmac-sha2-256",
                                        macServerToClient: "hmac-sha2-256")
    let preferences = AlgorithmPreferences(keyExchange: ["curve25519-sha256"],
                                           hostKey: ["ssh-ed25519"],
                                           encryption: ["aes256-ctr"],
                                           mac: ["hmac-sha2-256"])
    #expect(throws: Never.self) { try verifyNegotiatedWithinPolicy(inPolicy, preferences) }
    // 空策略 = 库默认：没有可比对的集合，不报错也不做任何校验
    #expect(throws: Never.self) { try verifyNegotiatedWithinPolicy(inPolicy, .libraryDefault) }

    // 六个维度逐个都要能被抓住，方向是"策略被放宽"，不是"策略写了没用"
    let widened = [
        withKEX(inPolicy, "diffie-hellman-group14-sha1"),   // kex 退回带 SHA-1 的老路
        withHostKey(inPolicy, "ssh-dss"),                   // 主机密钥换成已废弃类型
        withCipher(inPolicy, "aes256-cbc"),                 // c→s 加密换成 CBC
        withCipherSC(inPolicy, "3des-cbc"),                 // s→c 单独被放宽
        withMAC(inPolicy, "hmac-sha1"),                     // mac 换成 SHA-1
    ]
    for bad in widened {
        var caught = false
        do {
            try verifyNegotiatedWithinPolicy(bad, preferences)
        } catch let error as RemoteError {
            caught = error.diagnosticCode == "protocolViolation"
        } catch {}
        #expect(caught, "这条策略外的协商值没被抓住：\(bad)")
    }
}

private func withKEX(_ base: NegotiatedAlgorithms, _ value: String) -> NegotiatedAlgorithms {
    NegotiatedAlgorithms(keyExchange: value, hostKey: base.hostKey,
                         encryptionClientToServer: base.encryptionClientToServer,
                         encryptionServerToClient: base.encryptionServerToClient,
                         macClientToServer: base.macClientToServer, macServerToClient: base.macServerToClient)
}

private func withHostKey(_ base: NegotiatedAlgorithms, _ value: String) -> NegotiatedAlgorithms {
    NegotiatedAlgorithms(keyExchange: base.keyExchange, hostKey: value,
                         encryptionClientToServer: base.encryptionClientToServer,
                         encryptionServerToClient: base.encryptionServerToClient,
                         macClientToServer: base.macClientToServer, macServerToClient: base.macServerToClient)
}

private func withCipher(_ base: NegotiatedAlgorithms, _ value: String) -> NegotiatedAlgorithms {
    NegotiatedAlgorithms(keyExchange: base.keyExchange, hostKey: base.hostKey,
                         encryptionClientToServer: value,
                         encryptionServerToClient: base.encryptionServerToClient,
                         macClientToServer: base.macClientToServer, macServerToClient: base.macServerToClient)
}

private func withCipherSC(_ base: NegotiatedAlgorithms, _ value: String) -> NegotiatedAlgorithms {
    NegotiatedAlgorithms(keyExchange: base.keyExchange, hostKey: base.hostKey,
                         encryptionClientToServer: base.encryptionClientToServer,
                         encryptionServerToClient: value,
                         macClientToServer: base.macClientToServer, macServerToClient: base.macServerToClient)
}

private func withMAC(_ base: NegotiatedAlgorithms, _ value: String) -> NegotiatedAlgorithms {
    NegotiatedAlgorithms(keyExchange: base.keyExchange, hostKey: base.hostKey,
                         encryptionClientToServer: base.encryptionClientToServer,
                         encryptionServerToClient: base.encryptionServerToClient,
                         macClientToServer: base.macClientToServer, macServerToClient: value)
}

// MARK: - 真机组

@Test("五台服务器都能握手，协商事实自洽且关闭语义正确", .enabled(if: liveServersEnabled))
func handshakeAgainstFiveServers() async throws {
    for port in [2201, 2202, 2203, 2204, 2205] {
        let backend = SFTPBackend(hostKeyTrust: AcceptAllTrust())
        let connection = backend.makeConnection(request(port: port))
        let session = try await connection.handshake()

        #expect(session.serverIdentification.hasPrefix("SSH-2.0-"),
                "\(port) banner: \(session.serverIdentification)")
        let dimensions = [session.algorithms.keyExchange, session.algorithms.hostKey,
                          session.algorithms.encryptionClientToServer, session.algorithms.encryptionServerToClient,
                          session.algorithms.macClientToServer, session.algorithms.macServerToClient]
        for value in dimensions {
            #expect(!value.isEmpty, "\(port) 有维度谈出空值：\(dimensions)")
        }
        // 指纹格式与 ssh-keygen -lf 一致（docs/spike/M1-02 §3 逐台核对）
        #expect(session.hostKey.fingerprintSHA256.hasPrefix("SHA256:"))
        #expect(!session.hostKey.fingerprintSHA256.hasSuffix("="))
        #expect(session.hostKey.blob.count > 0)

        let endpoint = connection.endpoint
        #expect(endpoint == Endpoint(host: "127.0.0.1", port: port, username: "tester"))
        let phase = await connection.phase
        #expect(phase == .ready)

        // 幂等重入：返回同一份事实，不再开一条 TCP
        let again = try await connection.handshake()
        #expect(again == session)

        await connection.close()
        let closed = await connection.phase
        #expect(closed == .closed)
        let afterClose = await outcome { try await connection.handshake() }
        #expect(afterClose == "network/connectionLost", "关闭后的 session 被复用去重握手了")
    }
}

@Test("真机握手的 C 调用全在同一条线程（D7）", .enabled(if: liveServersEnabled))
func handshakeConfinedToOneThread() async throws {
    let connection = SFTPConnection(request: request(port: 2202), hostKeyTrust: AcceptAllTrust())
    _ = try await connection.handshake()
    let measure = await connection.measure
    #expect(measure.executorThreads.count == 1,
            "跨了 \(measure.executorThreads.count) 条线程：\(measure.executorThreads)")
    await connection.close()
}

@Test("主机密钥不被信任时握手拒绝，且信任判定确实跑了", .enabled(if: liveServersEnabled))
func hostKeyRejectionRefusesConnection() async throws {
    let log = TrustLog()
    // 带真密码：一旦信任判定被挪到认证之后，这里会变成握手成功，测试立刻红
    let connection = SFTPConnection(request: request(port: 2202, authentication: .password("testpass")),
                                    hostKeyTrust: RefusingTrust(log: log))

    let result = await outcome { try await connection.handshake() }
    #expect(result == "hostKeyMismatch")
    let evaluated = await log.count
    #expect(evaluated == 1, "信任判定一次都没被调用")
    let phase = await connection.phase
    #expect(phase == .aborted)
    await connection.close()
}

@Test("策略窄到服务器不接受时握手失败，而不是悄悄放宽", .enabled(if: liveServersEnabled))
func modernOnlyPolicyRefusedByLegacyServers() async throws {
    let modern = AlgorithmPreferences(
        keyExchange: ["curve25519-sha256", "curve25519-sha256@libssh.org"],
        hostKey: ["ssh-ed25519", "rsa-sha2-512", "rsa-sha2-256"],
        encryption: ["aes256-ctr", "aes128-ctr"],
        mac: ["hmac-sha2-256", "hmac-sha2-512"])

    // 2203/2204 线路上只发 dh-group14-sha1 + ssh-rsa + CBC + hmac-sha1 一条路，
    // 与上面这份没有交集 → libssh2 回 KEX_FAILURE(-5)
    for port in [2203, 2204] {
        let connection = SFTPConnection(request: request(port: port, policy: policy(handshakeTimeout: .seconds(30),
                                                                                    algorithms: modern)),
                                        hostKeyTrust: AcceptAllTrust())
        let result = await outcome { try await connection.handshake() }
        #expect(result == "protocolViolation", "\(port) 本该拒绝这份策略，实际：\(result)")
        let phase = await connection.phase
        #expect(phase == .aborted)
    }

    // 对照组：2202 接受同一份现代策略，且协商值确实落在集合内
    let modernConnection = SFTPConnection(request: request(port: 2202, policy: policy(handshakeTimeout: .seconds(30),
                                                                                      algorithms: modern)),
                                          hostKeyTrust: AcceptAllTrust())
    let session = try await modernConnection.handshake()
    #expect(throws: Never.self) { try verifyNegotiatedWithinPolicy(session.algorithms, modern) }
    await modernConnection.close()
}

@Test("libssh2 对不认识的算法名是静默剔除，不是快速失败（钉住事实）", .enabled(if: liveServersEnabled))
func unknownAlgorithmNameStripsSilently() async throws {
    // 1.11.1 的 `libssh2_session_method_pref`（kex.c 的 strip 循环）把不认识的名字
    // 直接从偏好串里删掉，只有整串空了才返回 -33。所以"策略写了个没编进去的算法"
    // 不会报错，只会让那条偏好消失；空策略集下 advertised 只剩 ext-info 标记，
    // 服务器拒绝 → KEX_FAILURE(-5)。
    // 升级 libssh2 后若改成快速失败，这条会先变红，我们就得同步改掉对 strip 的推断。
    let bogusKex = AlgorithmPreferences(keyExchange: ["ferry-bogus-kex@example.com"],
                                       hostKey: [], encryption: [], mac: [])
    let first = SFTPConnection(request: request(port: 2202, policy: policy(handshakeTimeout: .seconds(30),
                                                                          algorithms: bogusKex)),
                               hostKeyTrust: AcceptAllTrust())
    let firstCode = await outcome { try await first.handshake() }
    #expect(firstCode == "protocolViolation")
    let firstPhase = await first.phase
    #expect(firstPhase == .aborted)

    // 反过来，某个维度全是不认识的名字时串会被剔空，libssh2 才给 -33。
    // 顺带钉住一个诊断事实：-5（对面不接受）与 -33（我们这侧不支持）在
    // `diagnosticCode` 上同为 protocolViolation，只能靠 rc 区分——M1'-8 出矩阵时要按 rc 分列。
    let strippedMAC = AlgorithmPreferences(keyExchange: [], hostKey: [],
                                          encryption: [], mac: ["ferry-bogus-mac@example.com"])
    let second = SFTPConnection(request: request(port: 2202, policy: policy(handshakeTimeout: .seconds(30),
                                                                           algorithms: strippedMAC)),
                                hostKeyTrust: AcceptAllTrust())
    var detail = ""
    do {
        _ = try await second.handshake()
        Issue.record("本该在算法被剔空时失败")
    } catch let error as RemoteError {
        if case .protocolViolation(let text) = error { detail = text }
        else { detail = error.diagnosticCode }
    }
    #expect(detail.contains("-33"), "剔空后的返回码不再是 -33：\(detail)")
    let secondPhase = await second.phase
    #expect(secondPhase == .aborted)
}
