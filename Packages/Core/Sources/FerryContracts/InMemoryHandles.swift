import Foundation
import FerryCore

/// `InMemoryFileSystem.openRead` 的返回值。
///
/// 它刻意**不**做零拷贝也不做缓冲：契约测试要验的是"后端交出来的字节对不对、
/// 边界怎么切、EOF 怎么表示"，这些与性能无关。真要压传输性能得走 M1'-6 的
/// `TransferSpike`（16 MB × 三个 chunk 档），不是这一层。
public actor InMemoryReader: RemoteReader {
    private let contents: Data
    private let reportedSize: Int64?
    private var cursor = 0
    private var closed = false
    private var cancelled = false

    public init(contents: Data, reportedSize: Int64?) {
        self.contents = contents
        self.reportedSize = reportedSize
    }

    /// 契约要能造出"取不到大小"的那一格（FTP 的部分 LIST 不给准头），
    /// 所以这里不是简单地把 `contents.count` 塞进去。
    public nonisolated var totalSize: Int64? { reportedSize }

    public nonisolated func cancel() {
        // actor 隔离挡住了同步置位。取消"落点决定命运"那一层是 M1'-6 的传输层问题
        //（docs/spike/M1-06 §5 的 settle 扫描），fake 只保证标志最终被观察到。
        Task { await self.markCancelled() }
    }

    public func markCancelled() { cancelled = true }

    public func read(maxBytes: Int) async throws -> Data {
        if cancelled { throw CancellationError() }
        guard !closed else { throw RemoteError.operationFailed(OperationFailure(
            kind: .undetermined, operation: .read, path: nil, rc: -1)) }
        // EOF 是空 Data，不是 nil 也不是抛错：TransferEngine 靠它结束循环。
        guard maxBytes > 0, cursor < contents.count else { return Data() }
        let upper = min(cursor + maxBytes, contents.count)
        defer { cursor = upper }
        return Data(contents[cursor..<upper])
    }

    public func close() async { closed = true }
}

/// `InMemoryFileSystem.createWrite` 的返回值。
///
/// `commit` 才落盘是刻意的：契约里有一格专门验"没 commit 的写不该出现在 `stat` 里"，
/// 这条对应 `RemoteWriter.abort` 的存在理由——半途失败留下的文件如果已经可见，
/// 同步引擎会把它当成成品。
public actor InMemoryWriter: RemoteWriter {
    private let fs: InMemoryFileSystem
    private let path: RemotePath
    private var buffer: Data
    private var cancelled = false
    private var settled = false

    /// `initial` 是开句柄那一刻按 offset 算出来的起点（续传保留前缀，覆盖则为空）。
    /// 它**不在**开句柄时就落到树上：`commit` 才写，半途 `abort` 的写不该被看见。
    public init(fs: InMemoryFileSystem, path: RemotePath, initial: Data) {
        self.fs = fs
        self.path = path
        self.buffer = initial
    }

    public nonisolated func cancel() {
        Task { await self.markCancelled() }
    }

    public func markCancelled() { cancelled = true }

    @discardableResult
    public func write(_ data: Data) async throws -> Int {
        if cancelled { throw CancellationError() }
        guard !settled else { throw RemoteError.operationFailed(OperationFailure(
            kind: .undetermined, operation: .write, path: path, rc: -1)) }
        buffer.append(data)
        // 契约要求返回**服务器已确认**的字节数（累计值），不是"这一段交出去了"。
        // 断点续传按这个数算下一段的偏移，返回段长会让偏移一次次错位。
        return buffer.count
    }

    public func commit() async throws {
        if cancelled { throw CancellationError() }
        await fs.storeWrite(path: path, contents: buffer)
        settled = true
    }

    public func abort() async {
        settled = true
        buffer.removeAll()
    }
}