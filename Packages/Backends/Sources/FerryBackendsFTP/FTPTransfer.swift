import CLibcurl
import FerryCore
import Foundation

/// 线程安全的异步块缓冲区，作为 curl 数据接收与下游 read 之间的通道。
private final class AsyncChunkBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [Data] = []
    private var isFinished = false
    private var waitingContinuation: CheckedContinuation<Data?, Never>?

    func append(_ data: Data) {
        lock.lock()
        if let continuation = waitingContinuation {
            waitingContinuation = nil
            lock.unlock()
            continuation.resume(returning: data)
        } else {
            chunks.append(data)
            lock.unlock()
        }
    }

    func finish() {
        lock.lock()
        isFinished = true
        if let continuation = waitingContinuation {
            waitingContinuation = nil
            lock.unlock()
            continuation.resume(returning: nil)
        } else {
            lock.unlock()
        }
    }

    func nextChunk() async -> Data? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if !chunks.isEmpty {
                let item = chunks.removeFirst()
                lock.unlock()
                continuation.resume(returning: item)
            } else if isFinished {
                lock.unlock()
                continuation.resume(returning: nil)
            } else {
                waitingContinuation = continuation
                lock.unlock()
            }
        }
    }
}

/// FTP 只读句柄（v2.3 §150, §315）。
///
/// 使用 libcurl 的 CURLOPT_RESUME_FROM_LARGE 支持断点读取，
/// 通过后台 Task 与 AsyncChunkBuffer 提供非阻塞 chunk 读取。
public actor FTPFileReader: RemoteReader {
    public nonisolated let totalSize: Int64?
    private let cancellationFlag = CancellationFlag()
    private var isClosed = false
    private var buffer = Data()
    private var downloadTask: Task<Void, Error>?
    private let chunkBuffer = AsyncChunkBuffer()

    public init(
        url: String,
        userpwd: String?,
        offset: Int64,
        totalSize: Int64?,
        timeoutSeconds: Int = 30
    ) {
        self.totalSize = totalSize

        let flag = self.cancellationFlag
        let streamBox = self.chunkBuffer

        // 启动后台下载泵
        self.downloadTask = Task.detached {
            guard let curl = ferry_curl_easy_init() else {
                streamBox.finish()
                return
            }
            defer { ferry_curl_easy_cleanup(curl) }

            ferry_curl_set_url(curl, url)
            if let userpwd {
                ferry_curl_set_userpwd(curl, userpwd)
            }
            ferry_curl_set_timeout(curl, Int(timeoutSeconds))
            ferry_curl_set_connect_timeout(curl, 10)
            if offset > 0 {
                ferry_curl_set_resume_from(curl, curl_off_t(offset))
            }

            final class Context: @unchecked Sendable {
                let box: AsyncChunkBuffer
                let flag: CancellationFlag
                init(box: AsyncChunkBuffer, flag: CancellationFlag) {
                    self.box = box
                    self.flag = flag
                }
            }
            let ctx = Context(box: streamBox, flag: flag)
            let unmanaged = Unmanaged.passRetained(ctx)

            ferry_curl_set_write_callback(curl, { ptr, size, nmemb, userdata in
                guard let ptr, let userdata else { return 0 }
                let totalBytes = size * nmemb
                let ctx = Unmanaged<Context>.fromOpaque(userdata).takeUnretainedValue()
                if ctx.flag.isSet {
                    return 0 // 中断传输
                }
                let data = Data(bytes: ptr, count: totalBytes)
                ctx.box.append(data)
                return totalBytes
            }, unmanaged.toOpaque())

            ferry_curl_set_xferinfo_callback(curl, { userdata, _, _, _, _ in
                guard let userdata else { return 0 }
                let ctx = Unmanaged<Context>.fromOpaque(userdata).takeUnretainedValue()
                return ctx.flag.isSet ? 1 : 0
            }, unmanaged.toOpaque())

            _ = ferry_curl_easy_perform(curl)
            unmanaged.release()
            streamBox.finish()
        }
    }

    public func read(maxBytes: Int) async throws -> Data {
        guard !isClosed else { throw CancellationError() }
        if cancellationFlag.isSet { throw CancellationError() }

        while buffer.count < maxBytes {
            guard let nextChunk = await chunkBuffer.nextChunk() else {
                break
            }
            buffer.append(nextChunk)
        }

        if buffer.isEmpty {
            return Data()
        }

        let count = min(buffer.count, maxBytes)
        let slice = buffer.prefix(count)
        buffer.removeFirst(count)
        return Data(slice)
    }

    public nonisolated func cancel() {
        cancellationFlag.cancel()
    }

    public func close() async {
        isClosed = true
        cancel()
        chunkBuffer.finish()
        downloadTask?.cancel()
        downloadTask = nil
        buffer.removeAll()
    }
}

/// FTP 写句柄（v2.3 §150, §315）。
///
/// 使用 libcurl 的 CURLOPT_UPLOAD 与 CURLOPT_FTPAPPEND 支持写入与续传。
public actor FTPFileWriter: RemoteWriter {
    private let cancellationFlag = CancellationFlag()
    private var isAborted = false
    private let url: String
    private let userpwd: String?
    private let offset: Int64
    private var accumulatedData = Data()

    public init(
        url: String,
        userpwd: String?,
        offset: Int64
    ) {
        self.url = url
        self.userpwd = userpwd
        self.offset = offset
    }

    @discardableResult
    public func write(_ data: Data) async throws -> Int {
        guard !isAborted else { throw CancellationError() }
        if cancellationFlag.isSet { throw CancellationError() }

        accumulatedData.append(data)
        return data.count
    }

    public nonisolated func cancel() {
        cancellationFlag.cancel()
    }

    public func commit() async throws {
        guard !isAborted else { throw CancellationError() }
        if cancellationFlag.isSet { throw CancellationError() }

        // 执行最终落盘上传
        guard let curl = ferry_curl_easy_init() else {
            throw RemoteError.operationFailed(OperationFailure(kind: .sessionCode(-1), operation: .write, path: nil, rc: -1))
        }
        defer { ferry_curl_easy_cleanup(curl) }

        ferry_curl_set_url(curl, url)
        if let userpwd {
            ferry_curl_set_userpwd(curl, userpwd)
        }
        ferry_curl_set_upload(curl, 1)
        if offset > 0 {
            ferry_curl_set_append(curl, 1)
        }

        final class UploadContext: @unchecked Sendable {
            var data: Data
            var readOffset: Int = 0
            let flag: CancellationFlag
            init(data: Data, flag: CancellationFlag) {
                self.data = data
                self.flag = flag
            }
        }

        let ctx = UploadContext(data: accumulatedData, flag: cancellationFlag)
        let unmanaged = Unmanaged.passRetained(ctx)

        ferry_curl_set_infilesize(curl, curl_off_t(accumulatedData.count))
        ferry_curl_set_read_callback(curl, { ptr, size, nmemb, userdata in
            guard let ptr, let userdata else { return 0 }
            let maxCanRead = size * nmemb
            let ctx = Unmanaged<UploadContext>.fromOpaque(userdata).takeUnretainedValue()
            if ctx.flag.isSet {
                return 0
            }
            let remaining = ctx.data.count - ctx.readOffset
            if remaining <= 0 { return 0 }
            let toCopy = min(maxCanRead, remaining)
            ctx.data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                memcpy(ptr, base.advanced(by: ctx.readOffset), toCopy)
            }
            ctx.readOffset += toCopy
            return toCopy
        }, unmanaged.toOpaque())

        let rc = ferry_curl_easy_perform(curl)
        unmanaged.release()
        accumulatedData.removeAll()

        if cancellationFlag.isSet {
            throw CancellationError()
        }
        if rc != CURLE_OK {
            throw RemoteError.operationFailed(OperationFailure(kind: .ftpReply(Int32(rc.rawValue)), operation: .write, path: nil, rc: Int32(rc.rawValue)))
        }
    }

    public func abort() async {
        isAborted = true
        cancel()
        accumulatedData.removeAll()
    }
}
