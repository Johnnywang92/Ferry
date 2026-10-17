import Foundation

/// 令牌桶限速器（v2.3 §342）。
///
/// 运行在 actor 上，保证在多并发传输（默认 N=3）下各 worker
/// 共享限速预算时计算严格串行无竞争。
///
/// 速率单位为字节/秒（bytes per second）。若 `bytesPerSecond == nil` 或 `<= 0`，
/// 则表示无限制（unlimited），`consume` 立即放行。
public actor RateLimiter {
    public private(set) var bytesPerSecond: Int64?
    private var availableTokens: Double
    private var lastRefillNanoseconds: UInt64
    private let clock: @Sendable () -> UInt64

    public init(bytesPerSecond: Int64? = nil,
                clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.bytesPerSecond = (bytesPerSecond != nil && bytesPerSecond! > 0) ? bytesPerSecond : nil
        self.availableTokens = Double(self.bytesPerSecond ?? 0)
        self.clock = clock
        self.lastRefillNanoseconds = clock()
    }

    /// 更新限速值。运行时动态调速，立即生效。
    public func setBytesPerSecond(_ limit: Int64?) {
        refill()
        self.bytesPerSecond = (limit != nil && limit! > 0) ? limit : nil
        if let limit = self.bytesPerSecond {
            self.availableTokens = min(self.availableTokens, Double(limit))
        }
    }

    /// 消费指定字节的配额。如果配额不足，挂起当前任务等待令牌补充。
    ///
    /// 响应任务取消：挂起睡眠期间如果外部触发 `Task.cancel()`，将直接抛出 `CancellationError`。
    public func consume(bytes: Int) async throws {
        guard let limit = bytesPerSecond, limit > 0 else {
            return // 无限速
        }
        guard bytes > 0 else { return }

        while true {
            try Task.checkCancellation()
            refill()

            if availableTokens >= Double(bytes) {
                availableTokens -= Double(bytes)
                return
            }

            // 令牌不足，计算需要补充的差额与对应的休眠时长
            let needed = Double(bytes) - availableTokens
            let waitSeconds = needed / Double(limit)
            let waitNanoseconds = UInt64(waitSeconds * 1_000_000_000)

            // 最少睡 1ms，避免忙等自旋；最大睡 500ms，保证可动态响应调速与取消
            let clampedSleep = max(min(waitNanoseconds, 500_000_000), 1_000_000)
            try await Task.sleep(nanoseconds: clampedSleep)
        }
    }

    private func refill() {
        guard let limit = bytesPerSecond, limit > 0 else { return }
        let now = clock()
        let elapsedNanos = now &- lastRefillNanoseconds
        lastRefillNanoseconds = now

        let elapsedSeconds = Double(elapsedNanos) / 1_000_000_000.0
        let added = elapsedSeconds * Double(limit)
        // 桶容量最大为 1 秒的配额（防止长时间空闲后突发脉冲压垮对端）
        availableTokens = min(availableTokens + added, Double(limit))
    }
}
