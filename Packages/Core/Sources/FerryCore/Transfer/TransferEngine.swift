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

    public init(bytesDone: Int64, totalBytes: Int64?, chunks: Int, isFinal: Bool) {
        self.bytesDone = bytesDone
        self.totalBytes = totalBytes
        self.chunks = chunks
        self.isFinal = isFinal
    }
}

/// 传输执行结果（M3）。
public struct TransferExecutionResult: Sendable, Equatable {
    public let bytesTransferred: Int64
    public let totalBytes: Int64?
    public let confidence: ResumeConfidence
    public let finalSnapshot: ResumeSnapshot?

    public init(bytesTransferred: Int64, totalBytes: Int64?, confidence: ResumeConfidence, finalSnapshot: ResumeSnapshot?) {
        self.bytesTransferred = bytesTransferred
        self.totalBytes = totalBytes
        self.confidence = confidence
        self.finalSnapshot = finalSnapshot
    }
}

/// 传输泵（M1'-6 / M3）。
///
/// 核心纪律：
/// 1. 下载：先写 `<target>.part` 临时文件，完成后原子 replace/rename 到目标路径；
///    暂停保留 `.part`，取消删除 `.part`。
/// 2. 上传：写 `<remote>.part-<uuid>`，校验通过后原子覆盖 rename 到目标；
/// 3. 续传置信度双采样校验（v2.3 §334）：`mtimeIsReliable == false` 时禁用上传续传；
///    下载续传校验远端 size 必须匹配或大于本地已传 offset；
/// 4. 限速接入：泵循环每 chunk 消费 RateLimiter 配额；
/// 5. 取消响应：长循环内部检查 Task.isCancelled 与 CancellationFlag，200ms 内退出。
public enum TransferEngine {
    /// 一个 chunk 的字节数：ADR-0000 I1 与 v2.3 传输层钉的 256 KB。
    public static let defaultChunkBytes = 262_144

    /// 进度节流间隔，落在 ADR-0001 §4.4 要求的 100–200 ms 区间中间。
    public static let defaultProgressInterval: Duration = .milliseconds(150)

    /// 单调时钟（纳秒）。
    public struct Clock: Sendable {
        public let nanoseconds: @Sendable () -> UInt64

        public init(_ nanoseconds: @escaping @Sendable () -> UInt64) {
            self.nanoseconds = nanoseconds
        }

        public static let uptime = Clock { DispatchTime.now().uptimeNanoseconds }
    }

    // MARK: - 下载：远端 → 本地

    /// 下载一个远端文件到本地路径，返回传输执行结果。
    @discardableResult
    public static func download(
        _ remote: RemotePath,
        to local: URL,
        using transfer: any RemoteTransfer,
        chunkBytes: Int = defaultChunkBytes,
        progressInterval: Duration = defaultProgressInterval,
        clock: Clock = .uptime,
        rateLimiter: RateLimiter? = nil,
        usePartFile: Bool = true,
        allowResume: Bool = true,
        initialSnapshot: ResumeSnapshot? = nil,
        onUpdate: @escaping @Sendable (TransferProgress) -> Void = { _ in }
    ) async throws -> TransferExecutionResult {
        let targetPartURL = usePartFile ? partFileURL(for: local) : local
        var startOffset: Int64 = 0
        var resumeConfidence: ResumeConfidence = .high

        // 检查断点续传条件与本地已有 .part 文件
        if usePartFile && allowResume && FileManager.default.fileExists(atPath: targetPartURL.path) {
            let existingSize = (try? FileManager.default.attributesOfItem(atPath: targetPartURL.path)[.size] as? Int64) ?? 0
            if existingSize > 0 {
                startOffset = existingSize
            }
        }

        // 打开远端读句柄
        let reader = try await transfer.openRead(remote, offset: startOffset)
        let totalSize = await reader.totalSize

        // 续传置信度双采样校验（起点采样与复查）
        if startOffset > 0 {
            if let total = totalSize {
                if total < startOffset {
                    // 远端文件比本地已下部分还要小，说明远端已被修改或重置，续传无效，从头下载
                    resumeConfidence = .invalid(reason: "远端文件大小小于本地 .part 偏移")
                    startOffset = 0
                } else if total == startOffset {
                    // 本地已完全下载完毕，直接落定
                    await reader.close()
                    if usePartFile {
                        try replaceOrMove(from: targetPartURL, to: local)
                    }
                    onUpdate(TransferProgress(bytesDone: total, totalBytes: total, chunks: 0, isFinal: true))
                    return TransferExecutionResult(
                        bytesTransferred: 0,
                        totalBytes: total,
                        confidence: .high,
                        finalSnapshot: ResumeSnapshot(size: total, modificationDate: nil, mtimeIsReliable: true)
                    )
                }
            }

            if let initial = initialSnapshot, let total = totalSize {
                if initial.size != total {
                    resumeConfidence = .invalid(reason: "远端文件在断点期间大小发生改变")
                    startOffset = 0
                }
            }
        }

        // 打开本地写入句柄
        let handle: FileHandle
        do {
            handle = try openForWriting(targetPartURL, append: startOffset > 0)
        } catch {
            await reader.close()
            throw error
        }

        let written: Int64
        do {
            written = try await withTaskCancellationHandler(operation: {
                try await pumpDownload(
                    reader: reader,
                    into: handle,
                    startOffset: startOffset,
                    totalSize: totalSize,
                    chunkBytes: chunkBytes,
                    progressInterval: progressInterval,
                    clock: clock,
                    rateLimiter: rateLimiter,
                    onUpdate: onUpdate
                )
            }, onCancel: {
                reader.cancel()
            })
            try handle.close()
            await reader.close()

            // 下载成功收尾：原子替换到最终目标
            if usePartFile {
                try replaceOrMove(from: targetPartURL, to: local)
            }
        } catch is CancellationError {
            try? handle.close()
            await reader.close()
            throw CancellationError()
        } catch {
            try? handle.close()
            await reader.close()
            throw error
        }

        let finalTotal = startOffset + written
        let finalSnapshot = ResumeSnapshot(size: finalTotal, modificationDate: nil, mtimeIsReliable: true)
        return TransferExecutionResult(
            bytesTransferred: written,
            totalBytes: totalSize ?? finalTotal,
            confidence: resumeConfidence,
            finalSnapshot: finalSnapshot
        )
    }

    private static func pumpDownload(
        reader: any RemoteReader,
        into handle: FileHandle,
        startOffset: Int64,
        totalSize: Int64?,
        chunkBytes: Int,
        progressInterval: Duration,
        clock: Clock,
        rateLimiter: RateLimiter?,
        onUpdate: @escaping @Sendable (TransferProgress) -> Void
    ) async throws -> Int64 {
        var reporter = ProgressReporter(totalBytes: totalSize, interval: progressInterval,
                                        clock: clock, onUpdate: onUpdate)
        var written: Int64 = 0
        var chunks = 0

        while true {
            try Task.checkCancellation()

            let data = try await reader.read(maxBytes: chunkBytes)
            if data.isEmpty { break } // EOF

            // 限速器控速
            if let limiter = rateLimiter {
                try await limiter.consume(bytes: data.count)
            }

            try writeLocally(data, to: handle)
            written += Int64(data.count)
            chunks += 1
            reporter.report(bytesDone: startOffset + written, chunks: chunks)
        }
        reporter.finish(bytesDone: startOffset + written, chunks: chunks)
        return written
    }

    // MARK: - 上传：本地 → 远端

    /// 上传一个本地文件到远端路径，返回传输执行结果。
    @discardableResult
    public static func upload(
        from local: URL,
        to remote: RemotePath,
        using transfer: any RemoteTransfer,
        fileSystem: (any RemoteFileSystem)? = nil,
        chunkBytes: Int = defaultChunkBytes,
        progressInterval: Duration = defaultProgressInterval,
        clock: Clock = .uptime,
        rateLimiter: RateLimiter? = nil,
        usePartFile: Bool = false,
        allowResume: Bool = false,
        initialSnapshot: ResumeSnapshot? = nil,
        onUpdate: @escaping @Sendable (TransferProgress) -> Void = { _ in }
    ) async throws -> TransferExecutionResult {
        let source = try openForReading(local)
        let totalBytes: Int64
        do {
            totalBytes = try sizeOfSource(source, at: local)
        } catch {
            try? source.close()
            throw error
        }

        // 续传置信度判断：若 initialSnapshot 存在且 mtime 不可靠，禁用上传续传
        var startOffset: Int64 = 0
        var resumeConfidence: ResumeConfidence = .high
        if allowResume, let initial = initialSnapshot {
            if !initial.mtimeIsReliable {
                resumeConfidence = .low(reason: "远端服务器 mtime 不可靠，已禁用上传续传")
                startOffset = 0
            } else {
                startOffset = initial.size
            }
        }

        // 目标远端路径：若使用临时名且具备 fileSystem 替换能力，则写临时名
        let targetRemote: RemotePath
        let partRemoteSuffix: String?
        if usePartFile && fileSystem != nil {
            let suffix = "part-\(UUID().uuidString.prefix(8))"
            partRemoteSuffix = suffix
            let fileName = remote.lastComponent?.displayString() ?? "file"
            targetRemote = try remote.parent().appending(component: "\(fileName).\(suffix)")
        } else {
            targetRemote = remote
            partRemoteSuffix = nil
        }

        if startOffset > 0 {
            try? source.seek(toOffset: UInt64(startOffset))
        }

        let writer: any RemoteWriter
        do {
            writer = try await transfer.createWrite(targetRemote, offset: startOffset)
        } catch {
            if let fs = fileSystem {
                let parent = targetRemote.parent()
                do {
                    try await ensureRemoteDirectory(parent, fileSystem: fs)
                    writer = try await transfer.createWrite(targetRemote, offset: startOffset)
                } catch {
                    try? source.close()
                    throw error
                }
            } else {
                try? source.close()
                throw error
            }
        }

        let sent: Int64
        do {
            sent = try await withTaskCancellationHandler(operation: {
                try await pumpUpload(
                    writer: writer,
                    from: source,
                    startOffset: startOffset,
                    totalBytes: totalBytes,
                    chunkBytes: chunkBytes,
                    progressInterval: progressInterval,
                    clock: clock,
                    rateLimiter: rateLimiter,
                    onUpdate: onUpdate
                )
            }, onCancel: {
                writer.cancel()
            })
            try source.close()
            try await writer.commit()

            // 若写的是临时文件，校验后原子覆盖 rename 到最终目标路径
            if let _ = partRemoteSuffix, let fs = fileSystem {
                try await fs.rename(targetRemote, to: remote, overwrite: true)
            }
        } catch is CancellationError {
            await writer.abort()
            try? source.close()
            if let _ = partRemoteSuffix, let fs = fileSystem {
                try? await fs.remove(targetRemote, recursive: false)
            }
            throw CancellationError()
        } catch {
            await writer.abort()
            try? source.close()
            if let _ = partRemoteSuffix, let fs = fileSystem {
                try? await fs.remove(targetRemote, recursive: false)
            }
            throw error
        }

        let finalTotal = startOffset + sent
        let finalSnapshot = ResumeSnapshot(size: finalTotal, modificationDate: Date(), mtimeIsReliable: true)
        return TransferExecutionResult(
            bytesTransferred: sent,
            totalBytes: totalBytes,
            confidence: resumeConfidence,
            finalSnapshot: finalSnapshot
        )
    }

    private static func pumpUpload(
        writer: any RemoteWriter,
        from source: FileHandle,
        startOffset: Int64,
        totalBytes: Int64,
        chunkBytes: Int,
        progressInterval: Duration,
        clock: Clock,
        rateLimiter: RateLimiter?,
        onUpdate: @escaping @Sendable (TransferProgress) -> Void
    ) async throws -> Int64 {
        var reporter = ProgressReporter(totalBytes: totalBytes, interval: progressInterval,
                                        clock: clock, onUpdate: onUpdate)
        var sent: Int64 = 0
        var chunks = 0

        while true {
            try Task.checkCancellation()

            let data = try readLocally(source, count: chunkBytes)
            if data.isEmpty { break }

            if let limiter = rateLimiter {
                try await limiter.consume(bytes: data.count)
            }

            let accepted = try await writer.write(data)
            guard accepted == data.count else {
                throw RemoteError.protocolViolation("写入只被确认 \(accepted)/\(data.count) 字节")
            }
            sent += Int64(accepted)
            chunks += 1
            reporter.report(bytesDone: startOffset + sent, chunks: chunks)
        }
        reporter.finish(bytesDone: startOffset + sent, chunks: chunks)
        return sent
    }

    // MARK: - 本地图层

    /// 计算本地目标对应的 .part 临时文件路径。
    ///
    /// APFS/HFS+ 与大多数 POSIX 文件系统的 NAME_MAX 严格等于 255 字节。
    /// 若原始文件名已达 255 字节，直接追加 `.part` 会触发 ENAMETOOLONG 失败，
    /// 因此在文件名超长时必须安全裁剪基础名，确保整个文件名长度不超过 255 字节。
    public static func partFileURL(for target: URL) -> URL {
        let fileName = target.lastPathComponent
        let dir = target.deletingLastPathComponent()
        let partSuffix = ".part"
        if fileName.utf8.count + partSuffix.utf8.count <= 255 {
            return dir.appendingPathComponent("\(fileName)\(partSuffix)")
        } else {
            let maxBaseBytes = 255 - partSuffix.utf8.count
            var truncated = fileName
            while truncated.utf8.count > maxBaseBytes {
                truncated.removeLast()
            }
            return dir.appendingPathComponent("\(truncated)\(partSuffix)")
        }
    }

    public static func replaceOrMove(from: URL, to: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: to.path) {
            _ = try fm.replaceItemAt(to, withItemAt: from)
        } else {
            try fm.moveItem(at: from, to: to)
        }
    }

    private static func openForWriting(_ local: URL, append: Bool = false) throws -> FileHandle {
        do {
            let parentDir = local.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: local.path) {
                if !FileManager.default.createFile(atPath: local.path, contents: nil) {
                    throw posixError()
                }
            }
            let handle = try FileHandle(forWritingTo: local)
            if append {
                try handle.seekToEnd()
            } else {
                try handle.truncate(atOffset: 0)
            }
            return handle
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

    private static func ensureRemoteDirectory(_ path: RemotePath, fileSystem: any RemoteFileSystem) async throws {
        if path.wireBytes == [0x2F] { return }
        if (try? await fileSystem.stat(path)) != nil { return }
        let parent = path.parent()
        if parent != path {
            try await ensureRemoteDirectory(parent, fileSystem: fileSystem)
        }
        try await fileSystem.mkdir(path, permissions: 0o755)
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
    }
}

private extension RemotePath {
    func parent() -> RemotePath {
        if wireBytes == [0x2F] { return self }
        var bytes = wireBytes
        while bytes.count > 1 && bytes.last == 0x2F {
            bytes.removeLast()
        }
        if let lastSlash = bytes.lastIndex(of: 0x2F) {
            if lastSlash == 0 {
                return RemotePath(wireBytes: [0x2F], isAbsolute: true)
            }
            return RemotePath(wireBytes: Array(bytes[..<lastSlash]), isAbsolute: isAbsolute)
        }
        return RemotePath(wireBytes: [0x2F], isAbsolute: true)
    }
}

/// 进度节流。
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
        onUpdate(TransferProgress(bytesDone: bytesDone, totalBytes: totalBytes,
                                  chunks: chunks, isFinal: true))
    }
}
