import AppKit
import FerryCore
import Foundation
import UniformTypeIdentifiers

/// 拖拽类型标识符。
public enum FerryUTI {
    public static let remoteItemIdentifier = "com.ferry.remote-item"
    public static let localItemIdentifier = "com.ferry.local-item"

    public static let remoteItemType = UTType(exportedAs: remoteItemIdentifier)
}


/// 拖拽矩阵核心调度服务（v2.3 §360-371）。
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

    /// 为远端项创建 NSItemProvider（同时支持内部拖拽与 Finder 落下下载，v2.3 §367）。
    public func createItemProvider(for remoteItem: RemoteDisplayItem) -> NSItemProvider {
        let provider = NSItemProvider()

        // 1. 注册内部 RemotePath 标识（给 Ferry 本地面板或子目录移动识别）
        provider.registerDataRepresentation(forTypeIdentifier: FerryUTI.remoteItemIdentifier, visibility: .all) { completion in
            let data = Data(remoteItem.path.wireBytes)
            completion(data, nil)
            return nil
        }

        // 2. 如果是文件，注册异步 FileRepresentation 给 Finder 落下下载（v2.3 §367）
        if !remoteItem.isDirectory {
            let fileType = UTType(filenameExtension: URL(fileURLWithPath: remoteItem.name).pathExtension) ?? .item
            let tempTarget = dragTempDirectory.appendingPathComponent(remoteItem.name)

            provider.registerFileRepresentation(
                forTypeIdentifier: fileType.identifier,
                fileOptions: [],
                visibility: .all
            ) { completion in
                Task {
                    guard let connection = await ConnectionService.shared.activeConnection else {
                        completion(nil, false, NSError(domain: "Ferry", code: -1, userInfo: [NSLocalizedDescriptionKey: "未连接到远程服务器"]))
                        return
                    }
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
                return nil
            }
        }

        return provider
    }

    /// 执行远端同服务器移动（远端 → 远端子目录归类，v2.3 §368）。
    public func moveRemoteItem(
        _ sourcePath: RemotePath,
        toDestinationDirectory destDir: RemotePath
    ) async -> Bool {
        guard let connection = ConnectionService.shared.activeConnection else { return false }
        guard let fileNameBytes = sourcePath.wireBytes.split(separator: 0x2F).last else { return false }

        // 禁止自身移动到自身
        if sourcePath == destDir { return false }

        do {
            let targetPath = try PathResolver.child(of: destDir, name: Array(fileNameBytes))
            if sourcePath == targetPath { return false }
            try await connection.rename(sourcePath, to: targetPath, overwrite: false)
            await ConnectionService.shared.refreshRemote()
            return true
        } catch {
            return false
        }
    }
}

