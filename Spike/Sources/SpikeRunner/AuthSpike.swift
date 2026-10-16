import CLibssh2
import Darwin
import FerryBackendsSFTP
import FerryCore
import Foundation

/// M1'-4 用：把认证这一层的**原始事实**打成表——libssh2 回了什么码、服务器列了什么方式、
/// 每一步花了几毫秒。
///
/// 为什么不只在测试里断言就够：测试要的是"实现符合结论"，spike 要的是"结论本身是从
/// 哪台机器上量出来的"。`-48` 和 `-16` 各在哪种私钥格式上出现、`none` 探测到底把
/// banner 吃没吃掉、agent 那条 Unix socket 卡住能卡多久——这些都不是我们能选的，
/// 只能量。测试里写的每个数都能在这里重跑出来。
///
/// 用法（五台服务器要先起着，见 docs/spike/M1-01）：
///   spike auth                                    # ①~④：只读，不改服务器状态
///   SPIKE_EXPERIMENT=tries spike auth             # ⑤：把一条连接的 MaxAuthTries 烧干
///   SPIKE_EXPERIMENT=cancel spike auth            # ⑥：取消落在 bcrypt / kbdint 等待上的延迟
///   SPIKE_EXPERIMENT=stuckagent spike auth        # ⑦：agent 的 socket 应连接但不回话
///
/// ⑤⑥ 会真的消耗服务器侧的认证次数，所以放在开关后面：跑完这一台容器的
/// `tester` 只是被 sshd 记了几次失败，重启容器即清。
///
/// agent 那两节必须跑在临时 agent 里（`Spike/Scripts/ssh-agent-test.sh -- spike auth`）：
/// 本机 `SSH_AUTH_SOCK` 里挂的是真实工作密钥，试出来的密钥列表没有意义（ADR-0000 §9 N4）。
enum AuthSpike {
    private static let goodPassword = "testpass"
    private static let passphrase = "secret123"
    private static let keyDirectory = ProcessInfo.processInfo.environment["SPIKE_KEY_DIR"] ?? "/tmp/ferry-keys"
    private static let ports: [Int] = (ProcessInfo.processInfo.environment["SPIKE_PORTS"] ?? "2201 2202 2203 2204 2205")
        .split(separator: " ").compactMap { Int($0) }

    // MARK: - 入口

    static func run() async {
        let env = ProcessInfo.processInfo.environment
        let host = env["SPIKE_HOST"] ?? "127.0.0.1"
        print("libssh2 \(SpikeProbe.version())，服务器 = \(host) 上的 \(ports.map(String.init).joined(separator: " "))")
        print("私钥目录 \(keyDirectory)，SSH_AUTH_SOCK = \(env["SSH_AUTH_SOCK"] ?? "<未设置>")")

        noneProbeGrid(host: host)
        await privateKeyMatrix(host: host, port: UInt16(env["SPIKE_PORT"] ?? "") ?? 2202)
        await productionMatrix(host: host)
        agentGrid(port: 2202)

        switch env["SPIKE_EXPERIMENT"] {
        case "tries": await maxAuthTriesBurn(host: host, port: 2202)
        case "cancel": await cancelLatency(host: host)
        case "stuckagent": stuckAgent()
        default: print("\n（⑤⑥⑦ 未跑：SPIKE_EXPERIMENT=tries / cancel / stuckagent）")
        }
    }

    // MARK: - ① `none` 探测：列表、指针归属、banner、认证失败之后列表会不会被改写

    private static func noneProbeGrid(host: String) {
        print("\n===== ① none 探测：libssh2_userauth_list / banner / 预算 =====")
        for port in ports {
            let endpoint = SpikeProbe.Endpoint(host: host, port: UInt16(port), user: "tester", password: goodPassword)
            guard let (fd, session) = try? SpikeProbe.unauthenticatedSession(endpoint)
            else { print("  \(port) 握手失败，跳过"); continue }
            defer { SpikeProbe.shutdown(session: session, fd: fd) }

            let first = userList(session, user: "tester")
            let banner = bannerText(session)
            print("  \(port)  第一次 list = \(quote(joined(first.text)))  errno=\(first.errno)  "
                  + "指针=\(address(first.pointer))  authenticated=\(libssh2_userauth_authenticated(session))")
            print("        banner rc=\(banner.rc) 内容=\(quote(banner.text))")

            // 再列一次：缓冲是每次调用重新 ALLOC 的（userauth.c:91），地址每次都变。
            // 更要紧的是这一句本身就是一条 USERAUTH_REQUEST(method=none)，服务器照收照记。
            let second = userList(session, user: "tester")
            print("        第二次 list 指针=\(address(second.pointer)) 内容=\(quote(joined(second.text)))  "
                  + "两次同址 = \(address(second.pointer) == address(first.pointer))")

            // 失败一次之后再列：这一行验的是"清单会被服务器改写"这句话到底对不对。
            let wrongRC = passwordAuth(session, user: "tester", password: "definitely-wrong")
            let afterFailure = userList(session, user: "tester")
            print("        错口令 rc=\(wrongRC) 之后 list = \(quote(joined(afterFailure.text)))  "
                  + "errno=\(afterFailure.errno) 指针=\(address(afterFailure.pointer))  "
                  + "与首次相同 = \(joined(afterFailure.text) == joined(first.text))")

            // 同一台、换一条连接，用一个全新的用户名去列。
            // 不能在同一条连接上换用户名：RFC 4252 §5.1 允许 sshd 直接断开，实测就是断开
            // （"Change of username or service not allowed"），跟用户名存不存在没关系。
            guard let (unknownFD, unknownSession) = try? SpikeProbe.unauthenticatedSession(
                SpikeProbe.Endpoint(host: host, port: UInt16(port), user: "nosuchuser", password: goodPassword))
            else { print("        （换用户名的那条连接起不来）"); continue }
            let unknown = userList(unknownSession, user: "nosuchuser")
            print("        新连接上不存在的用户名 list = \(quote(joined(unknown.text)))  errno=\(unknown.errno)")
            SpikeProbe.shutdown(session: unknownSession, fd: unknownFD)
        }

        // 每列一次就是一次认证尝试——这条用"数到第几次被踢"直接量，不依赖服务器日志。
        if let port = ports.first {
            let endpoint = SpikeProbe.Endpoint(host: "127.0.0.1", port: UInt16(port), user: "tester", password: goodPassword)
            if let (fd, session) = try? SpikeProbe.unauthenticatedSession(endpoint) {
                var counted = 0
                var stopErrno: Int32 = 0
                while counted < 12 {
                    let probe = userList(session, user: "tester")
                    if probe.pointer == nil { stopErrno = probe.errno; break }
                    counted += 1
                }
                print("        连续只调 list（\(port)）：第 \(counted + 1) 次拿到 NULL，errno=\(stopErrno) "
                      + "——`libssh2_userauth_list` 每调一次就是服务器上的一次认证尝试")
                SpikeProbe.shutdown(session: session, fd: fd)
            }
        }
        print("""
            要点：① list 的缓冲归 session，调用方 free 它会在 session_free 时二次释放
            （实测崩过：pointer being freed was not allocated），而且地址每次都变，所以必须在同一趟里抄出字符串；
            ② 这台不要凭据时 list 返回 NULL 而 errno=0，同时 authenticated 已经是真（userauth.c:203）；
            ③ banner 由这次调用吃掉，之后随时可取；
            ④ 五台都没有改写清单（失败之后列出来的还是同一串）——所以正式实现里"认证前先把清单存进
            `AuthenticatedSession.serverOfferedMethods`"这件事，一次探测就够，重试不必再探；
            ⑤ 一条连接上不许换用户名，UI 里改了用户名就得重连。
        """)
    }

    // MARK: - ② 私钥形态 × 口令 → 原始码

    private static func privateKeyMatrix(host: String, port: UInt16) async {
        print("\n===== ② 原始码矩阵：frommemory × 私钥形态 × 口令（\(port)）=====")
        let rows: [(String, String?)] = [
            // `ed_plain + 口令错` 那两格是 UI 会真撞上的形状：密钥本来没加密，
            // 用户却在对话框里填了口令。要看的是 libssh2 是忽略它还是判失败。
            ("ed_plain", nil), ("ed_plain", passphrase), ("ed_plain", "wrong"),
            ("ed_bcrypt", nil), ("ed_bcrypt", passphrase), ("ed_bcrypt", "wrong"),
            ("rsa_new", nil), ("rsa_new", passphrase), ("rsa_new", "wrong"),
            ("ecdsa_new", nil), ("ecdsa_new", passphrase), ("ecdsa_new", "wrong"),
            ("rsa_pem", nil), ("rsa_pem", passphrase), ("rsa_pem", "wrong"),
            ("garbage", nil),
        ]
        print(String(format: "  %-22@ %-10@ %-9@ %-8@ %-6@ %-24@ %@",
                     "语料" as NSString, "头部判定" as NSString, "入口" as NSString,
                     "原始 rc" as NSString, "ms" as NSString, "分类 token" as NSString,
                     "libssh2 文案" as NSString))
        for (name, phrase) in rows {
            let path = "\(keyDirectory)/\(name)"
            let data: Data
            if let loaded = FileManager.default.contents(atPath: path) {
                data = loaded
            } else if name == "garbage" {
                data = Data(Array("this is not a private key at all".utf8))
            } else {
                print("  \(name) 缺语料：\(path)（先跑 Spike/Scripts/keys.sh）")
                continue
            }
            let material = PrivateKeyMaterial(keyData: data, passphrase: phrase)
            let method = taxonomyMethod(passphrase: phrase, encryption: material.encryption)
            let label = "\(name)+\(phrase == nil ? "无口令" : "口令" + (phrase == passphrase ? "对" : "错"))"
            // 两个入口分开量：`frommemory` 是 Ferry 的真实路径（私钥从 Keychain 里以字节取），
            // 但它和 `fromfile` 走的解析函数不是同一个，码可能不同——这一列就是来看这个的。
            let entries: [(String, Bool)] = [("frommemory", true), ("fromfile", name != "garbage")]
            for (entry, exists) in entries {
                guard exists else { continue }
                guard let (fd, session) = try? SpikeProbe.unauthenticatedSession(
                    SpikeProbe.Endpoint(host: host, port: port, user: "tester", password: goodPassword))
                else { print("  \(label) 握手失败"); continue }
                defer { SpikeProbe.shutdown(session: session, fd: fd) }
                let start = DispatchTime.now()
                let rc = "tester".withCString { user in
                    if entry == "frommemory" {
                        return data.withUnsafeBytes { raw in
                            let key = raw.baseAddress!.assumingMemoryBound(to: CChar.self)
                            return phrase.withPassphrase { secret in
                                libssh2_userauth_publickey_frommemory(session, user, strlen(user),
                                                                      nil, 0, key, data.count, secret)
                            }
                        }
                    }
                    return path.withCString { file in
                        phrase.withPassphrase { secret in
                            libssh2_userauth_publickey_fromfile_ex(session, user, UInt32(strlen(user)),
                                                                   nil, file, secret)
                        }
                    }
                }
                let token = ErrorTaxonomy.classifyAuth(rc: rc, method: method).map { $0.diagnosticCode } ?? "（分类器不收）"
                print(String(format: "  %-22@ %-10@ %-9@ %-8d %-6d %-24@ %@",
                             label as NSString, "\(material.encryption)" as NSString, entry as NSString,
                             rc, elapsed(start), token as NSString, lastError(session) as NSString))
            }
        }
        print("""
            要点：这一片格子里没有一格回 `-48`。原因在 openssl.c:4987 的 `_libssh2_pub_priv_keyfilememory`：
            它先让 OpenSSL 自己 `PEM_read_bio_PrivateKey`，读不出来（`openssh-key-v1` 它不认；
            加密 PEM 拿空口令解不开）就转去试 openssh 格式，那条路径里 pem.c:466 确实会返回
            `-48 KEYFILE_AUTH_FAILED`，可调用方只看 `st == 0`，非 0 一律换成
            `-16 FILE` + "Unsupported private key file format"——`-48` 在这一步被丢掉。
            本来能把"口令错"单认出来的那段靠 `HAVE_SSLERROR_BAD_DECRYPT`，我们这份编译产物没定义它。
            `fromfile` 同理，只是文案换成 "Wrong passphrase or invalid/unrecognized private key file format"。
            ⇒ 修正 M0a-05 的说法：`-16` 不是"三件事共用一枚码"，而是"两个入口、四种格式**全都**收成这一枚"。
            头部探针是唯一的分流位置。分类器仍保留 `-48` 那三行：那是 pem.c 写死的事实，
            换 crypto 后端（mbedtls / 无后端）就会回来，留着不会把 `-16` 说错。
        """)
    }

    // MARK: - ③ 正式实现：每种方式在每台服务器上的结果

    private static func productionMatrix(host: String) async {
        print("\n===== ③ 正式实现（SFTPConnection.authenticate）逐台逐方式 =====")
        let backend = SFTPBackend(hostKeyTrust: TrustPass())
        for port in ports {
            let rows: [(String, AuthenticationMethod, (any KeyboardInteractiveResponder)?)] = [
                ("password 对", .password(goodPassword), nil),
                ("password 错", .password("definitely-wrong"), nil),
                ("publickey 明文", .privateKey(material("ed_plain", nil)), nil),
                ("publickey bcrypt+口令", .privateKey(material("ed_bcrypt", passphrase)), nil),
                ("publickey bcrypt 无口令", .privateKey(material("ed_bcrypt", nil)), nil),
                ("keyboard-interactive", .keyboardInteractive, SpikeResponder(log: PromptLog(), answers: {
                    Array(repeating: goodPassword, count: $0.prompts.count)
                })),
                ("ssh-agent", .sshAgent, nil),
            ]
            for (label, authentication, responder) in rows {
                let connection = backend.makeConnection(ConnectionRequest(
                    endpoint: Endpoint(host: host, port: port, username: "tester"),
                    authentication: authentication,
                    policy: ConnectionPolicy(connectTimeout: .seconds(10), handshakeTimeout: .seconds(30),
                                             authenticationTimeout: .seconds(30),
                                             algorithms: HandshakeProbe.legacy)))
                let start = DispatchTime.now()
                var outcome = "ok"
                var detail = ""
                do {
                    _ = try await connection.handshake()
                    let session = try await connection.authenticate(interactive: responder)
                    detail = "线路方式=\(session.method.rawValue) 服务器列过=\(session.serverOfferedMethods.joined(separator: ","))"
                    + (session.agentIdentity.map { " agent 身份=\($0)" } ?? "")
                } catch {
                    outcome = token(error)
                }
                let measure = await measure(of: connection)
                let phase = await connection.phase
                print(String(format: "  %-5@ %-24@ %-26@ %6d ms  phase=%-14@ 尝试=%@ 线程=%@  %@",
                             "\(port)" as NSString, label as NSString, outcome as NSString,
                             elapsed(start), phase.rawValue as NSString,
                             "\(measure?.authAttempts ?? -1)" as NSString,
                             "\(measure?.executorThreads.count ?? -1)" as NSString, detail as NSString))
                await connection.close()
            }
        }
        print("""
            要点：2201 把 keyboard-interactive 列进清单却不问任何问题（userauth.c 那条 INFO_REQUEST
            路径压根没走），空应答换来的 `-18` 报成 badPassword；只有 2205 真问。
            keyboard-interactive 打在 2202/2203/2204 上是 methodNotOffered——依据是服务器自己列的清单。
        """)

        // 失败之后同一条连接还能不能用：这一格决定换个口令要不要重跑密钥交换。
        print("\n  —— 失败后同连接重试（2202）——")
        let connection = backend.makeConnection(ConnectionRequest(
            endpoint: Endpoint(host: host, port: 2202, username: "tester"),
            authentication: .password("definitely-wrong"),
            policy: ConnectionPolicy(connectTimeout: .seconds(10), handshakeTimeout: .seconds(30),
                                     authenticationTimeout: .seconds(30), algorithms: HandshakeProbe.legacy)))
        do {
            _ = try await connection.handshake()
            let failed = DispatchTime.now()
            let first = await outcome { try await connection.authenticate(interactive: nil) }
            print("    第一次（错口令）\(first)  \(elapsed(failed)) ms  phase=\(await connection.phase)")
            let second = DispatchTime.now()
            // 凭据已经定死在 request 里，正式实现没法中途换口令——所以这里只能用
            // 同一个 request 再试一次，验的是"会话还在不在"，不是"换个口令能不能登进来"。
            let result = await outcome { try await connection.authenticate(interactive: nil) }
            print("    第二次同一条连接：\(result)  \(elapsed(second)) ms（没有重新 kex，authAttempts 累计）")
            let measure = await measure(of: connection)
            print("    authAttempts=\(measure?.authAttempts ?? -1) 认证累计=\(measure?.authElapsedMs ?? -1) ms  "
                  + "线程=\(measure?.executorThreads.count ?? -1)")
            await connection.close()
        } catch {
            print("    握手就没过：\(token(error))")
        }
    }

    // MARK: - ④ agent：每一步几毫秒、socket 不在时什么码

    private static func agentGrid(port: Int) {
        print("\n===== ④ ssh-agent：分步计时与失败码 =====")
        guard let (fd, session) = try? SpikeProbe.unauthenticatedSession(
            SpikeProbe.Endpoint(host: "127.0.0.1", port: UInt16(port), user: "tester", password: goodPassword))
        else { print("  握手失败，跳过"); return }
        defer { SpikeProbe.shutdown(session: session, fd: fd) }

        let env = ProcessInfo.processInfo.environment
        if env["SSH_AUTH_SOCK"] != nil {
            timeAgentSteps(session)
        } else {
            print("  SSH_AUTH_SOCK 未设置：agent 主路径未测（用 Spike/Scripts/ssh-agent-test.sh -- spike auth）")
        }

        // 没有 agent 与 agent 在但拒绝服务是两枚码，都得当场验一次：
        // `-39 BAD_USE` 说的是"本机压根没有可用的 agent"（agent.c:182 取不到 socket 名），
        // 报成 keyRejected 会把用户支去查服务器上的 authorized_keys。
        let original = env["SSH_AUTH_SOCK"]
        unsetenv("SSH_AUTH_SOCK")
        guard let agent = libssh2_agent_init(session) else { print("  agent_init 返回 NULL"); return }
        let noSocket = libssh2_agent_connect(agent)
        print("  无 SSH_AUTH_SOCK：agent_connect rc=\(noSocket)  "
              + "token=\(ErrorTaxonomy.classifyAuth(rc: noSocket, method: .agent)?.diagnosticCode ?? "nil")")
        libssh2_agent_free(agent)

        setenv("SSH_AUTH_SOCK", "/tmp/ferry-does-not-exist.sock", 1)
        let dead = libssh2_agent_init(session)
        if let dead {
            let rc = libssh2_agent_connect(dead)
            print("  SSH_AUTH_SOCK 指向不存在的文件：agent_connect rc=\(rc)  last_error=\(quote(lastError(session)))")
            libssh2_agent_free(dead)
        }
        if let original {
            setenv("SSH_AUTH_SOCK", original, 1)
        } else {
            unsetenv("SSH_AUTH_SOCK")
        }
    }

    private static func timeAgentSteps(_ session: OpaquePointer) {
        guard let agent = libssh2_agent_init(session) else { print("  agent_init 返回 NULL"); return }
        defer { libssh2_agent_free(agent) }
        let path = libssh2_agent_get_identity_path(agent).map { String(cString: $0) } ?? "<无>"
        print("  identity_path = \(path)")

        let connectStart = DispatchTime.now()
        let connectRC = libssh2_agent_connect(agent)
        print("  agent_connect rc=\(connectRC)  \(elapsed(connectStart)) ms")
        guard connectRC == 0 else { return }

        let listStart = DispatchTime.now()
        let listRC = libssh2_agent_list_identities(agent)
        print("  agent_list_identities rc=\(listRC)  \(elapsed(listStart)) ms")
        guard listRC == 0 else { return }

        var previous: UnsafeMutablePointer<libssh2_agent_publickey>?
        var index = 0
        while true {
            var store: UnsafeMutablePointer<libssh2_agent_publickey>?
            let step = libssh2_agent_get_identity(agent, &store, previous)
            if step == 1 { break }
            guard step == 0, let identity = store else { print("  get_identity rc=\(step)"); return }
            previous = identity
            index += 1
            let comment = identity.pointee.comment.map { String(cString: $0) } ?? ""
            let start = DispatchTime.now()
            let rc = "tester".withCString { user in libssh2_agent_userauth(agent, user, identity) }
            print(String(format: "  #%d agent_userauth rc=%-5d %6d ms  %@", index, rc, elapsed(start),
                         quote(comment) as NSString))
            if rc == 0 { break }
        }
        print("  一共试了 \(index) 把（第一把过了就停，agent 里实际有两条身份）；"
              + "每把一次 userauth 都是一次完整的 publickey 认证尝试")
    }

    // MARK: - ⑤ MaxAuthTries

    private static func maxAuthTriesBurn(host: String, port: UInt16) async {
        print("\n===== ⑤ 一条连接上连错口令，直到服务器踢人（\(port)）=====")
        let backend = SFTPBackend(hostKeyTrust: TrustPass())
        let connection = backend.makeConnection(ConnectionRequest(
            endpoint: Endpoint(host: host, port: Int(port), username: "tester"),
            authentication: .password("definitely-wrong"),
            policy: ConnectionPolicy(connectTimeout: .seconds(10), handshakeTimeout: .seconds(30),
                                     authenticationTimeout: .seconds(30), algorithms: HandshakeProbe.legacy)))
        do { _ = try await connection.handshake() } catch { print("  握手失败：\(token(error))"); return }
        for attempt in 1...10 {
            let start = DispatchTime.now()
            let result = await outcome { try await connection.authenticate(interactive: nil) }
            let measure = await measure(of: connection)
            print("    #\(attempt) \(result)  \(elapsed(start)) ms  phase=\(await connection.phase.rawValue)  "
                  + "authAttempts=\(measure?.authAttempts ?? -1)")
            if !result.hasPrefix("auth/") { break }
        }
        print("""
            要点：认证失败不拆 transport（ADR-0001 D7 的例外表），于是 MaxAuthTries 是在
            **同一条连接**上烧掉的。`none` 探测自己也占一次，所以上限比 sshd 配置里那个数少一。
            踢人之后拿到的是链路错误而不是 auth token——诊断报告得能分清"你口令错"和"这台把我们断了"。
        """)
        await connection.close()
    }

    // MARK: - ⑥ 取消落在两处 CPU/等待上的延迟

    private static func cancelLatency(host: String) async {
        print("\n===== ⑥ 取消延迟：bcrypt 期间与 kbdint 等待期间 =====")
        let backend = SFTPBackend(hostKeyTrust: TrustPass())

        // 对照：不取消，量一次完整 bcrypt。`authOnly` 只算 authenticate 那一段，
        // 免得把 kex 的几百毫秒混进"口令解密要多久"这个数里。
        let control = await timedAuthenticate(backend: backend, host: host, port: 2202,
                                              authentication: .privateKey(material("ed_bcrypt", passphrase)))
        print("  不取消：认证本身 \(control.authOnly) ms（含 bcrypt 解私钥，纯 CPU 不可打断），"
              + "握手+认证全程 \(control.total) ms")

        // 取消：睡 100 ms 后置标志，那时 C 调用大概率还在 bcrypt 里。
        let connection = backend.makeConnection(ConnectionRequest(
            endpoint: Endpoint(host: host, port: 2202, username: "tester"),
            authentication: .privateKey(material("ed_bcrypt", passphrase)),
            policy: ConnectionPolicy(connectTimeout: .seconds(10), handshakeTimeout: .seconds(30),
                                     authenticationTimeout: .seconds(30), algorithms: HandshakeProbe.legacy)))
        let box = Box()
        let task = Task {
            do {
                _ = try await connection.handshake()
                let r = await outcome { try await connection.authenticate(interactive: nil) }
                box.finish(r)
            } catch { box.finish("handshake " + token(error)) }
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        let at = DispatchTime.now()
        connection.cancel()
        await task.value
        print("  bcrypt 期间置标志 → authenticate 抛出 \(ms(at, box.at ?? at)) ms，结果=\(box.value ?? "<无>")  "
              + "phase=\(await connection.phase.rawValue)")
        print("    这一段是 D3 的已知粒度上限：取消标志只能在 C 调用返回之后被 drive 循环顶部看到，"
              + "bcrypt 那 0.4~0.6 s 打断不了（M0a-03 同一条）。")
        await connection.close()

        // kbdint 等待期间取消：只有 2205 真问问题。
        let slow = SpikeResponder(log: PromptLog()) { _ in
            Thread.sleep(forTimeInterval: 10)
            return ["x"]
        }
        let kbd = backend.makeConnection(ConnectionRequest(
            endpoint: Endpoint(host: host, port: 2205, username: "tester"),
            authentication: .keyboardInteractive,
            policy: ConnectionPolicy(connectTimeout: .seconds(10), handshakeTimeout: .seconds(30),
                                     authenticationTimeout: .seconds(30), algorithms: HandshakeProbe.legacy)))
        let kbdBox = Box()
        let kbdTask = Task {
            do {
                _ = try await kbd.handshake()
                let began = DispatchTime.now()
                let r = await outcome { try await kbd.authenticate(interactive: slow) }
                kbdBox.finish(r, latency: ms(began, DispatchTime.now()))
            } catch { kbdBox.finish("handshake " + token(error)) }
        }
        try? await Task.sleep(nanoseconds: 500_000_000)
        let kbdCancelAt = DispatchTime.now()
        kbd.cancel()
        await kbdTask.value
        print("  用户在答题（这里睡 10 s）时置标志 → \(ms(kbdCancelAt, DispatchTime.now())) ms 后返回，"
              + "结果=\(kbdBox.value ?? "<无>")  整个 authenticate 等了 \(kbdBox.latency ?? -1) ms  "
              + "phase=\(await kbd.phase.rawValue)")
        print("    这一格能按时退出靠的是回调里那条 50 ms 切片等待（ADR-0000 §12 H11），"
              + "代价是服务器已经收到一次空应答，MaxAuthTries 白烧一格。")
        await kbd.close()
    }

    // MARK: - ⑦ agent 的 socket 应连接但不回话

    private static func stuckAgent() {
        print("\n===== ⑦ agent 的 Unix socket 挂着不回话（agent.c:110 那条 not yet implemented）=====")
        let path: String
        do { path = try StuckAgent.start() } catch { print("  起不来：\(error)"); return }
        let saved = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"]
        setenv("SSH_AUTH_SOCK", path, 1)
        guard let (fd, session) = try? SpikeProbe.unauthenticatedSession(
            SpikeProbe.Endpoint(host: "127.0.0.1", port: 2202, user: "tester", password: goodPassword))
        else { print("  握手失败"); return }
        defer { SpikeProbe.shutdown(session: session, fd: fd) }
        guard let agent = libssh2_agent_init(session) else { print("  agent_init 返回 NULL"); return }

        let connected = DispatchTime.now()
        let connectRC = libssh2_agent_connect(agent)
        print("  agent_connect rc=\(connectRC)  \(elapsed(connected)) ms（connect 到监听队列就成功了，不需要对面读）")
        guard connectRC == 0 else { return }

        // 这一句会睡死在 read() 上：没有超时、没有 EAGAIN，取消标志看不见它。
        // 所以只能另起一条线程、在外部等一个上限，量"它到底会不会回来"。
        let gate = DispatchSemaphore(value: 0)
        let step = AgentStep(agent: agent)
        DispatchQueue.global().async {
            step.rc = libssh2_agent_list_identities(step.agent)
            gate.signal()
        }
        let start = DispatchTime.now()
        let returned = gate.wait(timeout: .now() + .seconds(5)) == .success
        let verdict = returned ? "\(elapsed(start)) ms 后返回 rc=\(step.rc)"
            : "5000 ms 没返回：判定为无限阻塞（socket 是阻塞的，libssh2 不给超时）"
        print("  agent_list_identities \(verdict)")
        print("""
            结论：agent 路上"置标志到停下"的粒度不是 50 ms，而是"等这一步自己回来"。
            本期不修（要修得换成自己的 agent 协议实现），出口标准里明写这条上限，见 M1-04 §6。
        """)
        if let saved { setenv("SSH_AUTH_SOCK", saved, 1) } else { unsetenv("SSH_AUTH_SOCK") }
        unlink(path)
        // 那条线程还在 read() 里睡，只能直接结束进程——libssh2_agent_free 会先 disconnect
        // （也是阻塞的），在这里调它就是自杀。
        exit(0)
    }

    // MARK: - 夹具

    private struct TrustPass: HostKeyTrust {
        func evaluate(endpoint: Endpoint, hostKey: HostKey) async throws {}
    }

    private actor PromptLog {
        private(set) var requests: [KeyboardInteractiveRequest] = []
        func note(_ request: KeyboardInteractiveRequest) { requests.append(request) }
    }

    private struct SpikeResponder: KeyboardInteractiveResponder {
        let log: PromptLog
        let answers: @Sendable (KeyboardInteractiveRequest) -> [String]?

        func respond(to request: KeyboardInteractiveRequest) async -> [String]? {
            await log.note(request)
            return answers(request)
        }
    }

    private final class Box: @unchecked Sendable {
        var value: String?
        var at: DispatchTime?
        var latency: Int?
        func finish(_ value: String) { self.value = value; self.at = DispatchTime.now() }
        func finish(_ value: String, latency: Int) { self.value = value; self.at = DispatchTime.now(); self.latency = latency }
    }

    /// ⑦ 用：`OpaquePointer` 不是 Sendable，而那条线程可能永远不回来，
    /// 主线程等 5 秒就要读这个值——所以照旧上锁，指针本身只是转交一次、不再并发改。
    private final class AgentStep: @unchecked Sendable {
        let agent: OpaquePointer
        private let lock = NSLock()
        private var stored: Int32 = 999
        init(agent: OpaquePointer) { self.agent = agent }
        var rc: Int32 {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    private static func timedAuthenticate(backend: any RemoteBackend, host: String, port: UInt16,
                                          authentication: AuthenticationMethod) async -> (total: Int, authOnly: Int) {
        let connection = backend.makeConnection(ConnectionRequest(
            endpoint: Endpoint(host: host, port: Int(port), username: "tester"),
            authentication: authentication,
            policy: ConnectionPolicy(connectTimeout: .seconds(10), handshakeTimeout: .seconds(30),
                                     authenticationTimeout: .seconds(30), algorithms: HandshakeProbe.legacy)))
        let start = DispatchTime.now()
        do {
            _ = try await connection.handshake()
            _ = try await connection.authenticate(interactive: nil)
            // 这条连接是新建的，`authElapsedMs` 就是从这一次 authenticate 累起来的。
            let authOnly = Int(await measure(of: connection)?.authElapsedMs ?? -1)
            await connection.close()
            return (elapsed(start), authOnly)
        } catch {
            await connection.close()
            return (elapsed(start), -1)
        }
    }

    private static func keyDataOrNil(_ name: String) -> Data? {
        FileManager.default.contents(atPath: "\(keyDirectory)/\(name)")
    }

    /// 语料缺失时给一份空字节：正式实现对空密钥材料在碰网络之前就抛 `localIO/readFailed`，
    /// 表里那一行会直说"缺语料"而不是连不上。
    private static func material(_ name: String, _ phrase: String?) -> PrivateKeyMaterial {
        PrivateKeyMaterial(keyData: keyDataOrNil(name) ?? Data(), passphrase: phrase)
    }

    private static func measure(of connection: any RemoteConnection) async -> SFTPConnection.Measure? {
        guard let sftp = connection as? SFTPConnection else { return nil }
        return await sftp.measure
    }

    private static func outcome(_ body: () async throws -> some Any) async -> String {
        do { _ = try await body(); return "ok" }
        catch is CancellationError { return "cancelled" }
        catch let error as RemoteError { return error.diagnosticCode }
        catch { return "other(\(error))" }
    }

    /// 分类器只认 `ErrorTaxonomy.AuthMethod`，正式实现里这一步在 `taxonomyMethod(for:)`。
    /// spike 要独立复现，所以照同一条规则再写一遍——两处不一致时，测试会先炸。
    private static func taxonomyMethod(passphrase: String?, encryption: PrivateKeyEncryption)
        -> ErrorTaxonomy.AuthMethod {
        switch (passphrase != nil, encryption) {
        case (true, _): return .encryptedKey
        case (false, .encrypted): return .encryptedKeyWithoutPassphrase
        case (false, .plain), (false, .unrecognized): return .plainKey
        }
    }

    // MARK: - 原始调用小工具

    private static func userList(_ session: OpaquePointer, user: String)
        -> (text: [String], errno: Int32, pointer: UnsafeMutablePointer<CChar>?) {
        var captured: UnsafeMutablePointer<CChar>?
        let rc = user.withCString { name in
            let pointer = libssh2_userauth_list(session, name, UInt32(strlen(name)))
            captured = pointer
            return pointer != nil ? Int32(0) : libssh2_session_last_errno(session)
        }
        guard rc == 0, let captured else {
            return ([], rc, captured)
        }
        // 必须现在就抄出来：这块缓冲下一次调用就会被覆写，而且它归 session。
        return (String(cString: captured).split(separator: ",").map(String.init), 0, captured)
    }

    private static func passwordAuth(_ session: OpaquePointer, user: String, password: String) -> Int32 {
        user.withCString { name in
            password.withCString { secret in
                libssh2_userauth_password_ex(session, name, UInt32(strlen(name)),
                                             secret, UInt32(strlen(secret)), nil)
            }
        }
    }

    private static func bannerText(_ session: OpaquePointer) -> (rc: Int32, text: String) {
        var pointer: UnsafeMutablePointer<CChar>?
        let rc = libssh2_userauth_banner(session, &pointer)
        return (rc, pointer.map { String(cString: $0) } ?? "")
    }

    private static func lastError(_ session: OpaquePointer) -> String {
        var pointer: UnsafeMutablePointer<CChar>?
        libssh2_session_last_error(session, &pointer, nil, 0)
        return pointer.map { String(cString: $0) } ?? "<无消息>"
    }

    private static func joined(_ items: [String]) -> String { items.joined(separator: ",") }

    private static func quote(_ text: String) -> String { text.isEmpty ? "<空>" : "「\(text)」" }

    private static func address(_ pointer: UnsafeMutablePointer<CChar>?) -> String {
        // 指针自己的 description 就是十六进制地址；两次调用之间它可能已经变了，
        // 但地址值抄下来就还是"当时那块缓冲"，够用。
        pointer.map { "\($0)" } ?? "nil"
    }

    private static func token(_ error: any Error) -> String {
        if let remote = error as? RemoteError { return remote.diagnosticCode }
        if error is CancellationError { return "cancelled" }
        return "\(error)"
    }

    private static func elapsed(_ start: DispatchTime) -> Int { ms(start, DispatchTime.now()) }

    private static func ms(_ start: DispatchTime, _ end: DispatchTime) -> Int {
        Int(end.uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000
    }
}

/// 只 accept、一个字节都不回的 Unix socket，用来复现"agent 在、但它不答话"。
private enum StuckAgent {
    private final class Held: @unchecked Sendable {
        var descriptors: [Int32] = []
    }
    private static let held = Held()

    static func start() throws -> String {
        let path = "/tmp/ferry-stuck-agent-\(getpid()).sock"
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SpikeProbe.Failure(step: "unix socket", code: Int32(errno)) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw SpikeProbe.Failure(step: "path 太长", code: -1)
        }
        withUnsafeMutablePointer(to: &address.sun_path.0) { slot in
            bytes.withUnsafeBytes { source in
                _ = memcpy(slot, source.baseAddress, source.count)
            }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { throw SpikeProbe.Failure(step: "bind \(path)", code: Int32(errno)) }
        guard listen(fd, 4) == 0 else { throw SpikeProbe.Failure(step: "listen", code: Int32(errno)) }
        Thread.detachNewThread {
            while true {
                let peer = accept(fd, nil, nil)
                if peer >= 0 { held.descriptors.append(peer) }
            }
        }
        return path
    }
}
