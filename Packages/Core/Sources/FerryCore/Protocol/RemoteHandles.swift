import Foundation

/// 句柄必须是引用语义，杜绝"后台正在读、外部并发 cancel"触发 Swift 独占访问违规。
///
/// 关于缓冲复用（ADR-0000 I1）：`UnsafeMutableRawBufferPointer` 非 Sendable，
/// 在 Swift 6 严格并发下不能作为参数传入 actor 隔离的 `async` 方法。
/// 因此本协议返回 `Data`，每 chunk 接受一次 256KB 拷贝；
/// 零拷贝复用是 M3 用 Instruments 测量后才决定是否引入的优化，不是出口标准。
public protocol RemoteReader: Actor {
    var totalSize: Int64? { get }

    /// 读取下一段；返回空 `Data` 表示 EOF。
    func read(maxBytes: Int) async throws -> Data

    /// 只置原子取消标志，由底层 poll 循环观察并抛出 `CancellationError`。
    nonisolated func cancel()

    func close() async
}

public protocol RemoteWriter: Actor {
    /// 返回实际写入字节数，供断点续传精确校验。
    @discardableResult
    func write(_ data: Data) async throws -> Int

    func commit() async throws
    /// 释放远端句柄并清理远端临时文件。
    func abort() async
}
