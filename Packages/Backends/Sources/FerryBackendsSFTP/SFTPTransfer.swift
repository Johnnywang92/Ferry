import CLibssh2
import Darwin
import FerryCore
import Foundation

/// M1'-6：单文件上下传。
///
/// 形状：`SFTPConnection` 开句柄并把指针留在自己那张表里，`SFTPFileReader` /
/// `SFTPFileWriter` 只拿得到一个 id；一次 `read`/`write` 就是一趟 `filesystemCall`，
/// 即"一个 chunk 一个 actor hop"。于是一边传文件一边还能列目录——libssh2 在同一通道上
/// 不许两个请求同时在途（第二个回 `-31`，M0a-02 结论 1），但 chunk 与 chunk 之间是空的，
/// 别的请求正好挤进去（实测见 docs/spike/M1-06 §5）。
///
/// 取消是**句柄级**的标志，检查点与连接级同一处（`SessionLoop` 的循环顶部）。
/// 生效边界却仍然是一整条 session：一旦 `CancellationError` 抛出，闸门按 K1/D4 硬拆并转
/// `.aborted`。理由与实测都在 M1-06 §5：被打断的那个请求在 libssh2 里停在半程状态
/// （`sftp->read_state`/`write_state`），下一发请求上来时它不知道该从哪儿续。
extension SFTPConnection: RemoteTransfer {
    /// 上传新建文件的权限位。本地权限的搬运是 M3 的事（`chmod` 还没接），
    /// 这一轮先固定 `0644`——它是"能不能被自己读回来"的最小正确值，实测五台都收。
    static let uploadPermissions: UInt = UInt(LIBSSH2_SFTP_S_IRUSR | LIBSSH2_SFTP_S_IWUSR
        | LIBSSH2_SFTP_S_IRGRP | LIBSSH2_SFTP_S_IROTH)

    // MARK: - 开句柄

    public func openRead(_ path: RemotePath) async throws -> any RemoteReader {
        try await openRead(path, offset: 0)
    }

    public func openRead(_ path: RemotePath, offset: Int64) async throws -> any RemoteReader {
        guard offset >= 0 else {
            throw RemoteError.protocolViolation("读偏移不能是负数（\(offset)）")
        }
        let opened = try await filesystemCall { channel -> (UInt64, Int64?) in
            let absolute = try self.resolveForTransfer(path, channel: channel)
            let pointer = try self.openFile(absolute, flags: UInt(LIBSSH2_FXF_READ), mode: 0,
                                            operation: .openRead, channel: channel)
            if offset > 0 {
                libssh2_sftp_seek64(pointer, UInt64(offset))
            }
            return (try self.registerFile(pointer, path: absolute, writable: false),
                    try self.fstatSize(pointer, path: absolute, channel: channel))
        }
        return SFTPFileReader(connection: self, fileID: opened.0, totalSize: opened.1)
    }

    /// 开一个写句柄。
    ///
    /// `offset == 0` 带 `FXF_TRUNC`：不截断的话，"新文件比旧的短"会在尾巴上留下上一次的
    /// 内容——那是静默损坏，比覆盖更坏。`offset > 0` 不截断并 `seek64` 过去，
    /// 但**断点续传不在这一轮**（M3/M4），这里只是把契约里那一格填成有意义的行为。
    public func createWrite(_ path: RemotePath, offset: Int64) async throws -> any RemoteWriter {
        guard offset >= 0 else {
            throw RemoteError.protocolViolation("写偏移不能是负数（\(offset)）")
        }
        let id = try await filesystemCall { channel -> UInt64 in
            let absolute = try self.resolveForTransfer(path, channel: channel)
            var flags: UInt = UInt(LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT)
            if offset == 0 { flags |= UInt(LIBSSH2_FXF_TRUNC) }
            let pointer = try self.openFile(absolute, flags: flags,
                                            mode: Int(Self.uploadPermissions),
                                            operation: .createWrite, channel: channel)
            if offset > 0 {
                // 只在刚开完、一发都没发的时候 seek：`libssh2_sftp_seek64` 会把在途包
                // 全部丢掉（sftp.c:2553），中途 seek 等于丢数据。
                libssh2_sftp_seek64(pointer, UInt64(offset))
            }
            return try self.registerFile(pointer, path: absolute, writable: true)
        }
        return SFTPFileWriter(connection: self, fileID: id)
    }

    /// 传输这一族的相对路径与 `~` 也在发出任何字节之前消化掉（与 `list` 同一条纪律）。
    private func resolveForTransfer(_ path: RemotePath, channel: OpaquePointer) throws -> RemotePath {
        let home = try loginDirectory(channel: channel)
        return try PathResolver(homeDirectory: home).lexicalResolve(path, relativeTo: home)
    }

    private func registerFile(_ pointer: OpaquePointer, path: RemotePath, writable: Bool) throws
        -> UInt64
    {
        fileStats.openCalls += 1
        let id = nextFileID
        nextFileID += 1
        openFiles[id] = ManagedFile(pointer: pointer, path: path, writable: writable)
        return id
    }

    /// `SSH_FXP_OPEN` 开一个普通文件。与开目录同一套：失败时指针给 NULL，
    /// 会话码要从 session 取、状态码要从 channel 取，两者必须成对（`ErrorTaxonomy` 规则 2）。
    private func openFile(_ path: RemotePath, flags: UInt, mode: Int, operation: RemoteOperation,
                          channel: OpaquePointer) throws -> OpaquePointer
    {
        guard let session else { throw RemoteError.protocolViolation("session 已经不在了") }
        var terminated = path.wireBytes
        terminated.append(0)
        var loop = newLoop(session)
        nonisolated(unsafe) var opened: OpaquePointer?
        let length = UInt32(path.wireBytes.count)
        let rc = try terminated.withUnsafeBytes { raw -> Int32 in
            let pointer = raw.bindMemory(to: CChar.self).baseAddress!
            return try loop.drive(deadlineMs: operationBudget()) {
                if let handle = libssh2_sftp_open_ex(channel, pointer, length, flags, mode,
                                                     LIBSSH2_SFTP_OPENFILE) {
                    opened = handle
                    return 0
                }
                return Int32(libssh2_session_last_errno(session))
            }
        }
        guard rc == 0, let opened else {
            throw sftpFailure(rc, channel: channel, operation: operation, path: path)
        }
        return opened
    }

    /// 开完句柄再问一次 `fstat` 拿总长。
    ///
    /// 这是**额外一发往返**，不是白送：`libssh2_sftp_open_ex_r` 那个 `attrs` 参数只用于
    /// 拼**发出去**的 OPEN 请求（sftp.c:1162 起），HANDLE 回包里的属性段压根没往回抄。
    /// 所以想知道总长只能 fstat（实测代价与能不能省掉见 M1-06 §3）。
    private func fstatSize(_ pointer: OpaquePointer, path: RemotePath, channel: OpaquePointer) throws
        -> Int64?
    {
        guard let session else { throw RemoteError.protocolViolation("session 已经不在了") }
        fileStats.fstatCalls += 1
        var loop = newLoop(session)
        nonisolated(unsafe) var attrs = LIBSSH2_SFTP_ATTRIBUTES()
        let rc = try loop.drive(deadlineMs: operationBudget()) {
            libssh2_sftp_fstat_ex(pointer, &attrs, 0)
        }
        guard rc == 0 else {
            throw sftpFailure(rc, channel: channel, operation: .openRead, path: path)
        }
        guard UInt(attrs.flags) & SFTPAttributes.attrSize != 0 else { return nil }
        return Int64(truncatingIfNeeded: attrs.filesize)
    }

    // MARK: - chunk 级调用

    /// 读一个 chunk。返回空 `Data` 就是 EOF（`libssh2_sftp_read` 回 0）。
    ///
    /// 一次调用**可以少于** `maxBytes`：libssh2 内部按 `MAX_SFTP_READ_SIZE`（30000 字节）
    /// 分包，手里的包凑不齐时就先给一部分。泵不看"够不够"，只看"是不是 0"。
    func readChunk(_ id: UInt64, handleCancel: CancellationFlag, maxBytes: Int) async throws -> Data {
        let start = uptimeMilliseconds()
        let data = try await filesystemCall { channel -> Data in
            guard let file = self.openFiles[id] else { throw RemoteError.network(.connectionLost) }
            guard let session else { throw RemoteError.protocolViolation("session 已经不在了") }
            fileStats.readChunks += 1
            var loop = newLoop(session, handleCancel: handleCancel)
            // 读进 `Data` 自己的存储，不另开一块缓冲区。`Data(count:)` 给的是已初始化的
            // 全零内存，C 那边写多少算多少——下面把 `count` 收到实际读到的字节数，
            // 调用方拿不到一个没被写过的字节。
            var buffer = Data(count: maxBytes)
            let read = try buffer.withUnsafeMutableBytes { raw -> Int in
                let base = raw.bindMemory(to: CChar.self).baseAddress!
                // `drive` 收的是 Int32（libssh2 的会话码都在这格里），而 `sftp_read`
                // 返回 ssize_t：上界就是 `maxBytes`，下界是错误码，Int32 装得下。
                return Int(try loop.drive(deadlineMs: operationBudget()) {
                    Int32(libssh2_sftp_read(file.pointer, base, maxBytes))
                })
            }
            guard read >= 0 else {
                throw sftpFailure(Int32(read), channel: channel, operation: .read, path: file.path)
            }
            buffer.count = read
            return buffer
        }
        fileStats.transferElapsedMs += uptimeMilliseconds() - start
        return data
    }

    /// 把 `payload` 交给 libssh2，返回**已经被服务器确认**的字节数。
    ///
    /// `payload` 必须是"交出去过但还没被确认的那一段，从头开始"。这不是审美：
    /// `sftp.c:2115–2122` 在每次调用开头会按 `already`（= 已排队未确认的字节数）
    /// 跳过入参缓冲的前面一段。我们手里 `pending.count` 恰好等于那个 `already`，
    /// 所以跳过之后接着排的就是新数据；传错起点等于**凭空删掉一段内容**，
    /// 而服务器只会照单收下，事后什么都看不出来。
    /// 返回值可能小于 `payload.count`（一次只回一个包那 30000 字节），所以调用方
    /// 必须循环到这里给空——`SFTPFileWriter.write` 就是这么做的。
    ///
    /// **回 0 不是失败，是"这轮一个字节都没确认"**：包还没发完就跳出了 ACK 循环
    /// （sftp.c:2203 的 `if(chunk->lefttosend) break` → 2292 的 `return 0`）。
    /// 实测在把 1 MB 交给非阻塞 write 之后，下一发 blocking write 就会回 0 且
    /// `session_last_errno` 为 0（M1-06 §2）。所以这里把 0 交给 `drive` 当停顿重驱：
    /// 等一片 socket 再交同一串字节。判成协议违规会把一次本可完成的上传杀掉。
    func writeChunk(_ id: UInt64, handleCancel: CancellationFlag, payload: Data) async throws -> Int {
        let start = uptimeMilliseconds()
        let credited = try await filesystemCall { channel -> Int in
            guard let file = self.openFiles[id] else { throw RemoteError.network(.connectionLost) }
            guard let session else { throw RemoteError.protocolViolation("session 已经不在了") }
            var loop = newLoop(session, handleCancel: handleCancel)
            fileStats.writeChunks += 1
            let written = try payload.withUnsafeBytes { raw -> Int in
                let base = raw.bindMemory(to: CChar.self).baseAddress!
                // 同 `readChunk`：`sftp_write` 返回 ssize_t，`drive` 收 Int32。
                // 上界是 `payload.count`（一次写不超过一个 chunk），下界是错误码。
                return Int(try loop.drive(deadlineMs: operationBudget(), zeroMeansStall: true) {
                    Int32(libssh2_sftp_write(file.pointer, base, payload.count))
                })
            }
            guard written >= 0 else {
                throw sftpFailure(Int32(written), channel: channel, operation: .write, path: file.path)
            }
            if written > 0 { fileStats.writeCredits += 1 }
            return written
        }
        fileStats.transferElapsedMs += uptimeMilliseconds() - start
        return credited
    }

    /// 让服务器把已收数据落到稳定存储（`fsync@openssh.com` 扩展）。
    ///
    /// 服务器没实现这个扩展**不算失败**：字节早就被 WRITE 的 STATUS 确认过了，这一发
    /// 只是再要它落盘一次。其余成因照原样抛出去。实测五台给什么码见 M1-06 §4。
    func syncFile(_ id: UInt64) async throws {
        try await filesystemCall { channel in
            guard let file = self.openFiles[id] else { return }
            guard let session else { throw RemoteError.protocolViolation("session 已经不在了") }
            var loop = newLoop(session)
            let rc = try loop.drive(deadlineMs: operationBudget()) {
                libssh2_sftp_fsync(file.pointer)
            }
            guard rc != 0 else { return }
            let failure = sftpFailure(rc, channel: channel, operation: .close, path: file.path)
            if case .operationFailed(let detail) = failure,
               case .sftpStatus(.opUnsupported) = detail.kind { return }
            throw failure
        }
    }

    /// 释放句柄。**只在没被取消的时候**发 `SSH_FXP_CLOSE`（D4：取消路径不做体面关闭）。
    /// 一旦连接级或句柄级取消标志已置位，按 ADR-0001 K1/D4 与 M2 开工前定案一律硬拆转 `.aborted`，
    /// 消除取消落在 chunk 之间与 chunk 之内的行为分歧。
    /// 表里的 id 无论如何都摘掉——`hardTeardown()` 之后那些指针已经不是合法内存了。
    func releaseFile(_ id: UInt64, handleCancel: CancellationFlag?) {
        let removed = openFiles.removeValue(forKey: id)
        if cancelFlag.isSet || handleCancel?.isSet == true {
            if state != .aborted && state != .closed {
                hardTeardown()
            }
            return
        }
        guard let file = removed, let session, fd >= 0 else { return }
        var loop = newLoop(session)
        _ = try? loop.drive(deadlineMs: operationBudget()) {
            libssh2_sftp_close_handle(file.pointer)
        }
    }
}

/// 下载句柄。状态只有"这一个 chunk 在读"，全部远端状态都留在连接 actor 上。
actor SFTPFileReader: RemoteReader {
    private let connection: SFTPConnection
    private let fileID: UInt64
    private let handleCancel = CancellationFlag()
    let totalSize: Int64?

    init(connection: SFTPConnection, fileID: UInt64, totalSize: Int64?) {
        self.connection = connection
        self.fileID = fileID
        self.totalSize = totalSize
    }

    func read(maxBytes: Int) async throws -> Data {
        // 0 字节的读法在 libssh2 里没有定义（它会把这当成"来一发空 READ"），
        // 而 `Data(count: 0)` 的 baseAddress 是 nil，指针会带着 0 长度进 C。
        guard maxBytes > 0 else {
            throw RemoteError.protocolViolation("read(maxBytes:) 要正数，给了 \(maxBytes)")
        }
        // 不在此处短路抛 CancellationError：统一进 readChunk -> filesystemCall -> loop.drive，
        // 由 drive 循环顶部检出取消并经 filesystemCall 闸门触发 hardTeardown 转 .aborted。
        return try await connection.readChunk(fileID, handleCancel: handleCancel, maxBytes: maxBytes)
    }

    nonisolated func cancel() { handleCancel.cancel() }

    func close() async {
        await connection.releaseFile(fileID, handleCancel: handleCancel)
    }
}

/// 上传句柄。唯一的状态在这里：`pending`。
actor SFTPFileWriter: RemoteWriter {
    private let connection: SFTPConnection
    private let fileID: UInt64
    private let handleCancel = CancellationFlag()
    /// 已经交给 libssh2、还没被服务器确认的那一段。必须**从头**再交一遍，理由见
    /// `SFTPConnection.writeChunk` 的注释——那是这整个文件里最容易写错的一处。
    private var pending = Data()
    private var finished = false

    init(connection: SFTPConnection, fileID: UInt64) {
        self.connection = connection
        self.fileID = fileID
    }

    @discardableResult
    func write(_ data: Data) async throws -> Int {
        guard !finished else {
            throw RemoteError.protocolViolation("这个写句柄已经收尾了")
        }
        pending.append(data)

        // 一直到 libssh2 把这一段全部确认完才返回。契约要求 `write` 的返回值能当
        // "远端已有多少字节"用，而"已经交给 libssh2 排队"不是已写入——
        // `libssh2_sftp_close_handle` 会把没确认的在途块直接 free 掉（sftp.c:2751）。
        while !pending.isEmpty {
            let outstanding = pending.count
            do {
                let acked = try await connection.writeChunk(fileID, handleCancel: handleCancel,
                                                            payload: pending)
                guard acked > 0 else {
                    // `writeChunk` 已经把"回 0 = 这轮一个字节都没确认"交给 drive 重驱了，
                    // 所以 drive 能带回来的 0 只剩"参数本身是空的"这一种。
                    // 再循环就是死循环，宁可判成协议违规。
                    throw RemoteError.protocolViolation("写入没有任何进展（还欠 \(outstanding) 字节）")
                }
                pending.removeFirst(acked)
            } catch {
                // 失败之后 libssh2 已经把在途块全丢了、远端偏移退回最后一次确认的位置
                // （sftp.c:2249–2262）。留着 `pending` 再交一次，就会把同一段字节当成新数据
                // 写两遍。这一轮的收尾就是放弃这次上传，字节账目由调用方按错误处理。
                pending.removeAll(keepingCapacity: true)
                throw error
            }
        }
        // 进来时 `pending` 是空的（上一轮就是这么收尾的），所以确认完的字节数恰是这一段。
        return data.count
    }

    nonisolated func cancel() { handleCancel.cancel() }

    func commit() async throws {
        guard !finished else {
            throw RemoteError.protocolViolation("这个写句柄已经收尾了")
        }
        finished = true
        try await connection.syncFile(fileID)
        await connection.releaseFile(fileID, handleCancel: handleCancel)
    }

    func abort() async {
        finished = true
        // 远端临时文件的清理（`.part` 那一套）在 M3/M4，这一轮只保证句柄不悬着。
        await connection.releaseFile(fileID, handleCancel: handleCancel)
    }
}
