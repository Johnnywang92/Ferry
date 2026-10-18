import FerryContracts
@testable import FerryCore
import Foundation
import Testing

@Suite("M7: 服务器间直传与双向独立限速")
struct RelayEngineTests {

    private final class ProgressCollector: @unchecked Sendable {
        private let lock = NSLock()
        var reports: [RelayEngine.Progress] = []
        func append(_ p: RelayEngine.Progress) {
            lock.lock()
            defer { lock.unlock() }
            reports.append(p)
        }
    }

    @Test("RelayEngine：单文件跨服务器流式中继直传（零本地临时文件）")
    func relaySingleFile() async throws {
        let serverA = InMemoryFileSystem()
        let serverB = InMemoryFileSystem()

        let content = "Hello Server-to-Server Relay via Ferry RAM Pipeline!"
        try await serverA.seed([.text("source.txt", content)])

        let srcPath = RemotePath(string: "/source.txt", isAbsolute: true)!
        let dstPath = RemotePath(string: "/destination.txt", isAbsolute: true)!

        let collector = ProgressCollector()
        let bytesTransferred = try await RelayEngine.relayFile(
            from: srcPath,
            using: serverA,
            to: dstPath,
            using: serverB,
            chunkBytes: 16, // 用小 chunk 验证多轮泵循环
            rateLimiter: nil,
            onProgress: { p in
                collector.append(p)
            }
        )

        #expect(bytesTransferred == Int64(content.utf8.count))
        #expect(!collector.reports.isEmpty)
        #expect(collector.reports.last?.isCompleted == true)

        // 验证 Server B 上写出的文件内容与大小
        let statB = try await serverB.stat(dstPath)
        #expect(statB.size == Int64(content.utf8.count))

        let readerB = try await serverB.openRead(dstPath, offset: 0)
        let readBackData = try await readerB.read(maxBytes: 1024)
        await readerB.close()
        #expect(String(data: readBackData, encoding: .utf8) == content)
    }

    @Test("RelayEngine：递归直传跨服务器整个多层目录")
    func relayDirectoryTree() async throws {
        let serverA = InMemoryFileSystem()
        let serverB = InMemoryFileSystem()

        // 在 Server A 上铺设目录树
        try await serverA.mkdir(RemotePath(string: "/webapp", isAbsolute: true)!, permissions: 0o755)
        try await serverA.mkdir(RemotePath(string: "/webapp/static", isAbsolute: true)!, permissions: 0o755)
        try await serverA.seed([
            .text("webapp/index.html", "<h1>Hello WebApp</h1>"),
            .text("webapp/static/style.css", "body { background: #000; }"),
            .text("webapp/static/app.js", "console.log('Ferry Relay');")
        ])

        let srcDir = RemotePath(string: "/webapp", isAbsolute: true)!
        let dstDir = RemotePath(string: "/backup/webapp", isAbsolute: true)!

        let result = try await RelayEngine.relayDirectory(
            from: srcDir,
            using: serverA,
            to: dstDir,
            using: serverB,
            chunkBytes: 64,
            rateLimiter: nil,
            onProgress: nil
        )

        #expect(result.filesCount == 3)
        #expect(result.totalBytes > 0)

        // 验证 Server B 目录树与文件
        let indexStat = try await serverB.stat(RemotePath(string: "/backup/webapp/index.html", isAbsolute: true)!)
        #expect(indexStat.size == Int64("<h1>Hello WebApp</h1>".utf8.count))

        let cssStat = try await serverB.stat(RemotePath(string: "/backup/webapp/static/style.css", isAbsolute: true)!)
        #expect(cssStat.size == Int64("body { background: #000; }".utf8.count))

        let jsStat = try await serverB.stat(RemotePath(string: "/backup/webapp/static/app.js", isAbsolute: true)!)
        #expect(jsStat.size == Int64("console.log('Ferry Relay');".utf8.count))
    }

    @Test("RelayEngine：传输期间响应 Task 取消，立即中断")
    func relayCancellation() async throws {
        let serverA = InMemoryFileSystem()
        let serverB = InMemoryFileSystem()

        let bigData = String(repeating: "LargeDataChunkBlock", count: 1000)
        try await serverA.seed([.text("big.bin", bigData)])

        let srcPath = RemotePath(string: "/big.bin", isAbsolute: true)!
        let dstPath = RemotePath(string: "/big_copied.bin", isAbsolute: true)!

        // 使用限制 100 字节/秒的限速器拉长传输时间
        let slowLimiter = RateLimiter(bytesPerSecond: 100)

        let task = Task {
            try await RelayEngine.relayFile(
                from: srcPath,
                using: serverA,
                to: dstPath,
                using: serverB,
                chunkBytes: 16,
                rateLimiter: slowLimiter,
                onProgress: nil
            )
        }

        try await Task.sleep(nanoseconds: 20_000_000) // 20ms
        task.cancel()

        let res = await task.result
        switch res {
        case .success:
            Issue.record("中继直传在 Task 取消后应当抛出 CancellationError")
        case .failure(let err):
            #expect(err is CancellationError)
        }
    }

    @Test("TransferQueue：独立的上传与下载限速器可动态调速")
    func dualRateLimiters() async throws {
        let queue = TransferQueue(
            uploadBytesPerSecond: 500_000,
            downloadBytesPerSecond: 1_000_000
        )

        #expect(await queue.uploadRateLimiter.bytesPerSecond == 500_000)
        #expect(await queue.downloadRateLimiter.bytesPerSecond == 1_000_000)

        // 动态调速
        await queue.setRateLimits(uploadBytesPerSecond: 250_000, downloadBytesPerSecond: 5_000_000)
        #expect(await queue.uploadRateLimiter.bytesPerSecond == 250_000)
        #expect(await queue.downloadRateLimiter.bytesPerSecond == 5_000_000)

        // 解除限制
        await queue.setRateLimits(uploadBytesPerSecond: nil, downloadBytesPerSecond: nil)
        #expect(await queue.uploadRateLimiter.bytesPerSecond == nil)
        #expect(await queue.downloadRateLimiter.bytesPerSecond == nil)
    }
}
