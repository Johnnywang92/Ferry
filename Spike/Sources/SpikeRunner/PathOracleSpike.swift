import CLibssh2
import FerryCore
import Foundation

/// M0b 出口验证：`PathResolver.resolve` 必须与服务器自己的 realpath 一致。
/// 单测只能证明算法自洽，证明不了"和 OpenSSH 的实现一样"，所以拿真服务器当预言机。
/// 顺带把 SFTP 后端里 `lstat` + `readlink` 这两个调用的真实形态先走一遍。
enum PathOracleSpike {
    struct OracleError: Error, CustomStringConvertible {
        let step: String
        let detail: String
        var description: String { "\(step)：\(detail)" }
    }

    /// 软链解析每推进一段就是一次真实往返，M0a-04 已证明这类请求按 RTT 计费，所以单独计数。
    final class Counter: @unchecked Sendable { var lookups = 0 }

    struct Row {
        let input: String
        let server: String
        let mine: String
        let verdict: String
        let lookups: Int
        let ms: Double
    }

    private static let linkMask: UInt = 0o170000
    private static let linkBits: UInt = 0o120000
    private static let separator: UInt8 = 0x2F

    /// 名字节化。迷宫里有一个 GBK 文件名，它只能以字节形式存在，所以全程用字节路径。
    private static func b(_ string: String) -> [UInt8] { [UInt8](string.utf8) }

    static func run() {
        let endpoint = SpikeProbe.Endpoint.fromEnvironment(defaultPort: 2201)
        print("libssh2 \(SpikeProbe.version()) -> \(endpoint.host):\(endpoint.port) as \(endpoint.user)")

        let fd: Int32
        let session: OpaquePointer
        do {
            (fd, session) = try SpikeProbe.authenticatedSession(endpoint)
        } catch {
            print("FAIL 建立会话失败：\(error)")
            exit(1)
        }
        defer { SpikeProbe.shutdown(session: session, fd: fd) }
        guard let sftp = libssh2_sftp_init(session) else {
            print("FAIL sftp_init：\(ThroughputSpike.lastSessionError(session))")
            exit(1)
        }
        defer { libssh2_sftp_shutdown(sftp) }

        do {
            let rows = try execute(sftp: sftp, session: session)
            print(String(format: "  %-34@ %-34@ %-34@ %-10@ %4@ %6@",
                         "用例", "服务器 realpath", "PathResolver", "判定", "往返", "ms"))
            for row in rows {
                print(String(format: "  %-34@ %-34@ %-34@ %-10@ %4d %6.1f",
                             row.input as NSString, row.server as NSString, row.mine as NSString,
                             row.verdict as NSString, row.lookups, row.ms))
            }
            let mismatch = rows.filter { $0.verdict == "不一致" }.count
            let skipped = rows.filter { $0.verdict.contains("拒绝") && $0.verdict != "双方拒绝" }.count
            let bothRefused = rows.filter { $0.verdict == "双方拒绝" }.count
            // 解析失败 = 服务器给出了路径而我们没给，同样是算法分歧，必须算硬失败
            let hardFailures = mismatch + rows.filter { $0.verdict == "解析失败" }.count
            let maxLookups = rows.map(\.lookups).max() ?? 0
            print("  一致 \(rows.count - hardFailures - skipped)，不一致 \(mismatch)，"
                  + "解析失败 \(hardFailures - mismatch)，双方都拒绝 \(bothRefused)，仅服务器拒绝 \(skipped)")
            print("  单次解析最多往返 \(maxLookups) 次：同步引擎若逐条目解析路径，成本按条目数乘 RTT")
            exit(hardFailures == 0 ? 0 : 1)
        } catch {
            print("FAIL \(error)")
            exit(1)
        }
    }

    static func execute(sftp: OpaquePointer, session: OpaquePointer) throws -> [Row] {
        guard let root = try realPath(sftp, b(".")) else {
            throw OracleError(step: "realpath(.)", detail: "服务器拒绝给出登录目录")
        }
        print("登录目录（SFTP 视图）= \(show(root))")
        // atmoz 会把用户 chroot 到家目录，而 chroot 根必须 root:root 属主，
        // 可写的只有 upload/ 子目录。写哪里不是重点，"能写在哪"必须先问服务器。
        guard let dir = try writableMazeDir(sftp: sftp, root: root) else {
            throw OracleError(step: "mkdir", detail: "登录目录下没有可写位置放迷宫")
        }
        try probeSymlinkOrder(sftp: sftp, session: session, dir: dir)
        print("SSH_FXP_SYMLINK 参数顺序：\(symlinkOrder)（建链成功时 libssh2 回 rc=\(symlinkRc)）")
        try buildMaze(sftp: sftp, dir: dir)
        let pairs = Dictionary(grouping: mazeSymlinkRcs) { "\($0.rc)/\($0.status)" }
            .map { "\($0.key)×\($0.value.count)" }
            .sorted()
        print("  迷宫建链 \(mazeSymlinkRcs.count) 条全部回读确认，rc/status 分布："
              + pairs.joined(separator: " ") + "（返回码不可信，后端要按回读判定成功）")
        try negativeControl(sftp: sftp, dir: dir)
        // `~` 展开到哪个目录由服务器决定；用 dir 去掉 root 前缀反推，两种目录布局都成立
        var rootPrefix = root
        if rootPrefix.count > 1, rootPrefix.last == separator { rootPrefix = Array(rootPrefix.dropLast()) }
        if rootPrefix == [separator] { rootPrefix = [] }   // chroot 视图里根就是家目录
        let tildeInput = b("~") + dir.dropFirst(rootPrefix.count)
        let cases: [(input: [UInt8], base: [UInt8])] = [
            (dir + b("/abs/f.txt"), root),
            (dir + b("/rel/f.txt"), root),
            (dir + b("/up/f.txt"), root),
            (dir + b("/chain1/f.txt"), root),
            (dir + b("/nested/a/f.txt"), root),
            (dir + b("/trailing/f.txt"), root),
            (dir + b("/doubleslash/f.txt"), root),
            (dir + b("/dotdot/f.txt"), root),
            (dir + b("/abs/../dir2"), root),
            (dir + b("/rel/.."), root),
            (dir + b("/abs/./f.txt"), root),
            (dir + b("//abs//f.txt"), root),
            (b("//") + dir.dropFirst(1) + b("/abs/f.txt"), root),
            (dir + b("/abs/"), root),
            (dir + b("/filelink"), root),
            (dir + b("/broken"), root),
            (dir + b("/broken/deeper"), root),
            (dir + b("/loopa/f.txt"), root),
            (dir + [0xCA, 0xD6], root),
            (dir + b("/gbklink"), root),
            (dir + b("/nope/x.txt"), root),
            (b("abs/f.txt"), dir),
            (b("../m0b-maze/rel/f.txt"), dir),
            (tildeInput + b("/rel/f.txt"), root),
            (b("."), root),
            (b("/"), root)
        ]

        var rows: [Row] = []
        for testCase in cases {
            let counter = Counter()
            let resolver = PathResolver(homeDirectory: RemotePath(wireBytes: root, isAbsolute: true))
            let base = RemotePath(wireBytes: testCase.base, isAbsolute: true)

            let started = Date()
            let serverValue = try realPath(sftp, testCase.input)
            let elapsedMs = Date().timeIntervalSince(started) * 1000
            var mine: [UInt8]?
            var failure: String?
            do {
                mine = try resolver.resolve(
                    RemotePath(wireBytes: testCase.input, isAbsolute: testCase.input.first == separator),
                    relativeTo: base
                ) { candidate in
                    counter.lookups += 1
                    return try readLink(sftp, candidate.wireBytes)
                }.wireBytes
            } catch let error as PathResolutionError {
                failure = "\(error)"
            }

            let verdict: String
            if let serverValue, let mine {
                verdict = serverValue == mine ? "一致" : "不一致"
            } else if serverValue == nil {
                // 服务器拒绝而我们能解析，全部是"要求路径存在"或"不展开 ~"这类语义差，
                // 不是算法分歧；两边都拒绝则说明环检测也对上了。
                verdict = mine == nil ? "双方拒绝" : "仅服务器拒绝"
            } else {
                verdict = "解析失败"
            }
            rows.append(Row(input: show(testCase.input),
                            server: serverValue.map(show) ?? "<拒绝>",
                            mine: mine.map(show) ?? "<\(failure ?? "nil")>",
                            verdict: verdict, lookups: counter.lookups, ms: elapsedMs))
        }
        return rows
    }

    /// 逐个试可写位置，返回第一个建出目录的绝对路径（SFTP 视图）。
    private static func writableMazeDir(sftp: OpaquePointer, root: [UInt8]) throws -> [UInt8]? {
        var candidates: [[UInt8]] = [try under(root, "upload/m0b-maze")]
        if root != [separator] { candidates.append(try under(root, "m0b-maze")) }
        for candidate in candidates {
            _ = rmdir(sftp, candidate)
            // 上一轮留下的目录也算可写：mkdir 对已存在路径一定失败，不能当成"不可写"
            if tryMkdir(sftp, candidate) || isDirectory(sftp, candidate) { return candidate }
            let rc = mkdirRc(sftp, candidate)
            print("  可写位置探测失败：\(show(candidate)) rc=\(rc) status=\(libssh2_sftp_last_error(sftp))")
        }
        return nil
    }

    private static func isDirectory(_ sftp: OpaquePointer, _ bytes: [UInt8]) -> Bool {
        var attrs = LIBSSH2_SFTP_ATTRIBUTES()
        let rc = cstr(bytes) { libssh2_sftp_stat_ex(sftp, $0, UInt32(bytes.count), LIBSSH2_SFTP_STAT, &attrs) }
        return rc == 0 && (attrs.permissions & linkMask) == 0o040000
    }

    private static func mkdirRc(_ sftp: OpaquePointer, _ bytes: [UInt8]) -> Int32 {
        let mode = Int(LIBSSH2_SFTP_S_IRWXU | LIBSSH2_SFTP_S_IRGRP | LIBSSH2_SFTP_S_IXGRP |
                       LIBSSH2_SFTP_S_IROTH | LIBSSH2_SFTP_S_IXOTH)
        let rc = cstr(bytes) { libssh2_sftp_mkdir_ex(sftp, $0, UInt32(bytes.count), mode) }
        return rc
    }

    /// 逐级拼接，专挑 `PathResolver.child` 的毛病：根目录是 "/" 时手拼会得到 "//x"。
    private static func under(_ parent: [UInt8], _ tail: String) throws -> [UInt8] {
        var current = RemotePath(wireBytes: parent, isAbsolute: true)
        for component in tail.split(separator: "/", omittingEmptySubsequences: true) {
            current = try PathResolver.child(of: current, name: b(String(component)))
        }
        return current.wireBytes
    }

    /// 幂等建迷宫：先尽力清干净再建。`symlink_ex` 的参数顺序是"目标在前、链在后"。
    private static func buildMaze(sftp: OpaquePointer, dir: [UInt8]) throws {
        let cleanup: [[UInt8]] = [
            dir + b("/abs"), dir + b("/rel"), dir + b("/up"), dir + b("/chain1"), dir + b("/chain2"),
            dir + b("/nested/a"), dir + b("/nested"), dir + b("/trailing"), dir + b("/doubleslash"),
            dir + b("/dotdot"), dir + b("/filelink"), dir + b("/broken"), dir + b("/loopa"), dir + b("/loopb"),
            dir + b("/self"), dir + b("/gbklink"), dir + [0xCA, 0xD6],
            dir + b("/dir1/chain2"), dir + b("/dir1/f.txt"), dir + b("/dir1"), dir + b("/dir2"), dir
        ]
        for path in cleanup {
            _ = unlink(sftp, path)
            _ = rmdir(sftp, path)
        }

        try mkdir(sftp, dir)
        try mkdir(sftp, dir + b("/dir1"))
        try mkdir(sftp, dir + b("/dir2"))
        try mkdir(sftp, dir + b("/nested"))
        try write(sftp, dir + b("/dir1/f.txt"), payload: b("ferry-m0b\n"))
        try write(sftp, dir + [0xCA, 0xD6], payload: b("gbk-name\n"))

        try symlink(sftp: sftp, target: dir + b("/dir1"), link: dir + b("/abs"))
        try symlink(sftp: sftp, target: b("dir1"), link: dir + b("/rel"))
        try symlink(sftp: sftp, target: b("../m0b-maze/dir1"), link: dir + b("/up"))
        try symlink(sftp: sftp, target: b("chain2"), link: dir + b("/chain1"))
        try symlink(sftp: sftp, target: b("dir1"), link: dir + b("/chain2"))
        try symlink(sftp: sftp, target: b("dir1"), link: dir + b("/dir1/chain2"))
        try symlink(sftp: sftp, target: b("../dir1"), link: dir + b("/nested/a"))
        try symlink(sftp: sftp, target: b("dir1/"), link: dir + b("/trailing"))
        // 目标里塞重复分隔符：服务器折叠成什么样，PathResolver 就得折叠成什么样
        try symlink(sftp: sftp, target: dir + b("//dir1"), link: dir + b("/doubleslash"))
        try symlink(sftp: sftp, target: b("dir2/../dir1"), link: dir + b("/dotdot"))
        try symlink(sftp: sftp, target: b("dir1/f.txt"), link: dir + b("/filelink"))
        try symlink(sftp: sftp, target: b("nowhere"), link: dir + b("/broken"))
        try symlink(sftp: sftp, target: b("loopb"), link: dir + b("/loopa"))
        try symlink(sftp: sftp, target: b("loopa"), link: dir + b("/loopb"))
        try symlink(sftp: sftp, target: b("self"), link: dir + b("/self"))
        try symlink(sftp: sftp, target: [0xCA, 0xD6], link: dir + b("/gbklink"))
    }

    /// libssh2 只接受 C 字符串，长度却是独立参数，所以补一个终止符就够；
    /// `>=0x80` 的字节不参与任何解释，GBK 文件名原样送出。
    private static func cstr<R>(_ bytes: [UInt8], _ body: (UnsafePointer<CChar>) throws -> R) rethrows -> R {
        var terminated = bytes
        terminated.append(0)
        return try terminated.withUnsafeBytes { raw in
            try body(UnsafeRawPointer(raw.baseAddress!).assumingMemoryBound(to: CChar.self))
        }
    }

    private static func mkdir(_ sftp: OpaquePointer, _ bytes: [UInt8]) throws {
        guard tryMkdir(sftp, bytes) else { throw OracleError(step: "mkdir", detail: show(bytes)) }
    }

    @discardableResult private static func tryMkdir(_ sftp: OpaquePointer, _ bytes: [UInt8]) -> Bool {
        let mode = Int(LIBSSH2_SFTP_S_IRWXU | LIBSSH2_SFTP_S_IRGRP | LIBSSH2_SFTP_S_IXGRP |
                       LIBSSH2_SFTP_S_IROTH | LIBSSH2_SFTP_S_IXOTH)
        let rc = cstr(bytes) { libssh2_sftp_mkdir_ex(sftp, $0, UInt32(bytes.count), mode) }
        return rc == 0
    }

    private static func write(_ sftp: OpaquePointer, _ bytes: [UInt8], payload: [UInt8]) throws {
        let flags = UInt(LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_TRUNC)
        let mode = Int(LIBSSH2_SFTP_S_IRUSR | LIBSSH2_SFTP_S_IWUSR | LIBSSH2_SFTP_S_IRGRP | LIBSSH2_SFTP_S_IROTH)
        guard let handle = cstr(bytes, { pointer in
            libssh2_sftp_open_ex(sftp, pointer, UInt32(bytes.count), flags, mode, LIBSSH2_SFTP_OPENFILE)
        }) else { throw OracleError(step: "open_write", detail: show(bytes)) }
        defer { libssh2_sftp_close_handle(handle) }
        let rc = cstr(payload) { libssh2_sftp_write(handle, $0, payload.count) }
        guard rc == payload.count else {
            throw OracleError(step: "write", detail: "\(show(bytes)) rc=\(rc)")
        }
    }

    /// 可变版：`symlink_ex` 把"链本身"这一组参数声明成 `char *`（它本意是输出缓冲），
    /// 所以创建软链时链路径必须送可变指针。
    private static func cstrMutable<R>(_ bytes: [UInt8], _ body: (UnsafeMutablePointer<CChar>) throws -> R) rethrows -> R {
        var terminated = bytes
        terminated.append(0)
        return try terminated.withUnsafeMutableBytes { raw in
            try body(raw.bindMemory(to: CChar.self).baseAddress!)
        }
    }

    /// 服务器之间 SSH_FXP_SYMLINK 的参数顺序不一致：libssh2 的头文件宏按"目标在前"传，
    /// OpenSSH 的 sftp-server 却按"链在前"读。后端创建软链时必须按服务器实际接受的顺序发，
    /// 所以先探测一次，而不是每个链都试两种。
    nonisolated(unsafe) static var symlinkOrder: String = "未测"

    /// 建链成功时 libssh2 实际回的是什么码——后端判定成功要按这个来，不能假设 0。
    nonisolated(unsafe) static var symlinkRc: Int32 = 0

    /// 迷宫里每条链的（rc, sftp_last_error），用来回答"rc=-31 是探测的偶发还是 libssh2 的常态"。
    /// 状态码必须紧跟建链请求取，后面的回读会覆盖它。
    nonisolated(unsafe) static var mazeSymlinkRcs: [(rc: Int32, status: UInt)] = []

    private static func symlinkRaw(sftp: OpaquePointer, first: [UInt8], second: [UInt8]) -> Int32 {
        let rc = cstr(first) { a in
            cstrMutable(second) { b2 in
                libssh2_sftp_symlink_ex(sftp, a, UInt32(first.count), b2, UInt32(second.count),
                                        LIBSSH2_SFTP_SYMLINK)
            }
        }
        return rc
    }

    /// 探测用的两个路径都在迷宫目录里，且都用绝对路径：猜错顺序时最坏情况是在这两个名字上
    /// 建出错误的链，而不是污染迷宫别处。相对路径会让两种顺序都撞到"已存在"，探不出真相。
    ///
    /// 判据是回读而不是返回码：libssh2 在服务器已经建好链时也可能回负码，
    /// 只有 `readlink(链) == 目标` 才证明这条顺序真的对。
    private static func probeSymlinkOrder(sftp: OpaquePointer, session: OpaquePointer, dir: [UInt8]) throws {
        let src = dir + b("/.probe-src")
        let link = dir + b("/.probe-link")
        _ = unlink(sftp, src)
        _ = unlink(sftp, link)
        try write(sftp, src, payload: b("p\n"))

        let orders: [(label: String, first: [UInt8], second: [UInt8])] = [
            ("目标在前", src, link),
            ("链在前", link, src)
        ]
        for order in orders {
            _ = unlink(sftp, link)
            guard try readLink(sftp, link) == nil else {
                throw OracleError(step: "symlink 探测", detail:
                    "unlink 之后 \(show(link)) 仍是软链，探测环境不干净")
            }
            let rc = symlinkRaw(sftp: sftp, first: order.first, second: order.second)
            // 必须在 readLink 之前取：下一个请求会覆盖 last_error 与会话消息
            let status = libssh2_sftp_last_error(sftp)
            let message = ThroughputSpike.lastSessionError(session)
            let target = try readLink(sftp, link)
            print("  顺序 \(order.label)：rc=\(rc) status=\(status) 会话错误=\"\(message)\" "
                  + "readlink(链)=\(target.map(show) ?? "nil")")
            if target == src {
                symlinkOrder = order.label
                symlinkRc = rc
                break
            }
        }
        _ = unlink(sftp, link)
        _ = unlink(sftp, src)
        guard symlinkOrder != "未测" else {
            throw OracleError(step: "symlink", detail: "两种参数顺序都无法建出预期的链")
        }
    }

    /// 负向对照：父目录不存在，服务器必然拒绝。拿它和"建成功"的那次返回值比，
    /// 才能判定后端有没有可能只靠 rc 区分成功与失败。
    private static func negativeControl(sftp: OpaquePointer, dir: [UInt8]) throws {
        let link = dir + b("/.nope-dir/.control-link")
        let rc = symlinkOrder == "链在前"
            ? symlinkRaw(sftp: sftp, first: link, second: dir + b("/dir1"))
            : symlinkRaw(sftp: sftp, first: dir + b("/dir1"), second: link)
        let status = libssh2_sftp_last_error(sftp)
        let exists = try readLink(sftp, link) != nil
        print("  负向对照（父目录不存在）：rc=\(rc) status=\(status) 链\(exists ? "竟存在" : "不存在")")
    }

    /// 建链后回读判定：探测已经证明 `rc` 与"链是否建好"不完全对应。
    /// `readlink` 返回写入时的原始字节，所以相对目标也能逐字节比对。
    private static func symlink(sftp: OpaquePointer, target: [UInt8], link: [UInt8]) throws {
        _ = unlink(sftp, link)
        let rc = symlinkOrder == "链在前"
            ? symlinkRaw(sftp: sftp, first: link, second: target)
            : symlinkRaw(sftp: sftp, first: target, second: link)
        // 状态码必须紧跟请求取，随后的回读会覆盖它
        let status = libssh2_sftp_last_error(sftp)
        guard try readLink(sftp, link) == target else {
            throw OracleError(step: "symlink", detail:
                "\(show(link)) -> \(show(target)) rc=\(rc) status=\(status)")
        }
        mazeSymlinkRcs.append((rc: rc, status: status))
    }

    @discardableResult private static func unlink(_ sftp: OpaquePointer, _ bytes: [UInt8]) -> Bool {
        cstr(bytes) { libssh2_sftp_unlink_ex(sftp, $0, UInt32(bytes.count)) } == 0
    }

    @discardableResult private static func rmdir(_ sftp: OpaquePointer, _ bytes: [UInt8]) -> Bool {
        cstr(bytes) { libssh2_sftp_rmdir_ex(sftp, $0, UInt32(bytes.count)) } == 0
    }

    /// 非软链与不存在都返回 nil：PathResolver 把两者都当成"这一段不是链"，
    /// 与内核路径查找的处理一致。
    private static func readLink(_ sftp: OpaquePointer, _ bytes: [UInt8]) throws -> [UInt8]? {
        var attrs = LIBSSH2_SFTP_ATTRIBUTES()
        let rc = cstr(bytes) {
            libssh2_sftp_stat_ex(sftp, $0, UInt32(bytes.count), LIBSSH2_SFTP_LSTAT, &attrs)
        }
        guard rc == 0, (attrs.permissions & linkMask) == linkBits else { return nil }
        return try symlinkRead(sftp, bytes, LIBSSH2_SFTP_READLINK)
    }

    private static func realPath(_ sftp: OpaquePointer, _ bytes: [UInt8]) throws -> [UInt8]? {
        try symlinkRead(sftp, bytes, LIBSSH2_SFTP_REALPATH)
    }

    /// 服务器拒绝（不存在、ELOOP、权限）不是解析错误，返回 nil 交给调用方判定。
    private static func symlinkRead(_ sftp: OpaquePointer, _ bytes: [UInt8], _ kind: Int32) throws -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let capacity = buffer.count   // 独占访问期间不能再读 buffer.count
        let n: Int = try buffer.withUnsafeMutableBytes { raw in
            guard let base = raw.bindMemory(to: CChar.self).baseAddress else {
                throw OracleError(step: "buffer", detail: "空缓冲")
            }
            return try cstr(bytes) { pointer in
                let rc = libssh2_sftp_symlink_ex(sftp, pointer, UInt32(bytes.count), base,
                                                 UInt32(capacity), kind)
                if rc == LIBSSH2_ERROR_FILE || rc == LIBSSH2_ERROR_SFTP_PROTOCOL { return -1 }
                guard rc >= 0 else { throw OracleError(step: "symlink_read", detail: "\(show(bytes)) rc=\(rc)") }
                return Int(rc)
            }
        }
        guard n >= 0 else { return nil }
        return Array(buffer[0..<n])
    }

    private static func show(_ bytes: [UInt8]) -> String {
        RemotePath(wireBytes: bytes, isAbsolute: bytes.first == separator).displayString()
    }
}
