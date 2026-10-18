import Foundation

/// 文件夹递归扫描器（v2.3 §343, §346）。
///
/// 纪律要求：
/// 1. 文件夹传输先递归展开为文件任务再入队；
/// 2. 取消贯穿长循环：在递归扫描的每一步必须响应 `Task.checkCancellation()`，
///    确保即使面对数万个文件的深层目录，用户点击取消时也能在 200ms 内瞬间停止。
public enum DirectoryScanner {

    /// 展开结果项。
    public struct ScannedFile: Sendable, Hashable {
        /// 本地文件 URL。
        public let localURL: URL
        /// 对应的远端路径。
        public let remotePath: RemotePath
        /// 文件大小（若已知）。
        public let size: Int64?

        public init(localURL: URL, remotePath: RemotePath, size: Int64? = nil) {
            self.localURL = localURL
            self.remotePath = remotePath
            self.size = size
        }
    }

    // MARK: - 本地目录展开（准备上传）

    /// 递归扫描本地文件夹，展开为相对于 `targetRemoteDir` 的文件列表。
    public static func scanLocalDirectory(
        _ rootURL: URL,
        targetRemoteDir: RemotePath,
        onProgress: (@Sendable (_ scannedCount: Int, _ currentItemName: String) -> Void)? = nil
    ) throws -> [ScannedFile] {
        var results: [ScannedFile] = []
        let fileManager = FileManager.default

        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDir) else {
            return []
        }

        if !isDir.boolValue {
            // 单文件
            let attrs = try? fileManager.attributesOfItem(atPath: rootURL.path)
            let size = attrs?[.size] as? Int64
            let targetPath = try targetRemoteDir.appending(component: rootURL.lastPathComponent)
            let scanned = ScannedFile(localURL: rootURL, remotePath: targetPath, size: size)
            onProgress?(1, rootURL.lastPathComponent)
            return [scanned]
        }

        // 根目录是文件夹：创建目标子目录名并展开子内容
        let folderName = rootURL.lastPathComponent
        let baseRemoteFolder = try targetRemoteDir.appending(component: folderName)

        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        for case let fileURL as URL in enumerator {
            try Task.checkCancellation()

            let resourceValues = try fileURL.resourceValues(forKeys: Set(keys))
            if resourceValues.isRegularFile == true {
                // 计算相对路径（使用 resolvingSymlinksInPath 抹平 macOS /var 符号链接）
                let rootResolved = rootURL.resolvingSymlinksInPath().path
                let fileResolved = fileURL.resolvingSymlinksInPath().path
                let relPath = fileResolved.deletingPrefix(rootResolved)
                let trimmedRel = relPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let components = trimmedRel.split(separator: "/").map(String.init)

                var targetRemote = baseRemoteFolder
                for c in components {
                    targetRemote = try targetRemote.appending(component: c)
                }

                let size = resourceValues.fileSize.map { Int64($0) }
                results.append(ScannedFile(localURL: fileURL, remotePath: targetRemote, size: size))
                onProgress?(results.count, fileURL.lastPathComponent)
            }
        }

        return results
    }

    // MARK: - 远端目录展开（准备下载）

    /// 递归扫描远端目录，展开为相对于 `targetLocalDir` 的下载文件列表。
    public static func scanRemoteDirectory(
        _ remoteRoot: RemotePath,
        fileSystem: any RemoteFileSystem,
        targetLocalDir: URL,
        onProgress: (@Sendable (_ scannedCount: Int, _ currentItemName: String) -> Void)? = nil
    ) async throws -> [ScannedFile] {
        var results: [ScannedFile] = []

        let rootItem = try await fileSystem.stat(remoteRoot)
        if rootItem.kind != .directory {
            // 单文件
            let localURL = targetLocalDir.appendingPathComponent(
                remoteRoot.lastComponent?.displayString() ?? "download"
            )
            let scanned = ScannedFile(localURL: localURL, remotePath: remoteRoot, size: rootItem.size)
            onProgress?(1, remoteRoot.lastComponent?.displayString() ?? "download")
            return [scanned]
        }

        let folderName = remoteRoot.lastComponent?.displayString() ?? "folder"
        let baseLocalDir = targetLocalDir.appendingPathComponent(folderName, isDirectory: true)

        try await scanRemoteRecursive(
            currentRemote: remoteRoot,
            currentLocalDir: baseLocalDir,
            fileSystem: fileSystem,
            results: &results,
            onProgress: onProgress
        )

        return results
    }

    private static func scanRemoteRecursive(
        currentRemote: RemotePath,
        currentLocalDir: URL,
        fileSystem: any RemoteFileSystem,
        results: inout [ScannedFile],
        onProgress: (@Sendable (_ scannedCount: Int, _ currentItemName: String) -> Void)? = nil
    ) async throws {
        try Task.checkCancellation()

        let listing = try await fileSystem.list(currentRemote)
        for item in listing.entries {
            try Task.checkCancellation()

            let name = item.path.lastComponent?.displayString() ?? "item"
            let localTarget = currentLocalDir.appendingPathComponent(name)

            switch item.kind {
            case .directory:
                onProgress?(results.count, name)
                try await scanRemoteRecursive(
                    currentRemote: item.path,
                    currentLocalDir: localTarget,
                    fileSystem: fileSystem,
                    results: &results,
                    onProgress: onProgress
                )
            case .file:
                results.append(ScannedFile(localURL: localTarget, remotePath: item.path, size: item.size))
                onProgress?(results.count, name)
            case .symbolicLink:
                // 若为软链且目标是文件，纳入下载；若是目录，递归扫描（防成环由 RemoteFileSystem 兜住）
                var mutableListing = listing
                if let res = try? await fileSystem.resolve(item, in: &mutableListing) {
                    if let target = res.resolved {
                        let targetItem = try? await fileSystem.stat(target)
                        if targetItem?.kind == RemoteItemKind.directory {
                            onProgress?(results.count, name)
                            try await scanRemoteRecursive(
                                currentRemote: target,
                                currentLocalDir: localTarget,
                                fileSystem: fileSystem,
                                results: &results,
                                onProgress: onProgress
                            )
                        } else if targetItem?.kind == RemoteItemKind.file {
                            results.append(ScannedFile(localURL: localTarget, remotePath: item.path, size: targetItem?.size))
                            onProgress?(results.count, name)
                        }
                    }
                }
            default:
                break
            }
        }
    }
}

private extension String {
    func deletingPrefix(_ prefix: String) -> String {
        guard self.hasPrefix(prefix) else { return self }
        return String(self.dropFirst(prefix.count))
    }
}
