import CLibssh2
import Darwin
import FerryCore
import Foundation
import os

/// libssh2 的会话层错误码，认证这段要用到的几枚。
///
/// `ErrorTaxonomy` 里同名的常量是模块内部的（Core 不该被后端反向依赖），
/// 而这里要在 agent 循环里做"这把不换下一把"的判断——那是流程，不是分类，
/// 所以后端自己留一份。编号出处 libssh2.h:529-592（1.11.1）。
private enum SessionCode {
    static let authenticationFailed: Int32 = -18
    static let publicKeyUnverified: Int32 = -19
}

/// 挂在 `session->abstract` 上的连接级上下文。
///
/// 除了 `cancel`（本来就允许跨线程置位），全部字段只在 session 那条串行 executor 上读写：
/// actor 保证同一时刻只有一个 `authenticate()` 在跑，而 C 回调就嵌在这次调用里面。
/// 标 `@unchecked Sendable` 是必须的——回调签名由 libssh2 的宏定死，
/// 拿不到 actor 隔离证明，只能把这条纪律写在这儿。
final class SessionContext: @unchecked Sendable {
    let endpoint: Endpoint
    let cancel: CancellationFlag

    /// 这一次 `authenticate()` 的应答者。
    var interactive: (any KeyboardInteractiveResponder)?
    /// 等用户答题累计的毫秒数。`SessionLoop` 的网络预算要把它扣掉，
    /// 否则"用户找验证码 40 秒"会被算成网络超时（M1-04 §4）。
    var waitedMs: Int64 = 0
    /// 等待期间取消标志被置位。
    var cancelledDuringPrompt = false
    /// 用户关掉对话框、一条没答。与取消同形：抛 `CancellationError`，
    /// 不许报成"口令错"（ADR-0000 §11 H6 的同一个理由）。
    var declinedPrompt = false
    /// 应答条数与询问条数不符，记下两边各是几条：这条违规的唯一线索就是这两个数。
    var mismatchedPromptCount: (expected: Int, got: Int)?
    /// D7 的可证伪版本：证明回调落在 session 自己那条线程上。
    var promptThreadIDs: Set<UInt64> = []

    init(endpoint: Endpoint, cancel: CancellationFlag) {
        self.endpoint = endpoint
        self.cancel = cancel
    }

    /// 回调拿到的 `abstract` 是 `&session->abstract`（userauth.c:2251），
    /// 槽里存的才是 `libssh2_session_init_ex` 第 4 参放进来的那个盒子
    /// ——`session.c:469` 是 `session->abstract = abstract`，直接存值、不解引用。
    static func from(abstract: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> SessionContext? {
        guard let box = abstract?.pointee else { return nil }
        return Unmanaged<SessionContext>.fromOpaque(box).takeUnretainedValue()
    }
}

/// 应答者那条 Task 与 session 线程之间的交接点。
///
/// 信号量的 wait/signal 本来就能建立顺序，但这条仓库的规矩是不靠隐式顺序碰普通变量
/// （见 `CancellationFlag` 的注释），所以照旧上锁。
private final class PromptWait: @unchecked Sendable {
    enum Outcome: Sendable {
        case answered([String])
        case declined
    }

    let gate = DispatchSemaphore(value: 0)
    private let lock = OSAllocatedUnfairLock(initialState: Outcome?.none)

    var outcome: Outcome? { lock.withLock { $0 } }

    func finish(_ result: Outcome) {
        lock.withLock { $0 = result }
        gate.signal()
    }
}

/// keyboard-interactive 的应答回调。签名是 `LIBSSH2_USERAUTH_KBDINT_RESPONSE_FUNC`
/// 这个宏展开出来的（libssh2.h:314-318），Swift 只能照着写；libssh2 会在
/// `libssh2_userauth_keyboard_interactive_ex` **里面**、每收到一轮
/// `USERAUTH_INFO_REQUEST` 同步调一次（userauth.c:2247 起）。
///
/// 这里必须交出一个已经填好的答案，而 UI 是异步的——于是把 session 线程睡住，
/// 每 50 ms 一个切片回顶部查取消（ADR-0000 §12 H11）。取消或用户关框时**不填应答**：
/// 回调没有"返回错误"这条路，libssh2 会把 CALLOC 出来的空槽原样发出去
/// （`_libssh2_store_str` 对长度 0 直接跳过 memcpy，misc.c:289），
/// 所以取消最坏情况是给服务器记一次失败认证；真实代价见 M1-04 §4.3。
///
/// 参数类型逐个抄自编译器打印的导入结果：`void **abstract` 落成
/// `UnsafeMutablePointer<UnsafeMutableRawPointer?>?`，两个长度和 `num_prompts` 都是 `int`，
/// 所以是 `Int32`（libssh2.h 里紧跟着就有一条 FIXME 说这些该改成 size_t）。
/// 函数本身不写 `@convention(c)`：那只能修饰类型；只要参数与返回值都是 C 可表达类型，
/// 函数引用传给 `libssh2_userauth_keyboard_interactive_ex` 时自动落成一条 C 指针。
private func ferryKeyboardInteractiveResponse(
    name: UnsafePointer<CChar>?,
    nameLen: Int32,
    instruction: UnsafePointer<CChar>?,
    instructionLen: Int32,
    numPrompts: Int32,
    prompts: UnsafePointer<LIBSSH2_USERAUTH_KBDINT_PROMPT>?,
    responses: UnsafeMutablePointer<LIBSSH2_USERAUTH_KBDINT_RESPONSE>?,
    abstract: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) {
    guard numPrompts > 0, let prompts, let responses,
          let context = SessionContext.from(abstract: abstract),
          let responder = context.interactive else { return }

    context.promptThreadIDs.insert(currentThreadID())
    let startedAt = uptimeMilliseconds()
    defer { context.waitedMs += uptimeMilliseconds() - startedAt }

    func text(_ pointer: UnsafePointer<CChar>?, length: Int32) -> String {
        guard let pointer, length > 0 else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: pointer, count: Int(length)), as: UTF8.self)
    }

    var items: [KeyboardInteractivePrompt] = []
    items.reserveCapacity(Int(numPrompts))
    for index in 0..<Int(numPrompts) {
        let prompt = prompts[index]
        let body = prompt.text.map {
            String(decoding: UnsafeRawBufferPointer(start: $0, count: prompt.length), as: UTF8.self)
        } ?? ""
        items.append(KeyboardInteractivePrompt(text: body, echo: prompt.echo != 0))
    }

    let ask = KeyboardInteractiveRequest(endpoint: context.endpoint,
                                         name: text(name, length: nameLen),
                                         instruction: text(instruction, length: instructionLen),
                                         prompts: items)

    let wait = PromptWait()
    // detached 是必需的：`Task {}` 会继承当前执行器，而我们现在正站在 session 那条
    // 串行 executor 上——回调把这条线程睡了，继承过去的 Task 永远排不上，自己等自己。
    Task.detached(priority: .userInitiated) {
        let answers = await responder.respond(to: ask)
        wait.finish(answers.map { .answered($0) } ?? .declined)
    }

    let slice = Int(TCPStream.pollSliceMs)
    while true {
        if wait.gate.wait(timeout: .now() + .milliseconds(slice)) == .success { break }
        if context.cancel.isSet {
            context.cancelledDuringPrompt = true
            return
        }
    }

    switch wait.outcome {
    case .none, .some(.declined):
        context.declinedPrompt = true
    case .some(.answered(let answers)):
        guard answers.count == Int(numPrompts) else {
            context.mismatchedPromptCount = (Int(numPrompts), answers.count)
            return
        }
        for (index, answer) in answers.enumerated() {
            fill(&responses[index], with: answer)
        }
    }
}

/// 填一条应答。内存归 libssh2：回调返回后它按 `LIBSSH2_FREE` 回收
/// （userauth.c:2347），而默认分配器就是 `free`（session.c:71-88），所以这里必须用 `malloc`。
private func fill(_ slot: inout LIBSSH2_USERAUTH_KBDINT_RESPONSE, with answer: String) {
    let bytes = Array(answer.utf8)
    guard !bytes.isEmpty else {
        slot.text = nil
        slot.length = 0
        return
    }
    guard let buffer = malloc(bytes.count) else {
        slot.text = nil
        slot.length = 0
        return
    }
    bytes.withUnsafeBytes { source in
        buffer.copyMemory(from: source.baseAddress!, byteCount: bytes.count)
    }
    slot.text = buffer.assumingMemoryBound(to: CChar.self)
    slot.length = UInt32(bytes.count)
}

extension SFTPConnection {
    /// agent 里挂十几把钥匙是常态，而 OpenSSH 默认 `MaxAuthTries 6`：
    /// 不设上限就是把服务器打到 "Too many authentication failures" 主动断线，
    /// 下次连接还得从零再来。留一格给分类本身。
    static let agentAttemptLimit = 5

    public func authenticate(interactive: (any KeyboardInteractiveResponder)?) async throws
        -> AuthenticatedSession
    {
        switch state {
        case .idle, .connecting:
            throw RemoteError.protocolViolation("还没握手就发起认证（phase=\(state.rawValue)）")
        case .aborted, .closed:
            throw RemoteError.network(.connectionLost)
        case .authenticated:
            // 幂等：认证过了的连接不该再发一次凭据。
            guard let authenticated else {
                throw RemoteError.protocolViolation("phase=authenticated 但没有认证结果")
            }
            return authenticated
        case .ready:
            break
        }

        // 下面两格都在碰网络之前判：凭据都没准备好，不该让服务器看见半截请求，
        // 也不该因此拆掉一条谈好的 transport。
        if case .keyboardInteractive = request.authentication, interactive == nil {
            throw RemoteError.protocolViolation("选了 keyboard-interactive 却没给应答者")
        }
        if case .privateKey(let material) = request.authentication, material.keyData.isEmpty {
            throw RemoteError.localIO(.readFailed)
        }

        guard let handle = session, let context else {
            throw RemoteError.protocolViolation("phase=ready 但 session 已经不在了")
        }

        let start = uptimeMilliseconds()
        do {
            let result = try performAuthentication(handle: handle, context: context, interactive: interactive)
            authElapsedMs += uptimeMilliseconds() - start
            authenticated = result
            state = .authenticated
            return result
        } catch {
            authElapsedMs += uptimeMilliseconds() - start
            if !keepsSessionAfter(error) {
                hardTeardown()
                state = .aborted
            }
            throw error
        }
    }

    /// 凭据不对不拆会话：换个口令再调一次就行，免掉 TCP 建连、密钥交换和那次 `none` 探测
    /// （M1-04 §2.2）。bcrypt 那一轮 0.4–0.6 s 省不掉，它按调用计费（M0b-03 §6、M1-04 §3.1）。
    /// 取消、超时、socket 断了是链路的事，transport 状态不可信，只能硬拆。
    private func keepsSessionAfter(_ error: Error) -> Bool {
        guard let error = error as? RemoteError else { return false }
        switch error {
        case .auth, .localIO: return true
        default: return false
        }
    }

    private func performAuthentication(handle: OpaquePointer, context: SessionContext,
                                       interactive: (any KeyboardInteractiveResponder)?) throws
        -> AuthenticatedSession
    {
        visitedThreads.insert(currentThreadID())
        context.interactive = interactive
        // 认证失败不拆会话，于是同一条 session 会二次进入这里。这几格都是上一次尝试的
        // 事实，留着的话第二次尝试一进门就会被自己的旧记录判成"用户没答"。
        context.waitedMs = 0
        context.cancelledDuringPrompt = false
        context.declinedPrompt = false
        context.mismatchedPromptCount = nil
        defer {
            visitedThreads.formUnion(context.promptThreadIDs)
            context.interactive = nil
            context.promptThreadIDs.removeAll()
        }

        let budget = milliseconds(of: request.policy.authenticationTimeout)
        var loop = SessionLoop(fd: fd, session: handle, cancel: cancelFlag, stats: loopStats)

        // 清单只探一次就存下来：`libssh2_userauth_list` 每调一次都是一条
        // `USERAUTH_REQUEST(method=none)`，服务器把它记成一次认证尝试（M1-04 §1.4 实测：
        // 连续只调它，第 7 次被 `MaxAuthTries 6` 踢）。认证失败不拆会话，
        // 所以重试若每次都重探，用户能犯的口令错误就从 5 次缩到 3 次（M1-04 §2.3 前后对比）。
        let offered: [String]
        if let cached = offeredMethods {
            offered = cached
        } else {
            let probed = try serverOfferedMethods(handle: handle, loop: &loop, budget: budget)
            offered = probed
            offeredMethods = probed
        }
        if libssh2_userauth_authenticated(handle) != 0 {
            // `none` 探测就把服务器哄好了：用户填的凭据一个字节都没发出去，
            // 所以这条路记成 `none`，不许冒充 password/publickey。
            return AuthenticatedSession(method: .none, serverOfferedMethods: offered)
        }

        switch request.authentication {
        case .password:
            try requireMethod("password", offered: offered)
            let rc = try drivePassword(handle: handle, loop: &loop, budget: budget)
            return try finish(handle: handle, rc: rc, method: .password, context: context,
                              offered: offered, agentIdentity: nil)
        case .privateKey(let material):
            try requireMethod("publickey", offered: offered)
            let rc = try drivePublicKey(handle: handle, loop: &loop, budget: budget, material: material)
            return try finish(handle: handle, rc: rc, method: taxonomyMethod(for: material),
                              context: context, offered: offered, agentIdentity: nil)
        case .keyboardInteractive:
            try requireMethod("keyboard-interactive", offered: offered)
            let rc = try driveKeyboardInteractive(handle: handle, loop: &loop, budget: budget, context: context)
            return try finish(handle: handle, rc: rc, method: .keyboardInteractive, context: context,
                              offered: offered, agentIdentity: nil)
        case .sshAgent:
            try requireMethod("publickey", offered: offered)
            return try driveAgent(handle: handle, loop: &loop, budget: budget,
                                  context: context, offered: offered)
        }
    }

    /// 认证前的那次 `none` 探测：服务器在 `USERAUTH_FAILURE` 里列出的可用方式。
    ///
    /// `libssh2_userauth_list` 返回 NULL 有两种意思，必须靠 `last_errno` 分开：
    /// EAGAIN（非阻塞下要重试，`drive` 负责）和真的失败。还有第三种——
    /// 服务器直接给了 SUCCESS，此时 NULL 配 errno 0，而 `authenticated` 已经是真
    /// （userauth.c:330 起的 none 探测路径）。
    /// 顺带一个副作用：这条调用会把 `USERAUTH_BANNER` 吃掉存进 session，
    /// `libssh2_userauth_banner()` 之后还能取，本期不取（M1-04 §8 待核 22）。
    private func serverOfferedMethods(handle: OpaquePointer, loop: inout SessionLoop,
                                      budget: Int64) throws -> [String] {
        let username = request.endpoint.username
        var list: UnsafeMutablePointer<CChar>?
        let rc = try loop.drive(deadlineMs: budget) {
            username.withCString { name in
                let pointer = libssh2_userauth_list(handle, name, UInt32(strlen(name)))
                list = pointer
                return pointer != nil ? 0 : Int32(libssh2_session_last_errno(handle))
            }
        }
        // 这块缓冲**不归我们**：`libssh2_userauth_list` 返回的就是 `session->userauth_list_data`
        // 本身（userauth.c:230），而 `libssh2_session_free` 收尾时会再放一次（session.c:1059）。
        // 调用方 free 它 = 让 session 揣着一个悬垂指针，等到关闭时炸成
        // "pointer being freed was not allocated"。man page 那句 "internally managed by libssh2"
        // 就是这个意思，所以只读、只在这一趟里把字符串抄出来。
        guard rc == 0 else { throw authFailure(rc, method: .password) }
        guard let list else { return [] }   // errno 0 + NULL：none 被接受，没有列表可读
        return String(cString: list).split(separator: ",").map { String($0) }
    }

    private func requireMethod(_ wire: String, offered: [String]) throws {
        guard !offered.isEmpty, !offered.contains(wire) else { return }
        // 依据是服务器自己列的清单，不是错误码——所以这条可以直说"这台不用这种方式"，
        // 而不是让用户去怀疑他打错了口令。
        throw RemoteError.auth(.methodNotOffered)
    }

    private func drivePassword(handle: OpaquePointer, loop: inout SessionLoop, budget: Int64) throws -> Int32 {
        let username = request.endpoint.username
        guard case .password(let password) = request.authentication else {
            throw RemoteError.protocolViolation("drivePassword 配上了别的认证方式")
        }
        authAttempts += 1
        return try loop.drive(deadlineMs: budget) {
            username.withCString { name in
                password.withCString { secret in
                    libssh2_userauth_password_ex(handle, name, UInt32(strlen(name)),
                                                 secret, UInt32(strlen(secret)), nil)
                }
            }
        }
    }

    /// 私钥走 `frommemory`：Swift 层不做任何预解密，`openssh-key-v1` + bcrypt
    /// 和老式 PEM 都由 libssh2 自己认（M0a-05 结论 1/5，ADR-0000 I1）。
    /// 口令为 nil 时传 NULL，libssh2 内部换成空串（userauth.c:2035 起）。
    private func drivePublicKey(handle: OpaquePointer, loop: inout SessionLoop, budget: Int64,
                                material: PrivateKeyMaterial) throws -> Int32 {
        let username = request.endpoint.username
        authAttempts += 1
        let keySize = material.keyData.count
        return try loop.drive(deadlineMs: budget) {
            username.withCString { name in
                material.keyData.withUnsafeBytes { raw in
                    let key = raw.baseAddress!.assumingMemoryBound(to: CChar.self)
                    switch material.passphrase {
                    case .none:
                        return libssh2_userauth_publickey_frommemory(handle, name, strlen(name),
                                                                     nil, 0, key, keySize, nil)
                    case .some(let phrase):
                        return phrase.withCString { secret in
                            libssh2_userauth_publickey_frommemory(handle, name, strlen(name),
                                                                  nil, 0, key, keySize, secret)
                        }
                    }
                }
            }
        }
    }

    private func driveKeyboardInteractive(handle: OpaquePointer, loop: inout SessionLoop, budget: Int64,
                                          context: SessionContext) throws -> Int32 {
        let username = request.endpoint.username
        authAttempts += 1
        // `pausedMs`：等用户答题的那段不占用网络预算，但取消检查照旧（H11）。
        return try loop.drive(deadlineMs: budget, pausedMs: { context.waitedMs }) {
            username.withCString { name in
                libssh2_userauth_keyboard_interactive_ex(handle, name, UInt32(strlen(name)),
                                                         ferryKeyboardInteractiveResponse)
            }
        }
    }

    /// agent 路径。三件事决定了它的形状：
    /// 1. `libssh2_agent_init` 必须挂在已存在的 session 上，传 NULL 直接段错误（M0a-05 结论 4）；
    /// 2. 只有 `libssh2_agent_userauth` 是 BLOCK_ADJUST（agent.c:901），它的 EAGAIN 指的是
    ///    SSH socket，所以照样能用 `SessionLoop`；`connect` 与 `list_identities`
    ///    走 agent 的 Unix socket，而那条 socket 是阻塞的（agent.c:110 明写"not yet implemented"），
    ///    取消只能等它自己回来——这是本期已知的取消粒度上限（M1-04 §6）。
    /// 3. 一把被拒就换下一把，直到上限：服务器不会因为我们有 agent 就多给机会。
    private func driveAgent(handle: OpaquePointer, loop: inout SessionLoop, budget: Int64,
                            context: SessionContext, offered: [String]) throws -> AuthenticatedSession {
        guard let agent = libssh2_agent_init(handle) else {
            throw RemoteError.operationFailed(OperationFailure(kind: .undetermined,
                                                               operation: .authenticate, path: nil, rc: -1))
        }
        // `libssh2_agent_free` 内部先 disconnect 再释放身份列表（agent.c:983-995），
        // 所以这一条 defer 就够，不需要单独配对。
        defer { libssh2_agent_free(agent) }

        // connect/list 这两步的码要先过 `classifyAuth`：`-39 BAD_USE` 在这条路上说的是
        // "本机没有可用的 agent"（agent.c:182 就是从环境里取不到 socket 名），
        // 报成 keyRejected 会把用户支去查服务器上的 authorized_keys。其余码照旧走会话层。
        let connectRC = libssh2_agent_connect(agent)
        guard connectRC == 0 else { throw authFailure(connectRC, method: .agent) }

        let listRC = libssh2_agent_list_identities(agent)
        guard listRC == 0 else { throw authFailure(listRC, method: .agent) }

        let username = request.endpoint.username
        var previous: UnsafeMutablePointer<libssh2_agent_publickey>?
        var tried = 0
        var lastRC: Int32 = SessionCode.publicKeyUnverified

        while true {
            var store: UnsafeMutablePointer<libssh2_agent_publickey>?
            let step = libssh2_agent_get_identity(agent, &store, previous)
            if step == 1 { break }                       // 列表走完，一把都没成
            guard step == 0, let identity = store else { throw authFailure(Int32(step), method: .agent) }
            previous = identity

            tried += 1
            if tried > Self.agentAttemptLimit { throw RemoteError.auth(.tooManyAuthAttempts) }
            authAttempts += 1

            let rc = try loop.drive(deadlineMs: budget) {
                username.withCString { name in
                    libssh2_agent_userauth(agent, name, identity)
                }
            }
            lastRC = rc
            // -19 = 查询阶段服务器就不要这把，-18 = 签名之后被拒：两者都只是"这把不对"，
            // agent 里还有下一把，继续试。别的码（socket 断、算法不支持）不是"换一把"能解决的。
            guard rc == SessionCode.publicKeyUnverified || rc == SessionCode.authenticationFailed else {
                return try finish(handle: handle, rc: rc, method: .agent, context: context,
                                  offered: offered, agentIdentity: describe(identity))
            }
        }
        // 全试完都不认。`-19` 是这条路上最常见的那个码，分类结果就是 keyRejected。
        return try finish(handle: handle, rc: lastRC, method: .agent, context: context,
                          offered: offered, agentIdentity: nil)
    }

    /// agent 里那条身份的可用名字。libssh2 只给 `comment`（`ssh-add` 里那一串），
    /// 没有算法名和指纹；空 comment 就退回 blob 长度，总之要能在诊断报告里指认是哪把。
    private func describe(_ identity: UnsafeMutablePointer<libssh2_agent_publickey>) -> String {
        let pointee = identity.pointee
        if let comment = pointee.comment {
            let text = String(cString: comment)
            if !text.isEmpty { return text }
        }
        return "blob \(pointee.blob_len) B"
    }

    /// 口令错、"这把是加密的但你没给口令"、"这串字节不是私钥"在 libssh2 那里都是 `-16`
    /// （M0a-05 结论 6）。所以分哪一格要看两件事实：带没带口令、头部说这把是不是加密的。
    private func taxonomyMethod(for material: PrivateKeyMaterial) -> ErrorTaxonomy.AuthMethod {
        switch (material.passphrase != nil, material.encryption) {
        case (true, _): return .encryptedKey
        case (false, .encrypted): return .encryptedKeyWithoutPassphrase
        case (false, .plain), (false, .unrecognized): return .plainKey
        }
    }

    /// 成功与失败都收在这一个出口，顺序要紧：
    /// 先看回调里留下的"用户没答"标志，再分类 `rc`。
    /// 反过来的话那条空应答换来的 `-18` 会被报成"口令错"——那是谎报。
    private func finish(handle: OpaquePointer, rc: Int32, method: ErrorTaxonomy.AuthMethod,
                        context: SessionContext, offered: [String],
                        agentIdentity: String?) throws -> AuthenticatedSession {
        if context.cancelledDuringPrompt || context.declinedPrompt { throw CancellationError() }
        if let mismatch = context.mismatchedPromptCount {
            throw RemoteError.protocolViolation("keyboard-interactive 应答 \(mismatch.got) 条，"
                                                + "服务器问了 \(mismatch.expected) 条")
        }
        guard rc == 0 else { throw authFailure(rc, method: method) }
        guard libssh2_userauth_authenticated(handle) != 0 else {
            throw RemoteError.protocolViolation("userauth 回 0 但 session 说自己没认证")
        }
        let wire: AuthenticatedMethod = switch method {
        case .password: .password
        case .agent: .agent
        case .keyboardInteractive: .keyboardInteractive
        case .encryptedKey, .plainKey, .encryptedKeyWithoutPassphrase: .publickey
        }
        return AuthenticatedSession(method: wire, serverOfferedMethods: offered, agentIdentity: agentIdentity)
    }

    private func authFailure(_ rc: Int32, method: ErrorTaxonomy.AuthMethod) -> RemoteError {
        let context = RemoteErrorContext(operation: .authenticate)
        return ErrorTaxonomy.classifyAuth(rc: rc, method: method)
            ?? ErrorTaxonomy.classifySession(rc: rc, context: context)
            ?? RemoteError.operationFailed(OperationFailure(kind: .sessionCode(rc),
                                                            operation: .authenticate, path: nil, rc: rc))
    }
}
