import CryptoKit
import Foundation

/// 同步引擎（v2.3 §384-434）。
///
/// 核心原则：
/// 1. stat 未变不读内容，可疑才比内容（R13，v2.3 §386）；
/// 2. 冲突绝不自动解决，写入 DiffPlan 供用户决断（R3，v2.3 §428）；
/// 3. notFound 与网络错误必须区分，网络错误一律放弃本次同步（v2.3 §430）；
/// 4. 以 (ComparisonKey, size) 为主键建索引，避免 O(n²) 比较（v2.3 §433）；
/// 5. 出口标准：双端同时修改同一文件被识别为冲突。
public struct SyncEngine: Sendable {
    public init() {}

    // MARK: - 计算差异计划（DiffPlan）

    /// 计算本地与远端目录的差异计划。
    public func computeDiffPlan(
        localRootURL: URL,
        remoteRootPath: RemotePath,
        fileSystem: any RemoteFileSystem,
        baseSnapshot: SyncBaseSnapshot?,
        options: SyncOptions = SyncOptions()
    ) async throws -> DiffPlan {
        try Task.checkCancellation()

        // 1. 递归扫描本地文件
        let localItems = try scanLocalFiles(localRootURL: localRootURL, options: options)
        try Task.checkCancellation()

        // 2. 递归扫描远端文件（网络错误必须向外抛出中断同步，v2.3 §430）
        let remoteItems = try await scanRemoteFiles(
            currentRemotePath: remoteRootPath,
            remoteRootPath: remoteRootPath,
            fileSystem: fileSystem,
            options: options
        )
        try Task.checkCancellation()

        // 3. 构建索引与碰撞检测（v2.3 §431, §433）
        var localByKey: [ComparisonKey: SyncItemSnapshot] = [:]
        var localCollisions: Set<ComparisonKey> = []
        for item in localItems {
            let key = ComparisonKey(string: item.relativePath, pathPolicy: options.pathPolicy)
            if localByKey[key] != nil {
                localCollisions.insert(key)
            } else {
                localByKey[key] = item
            }
        }

        var remoteByKey: [ComparisonKey: SyncItemSnapshot] = [:]
        var remoteCollisions: Set<ComparisonKey> = []
        for item in remoteItems {
            let key = ComparisonKey(string: item.relativePath, pathPolicy: options.pathPolicy)
            if remoteByKey[key] != nil {
                remoteCollisions.insert(key)
            } else {
                remoteByKey[key] = item
            }
        }

        let baseEntries = baseSnapshot?.entries ?? [:]

        // 获取所有涉及的 ComparisonKey 并集
        var allKeys = Set<ComparisonKey>()
        allKeys.formUnion(localByKey.keys)
        allKeys.formUnion(remoteByKey.keys)
        allKeys.formUnion(baseEntries.keys)

        var diffItems: [SyncDiffItem] = []

        for key in allKeys.sorted(by: { $0.bytes.lexicographicallyPrecedes($1.bytes) }) {
            try Task.checkCancellation()

            // 碰撞检测优先标为冲突
            if localCollisions.contains(key) || remoteCollisions.contains(key) {
                let relPath = localByKey[key]?.relativePath ?? remoteByKey[key]?.relativePath ?? baseEntries[key]?.relativePath ?? "collision"
                diffItems.append(SyncDiffItem(
                    relativePath: relPath,
                    comparisonKey: key,
                    localItem: localByKey[key],
                    remoteItem: remoteByKey[key],
                    baseEntry: baseEntries[key],
                    action: .conflict,
                    conflictReason: .keyCollision
                ))
                continue
            }

            let local = localByKey[key]
            let remote = remoteByKey[key]
            let base = baseEntries[key]
            let relPath = local?.relativePath ?? remote?.relativePath ?? base?.relativePath ?? ""

            // 类型冲突检测（一侧为文件，另一侧为目录，v2.3 §424）
            if let l = local, let r = remote, l.isDirectory != r.isDirectory {
                diffItems.append(SyncDiffItem(
                    relativePath: relPath,
                    comparisonKey: key,
                    localItem: l,
                    remoteItem: r,
                    baseEntry: base,
                    action: .conflict,
                    conflictReason: .kindMismatch
                ))
                continue
            }

            // 双方都是文件夹时，只需要同步其内容，文件夹本身无需直接上下传
            if local?.isDirectory == true || remote?.isDirectory == true {
                continue
            }

            // 依据真值表判定单项动作
            let item = evaluateTruthTable(
                relativePath: relPath,
                key: key,
                local: local,
                remote: remote,
                base: base,
                localRootURL: localRootURL,
                remoteRootPath: remoteRootPath,
                fileSystem: fileSystem,
                options: options
            )
            diffItems.append(item)
        }

        return DiffPlan(
            localRootURL: localRootURL,
            remoteRootPath: remoteRootPath,
            items: diffItems
        )
    }

    // MARK: - 真值表判定逻辑（v2.3 §411-424）

    private func evaluateTruthTable(
        relativePath: String,
        key: ComparisonKey,
        local: SyncItemSnapshot?,
        remote: SyncItemSnapshot?,
        base: SyncBaseEntry?,
        localRootURL: URL,
        remoteRootPath: RemotePath,
        fileSystem: any RemoteFileSystem,
        options: SyncOptions
    ) -> SyncDiffItem {
        // 判定本地状态
        enum SideState {
            case absent
            case unchanged
            case created
            case modified
            case deleted
        }

        let localState: SideState
        if let l = local {
            if let b = base {
                if l.size == b.localSize && isSameTime(l.modificationDate, b.localMTime) {
                    localState = .unchanged
                } else {
                    localState = .modified
                }
            } else {
                localState = .created
            }
        } else {
            localState = (base != nil) ? .deleted : .absent
        }

        // 判定远端状态
        let remoteState: SideState
        if let r = remote {
            if let b = base {
                if r.size == b.remoteSize && r.mtimeIsReliable && isSameTime(r.modificationDate, b.remoteMTime) {
                    remoteState = .unchanged
                } else {
                    remoteState = .modified
                }
            } else {
                remoteState = .created
            }
        } else {
            remoteState = (base != nil) ? .deleted : .absent
        }

        var action: SyncAction = .none
        var conflictReason: SyncConflictReason? = nil

        switch (localState, remoteState) {
        // 1. 未变 / 未变 -> 无操作
        case (.unchanged, .unchanged):
            action = .none

        // 2. 本地变 / 远端未变 -> 上行
        case (.modified, .unchanged), (.created, .absent):
            action = .upload

        // 3. 本地未变 / 远端变 -> 下行
        case (.unchanged, .modified), (.absent, .created):
            action = .download

        // 4. 两侧同时修改
        case (.modified, .modified):
            if local?.size == remote?.size && local?.size != nil {
                // 大小一致时，如果有内容哈希且一致，更新 base，不算冲突（§416）
                if let lHash = local?.contentHash, let rHash = remote?.contentHash, lHash == rHash {
                    action = .none
                } else if options.forceCompareHash {
                    // 若开启强制内容比较，尝试比对
                    let lURL = localRootURL.appendingPathComponent(relativePath)
                    let lHash = computeSHA256(forURL: lURL)
                    if let lHash, let bHash = base?.contentHash, lHash == bHash {
                        // 本地内容实际没变
                        action = .download
                    } else {
                        action = .conflict
                        conflictReason = .bothModifiedContentDifferent
                    }
                } else {
                    // 默认不自动下载远端文件，标为冲突（M5 出口标准）
                    action = .conflict
                    conflictReason = .bothModifiedContentDifferent
                }
            } else {
                action = .conflict
                conflictReason = .bothModifiedContentDifferent
            }

        // 5. 两侧同时新建（§422, §423）
        case (.created, .created):
            if local?.size == remote?.size && local?.size != nil {
                if let lHash = local?.contentHash, let rHash = remote?.contentHash, lHash == rHash {
                    action = .none
                } else {
                    action = .conflict
                    conflictReason = .bothCreatedContentDifferent
                }
            } else {
                action = .conflict
                conflictReason = .bothCreatedContentDifferent
            }

        // 6. 本地删除 / 远端未变（§418）
        case (.deleted, .unchanged):
            action = options.allowDeletions ? .deleteRemote : .none

        // 7. 本地未变 / 远端删除（§419）
        case (.unchanged, .deleted):
            action = options.allowDeletions ? .deleteLocal : .none

        // 8. 一侧删除 / 另一侧变 -> 冲突（§420, §421）
        case (.deleted, .modified), (.modified, .deleted):
            action = .conflict
            conflictReason = .deletedAndModified

        // 9. 两侧都删除
        case (.deleted, .deleted):
            action = .none

        default:
            action = .none
        }

        return SyncDiffItem(
            relativePath: relativePath,
            comparisonKey: key,
            localItem: local,
            remoteItem: remote,
            baseEntry: base,
            action: action,
            conflictReason: conflictReason
        )
    }

    // MARK: - 本地与远端递归扫描辅助

    private func scanLocalFiles(localRootURL: URL, options: SyncOptions) throws -> [SyncItemSnapshot] {
        var items: [SyncItemSnapshot] = []
        let fileManager = FileManager.default
        let rootPath = localRootURL.standardizedFileURL.path

        guard let enumerator = fileManager.enumerator(
            at: localRootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        for case let fileURL as URL in enumerator {
            try Task.checkCancellation()
            let stdURL = fileURL.standardizedFileURL
            let path = stdURL.path
            guard path.hasPrefix(rootPath) else { continue }
            var relPath = String(path.dropFirst(rootPath.count))
            while relPath.hasPrefix("/") { relPath.removeFirst() }
            if relPath.isEmpty { continue }

            let resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            let isDir = resourceValues.isDirectory ?? false
            let size = resourceValues.fileSize.map { Int64($0) }
            let mtime = resourceValues.contentModificationDate

            var hash: String? = nil
            if !isDir && options.forceCompareHash {
                hash = computeSHA256(forURL: fileURL)
            }

            items.append(SyncItemSnapshot(
                relativePath: relPath,
                isDirectory: isDir,
                size: size,
                modificationDate: mtime,
                mtimeIsReliable: true,
                contentHash: hash
            ))
        }

        return items
    }

    private func scanRemoteFiles(
        currentRemotePath: RemotePath,
        remoteRootPath: RemotePath,
        fileSystem: any RemoteFileSystem,
        options: SyncOptions
    ) async throws -> [SyncItemSnapshot] {
        var items: [SyncItemSnapshot] = []
        try Task.checkCancellation()

        let listing: RemoteDirectoryListing
        do {
            listing = try await fileSystem.list(currentRemotePath)
        } catch let error as RemoteError {
            if case .notFound = error, currentRemotePath == remoteRootPath {
                return []
            }
            throw error
        }

        let rootStr = remoteRootPath.displayString()

        for entry in listing.entries {
            try Task.checkCancellation()
            let fullStr = entry.path.displayString()
            guard fullStr.hasPrefix(rootStr) else { continue }
            var relPath = String(fullStr.dropFirst(rootStr.count))
            while relPath.hasPrefix("/") { relPath.removeFirst() }
            if relPath.isEmpty { continue }

            let isDir = entry.kind == .directory
            items.append(SyncItemSnapshot(
                relativePath: relPath,
                isDirectory: isDir,
                size: entry.size,
                modificationDate: entry.modificationDate,
                mtimeIsReliable: entry.mtimeIsReliable,
                contentHash: nil
            ))

            if isDir {
                let subItems = try await scanRemoteFiles(
                    currentRemotePath: entry.path,
                    remoteRootPath: remoteRootPath,
                    fileSystem: fileSystem,
                    options: options
                )
                items.append(contentsOf: subItems)
            }
        }

        return items
    }

    // MARK: - 工具方法

    private func isSameTime(_ d1: Date?, _ d2: Date?) -> Bool {
        guard let d1, let d2 else { return false }
        // SFTP 与部分服务器时间戳仅保留秒级精度（v2.3 §338, §393）
        return abs(d1.timeIntervalSince(d2)) < 1.0
    }

    public func computeSHA256(forURL url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try? handle.read(upToCount: 64 * 1024), !data.isEmpty {
            hasher.update(data: data)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
