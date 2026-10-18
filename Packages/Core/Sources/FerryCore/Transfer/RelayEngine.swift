import Foundation

/// 服务器间直传流式中继引擎（Server-to-Server Relay Transfer / FXP 现代替代方案）。
///
/// 特性与纪律：
/// 1. 内存中继（Client-Assisted Relay）：从源端 Reader 流式读取并通过目标端 Writer 写入，
///    数据在内存管道流转，零本地磁盘临时文件写入，保护本地 SSD 寿命并杜绝磁盘容量不足问题；
/// 2. 限速集成：支持 RateLimiter 令牌桶接入，在跨机中继时控制本地网络占用；
/// 3. 取消响应：每 chunk 与每文件边界严格响应 `Task.checkCancellation()`，
///    一旦取消自动调用 writer.abort() 与 reader.close()，不留半截损坏文件；
/// 4. 目录递归：支持整目录跨服务器镜像拷贝，自动在目标服务器构建目录树。
public enum RelayEngine {
    /// 默认中继 chunk 块大小：256 KB
    public static let defaultChunkBytes = 262_144

    /// 中继进度快照
    public struct Progress: Sendable, Hashable {
        public let bytesDone: Int64
        public let totalBytes: Int64?
        public let currentItemName: String
        public let isCompleted: Bool

        public init(bytesDone: Int64, totalBytes: Int64?, currentItemName: String, isCompleted: Bool = false) {
            self.bytesDone = bytesDone
            self.totalBytes = totalBytes
            self.currentItemName = currentItemName
            self.isCompleted = isCompleted
        }
    }

    /// 在两台远端服务器之间流式中继传输单个文件（内存管道，零本地磁盘 I/O）
    @discardableResult
    public static func relayFile(
        from sourcePath: RemotePath,
        using sourceTransfer: any RemoteTransfer,
        to destPath: RemotePath,
        using destTransfer: any RemoteTransfer,
        chunkBytes: Int = defaultChunkBytes,
        rateLimiter: RateLimiter? = nil,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> Int64 {
        let reader = try await sourceTransfer.openRead(sourcePath, offset: 0)
        let totalSize = await reader.totalSize

        let writer: any RemoteWriter
        do {
            writer = try await destTransfer.createWrite(destPath, offset: 0)
        } catch {
            await reader.close()
            throw error
        }

        var bytesWritten: Int64 = 0
        let itemName = sourcePath.displayString()

        do {
            while true {
                try Task.checkCancellation()
                let chunk = try await reader.read(maxBytes: chunkBytes)
                if chunk.isEmpty { break } // EOF

                if let limiter = rateLimiter {
                    try await limiter.consume(bytes: chunk.count)
                }

                _ = try await writer.write(chunk)
                bytesWritten += Int64(chunk.count)
                onProgress?(Progress(bytesDone: bytesWritten, totalBytes: totalSize, currentItemName: itemName, isCompleted: false))
            }

            try await writer.commit()
            await reader.close()
            onProgress?(Progress(bytesDone: bytesWritten, totalBytes: totalSize ?? bytesWritten, currentItemName: itemName, isCompleted: true))
            return bytesWritten
        } catch is CancellationError {
            await writer.abort()
            await reader.close()
            throw CancellationError()
        } catch {
            await writer.abort()
            await reader.close()
            throw error
        }
    }

    /// 在两台远端服务器之间递归直传整个文件夹
    @discardableResult
    public static func relayDirectory(
        from sourceDir: RemotePath,
        using sourceClient: any RemoteFileSystem & RemoteTransfer,
        to destDir: RemotePath,
        using destClient: any RemoteFileSystem & RemoteTransfer,
        chunkBytes: Int = defaultChunkBytes,
        rateLimiter: RateLimiter? = nil,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> (filesCount: Int, totalBytes: Int64) {
        // 递归确保目标路径各层级父目录存在
        try await ensureDirectoryExists(destDir, on: destClient)

        let entries = try await sourceClient.list(sourceDir)
        var totalBytesTransferred: Int64 = 0
        var filesTransferred = 0

        for entry in entries.entries {
            try Task.checkCancellation()
            let subName = entry.path.wireBytes.split(separator: 0x2F).last.map(Array.init) ?? []
            guard !subName.isEmpty else { continue }
            let targetSubPath = try PathResolver.child(of: destDir, name: subName)

            if entry.kind == .directory {
                let subResult = try await relayDirectory(
                    from: entry.path,
                    using: sourceClient,
                    to: targetSubPath,
                    using: destClient,
                    chunkBytes: chunkBytes,
                    rateLimiter: rateLimiter,
                    onProgress: onProgress
                )
                filesTransferred += subResult.filesCount
                totalBytesTransferred += subResult.totalBytes
            } else {
                let transferred = try await relayFile(
                    from: entry.path,
                    using: sourceClient,
                    to: targetSubPath,
                    using: destClient,
                    chunkBytes: chunkBytes,
                    rateLimiter: rateLimiter,
                    onProgress: onProgress
                )
                filesTransferred += 1
                totalBytesTransferred += transferred
            }
        }

        return (filesTransferred, totalBytesTransferred)
    }

    /// 递归确保从根目录到指定路径的每一级父目录均已存在
    private static func ensureDirectoryExists(
        _ path: RemotePath,
        on client: any RemoteFileSystem
    ) async throws {
        let parts = path.wireBytes.split(separator: 0x2F).filter { !$0.isEmpty }
        var current = PathResolver.root
        for part in parts {
            let child = try PathResolver.child(of: current, name: Array(part))
            let isExisting: Bool
            do {
                _ = try await client.stat(child)
                isExisting = true
            } catch {
                isExisting = false
            }
            if !isExisting {
                try? await client.mkdir(child, permissions: 0o755)
            }
            current = child
        }
    }
}
