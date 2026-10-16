import FerryBackendsSFTP
import FerryCore
import Foundation

/// M1'-2 用：拿**正式实现**（`SFTPBackend` + `SFTPConnection`）打五台服务器，
/// 把协商结果与计时打印成表。刻意不在这里重抄一遍 libssh2 调用——
/// 测的必须是以后要发布的那条代码路径，否则表里的数字没有意义。
///
/// 用法：
///   SPIKE_PORTS="2201 2202" spike handshake                    # 默认：库内算法偏好
///   SPIKE_PREFS=legacy spike handshake                          # 放开老算法（M1'-8 用它出矩阵）
///   SPIKE_EXPERIMENT=stall spike handshake                      # 加测取消与超时（本地黑洞监听）
enum HandshakeProbe {

    /// spike 只关心"谈成了什么"，不拦指纹。生产路径的实现在 M1'-3。
    private struct TrustForSpike: HostKeyTrust {
        func evaluate(endpoint: Endpoint, hostKey: HostKey) async throws {}
    }

    struct Failure: Error { let step: String; let detail: String }

    private static let legacy = AlgorithmPreferences(
        keyExchange: ["diffie-hellman-group14-sha1", "diffie-hellman-group-exchange-sha256",
                      "diffie-hellman-group1-sha1", "ecdh-sha2-nistp256", "curve25519-sha256"],
        hostKey: ["ssh-rsa", "ssh-ed25519", "ecdsa-sha2-nistp256"],
        encryption: ["aes128-cbc", "aes192-cbc", "aes256-cbc", "aes128-ctr", "aes256-ctr", "3des-cbc"],
        mac: ["hmac-sha1", "hmac-sha1-96", "hmac-sha2-256", "hmac-md5"]
    )

    /// 只留现代算法：用来量"配置窄到不接受我们时，失败长什么样"（M1'-8 的一格）。
    private static let modern = AlgorithmPreferences(
        keyExchange: ["curve25519-sha256", "curve25519-sha256@libssh.org", "ecdh-sha2-nistp256"],
        hostKey: ["ssh-ed25519", "rsa-sha2-512", "rsa-sha2-256", "ecdsa-sha2-nistp256"],
        encryption: ["chacha20-poly1305@openssh.com", "aes256-gcm@openssh.com", "aes128-gcm@openssh.com", "aes256-ctr", "aes192-ctr", "aes128-ctr"],
        mac: ["hmac-sha2-512-etm@openssh.com", "hmac-sha2-256-etm@openssh.com", "hmac-sha2-512", "hmac-sha2-256"]
    )

    /// 认不出的名字：`method_pref` 立刻返回 METHOD_NOT_SUPPORTED，
    /// 这是"我们这侧压根不支持"与"服务器不接受"的分界样本。
    private static let bogus = AlgorithmPreferences(
        keyExchange: ["ferry-bogus-kex@example.com"], hostKey: [], encryption: [], mac: []
    )

    /// 主机密钥证书算法名：libssh2 认这个名字（`hostkey_methods[]` 里有，但 `init`/`sig_verify` 是 NULL），
    /// 所以不会像 bogus 那样被静默剔掉，而是走到 KEX 里才失败。M1'-3 §5 用它钉"证书进不了信任判定"。
    private static let cert = AlgorithmPreferences(
        keyExchange: [], hostKey: ["ssh-ed25519-cert-v01@openssh.com"], encryption: [], mac: []
    )

    static func run() async {
        let env = ProcessInfo.processInfo.environment
        let host = env["SPIKE_AGENT_HOST"] ?? env["SPIKE_HOST"] ?? "127.0.0.1"
        let ports = (env["SPIKE_PORTS"] ?? "2201 2202 2203 2204 2205")
            .split(separator: " ").compactMap { Int($0) }
        let preferences: AlgorithmPreferences
        switch env["SPIKE_PREFS"] {
        case "legacy": preferences = legacy
        case "modern": preferences = modern
        case "bogus": preferences = bogus
        case "cert": preferences = cert
        default: preferences = .libraryDefault
        }
        let backend = SFTPBackend(hostKeyTrust: TrustForSpike())

        print("算法偏好：\(env["SPIKE_PREFS"] ?? "default")")
        print(String(repeating: "-", count: 148))
        print(String(format: "%-7@ %-38@ %-30@ %-22@ %-30@ %-30@ %@",
                     "端口" as NSString, "服务器 banner" as NSString, "kex" as NSString,
                     "host key" as NSString, "cipher(c→s)" as NSString, "mac(c→s)" as NSString,
                     "指纹" as NSString))
        print(String(repeating: "-", count: 148))

        for port in ports {
            let endpoint = Endpoint(host: host, port: port, username: "tester")
            let request = ConnectionRequest(endpoint: endpoint,
                                            authentication: .sshAgent,      // 握手阶段不碰凭据
                                            policy: ConnectionPolicy(connectTimeout: .seconds(10),
                                                                     handshakeTimeout: .seconds(30),
                                                                     algorithms: preferences))
            let connection = backend.makeConnection(request)
            let start = DispatchTime.now()
            do {
                let session = try await connection.handshake()
                let ms = elapsed(start)
                let measure = await measure(of: connection)
                print(String(format: "%-7@ %-38@ %-30@ %-22@ %-30@ %-30@ %@",
                             "\(port)" as NSString, short(session.serverIdentification, 38) as NSString,
                             short(session.algorithms.keyExchange, 30) as NSString,
                             short(session.algorithms.hostKey, 22) as NSString,
                             short(session.algorithms.encryptionClientToServer, 30) as NSString,
                             short(session.algorithms.macClientToServer, 30) as NSString,
                             session.hostKey.fingerprintSHA256 as NSString))
                print(String(format: "        %d ms  EAGAIN=%d poll=%d 超时片=%d 线程=%d  主机密钥 blob=%d B  cipher(s→c)=%@ mac(s→c)=%@",
                             ms, measure?.eagainCount ?? -1, measure?.pollCount ?? -1,
                             measure?.pollTimeoutCount ?? -1, measure?.executorThreads.count ?? -1,
                             session.hostKey.blob.count,
                             session.algorithms.encryptionServerToClient as NSString,
                             session.algorithms.macServerToClient as NSString))
            } catch {
                print(String(format: "%-7@ FAIL %d ms  %@", "\(port)" as NSString, elapsed(start),
                             describe(error) as NSString))
            }
            await connection.close()
        }
        print(String(repeating: "-", count: 148))

        if env["SPIKE_EXPERIMENT"] == "stall" {
            await stallExperiment(backend: backend, host: host)
        }
    }

    /// 只 accept、一个字节都不回的监听 socket。
    ///
    /// 建阶段的取消与超时只在真机慢速链路上才稳定出现，本地 loopback 握手
    /// 几毫秒就完了，量不到切片。这里把"服务器连 banner 都不发"这个状态
    /// 在本地复现一次，代价是要自己写监听。
    private static func stallExperiment(backend: any RemoteBackend, host: String) async {
        let port: UInt16
        do { port = try StallListener.start() } catch { print("黑洞监听起不来：\(error)"); return }

        // 1) 取消：睡 300 ms 让握手确实停在 poll 里，然后置标志。
        let endpoint = Endpoint(host: host, port: Int(port), username: "tester")
        let policy = ConnectionPolicy(connectTimeout: .seconds(5), handshakeTimeout: .seconds(30),
                                      algorithms: .libraryDefault)
        let connection = backend.makeConnection(ConnectionRequest(endpoint: endpoint,
                                                                  authentication: .sshAgent,
                                                                  policy: policy))
        let box = ResultBox()
        let began = DispatchTime.now()
        let task = Task {
            do { _ = try await connection.handshake(); box.finish(ok: true, at: DispatchTime.now()) }
            catch is CancellationError { box.finish(ok: false, at: DispatchTime.now(), note: "CancellationError") }
            catch { box.finish(ok: false, at: DispatchTime.now(), note: describe(error)) }
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        let cancelAt = DispatchTime.now()
        connection.cancel()
        await task.value
        let exitAt = box.at ?? cancelAt
        print("取消实验（服务器不回 banner）：置标志→handshake 抛出 \(ms(cancelAt, exitAt)) ms，"
              + "其中在飞 \(ms(began, exitAt)) ms；\(box.note ?? "")")
        if let measure = await measure(of: connection) {
            print("  EAGAIN=\(measure.eagainCount) poll=\(measure.pollCount) 超时片=\(measure.pollTimeoutCount) "
                  + "线程=\(measure.executorThreads.count)（切片 50 ms，超时片数×50 ≈ 在飞时长）")
        }
        let closeStart = DispatchTime.now()
        await connection.close()
        let closedPhase = await connection.phase
        print("  取消后再调 close() 只花 \(elapsed(closeStart)) ms（phase=\(closedPhase.rawValue)）："
              + "aborted 不补体面关闭，M0a-03 实测那条路要 8 s")

        // 2) 超时：同一条黑洞连接，不取消，让握手预算烧完。
        let timedOut = backend.makeConnection(ConnectionRequest(endpoint: endpoint, authentication: .sshAgent,
                                                                policy: ConnectionPolicy(connectTimeout: .seconds(5),
                                                                                         handshakeTimeout: .milliseconds(300),
                                                                                         algorithms: .libraryDefault)))
        let started = DispatchTime.now()
        do {
            _ = try await timedOut.handshake()
            print("超时实验：没超时，300 ms 预算内握手成了（说明这条链路不是黑洞，实验无效）")
        } catch {
            print("超时实验：\(ms(started, DispatchTime.now())) ms 后抛出 \(describe(error))")
        }
        await timedOut.close()
    }

    private final class ResultBox: @unchecked Sendable {
        var at: DispatchTime?
        var note: String?
        var succeeded = false
        func finish(ok: Bool, at: DispatchTime, note: String = "握手竟然成功") {
            self.at = at
            self.succeeded = ok
            self.note = ok ? nil : note
        }
    }

    /// `measure` 是诊断量，刻意没放进 `RemoteConnection` 契约，所以这里对正式实现做一次向下转型。
    private static func measure(of connection: any RemoteConnection) async -> SFTPConnection.Measure? {
        guard let sftp = connection as? SFTPConnection else { return nil }
        return await sftp.measure
    }

    private static func short(_ text: String, _ width: Int) -> String {
        text.count <= width ? text : String(text.prefix(width - 1)) + "…"
    }

    private static func elapsed(_ start: DispatchTime) -> Int {
        ms(start, DispatchTime.now())
    }

    private static func ms(_ start: DispatchTime, _ end: DispatchTime) -> Int {
        Int(end.uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000
    }

    /// 只报稳定 token 与 libssh2 码，不报文案——分类不许依赖字符串（ErrorTaxonomy 规则 1）。
    private static func describe(_ error: any Error) -> String {
        if let remote = error as? RemoteError {
            var line = remote.diagnosticCode
            if case .operationFailed(let failure) = remote { line += " rc=\(failure.rc)" }
            if case .protocolViolation(let detail) = remote { line += " \(detail)" }
            return line
        }
        return "\(error)"
    }
}

/// `socket/bind/listen` 起一个不回数据的监听端口，端口号由内核选，返回给用户。
enum StallListener {
    private final class Held: @unchecked Sendable {
        var descriptors: [Int32] = []
    }
    private static let held = Held()

    static func start() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HandshakeProbe.Failure(step: "socket", detail: "errno=\(errno)") }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else {
            throw HandshakeProbe.Failure(step: "bind", detail: "errno=\(errno)")
        }
        guard listen(fd, 8) == 0 else {
            throw HandshakeProbe.Failure(step: "listen", detail: "errno=\(errno)")
        }

        var name = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let read = withUnsafeMutablePointer(to: &name) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard read == 0 else { throw HandshakeProbe.Failure(step: "getsockname", detail: "errno=\(errno)") }

        // accept 后不回任何字节，也不关：连接挂在服务器侧，客户端只能等。
        Thread.detachNewThread {
            while true {
                let peer = accept(fd, nil, nil)
                if peer >= 0 { held.descriptors.append(peer) }
            }
        }
        return UInt16(bigEndian: name.sin_port)
    }
}
