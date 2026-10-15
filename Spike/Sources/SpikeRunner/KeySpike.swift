import CLibssh2
import Foundation

/// spike #8：加密后端能不能直接解析 `openssh-key-v1` + bcrypt 私钥。
///
/// 方案 v2.3 的判定是"解析成功则不做 Swift 预解析"。对 Ferry 更关键的是
/// `frommemory`：私钥要从 Keychain 里以字节取出来，只能走内存版本，
/// 所以两个入口都要测。
///
/// 认证对象是 `sftp-modern`，公钥由 `Spike/Scripts/keys.sh` 装进容器。
enum KeySpike {

    struct Candidate {
        let label: String
        let file: String
        let passphrase: String?
    }

    struct Outcome {
        let label: String
        let entry: String
        let rc: Int32
        let ms: Double
        let error: String
        var parsed: Bool {
            // 能进到认证阶段（成功或被拒）说明私钥已解出；
            // 解析失败会在发包前就返回，耗时也是 0 量级。
            rc == 0 || rc == LIBSSH2_ERROR_AUTHENTICATION_FAILED
        }
    }

    static func run() {
        libssh2_init(0)
        defer { libssh2_exit() }

        let endpoint = SpikeProbe.Endpoint.fromEnvironment()
        let env = ProcessInfo.processInfo.environment
        let dir = env["SPIKE_KEY_DIR"] ?? "/tmp/ferry-keys"
        let user = env["SPIKE_KEY_USER"] ?? endpoint.user

        print("libssh2 \(SpikeProbe.version()) -> \(endpoint.host):\(endpoint.port)，crypto backend = \(cryptoEngine())")
        print("私钥目录：\(dir)")

        let candidates: [Candidate] = [
            Candidate(label: "ed25519 openssh格式+bcrypt(有口令)", file: "\(dir)/ed_bcrypt", passphrase: "secret123"),
            Candidate(label: "ed25519 openssh格式(无口令)", file: "\(dir)/ed_plain", passphrase: nil),
            Candidate(label: "rsa3072 openssh格式+bcrypt", file: "\(dir)/rsa_new", passphrase: "secret123"),
            Candidate(label: "ecdsa256 openssh格式+bcrypt", file: "\(dir)/ecdsa_new", passphrase: "secret123"),
            Candidate(label: "rsa2048 老式PEM+口令", file: "\(dir)/rsa_pem", passphrase: "secret123"),
            Candidate(label: "ed25519 口令错误", file: "\(dir)/ed_bcrypt", passphrase: "wrong"),
            Candidate(label: "私钥文件不存在", file: "\(dir)/does-not-exist", passphrase: nil)
        ]

        var outcomes: [Outcome] = []
        for candidate in candidates {
            outcomes.append(contentsOf: probe(endpoint: endpoint, user: user, candidate: candidate))
        }
        report(outcomes)
        agentProbe(endpoint: endpoint)
    }

    static func cryptoEngine() -> String {
        let engine = libssh2_crypto_engine()
        switch engine.rawValue {
        case libssh2_openssl.rawValue: return "openssl"
        case libssh2_gcrypt.rawValue: return "gcrypt"
        case libssh2_mbedtls.rawValue: return "mbedtls"
        case libssh2_wincng.rawValue: return "wincng"
        case libssh2_os400qc3.rawValue: return "os400qc3"
        case libssh2_no_crypto.rawValue: return "无（编译时未接 crypto）"
        default: return "unknown(\(engine.rawValue))"
        }
    }

    /// 同一个私钥分别走 fromfile 与 frommemory；后者是 Ferry 的真实路径。
    static func probe(endpoint: SpikeProbe.Endpoint, user: String, candidate: Candidate) -> [Outcome] {
        var results: [Outcome] = []
        if let data = try? Data(contentsOf: URL(fileURLWithPath: candidate.file)) {
            results.append(auth(endpoint: endpoint, user: user, candidate: candidate,
                                entry: "frommemory", memory: data))
        }
        results.append(auth(endpoint: endpoint, user: user, candidate: candidate,
                            entry: "fromfile", memory: nil))
        return results
    }

    static func auth(endpoint: SpikeProbe.Endpoint, user: String, candidate: Candidate,
                     entry: String, memory: Data?) -> Outcome {
        let label = "\(candidate.label) [\(entry)]"
        guard let (fd, session) = try? SpikeProbe.unauthenticatedSession(endpoint) else {
            return Outcome(label: label, entry: entry, rc: -999, ms: 0, error: "无法建立未认证连接")
        }
        defer { SpikeProbe.shutdown(session: session, fd: fd) }

        let start = Date()
        let rc: Int32 = user.withCString { username in
            if let memory {
                // frommemory 的三个长度参数是 size_t（Swift 里是 Int），username_len 也是
                return memory.withUnsafeBytes { raw in
                    candidate.passphrase.withPassphrase { phrase in
                        libssh2_userauth_publickey_frommemory(session, username, strlen(username),
                                                              nil, 0,
                                                              raw.baseAddress!.assumingMemoryBound(to: CChar.self),
                                                              memory.count, phrase)
                    }
                }
            }
            return candidate.file.withCString { path in
                candidate.passphrase.withPassphrase { phrase in
                    libssh2_userauth_publickey_fromfile_ex(session, username, UInt32(strlen(username)),
                                                           nil, path, phrase)
                }
            }
        }
        let ms = Date().timeIntervalSince(start) * 1000
        return Outcome(label: "\(label)", entry: entry, rc: rc, ms: ms,
                       error: ThroughputSpike.lastSessionError(session))
    }

    static func report(_ outcomes: [Outcome]) {
        print("\n  入口                                             结果   耗时ms   判定   错误")
        for outcome in outcomes {
            let verdict = outcome.parsed ? "可解析" : "解析失败"
            print(String(format: "  %-46@ %8d %8.1f %6@  %@",
                         outcome.label as NSString, outcome.rc, outcome.ms, verdict as NSString,
                         outcome.error as NSString))
        }
    }

    /// 顺带确认 ssh-agent 路径。
    /// 注意：`libssh2_agent_init(NULL)` 会直接段错误——它用 session 的 allocator 分配内存，
    /// 传 nil 进 `_libssh2_calloc` 就炸。这里必须先有一个 session（哪怕没认证）。
    static func agentProbe(endpoint: SpikeProbe.Endpoint) {
        guard let socket = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] else {
            print("\n  SSH_AUTH_SOCK 未设置，agent 路径未测")
            return
        }
        print("\n  SSH_AUTH_SOCK = \(socket)")
        guard let (fd, session) = try? SpikeProbe.unauthenticatedSession(endpoint) else {
            print("    无法建立 session，agent 未测")
            return
        }
        defer { SpikeProbe.shutdown(session: session, fd: fd) }
        guard let agent = libssh2_agent_init(session) else { print("    agent_init 失败"); return }
        defer { libssh2_agent_free(agent) }
        let connectRC = libssh2_agent_connect(agent)
        print("    agent_connect rc=\(connectRC)")
        guard connectRC == 0 else { return }
        let listRC = libssh2_agent_list_identities(agent)
        var count = 0
        if listRC == 0 {
            var identity: UnsafeMutablePointer<libssh2_agent_publickey>?
            while libssh2_agent_get_identity(agent, &identity, nil) == 0 { count += 1 }
        }
        print("    agent_list_identities rc=\(listRC)，可读身份 \(count) 个")
    }
}

extension Optional where Wrapped == String {
    func withPassphrase<R>(_ body: (UnsafePointer<CChar>?) -> R) -> R {
        switch self {
        case let .some(text): return text.withCString(body)
        case nil: return body(nil)
        }
    }
}
