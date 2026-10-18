import AppKit
import FerryCore
import Foundation
import UniformTypeIdentifiers

/// 拖拽类型标识符。
public enum FerryUTI {
    public static let remoteItemIdentifier = "com.ferry.remote-item"
    public static let localItemIdentifier = "com.ferry.local-item"
    public static let promisedFileIdentifier = "com.apple.pasteboard.promised-file-url"

    public static let remoteItemType = UTType(remoteItemIdentifier) ?? .data
    public static let localItemType = UTType(localItemIdentifier) ?? .data
}

/// 远端多选拖拽数据负载（Codable）。
public struct RemoteDragPayload: Codable, Sendable {
    public struct ItemPayload: Codable, Sendable {
        public let name: String
        public let wireBytes: [UInt8]
        public let isDirectory: Bool
        public let size: Int64?

        public init(name: String, wireBytes: [UInt8], isDirectory: Bool, size: Int64?) {
            self.name = name
            self.wireBytes = wireBytes
            self.isDirectory = isDirectory
            self.size = size
        }
    }

    public let items: [ItemPayload]

    public init(items: [ItemPayload]) {
        self.items = items
    }
}

/// 本地多选拖拽数据负载（Codable）。
public struct LocalDragPayload: Codable, Sendable {
    public let urls: [URL]

    public init(urls: [URL]) {
        self.urls = urls
    }
}

/// 拖拽矩阵核心调度服务（v2.3 §360-371 & ADR-0000）。
/// 支持：
/// 1. 远端 → Finder（NSFilePromiseProvider 延迟下载至临时目录交付访达）
/// 2. Finder → 远端面板（普通 fileURL 与 NSFilePromiseReceiver 异步接收并聚合上传）
/// 3. 本地 ⇋ 远端内部拖拽（支持单选与多选批量传输）
/// 4. 远端同服务器移动（拖动至子目录直接 rename 移动）
@MainActor
public final class FerryDragDropService {
    public static let shared = FerryDragDropService()

    private let dragTempDirectory: URL

    private init() {
        let baseTemp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = baseTemp.appendingPathComponent("Ferry/DragPromises", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.dragTempDirectory = dir
    }

    // MARK: - 远端项目拖出（远端 → 本地 / 远端 → Finder）

    /// 为远端项目创建 NSItemProvider。
    /// 支持同时提供内部 RemoteDragPayload、以及面向 Finder / 外界应用的 FileRepresentation 延迟 Promise 下载。
    public func createItemProvider(
        for remoteItem: RemoteDisplayItem,
        allSelectedItems: [RemoteDisplayItem] = []
    ) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = remoteItem.name

        // 计算当前拖拽应包含的项目：如果被拖动的行在多选范围内，则携带完整多选集合
        let itemsToDrag: [RemoteDisplayItem]
        if allSelectedItems.contains(where: { $0.id == remoteItem.id }) && allSelectedItems.count > 1 {
            itemsToDrag = allSelectedItems
        } else {
            itemsToDrag = [remoteItem]
        }

        // 1. 注册内部多选负载（供 Ferry 本地面板或子目录整理使用）
        provider.registerDataRepresentation(forTypeIdentifier: FerryUTI.remoteItemIdentifier, visibility: .all) { completion in
            let payloadItems = itemsToDrag.map {
                RemoteDragPayload.ItemPayload(
                    name: $0.name,
                    wireBytes: $0.path.wireBytes,
                    isDirectory: $0.isDirectory,
                    size: $0.size
                )
            }
            let payload = RemoteDragPayload(items: payloadItems)
            if let data = try? JSONEncoder().encode(payload) {
                completion(data, nil)
            } else {
                // 兜底：直接输出首个项目的 wireBytes
                completion(Data(remoteItem.path.wireBytes), nil)
            }
            return nil
        }

        // 2. 注册延迟下载文件表现形式（给 Finder 落下下载使用，v2.3 §367）
        let fileTypeIdentifier: String
        if remoteItem.isDirectory {
            fileTypeIdentifier = UTType.folder.identifier
        } else {
            let ext = URL(fileURLWithPath: remoteItem.name).pathExtension
            fileTypeIdentifier = UTType(filenameExtension: ext)?.identifier ?? UTType.item.identifier
        }

        let tempSubdir = dragTempDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)

        provider.registerFileRepresentation(
            forTypeIdentifier: fileTypeIdentifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            Task {
                guard let connection = await ConnectionService.shared.activeConnection else {
                    completion(nil, false, NSError(domain: "Ferry", code: -1, userInfo: [NSLocalizedDescriptionKey: "未连接到远程服务器"]))
                    return
                }

                try? FileManager.default.createDirectory(at: tempSubdir, withIntermediateDirectories: true)

                if remoteItem.isDirectory {
                    // 目录 Promise：递归下载到临时文件夹中交付 Finder
                    let targetFolder = tempSubdir.appendingPathComponent(remoteItem.name, isDirectory: true)
                    try? FileManager.default.createDirectory(at: targetFolder, withIntermediateDirectories: true)
                    do {
                        let scanned = try await DirectoryScanner.scanRemoteDirectory(
                            remoteItem.path,
                            fileSystem: connection,
                            targetLocalDir: targetFolder,
                            onProgress: nil
                        )
                        for file in scanned {
                            let parent = file.localURL.deletingLastPathComponent()
                            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                            _ = try await TransferEngine.download(
                                file.remotePath,
                                to: file.localURL,
                                using: connection,
                                usePartFile: false
                            )
                        }
                        completion(targetFolder, false, nil)
                    } catch {
                        completion(nil, false, error)
                    }
                } else {
                    // 单文件 Promise：下载到临时目录交付 Finder
                    let tempTarget = tempSubdir.appendingPathComponent(remoteItem.name)
                    do {
                        _ = try await TransferEngine.download(
                            remoteItem.path,
                            to: tempTarget,
                            using: connection,
                            usePartFile: false
                        )
                        completion(tempTarget, false, nil)
                    } catch {
                        completion(nil, false, error)
                    }
                }
            }
            return nil
        }

        return provider
    }

    // MARK: - 本地项目拖出（本地 → 远端 / 本地 → Finder）

    /// 为本地项目创建 NSItemProvider。
    public func createLocalItemProvider(
        for localItem: LocalItem,
        allSelectedItems: [LocalItem] = []
    ) -> NSItemProvider {
        let provider = NSItemProvider(object: localItem.url as NSURL)
        provider.suggestedName = localItem.name

        let itemsToDrag: [LocalItem]
        if allSelectedItems.contains(where: { $0.id == localItem.id }) && allSelectedItems.count > 1 {
            itemsToDrag = allSelectedItems
        } else {
            itemsToDrag = [localItem]
        }

        // 注册内部 local-item 载荷（包含所有选中 URL）
        provider.registerDataRepresentation(forTypeIdentifier: FerryUTI.localItemIdentifier, visibility: .all) { completion in
            let payload = LocalDragPayload(urls: itemsToDrag.map { $0.url })
            if let data = try? JSONEncoder().encode(payload) {
                completion(data, nil)
            } else {
                completion(nil, nil)
            }
            return nil
        }

        return provider
    }

    // MARK: - 落下解析（Finder → 远端 / Finder → 本地 / NSFilePromiseReceiver）

    /// 从一组 NSItemProvider 异步解包出所有本地文件 URL。
    /// 支持：
    /// - `NSFilePromiseReceiver`（Finder/外部应用异步承诺文件，v2.3 §366）
    /// - `UTType.fileURL`
    /// - `UTType.url`
    public func resolveIncomingFiles(from providers: [NSItemProvider]) async -> [URL] {
        var results: [URL] = []
        let tempDropDir = dragTempDirectory.appendingPathComponent("IncomingPromises/\(UUID().uuidString)", isDirectory: true)

        // 1. 检查拖拽剪贴板中是否存在 NSFilePromiseReceiver（Finder 承诺文件，v2.3 §366）
        let dragPasteboard = NSPasteboard(name: .drag)
        if let receivers = dragPasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver], !receivers.isEmpty {
            for receiver in receivers {
                let promised = await receivePromise(receiver: receiver, destinationDir: tempDropDir)
                results.append(contentsOf: promised)
            }
            if !results.isEmpty {
                return results
            }
        }

        // 2. 解包标准 fileURL 或通用 URL
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                let loadedURL: URL? = await withCheckedContinuation { continuation in
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                        if let u = item as? URL {
                            continuation.resume(returning: u)
                        } else if let data = item as? Data, let str = String(data: data, encoding: .utf8) {
                            continuation.resume(returning: URL(string: str))
                        } else {
                            continuation.resume(returning: nil)
                        }
                    }
                }
                if let u = loadedURL {
                    results.append(u)
                    continue
                }
            }

            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                let loadedURL: URL? = await withCheckedContinuation { continuation in
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        continuation.resume(returning: url)
                    }
                }
                if let u = loadedURL, u.isFileURL {
                    results.append(u)
                }
            }
        }

        return results
    }

    /// 接收并落地 NSFilePromiseReceiver。
    private func receivePromise(receiver: NSFilePromiseReceiver, destinationDir: URL) async -> [URL] {
        try? FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)

        let total = receiver.fileNames.count
        if total == 0 {
            return []
        }

        let opQueue = OperationQueue()
        opQueue.qualityOfService = .userInitiated

        return await withCheckedContinuation { continuation in
            var received: [URL] = []
            var remaining = total
            var didFinish = false
            let lock = NSLock()

            receiver.receivePromisedFiles(atDestination: destinationDir, options: [:], operationQueue: opQueue) { url, err in
                lock.lock()
                defer { lock.unlock() }
                if didFinish { return }

                if err == nil {
                    received.append(url)
                }
                remaining -= 1
                if remaining <= 0 {
                    didFinish = true
                    continuation.resume(returning: received)
                }
            }
        }
    }


    // MARK: - 载荷解码

    /// 从内部 remote-item 数据解码出 RemoteDisplayItem 列表。
    public func decodeRemoteItems(from data: Data) -> [RemoteDisplayItem] {
        if let payload = try? JSONDecoder().decode(RemoteDragPayload.self, from: data) {
            let converter = CharsetConverter(charset: ConnectionService.shared.currentCharset)
            return payload.items.compactMap { item in
                let path = RemotePath(wireBytes: item.wireBytes, isAbsolute: true)
                if let existing = ConnectionService.shared.remoteItems.first(where: { $0.path == path }) {
                    return existing
                }
                let kind: RemoteItemKind = item.isDirectory ? .directory : .file
                let rItem = RemoteItem(
                    path: path,
                    kind: kind,
                    size: item.size,
                    modificationDate: nil,
                    sizeIsExact: true,
                    mtimeIsReliable: false,
                    linkTarget: nil,
                    permissions: nil
                )
                return RemoteDisplayItem(item: rItem, charsetConverter: converter)
            }
        }
        // 兼容单项原始 wireBytes
        let bytes = Array(data)
        if !bytes.isEmpty {
            let path = RemotePath(wireBytes: bytes, isAbsolute: true)
            if let existing = ConnectionService.shared.remoteItems.first(where: { $0.path == path }) {
                return [existing]
            }
            let converter = CharsetConverter(charset: ConnectionService.shared.currentCharset)
            let rItem = RemoteItem(
                path: path,
                kind: .file,
                size: nil,
                modificationDate: nil,
                sizeIsExact: false,
                mtimeIsReliable: false,
                linkTarget: nil,
                permissions: nil
            )
            return [RemoteDisplayItem(item: rItem, charsetConverter: converter)]
        }
        return []
    }

    /// 从内部 remote-item 数据解码出所有 RemotePath。
    public func decodeRemotePaths(from data: Data) -> [RemotePath] {
        if let payload = try? JSONDecoder().decode(RemoteDragPayload.self, from: data) {
            return payload.items.map { RemotePath(wireBytes: $0.wireBytes, isAbsolute: true) }
        }
        // 兼容单项原始 wireBytes
        let bytes = Array(data)
        if !bytes.isEmpty {
            return [RemotePath(wireBytes: bytes, isAbsolute: true)]
        }
        return []
    }

    /// 从内部 local-item 数据解码出所有 URL。
    public func decodeLocalURLs(from data: Data) -> [URL] {
        if let payload = try? JSONDecoder().decode(LocalDragPayload.self, from: data) {
            return payload.urls
        }
        return []
    }

    // MARK: - 远端同服务器移动（远端 → 远端子目录归类，v2.3 §368）

    /// 执行远端同服务器批量移动。
    public func moveRemoteItems(
        _ sourcePaths: [RemotePath],
        toDestinationDirectory destDir: RemotePath
    ) async -> Int {
        guard let connection = ConnectionService.shared.activeConnection else { return 0 }
        var successCount = 0

        for sourcePath in sourcePaths {
            guard let fileNameBytes = sourcePath.wireBytes.split(separator: 0x2F).last else { continue }
            if sourcePath == destDir { continue }

            do {
                let targetPath = try PathResolver.child(of: destDir, name: Array(fileNameBytes))
                if sourcePath == targetPath { continue }
                try await connection.rename(sourcePath, to: targetPath, overwrite: false)
                successCount += 1
            } catch {
                // 忽略单个移动错误，继续执行其他项
            }
        }

        if successCount > 0 {
            await ConnectionService.shared.refreshRemote()
        }
        return successCount
    }
}
