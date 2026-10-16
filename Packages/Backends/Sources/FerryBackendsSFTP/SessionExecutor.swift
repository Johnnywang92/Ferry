import Foundation

/// ADR-0001 D7：一条 session 一个专属串行 executor，所有 libssh2 调用排在这一个线程上。
///
/// 两个理由都在这台机器上：libssh2 的 session 不是线程安全的；
/// 而 `poll` 会真的睡住执行线程，占着 Swift 协作线程池就等于
/// 用 3 条并发传输把整个 App 的 async 任务饿死（v2.3 §并发模型 设计原因）。
final class SessionExecutor: SerialExecutor, @unchecked Sendable {
    let queue: DispatchQueue

    init(label: String) {
        queue = DispatchQueue(label: label, qos: .userInitiated, autoreleaseFrequency: .never)
    }

    func enqueue(_ job: consuming ExecutorJob) {
        // ExecutorJob 不可拷贝，也不能跨 dispatch 块持有；转成 UnownedJob 后
        // 由队列在同一个线程上就地执行——正是"串行"要的东西。
        let unowned = UnownedJob(job)
        queue.async { [self] in
            unowned.runSynchronously(on: asUnownedSerialExecutor())
        }
    }

    func checkIfExecuting(onSerialExecutor executor: any SerialExecutor) -> Bool {
        (executor as? SessionExecutor)?.queue === queue
    }
}

/// 当前线程的机器标识。串行 executor 的"只有一个线程"这条声明
/// 必须能被测试证明，而不是靠读代码的人相信 dispatch 的语义。
func currentThreadID() -> UInt64 {
    UInt64(pthread_mach_thread_np(pthread_self()))
}
