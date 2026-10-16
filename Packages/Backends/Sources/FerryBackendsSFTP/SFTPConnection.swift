import CLibssh2
import Darwin
import FerryCore
import Foundation

/// libssh2 的进程级初始化。`static let` 由 Swift 保证只执行一次且带锁，
/// 比"每次连接调一次 libssh2_init"好——它是引用计数的，重复调要配对 exit，
/// 而我们的退出时机在 App 生命周期里，不在连接里。
enum Libssh2 {
    static let status: Int32 = libssh2_init(0)
}

/// 一条 SFTP 连接的握手部分：TCP → 算法偏好 → 密钥交换 → 主机密钥信任判定。
///
/// 线程模型直接来自 ADR-0001 D7：actor 绑在自己那条 `SessionExecutor` 上，
/// 于是 fd、`LIBSSH2_SESSION *` 和计时都是 actor 隔离状态，一把锁都不用加；
/// 唯一 `nonisolated` 的是取消标志，它必须能从 UI 线程立刻置位（D3）。
///
/// 认证在 M1'-4 接进来，`sftp_init` 与文件系统操作在 M1'-5。
public actor SFTPConnection: RemoteConnection {
    nonisolated private let executor: SessionExecutor
    nonisolated private let request: ConnectionRequest
    nonisolated private let hostKeyTrust: any HostKeyTrust
    nonisolated private let cancelFlag = CancellationFlag()

    private var state: ConnectionPhase = .idle
    private var fd: Int32 = -1
    private var session: OpaquePointer?
    private var negotiated: NegotiatedSession?
    private var loopStats = LoopStats()
    private var elapsedMs: Int64 = 0
    /// D7 的可证伪版本：握手的每一步都往这里记线程号，测试断言它只有一个元素。
    private var visitedThreads: Set<UInt64> = []

    public init(request: ConnectionRequest, hostKeyTrust: any HostKeyTrust) {
        self.request = request
        self.hostKeyTrust = hostKeyTrust
        self.executor = SessionExecutor(label: "local.ferry.sftp.session")
    }

    nonisolated public var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    nonisolated public var endpoint: Endpoint { request.endpoint }

    nonisolated public func cancel() {
        cancelFlag.cancel()
    }

    public var phase: ConnectionPhase { state }

    /// 握手的实测数据，给测试和诊断报告用。
    public struct Measure: Sendable, Hashable {
        public let elapsedMs: Int64
        public let eagainCount: Int
        public let pollCount: Int
        public let pollTimeoutCount: Int
        public let executorThreads: [UInt64]
    }

    public var measure: Measure {
        Measure(elapsedMs: elapsedMs,
                eagainCount: loopStats.eagain,
                pollCount: loopStats.polls,
                pollTimeoutCount: loopStats.pollTimeouts,
                executorThreads: visitedThreads.sorted())
    }

    public func handshake() async throws -> NegotiatedSession {
        switch state {
        case .idle:
            break
        case .ready:
            // 幂等：重入拿到的是同一份事实，不会二次握手。
            guard let negotiated else {
                throw RemoteError.protocolViolation("phase=ready 但没有握手结果")
            }
            return negotiated
        case .connecting:
            throw RemoteError.protocolViolation("同一条连接上并发发起握手")
        case .aborted, .closed:
            throw RemoteError.network(.connectionLost)
        }

        state = .connecting
        let start = uptimeMilliseconds()
        do {
            let result = try await performHandshake()
            elapsedMs = uptimeMilliseconds() - start
            negotiated = result
            state = .ready
            return result
        } catch {
            elapsedMs = uptimeMilliseconds() - start
            // 失败一律硬拆：超时/拒连时对面根本不该再收包，主机密钥不被信任时
            // 更不能把凭据发出去；被取消时体面关闭要 8 秒（D4）。
            hardTeardown()
            state = .aborted
            throw error
        }
    }

    private func performHandshake() async throws -> NegotiatedSession {
        guard Libssh2.status == 0 else {
            throw RemoteError.operationFailed(OperationFailure(
                kind: .sessionCode(Libssh2.status), operation: .handshake, path: nil, rc: Libssh2.status))
        }
        let policy = request.policy
        visitedThreads.insert(currentThreadID())

        fd = try TCPStream.connect(endpoint: request.endpoint,
                                   timeout: policy.connectTimeout,
                                   cancel: cancelFlag,
                                   stats: loopStats).fd
        visitedThreads.insert(currentThreadID())

        guard let newSession = libssh2_session_init_ex(nil, nil, nil, nil) else {
            throw RemoteError.operationFailed(OperationFailure(
                kind: .sessionCode(-1), operation: .handshake, path: nil, rc: -1))
        }
        session = newSession

        // 非阻塞必须在 handshake 之前设：D5 说的就是"建阶段也得能按时取消"。
        libssh2_session_set_blocking(newSession, 0)
        // 兜底：非阻塞模式下不该有阻塞读，但留个上限，免得哪条内部路径睡死。
        libssh2_session_set_timeout(newSession, Int(milliseconds(of: policy.handshakeTimeout)))

        try applyAlgorithmPreferences(newSession, policy.algorithms)
        visitedThreads.insert(currentThreadID())

        let socket = fd
        // 计数直接写进 actor 状态：drive() 抛错时（取消、超时）这一路径上
        // "切片用了几个"正是要看的数，不能只成功返回才带回来。
        var loop = SessionLoop(fd: socket, session: newSession, cancel: cancelFlag, stats: loopStats)
        let rc = try loop.drive(deadlineMs: milliseconds(of: policy.handshakeTimeout)) {
            libssh2_session_handshake(newSession, socket)
        }
        visitedThreads.insert(currentThreadID())

        if rc != 0 {
            throw ErrorTaxonomy.classifySession(rc: rc, context: RemoteErrorContext(operation: .handshake))
                ?? RemoteError.operationFailed(OperationFailure(
                    kind: .sessionCode(rc), operation: .handshake, path: nil, rc: rc))
        }

        let banner = libssh2_session_banner_get(newSession).map { String(cString: $0) } ?? ""
        guard banner.hasPrefix("SSH-") else {
            throw RemoteError.protocolViolation("banner 不像 SSH：\(banner.prefix(64))")
        }

        var keyLength: Int = 0
        var keyType: Int32 = 0
        guard let keyPointer = libssh2_session_hostkey(newSession, &keyLength, &keyType), keyLength > 0 else {
            throw RemoteError.protocolViolation("握手成功但取不到主机密钥（type=\(keyType) len=\(keyLength)）")
        }
        let hostKey = try HostKey(algorithm: try methodName(newSession, LIBSSH2_METHOD_HOSTKEY),
                                  blob: Data(bytes: UnsafeRawPointer(keyPointer), count: keyLength))

        let algorithms = NegotiatedAlgorithms(
            keyExchange: try methodName(newSession, LIBSSH2_METHOD_KEX),
            hostKey: hostKey.algorithm,
            encryptionClientToServer: try methodName(newSession, LIBSSH2_METHOD_CRYPT_CS),
            encryptionServerToClient: try methodName(newSession, LIBSSH2_METHOD_CRYPT_SC),
            macClientToServer: try methodName(newSession, LIBSSH2_METHOD_MAC_CS),
            macServerToClient: try methodName(newSession, LIBSSH2_METHOD_MAC_SC))
        try verifyNegotiatedWithinPolicy(algorithms, policy.algorithms)

        visitedThreads.insert(currentThreadID())
        // 认证一个字节都还没发出去。拒绝时对面只会看到一个被掐断的 socket。
        try await hostKeyTrust.evaluate(endpoint: request.endpoint, hostKey: hostKey)

        return NegotiatedSession(serverIdentification: banner, hostKey: hostKey, algorithms: algorithms)
    }

    /// 算法偏好。libssh2 只认自己编译进去的算法名，给了不认识的名字
    /// `method_pref` 立刻返回 `LIBSSH2_ERROR_METHOD_NOT_SUPPORTED`——
    /// 这条正是"我们这侧压根不支持"与"服务器不接受"的分界（M1'-8 要用）。
    private func applyAlgorithmPreferences(_ newSession: OpaquePointer, _ preferences: AlgorithmPreferences) throws {
        guard !preferences.isEmpty else { return }
        let table: [(kind: Int32, names: [String])] = [
            (LIBSSH2_METHOD_KEX, preferences.keyExchange),
            (LIBSSH2_METHOD_HOSTKEY, preferences.hostKey),
            (LIBSSH2_METHOD_CRYPT_CS, preferences.encryption),
            (LIBSSH2_METHOD_CRYPT_SC, preferences.encryption),
            (LIBSSH2_METHOD_MAC_CS, preferences.mac),
            (LIBSSH2_METHOD_MAC_SC, preferences.mac),
        ]
        for entry in table where !entry.names.isEmpty {
            let joined = entry.names.joined(separator: ",")
            let rc = joined.withCString { libssh2_session_method_pref(newSession, entry.kind, $0) }
            guard rc != 0 else { continue }
            throw ErrorTaxonomy.classifySession(rc: rc, context: RemoteErrorContext(operation: .handshake))
                ?? RemoteError.operationFailed(OperationFailure(
                    kind: .sessionCode(rc), operation: .handshake, path: nil, rc: rc))
        }
    }

    private func methodName(_ newSession: OpaquePointer, _ kind: Int32) throws -> String {
        guard let pointer = libssh2_session_methods(newSession, kind) else {
            throw RemoteError.protocolViolation("取不到协商结果（method=\(kind)）：\(lastErrorText(newSession))")
        }
        return String(cString: pointer)
    }

    /// 只进诊断报告，不参与分类——`ErrorTaxonomy` 规则 1 说的就是别拿 libssh2 的
    /// 文案当依据（实测它会把口令错说成"Unsupported private key file format"）。
    private func lastErrorText(_ newSession: OpaquePointer) -> String {
        var buffer: UnsafeMutablePointer<CChar>?
        libssh2_session_last_error(newSession, &buffer, nil, 0)
        return buffer.map { String(cString: $0) } ?? "<无消息>"
    }

    /// 正常收尾：发 `SSH_MSG_DISCONNECT`，再释放 session 与 socket。
    /// 只在没人取消时走这条路（D4 禁止在取消路径上做体面关闭）。
    public func close() async {
        switch state {
        case .idle:
            state = .closed
        case .connecting, .ready:
            disconnectOrderly()
            releaseSession()
            state = .closed
        case .aborted, .closed:
            break
        }
    }

    private func disconnectOrderly() {
        guard let session, fd >= 0 else { return }
        let socket = fd
        var loop = SessionLoop(fd: socket, session: session, cancel: cancelFlag, stats: loopStats)
        // 对面已经死了的话这里会超时；超时不重要，释放照做，所以吞掉错误。
        _ = try? loop.drive(deadlineMs: 500) {
            libssh2_session_disconnect_ex(session, SSH_DISCONNECT_BY_APPLICATION, "Ferry closed the connection", "")
        }
    }

    /// 取消/失败收尾：`shutdown(SHUT_RDWR)` → `session_free` → `close`，
    /// 不发任何协议包、不等任何响应（ADR-0001 D4，实测 8.05 s → 0.20 s）。
    private func hardTeardown() {
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
            fd = -1
        }
        releaseSession()
    }

    private func releaseSession() {
        if let session {
            libssh2_session_free(session)
            self.session = nil
        }
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }
}

/// 协商结果必须落在策略集合内，否则判协议违规。
///
/// 这一条不能省。实测 libssh2 1.11.1 的 `libssh2_session_method_pref`
/// （kex.c:4214 起的 strip 循环）会**静默剔除**它编译时不认识的名字，只有整串被剔光
/// 才返回 `-33 METHOD_NOT_SUPPORTED`——"策略里写了个我们没编进去的算法"不报错，
/// 只是那条偏好悄悄消失。SecurityBaseline 禁止静默降级，兜底只能是拿实际协商值反查策略：
/// 方向也刚好对，策略被放宽一定会在这里露出来。
///
/// 空策略（库默认）时无从校验，所以什么都不查——2203/2204 能用 `hmac-sha1` + `aes*-cbc`
/// 握手成功就是因为 libssh2 的默认集很宽；出厂默认策略要由 M1'-8 的矩阵来定。
///
/// 写成自由函数是为了让单测能直接构造"策略外"的协商值：真机上凑不出这一格
/// （libssh2 不会主动谈策略外的算法），但它正是这条守卫防的事。
func verifyNegotiatedWithinPolicy(_ negotiated: NegotiatedAlgorithms, _ preferences: AlgorithmPreferences) throws {
    func check(_ dimension: String, allowed: [String], actual: String) throws {
        guard !allowed.isEmpty, !allowed.contains(actual) else { return }
        throw RemoteError.protocolViolation(
            "协商出策略外的 \(dimension)：\(actual)，策略=\(allowed.joined(separator: ","))")
    }
    try check("kex", allowed: preferences.keyExchange, actual: negotiated.keyExchange)
    try check("host key", allowed: preferences.hostKey, actual: negotiated.hostKey)
    try check("cipher(c→s)", allowed: preferences.encryption, actual: negotiated.encryptionClientToServer)
    try check("cipher(s→c)", allowed: preferences.encryption, actual: negotiated.encryptionServerToClient)
    try check("mac(c→s)", allowed: preferences.mac, actual: negotiated.macClientToServer)
    try check("mac(s→c)", allowed: preferences.mac, actual: negotiated.macServerToClient)
}
