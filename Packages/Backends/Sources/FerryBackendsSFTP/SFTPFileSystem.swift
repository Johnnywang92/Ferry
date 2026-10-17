import CLibssh2
import Darwin
import FerryCore
import Foundation

/// M1'-5：SFTP 通道与目录列表。
///
/// 三个 M0b 模块在这里接上：路径全部先过 `PathResolver`（相对路径与 `~` 不许裸发给
/// 服务器，M0b-01 §0 结论 2/3），条目名字节交给 `CharsetConverter` 决定显示（R5），
/// 原始码交给 `ErrorTaxonomy.classifySFTP`（`rc` 与 `status` 必须成对即时取）。
///
/// 一台连接**只开一条 SFTP 通道**并复用：`sftp_init` 就是一条 SSH 通道，服务器按
/// `MaxSessions` 记账，实测两台都在第 11 次回 `-21`（M0a-01），而 atmoz 那台一次
/// `sftp_init` 要 390–433 ms。
///
/// 下面这些 `nonisolated(unsafe) var` 是 C 调用的出参暂存格。它们被 `drive` 的闭包捕获，
/// 而整条闭包链在同一个 actor hop 里同步跑完（D7：同一时刻只有一条线程碰 session），
/// 不存在并发访问——Swift 6 的区域隔离看不出这一点，只能显式说明。
extension SFTPConnection {
    /// libssh2 在缓冲不够时回这一枚（`libssh2.h:576`）。
    ///
    /// 它**不是**错误：`readdir_ex` 与 `symlink_ex(READLINK/REALPATH)` 名字或目标
    /// 装不下时都回它，而且状态机不推进（sftp.c 的 `goto end` 在 `next_name` 赋值之前），
    /// 所以正确做法是换大缓冲重来这一条，不是报错也不是往下走。
    static let bufferTooSmall: Int32 = -38

    /// 目录里这两个名字不进清单：它们的词法含义已经被 `PathResolver` 消化掉了
    /// （`.` 是本级、`..` 是父级），留下反而要后端自己解释"`/x/..` 是什么"。
    /// 丢弃计数进 `FileStats.entriesObserved`，实测每台都发（M1-05 §3.4）。
    private static let selfName: [UInt8] = [0x2E]
    private static let parentName: [UInt8] = [0x2E, 0x2E]

    /// 显示字符集与比较策略：都来自连接配置，不是每个路径自带（R5）。
    public var charsetConverter: CharsetConverter { CharsetConverter(charset: request.charset) }
    public var pathPolicy: PathPolicy { request.pathPolicy }

    /// 登录后 `realpath(".")` 给的那个目录，已拿到过的话直接回。
    public var knownLoginDirectory: RemotePath? { loginDirectory }

    public func homeDirectory() async throws -> RemotePath {
        try await filesystemCall { channel in
            try loginDirectory(channel: channel)
        }
    }

    // MARK: - 目录列表

    /// 一次列完：`opendir` + `readdir` 到底，属性取每个 `SSH_FXP_NAME` 包里自带的那份。
    ///
    /// 这里**不**做任何逐条 `stat`/`readlink`（ADR-0001 D8）：实测 readdir 摊下来
    /// 0.03 ms/条目而逐条 stat 是 0.37 ms/条目，差 12.7 倍，跨洋按 1 s RTT 算是
    /// 19 s 对 16.8 分钟。软链的目标要拿就得一条一次往返，所以留给
    /// `resolve(_:in:)` 显式请求，并且结果缓存回这张清单。
    public func list(_ path: RemotePath) async throws -> RemoteDirectoryListing {
        let start = uptimeMilliseconds()
        fileStats.listCalls += 1
        let listing = try await filesystemCall { channel in
            let home = try loginDirectory(channel: channel)
            let resolver = PathResolver(homeDirectory: home)
            // 相对路径与 `~` 只能在这一步被消化：服务器 `realpath` 两样都不认
            // （M0b-01 §0 结论 2/3，实测三台全部拒绝）。
            let absolute = try resolver.lexicalResolve(path, relativeTo: home)
            return try readDirectory(absolute, channel: channel)
        }
        fileStats.listingElapsedMs += uptimeMilliseconds() - start
        return listing
    }

    /// 把一条软链解析到底，结果写回清单的缓存。
    ///
    /// 走链用的是 `PathResolver.resolve`，也就是 M0b-01 拿服务器 `realpath` 当预言机
    /// 对过 26 条用例的那一套；每推进一段先查缓存，只有缓存里没有的段才发一次
    /// `readlink`。所以对同一张清单里的第二条链，代价通常是"多问一两个新段"，
    /// 而不是重新走一遍整条链（实测见 M1-05 §4）。
    public func resolve(_ item: RemoteItem,
                        in listing: inout RemoteDirectoryListing) async throws
        -> RemoteDirectoryListing.LinkResolution?
    {
        if let cached = listing.resolution(for: item) {
            fileStats.linkCacheHits += 1
            return cached
        }
        guard item.kind == .symbolicLink else { return nil }
        let start = uptimeMilliseconds()
        // 段的缓存只把**快照**带进闭包，出来的结果再并回 `listing`：`filesystemCall` 的
        // body 是同步闭包，在里面写 `inout listing` 等于把这张清单的独占访问权拆给两处。
        let probesIn = listing.probes
        let outcome = try await filesystemCall { channel -> (RemoteDirectoryListing.LinkResolution, [RemotePath: RemotePath?]) in
            let home = try loginDirectory(channel: channel)
            let resolver = PathResolver(homeDirectory: home)
            var cache = probesIn
            var fresh: [RemotePath: RemotePath?] = [:]
            var segmentsLookedUp = 0

            // 末段是链本身也要展开：`resolve` 的语义与服务器 `open` 一致（M0b-01 §0.5），
            // 断链照样有词法结果，`realpath` 与它逐字相同的那 26 条用例就是这么对的。
            let resolved = try resolver.resolve(item.path, relativeTo: home) { candidate in
                if let entry = cache[candidate] {
                    // 外层 nil 才是"没问过"。问过且答案是"这段不是链"也算命中：
                    // 分不清这两种，迷宫里那 8 条链共用的 `dir1` 每来一次就白问一次。
                    fileStats.linkCacheHits += 1
                    return entry?.wireBytes
                }
                segmentsLookedUp += 1
                let target = try readlinkOrNil(candidate, channel: channel)
                cache[candidate] = target
                fresh[candidate] = target
                return target?.wireBytes
            }
            return (RemoteDirectoryListing.LinkResolution(
                        target: cache[item.path] ?? nil,
                        resolved: resolved,
                        segmentsLookedUp: segmentsLookedUp),
                    fresh)
        }
        fileStats.listingElapsedMs += uptimeMilliseconds() - start
        for (path, target) in outcome.1 { listing.noteProbe(path, target: target) }
        listing.note(outcome.0, for: item)
        return outcome.0
    }

    // MARK: - 单条属性

    /// 跟随软链的属性（`SSH_FXP_STAT`）。
    public func stat(_ path: RemotePath) async throws -> RemoteItem {
        try await attribute(path, mode: LIBSSH2_SFTP_STAT, operation: .stat)
    }

    /// 不跟随软链的属性（`SSH_FXP_LSTAT`）。清单里那条链是不是断的，只有这条能回答。
    public func lstat(_ path: RemotePath) async throws -> RemoteItem {
        try await attribute(path, mode: LIBSSH2_SFTP_LSTAT, operation: .lstat)
    }

    private func attribute(_ path: RemotePath, mode: Int32, operation: RemoteOperation) async throws
        -> RemoteItem
    {
        let start = uptimeMilliseconds()
        let result = try await filesystemCall { channel -> (RemotePath, LIBSSH2_SFTP_ATTRIBUTES) in
            let home = try loginDirectory(channel: channel)
            let resolver = PathResolver(homeDirectory: home)
            let absolute = try resolver.lexicalResolve(path, relativeTo: home)
            fileStats.statCalls += 1
            let attrs = try statBytes(absolute, mode: mode, channel: channel)
            return (absolute, attrs)
        }
        fileStats.listingElapsedMs += uptimeMilliseconds() - start
        return SFTPAttributes.item(path: result.0, attrs: result.1)
    }

    // MARK: - 公共外壳

    /// 一次文件系统调用的闸门、通道、执行器与失败两类走向。
    ///
    /// 全部 C 调用都在这一个 actor  hop 里同步跑完，所以 ADR-0001 D7（同一时刻只有一条
    /// 线程碰 session）不需要额外加锁；`body` 拿不到 `await`，也就没法把 session
    /// 指针带离这条线程。
    ///
    /// 失败分两类，沿用认证那套判据（M1-04 §2）：服务器明确回了一个 SFTP 状态码
    /// 说明 transport 完好，连接留在 `.authenticated`，换个路径再调一次就行；
    /// 网络类失败、协议违规和被取消则硬拆转 `.aborted`。
    ///
    /// internal 的理由与上面那批状态一样：传输在 `SFTPTransfer.swift` 的 extension 里，
    /// 每一 chunk 都要过同一个闸门。
    func filesystemCall<R>(_ body: (OpaquePointer) throws -> R) async throws -> R {
        switch state {
        case .idle, .connecting, .ready:
            throw RemoteError.protocolViolation(
                "认证还没完成就发起文件系统操作（phase=\(state.rawValue)）")
        case .aborted, .closed:
            throw RemoteError.network(.connectionLost)
        case .authenticated:
            break
        }
        guard let session else {
            throw RemoteError.protocolViolation("phase=authenticated 但 session 已经不在了")
        }
        visitedThreads.insert(currentThreadID())
        do {
            let channel = try ensureChannel(session)
            let result = try body(channel)
            visitedThreads.insert(currentThreadID())
            return result
        } catch {
            visitedThreads.insert(currentThreadID())
            if !keepsTransportAfter(error) {
                hardTeardown()
                state = .aborted
            }
            throw error
        }
    }

    /// 服务器给了明确状态码的失败不动 transport；链路上的问题一律硬拆。
    private func keepsTransportAfter(_ error: Error) -> Bool {
        // 词法错误在发出任何一个字节之前就判定了（`PathResolver` §0.1：路径出错就是
        // 全盘错，但不能因此废掉一条已经认证好的连接）。
        if error is PathResolutionError { return true }
        guard let error = error as? RemoteError else { return false }   // CancellationError 也在这儿
        switch error {
        case .notFound, .permissionDenied, .unsupported, .keyCollision, .undecodablePath:
            return true
        case .operationFailed(let failure):
            // `-31` 配一个合法的 `SSH_FX_*`：话是服务器说的，通道还好好的。
            // 会话层码（socket 断、超时）与 `undetermined` 不算：那连"服务器说了什么"都不知道。
            if case .sftpStatus = failure.kind { return true }
            return false
        default:
            return false
        }
    }

    func operationBudget() -> Int64 {
        milliseconds(of: request.policy.fileOperationTimeout)
    }

    /// `handleCancel` 只给传输那一族用：一个 chunk 之内也要能停（M1'-6）。
    func newLoop(_ session: OpaquePointer, handleCancel: CancellationFlag? = nil) -> SessionLoop {
        SessionLoop(fd: fd, session: session, cancel: cancelFlag, handleCancel: handleCancel,
                    stats: loopStats)
    }

    // MARK: - 通道

    private func ensureChannel(_ session: OpaquePointer) throws -> OpaquePointer {
        if let existing = sftpChannel { return existing }
        var loop = newLoop(session)
        nonisolated(unsafe) var created: OpaquePointer?
        let rc = try loop.drive(deadlineMs: operationBudget()) {
            if let handle = libssh2_sftp_init(session) {
                created = handle
                return 0
            }
            return Int32(libssh2_session_last_errno(session))
        }
        guard rc == 0, let created else {
            throw ErrorTaxonomy.classifySession(rc: rc, context: RemoteErrorContext(operation: .list))
                ?? RemoteError.operationFailed(OperationFailure(
                    kind: .sessionCode(rc), operation: .list, path: nil, rc: rc))
        }
        sftpChannel = created
        fileStats.channelInits += 1
        return created
    }

    // MARK: - 路径类调用

    /// 登录后问一次 `realpath(".")`，之后一直用这份基准。
    ///
    /// 这里刻意传字面 `.`：基准目录必须由服务器给（2201 的 chroot 视图根是 `/`，
    /// 2202 是 `/home/tester`），而 `.` 是相对路径里唯一一条服务器认得的（M0b-01 §0.3）。
    /// internal 的理由同上面那批状态：`private` 是文件作用域，传输在
    /// `SFTPTransfer.swift` 里也要拿这个基准做词法解析。
    func loginDirectory(channel: OpaquePointer) throws -> RemotePath {
        if let cached = loginDirectory { return cached }
        let resolved = try readTarget([0x2E], channel: channel, kind: LIBSSH2_SFTP_REALPATH,
                                      operation: .realpath)
        guard resolved.first == 0x2F else {
            throw RemoteError.protocolViolation(
                "realpath(\".\") 回来的不是绝对路径（\(resolved.count) 字节）")
        }
        let path = RemotePath(wireBytes: resolved, isAbsolute: true)
        loginDirectory = path
        return path
    }

    /// 单读一条链的原文（`RemoteFileSystem.readlink`）。返回的是**未解析**的原始字节，
    /// 相对目标保持相对；字符集一律交给调用方按连接配置决定（R5）。
    public func readlink(_ path: RemotePath) async throws -> RemotePath {
        try await filesystemCall { channel in
            let home = try loginDirectory(channel: channel)
            let absolute = try PathResolver(homeDirectory: home)
                .lexicalResolve(path, relativeTo: home)
            fileStats.linkProbes += 1
            let raw = try readTarget(absolute.wireBytes, channel: channel,
                                     kind: LIBSSH2_SFTP_READLINK, operation: .readlink)
            return RemotePath(wireBytes: raw, isAbsolute: raw.first == 0x2F)
        }
    }

    /// 走链时的一段查询：**先用 lstat 的类型位判是不是链，确认是链才发 READLINK**。
    ///
    /// 这个顺序不是审美选择，是被 0008 补丁（CVE-2025-15661）逼出来的。它改的正是
    /// `sftp_symlink()`，而改写后的 `SSH_FXP_STATUS` 分支在 `type` 之后只取一个 u32——
    /// wire 上那一格是**请求 id**，状态码在它后面。原始 C 实测（M1-05 §9，另开一条连接）：
    ///   · 请求 id 恰为 0 时失败被读成 `SSH_FX_OK`：`rc=0`，出参缓冲一格都没写——**假成功**；
    ///   · 其余失败的 `libssh2_sftp_last_error` 就是请求 id（1/2/3/28/32）；把计数器推高，
    ///     这个数就落进 `LIBSSH2_FX_*` 值域之外，怎么配对都配不出可读的成因；
    ///   · 普通文件上的 readlink 回 3，看着像 `PERMISSION_DENIED`，而服务器实际回的是
    ///     `INVALID_FILENAME(20)`。
    /// `sftp.c` 里**只有这一处**状态分支被改坏：stat/lstat/open/readdir/mkdir/rmdir/unlink/
    /// rename/statvfs 至今仍是正确的 `data + 5`，上游 master 也一样。所以"这段是不是链"
    /// 必须由 lstat 的属性回答，READLINK 只用在必定成功的场合。
    ///
    /// 代价：非链段与原先一次往返，链段两次——M0b-01 §0 结论 7 的 4–11 次往返
    /// 就是这么量的（那套 oracle 同样是 lstat 先行）。
    private func readlinkOrNil(_ path: RemotePath, channel: OpaquePointer) throws -> RemotePath? {
        let attrs: LIBSSH2_SFTP_ATTRIBUTES
        fileStats.linkSegmentStats += 1
        do {
            attrs = try statBytes(path, mode: LIBSSH2_SFTP_LSTAT, channel: channel)
        } catch let error as RemoteError {
            // 不存在、父路径途中的名字不是目录：内核在这一步也当"这段没法是链"，词法继续走。
            // 权限拒绝不算——那是"问不出来"，与"不是链"是两回事，别把它咽进缓存。
            guard case .notFound = error else { throw error }
            return nil
        }
        guard UInt(attrs.flags) & SFTPAttributes.attrPermissions != 0,
              attrs.permissions & SFTPAttributes.typeMask == SFTPAttributes.typeLink else { return nil }
        fileStats.linkProbes += 1
        let raw = try readTarget(path.wireBytes, channel: channel,
                                 kind: LIBSSH2_SFTP_READLINK, operation: .readlink)
        return RemotePath(wireBytes: raw, isAbsolute: raw.first == 0x2F)
    }

    /// `symlink_ex` 读目标：缓冲区装不下时回 `-38`，而这一枚码的代价是**一次已经发出去
    /// 的往返**（请求已经发了，答案在 libssh2 里被丢掉，sftp.c:3950）。所以容量从 1 KB
    /// 起、按 4 倍涨，实测一条 255 字节的目标只用一次涨档（M1-05 §5）。
    private func readTarget(_ bytes: [UInt8], channel: OpaquePointer, kind: Int32,
                            operation: RemoteOperation) throws -> [UInt8] {
        guard let session else { throw RemoteError.protocolViolation("session 已经不在了") }
        var terminated = bytes
        terminated.append(0)
        nonisolated(unsafe) var capacity = 1024
        nonisolated(unsafe) var buffer = UnsafeMutablePointer<CChar>.allocate(capacity: capacity)
        defer { buffer.deallocate() }

        while true {
            var loop = newLoop(session)
            let rc = try terminated.withUnsafeBytes { raw -> Int32 in
                let path = raw.bindMemory(to: CChar.self).baseAddress!
                return try loop.drive(deadlineMs: operationBudget()) {
                    libssh2_sftp_symlink_ex(channel, path, UInt32(bytes.count), buffer,
                                            UInt32(capacity), kind)
                }
            }
            // `sftp.c:3943` 只在 `lk_len < target_len` 时拷贝并补 `\0`，所以成功返回的
            // `rc` 就是目标的**原始字节数**：按 `rc` 直接搬，绝不能过一遍 `String`
            // ——GBK 目标是合法字节但不是合法 UTF-8，转出去就丢（R5）。
            if rc >= 0 { return Array(UnsafeRawBufferPointer(start: buffer, count: Int(rc))) }
            if rc == Self.bufferTooSmall, capacity < (1 << 20) {
                fileStats.bufferGrowths += 1
                buffer.deallocate()
                capacity *= 4
                buffer = UnsafeMutablePointer<CChar>.allocate(capacity: capacity)
                continue
            }
            throw sftpFailure(rc, channel: channel, operation: operation, path: path(bytes),
                              statusTrustworthy: false)
        }
    }

    // MARK: - 目录

    private func readDirectory(_ directory: RemotePath, channel: OpaquePointer) throws
        -> RemoteDirectoryListing
    {
        let handle = try openDirectory(directory, channel: channel)
        defer { releaseHandle(handle) }

        var entries: [RemoteItem] = []
        nonisolated(unsafe) var capacity = 1024
        nonisolated(unsafe) var buffer = UnsafeMutablePointer<CChar>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        nonisolated(unsafe) var attrs = LIBSSH2_SFTP_ATTRIBUTES()
        var packets = 0

        while true {
            guard let session else { throw RemoteError.protocolViolation("session 已经不在了") }
            var loop = newLoop(session)
            let eagainBefore = loopStats.eagain
            fileStats.readdirCalls += 1
            let rc = try loop.drive(deadlineMs: operationBudget()) {
                libssh2_sftp_readdir_ex(handle, buffer, capacity, nil, 0, &attrs)
            }
            if rc == 0 { break }                       // SSH_FXP_STATUS / EOF
            if eagainBefore != loopStats.eagain { packets += 1 }
            if rc < 0 {
                guard rc == Self.bufferTooSmall, capacity < (1 << 20) else {
                    throw sftpFailure(rc, channel: channel, operation: .list, path: directory)
                }
                // 状态机没推进（sftp.c 的 `goto end` 在 `next_name` 赋值之前），
                // 换大缓冲**重来这一条**，不是跳过它。
                fileStats.bufferGrowths += 1
                buffer.deallocate()
                capacity *= 4
                buffer = UnsafeMutablePointer<CChar>.allocate(capacity: capacity)
                continue
            }

            // 名字按 `rc` 长度的**原始字节**取走。`sftp.c:1857` 的判据是
            // `filename_len >= buffer_maxlen` 才回 `-38`，所以成功返回的字节里不含 `\0`
            // 之外的任何东西；过 `String(cString:)` 会把 GBK 名字变成替代字符（R5 破口）。
            let name = Array(UnsafeRawBufferPointer(start: buffer, count: Int(rc)))
            fileStats.entriesObserved += 1
            if name == Self.selfName || name == Self.parentName { continue }
            // 拼路径只允许 `PathResolver.child`：视图根是 `/` 时任何手拼都会产出 `//name`
            // （M0b-01 §3 约束 2，第一版就在这里 mkdir 失败过）。
            let itemPath = try PathResolver.child(of: directory, name: name)
            entries.append(SFTPAttributes.item(path: itemPath, attrs: attrs))
        }

        fileStats.readdirPackets += packets
        return RemoteDirectoryListing(directory: directory, entries: entries)
    }

    private func openDirectory(_ path: RemotePath, channel: OpaquePointer) throws -> OpaquePointer {
        guard let session else { throw RemoteError.protocolViolation("session 已经不在了") }
        var terminated = path.wireBytes
        terminated.append(0)
        var loop = newLoop(session)
        nonisolated(unsafe) var opened: OpaquePointer?
        let length = UInt32(path.wireBytes.count)
        let rc = try terminated.withUnsafeBytes { raw -> Int32 in
            let pointer = raw.bindMemory(to: CChar.self).baseAddress!
            return try loop.drive(deadlineMs: operationBudget()) {
                if let handle = libssh2_sftp_open_ex(channel, pointer, length,
                                                     UInt(LIBSSH2_FXF_READ), 0,
                                                     LIBSSH2_SFTP_OPENDIR) {
                    opened = handle
                    return 0
                }
                return Int32(libssh2_session_last_errno(session))
            }
        }
        guard rc == 0, let opened else {
            throw sftpFailure(rc, channel: channel, operation: .list, path: path)
        }
        return opened
    }

    /// 目录句柄的释放。**取消路径上不做**（D4）：留着由 `libssh2_session_free` 一起收，
    /// 代价是每条被废掉的连接漏一个句柄，而不是让取消多等一个往返。
    private func releaseHandle(_ handle: OpaquePointer) {
        guard !cancelFlag.isSet, let session, fd >= 0 else { return }
        var loop = newLoop(session)
        _ = try? loop.drive(deadlineMs: operationBudget()) {
            libssh2_sftp_close_handle(handle)
        }
    }

    private func statBytes(_ path: RemotePath, mode: Int32, channel: OpaquePointer) throws
        -> LIBSSH2_SFTP_ATTRIBUTES
    {
        guard let session else { throw RemoteError.protocolViolation("session 已经不在了") }
        var terminated = path.wireBytes
        terminated.append(0)
        var loop = newLoop(session)
        nonisolated(unsafe) var attrs = LIBSSH2_SFTP_ATTRIBUTES()
        let length = UInt32(path.wireBytes.count)
        let rc = try terminated.withUnsafeBytes { raw -> Int32 in
            let pointer = raw.bindMemory(to: CChar.self).baseAddress!
            return try loop.drive(deadlineMs: operationBudget()) {
                libssh2_sftp_stat_ex(channel, pointer, length, mode, &attrs)
            }
        }
        guard rc == 0 else {
            throw sftpFailure(rc, channel: channel,
                              operation: mode == LIBSSH2_SFTP_LSTAT ? .lstat : .stat, path: path)
        }
        return attrs
    }

    // MARK: - 错误

    /// `rc` 与 `status` **成对即时**取（`ErrorTaxonomy` 规则 2）：
    /// `libssh2_sftp_last_error` 会被下一个请求覆盖，而实测有 `-31` 配 `0`、
    /// `-31` 配 71–134 这类非法值的调用。
    ///
    /// `statusTrustworthy: false` 用于 `symlink_ex` 那一族调用：0008 补丁（CVE-2025-15661）
    /// 改坏了 `sftp_symlink()` 的 `SSH_FXP_STATUS` 分支，它从 `type` 之后只取一个 u32，
    /// 而 wire 上那一格是**请求 id**，状态码在它后面。于是这个"状态码"是 1、2、3、7、10
    /// 这些数的时候，分类器会把请求序号读成 `EOF`/`NO_SUCH_FILE`/`PERMISSION_DENIED`/
    /// `CONNECTION_LOST`/`NO_SUCH_PATH`——`notFound` 会把同步引擎支去删本地文件，
    /// `connectionLost` 会让一个确定性失败变成可重试。这一族的失败一律走 `undetermined`：
    /// 宁可说"判不出成因"，也不给一个凭似乎是成因的码（实测见 M1-05 §9）。
    func sftpFailure(_ rc: Int32, channel: OpaquePointer, operation: RemoteOperation,
                     path: RemotePath?, statusTrustworthy: Bool = true) -> RemoteError {
        let context = RemoteErrorContext(operation: operation, path: path)
        guard statusTrustworthy else {
            return RemoteError.operationFailed(OperationFailure(
                kind: .undetermined, operation: operation, path: path, rc: rc))
        }
        let status = UInt32(truncatingIfNeeded: libssh2_sftp_last_error(channel))
        // 实测：`-38 BUFFER_TOO_SMALL` 是 libssh2 本地的缓冲判定，不是服务器回的码。
        // 走到这里说明缓冲已经涨到 1 MB 还装不下——不猜 notFound，报协议违规。
        if rc == Self.bufferTooSmall {
            return RemoteError.protocolViolation(
                "名字或目标超过 1 MB 可读上限（operation=\(operation.rawValue)，路径 \((path?.wireBytes.count ?? 0)) 字节）")
        }
        return ErrorTaxonomy.classifySFTP(rc: rc, status: status == 0 ? nil : status, context: context)
            ?? RemoteError.operationFailed(OperationFailure(
                kind: .undetermined, operation: operation, path: path, rc: rc))
    }

    private func path(_ bytes: [UInt8]) -> RemotePath {
        RemotePath(wireBytes: bytes, isAbsolute: bytes.first == 0x2F)
    }
}

/// `LIBSSH2_SFTP_ATTRIBUTES` → `RemoteItem`。纯函数，所以单独拿出来给单测直接喂构造的属性。
///
/// 唯一依据是 `flags` 的那四个位：属性包里没给的字段一律 nil，不猜、不用 0 顶。
/// 这条纪律是 M1-01 §0 结论 6 逼出来的——同一台 Mac 客户端在 2201 拿得到硬链接数、
/// 在 9.7 的三台拿不到，"字段缺失"不是异常而是常态。
enum SFTPAttributes {
    static let attrSize: UInt = 0x00000001
    static let attrUidGid: UInt = 0x00000002
    static let attrPermissions: UInt = 0x00000004
    static let attrAcModTime: UInt = 0x00000008
    static let attrExtended: UInt = 0x80000000

    /// 类型位掩码。`S_ISDIR()` 一类的宏在 Swift 侧导不进来（函数宏），只能自己按位比
    /// （M0b-01 §4）。
    static let typeMask: UInt = 0o170000
    static let typeSocket: UInt = 0o140000
    static let typeLink: UInt = 0o120000
    static let typeRegular: UInt = 0o100000
    static let typeFileBlock: UInt = 0o060000
    static let typeFileCharacter: UInt = 0o020000
    static let typeDirectory: UInt = 0o040000
    static let typeFifo: UInt = 0o010000

    static func item(path: RemotePath, attrs: LIBSSH2_SFTP_ATTRIBUTES) -> RemoteItem {
        let flags = UInt(attrs.flags)
        let hasPermissions = flags & attrPermissions != 0
        let permissions = hasPermissions ? UInt16(truncatingIfNeeded: attrs.permissions) : nil

        var kind = RemoteItemKind.unknown
        if hasPermissions {
            switch attrs.permissions & typeMask {
            case typeRegular: kind = .file
            case typeDirectory: kind = .directory
            case typeLink: kind = .symbolicLink
            case typeSocket, typeFifo, typeFileBlock, typeFileCharacter: kind = .other
            default: kind = .other
            }
        }

        let size = (flags & attrSize != 0) ? Int64(truncatingIfNeeded: attrs.filesize) : nil
        let date: Date? = (flags & attrAcModTime != 0)
            ? Date(timeIntervalSince1970: TimeInterval(attrs.mtime)) : nil
        let ids = (flags & attrUidGid != 0)
            ? (UInt32(truncatingIfNeeded: attrs.uid), UInt32(truncatingIfNeeded: attrs.gid))
            : (nil, nil)

        return RemoteItem(path: path,
                          kind: kind,
                          size: size,
                          modificationDate: date,
                          // SFTP v3 的 size 就是 `st_size`，给得出就是准的；给不出才是"不精确"。
                          sizeIsExact: size != nil,
                          // 秒级精度（协议字段是 uint32 秒），所以"可靠"指的是这个数真的来自服务器。
                          mtimeIsReliable: date != nil,
                          linkTarget: nil,
                          permissions: permissions,
                          uid: ids.0,
                          gid: ids.1,
                          owner: nil,
                          group: nil)
    }

    /// 属性包里有没有扩展段。有也不代表拿得到属主名：`_LIBSSH2_SFTP_ATTRIBUTES`
    /// 里压根没有 username/groupname 字段，`sftp_bin2attr` 解析扩展段只为了推进游标
    /// （sftp.c:736–741），内容直接丢掉。
    static func hasExtended(attrs: LIBSSH2_SFTP_ATTRIBUTES) -> Bool {
        UInt(attrs.flags) & attrExtended != 0
    }
}
