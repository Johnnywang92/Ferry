import CLibssh2
import Darwin
import Foundation

/// M1'-6 用：四件只在 libssh2 内部发生、正式路径已经绕开的事，用裸 C 复现一遍。
///
/// ① `fsync` 扩展的支持面：`fsync@openssh.com` 不是 RFC 4716 的一部分，服务器不给时
///    回什么码（决定 `commit()` 能不能把它当失败）。
/// ② 写队列没排空就关闭：`libssh2_sftp_close_handle` 只发 CLOSE、等自己的 STATUS，
///    最后把 `packet_list` 直接 free 掉（sftp.c:2751）。CLOSE 走通道的 outbuf、在途的
///    WRITE 包走 `packet_list`，两条路不是一个队列，所以"服务器上到底留了多少"只能换
///    一条连接去 `stat` 才量得准。顺带数一次干净上传里 `sftp_write` 回 0 出现几次
///    （sftp.c:2183→2203→2292：0 既不是错误也不是 EOF，是"这轮一个字节都没确认"）。
/// ③ `FXF_TRUNC`：不带它去覆盖一个更长的旧文件，尾巴留着上一次的字节。
/// ④ 半途放弃一次 READ：`sftp->read_state` 是通道级状态，放弃之后再发请求会拿到什么。
///    这一条决定"取消只废句柄"还是"整条 session 作废"。
///
/// 每个实验各自开一条 session：② 会把通道弄脏，共用会让③④ 的结论变成"脏状态的连带"，
/// 而不是各自那件事本身的证据。
///
/// 用法：Spike/.build/debug/SpikeRunner xfer-raw      # 五台
///       SPIKE_PORTS="2202" …/SpikeRunner xfer-raw    # 只跑一台
///       SPIKE_ABANDON=16777216 …/SpikeRunner xfer-raw # 换放弃写入的字节数
enum TransferRawSpike {
    private static let ports: [Int] = (ProcessInfo.processInfo.environment["SPIKE_PORTS"]
                                        ?? "2201 2202 2203 2204 2205")
        .split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Int($0) }
    private static let host = ProcessInfo.processInfo.environment["SPIKE_HOST"] ?? "127.0.0.1"
    private static let chunk = Int(ProcessInfo.processInfo.environment["SPIKE_CHUNK"] ?? "") ?? 262_144
    /// 放弃写入那一步交出去的总量。必须**明显大于**环回 socket 缓冲区与 SSH 通道窗口，
    /// 否则内核全收下、close 无可丢，实验就变成"没复现"（第一版就是 1 MB 撞在这上面）。
    private static let abandonBytes
        = Int(ProcessInfo.processInfo.environment["SPIKE_ABANDON"] ?? "") ?? 16_777_216

    private struct Failure: Error, CustomStringConvertible {
        let step: String
        let detail: String
        var description: String { "\(step)：\(detail)" }
    }

    /// 内容按 `byte = offset % 251` 生成：块序错位、漏发一整块、偏移算错都会露出来，
    /// 而全零或整份同一字节的负载对这三类 bug 完全无感。
    private static func byte(at offset: Int) -> UInt8 { UInt8(offset % 251) }
    private static func pattern(_ length: Int) -> [UInt8] { (0..<length).map { byte(at: $0) } }

    private static func errorText(_ session: OpaquePointer) -> String {
        var message: UnsafeMutablePointer<CChar>?
        libssh2_session_last_error(session, &message, nil, 0)
        return message.map { String(cString: $0) } ?? "<无>"
    }

    private static func resolveHome(_ sftp: OpaquePointer) -> String {
        var buffer = [CChar](repeating: 0, count: 1024)
        let dot = "."
        let rc = dot.withCString { p in
            libssh2_sftp_symlink_ex(sftp, p, UInt32(strlen(p)), &buffer, UInt32(buffer.count), LIBSSH2_SFTP_REALPATH)
        }
        if rc > 0 {
            let bytes = buffer.prefix(Int(rc)).map { UInt8(bitPattern: $0) }
            let home = String(decoding: bytes, as: UTF8.self)
            return home == "/" ? "" : home
        }
        return "/home/tester"
    }

    static func run() async {
        print("libssh2 \(SpikeProbe.version())，服务器 = \(ports.map(String.init).joined(separator: " "))")
        print("chunk=\(chunk)  放弃写入=\(abandonBytes)  libssh2 的 SFTP 包上限=30000（sftp.h:47,52）")
        for port in ports {
            print("\n===== \(port) =====")
            attempt { try fsyncExperiment(port) }
            attempt { try drainExperiment(port) }
            attempt { try truncateExperiment(port) }
            attempt { try abandonExperiment(port) }
        }
        print("""

            结论与数字见 docs/spike/M1-06。跑之前先铺语料：Spike/Scripts/seed-transfer-corpus.sh
        """)
    }

    /// 一个实验炸了不影响下一个：② 本来就会把通道弄脏，脏到别的实验里也要能看见结果。
    private static func attempt(_ body: () throws -> Void) {
        do { try body() } catch { print("  失败：\(error)") }
    }

    /// 每个实验一条干净的 session；`sftp` 通道由调用方自己关（`defer`）。
    private static func withSFTP<R>(_ port: Int,
                                    _ body: (OpaquePointer, OpaquePointer, Int32) throws -> R) throws -> R
    {
        let endpoint = SpikeProbe.Endpoint(host: host, port: UInt16(port), user: "tester",
                                          password: "testpass")
        let (fd, session) = try SpikeProbe.authenticatedSession(endpoint)
        libssh2_session_set_timeout(session, 5000)
        defer { SpikeProbe.shutdown(session: session, fd: fd) }
        guard let sftp = libssh2_sftp_init(session) else {
            throw Failure(step: "sftp_init", detail: errorText(session))
        }
        defer { libssh2_sftp_shutdown(sftp) }
        return try body(sftp, session, fd)
    }

    /// 拿一条**全新的**连接去问文件大小。②(c) 那种把原通道弄脏的实验，只有换个视角才
    /// 量得出服务器上真实留了多少字节——脏通道上的 STAT 自己就发不出去。
    private static func remoteSizeText(port: Int, path: String) -> String {
        do {
            return try withSFTP(port) { sftp, session, _ in
                sizeText(sftp, session: session, path: path)
            }
        } catch {
            return "新连接都开不起来：\(error)"
        }
    }

    // MARK: - 建句柄 / 写 / 问大小

    private static func open(sftp: OpaquePointer, session: OpaquePointer, path: String,
                             flags: UInt, mode: Int = Int(0o644)) throws -> OpaquePointer {
        guard let handle = path.withCString({ pointer in
            libssh2_sftp_open_ex(sftp, pointer, UInt32(strlen(pointer)), flags, mode,
                                 LIBSSH2_SFTP_OPENFILE)
        }) else {
            throw Failure(step: "sftp_open \(path)",
                          detail: "session码=\(libssh2_session_last_errno(session)) "
                              + "sftp码=\(libssh2_sftp_last_error(sftp)) \(errorText(session))")
        }
        return handle
    }

    private static func openDirectory(sftp: OpaquePointer, session: OpaquePointer,
                                      path: String) throws -> OpaquePointer {
        guard let handle = path.withCString({ pointer in
            libssh2_sftp_open_ex(sftp, pointer, UInt32(strlen(pointer)), 0, 0, LIBSSH2_SFTP_OPENDIR)
        }) else {
            throw Failure(step: "sftp_opendir \(path)",
                          detail: "sftp码=\(libssh2_sftp_last_error(sftp)) \(errorText(session))")
        }
        return handle
    }

    /// 阻塞模式写到"欠账为 0"。返回每次调用确认了多少（数"一个 chunk 要几轮"）
    /// 和回 0 的次数。**必须容忍 rc=0**：一次调用可能一个字节都没确认（第一发包没发完
    /// 就跳出 ACK 循环，sftp.c:2183→2203→2292），这不是失败，重新交同一串字节就往前走。
    /// 产品侧 `SFTPTransfer.writeChunk` 的 `zeroMeansStall` 分支就是为这一条加的。
    private static func writeAll(_ handle: OpaquePointer, _ payload: [UInt8],
                                 session: OpaquePointer) throws -> (rounds: [Int], zeros: Int) {
        var rounds: [Int] = []
        var zeros = 0
        var sent = 0
        try payload.withUnsafeBytes { raw in
            let base = raw.bindMemory(to: CChar.self).baseAddress!
            // 一次调用最多确认一个包（30000 字节），所以调用次数不该超过包数 + 一点余量。
            let callCap = payload.count / 30_000 + 64
            while sent < payload.count {
                let rc = libssh2_sftp_write(handle, base + sent, payload.count - sent)
                if rc > 0 { rounds.append(Int(rc)); sent += Int(rc); continue }
                if rc == 0 {
                    zeros += 1
                    if rounds.count + zeros >= callCap {
                        throw Failure(step: "sftp_write", detail: "回 0 累计超 \(callCap) 次，卡住了")
                    }
                    continue
                }
                throw Failure(step: "sftp_write",
                              detail: "rc=\(rc) session码=\(libssh2_session_last_errno(session)) "
                                  + "\(errorText(session))")
            }
        }
        return (rounds, zeros)
    }

    /// 问服务器上的大小。返回 nil 表示**这一发 STAT 没成**——不能把失败读成 0：
    /// 脏通道上 `libssh2_sftp_last_error` 恰好是 0，混起来就会把"问不到"写成"丢了 16 MB"。
    private static func size(_ sftp: OpaquePointer, session: OpaquePointer, path: String) -> Int? {
        var attrs = LIBSSH2_SFTP_ATTRIBUTES()
        let rc = path.withCString { pointer in
            libssh2_sftp_stat_ex(sftp, pointer, UInt32(strlen(pointer)), LIBSSH2_SFTP_STAT, &attrs)
        }
        // `LIBSSH2_SFTP_ATTR_SIZE` 导进来是 Int32，`attrs.flags` 是 UInt，得先对齐。
        guard rc == 0, attrs.flags & UInt(LIBSSH2_SFTP_ATTR_SIZE) != 0 else { return nil }
        return Int(attrs.filesize)
    }

    private static func sizeText(_ sftp: OpaquePointer, session: OpaquePointer, path: String) -> String {
        size(sftp, session: session, path: path).map(String.init) ?? "问不到"
    }

    /// 非阻塞下等一次可读/可写，超时 50 ms——与产品里 `SessionLoop` 的切片同宽。
    private static func waitSocket(session: OpaquePointer, fd: Int32) {
        var events: Int16 = 0
        let directions = libssh2_session_block_directions(session)
        if directions & LIBSSH2_SESSION_BLOCK_INBOUND != 0 { events |= Int16(POLLIN) }
        if directions & LIBSSH2_SESSION_BLOCK_OUTBOUND != 0 { events |= Int16(POLLOUT) }
        var descriptor = pollfd(fd: fd, events: events, revents: 0)
        _ = poll(&descriptor, 1, 50)
    }

    /// 非阻塞下调一个会返 EAGAIN 的调用，直到它不再 EAGAIN（或睡满 20 片 = 1 秒）。
    /// 上限取 20 片：睡满还没回来**本身就是结论**（通道锁死），而 4000 片要真等 200 秒。
    private static func drive(session: OpaquePointer, fd: Int32,
                              _ call: () -> Int32) -> (rc: Int32, spins: Int) {
        var rc = call()
        var spins = 0
        while rc == LIBSSH2_ERROR_EAGAIN, spins < 20 {
            waitSocket(session: session, fd: fd)
            rc = call()
            spins += 1
        }
        return (rc, spins)
    }

    // MARK: - ① fsync 扩展支持面

    private static func fsyncExperiment(_ port: Int) throws {
        try withSFTP(port) { sftp, session, _ in
            let home = resolveHome(sftp)
            let path = "\(home)/spike/xfer/raw-fsync.bin"
            let handle = try open(sftp: sftp, session: session, path: path,
                                  flags: UInt(LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_TRUNC))
            _ = try writeAll(handle, Array("fsync probe\n".utf8), session: session)
            let rc = libssh2_sftp_fsync(handle)
            print("  ① fsync：rc=\(rc)  session码=\(libssh2_session_last_errno(session))  "
                  + "sftp码=\(libssh2_sftp_last_error(sftp))  文案=\(errorText(session))")
            _ = libssh2_sftp_close_handle(handle)
        }
    }

    // MARK: - ② 不排空就关闭

    private static func drainExperiment(_ port: Int) throws {
        try withSFTP(port) { sftp, session, fd in
            let home = resolveHome(sftp)
            let path = "\(home)/spike/xfer/raw-drain.bin"
            let total = abandonBytes

            // (a) 对照组：全部确认完再关闭。
            let good = try open(sftp: sftp, session: session, path: path,
                                flags: UInt(LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_TRUNC))
            let payload = pattern(total)
            let drained = try writeAll(good, payload, session: session)
            _ = libssh2_sftp_close_handle(good)
            print("  ②(a) 排空后关闭：远端 \(sizeText(sftp, session: session, path: path)) / \(total) 字节，"
                  + "write 调用 \(drained.rounds.count) 次（单次最多 \(drained.rounds.max() ?? 0) 字节）、"
                  + "回 0 共 \(drained.zeros) 次")

            // (b) 实验组：非阻塞下**一发**交完整块——`sftp_write` 凑到任何一点确认就先回
            // （sftp.c:2208），发不完就先跳出（2183），剩下的包留在 `handle->packet_list`。
            // 立刻关闭：close 只发 CLOSE、等自己的 STATUS，最后 free 掉整个队列（2751）。
            // libssh2 不暴露 `offset_sent`，所以"远端已有多少"只能用 `stat` 反证。
            let fast = try open(sftp: sftp, session: session, path: path,
                                flags: UInt(LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_TRUNC))
            libssh2_session_set_blocking(session, 0)
            var firstRC: Int32 = 0
            payload.withUnsafeBytes { raw in
                firstRC = Int32(libssh2_sftp_write(fast, raw.bindMemory(to: CChar.self).baseAddress!,
                                                   total))
            }
            let (closeRC, closeSpins) = drive(session: session, fd: fd) {
                libssh2_sftp_close_handle(fast)
            }
            let after = size(sftp, session: session, path: path)
            let afterText = after.map(String.init) ?? "问不到"
            let afterVerdict: String
            if let after {
                afterVerdict = after < total
                    ? "★ 少 \(total - after) 字节，被 close 静默丢掉"
                    : "（一个字节没丢：内核全收下了，换大 `SPIKE_ABANDON`）"
            } else {
                afterVerdict = "（STAT 没成：脏通道上问不到，不能读成丢了 \(total) 字节）"
            }
            print("     (b) 一发 write 交 \(total)、回 \(firstRC) 就立刻关闭："
                  + "close 回 \(closeRC)（驱动 \(closeSpins) 片）、远端 \(afterText) 字节  " + afterVerdict)

            // (c) 脏队列之后，同一条通道上开新句柄、发**阻塞** write：libssh2 回什么。
            // 这一条决定产品侧的泵要不要把"回 0"当失败——`SFTPTransfer.writeChunk` 里
            // 那条 `zeroMeansStall` 分支就是为它加的。
            libssh2_session_set_blocking(session, 1)
            if let next = try? open(sftp: sftp, session: session, path: path,
                                   flags: UInt(LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_TRUNC)) {
                var rcs: [Int32] = []
                var credited = 0
                payload.withUnsafeBytes { raw in
                    let base = raw.bindMemory(to: CChar.self).baseAddress!
                    while credited < total, rcs.count < 200 {
                        let rc = libssh2_sftp_write(next, base + credited, total - credited)
                        rcs.append(Int32(rc))
                        if rc > 0 { credited += Int(rc) } else if rc < 0 { break }
                    }
                }
                let zeroCount = rcs.filter { $0 == 0 }.count
                let lastRC = rcs.last ?? 0
                print("     (c) 关闭后新句柄阻塞 write：调用 \(rcs.count) 次、回 0 共 \(zeroCount) 次、"
                      + "末次 rc=\(lastRC) session码=\(libssh2_session_last_errno(session)) "
                      + "确认 \(credited)/\(total) 字节  "
                      + (zeroCount > 0 ? "★ 0 不是错误也不是 EOF，是这轮没确认" : "（这次没回 0）"))
                _ = libssh2_sftp_close_handle(next)
            } else {
                print("     (c) 关闭后新句柄 open 失败：脏通道上服务器拒绝开句柄")
            }
        }
    }

    // MARK: - ③ FXF_TRUNC

    private static func truncateExperiment(_ port: Int) throws {
        try withSFTP(port) { sftp, session, _ in
            let home = resolveHome(sftp)
            let path = "\(home)/spike/xfer/raw-trunc.bin"
            let long = 3_000_000
            let short = 100_000
            let seed = try open(sftp: sftp, session: session, path: path,
                                flags: UInt(LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_TRUNC))
            _ = try writeAll(seed, pattern(long), session: session)
            _ = libssh2_sftp_close_handle(seed)

            // 不带 TRUNC，从 0 写短内容：尾巴留着上一次的字节。
            let noTrunc = try open(sftp: sftp, session: session, path: path,
                                   flags: UInt(LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT))
            libssh2_sftp_seek64(noTrunc, 0)
            _ = try writeAll(noTrunc, pattern(short), session: session)
            _ = libssh2_sftp_close_handle(noTrunc)
            let without = size(sftp, session: session, path: path)

            let withHandle = try open(sftp: sftp, session: session, path: path,
                                      flags: UInt(LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_TRUNC))
            _ = try writeAll(withHandle, pattern(short), session: session)
            _ = libssh2_sftp_close_handle(withHandle)
            let with = size(sftp, session: session, path: path)
            print("  ③ 用 \(short) 字节覆盖 \(long) 字节旧文件：不带 TRUNC → "
                  + "\(without.map(String.init) ?? "问不到") 字节，"
                  + "带 TRUNC → \(with.map(String.init) ?? "问不到") 字节  "
                  + (without == long ? "★ 旧尾巴还在（静默损坏）" : "对照没复现"))
        }
    }

    // MARK: - ④ 半途放弃一次 READ

    private static func abandonExperiment(_ port: Int) throws {
        try withSFTP(port) { sftp, session, fd in
            let home = resolveHome(sftp)
            let path = "\(home)/spike/xfer/raw-abandon.bin"
            let total = 1_048_576
            let seed = try open(sftp: sftp, session: session, path: path,
                                flags: UInt(LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_TRUNC))
            _ = try writeAll(seed, pattern(total), session: session)
            _ = libssh2_sftp_close_handle(seed)

            let handle = try open(sftp: sftp, session: session, path: path,
                                  flags: UInt(LIBSSH2_FXF_READ), mode: 0)
            let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: chunk)
            defer { buffer.deallocate() }

            // 非阻塞读满 256 KB，但故意在第 21 片 EAGAIN 时停手：此刻通道上挂着
            // 一个 `sftp->read_state != idle` 的在途 READ。
            libssh2_session_set_blocking(session, 0)
            var received = 0
            var polls = 0
            var parked = false
            while received < chunk {
                let rc = libssh2_sftp_read(handle, buffer + received, chunk - received)
                if rc > 0 { received += Int(rc); continue }
                if rc == 0 { break }
                if rc == LIBSSH2_ERROR_EAGAIN {
                    polls += 1
                    if polls > 20 { parked = true; break }
                    waitSocket(session: session, fd: fd)
                    continue
                }
                libssh2_session_set_blocking(session, 1)
                throw Failure(step: "sftp_read(非阻塞)", detail: "rc=\(rc) \(errorText(session))")
            }
            libssh2_session_set_blocking(session, 1)
            print("  ④ 半途放弃一次 READ：已收 \(received)/\(chunk) 字节，poll \(polls) 片后停手（parked=\(parked)）")

            // (a) 通道上还挂着未完成的 READ 时，先发一发别的请求（STAT）
            var attrs = LIBSSH2_SFTP_ATTRIBUTES()
            let statRC = path.withCString { pointer in
                libssh2_sftp_stat_ex(sftp, pointer, UInt32(strlen(pointer)), LIBSSH2_SFTP_STAT, &attrs)
            }
            print("     (a) 立即发 STAT：rc=\(statRC)  session码=\(libssh2_session_last_errno(session))  "
                  + "sftp码=\(libssh2_sftp_last_error(sftp))  \(errorText(session))")

            // (b) 再回来把被打断的那个句柄读完，逐字节核对偏移有没有跑偏
            var offset = received
            var firstBad = -1
            var readError: Int32 = 0
            while offset < total {
                let rc = libssh2_sftp_read(handle, buffer, chunk)
                if rc == 0 { break }
                if rc < 0 { readError = Int32(rc); break }
                for index in 0..<Int(rc) where buffer[index] != CChar(bitPattern: byte(at: offset + index)) {
                    if firstBad < 0 { firstBad = offset + index }
                    break
                }
                offset += Int(rc)
            }
            print("     (b) 续读同一句柄：到 \(offset)/\(total) 字节，首个错字节 "
                  + "\(firstBad < 0 ? "没有" : "\(firstBad)")  读错误 rc=\(readError)  "
                  + "session码=\(libssh2_session_last_errno(session))")

            // (c) 关掉这个句柄、开一条新的，在同一通道上从 0 再读一遍
            _ = libssh2_sftp_close_handle(handle)
            let fresh = try open(sftp: sftp, session: session, path: path,
                                 flags: UInt(LIBSSH2_FXF_READ), mode: 0)
            let freshRC = libssh2_sftp_read(fresh, buffer, chunk)
            var freshBad = -1
            if freshRC > 0 {
                for index in 0..<Int(freshRC) where buffer[index] != CChar(bitPattern: byte(at: index)) {
                    freshBad = index; break
                }
            }
            print("     (c) 新句柄从 0 再读：rc=\(freshRC)  首个错字节 "
                  + "\(freshBad < 0 ? "没有" : "\(freshBad)")  sftp码=\(libssh2_sftp_last_error(sftp))")
            _ = libssh2_sftp_close_handle(fresh)

            // (d) 同通道开目录：这一串之后 readdir 还正不正常
            let directory = try openDirectory(sftp: sftp, session: session, path: "\(home)/spike/xfer")
            var name = [UInt8](repeating: 0, count: 1024)
            var readdirAttrs = LIBSSH2_SFTP_ATTRIBUTES()
            let entries = name.withUnsafeMutableBytes { raw -> Int in
                let base = raw.bindMemory(to: CChar.self).baseAddress!
                var count = 0
                while true {
                    // `libssh2_sftp_readdir` 是宏，Swift 导不进来；`longentry` 给 NULL 就行。
                    let rc = libssh2_sftp_readdir_ex(directory, base, 1024, nil, 0, &readdirAttrs)
                    if rc > 0 { count += 1; continue }
                    break
                }
                return count
            }
            print("     (d) 同通道 readdir：读到 \(entries) 条  "
                  + "rc后 session码=\(libssh2_session_last_errno(session))  sftp码=\(libssh2_sftp_last_error(sftp))")
            _ = libssh2_sftp_close_handle(directory)
        }
    }
}
