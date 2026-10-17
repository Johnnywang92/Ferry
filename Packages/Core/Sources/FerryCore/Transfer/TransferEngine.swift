import Foundation

/// 一次传输的进度快照。
///
/// 只有绝对值，没有百分比：`totalBytes` 可以是 nil（后端拿不到总长时不许瞎猜一个分母），
/// 百分比留给上层聚合。这一层只负责把字节数如实、按节流报出去。
public struct TransferProgress: Sendable, Hashable {
    public let bytesDone: Int64
    public let totalBytes: Int64?
    /// 已经泵过几个 chunk。不足一个 chunk 的小文件也要有至少两次汇报（开始与收尾），
    /// 所以这个数不能当"跑了几轮"的唯一依据。
    public let chunks: Int
    /// 收尾那一次：EOF 或写完必发，不看节流间隔。UI 靠它把进度条落定。
    public let isFinal: Bool
}

/// 单文件上下传的泵（M1'-6）。
///
/// 这一层刻意不知道"临时文件""断点续传""冲突策略"这三件事——它们分属 M3/M3/M4
/// （v2.3 的分层），本轮的出口标准只有"单文件上下传可用"。这里要成立的是四件小事：
/// chunk 大小、进度节流、取消怎么落到句柄、错误怎么分出去。
///
/// 本地磁盘走同步 `FileHandle`，一次一 chunk。调用方不要在 main actor 上跑它：
/// 每 chunk 的读写阻塞时间是真实的（本机实测见 docs/spike/M1-06 §3）。
public enum TransferEngine {
    /// 一个 chunk 的字节数：ADR-0000 I1 与 v2.3 传输层钉的那个 256 KB。
    ///
    /// 上下传共用这一个数。libssh2 会把它再拆成 `MAX_SFTP_READ_SIZE`/
    /// `MAX_SFTP_OUTGOING_SIZE`（各 30000 字节，`sftp.h:47,52`）那么多个包，
    /// 所以 chunk 越大、在途包越多、往返摊得越薄；代价是内存占用与取消粒度。
    public static let defaultChunkBytes = 262_144

    /// 进度节流间隔，落在 ADR-0001 §4.4 要求的 100–200 ms 区间中间。
    public static let defaultProgressInterval: Duration = .milliseconds(150)

    /// 单调时钟（纳秒）。做成参数是为了让"节流生效"这条断言能在不睡真时间的单测里跑。
    public struct Clock: Sendable {
        public let nanoseconds: @Sendable () -> UInt64

        public init(_ nanoseconds: @escaping @Sendable () -> UInt64) {
            self.nanoseconds = nanoseconds
        }

        public static let uptime = Clock { DispatchTime.now().uptimeNanoseconds }
    }

    // MARK: - 下载：远端 → 本地

    /// 下载一个远端文件到本地路径，返回落盘的字节数。
    ///
    /// 抛出的错误分三类且**不合并**：`RemoteError`（远端或协议）、`.localIO`（本地盘）、
    /// `CancellationError`（被取消）。同步引擎对这三类的处置完全不同——重试、提示用户、
    /// 还是直接放弃——在这里合成一个错误就把这个区分丢掉了。
    @discardableResult
    public static func download(_ remote: RemotePath,
                                to local: URL,
                                using transfer: any RemoteTransfer,
                                chunkBytes: Int = defaultChunkBytes,
                                progressInterval: Duration = defaultProgressInterval,
                                clock: Clock = .uptime,
                                onUpdate: @escaping @Sendable (TransferProgress) -> Void = { _ in }
    ) async throws -> Int64 {
        let reader = try await transfer.openRead(remote)
        let totalSize = await reader.totalSize
        // 本地文件先建成 0 字节再开工：目录不可写、盘满这些应当在发出第一个 chunk
        // 之前失败，而不是传到一半留下半份文件。
        let handle: FileHandle
        do {
            handle = try openForWriting(local)
        } catch {
            // 本地开不出来也必须摘远端句柄：否则每撞一次"目录不可写"就漏一个
            // 服务器侧 READ 句柄（它要挂到连接关闭才回收）。
            await reader.close()
            throw error
        }

        let written: Int64
        do {
            written = try await withTaskCancellationHandler(operation: {
                try await pumpDownload(reader: reader, into: handle, totalSize: totalSize,
                                       chunkBytes: chunkBytes, progressInterval: progressInterval,
                                       clock: clock, onUpdate: onUpdate)
            }, onCancel: {
                // 只置标志就返回：真正退出由句柄内部的 poll 循环在下一个切片边界观察到（K1）。
                reader.cancel()
            })
            try handle.close()
            // EOF 之后必须关远端句柄：不关的话服务器侧那个 READ 句柄会一直挂到连接
            // 关闭，下载 N 个文件就漏 N 个（上传路径有 commit/abort 收尾，下载不能没有）。
            await reader.close()
        } catch {
            // 取消路径上 `close()` 只是本地 fclose，与协议无关，照样把文件描述符还掉。
            try? handle.close()
            // 失败路径也要摘句柄：`releaseFile` 内部会跳过取消时的 CLOSE（D4），
            // 只是把连接表里的 id 拿掉——`hardTeardown` 之后那些指针已不是合法内存。
            await reader.close()
            throw error
        }
        return written
    }

    private static func pumpDownload(reader: any RemoteReader,
                                     into handle: FileHandle,
                                     totalSize: Int64?,
                                     chunkBytes: Int,
                                     progressInterval: Duration,
                                     clock: Clock,
                                     onUpdate: @escaping @Sendable (TransferProgress) -> Void) async throws
        -> Int64
    {
        var reporter = ProgressReporter(totalBytes: totalSize, interval: progressInterval,
                                        clock: clock, onUpdate: onUpdate)
        var written: Int64 = 0
        var chunks = 0

        while true {
            let data = try await reader.read(maxBytes: chunkBytes)
            if data.isEmpty { break }                       // EOF
            try writeLocally(data, to: handle)
            written += Int64(data.count)
            chunks += 1
            reporter.report(bytesDone: written, chunks: chunks)
        }
        reporter.finish(bytesDone: written, chunks: chunks)
        return written
    }

    // MARK: - 上传：本地 → 远端

    /// 上传一个本地文件到远端路径，返回远端确认写入的字节数。
    ///
    /// 目标已存在时**整体覆盖**：`createWrite(offset: 0)` 带截断。不截断会在
    /// "新文件比旧的短"时留下上一次的尾巴——那是静默损坏，比覆盖更坏。
    /// 冲突询问与 `.part` 临时文件是 M3/M4 的事，但这个默认行为要先记进基线
    /// （docs/spike/M1-06 §6），否则 UI 一上线就会静默删数据。
    @discardableResult
    public static func upload(from local: URL,
                              to remote: RemotePath,
                              using transfer: any RemoteTransfer,
                              chunkBytes: Int = defaultChunkBytes,
                              progressInterval: Duration = defaultProgressInterval,
                              clock: Clock = .uptime,
                              onUpdate: @escaping @Sendable (TransferProgress) -> Void = { _ in }
    ) async throws -> Int64 {
        let source = try openForReading(local)
        let writer: any RemoteWriter
        do {
            writer = try await transfer.createWrite(remote, offset: 0)
        } catch {
            // 远端开不出来也必须还本地描述符：与 download 侧 `openForWriting` 失败
            // 要关 reader 是同一条纪律（上传先开本地、下载先开远端，各自兜住对面）。
            try? source.close()
            throw error
        }
        let totalBytes = try sizeOfSource(source, at: local)

        let sent: Int64
        do {
            sent = try await withTaskCancellationHandler(operation: {
                try await pumpUpload(writer: writer, from: source, totalBytes: totalBytes,
                                     chunkBytes: chunkBytes, progressInterval: progressInterval,
                                     clock: clock, onUpdate: onUpdate)
            }, onCancel: {
                writer.cancel()
            })
            try source.close()
        } catch {
            // 远端句柄的回滚交给 writer 自己：它知道该不该发 CLOSE（取消路径不许体面关闭，D4）。
            await writer.abort()
            try? source.close()
            throw error
        }
        return sent
    }

    private static func pumpUpload(writer: any RemoteWriter,
                                   from source: FileHandle,
                                   totalBytes: Int64,
                                   chunkBytes: Int,
                                   progressInterval: Duration,
                                   clock: Clock,
                                   onUpdate: @escaping @Sendable (TransferProgress) -> Void) async throws
        -> Int64
    {
        var reporter = ProgressReporter(totalBytes: totalBytes, interval: progressInterval,
                                        clock: clock, onUpdate: onUpdate)
        var sent: Int64 = 0
        var chunks = 0

        while true {
            let data = try readLocally(source, count: chunkBytes)
            if data.isEmpty { break }
            let accepted = try await writer.write(data)
            // 含糊不得：`write` 说收了 N 字节却只回更少，差额就是永久丢掉的一段数据，
            // 而且下一次 `write` 会从错的位置续上去。
            guard accepted == data.count else {
                throw RemoteError.protocolViolation(
                    "写入只被确认 \(accepted)/\(data.count) 字节")
            }
            sent += Int64(accepted)
            chunks += 1
            reporter.report(bytesDone: sent, chunks: chunks)
        }
        try await writer.commit()
        reporter.finish(bytesDone: sent, chunks: chunks)
        return sent
    }

    // MARK: - 本地图层

    /// 本地读写失败的分界：能分出"盘满"就分出 `diskFull`，其余按方向给
    /// `writeFailed`/`readFailed`。不许把本地故障报成网络错误——那会让同步引擎去重试
    /// 一个重试一万次也不会成功的操作（`RemoteError.isRetryable` 只认 `.network`）。
    private static func openForWriting(_ local: URL) throws -> FileHandle {
        do {
            if !FileManager.default.createFile(atPath: local.path, contents: nil) {
                throw posixError()
            }
            return try FileHandle(forWritingTo: local)
        } catch let error as RemoteError {
            throw error
        } catch {
            throw RemoteError.localIO(localKind(error, fallback: .writeFailed))
        }
    }

    private static func openForReading(_ local: URL) throws -> FileHandle {
        do {
            return try FileHandle(forReadingFrom: local)
        } catch {
            throw RemoteError.localIO(localKind(error, fallback: .readFailed))
        }
    }

    private static func sizeOfSource(_ handle: FileHandle, at local: URL) throws -> Int64 {
        do {
            let size = try handle.seekToEnd()
            try handle.seek(toOffset: 0)
            return Int64(size)
        } catch {
            throw RemoteError.localIO(localKind(error, fallback: .readFailed))
        }
    }

    private static func readLocally(_ handle: FileHandle, count: Int) throws -> Data {
        do {
            guard let data = try handle.read(upToCount: count) else {
                return Data()
            }
            return data
        } catch {
            throw RemoteError.localIO(.readFailed)
        }
    }

    private static func writeLocally(_ data: Data, to handle: FileHandle) throws {
        do {
            try handle.write(contentsOf: data)
        } catch {
            throw RemoteError.localIO(localKind(error, fallback: .writeFailed))
        }
    }

    private static func localKind(_ error: Error, fallback: LocalIOKind) -> LocalIOKind {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOSPC) { return .diskFull }
        return fallback
    }

    /// `createFile` 失败时不给 error，只能自己造一个 POSIX 码进去。
    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
    }
}

/// 进度节流：两次汇报之间至少隔 `interval`，收尾那一次必发。
///
/// 不做这层的话，256 KB chunk 在本机是每几毫秒一跳，UI 会被淹掉（ADR-0001 §4.4）。
/// 被压掉的那几次不用补报：每个进度带的都是**累计**字节数，最新那一个自然包含前面的。
/// 起点取"现在减去间隔"，所以第一个 chunk 就能报出去——用户看到的不是"开始不动"，
/// 而是"开始了"。
struct ProgressReporter {
    private let totalBytes: Int64?
    private let intervalNanoseconds: UInt64
    private let clock: TransferEngine.Clock
    private let onUpdate: @Sendable (TransferProgress) -> Void
    private var lastNanoseconds: UInt64

    init(totalBytes: Int64?, interval: Duration, clock: TransferEngine.Clock,
         onUpdate: @escaping @Sendable (TransferProgress) -> Void) {
        let components = interval.components
        self.totalBytes = totalBytes
        self.intervalNanoseconds = UInt64(components.seconds) * 1_000_000_000
            + UInt64(components.attoseconds / 1_000_000_000)
        self.clock = clock
        self.onUpdate = onUpdate
        self.lastNanoseconds = clock.nanoseconds() - intervalNanoseconds
    }

    mutating func report(bytesDone: Int64, chunks: Int) {
        let now = clock.nanoseconds()
        guard now &- lastNanoseconds >= intervalNanoseconds else { return }
        lastNanoseconds = now
        onUpdate(TransferProgress(bytesDone: bytesDone, totalBytes: totalBytes,
                                  chunks: chunks, isFinal: false))
    }

    mutating func finish(bytesDone: Int64, chunks: Int) {
        // 收尾不看间隔：最后那 100–200 ms 的进度要是也被压掉，UI 会永远停在"差一点"上。
        onUpdate(TransferProgress(bytesDone: bytesDone, totalBytes: totalBytes,
                                  chunks: chunks, isFinal: true))
    }
}
