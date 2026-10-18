import Foundation

/// 传输队列调度器（v2.3 §315-347, ADR-0001 §3）。
///
/// 核心职责：
/// 1. 任务并发调度：默认并发数 N=3，单任务失败隔离；
/// 2. 暂停与取消语义严格分离（暂停保留 .part 与已传偏移，取消删除 .part 与清理远端）；
/// 3. 错误自动分类与指数退避重试（仅 .network 类自动重试 1s/2s/4s）；
/// 4. 实时速度与 ETA 预估计算；
/// 5. 500ms 防抖落盘与崩溃恢复；
/// 6. 限速器集成。
public actor TransferQueue {
    public static let defaultMaxConcurrency: Int = 3
    public static let maxRetryAttempts: Int = 3

    public private(set) var maxConcurrency: Int
    public let rateLimiter: RateLimiter
    public let uploadRateLimiter: RateLimiter
    public let downloadRateLimiter: RateLimiter
    private let persistence: TransferQueuePersistence?

    private var records: [TransferTaskRecord] = []
    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    private var taskStates: [UUID: TransferTaskState] = [:]

    // 传输后端
    public private(set) var transferBackend: (any RemoteTransfer)?
    public private(set) var fileSystemBackend: (any RemoteFileSystem)?

    // 状态流广播
    private var stateChangeListeners: [@Sendable ([TransferTaskState]) -> Void] = []

    public init(
        maxConcurrency: Int = defaultMaxConcurrency,
        bytesPerSecond: Int64? = nil,
        uploadBytesPerSecond: Int64? = nil,
        downloadBytesPerSecond: Int64? = nil,
        persistenceURL: URL? = nil,
        transferBackend: (any RemoteTransfer)? = nil,
        fileSystemBackend: (any RemoteFileSystem)? = nil
    ) {
        self.maxConcurrency = maxConcurrency
        self.rateLimiter = RateLimiter(bytesPerSecond: bytesPerSecond)
        self.uploadRateLimiter = RateLimiter(bytesPerSecond: uploadBytesPerSecond ?? bytesPerSecond)
        self.downloadRateLimiter = RateLimiter(bytesPerSecond: downloadBytesPerSecond ?? bytesPerSecond)
        self.transferBackend = transferBackend
        self.fileSystemBackend = fileSystemBackend
        if let url = persistenceURL {
            self.persistence = TransferQueuePersistence(storeURL: url)
        } else {
            self.persistence = nil
        }
    }

    /// 动态更新上下行限速（字节/秒，nil 或 <=0 表示无限制）
    public func setRateLimits(uploadBytesPerSecond: Int64?, downloadBytesPerSecond: Int64?) async {
        await uploadRateLimiter.setBytesPerSecond(uploadBytesPerSecond)
        await downloadRateLimiter.setBytesPerSecond(downloadBytesPerSecond)
        await rateLimiter.setBytesPerSecond(uploadBytesPerSecond ?? downloadBytesPerSecond)
    }

    /// 设置活动后端连接。
    public func setBackend(transfer: (any RemoteTransfer)?, fileSystem: (any RemoteFileSystem)? = nil) {
        self.transferBackend = transfer
        self.fileSystemBackend = fileSystem
        scheduleNext()
    }

    /// 设置并发数限制。
    public func setMaxConcurrency(_ limit: Int) {
        self.maxConcurrency = max(1, limit)
        scheduleNext()
    }

    /// 注册状态变更监听。
    public func addStateListener(_ listener: @escaping @Sendable ([TransferTaskState]) -> Void) {
        stateChangeListeners.append(listener)
        listener(allStates())
    }

    /// 初始化并执行崩溃恢复。
    public func initializeAndRecover() async {
        guard let p = persistence else { return }
        if let recovered = try? await p.loadAndRecover() {
            self.records = recovered
            for r in recovered {
                self.taskStates[r.id] = TransferTaskState(record: r)
            }
            notifyListeners()
        }
    }

    // MARK: - 任务入队

    /// 单文件入队。
    @discardableResult
    public func addTask(
        direction: TransferDirection,
        localURL: URL,
        remotePath: RemotePath,
        totalBytes: Int64? = nil,
        initialSnapshot: ResumeSnapshot? = nil
    ) -> UUID {
        let record = TransferTaskRecord(
            direction: direction,
            localURL: localURL,
            remotePath: remotePath,
            status: .pending,
            bytesDone: 0,
            totalBytes: totalBytes,
            initialSnapshot: initialSnapshot
        )
        records.append(record)
        taskStates[record.id] = TransferTaskState(record: record)
        notifyListeners()
        scheduleSave()
        scheduleNext()
        return record.id
    }

    /// 批量任务入队（文件夹递归展开结果）。
    @discardableResult
    public func addScannedBatch(
        _ files: [DirectoryScanner.ScannedFile],
        direction: TransferDirection
    ) -> [UUID] {
        var ids: [UUID] = []
        for file in files {
            let record = TransferTaskRecord(
                direction: direction,
                localURL: file.localURL,
                remotePath: file.remotePath,
                status: .pending,
                bytesDone: 0,
                totalBytes: file.size
            )
            records.append(record)
            taskStates[record.id] = TransferTaskState(record: record)
            ids.append(record.id)
        }
        notifyListeners()
        scheduleSave()
        scheduleNext()
        return ids
    }

    // MARK: - 任务控制（暂停 / 取消 / 重试）

    /// 暂停单个任务（保留 .part 与已传偏移）。
    public func pauseTask(id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        if let active = activeTasks[id] {
            records[index].status = .paused
            records[index].updatedAt = Date()
            updateTaskState(for: records[index])
            active.cancel()
        } else if records[index].status == .pending {
            records[index].status = .paused
            records[index].updatedAt = Date()
            updateTaskState(for: records[index])
        }
        notifyListeners()
        scheduleSave()
        scheduleNext()
    }

    /// 恢复单个任务（从断点续传）。
    public func resumeTask(id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        guard records[index].status.isPaused || records[index].status.isFailed else { return }
        records[index].status = .pending
        records[index].updatedAt = Date()
        updateTaskState(for: records[index])
        notifyListeners()
        scheduleSave()
        scheduleNext()
    }

    /// 取消单个任务（终止句柄、删除 .part、清理状态）。
    public func cancelTask(id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        let record = records[index]
        if let active = activeTasks[id] {
            active.cancel()
            activeTasks.removeValue(forKey: id)
        }
        // 清理本地 .part
        if record.direction == .download {
            let partURL = TransferEngine.partFileURL(for: record.localURL)
            try? FileManager.default.removeItem(at: partURL)
        }
        records[index].status = .cancelled
        records[index].updatedAt = Date()
        updateTaskState(for: records[index])
        notifyListeners()
        scheduleSave()
        scheduleNext()
    }

    /// 重试失败任务。
    public func retryTask(id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        guard records[index].status.isFailed else { return }
        records[index].status = .pending
        records[index].retryCount = 0
        records[index].updatedAt = Date()
        updateTaskState(for: records[index])
        notifyListeners()
        scheduleSave()
        scheduleNext()
    }

    /// 暂停全部活动任务。
    public func pauseAll() {
        for record in records where record.status.isRunning || record.status == .pending {
            pauseTask(id: record.id)
        }
    }

    /// 取消全部未完成任务（清理 .part 并停止全部调度）。
    public func cancelAll() {
        for record in records where !record.status.isTerminal {
            cancelTask(id: record.id)
        }
    }

    /// 恢复全部暂停或可重试的任务。
    public func resumeAll() {
        for record in records where record.status.isPaused {
            resumeTask(id: record.id)
        }
    }

    /// 清空已完成和已取消的任务。
    public func clearCompleted() {
        records.removeAll { $0.status.isTerminal }
        taskStates = taskStates.filter { _, state in !state.status.isTerminal }
        notifyListeners()
        scheduleSave()
    }

    // MARK: - 状态查询与度量

    public func allStates() -> [TransferTaskState] {
        records.map { taskStates[$0.id] ?? TransferTaskState(record: $0) }
    }

    /// 队列摘要（用于 UI 头部："1 项进行中 · 1 项失败 · 1 项等待"）。
    public var summary: (running: Int, failed: Int, pending: Int) {
        var r = 0, f = 0, p = 0
        for rec in records {
            switch rec.status {
            case .running: r += 1
            case .failed: f += 1
            case .pending: p += 1
            default: break
            }
        }
        return (r, f, p)
    }

    /// 汇总实时速率（用于底部状态栏："↑ x.x MB/s  ↓ y.y MB/s"，U7）。
    public var aggregateSpeed: (upload: Double, download: Double) {
        var up = 0.0, down = 0.0
        for state in taskStates.values where state.status.isRunning {
            if state.direction == .upload {
                up += state.speedBytesPerSec
            } else {
                down += state.speedBytesPerSec
            }
        }
        return (up, down)
    }

    // MARK: - 调度引擎

    private func scheduleNext() {
        guard let transfer = transferBackend else { return }
        while activeTasks.count < maxConcurrency {
            guard let nextIndex = records.firstIndex(where: { $0.status == .pending }) else {
                break
            }
            records[nextIndex].status = .running
            records[nextIndex].updatedAt = Date()
            let record = records[nextIndex]
            updateTaskState(for: record)
            notifyListeners()

            let taskId = record.id
            let fs = self.fileSystemBackend
            let limiter = (record.direction == .upload) ? self.uploadRateLimiter : self.downloadRateLimiter

            let worker = Task { [weak self, record] in
                guard let self else { return }
                await self.executeTransfer(
                    record: record,
                    transfer: transfer,
                    fileSystem: fs,
                    rateLimiter: limiter
                )
            }
            activeTasks[taskId] = worker
        }
    }

    private func executeTransfer(
        record: TransferTaskRecord,
        transfer: any RemoteTransfer,
        fileSystem: (any RemoteFileSystem)?,
        rateLimiter: RateLimiter
    ) async {
        let startTime = Date()

        do {
            let result: TransferExecutionResult
            if record.direction == .download {
                result = try await TransferEngine.download(
                    record.remotePath,
                    to: record.localURL,
                    using: transfer,
                    rateLimiter: rateLimiter,
                    usePartFile: true,
                    allowResume: true,
                    initialSnapshot: record.initialSnapshot,
                    onUpdate: { [weak self] progress in
                        let elapsed = max(Date().timeIntervalSince(startTime), 0.001)
                        let speed = Double(progress.bytesDone - record.bytesDone) / elapsed
                        let remaining = (progress.totalBytes ?? 0) - progress.bytesDone
                        let eta = (speed > 0 && remaining > 0) ? Double(remaining) / speed : nil

                        Task { [weak self] in
                            await self?.handleProgressUpdate(
                                id: record.id,
                                bytesDone: progress.bytesDone,
                                totalBytes: progress.totalBytes,
                                speed: speed,
                                eta: eta
                            )
                        }
                    }
                )
            } else {
                result = try await TransferEngine.upload(
                    from: record.localURL,
                    to: record.remotePath,
                    using: transfer,
                    fileSystem: fileSystem,
                    rateLimiter: rateLimiter,
                    usePartFile: true,
                    allowResume: true,
                    initialSnapshot: record.initialSnapshot,
                    onUpdate: { [weak self] progress in
                        let elapsed = max(Date().timeIntervalSince(startTime), 0.001)
                        let speed = Double(progress.bytesDone - record.bytesDone) / elapsed
                        let remaining = (progress.totalBytes ?? 0) - progress.bytesDone
                        let eta = (speed > 0 && remaining > 0) ? Double(remaining) / speed : nil

                        Task { [weak self] in
                            await self?.handleProgressUpdate(
                                id: record.id,
                                bytesDone: progress.bytesDone,
                                totalBytes: progress.totalBytes,
                                speed: speed,
                                eta: eta
                            )
                        }
                    }
                )
            }

            handleTransferSuccess(id: record.id, result: result)
        } catch is CancellationError {
            handleTransferCancelledOrPaused(id: record.id)
        } catch {
            handleTransferFailure(id: record.id, error: error)
        }
    }

    private func handleProgressUpdate(id: UUID, bytesDone: Int64, totalBytes: Int64?, speed: Double, eta: TimeInterval?) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].bytesDone = bytesDone
        if let total = totalBytes {
            records[index].totalBytes = total
        }
        let state = TransferTaskState(
            record: records[index],
            speedBytesPerSec: speed,
            etaSeconds: eta
        )
        taskStates[id] = state
        notifyListeners()
    }

    private func handleTransferSuccess(id: UUID, result: TransferExecutionResult) {
        activeTasks.removeValue(forKey: id)
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].status = .completed(confidence: result.confidence)
        records[index].bytesDone = result.totalBytes ?? records[index].bytesDone
        records[index].updatedAt = Date()
        updateTaskState(for: records[index])
        notifyListeners()
        scheduleSave()
        scheduleNext()
    }

    private func handleTransferCancelledOrPaused(id: UUID) {
        activeTasks.removeValue(forKey: id)
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        // 仅在任务当前仍为 running 时转为 paused（避免覆盖外部恢复操作置入的 .pending）
        if records[index].status == .running {
            records[index].status = .paused
        }
        records[index].updatedAt = Date()
        updateTaskState(for: records[index])
        notifyListeners()
        scheduleSave()
        scheduleNext()
    }

    private func handleTransferFailure(id: UUID, error: Error) {
        activeTasks.removeValue(forKey: id)
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }

        let isRetryable: Bool
        if let remoteErr = error as? RemoteError {
            isRetryable = remoteErr.isRetryable
        } else {
            isRetryable = false
        }

        if isRetryable && records[index].retryCount < Self.maxRetryAttempts {
            records[index].retryCount += 1
            records[index].status = .pending
            records[index].updatedAt = Date()
            updateTaskState(for: records[index])
            notifyListeners()

            // 指数退避：1s, 2s, 4s
            let backoffSeconds = min(pow(2.0, Double(records[index].retryCount - 1)), 30.0)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(backoffSeconds * 1_000_000_000))
                await self?.scheduleNext()
            }
        } else {
            let msg = (error as? RemoteError)?.diagnosticCode ?? error.localizedDescription
            records[index].status = .failed(message: msg, isRetryable: isRetryable)
            records[index].updatedAt = Date()
            updateTaskState(for: records[index])
            notifyListeners()
            scheduleSave()
            scheduleNext()
        }
    }

    private func updateTaskState(for record: TransferTaskRecord) {
        taskStates[record.id] = TransferTaskState(record: record)
    }

    private func notifyListeners() {
        let snapshot = allStates()
        for listener in stateChangeListeners {
            listener(snapshot)
        }
    }

    private func scheduleSave() {
        guard let p = persistence else { return }
        let snapshot = records
        Task {
            await p.scheduleSave(records: snapshot)
        }
    }
}
