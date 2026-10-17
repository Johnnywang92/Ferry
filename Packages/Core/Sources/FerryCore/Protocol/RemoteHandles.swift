import Foundation

/// 上下传需要的最小契约：只有开句柄这两件事，别的都没有。
///
/// 单独立一个协议而不是让 M1'-6 直接宣布 `SFTPConnection` 符合 `RemoteFileSystem`：
/// 后者的 mkdir/remove/rename/symlink/chmod/statvfs 还没实现，现在就声称符合等于
/// 交出一个处处抛"未实现"的壳（M1'-2 定 `RemoteConnection` 时同一条理由）。
/// `RemoteFileSystem` 继承本协议，所以等那些操作补齐、上层改用 `RemoteFileSystem` 时
/// 传输层一行都不用动。
public protocol RemoteTransfer: Sendable {
    /// 打开一个只读句柄。路径不存在应当抛 `.notFound`，不是返回 nil——
    /// 同步引擎靠这个区分"远端已删"与"网络故障"。
    func openRead(_ path: RemotePath) async throws -> any RemoteReader

    /// 打开一个写句柄。
    ///
    /// `offset == 0` 意味着"从零重写"，实现必须**截断**已有内容：不截断的话
    /// "新文件比旧的短"会在尾巴上留下上一次的字节，那是静默损坏，比覆盖更坏。
    /// `offset > 0` 从给定偏移续写，不截断。
    func createWrite(_ path: RemotePath, offset: Int64) async throws -> any RemoteWriter
}

/// 句柄必须是引用语义，杜绝"后台正在读、外部并发 cancel"触发 Swift 独占访问违规。
///
/// 关于缓冲复用（ADR-0000 I1）：`UnsafeMutableRawBufferPointer` 非 Sendable，
/// 在 Swift 6 严格并发下不能作为参数传入 actor 隔离的 `async` 方法。
/// 因此本协议返回 `Data`，每 chunk 接受一次 256KB 拷贝；
/// 零拷贝复用是 M3 用 Instruments 测量后才决定是否引入的优化，不是出口标准。
public protocol RemoteReader: Actor {
    /// 文件的总字节数，取不到就是 nil（进度只能显示绝对值，不许瞎猜分母）。
    var totalSize: Int64? { get }

    /// 读取下一段；返回空 `Data` 表示 EOF。
    func read(maxBytes: Int) async throws -> Data

    /// 只置原子标志，由底层 poll 循环观察并抛出 `CancellationError`。
    ///
    /// 生效边界是一条 session 而不是这一个句柄：一次取消之后这条连接判为 `aborted`，
    /// 因为被打断的那个请求在 libssh2 里停在半程状态（`sftp->read_state`），
    /// 换下一个请求上去它不知道要从哪儿续（M1-06 §5 实测）。
    nonisolated func cancel()

    func close() async
}

public protocol RemoteWriter: Actor {
    /// 返回实际写入字节数，供断点续传精确校验。
    ///
    /// 实现必须等这一段被服务器 ACK 之后才返回，否则"返回的字节数"意味着
    /// "已经交给 libssh2 排队"——而 `libssh2_sftp_close_handle` 会把没 ACK 的在途块
    /// 直接丢弃（M1-06 §4）。差一个字节都会让续传从错的位置开始写。
    @discardableResult
    func write(_ data: Data) async throws -> Int

    /// 只置原子标志，由底层 poll 循环观察并抛出 `CancellationError`（与 `RemoteReader` 同理）。
    ///
    /// M0a-2 定这份契约时漏了这一条：上传的 chunk 循环与下载用的是同一台 poll 机器，
    /// 取消就得能用同一个办法掐断。缺它只能等这一 chunk 自己超时（15 s）。
    nonisolated func cancel()

    /// 收尾：把在途数据确认干净（必要时 `fsync`）并释放远端句柄。抛错就是失败。
    func commit() async throws
    /// 释放远端句柄并清理远端临时文件。
    func abort() async
}
