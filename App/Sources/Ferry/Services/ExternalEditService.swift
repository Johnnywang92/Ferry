import AppKit
import FerryCore
import Foundation
import SwiftUI

/// 外部编辑会话状态。
public enum ExternalEditStatus: Sendable, Equatable {
    case monitoring
    case hasChanges
    case uploading
    case uploaded
    case conflict(remoteDate: Date)
    case error(String)

    public var displayText: String {
        switch self {
        case .monitoring: return "正在监视编辑器保存…"
        case .hasChanges: return "检测到本地修改，待回传"
        case .uploading: return "正在回传到远端…"
        case .uploaded: return "已成功回传并同步"
        case .conflict(let d):
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss"
            return "冲突：远端已于 \(f.string(from: d)) 变更"
        case .error(let msg): return "回传失败：\(msg)"
        }
    }
}

/// 外部编辑会话模型（v2.3 §378-383）。
@Observable
@MainActor
public final class ExternalEditSession: Identifiable {
    public let id = UUID()
    public let remoteItem: RemoteDisplayItem
    public let localFileURL: URL
    public let parentDirectoryURL: URL
    public let initialRemoteMtime: Date?

    public var status: ExternalEditStatus = .monitoring
    public var isAutoUploadEnabled: Bool = false
    public var hasPendingChanges: Bool = false
    public var lastModifiedDate: Date?

    private var dispatchSource: (any DispatchSourceFileSystemObject)?
    private var fileDescriptor: Int32 = -1
    private var debounceTask: Task<Void, Never>?

    public init(
        remoteItem: RemoteDisplayItem,
        localFileURL: URL,
        parentDirectoryURL: URL,
        initialRemoteMtime: Date?
    ) {
        self.remoteItem = remoteItem
        self.localFileURL = localFileURL
        self.parentDirectoryURL = parentDirectoryURL
        self.initialRemoteMtime = initialRemoteMtime
    }

    /// 开启对父目录的文件系统事件监听（防漏掉编辑器的写临时文件再 rename 覆盖行为，v2.3 §379）。
    public func startMonitoring(onChangeDetected: @escaping @MainActor () -> Void) {
        let path = parentDirectoryURL.path
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        self.fileDescriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .attrib],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            self?.handleFileSystemEvent(onChangeDetected: onChangeDetected)
        }

        source.setCancelHandler {
            close(fd)
        }

        self.dispatchSource = source
        source.resume()
    }

    private func handleFileSystemEvent(onChangeDetected: @escaping @MainActor () -> Void) {
        // 500~1000ms 防抖，防一次保存触发多次事件或上传半写完的文件（v2.3 §380）
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled else { return }
            guard let self = self else { return }

            if let attrs = try? FileManager.default.attributesOfItem(atPath: self.localFileURL.path),
               let modDate = attrs[.modificationDate] as? Date {
                if self.lastModifiedDate == nil || modDate > self.lastModifiedDate! {
                    self.lastModifiedDate = modDate
                    self.hasPendingChanges = true
                    self.status = .hasChanges
                    onChangeDetected()
                }
            }
        }
    }

    public func stopMonitoring() {
        debounceTask?.cancel()
        debounceTask = nil
        if let source = dispatchSource {
            source.cancel()
            dispatchSource = nil
        }
    }
}

/// 外部编辑回传服务调度中心。
@Observable
@MainActor
public final class ExternalEditService {
    public static let shared = ExternalEditService()

    public var activeSessions: [ExternalEditSession] = []
    public var currentSession: ExternalEditSession? {
        activeSessions.first
    }

    // 冲突告警挂起点
    public var conflictPromptSession: ExternalEditSession?
    public var conflictRemoteDate: Date?

    private let rootTempDirectory: URL

    private init() {
        let baseTemp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let editDir = baseTemp.appendingPathComponent("Ferry/ExternalEdits", isDirectory: true)
        try? FileManager.default.createDirectory(at: editDir, withIntermediateDirectories: true)
        self.rootTempDirectory = editDir
    }

    /// 打开远端文件进入外部编辑（拉取 -> 存临时子目录 -> 系统 open -> FSEvents 监听）。
    public func openForEditing(
        remoteItem: RemoteDisplayItem,
        connection: (any RemoteTransfer)?
    ) async throws {
        guard !remoteItem.isDirectory else { return }
        guard let transfer = connection else { return }

        // 为每个文件建隔离工作区目录
        let sessionFolder = rootTempDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionFolder, withIntermediateDirectories: true)
        let localTarget = sessionFolder.appendingPathComponent(remoteItem.name)

        // 拉取远端文件
        _ = try await TransferEngine.download(
            remoteItem.path,
            to: localTarget,
            using: transfer,
            usePartFile: false
        )

        let session = ExternalEditSession(
            remoteItem: remoteItem,
            localFileURL: localTarget,
            parentDirectoryURL: sessionFolder,
            initialRemoteMtime: remoteItem.mtime
        )

        // 启动 FSEvents 父目录监听
        session.startMonitoring { [weak self, weak session] in
            guard let self = self, let s = session else { return }
            if s.isAutoUploadEnabled {
                Task {
                    await self.uploadChanges(for: s)
                }
            }
        }

        activeSessions.insert(session, at: 0)

        // 使用系统默认关联程序打开（v2.3 §378）
        NSWorkspace.shared.open(localTarget)
    }

    /// 触发安全上传（上传前比对远端 mtime，已变更则停下询问，不静默覆盖，v2.3 §382）。
    public func uploadChanges(for session: ExternalEditSession, forceOverwrite: Bool = false) async {
        guard let connection = ConnectionService.shared.activeConnection else {
            session.status = .error("未连接到远程服务器")
            return
        }

        session.status = .uploading

        // 比对远端 mtime
        if !forceOverwrite {
            if let stat = try? await connection.stat(session.remoteItem.path),
               let remoteDate = stat.modificationDate,
               let initDate = session.initialRemoteMtime,
               remoteDate > initDate {
                session.status = .conflict(remoteDate: remoteDate)
                self.conflictRemoteDate = remoteDate
                self.conflictPromptSession = session
                return
            }
        }

        do {
            _ = try await TransferEngine.upload(
                from: session.localFileURL,
                to: session.remoteItem.path,
                using: connection,
                usePartFile: true
            )
            session.hasPendingChanges = false
            session.status = .uploaded
            // 刷新远端目录列表
            await ConnectionService.shared.refreshRemote()
        } catch {
            session.status = .error(error.localizedDescription)
        }
    }

    /// 关闭编辑会话并清理临时工作区。
    public func closeSession(_ session: ExternalEditSession) {
        session.stopMonitoring()
        try? FileManager.default.removeItem(at: session.parentDirectoryURL)
        activeSessions.removeAll { $0.id == session.id }
        if conflictPromptSession?.id == session.id {
            conflictPromptSession = nil
            conflictRemoteDate = nil
        }
    }

    /// 清理所有编辑会话。
    public func closeAllSessions() {
        for s in activeSessions {
            s.stopMonitoring()
            try? FileManager.default.removeItem(at: s.parentDirectoryURL)
        }
        activeSessions.removeAll()
        conflictPromptSession = nil
        conflictRemoteDate = nil
    }
}
