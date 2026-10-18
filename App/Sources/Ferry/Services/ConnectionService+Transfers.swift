import FerryCore
import Foundation

// MARK: - 文件上传/下载预检、冲突检测与队列派发扩展（v2.3 §340-360 & M3/M4）
extension ConnectionService {

    // MARK: - M4: 冲突处理响应方法
    public func resolveConflict(decision: ConflictDecision, applyToAll: Bool) {
        let continuation = conflictContinuation
        conflictContinuation = nil
        pendingConflictContext = nil
        continuation?.resume(returning: (decision, applyToAll))
    }

    public func cancelConflict() {
        let continuation = conflictContinuation
        conflictContinuation = nil
        pendingConflictContext = nil
        continuation?.resume(returning: nil)
    }

    func promptConflict(item: FileConflictItem, total: Int, remaining: Int) async -> (ConflictDecision, Bool)? {
        self.pendingConflictContext = PendingConflictContext(item: item, totalCount: total, remainingCount: remaining)
        return await withCheckedContinuation { continuation in
            self.conflictContinuation = continuation
        }
    }

    // MARK: - M3/M4: 传输队列与任务派发（含冲突策略拦截）

    public func uploadFiles(
        _ localURLs: [URL],
        toRemoteDirectory targetDir: RemotePath? = nil,
        onComplete: (@MainActor () -> Void)? = nil
    ) {
        guard let remoteDir = targetDir ?? currentRemotePath else { return }
        guard !localURLs.isEmpty else { return }
        guard transferPreparation == nil else { return }

        let hasDir = localURLs.contains(where: {
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDir) && isDir.boolValue
        })
        let initialMsg = hasDir ? "正在扫描本地文件夹并准备上传..." : "正在准备上传..."

        self.transferPreparation = TransferPreparationState(
            direction: .upload,
            totalItems: localURLs.count,
            scannedFilesCount: 0,
            statusMessage: initialMsg
        )
        self.isQueuePanelPresented = true

        Task { [self] in
            defer {
                self.transferPreparation = nil
            }
            var scannedFiles: [DirectoryScanner.ScannedFile] = []
            for (idx, url) in localURLs.enumerated() {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
                if isDir.boolValue {
                    self.transferPreparation?.statusMessage = "正在扫描本地目录：\(url.lastPathComponent) (\(idx + 1)/\(localURLs.count))..."
                    if let scanned = try? DirectoryScanner.scanLocalDirectory(
                        url,
                        targetRemoteDir: remoteDir,
                        onProgress: { [weak self] count, name in
                            Task { @MainActor [weak self] in
                                self?.transferPreparation?.scannedFilesCount = count
                                self?.transferPreparation?.currentScanningName = name
                                self?.transferPreparation?.statusMessage = "已发现 \(count) 个文件（正在扫描：\(name)）..."
                            }
                        }
                    ) {
                        scannedFiles.append(contentsOf: scanned)
                    }
                } else {
                    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                    let size = attrs?[.size] as? Int64
                    let targetName = url.lastPathComponent
                    if let targetRemote = try? PathResolver.child(of: remoteDir, name: Array(targetName.utf8)) {
                        scannedFiles.append(DirectoryScanner.ScannedFile(localURL: url, remotePath: targetRemote, size: size))
                        self.transferPreparation?.scannedFilesCount = scannedFiles.count
                    }
                }
            }

            guard !scannedFiles.isEmpty else { return }

            self.transferPreparation?.statusMessage = "正在检查文件冲突（共 \(scannedFiles.count) 个文件）..."

            // 冲突探测（上传：检查目标 remotePath 在当前 remoteItems 中是否已存在）
            var finalUploadBatch: [DirectoryScanner.ScannedFile] = []
            var existingRemoteNames = Set(self.remoteItems.map { $0.name })
            var conflictPairs: [(scanned: DirectoryScanner.ScannedFile, conflict: FileConflictItem)] = []

            for file in scannedFiles {
                let fileName = file.localURL.lastPathComponent
                if let existing = self.remoteItems.first(where: { $0.name == fileName }) {
                    let localAttrs = try? FileManager.default.attributesOfItem(atPath: file.localURL.path)
                    let localDate = localAttrs?[.modificationDate] as? Date
                    let localSize = (localAttrs?[.size] as? Int64) ?? file.size

                    let suggested = ConflictResolver.suggestRename(for: fileName, existingNames: existingRemoteNames)
                    let conflictItem = FileConflictItem(
                        fileName: fileName,
                        direction: .upload,
                        sourcePath: file.localURL.path,
                        sourceSize: localSize,
                        sourceDate: localDate,
                        destinationPath: file.remotePath.description,
                        destinationSize: existing.size,
                        destinationDate: existing.modificationDate,
                        suggestedRename: suggested
                    )
                    conflictPairs.append((file, conflictItem))
                } else {
                    finalUploadBatch.append(file)
                }
            }

            if !conflictPairs.isEmpty {
                var batchDecision: ConflictDecision? = nil
                let totalConflicts = conflictPairs.count

                for (index, pair) in conflictPairs.enumerated() {
                    let decision: ConflictDecision
                    if let bd = batchDecision {
                        decision = bd
                    } else {
                        let remaining = totalConflicts - index - 1
                        guard let (chosenDecision, applyToAll) = await self.promptConflict(
                            item: pair.conflict,
                            total: totalConflicts,
                            remaining: remaining
                        ) else {
                            // 用户取消了传输
                            return
                        }
                        decision = chosenDecision
                        if applyToAll {
                            batchDecision = chosenDecision
                        }
                    }

                    let outcome = ConflictResolver.resolve(item: pair.conflict, decision: decision)
                    switch outcome {
                    case .proceedOriginal:
                        finalUploadBatch.append(pair.scanned)
                    case .proceedRenamed(let newName):
                        existingRemoteNames.insert(newName)
                        if let parent = try? PathResolver.parent(of: pair.scanned.remotePath),
                           let renamedRemote = try? PathResolver.child(of: parent, name: Array(newName.utf8)) {
                            finalUploadBatch.append(DirectoryScanner.ScannedFile(
                                localURL: pair.scanned.localURL,
                                remotePath: renamedRemote,
                                size: pair.scanned.size
                            ))
                        } else {
                            finalUploadBatch.append(pair.scanned)
                        }
                    case .skipped:
                        break
                    }
                }
            }

            if !finalUploadBatch.isEmpty {
                self.isQueuePanelPresented = true
                await transferQueue.addScannedBatch(finalUploadBatch, direction: .upload)
            }
            onComplete?()
        }
    }

    public func downloadItems(_ items: [RemoteDisplayItem], to localDirectory: URL, onComplete: (@MainActor () -> Void)? = nil) {
        guard let connection = activeConnection else { return }
        guard !items.isEmpty else { return }
        guard transferPreparation == nil else { return }

        let hasDir = items.contains(where: { $0.isDirectory })
        let initialMsg = hasDir ? "正在扫描远程文件夹并准备下载..." : "正在准备下载..."

        self.transferPreparation = TransferPreparationState(
            direction: .download,
            totalItems: items.count,
            scannedFilesCount: 0,
            statusMessage: initialMsg
        )
        self.isQueuePanelPresented = true

        Task { [self] in
            defer {
                self.transferPreparation = nil
            }
            var scannedFiles: [DirectoryScanner.ScannedFile] = []
            for (idx, item) in items.enumerated() {
                if item.isDirectory {
                    self.transferPreparation?.statusMessage = "正在扫描远程目录：\(item.name) (\(idx + 1)/\(items.count))..."
                    let destFolder = localDirectory.appendingPathComponent(item.name)
                    if let scanned = try? await DirectoryScanner.scanRemoteDirectory(
                        item.path,
                        fileSystem: connection,
                        targetLocalDir: destFolder,
                        onProgress: { [weak self] count, name in
                            Task { @MainActor [weak self] in
                                self?.transferPreparation?.scannedFilesCount = count
                                self?.transferPreparation?.currentScanningName = name
                                self?.transferPreparation?.statusMessage = "已发现 \(count) 个文件（正在扫描：\(name)）..."
                            }
                        }
                    ) {
                        scannedFiles.append(contentsOf: scanned)
                    }
                } else {
                    let destination = localDirectory.appendingPathComponent(item.name)
                    scannedFiles.append(DirectoryScanner.ScannedFile(localURL: destination, remotePath: item.path, size: item.size))
                    self.transferPreparation?.scannedFilesCount = scannedFiles.count
                }
            }

            guard !scannedFiles.isEmpty else { return }

            self.transferPreparation?.statusMessage = "正在检查文件冲突（共 \(scannedFiles.count) 个文件）..."

            // 冲突探测（下载：检查目标 localURL 在本地磁盘中是否已存在）
            var finalDownloadBatch: [DirectoryScanner.ScannedFile] = []
            var conflictPairs: [(scanned: DirectoryScanner.ScannedFile, conflict: FileConflictItem)] = []

            let localExistingNames = (try? FileManager.default.contentsOfDirectory(atPath: localDirectory.path)) ?? []
            var localExistingSet = Set(localExistingNames)

            for file in scannedFiles {
                let localPath = file.localURL.path
                if FileManager.default.fileExists(atPath: localPath) {
                    let localAttrs = try? FileManager.default.attributesOfItem(atPath: localPath)
                    let localSize = localAttrs?[.size] as? Int64
                    let localDate = localAttrs?[.modificationDate] as? Date

                    let remoteItem = items.first(where: { $0.path == file.remotePath })
                    let remoteDate = remoteItem?.modificationDate

                    let suggested = ConflictResolver.suggestRename(for: file.localURL.lastPathComponent, existingNames: localExistingSet)
                    let conflictItem = FileConflictItem(
                        fileName: file.localURL.lastPathComponent,
                        direction: .download,
                        sourcePath: file.remotePath.description,
                        sourceSize: file.size,
                        sourceDate: remoteDate,
                        destinationPath: localPath,
                        destinationSize: localSize,
                        destinationDate: localDate,
                        suggestedRename: suggested
                    )
                    conflictPairs.append((file, conflictItem))
                } else {
                    finalDownloadBatch.append(file)
                }
            }

            if !conflictPairs.isEmpty {
                var batchDecision: ConflictDecision? = nil
                let totalConflicts = conflictPairs.count

                for (index, pair) in conflictPairs.enumerated() {
                    let decision: ConflictDecision
                    if let bd = batchDecision {
                        decision = bd
                    } else {
                        let remaining = totalConflicts - index - 1
                        guard let (chosenDecision, applyToAll) = await self.promptConflict(
                            item: pair.conflict,
                            total: totalConflicts,
                            remaining: remaining
                        ) else {
                            // 用户取消了传输
                            return
                        }
                        decision = chosenDecision
                        if applyToAll {
                            batchDecision = chosenDecision
                        }
                    }

                    let outcome = ConflictResolver.resolve(item: pair.conflict, decision: decision)
                    switch outcome {
                    case .proceedOriginal:
                        finalDownloadBatch.append(pair.scanned)
                    case .proceedRenamed(let newName):
                        localExistingSet.insert(newName)
                        let parent = pair.scanned.localURL.deletingLastPathComponent()
                        let newURL = parent.appendingPathComponent(newName)
                        finalDownloadBatch.append(DirectoryScanner.ScannedFile(
                            localURL: newURL,
                            remotePath: pair.scanned.remotePath,
                            size: pair.scanned.size
                        ))
                    case .skipped:
                        break
                    }
                }
            }

            if !finalDownloadBatch.isEmpty {
                self.isQueuePanelPresented = true
                await transferQueue.addScannedBatch(finalDownloadBatch, direction: .download)
            }
            onComplete?()
        }
    }

    public func pauseQueueTask(id: UUID) {
        Task { await transferQueue.pauseTask(id: id) }
    }

    public func resumeQueueTask(id: UUID) {
        Task { await transferQueue.resumeTask(id: id) }
    }

    public func cancelQueueTask(id: UUID) {
        Task { await transferQueue.cancelTask(id: id) }
    }

    public func retryQueueTask(id: UUID) {
        Task { await transferQueue.retryTask(id: id) }
    }

    public func pauseAllQueueTasks() {
        Task { await transferQueue.pauseAll() }
    }

    public func resumeAllQueueTasks() {
        Task { await transferQueue.resumeAll() }
    }

    public func clearCompletedQueueTasks() {
        Task { await transferQueue.clearCompleted() }
    }

    public func cancelActiveTransfer() {
        Task { await transferQueue.pauseAll() }
    }

    public func cancelAllQueueTasks() {
        Task { await transferQueue.cancelAll() }
    }
}
