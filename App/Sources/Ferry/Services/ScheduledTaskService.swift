import AppKit
import FerryBackendsFTP
import FerryBackendsSFTP
import FerryCore
import Foundation
import Observation
import UserNotifications

/// 定时计划任务后台执行调度器。
@Observable
@MainActor
public final class ScheduledTaskService {
    public static let shared = ScheduledTaskService()

    public private(set) var runningTaskIDs: Set<UUID> = []
    public private(set) var lastExecutionLog: [UUID: String] = [:]

    private var timerTask: Task<Void, Never>?

    private init() {
        startScheduler()
    }

    /// 启动 30 秒轮询调度循环
    public func startScheduler() {
        timerTask?.cancel()
        timerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self = self else { break }
                await self.checkAndExecuteDueTasks()
            }
        }
    }

    public func stopScheduler() {
        timerTask?.cancel()
        timerTask = nil
    }

    /// 检查并执行所有到期的定时任务
    public func checkAndExecuteDueTasks() async {
        let store = ScheduledTaskStore.shared
        let now = Date()

        for task in store.tasks where task.isEnabled {
            guard !runningTaskIDs.contains(task.id) else { continue }
            guard let next = task.nextRunTime, next <= now else { continue }

            await executeTask(task)
        }
    }

    /// 立即执行某个定时任务
    public func runTaskNow(_ task: ScheduledTask) async {
        guard !runningTaskIDs.contains(task.id) else { return }
        await executeTask(task)
    }

    private func executeTask(_ task: ScheduledTask) async {
        runningTaskIDs.insert(task.id)
        defer { runningTaskIDs.remove(task.id) }

        var updatedTask = task
        let startTime = Date()

        do {
            let filesCount = try await performSync(for: task)
            let elapsed = Int(Date().timeIntervalSince(startTime))
            let successMsg = L10n.format("已同步 %d 个文件 (耗时 %d 秒)", "Synced %d file(s) in %ds", filesCount, elapsed)

            updatedTask.lastRunTime = Date()
            updatedTask.lastRunStatus = successMsg
            updatedTask.nextRunTime = ScheduledTask.calculateNextRunTime(for: task.frequency, from: Date())
            lastExecutionLog[task.id] = successMsg

            await ScheduledTaskStore.shared.upsert(updatedTask)
            postNotification(title: task.name, message: successMsg)
        } catch {
            let errorMsg = L10n.format("执行失败：%@", "Execution failed: %@", error.localizedDescription)
            updatedTask.lastRunTime = Date()
            updatedTask.lastRunStatus = errorMsg
            updatedTask.nextRunTime = ScheduledTask.calculateNextRunTime(for: task.frequency, from: Date())
            lastExecutionLog[task.id] = errorMsg

            await ScheduledTaskStore.shared.upsert(updatedTask)
            postNotification(title: task.name, message: errorMsg)
        }
    }

    private func performSync(for task: ScheduledTask) async throws -> Int {
        let siteStore = SiteStore.shared

        // 1. 本地 -> 远端
        if task.sourceBookmarkID == nil, let destID = task.destinationBookmarkID {
            guard let destBookmark = siteStore.bookmarks.first(where: { $0.id == destID }) else {
                throw RemoteError.notFound(path: RemotePath(task.destinationPath))
            }
            let conn = try await connectToBookmark(destBookmark)
            defer { Task { await conn.close() } }

            let localURL = URL(fileURLWithPath: (task.sourcePath as NSString).expandingTildeInPath)
            let remoteTarget = RemotePath(string: task.destinationPath.isEmpty ? "/" : task.destinationPath, isAbsolute: true) ?? PathResolver.root

            let scanned = try DirectoryScanner.scanLocalDirectory(localURL, targetRemoteDir: remoteTarget)
            for file in scanned {
                try Task.checkCancellation()
                _ = try await TransferEngine.upload(
                    from: file.localURL,
                    to: file.remotePath,
                    using: conn,
                    fileSystem: conn,
                    usePartFile: true
                )
            }
            return scanned.count
        }

        // 2. 远端 -> 本地
        if let srcID = task.sourceBookmarkID, task.destinationBookmarkID == nil {
            guard let srcBookmark = siteStore.bookmarks.first(where: { $0.id == srcID }) else {
                throw RemoteError.notFound(path: RemotePath(task.sourcePath))
            }
            let conn = try await connectToBookmark(srcBookmark)
            defer { Task { await conn.close() } }

            let remoteSrc = RemotePath(string: task.sourcePath.isEmpty ? "/" : task.sourcePath, isAbsolute: true) ?? PathResolver.root
            let localDest = URL(fileURLWithPath: (task.destinationPath as NSString).expandingTildeInPath)

            let scanned = try await DirectoryScanner.scanRemoteDirectory(remoteSrc, fileSystem: conn, targetLocalDir: localDest)
            for file in scanned {
                try Task.checkCancellation()
                let parent = file.localURL.deletingLastPathComponent()
                try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                _ = try await TransferEngine.download(
                    file.remotePath,
                    to: file.localURL,
                    using: conn,
                    usePartFile: false
                )
            }
            return scanned.count
        }

        // 3. 远端 -> 远端 (使用 RelayEngine 流式中继直传！)
        if let srcID = task.sourceBookmarkID, let destID = task.destinationBookmarkID {
            guard let srcBookmark = siteStore.bookmarks.first(where: { $0.id == srcID }),
                  let destBookmark = siteStore.bookmarks.first(where: { $0.id == destID }) else {
                throw RemoteError.notFound(path: RemotePath(task.sourcePath))
            }
            let srcConn = try await connectToBookmark(srcBookmark)
            let destConn = try await connectToBookmark(destBookmark)
            defer {
                Task {
                    await srcConn.close()
                    await destConn.close()
                }
            }

            let remoteSrc = RemotePath(string: task.sourcePath.isEmpty ? "/" : task.sourcePath, isAbsolute: true) ?? PathResolver.root
            let remoteDst = RemotePath(string: task.destinationPath.isEmpty ? "/" : task.destinationPath, isAbsolute: true) ?? PathResolver.root

            let res = try await RelayEngine.relayDirectory(
                from: remoteSrc,
                using: srcConn,
                to: remoteDst,
                using: destConn
            )
            return res.filesCount
        }

        return 0
    }

    private func connectToBookmark(_ bookmark: SiteBookmark) async throws -> (any RemoteFileSystem & RemoteTransfer & RemoteConnection) {
        let endpoint = Endpoint(host: bookmark.host, port: bookmark.port, username: bookmark.username)
        let auth: AuthenticationMethod
        switch bookmark.authType {
        case .password:
            auth = .password(bookmark.password)
        case .privateKey:
            let keyUrl = URL(fileURLWithPath: (bookmark.privateKeyPath as NSString).expandingTildeInPath)
            let data = try Data(contentsOf: keyUrl)
            let pass = bookmark.passphrase.isEmpty ? nil : bookmark.passphrase
            auth = .privateKey(PrivateKeyMaterial(keyData: data, passphrase: pass))
        case .sshAgent:
            auth = .sshAgent
        case .anonymous:
            auth = .anonymous
        }

        let req = ConnectionRequest(endpoint: endpoint, authentication: auth, policy: .standard, charset: bookmark.charset)
        let backend: any RemoteBackend
        if bookmark.protocolType == .sftp {
            backend = SFTPBackend(hostKeyTrust: ConnectionService.shared.makeHostKeyStore())
        } else {
            backend = FTPBackend(isFTPS: bookmark.protocolType == .ftps)
        }

        let connection = backend.makeConnection(req) as! (any RemoteFileSystem & RemoteTransfer & RemoteConnection)
        _ = try await connection.handshake()
        _ = try await connection.authenticate(interactive: nil)
        return connection
    }

    private func postNotification(title: String, message: String) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = L10n.format("Ferry 定时任务：%@", "Ferry Scheduled Task: %@", title)
        content.body = message
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        center.add(request)
    }
}
