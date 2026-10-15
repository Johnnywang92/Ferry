import CLibssh2
import Foundation

/// spike #6：1000 个 1 KB 小文件的批量往返。
///
/// 验收标准是"记录总耗时与内存峰值，确认瓶颈是 round-trip 还是 UI 刷新"。
/// 网络侧能测干净：清单、逐文件 open/read/close、复用与并发档位、每次完成的间隔。
/// 间隔这一项直接回答"卡顿来自哪"——若最长间隔≈单文件往返，则瓶颈是 round-trip。
enum SmallFileSpike {

    struct Entry {
        let name: String
        let size: Int64
    }

    struct Result {
        let label: String
        let files: Int
        let wallMs: Double
        let userMs: Double
        let sysMs: Double
        let bytes: Int64
        let rssBefore: Int
        let rssAfter: Int
        let maxGapMs: Double
        var perFileMs: Double { wallMs / Double(max(files, 1)) }
        var filesPerSec: Double { Double(files) / (wallMs / 1000.0) }
        var cores: Double { (userMs + sysMs) / wallMs }
    }

    final class Stats: @unchecked Sendable {
        let lock = NSLock()
        var count = 0
        var maxGapMs = 0.0
        var last = Date()
        func tick() {
            lock.lock(); defer { lock.unlock() }
            let now = Date()
            maxGapMs = max(maxGapMs, now.timeIntervalSince(last) * 1000)
            last = now
            count += 1
        }
    }

    /// getrusage 的 ru_maxrss 只增不减，多档位横向对比要用当前驻留量
    static func currentRSS() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int(info.resident_size) : 0
    }

    // MARK: - 单文件原语

    static func openRead(_ sftp: OpaquePointer, _ path: String) throws -> OpaquePointer {
        guard let handle = path.withCString({ pointer in
            libssh2_sftp_open_ex(sftp, pointer, UInt32(strlen(pointer)),
                                 UInt(LIBSSH2_FXF_READ), 0, LIBSSH2_SFTP_OPENFILE)
        }) else { throw ThroughputSpike.Failure(step: "open", detail: path) }
        return handle
    }

    static func drain(_ handle: OpaquePointer, buffer: UnsafeMutablePointer<Int8>, size: Int) throws -> Int64 {
        var total: Int64 = 0
        while true {
            let rc = libssh2_sftp_read(handle, buffer, size)
            if rc == 0 { break }
            if rc < 0 { throw ThroughputSpike.Failure(step: "read", detail: "code=\(rc)") }
            total += Int64(rc)
        }
        return total
    }

    static func readOne(_ sftp: OpaquePointer, path: String,
                        buffer: UnsafeMutablePointer<Int8>, size: Int) throws -> Int64 {
        let handle = try openRead(sftp, path)
        defer { libssh2_sftp_close_handle(handle) }
        return try drain(handle, buffer: buffer, size: size)
    }

    static func writeOne(_ sftp: OpaquePointer, path: String,
                         buffer: UnsafeMutablePointer<Int8>, size: Int) throws -> Int64 {
        let mode = UInt(LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_TRUNC)
        let permissions = Int(LIBSSH2_SFTP_S_IRUSR | LIBSSH2_SFTP_S_IWUSR |
                                     LIBSSH2_SFTP_S_IRGRP | LIBSSH2_SFTP_S_IROTH)
        guard let handle = path.withCString({ pointer in
            libssh2_sftp_open_ex(sftp, pointer, UInt32(strlen(pointer)), mode, permissions, LIBSSH2_SFTP_OPENFILE)
        }) else { throw ThroughputSpike.Failure(step: "open_write", detail: path) }
        defer { libssh2_sftp_close_handle(handle) }
        var written: Int64 = 0
        while written < Int64(size) {
            let rc = libssh2_sftp_write(handle, buffer.advanced(by: Int(written)), size - Int(written))
            if rc < 0 { throw ThroughputSpike.Failure(step: "write", detail: "\(path) code=\(rc)") }
            written += Int64(rc)
        }
        return written
    }

    static func statOne(_ sftp: OpaquePointer, path: String) -> Int64? {
        var attrs = LIBSSH2_SFTP_ATTRIBUTES()
        let rc = path.withCString { pointer in
            libssh2_sftp_stat_ex(sftp, pointer, UInt32(strlen(pointer)), LIBSSH2_SFTP_STAT, &attrs)
        }
        return rc == 0 ? Int64(attrs.filesize) : nil
    }

    static func listDirectory(_ session: OpaquePointer, dir: String) throws -> [Entry] {
        guard let sftp = libssh2_sftp_init(session) else {
            throw ThroughputSpike.Failure(step: "sftp_init", detail: ThroughputSpike.lastSessionError(session))
        }
        defer { libssh2_sftp_shutdown(sftp) }
        guard let dirHandle = dir.withCString({ pointer in
            libssh2_sftp_open_ex(sftp, pointer, UInt32(strlen(pointer)), UInt(LIBSSH2_FXF_READ), 0,
                                 LIBSSH2_SFTP_OPENDIR)
        }) else { throw ThroughputSpike.Failure(step: "opendir", detail: dir) }
        defer { libssh2_sftp_close_handle(dirHandle) }

        // readdir_ex 的第 2 个缓冲是"文件名"，第 4 个才是 ls -l 风格的 longentry，
        // 顺序写反会把 longentry 当成文件名读回来。
        let nameSize = 256, longSize = 4096
        let nameBuffer = UnsafeMutablePointer<Int8>.allocate(capacity: nameSize)
        let longBuffer = UnsafeMutablePointer<Int8>.allocate(capacity: longSize)
        defer { nameBuffer.deallocate(); longBuffer.deallocate() }

        var entries: [Entry] = []
        var attrs = LIBSSH2_SFTP_ATTRIBUTES()
        while true {
            let rc = libssh2_sftp_readdir_ex(dirHandle, nameBuffer, nameSize,
                                             longBuffer, longSize, &attrs)
            if rc == 0 { break }
            if rc < 0 { throw ThroughputSpike.Failure(step: "readdir", detail: "code=\(rc)") }
            let name = String(cString: nameBuffer)
            if name != "." && name != ".." { entries.append(Entry(name: name, size: Int64(attrs.filesize))) }
        }
        return entries
    }

    // MARK: - 档位

    /// 一条 session 一条 channel：要么每文件 close，要么攒到最后统一 close。
    static func downloadSerial(endpoint: SpikeProbe.Endpoint, dir: String, names: [String],
                               label: String, keepHandlesOpen: Bool = false) throws -> Result {
        let stats = Stats()
        let (fd, session) = try SpikeProbe.authenticatedSession(endpoint)
        let connection = ThroughputSpike.Connection(fd: fd, session: session)
        guard let sftp = libssh2_sftp_init(session) else {
            SpikeProbe.shutdown(session: session, fd: fd)
            throw ThroughputSpike.Failure(step: "sftp_init", detail: ThroughputSpike.lastSessionError(session))
        }

        let size = 4096
        let buffer = UnsafeMutablePointer<Int8>.allocate(capacity: size)
        defer { buffer.deallocate() }

        let rssBefore = currentRSS()
        let cpuStart = ThroughputSpike.cpuSnapshot()
        let start = Date()
        var bytes: Int64 = 0
        var held: [OpaquePointer] = []
        for name in names {
            let path = dir + "/" + name
            if keepHandlesOpen {
                let handle = try openRead(sftp, path)
                held.append(handle)
                bytes += try drain(handle, buffer: buffer, size: size)
            } else {
                bytes += try readOne(sftp, path: path, buffer: buffer, size: size)
            }
            stats.tick()
        }
        // 统一 close 也是往返，放在计时里算进总成本
        if keepHandlesOpen { for handle in held { libssh2_sftp_close_handle(handle) } }
        libssh2_sftp_shutdown(sftp)
        SpikeProbe.shutdown(session: session, fd: fd)
        let wall = Date().timeIntervalSince(start) * 1000
        let cpu = ThroughputSpike.cpuSnapshot()
        return report(Result(label: label, files: names.count, wallMs: wall,
                             userMs: cpu.user - cpuStart.user, sysMs: cpu.sys - cpuStart.sys,
                             bytes: bytes, rssBefore: rssBefore, rssAfter: currentRSS(),
                             maxGapMs: stats.maxGapMs))
    }

    /// 反面教材：每个文件都新建一条连接（握手 + 认证 + sftp_init + open + close + 拆连接）
    static func downloadFreshSession(endpoint: SpikeProbe.Endpoint, dir: String,
                                     names: [String]) throws -> Result {
        let stats = Stats()
        let size = 4096
        let buffer = UnsafeMutablePointer<Int8>.allocate(capacity: size)
        defer { buffer.deallocate() }

        let rssBefore = currentRSS()
        let cpuStart = ThroughputSpike.cpuSnapshot()
        let start = Date()
        var bytes: Int64 = 0
        for name in names {
            let (fd, session) = try SpikeProbe.authenticatedSession(endpoint)
            defer { SpikeProbe.shutdown(session: session, fd: fd) }
            guard let sftp = libssh2_sftp_init(session) else {
                throw ThroughputSpike.Failure(step: "sftp_init", detail: name)
            }
            bytes += try readOne(sftp, path: dir + "/" + name, buffer: buffer, size: size)
            libssh2_sftp_shutdown(sftp)
            stats.tick()
        }
        let wall = Date().timeIntervalSince(start) * 1000
        let cpu = ThroughputSpike.cpuSnapshot()
        return report(Result(label: "每文件新建连接", files: names.count, wallMs: wall,
                             userMs: cpu.user - cpuStart.user, sysMs: cpu.sys - cpuStart.sys,
                             bytes: bytes, rssBefore: rssBefore, rssAfter: currentRSS(),
                             maxGapMs: stats.maxGapMs))
    }

    /// 方案 A：k 条 session，每条内串行，文件按下标取模分片
    static func downloadPool(endpoint: SpikeProbe.Endpoint, dir: String, names: [String],
                             concurrency: Int) throws -> Result {
        let label = "A \(concurrency) session 分片"
        let stats = Stats()
        var built: [ThroughputSpike.Connection] = []
        for _ in 0..<concurrency {
            let opened = try SpikeProbe.authenticatedSession(endpoint)
            built.append(ThroughputSpike.Connection(fd: opened.fd, session: opened.session))
        }
        let connections = built

        let counter = ThroughputSpike.Counter()
        let failures = ThroughputSpike.FailureBox()
        let group = DispatchGroup()
        let rssBefore = currentRSS()
        let cpuStart = ThroughputSpike.cpuSnapshot()
        let start = Date()

        for slot in 0..<concurrency {
            group.enter()
            DispatchQueue(label: "spike.small.\(slot)").async {
                defer { group.leave() }
                guard failures.failure == nil else { return }
                let connection = connections[slot]
                guard let sftp = libssh2_sftp_init(connection.session) else {
                    failures.failure = ThroughputSpike.Failure(step: "sftp_init",
                                                               detail: ThroughputSpike.lastSessionError(connection.session))
                    return
                }
                let size = 4096
                let buffer = UnsafeMutablePointer<Int8>.allocate(capacity: size)
                defer { buffer.deallocate() }
                var index = slot
                var local: Int64 = 0
                while index < names.count {
                    do { local += try readOne(sftp, path: dir + "/" + names[index], buffer: buffer, size: size) }
                    catch { failures.failure = error as? ThroughputSpike.Failure; break }
                    index += concurrency
                    stats.tick()
                }
                libssh2_sftp_shutdown(sftp)
                counter.bytes += local
            }
        }
        group.wait()
        let wall = Date().timeIntervalSince(start) * 1000
        let cpu = ThroughputSpike.cpuSnapshot()
        for connection in connections { SpikeProbe.shutdown(session: connection.session, fd: connection.fd) }
        if let failure = failures.failure { throw failure }
        return report(Result(label: label, files: names.count, wallMs: wall,
                             userMs: cpu.user - cpuStart.user, sysMs: cpu.sys - cpuStart.sys,
                             bytes: counter.bytes, rssBefore: rssBefore, rssAfter: currentRSS(),
                             maxGapMs: stats.maxGapMs))
    }

    static func uploadSerial(endpoint: SpikeProbe.Endpoint, dir: String, names: [String]) throws -> Result {
        let stats = Stats()
        let size = 1024
        let buffer = UnsafeMutablePointer<Int8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        memset(buffer, 0x5a, size)

        let (fd, session) = try SpikeProbe.authenticatedSession(endpoint)
        guard let sftp = libssh2_sftp_init(session) else {
            SpikeProbe.shutdown(session: session, fd: fd)
            throw ThroughputSpike.Failure(step: "sftp_init", detail: ThroughputSpike.lastSessionError(session))
        }
        let rssBefore = currentRSS()
        let cpuStart = ThroughputSpike.cpuSnapshot()
        let start = Date()
        var bytes: Int64 = 0
        for name in names {
            bytes += try writeOne(sftp, path: dir + "/" + name, buffer: buffer, size: size)
            stats.tick()
        }
        let wall = Date().timeIntervalSince(start) * 1000
        let cpu = ThroughputSpike.cpuSnapshot()
        libssh2_sftp_shutdown(sftp)
        SpikeProbe.shutdown(session: session, fd: fd)
        return report(Result(label: "上传 单channel", files: names.count, wallMs: wall,
                             userMs: cpu.user - cpuStart.user, sysMs: cpu.sys - cpuStart.sys,
                             bytes: bytes, rssBefore: rssBefore, rssAfter: currentRSS(),
                             maxGapMs: stats.maxGapMs))
    }

    @discardableResult
    static func report(_ result: Result) -> Result {
        print(String(format: "  %-24@ %5d 个 %8.1f ms  %6.1f 个/s  每文件 %5.2f ms  CPU %.2f 核  最长间隔 %6.1f ms  RSS %d→%d KB",
                     result.label as NSString, result.files, result.wallMs, result.filesPerSec,
                     result.perFileMs, result.cores, result.maxGapMs,
                     result.rssBefore / 1024, result.rssAfter / 1024))
        return result
    }

    // MARK: - 入口

    static func run() {
        libssh2_init(0)
        defer { libssh2_exit() }
        let endpoint = SpikeProbe.Endpoint.fromEnvironment()
        let env = ProcessInfo.processInfo.environment
        let dir = env["SPIKE_SMALL_DIR"] ?? "/home/tester/spike/small"
        let uploadDir = env["SPIKE_SMALL_UPLOAD"] ?? "/home/tester/spike/upload"
        let limit = Int(env["SPIKE_SMALL_COUNT"] ?? "") ?? 1000
        let freshLimit = Int(env["SPIKE_FRESH_COUNT"] ?? "") ?? 50
        let heldLimit = Int(env["SPIKE_HELD_COUNT"] ?? "") ?? 200

        print("libssh2 \(SpikeProbe.version()) -> \(endpoint.host):\(endpoint.port)")
        print("小文件批量：\(dir)，取前 \(limit) 个（1 KB/个）")

        do {
            let (fd, session) = try SpikeProbe.authenticatedSession(endpoint)
            var start = Date()
            let entries = try listDirectory(session, dir: dir)
            let readdirMs = Date().timeIntervalSince(start) * 1000
            print(String(format: "  %-24@ %5d 条 %8.1f ms  每条 %5.2f ms",
                         "readdir 一次列完" as NSString, entries.count, readdirMs,
                         readdirMs / Double(max(entries.count, 1))))

            let names = Array(entries.map(\.name).sorted().prefix(limit))
            if let sftp = libssh2_sftp_init(session) {
                start = Date()
                var hit = 0
                for name in names where statOne(sftp, path: dir + "/" + name) != nil { hit += 1 }
                let statMs = Date().timeIntervalSince(start) * 1000
                print(String(format: "  %-24@ %5d 条 %8.1f ms  每条 %5.2f ms（成功 %d）",
                             "逐条 stat" as NSString, names.count, statMs,
                             statMs / Double(max(names.count, 1)), hit))
                libssh2_sftp_shutdown(sftp)
            }
            SpikeProbe.shutdown(session: session, fd: fd)

            _ = try downloadFreshSession(endpoint: endpoint, dir: dir,
                                         names: Array(names.prefix(freshLimit)))
            _ = try downloadSerial(endpoint: endpoint, dir: dir, names: names, label: "单channel 串行")
            _ = try downloadSerial(endpoint: endpoint, dir: dir,
                                   names: Array(names.prefix(heldLimit)),
                                   label: "单channel 攒close", keepHandlesOpen: true)
            for k in [2, 4, 8] {
                _ = try downloadPool(endpoint: endpoint, dir: dir, names: names, concurrency: k)
            }
            _ = try uploadSerial(endpoint: endpoint, dir: uploadDir, names: names)
        } catch {
            print("  失败：\(error)")
        }
    }
}
