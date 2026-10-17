import Foundation

/// 传输队列持久化与崩溃恢复管理（v2.3 §344, §345）。
///
/// 纪律要求：
/// 1. 状态落 JSON，状态变化后 500ms 防抖写盘；
/// 2. 高频进度变化**不**触发写盘，仅在状态转移（创建、暂停、完成、失败、取消）与退出时落盘；
/// 3. 崩溃恢复：启动时把上次异常中断的 `running` 全部转为 `paused`，保留磁盘上的 `.part` 文件，
///    绝不自动续传，避免启动即传错，需用户手动恢复。
public actor TransferQueuePersistence {
    private let store: Store<[TransferTaskRecord]>
    private var pendingSaveTask: Task<Void, Never>?
    private var cachedRecords: [TransferTaskRecord] = []

    public init(storeURL: URL) {
        self.store = Store<[TransferTaskRecord]>(url: storeURL)
    }

    /// 加载持久化记录并执行崩溃恢复。
    public func loadAndRecover() async throws -> [TransferTaskRecord] {
        let loaded = try await store.read() ?? []
        var recovered: [TransferTaskRecord] = []
        var hadInterruptedRunning = false

        for var record in loaded {
            if record.status.isRunning {
                // 崩溃恢复：把上次中断的 running 强制重置为 paused
                record.status = .paused
                record.updatedAt = Date()
                hadInterruptedRunning = true
            }
            recovered.append(record)
        }

        self.cachedRecords = recovered
        if hadInterruptedRunning {
            // 将恢复后的状态同步落盘
            try await store.write(recovered)
        }
        return recovered
    }

    /// 状态变更时触发 500ms 防抖落盘。
    public func scheduleSave(records: [TransferTaskRecord]) {
        self.cachedRecords = records
        pendingSaveTask?.cancel()
        pendingSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
            guard !Task.isCancelled else { return }
            await self?.flushNow()
        }
    }

    /// 立即强制落盘（用于 App 退出、暂停全部或取消时）。
    public func flushNow() async {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        try? await store.write(cachedRecords)
    }

    /// 清理存储文件。
    public func clear() async throws {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        cachedRecords.removeAll()
        try await store.delete()
    }
}
