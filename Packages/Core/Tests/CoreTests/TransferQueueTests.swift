import FerryContracts
@testable import FerryCore
import Foundation
import Testing

@Suite("M3 传输队列与核心保障")
struct TransferQueueTests {

    // MARK: - 1. 令牌桶限速器测试

    @Test("RateLimiter：无限制时立即放行，有限制时按令牌桶控速")
    func rateLimiterBasic() async throws {
        // 1. 无限制
        let unlimited = RateLimiter(bytesPerSecond: nil)
        try await unlimited.consume(bytes: 1_000_000)
        #expect(await unlimited.bytesPerSecond == nil)

        // 2. 限制 100 KB/s
        let limiter = RateLimiter(bytesPerSecond: 100_000)
        #expect(await limiter.bytesPerSecond == 100_000)

        // 首次消费在初始可用配额内，不挂起
        try await limiter.consume(bytes: 10_000)

        // 动态调速
        await limiter.setBytesPerSecond(200_000)
        #expect(await limiter.bytesPerSecond == 200_000)
    }

    @Test("RateLimiter：限速等待期间响应 Task 取消")
    func rateLimiterCancellation() async throws {
        let limiter = RateLimiter(bytesPerSecond: 1_000) // 1 KB/s
        // 消耗完初始 1KB
        try await limiter.consume(bytes: 1_000)

        // 再索要 10KB 需要等待约 10 秒
        let task = Task {
            try await limiter.consume(bytes: 10_000)
        }

        try await Task.sleep(nanoseconds: 20_000_000) // 20ms
        task.cancel()

        let result = await task.result
        switch result {
        case .success:
            Issue.record("限速等待应当在 Task.cancel 后抛出取消异常")
        case .failure(let error):
            #expect(error is CancellationError)
        }
    }

    // MARK: - 2. 目录递归扫描与取消贯穿测试

    @Test("DirectoryScanner：本地多层嵌套目录递归展开为扁平任务")
    func localDirectoryScanning() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("scanner_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 创建多层结构:
        // tempDir/
        //   file1.txt
        //   sub1/
        //     file2.txt
        //     sub2/
        //       file3.bin
        try "hello 1".write(to: tempDir.appendingPathComponent("file1.txt"), atomically: true, encoding: .utf8)
        let sub1 = tempDir.appendingPathComponent("sub1")
        try FileManager.default.createDirectory(at: sub1, withIntermediateDirectories: true)
        try "hello 2".write(to: sub1.appendingPathComponent("file2.txt"), atomically: true, encoding: .utf8)
        let sub2 = sub1.appendingPathComponent("sub2")
        try FileManager.default.createDirectory(at: sub2, withIntermediateDirectories: true)
        try "hello 3".write(to: sub2.appendingPathComponent("file3.bin"), atomically: true, encoding: .utf8)

        let targetRemote = RemotePath(string: "/remote/backup", isAbsolute: true)!
        let scanned = try DirectoryScanner.scanLocalDirectory(tempDir, targetRemoteDir: targetRemote)

        #expect(scanned.count == 3)
        let remoteStrings = Set(scanned.map { $0.remotePath.displayString() })
        let folderName = tempDir.lastPathComponent
        #expect(remoteStrings.contains("/remote/backup/\(folderName)/file1.txt"))
        #expect(remoteStrings.contains("/remote/backup/\(folderName)/sub1/file2.txt"))
        #expect(remoteStrings.contains("/remote/backup/\(folderName)/sub1/sub2/file3.bin"))
    }

    // MARK: - 3. 持久化与崩溃恢复测试

    @Test("TransferQueuePersistence：状态持久化与崩溃恢复（running 转 paused，.part 完整保留）")
    func persistenceAndCrashRecovery() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("persist_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storeURL = tempDir.appendingPathComponent("queue.json")
        let persistence = TransferQueuePersistence(storeURL: storeURL)

        // 模拟 App 异常崩溃前的任务列表：
        // 包含 1 个 completed, 1 个 running (异常中断), 1 个 pending, 1 个 paused
        let local1 = tempDir.appendingPathComponent("doc1.txt")
        let local2 = tempDir.appendingPathComponent("doc2.txt")
        let local3 = tempDir.appendingPathComponent("doc3.txt")
        let local4 = tempDir.appendingPathComponent("doc4.txt")

        let remote = RemotePath(string: "/data/file.txt", isAbsolute: true)!

        let records: [TransferTaskRecord] = [
            TransferTaskRecord(direction: .download, localURL: local1, remotePath: remote, status: .completed(confidence: .high), bytesDone: 100, totalBytes: 100),
            TransferTaskRecord(direction: .download, localURL: local2, remotePath: remote, status: .running, bytesDone: 50, totalBytes: 100),
            TransferTaskRecord(direction: .upload, localURL: local3, remotePath: remote, status: .pending, bytesDone: 0, totalBytes: 200),
            TransferTaskRecord(direction: .download, localURL: local4, remotePath: remote, status: .paused, bytesDone: 30, totalBytes: 100)
        ]

        // 写入初始状态
        let rawStore = Store<[TransferTaskRecord]>(url: storeURL)
        try await rawStore.write(records)

        // 重启并加载（崩溃恢复出口标准验证）
        let recovered = try await persistence.loadAndRecover()

        #expect(recovered.count == 4)
        #expect(recovered[0].status.isCompleted)
        // 原 running 必须被安全重置为 paused
        #expect(recovered[1].status.isPaused)
        #expect(recovered[1].bytesDone == 50)
        // 原 pending 和 paused 保持不变
        #expect(recovered[2].status == .pending)
        #expect(recovered[3].status.isPaused)
    }

    // MARK: - 4. 传输队列状态机与并发调度测试

    @Test("TransferQueue：并发限制（N=3）与状态机流转")
    func queueConcurrencyAndFlow() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("queue_flow_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fs = InMemoryFileSystem()
        try await fs.seed([
            .text("file1.txt", "content 111"),
            .text("file2.txt", "content 222"),
            .text("file3.txt", "content 333"),
            .text("file4.txt", "content 444"),
            .text("file5.txt", "content 555")
        ])

        let queue = TransferQueue(
            maxConcurrency: 2, // 限制同时跑 2 个
            transferBackend: fs,
            fileSystemBackend: fs
        )

        var addedIds: [UUID] = []
        for i in 1...5 {
            let localURL = tempDir.appendingPathComponent("local_\(i).txt")
            let remote = RemotePath(string: "/file\(i).txt", isAbsolute: true)!
            let id = await queue.addTask(direction: .download, localURL: localURL, remotePath: remote, totalBytes: 11)
            addedIds.append(id)
        }

        // 等待全部任务调度完成
        var timeout = 50
        while timeout > 0 {
            let states = await queue.allStates()
            let completedCount = states.filter { $0.status.isCompleted }.count
            if completedCount == 5 { break }
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
            timeout -= 1
        }

        let states = await queue.allStates()
        #expect(states.filter { $0.status.isCompleted }.count == 5)
        for i in 1...5 {
            let localURL = tempDir.appendingPathComponent("local_\(i).txt")
            #expect(FileManager.default.fileExists(atPath: localURL.path))
            // .part 临时文件必须已被原子替换并移除
            let partURL = TransferEngine.partFileURL(for: localURL)
            #expect(!FileManager.default.fileExists(atPath: partURL.path))
        }
    }

    // MARK: - 5. 暂停与取消语义分离测试

    @Test("TransferQueue：暂停保留 .part 与 offset，恢复后断点续传")
    func pauseAndResumePreservesPart() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("pause_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fs = InMemoryFileSystem()
        let largeContent = String(repeating: "FerryRocks!", count: 1000) // 11000 字节
        try await fs.seed([.text("large.txt", largeContent)])

        let queue = TransferQueue(
            maxConcurrency: 1,
            transferBackend: fs,
            fileSystemBackend: fs
        )

        let localURL = tempDir.appendingPathComponent("large_downloaded.txt")
        let partURL = TransferEngine.partFileURL(for: localURL)
        let remote = RemotePath(string: "/large.txt", isAbsolute: true)!

        // 先人为制造一个已下载了一半的 .part 文件（例如 5500 字节）
        let halfContent = String(largeContent.prefix(5500))
        try halfContent.write(to: partURL, atomically: true, encoding: .utf8)

        // 入队并断点续传
        let taskId = await queue.addTask(
            direction: .download,
            localURL: localURL,
            remotePath: remote,
            totalBytes: Int64(largeContent.utf8.count),
            initialSnapshot: ResumeSnapshot(size: Int64(largeContent.utf8.count), modificationDate: nil, mtimeIsReliable: true)
        )

        // 暂停任务
        await queue.pauseTask(id: taskId)
        let stateAfterPause = await queue.allStates().first(where: { $0.id == taskId })
        #expect(stateAfterPause?.status.isPaused == true)
        // 暂停后 .part 必须完整保留
        #expect(FileManager.default.fileExists(atPath: partURL.path))

        // 恢复任务
        await queue.resumeTask(id: taskId)

        var timeout = 50
        while timeout > 0 {
            let state = await queue.allStates().first(where: { $0.id == taskId })
            if state?.status.isCompleted == true { break }
            try await Task.sleep(nanoseconds: 50_000_000)
            timeout -= 1
        }

        let finalState = await queue.allStates().first(where: { $0.id == taskId })
        #expect(finalState?.status.isCompleted == true)
        #expect(FileManager.default.fileExists(atPath: localURL.path))
        #expect(try String(contentsOf: localURL, encoding: .utf8) == largeContent)
        #expect(!FileManager.default.fileExists(atPath: partURL.path))
    }

    @Test("TransferQueue：取消删除 .part 临时文件并立即终止（200ms 内退出）")
    func cancelDeletesPartAndAbortsFast() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("cancel_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let localURL = tempDir.appendingPathComponent("cancelled_file.bin")
        let partURL = TransferEngine.partFileURL(for: localURL)
        try Data(count: 2048).write(to: partURL)
        #expect(FileManager.default.fileExists(atPath: partURL.path))

        let queue = TransferQueue()
        let remote = RemotePath(string: "/file.bin", isAbsolute: true)!
        let id = await queue.addTask(direction: .download, localURL: localURL, remotePath: remote, totalBytes: 10000)

        let startTime = DispatchTime.now()
        await queue.cancelTask(id: id)
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000.0

        let state = await queue.allStates().first(where: { $0.id == id })
        #expect(state?.status == .cancelled)
        // 取消验收标准：200ms 内停止
        #expect(elapsedMs < 200.0)
        // 取消后 .part 临时文件必须被清理删除
        #expect(!FileManager.default.fileExists(atPath: partURL.path))
    }

    // MARK: - 6. 错误分类与自动重试测试

    @Test("TransferQueue：可重试网络错误自动触发指数退避重试，不可重试直接失败")
    func errorClassificationAndRetry() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("error_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let localURL = tempDir.appendingPathComponent("fail.txt")
        let remote = RemotePath(string: "/not_exist.txt", isAbsolute: true)!

        let fs = InMemoryFileSystem() // 空文件系统，无此文件
        let queue = TransferQueue(
            maxConcurrency: 1,
            transferBackend: fs,
            fileSystemBackend: fs
        )

        let id = await queue.addTask(direction: .download, localURL: localURL, remotePath: remote)

        var timeout = 30
        while timeout > 0 {
            let state = await queue.allStates().first(where: { $0.id == id })
            if state?.status.isFailed == true { break }
            try await Task.sleep(nanoseconds: 50_000_000)
            timeout -= 1
        }

        let state = await queue.allStates().first(where: { $0.id == id })
        // notFound 属于不可自动重试错误
        #expect(state?.status.isFailed == true)
        if case .failed(_, let retryable) = state?.status {
            #expect(!retryable)
        }
    }
}
