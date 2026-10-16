import CLibssh2
import Darwin
import FerryBackendsSFTP
import FerryCore
import Foundation

/// M1'-5 用：目录列表这一层的**原始事实**——一个 readdir 包喂出几条、属性包里到底给了
/// 哪几位、走一条链要问服务器几次、`-38` 涨档花在哪、哪些回复属于"这不是链"。
///
/// 这些数不是拿来好看的：ADR-0001 D8（禁止逐条 stat）与 M0b-01 §0 结论 7（单次解析
/// 4–11 次往返）到了正式实现里就是"缓存挂在清单上""属性缺位一律 nil 不猜"这两条设计
/// 的全部依据。而正式路径换了（钉版 libssh2 + actor + 一台连接一条通道），所以必须在
/// 正式代码上重量一遍，不能引用 spike 壳里的老数字。
///
/// 用法（五台要先起着，语料要铺过）：
///   Spike/Scripts/seed-listing-corpus.sh
///   Spike/.build/debug/SpikeRunner listing
///   SPIKE_EXPERIMENT=stat …/SpikeRunner listing     # 外加逐条 stat 对照组
///   SPIKE_EXPERIMENT=raw  …/SpikeRunner listing     # 外加 ⑨：原始 C 走一遍 symlink_ex
///   SPIKE_PORTS="2202" …/SpikeRunner listing        # 只跑一台
///   SPIKE_CHARSET=utf8 …/SpikeRunner listing        # 连接按 UTF-8 配置，看非 UTF-8 名字怎么办
enum ListingSpike {
    private static let goodPassword = "testpass"
    private static let ports: [Int] = (ProcessInfo.processInfo.environment["SPIKE_PORTS"] ?? "2201 2202 2203 2204 2205")
        .split(separator: " ").compactMap { Int($0) }
    private static let host = ProcessInfo.processInfo.environment["SPIKE_HOST"] ?? "127.0.0.1"
    private static let wantStat = ProcessInfo.processInfo.environment["SPIKE_EXPERIMENT"] == "stat"
    private static let wantRaw = ProcessInfo.processInfo.environment["SPIKE_EXPERIMENT"] == "raw"
    private static let charset: CharsetConverter.Charset =
        (ProcessInfo.processInfo.environment["SPIKE_CHARSET"] == "utf8") ? .utf8 : .gbk

    /// 语料目录。2201 的 chroot 视图根是 `/`，同一个目录在它眼里是 `/spike/list`。
    private static func listRoot(home: RemotePath) -> RemotePath {
        child(home, "spike/list")
    }

    private static func makeConnection(port: Int) -> SFTPConnection {
        SFTPConnection(request: ConnectionRequest(
            endpoint: Endpoint(host: host, port: port, username: "tester"),
            authentication: .password(goodPassword),
            policy: ConnectionPolicy(connectTimeout: .seconds(10), handshakeTimeout: .seconds(60),
                                     authenticationTimeout: .seconds(30),
                                     algorithms: HandshakeProbe.legacy),
            charset: charset),
            hostKeyTrust: PassTrust())
    }

    private struct PassTrust: HostKeyTrust {
        func evaluate(endpoint: Endpoint, hostKey: HostKey) async throws {}
    }

    // MARK: - 入口

    static func run() async {
        print("libssh2 \(SpikeProbe.version())，服务器 = \(host) 上的 \(ports.map(String.init).joined(separator: " "))，字符集配置 = \(charset.rawValue)")
        for port in ports {
            print("\n===== \(port) =====")
            await oneServer(port: port)
        }
        print("""

            结论与表格见 docs/spike/M1-05。跑之前必须铺语料：Spike/Scripts/seed-listing-corpus.sh
        """)
    }

    private static func oneServer(port: Int) async {
        let connection = makeConnection(port: port)
        do {
            _ = try await connection.handshake()
            _ = try await connection.authenticate(interactive: nil)
        } catch {
            print("  认证失败：\(token(error))  phase=\(await connection.phase)")
            return
        }

        // ① 登录目录：`realpath(".")` 是唯一的基准（M0b-01 §0.3）
        guard let home = try? await connection.homeDirectory() else {
            print("  realpath(\".\") 失败，后面都跑不了  phase=\(await connection.phase)")
            return
        }
        print("  ① home = \(show(home.wireBytes))（\(home.wireBytes.count) 字节）")
        let root = listRoot(home: home)

        await listing(connection: connection, root: root)
        await attributes(connection: connection, root: root)
        if wantStat { await statComparison(connection: connection, root: root) }
        await linkCache(connection: connection, root: root)
        await longTarget(connection: connection, root: root)
        await charsetCheck(connection: connection, root: root)
        await failureClasses(connection: connection, root: root)
        if wantRaw { await symlinkStatusRaw(port: port, home: home) }

        let measure = await connection.measure
        print("  合计：通道=\(measure.file.channelInits) list=\(measure.file.listCalls) "
              + "readdir 调用=\(measure.file.readdirCalls) 包(估)=\(measure.file.readdirPackets) "
              + "观测条目=\(measure.file.entriesObserved) stat=\(measure.file.statCalls) "
              + "涨档=\(measure.file.bufferGrowths) 段lstat=\(measure.file.linkSegmentStats) "
              + "链查询=\(measure.file.linkProbes) "
              + "链命中=\(measure.file.linkCacheHits) 文件类累计=\(measure.file.listingElapsedMs) ms")
        print("  线程数=\(measure.executorThreads.count)（D7 要求 ≤2）  phase=\(await connection.phase)")
        await connection.close()
    }

    // MARK: - ② 大目录

    private static func listing(connection: SFTPConnection, root: RemotePath) async {
        print("\n  ② readdir 一次到底（flat，语料 1002 条）")
        let before = await connection.measure
        let start = DispatchTime.now()
        guard let listing = try? await connection.list(child(root, "flat")) else {
            print("    list 失败  phase=\(await connection.phase)"); return
        }
        let ms = elapsed(start)
        let f = (await connection.measure).file
        let observed = f.entriesObserved - before.file.entriesObserved
        print("    \(ms) ms  条目=\(listing.entries.count) 观测=\(observed) "
              + "调用=\(f.readdirCalls - before.file.readdirCalls) 包(估)=\(f.readdirPackets - before.file.readdirPackets) "
              + "涨档=\(f.bufferGrowths - before.file.bufferGrowths)")
        print(String(format: "    每条目 %.3f ms  丢掉的 `.`/`..` = %d  stat 增量=%d（D8 要求 0）",
                     Double(ms) / Double(max(1, listing.entries.count)),
                     observed - listing.entries.count, f.statCalls - before.file.statCalls))
        print("    清单的 directory = \(show(listing.directory.wireBytes))  撞名=\(listing.duplicatePaths.count)")
    }

    // MARK: - ③ 属性完整度

    private static func attributes(connection: SFTPConnection, root: RemotePath) async {
        guard let listing = try? await connection.list(child(root, "flat")) else { return }
        var kinds: [String: Int] = [:]
        for item in listing.entries { kinds[label(item.kind), default: 0] += 1 }
        print("\n  ③ 属性完整度（\(listing.entries.count) 条）")
        print("    类型分布 = \(kinds.sorted { $0.value > $1.value }.map { "\($0.key):\($0.value)" }.joined(separator: " "))")
        print("    缺 size=\(listing.entries.filter { $0.size == nil }.count)"
              + " 缺权限位=\(listing.entries.filter { $0.permissions == nil }.count)"
              + " 缺 mtime=\(listing.entries.filter { $0.modificationDate == nil }.count)"
              + " 缺 uid/gid=\(listing.entries.filter { $0.uid == nil }.count)"
              + " 缺 gid=\(listing.entries.filter { $0.gid == nil }.count)")
        print("    sizeIsExact=false 的=\(listing.entries.filter { !$0.sizeIsExact }.count)"
              + "  mtimeIsReliable=false 的=\(listing.entries.filter { !$0.mtimeIsReliable }.count)"
              + "  owner/group 非空的=\(listing.entries.filter { $0.owner != nil || $0.group != nil }.count)")
    }

    // MARK: - ④ 逐条 stat 对照

    private static func statComparison(connection: SFTPConnection, root: RemotePath) async {
        guard let listing = try? await connection.list(child(root, "flat")) else { return }
        let sample = min(200, listing.entries.count)
        let start = DispatchTime.now()
        var ok = 0
        for item in listing.entries.prefix(sample) {
            if (try? await connection.stat(item.path)) != nil { ok += 1 }
        }
        let ms = elapsed(start)
        print("\n  ④ 逐条 stat 对照（\(sample) 条）：\(ms) ms  成功=\(ok)"
              + String(format: "  每条 %.3f ms", Double(ms) / Double(max(1, sample))))
    }

    // MARK: - ⑤ 软链

    private static func linkCache(connection: SFTPConnection, root: RemotePath) async {
        guard var listing = try? await connection.list(child(root, "links")) else {
            print("\n  ⑤ links 列不出来"); return
        }
        let links = listing.entries.filter { $0.kind == .symbolicLink }
        print("\n  ⑤ 软链（清单 \(listing.entries.count) 条，判为链的 \(links.count) 条）")
        print("    清单里 linkTarget 非空的=\(listing.entries.filter { $0.linkTarget != nil }.count)（应当 0：readdir 包里没有目标）")

        let before = await connection.measure
        for item in links {
            let start = DispatchTime.now()
            do {
                if let resolution = try await connection.resolve(item, in: &listing) {
                    print("      \(name(of: item))  段数=\(resolution.segmentsLookedUp)"
                          + "  target=\(resolution.target.map { show($0.wireBytes) } ?? "<无>")"
                          + "  resolved=\(resolution.resolved.map { show($0.wireBytes) } ?? "<无>")"
                          + "  \(elapsed(start)) ms")
                } else {
                    print("      \(name(of: item))  不是链（resolve 直接返回 nil）  \(elapsed(start)) ms")
                }
            } catch {
                print("      \(name(of: item))  解析失败：\(token(error))  phase=\(await connection.phase)")
            }
        }
        let pass1 = await connection.measure
        print("    第一轮：查询=\(pass1.file.linkProbes - before.file.linkProbes)"
              + " 命中=\(pass1.file.linkCacheHits - before.file.linkCacheHits)"
              + " 缓存段=\(listing.probes.count) 结果=\(listing.resolutions.count)")

        let before2 = await connection.measure
        for item in links { _ = try? await connection.resolve(item, in: &listing) }
        let pass2 = await connection.measure
        print("    第二轮（同一张清单）：查询=\(pass2.file.linkProbes - before2.file.linkProbes)"
              + " 命中=\(pass2.file.linkCacheHits - before2.file.linkCacheHits)")
        print("    清单里的解析结果作废检查：staleResolutionCount=\(listing.staleResolutionCount)")
    }

    // MARK: - ⑥ `-38` 涨档

    private static func longTarget(connection: SFTPConnection, root: RemotePath) async {
        let before = await connection.measure
        let start = DispatchTime.now()
        let target = try? await connection.readlink(child(root, "links/l_long"))
        let ms = elapsed(start)
        let after = await connection.measure
        print("\n  ⑥ 1504 字节目标：\(ms) ms 涨档=\(after.file.bufferGrowths - before.file.bufferGrowths)"
              + " 拿到字节=\(target?.wireBytes.count ?? -1) 绝对=\(target?.isAbsolute ?? false)")
        if let target { print("    前 24 字节 = \(show(Array(target.wireBytes.prefix(24))))") }
    }

    // MARK: - ⑦ 非 UTF-8 名字

    private static func charsetCheck(connection: SFTPConnection, root: RemotePath) async {
        guard let listing = try? await connection.list(child(root, "flat")) else { return }
        let wanted = Array("gbk-".utf8) + [0xCE, 0xC4, 0xBC, 0xFE] + Array(".txt".utf8)
        // 比的是**名**，不是整条路径：清单里存的是 `<home>/spike/list/flat/gbk-…`。
        let hit = listing.entries.first { lastComponent($0.path.wireBytes) == wanted }
        // NAME_MAX 管的是**最后一段**，不是整条路径：flat 里最长名 255 字节，
        // 但拼上 `<home>/spike/list/flat/` 前缀后整条有 284 字节，按整条量就量错了。
        let longest = listing.entries.map { lastComponent($0.path.wireBytes).count }.max() ?? 0
        let longestPath = listing.entries.map(\.path.wireBytes.count).max() ?? 0
        print("\n  ⑦ R5 字节权威（连接字符集 = \(charset.rawValue)）")
        print("    GBK 名字按字节命中=\(hit != nil)  最长**名**=\(longest) 字节（NAME_MAX 255 < 缓冲 1024）"
              + " 最长整条路径=\(longestPath) 字节")
        if let hit {
            let configured = await connection.charsetConverter
            print("    按配置显示 = \(configured.displayString(hit.path.wireBytes))")
            print("    按 UTF-8 显示 = \(CharsetConverter(charset: .utf8).displayString(hit.path.wireBytes))")
        }
    }

    // MARK: - ⑧ 错误两类

    private static func failureClasses(connection: SFTPConnection, root: RemotePath) async {
        print("\n  ⑧ 失败两类（服务器明说的失败之后，phase 应当仍是 authenticated）")
        let nowhere = child(root, "flat-does-not-exist")
        print("    list 不存在      = \(await call { try await connection.list(nowhere) })  phase=\(await connection.phase)")
        print("    stat 不存在      = \(await call { try await connection.stat(nowhere) })  phase=\(await connection.phase)")
        print("    list 000 目录    = \(await call { try await connection.list(child(root, "noperm")) })  phase=\(await connection.phase)")
        print("    lstat 普通文件   = \(await call { try await connection.lstat(child(root, "dir/file")) })  phase=\(await connection.phase)")
        // 相对路径按登录目录解析（M0b-01 §0.3）：`./spike/list/dir` 应当**列得出来**，
        // `./flat` 则确实不存在——语料在 `<home>/spike/list/flat`，不是 `<home>/flat`。
        print("    list ./spike/list/dir = \(await call { try await connection.list(RemotePath(string: "./spike/list/dir", isAbsolute: false)!) })  （相对解析的正例）")
        print("    list ./flat      = \(await call { try await connection.list(RemotePath(string: "./flat", isAbsolute: false)!) })  phase=\(await connection.phase)")
        print("    list ~           = \(await call { try await connection.list(RemotePath(string: "~", isAbsolute: false)!) })")
        print("    list 名字含 NUL  = \(await call { try await connection.list(RemotePath(wireBytes: [0x2F, 0x00], isAbsolute: true)) })")
        print("    再一次 list dir  = \(await call { try await connection.list(child(root, "dir")) })  phase=\(await connection.phase)")
        // 这一发放在最后：`symlink_ex` 那一族的失败拿不到成因，按 `keepsTransportAfter`
        // 的既有规则就该硬拆（详见 ⑨ 与 docs/spike/M1-05 §9），后面再问只会得到
        // `network/connectionLost`——放中间就把这一节其余的数全带跑了。
        print("    readlink 普通文件 = \(await call { try await connection.readlink(child(root, "dir/file")) })"
              + "  phase=\(await connection.phase)  ←这一族的失败不采信状态码，连接判为用完")
    }

    // MARK: - ⑨ `symlink_ex` 的状态码取自哪一格（原始 C）

    /// 绕开全部正式代码，直接问 libssh2：`sftp_symlink_ex()` 失败时
    /// `libssh2_sftp_last_error()` 给的是不是服务器回的状态码？
    ///
    /// 起因是 ⑤ 里每条链的解析都失败成 `LIBSSH2_FX_*` 表外的数（33–45），而 0008 补丁
    /// （CVE-2025-15661，改的正是 `sftp_symlink()`）在 `SSH_FXP_STATUS` 分支里、type 之后
    /// 只 `_libssh2_get_u32` 一次——wire 上 type 后面第一个 u32 是**请求 id**，状态码在它后面
    /// 那一格。打补丁前的写法是 `_libssh2_ntohu32(data + 5)`（跳过 id），而且 `sftp.c` 里
    /// open/readdir/stat/lstat/mkdir/rmdir/rename/unlink/statvfs 至今全都还是 `data + 5`，
    /// **只有 symlink 这一处被改坏**。上游 master 也是错的（还多错一处 NAME 分支，
    /// 我们的补丁用"advance past id"那一格把它救回来了）。
    ///
    /// 这一节只用只读请求，不建链不删文件：语料原样不动。
    private static func symlinkStatusRaw(port: Int, home: RemotePath) async {
        print("\n  ⑨ symlink_ex 的状态码取自哪一格（原始 C，另开一条连接）")
        let endpoint = SpikeProbe.Endpoint(host: host, port: UInt16(port),
                                           user: "tester", password: goodPassword)
        let fd: Int32
        let session: OpaquePointer
        do { (fd, session) = try SpikeProbe.authenticatedSession(endpoint) }
        catch { print("    原始会话建不起来：\(error)"); return }
        guard let sftp = libssh2_sftp_init(session) else {
            print("    sftp_init 失败")
            SpikeProbe.shutdown(session: session, fd: fd)
            return
        }

        let root = listRoot(home: home)
        let nowhere = child(root, "links/nope-not-here").wireBytes
        let regular = child(root, "dir/file").wireBytes
        let aLink = child(root, "links/l_to_file").wireBytes

        var nextId = 0
        var failures = 0, statusIsId = 0
        func report(_ label: String, _ call: RawCall) {
            let id = nextId
            nextId += 1
            let bogus = call.rc == 0 && !call.target.isEmpty
                && call.target.allSatisfy { $0 == 0xA5 }
            var note = ""
            if bogus { note = "  ←假成功：rc=0 但 target 一格没写" }
            if call.rc != 0 {
                failures += 1
                if Int(call.sftpErr) == id { statusIsId += 1; note = "  ←last_errno 就是请求 id" }
            }
            print("      " + label + String(repeating: " ", count: max(1, 24 - label.count))
                  + "rc=\(call.rc) last_errno=\(call.sftpErr) 请求id=\(id)"
                  + " session_errno=\(call.sessionErrno)"
                  + (call.target.isEmpty ? "" : " target前8=\(show(call.target))")
                  + note)
        }

        report("READLINK 不存在", rawSymlink(sftp: sftp, session: session, path: nowhere,
                                            kind: LIBSSH2_SFTP_READLINK))
        report("READLINK 不存在", rawSymlink(sftp: sftp, session: session, path: nowhere,
                                            kind: LIBSSH2_SFTP_READLINK))
        report("READLINK 不存在", rawSymlink(sftp: sftp, session: session, path: nowhere,
                                            kind: LIBSSH2_SFTP_READLINK))
        report("READLINK 普通文件", rawSymlink(sftp: sftp, session: session, path: regular,
                                              kind: LIBSSH2_SFTP_READLINK))
        for _ in 0..<24 { _ = rawStat(sftp: sftp, session: session,
                                      path: regular, mode: LIBSSH2_SFTP_STAT) }
        print("      STAT 普通文件 ×24（把请求计数器推过 \(LIBSSH2_FX_LINK_LOOP)，"
              + "这样下一发的 last_errno 就没法伪装成状态码）")
        nextId += 24
        report("READLINK 不存在", rawSymlink(sftp: sftp, session: session, path: nowhere,
                                            kind: LIBSSH2_SFTP_READLINK))
        report("STAT 不存在(对照)", rawStat(sftp: sftp, session: session,
                                            path: nowhere, mode: LIBSSH2_SFTP_STAT))
        report("LSTAT 不存在(对照)", rawStat(sftp: sftp, session: session,
                                             path: nowhere, mode: LIBSSH2_SFTP_LSTAT))
        report("READLINK 真链(正例)", rawSymlink(sftp: sftp, session: session, path: aLink,
                                                 kind: LIBSSH2_SFTP_READLINK))
        report("REALPATH 穿过普通文件", rawSymlink(sftp: sftp, session: session,
                                                  path: child(root, "dir/file/nope").wireBytes,
                                                  kind: LIBSSH2_SFTP_REALPATH))
        print("    \(failures) 发被服务器拒绝，其中 \(statusIsId) 发的 last_errno 恰等于自己的请求 id"
              + "（全在 symlink 这一条路上）；紧挨着的 STAT/LSTAT 仍给出真实的 2 (NO_SUCH_FILE)。")
        libssh2_sftp_shutdown(sftp)
        SpikeProbe.shutdown(session: session, fd: fd)
    }

    private struct RawCall {
        let rc: Int32
        let sftpErr: UInt
        let sessionErrno: Int32
        /// 出参缓冲的前 8 字节；空数组表示这个调用没有出参缓冲。
        let target: [UInt8]
    }

    /// `target` 先填 `0xA5`：假成功时它一格都不会被写，正好把"rc=0 但没有结果"照出来。
    private static func rawSymlink(sftp: OpaquePointer, session: OpaquePointer,
                                   path: [UInt8], kind: Int32) -> RawCall {
        let capacity = 64
        var target = [UInt8](repeating: 0xA5, count: capacity)
        var terminated = path
        terminated.append(0)
        let rc = terminated.withUnsafeBytes { raw -> Int32 in
            guard let pathPointer = raw.bindMemory(to: CChar.self).baseAddress else { return -99 }
            return target.withUnsafeMutableBytes { box -> Int32 in
                guard let base = box.bindMemory(to: CChar.self).baseAddress else { return -99 }
                return libssh2_sftp_symlink_ex(sftp, pathPointer, UInt32(path.count),
                                               base, UInt32(capacity), kind)
            }
        }
        return RawCall(rc: rc, sftpErr: libssh2_sftp_last_error(sftp),
                       sessionErrno: libssh2_session_last_errno(session),
                       target: Array(target.prefix(8)))
    }

    private static func rawStat(sftp: OpaquePointer, session: OpaquePointer,
                                path: [UInt8], mode: Int32) -> RawCall {
        var attrs = LIBSSH2_SFTP_ATTRIBUTES()
        var terminated = path
        terminated.append(0)
        let rc = terminated.withUnsafeBytes { raw -> Int32 in
            guard let pointer = raw.bindMemory(to: CChar.self).baseAddress else { return -99 }
            return libssh2_sftp_stat_ex(sftp, pointer, UInt32(path.count), mode, &attrs)
        }
        return RawCall(rc: rc, sftpErr: libssh2_sftp_last_error(sftp),
                       sessionErrno: libssh2_session_last_errno(session), target: [])
    }

    // MARK: - 小工具

    private static func child(_ parent: RemotePath, _ name: String) -> RemotePath {
        guard let path = try? PathResolver.child(of: parent, name: Array(name.utf8)) else {
            fatalError("语料路径拼不出来：\(name)")
        }
        return path
    }

    private static func lastComponent(_ bytes: [UInt8]) -> [UInt8] {
        guard let slash = bytes.lastIndex(of: 0x2F) else { return bytes }
        return Array(bytes[bytes.index(after: slash)...])
    }

    private static func name(of item: RemoteItem) -> String {
        show(lastComponent(item.path.wireBytes))
    }

    private static func label(_ kind: RemoteItemKind) -> String {
        switch kind {
        case .file: return "file"
        case .directory: return "dir"
        case .symbolicLink: return "link"
        case .other: return "other"
        case .unknown: return "unknown"
        }
    }

    private static func call(_ body: () async throws -> some Any) async -> String {
        do { _ = try await body(); return "ok" }
        catch is CancellationError { return "cancelled" }
        catch let error as RemoteError { return error.diagnosticCode }
        catch let error as PathResolutionError { return "词法(\(error))" }
        catch { return "other(\(error))" }
    }

    private static func token(_ error: Error) -> String {
        if let error = error as? RemoteError { return error.diagnosticCode }
        return "\(error)"
    }

    private static func elapsed(_ start: DispatchTime) -> Int {
        Int(DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000
    }

    private static func show(_ bytes: [UInt8]) -> String {
        if let text = String(bytes: bytes, encoding: .utf8) { return text }
        return bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}
