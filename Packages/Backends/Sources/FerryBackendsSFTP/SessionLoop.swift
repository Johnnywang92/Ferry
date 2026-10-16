import CLibssh2
import Darwin
import FerryCore
import Foundation

/// 单调毫秒。用 `uptimeNanoseconds` 而不是墙钟：握手的预算不该被改系统时间影响。
func uptimeMilliseconds() -> Int64 { Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000) }

func milliseconds(of duration: Duration) -> Int64 {
    let components = duration.components
    return components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000
}

/// 一台机器自己的计数，用来证明取消延迟受切片约束、也用来出诊断报告。
///
/// 做成引用类型是有意的：握手的每一段（TCP connect、kex、disconnect）都写同一只盒子，
/// 于是抛错退出时计数已经在 actor 状态里，不会像"局部 struct 再拷回来"那样
/// 在最需要数据的那条路径（被取消、超时）上恰好丢掉。它只在 actor 隔离内流动，
/// 对外一律通过 `SFTPConnection.Measure` 拷成值。
final class LoopStats {
    var eagain = 0
    var polls = 0
    var pollTimeouts = 0
}

/// ADR-0001 D3 定下来的那台机器：调用返回 EAGAIN → 问 libssh2 要等读还是等写
/// → 对 socket `poll` 一个 50 ms 切片 → 重试。
///
/// 取消标志在**两处**检查：循环顶部（新到的取消最快生效）和 `poll` 超时返回后
/// （正在睡的这一片睡满就退出）。少一处就会出现"UI 显示已取消、网络仍在传"。
struct SessionLoop {
    let fd: Int32
    let session: OpaquePointer
    let cancel: CancellationFlag
    let stats: LoopStats

    init(fd: Int32, session: OpaquePointer, cancel: CancellationFlag, stats: LoopStats = LoopStats()) {
        self.fd = fd
        self.session = session
        self.cancel = cancel
        self.stats = stats
    }

    /// `deadlineMs` 从进入本次调用起算；nil 表示不设总时限，只受取消控制。
    ///
    /// `pausedMs` 累计"不该算进预算"的毫秒数。只有 keyboard-interactive 用得上：
    /// 回调里等用户答题的那段时间发生在 `call()` 内部，算进预算就会出现
    /// "用户去找验证码的 40 秒被认证超时杀掉"（M1-04 §4）。
    /// 返回最后一次调用的真实返回码（非 EAGAIN）。
    @discardableResult
    mutating func drive(deadlineMs: Int64? = nil,
                        pausedMs: () -> Int64 = { 0 },
                        _ call: () -> Int32) throws -> Int32 {
        let start = uptimeMilliseconds()
        var directionless = 0

        while true {
            if cancel.isSet { throw CancellationError() }

            let rc = call()
            if rc != LIBSSH2_ERROR_EAGAIN { return rc }
            stats.eagain += 1

            let elapsed = uptimeMilliseconds() - start - pausedMs()
            if let deadlineMs, elapsed >= deadlineMs { throw RemoteError.network(.timeout) }

            let directions = libssh2_session_block_directions(session)
            guard directions != 0 else {
                // EAGAIN 却说不出要等哪一边：libssh2 的状态机自相矛盾。
                // 不 sleep 就变成忙等，连吃三片直接判协议违规，不猜它想干嘛。
                directionless += 1
                if directionless > 3 {
                    throw RemoteError.protocolViolation("EAGAIN 但 block_directions 为 0（rc=\(rc)）")
                }
                continue
            }
            directionless = 0

            var events: Int16 = 0
            if directions & LIBSSH2_SESSION_BLOCK_INBOUND != 0 { events |= Int16(POLLIN) }
            if directions & LIBSSH2_SESSION_BLOCK_OUTBOUND != 0 { events |= Int16(POLLOUT) }

            let slice: Int32
            if let deadlineMs {
                slice = Int32(max(1, min(Int64(TCPStream.pollSliceMs), deadlineMs - elapsed)))
            } else {
                slice = TCPStream.pollSliceMs
            }

            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            stats.polls += 1
            let pollRC = withUnsafeMutablePointer(to: &descriptor) { poll($0, 1, slice) }
            if pollRC == 0 {
                stats.pollTimeouts += 1
                continue                      // 睡满一片也是取消检查点：下一轮循环顶部会查
            }
            if pollRC < 0, errno != EINTR {
                throw RemoteError.network(.connectionLost)
            }
        }
    }
}
