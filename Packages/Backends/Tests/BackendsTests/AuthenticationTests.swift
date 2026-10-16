import Darwin
import FerryCore
import Foundation
import Testing

@testable import FerryBackendsSFTP

/// M1'-4 的验收：四种认证方式都在真服务器上走过，错误分类只说事实撑得住的那句话，
/// 而 keyboard-interactive 那条异步缝隙没有破坏 ADR-0001 的取消与单线程纪律。
///
///     swift test --package-path Packages/Backends                        # 只用本地回环
///     FERRY_LIVE_SERVERS=1 swift test --package-path Packages/Backends   # 再加五台真机
///     FERRY_LIVE_SERVERS=1 Spike/Scripts/ssh-agent-test.sh -- \
///         swift test --package-path Packages/Backends                    # 再加 agent 那两条
///
/// agent 那两条必须跑在临时 agent 里：本机的 `SSH_AUTH_SOCK` 指向登录会话那个 agent，
/// 里面挂的是真实工作密钥，"agent 认证成功"这条结论会被它的密钥列表左右（ADR-0000 §9 N4）。
/// 没设 `SSH_AUTH_SOCK` 时它们自己跳过，不会假通过；另有一条专门测"没有 agent 时不许段错误"。
///
/// 私钥语料沿用 `/tmp/ferry-keys`（`Spike/Scripts/keys.sh` 生成，公钥装在 2202）。
/// 用 `FERRY_KEY_DIR` 换目录。
private let liveServersEnabled = ProcessInfo.processInfo.environment["FERRY_LIVE_SERVERS"] == "1"
private let agentAvailable = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] != nil
private let keyDirectory = ProcessInfo.processInfo.environment["FERRY_KEY_DIR"] ?? "/tmp/ferry-keys"

private let goodPassword = "testpass"
private let keyPassphrase = "secret123"

private struct TestFailure: Error, CustomStringConvertible {
    let detail: String
    init(_ detail: String) { self.detail = detail }
    var description: String { detail }
}

// MARK: - 夹具

private struct AcceptAllTrust: HostKeyTrust {
    func evaluate(endpoint: Endpoint, hostKey: HostKey) async throws {}
}

/// 只 listen、不 accept、拿到端口就关掉——connect 必然被拒。
private func startRefusedPort() throws -> Int {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw TestFailure("socket errno=\(errno)") }
    defer { close(fd) }
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
    guard listen(fd, 1) == 0 else { throw TestFailure("listen errno=\(errno)") }
    var name = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let rc = withUnsafeMutablePointer(to: &name) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    guard rc == 0 else { throw TestFailure("getsockname errno=\(errno)") }
    return Int(UInt16(bigEndian: name.sin_port))
}

private func request(port: Int, authentication: AuthenticationMethod) -> ConnectionRequest {
    ConnectionRequest(endpoint: Endpoint(host: "127.0.0.1", port: port, username: "tester"),
                      authentication: authentication, policy: .standard)
}

private func handshakeThenAuthenticate(port: Int, authentication: AuthenticationMethod,
                                       interactive: (any KeyboardInteractiveResponder)? = nil) async throws
    -> (SFTPConnection, AuthenticatedSession)
{
    let connection = SFTPConnection(request: request(port: port, authentication: authentication),
                                    hostKeyTrust: AcceptAllTrust())
    _ = try await connection.handshake()
    let session = try await connection.authenticate(interactive: interactive)
    return (connection, session)
}

/// 结果压成可断言的稳定 token。`CancellationError` 必须和 `RemoteError` 分得开：
/// "用户关掉了对话框"与"口令错"是完全不同的两件事，混成一个字符串这组测试就没意义了。
private func outcome(_ body: () async throws -> some Any) async -> String {
    do { _ = try await body(); return "ok" }
    catch is CancellationError { return "cancelled" }
    catch let error as RemoteError { return error.diagnosticCode }
    catch { return "other(\(error))" }
}

private func elapsed(_ start: DispatchTime) -> Int {
    Int(DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000
}

private func keyData(_ name: String) throws -> Data {
    let path = "\(keyDirectory)/\(name)"
    guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else {
        throw TestFailure("缺私钥语料：\(path)（先跑 Spike/Scripts/keys.sh）")
    }
    return data
}

private func material(_ name: String, passphrase: String?) throws -> PrivateKeyMaterial {
    PrivateKeyMaterial(keyData: try keyData(name), passphrase: passphrase)
}

// MARK: - 应答者替身

private typealias Answers = @Sendable (KeyboardInteractiveRequest) -> [String]?

private actor PromptLog {
    private(set) var requests: [KeyboardInteractiveRequest] = []
    func note(_ request: KeyboardInteractiveRequest) { requests.append(request) }
    var count: Int { requests.count }
    var first: KeyboardInteractiveRequest? { requests.first }
}

private struct RecordingResponder: KeyboardInteractiveResponder {
    let log: PromptLog
    let answers: Answers

    init(log: PromptLog, answers: @escaping Answers) {
        self.log = log
        self.answers = answers
    }

    func respond(to request: KeyboardInteractiveRequest) async -> [String]? {
        await log.note(request)
        return answers(request)
    }
}

/// 每条提示都拿同一个串去答。
private func always(_ text: String) -> Answers {
    { request in Array(repeating: text, count: request.prompts.count) }
}

// MARK: - 回环组：认证的状态机闸门

@Test("没握手就认证是调用方的错，抛协议违规且连接原地不动")
func authenticateRequiresHandshake() async throws {
    let connection = SFTPConnection(request: request(port: 2202, authentication: .password(goodPassword)),
                                    hostKeyTrust: AcceptAllTrust())
    let result = await outcome { try await connection.authenticate(interactive: nil) }
    #expect(result == "protocolViolation")
    let phase = await connection.phase
    #expect(phase == .idle, "拒掉之后连接状态被改成了 \(phase)")
}

@Test("已经废掉的连接不许再拿去认证")
func authenticateOnAbortedSessionReportsConnectionLost() async throws {
    let port = try startRefusedPort()
    let connection = SFTPConnection(request: request(port: port, authentication: .password(goodPassword)),
                                    hostKeyTrust: AcceptAllTrust())
    _ = await outcome { try await connection.handshake() }
    let afterHandshake = await connection.phase
    #expect(afterHandshake == .aborted)

    let result = await outcome { try await connection.authenticate(interactive: nil) }
    #expect(result == "network/connectionLost")
}

// MARK: - 真机组：密码

@Test("密码认证成功：方式、服务器给的清单、单线程与计数都落档", .enabled(if: liveServersEnabled))
func passwordAuthenticationSucceeds() async throws {
    let connection = SFTPConnection(request: request(port: 2202, authentication: .password(goodPassword)),
                                    hostKeyTrust: AcceptAllTrust())
    _ = try await connection.handshake()
    let afterHandshake = await connection.measure
    let session = try await connection.authenticate(interactive: nil)
    #expect(session.method == .password)
    #expect(session.serverOfferedMethods.contains("password"))
    #expect(session.serverOfferedMethods.contains("publickey"))
    #expect(session.agentIdentity == nil)
    let phase = await connection.phase
    #expect(phase == .authenticated)

    let measure = await connection.measure
    // D7 说"一条 session 的全部 C 调用只落在自己那条串行 executor 上"，实测要拆成两格才成立：
    // `DispatchQueue.async` 串行队列保证的是**不同时**执行两个 job，不是同一个 job 序列永远
    // 由同一条 worker 承载——握手那次 `await` 之后，Swift 的续体可能被队列的另一条 worker 接走。
    // 所以这里可证伪的是"认证这一趟自己没再换线程"，而不是"认证和握手共用一条线程"。
    #expect(Set(afterHandshake.executorThreads).count == 1, "握手阶段就有两条线程：\(afterHandshake.executorThreads)")
    let authOnly = Set(measure.executorThreads).subtracting(afterHandshake.executorThreads)
    #expect(authOnly.count <= 1, "认证阶段内部又换了线程：\(measure.executorThreads)")
    #expect(measure.authAttempts == 1, "凭据发了 \(measure.authAttempts) 次")
    // none 探测不算认证尝试，但它确实发过包：没进过 poll 循环就是实现绕过了 SessionLoop
    #expect(measure.eagainCount > 0)

    // 幂等：认证过了再调一次不该再发一遍凭据
    let again = try await connection.authenticate(interactive: nil)
    #expect(again == session)
    let afterRepeat = await connection.measure
    #expect(afterRepeat.authAttempts == 1, "重复调用又发了一次凭据")

    // 认证之后握手仍然幂等：连接池拿到的是一条完整可用的连接
    let negotiated = try await connection.handshake()
    #expect(negotiated.serverIdentification.hasPrefix("SSH-2.0-"))

    await connection.close()
    let closed = await connection.phase
    #expect(closed == .closed)
}

@Test("口令错不拆会话：同一份凭据可以就地重试，服务器清单还读得到", .enabled(if: liveServersEnabled))
func wrongPasswordKeepsSession() async throws {
    let connection = SFTPConnection(request: request(port: 2202, authentication: .password("definitely-wrong")),
                                    hostKeyTrust: AcceptAllTrust())
    _ = try await connection.handshake()

    let first = await outcome { try await connection.authenticate(interactive: nil) }
    #expect(first == "auth/badPassword")
    let phase = await connection.phase
    // 凭据问题不是链路问题：transport 完好，判成 aborted 等于对用户说"网络不行"
    #expect(phase == .ready, "口令错被判成了 \(phase)")

    let second = await outcome { try await connection.authenticate(interactive: nil) }
    #expect(second == "auth/badPassword")
    let measure = await connection.measure
    #expect(measure.authAttempts == 2, "两次尝试都该记在诊断里，实际 \(measure.authAttempts)")
    // 会话没被 auth 失败污染，关闭走的还是体面那条路
    await connection.close()
    let closed = await connection.phase
    #expect(closed == .closed)
}

@Test("重试不重复探测 none：五格错口令都还是口令错，而不是被服务器踢出场", .enabled(if: liveServersEnabled))
func retriesDoNotDoubleBurnServerAttempts() async throws {
    // 2202 生效值 `maxauthtries 6`（`docker exec ... sshd -T`）。一次 `libssh2_userauth_list`
    // 就是一条 `USERAUTH_REQUEST(method=none)`，服务器上照记一次尝试——M1-04 §1.4 是拿
    // "连续只列清单，第 7 次被踢"直接量出来的，sshd 日志里 attempt 一格一格涨也对得上。
    // 清单没缓存之前，每次 authenticate() 花两格 ⇒ 第 4 次就变成 connectionLost；
    // 缓存之后第 1 次花两格、其余各一格 ⇒ 前五格都还该是 badPassword。
    let connection = SFTPConnection(request: request(port: 2202, authentication: .password("definitely-wrong")),
                                    hostKeyTrust: AcceptAllTrust())
    _ = try await connection.handshake()
    for attempt in 1...5 {
        let result = await outcome { try await connection.authenticate(interactive: nil) }
        #expect(result == "auth/badPassword",
                "第 \(attempt) 次拿到 \(result)——多花的那一格是把用户踢出场，不是告诉他口令错")
    }
    let measure = await connection.measure
    #expect(measure.authAttempts == 5, "我们自己数的尝试次数：\(measure.authAttempts)")
    await connection.close()
}

@Test("服务器不收这种方式时直说，而不是让用户怀疑自己打错口令", .enabled(if: liveServersEnabled))
func methodNotOfferedByServerIsNamed() async throws {
    let log = PromptLog()
    // 2202 线路上只发 publickey/password（M1-01 §1），keyboard-interactive 该在这里被点破
    let connection = SFTPConnection(request: request(port: 2202, authentication: .keyboardInteractive),
                                    hostKeyTrust: AcceptAllTrust())
    _ = try await connection.handshake()
    let result = await outcome {
        try await connection.authenticate(interactive: RecordingResponder(log: log) { always("x")($0) })
    }
    #expect(result == "auth/methodNotOffered", "实际：\(result)")
    let asked = await log.count
    #expect(asked == 0, "方式都不支持还把对话框弹起来了")
    let phase = await connection.phase
    #expect(phase == .ready, "这条本该只停在 ready，实际 \(phase)")
    await connection.close()
}

// MARK: - 真机组：公钥与口令（H12 那三格）

@Test("明文私钥直接过；同一把加密私钥带没带口令，-16 分成两格", .enabled(if: liveServersEnabled))
func privateKeyPassphraseSplitsThreeWays() async throws {
    let plain = try keyData("ed_plain")
    let bcrypt = try keyData("ed_bcrypt")
    // 分界的前提是头部读得对
    #expect(PrivateKeyEncryption.probe(plain) == .plain)
    #expect(PrivateKeyEncryption.probe(bcrypt) == .encrypted)

    // 1) 明文私钥：压根没有口令可给，能过
    let (plainConnection, plainSession) = try await handshakeThenAuthenticate(
        port: 2202, authentication: .privateKey(PrivateKeyMaterial(keyData: plain, passphrase: nil)))
    #expect(plainSession.method == .publickey)
    await plainConnection.close()

    // 2) 加密私钥 + 错口令：只有这一格敢说 passphraseIncorrect
    let wrongConnection = SFTPConnection(
        request: request(port: 2202,
                         authentication: .privateKey(PrivateKeyMaterial(keyData: bcrypt,
                                                                        passphrase: "not-the-passphrase"))),
        hostKeyTrust: AcceptAllTrust())
    _ = try await wrongConnection.handshake()
    let wrong = await outcome { try await wrongConnection.authenticate(interactive: nil) }
    #expect(wrong == "auth/passphraseIncorrect", "实际：\(wrong)")
    let wrongPhase = await wrongConnection.phase
    #expect(wrongPhase == .ready)
    await wrongConnection.close()

    // 3) 加密私钥 + 没给口令：同一个 -16，下一步却是"去把口令填上"
    let missingConnection = SFTPConnection(
        request: request(port: 2202,
                         authentication: .privateKey(PrivateKeyMaterial(keyData: bcrypt, passphrase: nil))),
        hostKeyTrust: AcceptAllTrust())
    _ = try await missingConnection.handshake()
    let missing = await outcome { try await missingConnection.authenticate(interactive: nil) }
    #expect(missing == "auth/passphraseRequired",
            "没给口令的加密私钥被报成了 \(missing)——那是谎报口令错")
    await missingConnection.close()

    // 4) 加密私钥 + 对口令：bcrypt 这一轮该真的花掉那 0.4–0.6 s（M0b-03 §6）
    let (rightConnection, rightSession) = try await handshakeThenAuthenticate(
        port: 2202, authentication: .privateKey(PrivateKeyMaterial(keyData: bcrypt, passphrase: keyPassphrase)))
    #expect(rightSession.method == .publickey)
    let measure = await rightConnection.measure
    #expect(measure.authElapsedMs >= 200, "bcrypt 快得不像真的解了密：\(measure.authElapsedMs) ms")
    await rightConnection.close()
}

@Test("老式 PEM 与新格式共用同一枚 -16，分开三格全靠头部探针", .enabled(if: liveServersEnabled))
func legacyPemSharesTheSameCodeAsNewFormat() async throws {
    let pem = try keyData("rsa_pem")
    #expect(PrivateKeyEncryption.probe(pem) == .encrypted)

    // 没给口令：期望"去把口令填上"，而不是"口令错"或"钥匙被拒"。
    // 码是 `-16` 不是 `-48`：`pem.c:466` 那条 "passphrase required" 确实返回 `-48`，
    // 但它的调用方 `openssl.c:4987 _libssh2_pub_priv_keyfilememory` 只看 `st == 0`，
    // 非 0 一律换成 `-16 FILE` + "Unsupported private key file format"（M1-04 §3.1 实测 31 格，无一 -48）。
    // 所以 M0a-05 那句"-16 同时是三件事"要说满：两个入口、四种格式**全都**收成这一枚。
    let missing = SFTPConnection(
        request: request(port: 2202,
                         authentication: .privateKey(PrivateKeyMaterial(keyData: pem, passphrase: nil))),
        hostKeyTrust: AcceptAllTrust())
    _ = try await missing.handshake()
    let missingCode = await outcome { try await missing.authenticate(interactive: nil) }
    #expect(missingCode == "auth/passphraseRequired", "PEM 缺口令那一格实际：\(missingCode)")
    let missingPhase = await missing.phase
    #expect(missingPhase == .ready, "缺口令不该报废会话，实际 \(missingPhase)")
    await missing.close()

    // 口令错：还是 `-16`。这格能落到 passphraseIncorrect 全靠"带了口令"这个事实——
    // 我们这版 OpenSSL 里 libssh2 的 `HAVE_SSLERROR_BAD_DECRYPT` 没定义，
    // 它自己那条"Wrong passphrase"分支被编译掉了（openssl.c:5037-5047），
    // 于是口令错与"压根不是私钥"共用 -16。
    let wrong = SFTPConnection(
        request: request(port: 2202,
                         authentication: .privateKey(PrivateKeyMaterial(keyData: pem, passphrase: "not-the-passphrase"))),
        hostKeyTrust: AcceptAllTrust())
    _ = try await wrong.handshake()
    let wrongCode = await outcome { try await wrong.authenticate(interactive: nil) }
    #expect(wrongCode == "auth/passphraseIncorrect", "PEM 口令错那一格实际：\(wrongCode)")
    await wrong.close()

    // 对口令：换一条连接就该过——前两格烧掉的是各自那条连接上的服务器尝试次数。
    let (rightConnection, rightSession) = try await handshakeThenAuthenticate(
        port: 2202, authentication: .privateKey(PrivateKeyMaterial(keyData: pem, passphrase: keyPassphrase)))
    #expect(rightSession.method == .publickey)
    await rightConnection.close()

    let garbage = Data("PuTTY-User-Key-File-2: ssh-ed25519\nnot a key at all\n".utf8)
    #expect(PrivateKeyEncryption.probe(garbage) == .unrecognized)
    let garbageConnection = SFTPConnection(
        request: request(port: 2202,
                         authentication: .privateKey(PrivateKeyMaterial(keyData: garbage, passphrase: nil))),
        hostKeyTrust: AcceptAllTrust())
    _ = try await garbageConnection.handshake()
    let rejected = await outcome { try await garbageConnection.authenticate(interactive: nil) }
    // 读不出加密形态就不许猜"缺口令"，也不许猜"口令错"
    #expect(rejected == "auth/keyRejected", "实际：\(rejected)")
    await garbageConnection.close()
}

@Test("空私钥材料在本地就拒掉，不发到线上", .enabled(if: liveServersEnabled))
func emptyKeyMaterialFailsLocally() async throws {
    let connection = SFTPConnection(
        request: request(port: 2202,
                         authentication: .privateKey(PrivateKeyMaterial(keyData: Data(), passphrase: nil))),
        hostKeyTrust: AcceptAllTrust())
    _ = try await connection.handshake()
    let result = await outcome { try await connection.authenticate(interactive: nil) }
    #expect(result == "localIO/readFailed")
    // 这条同样是凭据问题：会话不该因此报废
    let phase = await connection.phase
    #expect(phase == .ready)
    await connection.close()
}

// MARK: - 真机组：keyboard-interactive

@Test("keyboard-interactive 在 2205 上真能问出提示并答进去", .enabled(if: liveServersEnabled))
func keyboardInteractiveRoundTrip() async throws {
    let log = PromptLog()
    let (connection, session) = try await handshakeThenAuthenticate(
        port: 2205, authentication: .keyboardInteractive,
        interactive: RecordingResponder(log: log) { always(goodPassword)($0) })

    #expect(session.method == .keyboardInteractive)
    #expect(session.serverOfferedMethods.contains("keyboard-interactive"))
    let asked = await log.count
    #expect(asked >= 1, "2205 一次都没问过用户")
    let first = await log.first
    #expect(first?.endpoint.username == "tester")
    // 提示原样来自服务器：PAM 那侧至少有一条不回显的口令提示，UI 才知道该画成密码框
    #expect((first?.prompts ?? []).contains { !$0.echo },
            "2205 的提示全是要回显的：\(first?.prompts ?? [])")

    let measure = await connection.measure
    // H11 的可证伪版本：回调是在 session 自己那条执行线程上被同步等住的，
    // 它答完之后的那趟 C 调用不该再换第三条线程（握手一条 + 认证一条是已知的上限）。
    #expect(measure.executorThreads.count <= 2, "跨了 \(measure.executorThreads.count) 条线程：\(measure.executorThreads)")
    await connection.close()
}

@Test("2201 把 keyboard-interactive 列进清单，却对请求直接回失败（不问就不许等）",
      .enabled(if: liveServersEnabled))
func advertisedButNeverAsks() async throws {
    let log = PromptLog()
    let connection = SFTPConnection(request: request(port: 2201, authentication: .keyboardInteractive),
                                    hostKeyTrust: AcceptAllTrust())
    _ = try await connection.handshake()
    let result = await outcome {
        try await connection.authenticate(
            interactive: RecordingResponder(log: log) { always(goodPassword)($0) })
    }
    // 清单里有 `keyboard-interactive`，服务器却不发 `USERAUTH_INFO_REQUEST`（`usepam no` 的
    // 8.4p1 实测，M1-04 §5.2）。libssh2 拿回 -18，UI 要是照着清单等提示就会一直转圈。
    #expect(result == "auth/badPassword", "实际：\(result)")
    let asked = await log.count
    #expect(asked == 0, "服务器压根没问，应答者却被调了 \(asked) 次")
    // 这是服务器的策略而不是链路故障，会话留着让用户改口令重填。
    let phase = await connection.phase
    #expect(phase == .ready)
    await connection.close()
}

@Test("认证失败后同一条会话换个答案重试就过了（不等用户答的时长不烧预算）", .enabled(if: liveServersEnabled))
func kbdintRetryWithNewAnswerReusesSession() async throws {
    let connection = SFTPConnection(request: request(port: 2205, authentication: .keyboardInteractive),
                                    hostKeyTrust: AcceptAllTrust())
    _ = try await connection.handshake()

    let first = await outcome {
        try await connection.authenticate(interactive: RecordingResponder(log: PromptLog()) { always("wrong")($0) })
    }
    #expect(first == "auth/badPassword", "第一次本该是口令错，实际：\(first)")
    let midPhase = await connection.phase
    #expect(midPhase == .ready)

    let second = try await connection.authenticate(interactive: RecordingResponder(log: PromptLog()) {
        always(goodPassword)($0)
    })
    #expect(second.method == .keyboardInteractive)
    let endPhase = await connection.phase
    #expect(endPhase == .authenticated)

    let measure = await connection.measure
    #expect(measure.authAttempts == 2, "两次都该记下，实际 \(measure.authAttempts)")
    // 同一条会话免掉的正是那次密钥交换：握手用时不该被认证次数带着涨
    #expect(measure.executorThreads.count <= 2, "\(measure.executorThreads)")
    await connection.close()
}

@Test("等用户答题期间取消，在一个半切片内生效且不谎报口令错", .enabled(if: liveServersEnabled))
func cancelDuringPromptIsFastAndHonest() async throws {
    let connection = SFTPConnection(request: request(port: 2205, authentication: .keyboardInteractive),
                                    hostKeyTrust: AcceptAllTrust())
    _ = try await connection.handshake()

    struct NeverAnswers: KeyboardInteractiveResponder {
        func respond(to request: KeyboardInteractiveRequest) async -> [String]? {
            // 用户还在找验证码。30 s 只是个够长的值，测试不会等它回来。
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            return nil
        }
    }

    let task = Task {
        await outcome { try await connection.authenticate(interactive: NeverAnswers()) }
    }
    // 让认证确实停在"等人答题"里面：提示从服务器到 UI 只要几十毫秒
    try? await Task.sleep(nanoseconds: 400_000_000)
    let cancelAt = DispatchTime.now()
    connection.cancel()
    let result = await task.value
    let latency = elapsed(cancelAt)

    // 回调那条空应答还是发出去了（libssh2 没给回调返回错误的路，M1-04 §4.3），
    // 所以上面拿回的必须是取消而不是服务器回的那次失败——否则用户会去改一个没错的口令。
    #expect(result == "cancelled", "实际：\(result)")
    #expect(latency <= 150, "取消延迟 \(latency) ms，超出一个半切片")
    let phase = await connection.phase
    #expect(phase == .aborted, "被取消打断的 session 只能丢弃（D6），实际 \(phase)")
}

@Test("用户关掉对话框算取消；答的条数不对算协议违规", .enabled(if: liveServersEnabled))
func declinedAndMismatchedPrompts() async throws {
    let declined = SFTPConnection(request: request(port: 2205, authentication: .keyboardInteractive),
                                  hostKeyTrust: AcceptAllTrust())
    _ = try await declined.handshake()
    let closed = await outcome {
        try await declined.authenticate(interactive: RecordingResponder(log: PromptLog()) { _ in nil })
    }
    #expect(closed == "cancelled", "关对话框被判成了：\(closed)")
    let declinedPhase = await declined.phase
    #expect(declinedPhase == .aborted, "用户主动取消之后连接还被当成可重试")

    let mismatch = SFTPConnection(request: request(port: 2205, authentication: .keyboardInteractive),
                                  hostKeyTrust: AcceptAllTrust())
    _ = try await mismatch.handshake()
    // 应答条数和服务器问的对不上是调用方的 bug，不能当成认证失败
    let wrong = await outcome {
        try await mismatch.authenticate(interactive: RecordingResponder(log: PromptLog()) { _ in ["a", "b", "c"] })
    }
    #expect(wrong == "protocolViolation", "条数不符被判成了：\(wrong)")
    let mismatchPhase = await mismatch.phase
    #expect(mismatchPhase == .aborted)
}

// MARK: - 真机组 + 临时 agent

@Test("ssh-agent 认证走的是 agent 里那把钥匙", .enabled(if: liveServersEnabled && agentAvailable))
func agentAuthenticationSucceeds() async throws {
    let (connection, session) = try await handshakeThenAuthenticate(port: 2202, authentication: .sshAgent)
    #expect(session.method == .agent)
    // 这一格只有真跑过 agent 才有内容：记下用的是哪把钥匙，诊断报告才指认得了
    let identity = session.agentIdentity ?? ""
    #expect(!identity.isEmpty, "认证成功却没记下用的是哪把钥匙")
    let phase = await connection.phase
    #expect(phase == .authenticated)
    let measure = await connection.measure
    #expect(measure.executorThreads.count <= 2, "\(measure.executorThreads)")
    #expect(measure.authAttempts >= 1)
    await connection.close()
}

@Test("2204 只认 ssh-rsa：agent 里有 RSA 就该过", .enabled(if: liveServersEnabled && agentAvailable))
func agentWorksOnRSAOnlyServer() async throws {
    // 2204 的 `PubkeyAcceptedAlgorithms ssh-rsa` 是整值赋值（M1-01 §2）。
    // 反向对照（agent 里只留 ed25519 必须被拒）由 Spike/Scripts/ssh-agent-test.sh §5 盯：
    // 测试脚本不去改 agent 的密钥列表，那是污染环境。
    let (connection, session) = try await handshakeThenAuthenticate(port: 2204, authentication: .sshAgent)
    #expect(session.method == .agent)
    await connection.close()
}

@Test("没有可用的 agent 时报认证失败而不是段错误", .enabled(if: liveServersEnabled && !agentAvailable))
func agentWithoutSocketFailsCleanly() async throws {
    let connection = SFTPConnection(request: request(port: 2202, authentication: .sshAgent),
                                    hostKeyTrust: AcceptAllTrust())
    _ = try await connection.handshake()
    let result = await outcome { try await connection.authenticate(interactive: nil) }
    // `libssh2_agent_init(NULL)` 会直接段错误（M0a-05 结论 4）：这条首先断言的是没崩。
    // 落格必须是 `agentUnavailable` 而不是 `keyRejected`：本机没有 agent 和用户选错了凭据来源
    // 是两件事，报成"钥匙被拒"会让人去查一个根本没收过这把钥匙的服务器。
    #expect(result == "auth/agentUnavailable", "实际：\(result)")
    // 这是本机的配置问题，不是链路问题：谈好的 transport 留着，用户改完设置可以就地再试。
    let phase = await connection.phase
    #expect(phase == .ready, "没 agent 不该报废会话，实际 \(phase)")
}
