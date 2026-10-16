import Foundation
import os

/// 取消标志：外部线程只置位，session 线程在 poll 循环边界自查（ADR-0001 D3）。
///
/// 用锁而不是裸 `Bool`：Swift 的普通变量跨线程读写是 data race，
/// 编译器不报错但可能把标志当成循环里的常量，那样取消永远不生效——
/// 正是 ADR 要防的"UI 显示已取消、网络仍在传"。
public final class CancellationFlag: Sendable {
    private struct Storage {
        var isSet = false
        var requestedAtNanoseconds: UInt64?
    }

    private let state = OSAllocatedUnfairLock(initialState: Storage())

    public init() {}

    public var isSet: Bool { state.withLock { $0.isSet } }

    /// 第一次置位的单调时刻，用来量化"置标志→循环退出"的真实延迟。后续置位不覆盖。
    public var requestedAtNanoseconds: UInt64? { state.withLock { $0.requestedAtNanoseconds } }

    public func cancel() {
        state.withLock { storage in
            guard !storage.isSet else { return }
            storage.isSet = true
            storage.requestedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
        }
    }
}
