import CLibssh2
import Foundation

/// spike #2/#3：三种并发方案的吞吐与 CPU 实测。
///
///   A = 多 Session 连接池：每 worker 一条 TCP + 一个独立 session，
///       服务端是 N 个 sshd 子进程 → 加密可跨核。
///   B = 单 Session 多 Channel：一条 TCP 上开 N 个 channel，
///       单线程 poll 复用 → 加密集中在一个核。
///   C = 单 Channel 请求流水线：一条 TCP 一个 channel 上排 N 个并发请求，
///       与 B 同为一个线程，区别只在 channel 数。
///
/// 三个方案读的是同一个文件的互不重叠区间，聚合字节数与耗时才可比。
/// session/channel/handle 全部在计时前建好，避免把握手成本混进吞吐。
enum ThroughputSpike {

    struct Failure: Error, CustomStringConvertible {
        let step: String
        let detail: String
        var description: String { "spike 失败于 \(step)：\(detail)" }
    }

    /// libssh2 的句柄不是 Sendable，用 @unchecked 壳把它带进 worker 队列。
    final class Connection: @unchecked Sendable {
        let fd: Int32
        let session: OpaquePointer
        init(fd: Int32, session: OpaquePointer) { self.fd = fd; self.session = session }
    }

    final class Counter: @unchecked Sendable {
        var bytes: Int64 = 0
        var calls: Int = 0
        var maxChunk: Int = 0
        var eagain: Int = 0
        var polls: Int = 0
        var pollTimeouts: Int = 0
    }

    final class FailureBox: @unchecked Sendable {
        var failure: Failure?
    }

    struct Sample {
        let scheme: String
        let concurrency: Int
        let wallMs: Double
        let userMs: Double
        let sysMs: Double
        let bytes: Int64
        var runs = 1
        var minMBs = 0.0
        var maxMBs = 0.0
        var mbPerSec: Double { Double(bytes) / 1_048_576.0 / (wallMs / 1000.0) }
        var cores: Double { (userMs + sysMs) / wallMs }
        var mbPerCoreSec: Double { mbPerSec / max(cores, 0.0001) }
    }

    // MARK: - 计时

    static func cpuSnapshot() -> (user: Double, sys: Double, peakRSS: Int) {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func ms(_ t: timeval) -> Double { Double(t.tv_sec) * 1000 + Double(t.tv_usec) / 1000 }
        return (ms(usage.ru_utime), ms(usage.ru_stime), usage.ru_maxrss)
    }

    // MARK: - 单区间读取

    /// 在已认证的阻塞 session 上读完 [offset, offset+length)。
    static func readRangeBlocking(connection: Connection, path: String,
                                  offset: Int64, length: Int64,
                                  chunk: Int, counter: Counter) throws {
        let session = connection.session
        guard let sftp = libssh2_sftp_init(session) else {
            throw Failure(step: "sftp_init", detail: lastSessionError(session))
        }
        defer { libssh2_sftp_shutdown(sftp) }

        let handle = path.withCString { pointer in
            libssh2_sftp_open_ex(sftp, pointer, UInt32(strlen(pointer)),
                                 UInt(LIBSSH2_FXF_READ), 0, LIBSSH2_SFTP_OPENFILE)
        }
        guard let handle else {
            throw Failure(step: "sftp_open", detail: "\(lastSessionError(session)) / sftp=\(libssh2_sftp_last_error(sftp))")
        }
        defer { _ = libssh2_sftp_close_handle(handle) }

        libssh2_sftp_seek64(handle, UInt64(offset))

        let buffer = malloc(chunk)!
        defer { free(buffer) }
        var remaining = length
        while remaining > 0 {
            let n = libssh2_sftp_read(handle, buffer, chunk)
            if n > 0 {
                counter.bytes += Int64(n)
                counter.calls += 1
                counter.maxChunk = max(counter.maxChunk, Int(n))
                remaining -= Int64(n)
                continue
            }
            if n == 0 { break }  // EOF
            throw Failure(step: "sftp_read", detail: "code=\(n) \(lastSessionError(session))")
        }
    }

    /// 非阻塞版本：一次 poll 循环里驱动多个 handle。
    /// 每个 handle 持有自己的区间，返回时全部读完或出错。
    private final class Pending: @unchecked Sendable {
        let sftp: OpaquePointer
        let handle: OpaquePointer
        let offset: Int64
        let length: Int64
        var remaining: Int64
        var received: Int64 = 0
        init(sftp: OpaquePointer, handle: OpaquePointer, offset: Int64, length: Int64) {
            self.sftp = sftp
            self.handle = handle
            self.offset = offset
            self.length = length
            self.remaining = length
        }
    }

    /// 取消标志：主线程置位，poll 循环在边界处自查。
    final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var set = false
        var setAt: Date?

        func request() {
            lock.lock(); defer { lock.unlock() }
            guard !set else { return }
            set = true
            setAt = Date()
        }

        var isSet: Bool {
            lock.lock(); defer { lock.unlock() }
            return set
        }
    }

    struct Cancellation: Error {
        let phase: String
        let bytesSoFar: Int64
        /// 循环真正离开的那一刻。之后还要关 handle / channel，
        /// 那部分同样是阻塞往返，必须和"取消响应"分开计。
        let exitAt: Date
    }

    static func runMultiplexed(connection: Connection, path: String, totalBytes: Int64,
                               channels: Int, handlesPerChannel: Int,
                               chunk: Int, counter: Counter, serial: Bool = false,
                               cancel: CancelFlag? = nil, pollTimeoutMs: Int = 5000,
                               parked: CancelFlag? = nil,
                               abortOnCancel: Bool = false) throws {
        let session = connection.session
        let fanout = channels * handlesPerChannel

        var pendings: [Pending] = []
        var sftps: [OpaquePointer] = []
        for _ in 0..<channels {
            guard let sftp = libssh2_sftp_init(session) else {
                throw Failure(step: "sftp_init", detail: lastSessionError(session))
            }
            sftps.append(sftp)
            for _ in 0..<handlesPerChannel {
                let handle = path.withCString { pointer in
                    libssh2_sftp_open_ex(sftp, pointer, UInt32(strlen(pointer)),
                                         UInt(LIBSSH2_FXF_READ), 0, LIBSSH2_SFTP_OPENFILE)
                }
                guard let handle else {
                    throw Failure(step: "sftp_open", detail: "\(lastSessionError(session))")
                }
                let index = pendings.count
                let length = totalBytes / Int64(fanout)
                let offset = Int64(index) * length
                let trailing = index == fanout - 1 ? totalBytes - length * Int64(fanout) : 0
                libssh2_sftp_seek64(handle, UInt64(offset))
                pendings.append(Pending(sftp: sftp, handle: handle, offset: offset, length: length + trailing))
            }
        }
        defer {
            for pending in pendings { _ = libssh2_sftp_close_handle(pending.handle) }
            for sftp in sftps { libssh2_sftp_shutdown(sftp) }
        }

        libssh2_session_set_blocking(session, 0)
        defer { libssh2_session_set_blocking(session, 1) }

        let buffer = malloc(chunk)!
        defer { free(buffer) }

        var active = pendings.count
        var stalled = 0
        while active > 0 {
            if cancel?.isSet == true {
                libssh2_session_set_blocking(session, 1)
                // abortOnCancel=true：故意不做体面关闭，交给调用方 shutdown + session_free。
                // 这些 handle/sftp 会随 session 一起消失，spike 里允许泄漏。
                if abortOnCancel { pendings.removeAll(); sftps.removeAll() }
                throw Cancellation(phase: "循环顶部", bytesSoFar: counter.bytes, exitAt: Date())
            }
            var progressed = false
            // serial=true 是对照组：同一个 channel 上只允许一个未完成请求，
            // 用来判定 C 的失败究竟来自"多 handle"还是"并发请求"。
            let gate = pendings.firstIndex { $0.remaining > 0 }
            for (index, pending) in pendings.enumerated() where pending.remaining > 0 {
                if serial, index != gate { continue }
                let n = libssh2_sftp_read(pending.handle, buffer, chunk)
                if n == Int(LIBSSH2_ERROR_EAGAIN) { counter.eagain += 1; continue }
                if n < 0 {
                    let others = pendings.enumerated()
                        .map { "#\($0.offset) 已读\($0.element.received) 待读\($0.element.remaining)" }
                        .joined(separator: " | ")
                    throw Failure(step: "sftp_read(非阻塞)",
                                  detail: "第 \(index) 号 handle 上 code=\(n) sftp_status=\(libssh2_sftp_last_error(pending.sftp)) "
                                        + "\(lastSessionError(session))；该 handle 已读 \(pending.received) B，"
                                        + "区间 \(pending.offset)+\(pending.length)。全部 handle 进度：\(others)")
                }
                if n == 0 {
                    pending.remaining = 0
                } else {
                    counter.bytes += Int64(n)
                    counter.calls += 1
                    counter.maxChunk = max(counter.maxChunk, Int(n))
                    pending.received += Int64(n)
                    pending.remaining = max(0, pending.remaining - Int64(n))
                }
                progressed = true
                if pending.remaining == 0 { active -= 1 }
            }
            if progressed { stalled = 0; continue }

            var events: Int16 = 0
            let directions = libssh2_session_block_directions(session)
            if directions & LIBSSH2_SESSION_BLOCK_INBOUND != 0 { events |= Int16(POLLIN) }
            if directions & LIBSSH2_SESSION_BLOCK_OUTBOUND != 0 { events |= Int16(POLLOUT) }
            var descriptor = pollfd(fd: connection.fd, events: events, revents: 0)
            // 进入等待前发信号：取消实验要区分"卡在建阶段"和"卡在 poll 边界"
            counter.polls += 1
            parked?.request()
            let rc = withUnsafeMutablePointer(to: &descriptor) { poll($0, 1, Int32(pollTimeoutMs)) }
            if rc == 0 {
                counter.pollTimeouts += 1
                // 超时是正常事件，也是取消检查点：poll 最多睡 pollTimeoutMs
                if cancel?.isSet == true {
                    libssh2_session_set_blocking(session, 1)
                    if abortOnCancel { pendings.removeAll(); sftps.removeAll() }
                    throw Cancellation(phase: "poll超时", bytesSoFar: counter.bytes, exitAt: Date())
                }
            } else if rc > 0 {
                stalled = 0
            } else {
                stalled += 1
                if stalled > 3 {
                    throw Failure(step: "poll", detail: "无进展，rc=\(rc) errno=\(errno)")
                }
            }
        }
    }

    static func lastSessionError(_ session: OpaquePointer) -> String {
        var message: UnsafeMutablePointer<CChar>?
        libssh2_session_last_error(session, &message, nil, 0)
        return message.map { String(cString: $0) } ?? "<无消息>"
    }

    // MARK: - 三个方案

    static func schemeA(endpoint: SpikeProbe.Endpoint, path: String, totalBytes: Int64,
                        chunk: Int, concurrency: Int) throws -> Sample {
        var built: [Connection] = []
        for _ in 0..<concurrency {
            let (fd, session) = try SpikeProbe.authenticatedSession(endpoint)
            built.append(Connection(fd: fd, session: session))
        }
        let connections = built
        let counters = (0..<concurrency).map { _ in Counter() }
        let length = totalBytes / Int64(concurrency)
        let failures = FailureBox()

        let startCPU = cpuSnapshot()
        let startTime = Date()
        let group = DispatchGroup()
        for index in 0..<concurrency {
            group.enter()
            DispatchQueue(label: "spike.a.\(index)").async {
                defer { group.leave() }
                let offset = Int64(index) * length
                let trailing = index == concurrency - 1 ? totalBytes - length * Int64(concurrency) : 0
                do {
                    try readRangeBlocking(connection: connections[index], path: path,
                                          offset: offset, length: length + trailing,
                                          chunk: chunk, counter: counters[index])
                } catch {
                    failures.failure = error as? Failure
                }
            }
        }
        group.wait()
        let wall = Date().timeIntervalSince(startTime) * 1000
        let endCPU = cpuSnapshot()
        defer { for c in connections { SpikeProbe.shutdown(session: c.session, fd: c.fd) } }
        if let failure = failures.failure { throw failure }
        return sample("A 多Session池", concurrency, wall, startCPU, endCPU, counters)
    }

    static func schemeBOrC(endpoint: SpikeProbe.Endpoint, path: String, totalBytes: Int64,
                           chunk: Int, channels: Int, handlesPerChannel: Int,
                           label: String, serial: Bool = false) throws -> Sample {
        let (fd, session) = try SpikeProbe.authenticatedSession(endpoint)
        let connection = Connection(fd: fd, session: session)
        let counter = Counter()
        let startCPU = cpuSnapshot()
        let startTime = Date()
        do {
            try runMultiplexed(connection: connection, path: path, totalBytes: totalBytes,
                               channels: channels, handlesPerChannel: handlesPerChannel,
                               chunk: chunk, counter: counter, serial: serial)
        } catch {
            SpikeProbe.shutdown(session: session, fd: fd)
            throw error
        }
        let wall = Date().timeIntervalSince(startTime) * 1000
        let endCPU = cpuSnapshot()
        SpikeProbe.shutdown(session: session, fd: fd)
        return sample(label, channels * handlesPerChannel, wall, startCPU, endCPU, [counter])
    }

    static func sample(_ scheme: String, _ concurrency: Int, _ wallMs: Double,
                       _ start: (user: Double, sys: Double, peakRSS: Int),
                       _ end: (user: Double, sys: Double, peakRSS: Int),
                       _ counters: [Counter]) -> Sample {
        Sample(scheme: scheme,
               concurrency: concurrency,
               wallMs: wallMs,
               userMs: end.user - start.user,
               sysMs: end.sys - start.sys,
               bytes: counters.reduce(0) { $0 + $1.bytes })
    }

    static func latencyMain() {
        let endpoint = SpikeProbe.Endpoint.fromEnvironment()
        let env = ProcessInfo.processInfo.environment
        let path = env["SPIKE_FILE"] ?? "/home/tester/spike/big.bin"
        let requests = Int(env["SPIKE_REQUESTS"] ?? "") ?? 8
        let requestSize = Int(env["SPIKE_REQ_SIZE"] ?? "") ?? 1024
        libssh2_init(0)
        print("libssh2 \(SpikeProbe.version()) -> \(endpoint.host):\(endpoint.port)")
        print("请求重叠实验：\(requests) × \(requestSize) B，文件 \(path)")
        do {
            try latencyProbe(endpoint: endpoint, path: path, requests: requests, requestSize: requestSize)
        } catch {
            print("FAIL \(error)")
            exit(1)
        }
    }

    /// 请求重叠实验：吞吐被转发链路封顶时，判断 libssh2 到底能不能
    /// 在多个 channel 上同时压住请求。用小请求把带宽维度摘掉，只剩 RTT。
    static func latencyProbe(endpoint: SpikeProbe.Endpoint, path: String,
                             requests: Int, requestSize: Int) throws {
        func attempt(_ label: String, _ body: () throws -> Void) {
            let start = Date()
            do {
                try body()
            } catch {
                print(String(format: "%-26@ 失败：%@", label as NSString, "\(error)" as NSString))
                return
            }
            let ms = Date().timeIntervalSince(start) * 1000
            print(String(format: "%-26@ %d 个请求 %8.0f ms  %6.2f ms/请求",
                         label as NSString, requests, ms, ms / Double(requests)))
        }

        let total = Int64(requests * requestSize)
        let (fd, session) = try SpikeProbe.authenticatedSession(endpoint)
        let connection = Connection(fd: fd, session: session)
        defer { SpikeProbe.shutdown(session: session, fd: fd) }

        // 参照系：完全阻塞、单 handle、连续 requests 个小请求
        attempt("阻塞串行 1Channel") {
            try readRangeBlocking(connection: connection, path: path, offset: 0,
                                  length: total, chunk: requestSize, counter: Counter())
        }

        // 同一套非阻塞 poll 机器，只变 channel 数：
        // channels=1 与 channels=k 的差值就是"并发请求是否真的重叠"，
        // 且两侧走的是同一份代码，排除了 harness 差异。
        for k in [1, 2, 4, 8] {
            attempt("非阻塞 \(k)Channel") {
                try runMultiplexed(connection: connection, path: path, totalBytes: total,
                                   channels: k, handlesPerChannel: 1,
                                   chunk: requestSize, counter: Counter())
            }
        }

        attempt("非阻塞 1Ch×\(requests)Handle") {
            try runMultiplexed(connection: connection, path: path, totalBytes: total,
                               channels: 1, handlesPerChannel: requests,
                               chunk: requestSize, counter: Counter())
        }

        for k in [2, 4, 8] {
            attempt("多Session \(k)连接") {
                try schemeA(endpoint: endpoint, path: path, totalBytes: total,
                            chunk: requestSize, concurrency: k)
            }
        }
    }

    static func run() {
        let endpoint = SpikeProbe.Endpoint.fromEnvironment()
        let env = ProcessInfo.processInfo.environment
        let path = env["SPIKE_FILE"] ?? "/home/tester/spike/big.bin"
        let chunk = Int(env["SPIKE_CHUNK"] ?? "") ?? 262_144
        let repeats = Int(env["SPIKE_REPEATS"] ?? "") ?? 3
        let levels = (env["SPIKE_LEVELS"] ?? "1,4,8").split(separator: ",").compactMap { Int($0) }

        print("libssh2 \(SpikeProbe.version()) -> \(endpoint.host):\(endpoint.port)")
        print("文件 \(path)  单次请求缓冲 \(chunk) B  并发档位 \(levels)")

        guard let size = remoteSize(endpoint: endpoint, path: path) else {
            print("FAIL 取不到远端文件大小，先确认容器与文件存在")
            exit(1)
        }
        print(String(format: "远端大小 %.1f MB", Double(size) / 1_048_576))

        do {
            // 预热：把服务端页缓存填上，否则第一轮明显偏慢
            let warm = Counter()
            let (fd, session) = try SpikeProbe.authenticatedSession(endpoint)
            try readRangeBlocking(connection: Connection(fd: fd, session: session),
                                  path: path, offset: 0, length: size, chunk: chunk, counter: warm)
            SpikeProbe.shutdown(session: session, fd: fd)
            print(String(format: "预热完成，单请求实际最大返回 %d B（libssh2 内部分包上限）", warm.maxChunk))

            var samples: [Sample] = []
            var errors: [(String, String)] = []

            /// 本地回环的抖动在 ±15% 量级，单次测量分不出方案差异，
            /// 所以每种组合跑 repeats 轮取中位数，并记录最小/最大值。
            func measure(_ label: String, level: Int, _ body: () throws -> Sample) {
                var collected: [Sample] = []
                for _ in 0..<repeats {
                    do {
                        collected.append(try body())
                    } catch {
                        errors.append(("\(label) @\(level)", "\(error)"))
                        print("  \(label) @\(level) 失败：\(error)")
                        return
                    }
                }
                collected.sort { $0.wallMs < $1.wallMs }
                var median = collected[collected.count / 2]
                median.runs = collected.count
                median.minMBs = collected.map(\.mbPerSec).min() ?? 0
                median.maxMBs = collected.map(\.mbPerSec).max() ?? 0
                samples.append(median)
            }

            measure("单Session单Channel（基准）", level: 1) {
                try baseline(endpoint: endpoint, path: path, size: size, chunk: chunk)
            }
            for level in levels where level > 1 {
                measure("A 多Session池", level: level) {
                    try schemeA(endpoint: endpoint, path: path, totalBytes: size,
                                chunk: chunk, concurrency: level)
                }
                measure("B 单Session多Channel", level: level) {
                    try schemeBOrC(endpoint: endpoint, path: path, totalBytes: size,
                                   chunk: chunk, channels: level, handlesPerChannel: 1,
                                   label: "B 单Session多Channel")
                }
                measure("C 单Channel请求流水线", level: level) {
                    try schemeBOrC(endpoint: endpoint, path: path, totalBytes: size,
                                   chunk: chunk, channels: 1, handlesPerChannel: level,
                                   label: "C 单Channel请求流水线")
                }
                // 对照组：同 channel 同数量 handle，但一次只允许一个未完成请求。
                // 若这组能跑通，C 的失败就来自"并发请求"而不是"多 handle"。
                measure("C' 同Channel串行(对照)", level: level) {
                    try schemeBOrC(endpoint: endpoint, path: path, totalBytes: size,
                                   chunk: chunk, channels: 1, handlesPerChannel: level,
                                   label: "C' 同Channel串行(对照)", serial: true)
                }
            }
            report(samples)
            if !errors.isEmpty {
                print("")
                print("未能跑通的组合：")
                for (label, message) in errors { print("  \(label)：\(message)") }
            }
        } catch {
            print("FAIL \(error)")
            exit(1)
        }
    }

    static func baseline(endpoint: SpikeProbe.Endpoint, path: String, size: Int64, chunk: Int) throws -> Sample {
        let (fd, session) = try SpikeProbe.authenticatedSession(endpoint)
        let counter = Counter()
        let startCPU = cpuSnapshot()
        let startTime = Date()
        try readRangeBlocking(connection: Connection(fd: fd, session: session),
                              path: path, offset: 0, length: size, chunk: chunk, counter: counter)
        let wall = Date().timeIntervalSince(startTime) * 1000
        let endCPU = cpuSnapshot()
        SpikeProbe.shutdown(session: session, fd: fd)
        return sample("单Session单Channel（基准）", 1, wall, startCPU, endCPU, [counter])
    }

    static func remoteSize(endpoint: SpikeProbe.Endpoint, path: String) -> Int64? {
        guard let (fd, session) = try? SpikeProbe.authenticatedSession(endpoint) else { return nil }
        defer { SpikeProbe.shutdown(session: session, fd: fd) }
        guard let sftp = libssh2_sftp_init(session) else { return nil }
        defer { libssh2_sftp_shutdown(sftp) }
        var attrs = LIBSSH2_SFTP_ATTRIBUTES()
        let rc = path.withCString { pointer in
            libssh2_sftp_stat_ex(sftp, pointer, UInt32(strlen(pointer)), LIBSSH2_SFTP_STAT, &attrs)
        }
        return rc == 0 ? Int64(attrs.filesize) : nil
    }

    static func report(_ samples: [Sample]) {
        func pad(_ text: String, _ width: Int) -> String {
            text.count >= width ? text + " " : text + String(repeating: " ", count: width - text.count)
        }
        func left(_ text: String) -> String { pad(text, 26) }
        print("")
        print(String(repeating: "-", count: 100))
        print(left("方案") + pad("并发", 6) + pad("轮次", 6) + pad("墙钟ms", 10) + pad("MB/s", 10)
              + pad("波动", 18) + pad("user ms", 10) + pad("sys ms", 10) + pad("占用核数", 10) + "每核MB/s")
        print(String(repeating: "-", count: 118))
        for s in samples {
            print(left(s.scheme)
                  + pad("\(s.concurrency)", 6)
                  + pad("\(s.runs)", 6)
                  + pad(String(format: "%.0f", s.wallMs), 10)
                  + pad(String(format: "%.1f", s.mbPerSec), 10)
                  + pad(String(format: "%.0f–%.0f", s.minMBs, s.maxMBs), 18)
                  + pad(String(format: "%.0f", s.userMs), 10)
                  + pad(String(format: "%.0f", s.sysMs), 10)
                  + pad(String(format: "%.2f", s.cores), 10)
                  + String(format: "%.1f", s.mbPerCoreSec))
        }
        print(String(repeating: "-", count: 118))
    }
}
