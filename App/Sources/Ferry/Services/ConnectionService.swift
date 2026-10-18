import FerryBackendsFTP
import FerryBackendsSFTP
import FerryCore
import Foundation
import SwiftUI

public enum ActiveConnectionState: Sendable, Hashable {
    case disconnected
    case connecting(step: String)
    case connected(siteName: String, protocolStr: String, rttMs: Int64)
    case failed(message: String)
}

public struct HostKeyMismatchAlert: Identifiable, Sendable {
    public let id = UUID()
    public let endpoint: Endpoint
    public let newFingerprint: String
    public let bookmark: SiteBookmark
}

public struct ActiveTransferInfo: Sendable, Equatable {
    public enum Direction: String, Sendable {
        case upload = "上传"
        case download = "下载"
    }

    public let direction: Direction
    public let fileName: String
    public let bytesDone: Int64
    public let totalBytes: Int64?
    public let speedBytesPerSec: Double
    public let isCompleted: Bool
    public let errorMessage: String?

    public var formattedSpeed: String {
        guard speedBytesPerSec > 0 else { return "0 KB/s" }
        let formatted = ByteCountFormatter.string(fromByteCount: Int64(speedBytesPerSec), countStyle: .file)
        return "\(formatted)/s"
    }

    public var progressFraction: Double {
        guard let total = totalBytes, total > 0 else { return isCompleted ? 1.0 : 0.0 }
        return min(max(Double(bytesDone) / Double(total), 0.0), 1.0)
    }
}

@Observable
@MainActor
public final class ConnectionService: HostKeyTrustPrompt, KeyboardInteractiveResponder {
    public static let shared = ConnectionService()

    public var state: ActiveConnectionState = .disconnected
    public var activeConnection: (any RemoteFileSystem & RemoteConnection)?
    public var currentBookmark: SiteBookmark?
    public var currentRemotePath: RemotePath?
    public var currentCharset: CharsetConverter.Charset = .utf8
    public var remoteItems: [RemoteDisplayItem] = []
    public var remoteListingStaleCount: Int = 0
    public var navigationErrorMessage: String?

    // 传输状态与取消控制
    public var activeTransfer: ActiveTransferInfo?
    private var transferTask: Task<Void, Never>?

    // 传输准备中状态（目录扫描与冲突检测中，给用户即时反馈防误重触）
    public struct TransferPreparationState: Equatable, Sendable {
        public enum Direction: String, Sendable {
            case upload = "上传"
            case download = "下载"
        }
        public let direction: Direction
        public let totalItems: Int
        public var scannedFilesCount: Int
        public var currentScanningName: String?
        public var statusMessage: String

        public init(
            direction: Direction,
            totalItems: Int,
            scannedFilesCount: Int = 0,
            currentScanningName: String? = nil,
            statusMessage: String
        ) {
            self.direction = direction
            self.totalItems = totalItems
            self.scannedFilesCount = scannedFilesCount
            self.currentScanningName = currentScanningName
            self.statusMessage = statusMessage
        }
    }
    public var transferPreparation: TransferPreparationState?

    // App Nap 防节流令牌（v2.3 §312）
    private var appNapActivity: NSObjectProtocol?

    // 缓存当前目录原始条目，供切换字符集时即时重解码（R5）
    private var cachedListing: RemoteDirectoryListing?
    private var cachedResolutions: [RemotePath: RemoteDirectoryListing.LinkResolution] = [:]

    // MARK: - TOFU、密钥变更硬阻断与键盘交互弹窗挂起点
    public var pendingHostKeyQuestion: HostKeyQuestion?
    private var hostKeyContinuation: CheckedContinuation<HostKeyDecision, Never>?

    public var pendingHostKeyMismatch: HostKeyMismatchAlert?

    public var pendingKeyboardRequest: KeyboardInteractiveRequest?
    private var keyboardContinuation: CheckedContinuation<[String]?, Never>?

    // MARK: - M4: 文件冲突弹窗挂起点
    public struct PendingConflictContext: Identifiable, Sendable {
        public let id = UUID()
        public let item: FileConflictItem
        public let totalCount: Int
        public let remainingCount: Int
    }
    public var pendingConflictContext: PendingConflictContext?
    private var conflictContinuation: CheckedContinuation<(ConflictDecision, Bool)?, Never>?


    // MARK: - M3: 传输队列调度器（TransferQueue）
    public let transferQueue: TransferQueue
    public var queueTasks: [TransferTaskState] = []
    public var queueSummary: (running: Int, failed: Int, pending: Int) = (0, 0, 0)
    public var aggregateSpeed: (upload: Double, download: Double) = (0, 0)
    public var isQueuePanelPresented: Bool = false

    public static var ferryTransferQueueURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let ferryDir = appSupport.appendingPathComponent("Ferry", isDirectory: true)
        try? FileManager.default.createDirectory(at: ferryDir, withIntermediateDirectories: true)
        return ferryDir.appendingPathComponent("transfer_queue.json")
    }

    public init() {
        let q = TransferQueue(persistenceURL: Self.ferryTransferQueueURL)
        self.transferQueue = q
        Task { [weak self] in
            await q.initializeAndRecover()
            await q.addStateListener { [weak self] states in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    self.queueTasks = states
                    var r = 0, f = 0, p = 0
                    var up = 0.0, down = 0.0
                    for s in states {
                        switch s.status {
                        case .running:
                            r += 1
                            if s.direction == .upload { up += s.speedBytesPerSec }
                            else { down += s.speedBytesPerSec }
                        case .failed:
                            f += 1
                        case .pending:
                            p += 1
                        default:
                            break
                        }
                    }
                    self.queueSummary = (r, f, p)
                    self.aggregateSpeed = (up, down)
                }
            }
        }
    }

    // MARK: - 主机密钥存储路径
    public static var ferryKnownHostsURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let ferryDir = appSupport.appendingPathComponent("Ferry", isDirectory: true)
        try? FileManager.default.createDirectory(at: ferryDir, withIntermediateDirectories: true)
        return ferryDir.appendingPathComponent("known_hosts")
    }

    public func makeHostKeyStore() -> HostKeyStore {
        let config = HostKeyStoreConfig.standard(storeURL: Self.ferryKnownHostsURL)
        return HostKeyStore(config: config, prompt: self)
    }

    // MARK: - 主机密钥信任询问回调（HostKeyTrustPrompt）
    public nonisolated func ask(_ question: HostKeyQuestion) async -> HostKeyDecision {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                self.hostKeyContinuation = continuation
                self.pendingHostKeyQuestion = question
            }
        }
    }

    public func resolveHostKeyDecision(_ decision: HostKeyDecision) {
        pendingHostKeyQuestion = nil
        hostKeyContinuation?.resume(returning: decision)
        hostKeyContinuation = nil
    }

    public func dismissHostKeyMismatch() {
        pendingHostKeyMismatch = nil
    }

    /// 针对密钥已变（硬阻断 H9）的唯一恢复路径：移除本机自建库中的旧记录并重连。
    public func removeMismatchedHostKeyAndReconnect() async {
        guard let mismatch = pendingHostKeyMismatch else { return }
        pendingHostKeyMismatch = nil
        let store = makeHostKeyStore()
        _ = try? await store.removeRecords(
            host: mismatch.endpoint.host,
            port: mismatch.endpoint.port,
            keyType: nil
        )
        await connect(to: mismatch.bookmark)
    }

    // MARK: - Keyboard-Interactive 询问回调（KeyboardInteractiveResponder）
    public nonisolated func respond(to request: KeyboardInteractiveRequest) async -> [String]? {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                self.keyboardContinuation = continuation
                self.pendingKeyboardRequest = request
            }
        }
    }

    public func resolveKeyboardResponse(_ answers: [String]?) {
        pendingKeyboardRequest = nil
        keyboardContinuation?.resume(returning: answers)
        keyboardContinuation = nil
    }

    // MARK: - 发起连接
    public func connect(to bookmark: SiteBookmark) async {
        if bookmark.protocolType == .sftp && bookmark.authType == .anonymous {
            state = .failed(message: "SFTP 协议不支持匿名认证，请选择密码或密钥")
            return
        }

        if let existing = activeConnection {
            await existing.close()
            self.activeConnection = nil
        }

        state = .connecting(step: "准备连接...")
        navigationErrorMessage = nil
        currentBookmark = bookmark
        currentCharset = bookmark.charset

        let endpoint = Endpoint(host: bookmark.host, port: bookmark.port, username: bookmark.username)

        let authMethod: AuthenticationMethod
        switch bookmark.authType {
        case .password:
            authMethod = .password(bookmark.password)
        case .privateKey:
            guard !bookmark.privateKeyPath.isEmpty else {
                state = .failed(message: "未指定私钥文件路径")
                return
            }
            let keyUrl = URL(fileURLWithPath: (bookmark.privateKeyPath as NSString).expandingTildeInPath)
            do {
                let data = try Data(contentsOf: keyUrl)
                let pass = bookmark.passphrase.isEmpty ? nil : bookmark.passphrase
                authMethod = .privateKey(PrivateKeyMaterial(keyData: data, passphrase: pass))
            } catch {
                state = .failed(message: "无法读取私钥文件：\(error.localizedDescription)")
                return
            }
        case .sshAgent:
            authMethod = .sshAgent
        case .anonymous:
            authMethod = .anonymous
        }

        var policy = ConnectionPolicy.standard
        if bookmark.allowWeakAlgorithms {
            policy.algorithms = AlgorithmPreferences(
                keyExchange: [
                    "curve25519-sha256",
                    "curve25519-sha256@libssh.org",
                    "ecdh-sha2-nistp256",
                    "diffie-hellman-group-exchange-sha256",
                    "diffie-hellman-group14-sha256",
                    "diffie-hellman-group14-sha1",
                    "diffie-hellman-group1-sha1"
                ],
                hostKey: [
                    "ssh-ed25519",
                    "ecdsa-sha2-nistp256",
                    "rsa-sha2-512",
                    "rsa-sha2-256",
                    "ssh-rsa",
                    "ssh-dss"
                ],
                encryption: [
                    "chacha20-poly1305@openssh.com",
                    "aes256-gcm@openssh.com",
                    "aes128-gcm@openssh.com",
                    "aes256-ctr",
                    "aes192-ctr",
                    "aes128-ctr",
                    "aes256-cbc",
                    "aes128-cbc",
                    "3des-cbc"
                ],
                mac: [
                    "hmac-sha2-512-etm@openssh.com",
                    "hmac-sha2-256-etm@openssh.com",
                    "hmac-sha2-512",
                    "hmac-sha2-256",
                    "hmac-sha1"
                ]
            )
        }

        let request = ConnectionRequest(
            endpoint: endpoint,
            authentication: authMethod,
            policy: policy,
            charset: bookmark.charset
        )

        let backend: any RemoteBackend
        if bookmark.protocolType == .sftp {
            let hostKeyStore = makeHostKeyStore()
            backend = SFTPBackend(hostKeyTrust: hostKeyStore)
        } else {
            backend = FTPBackend(isFTPS: bookmark.protocolType == .ftps)
        }

        let connection = backend.makeConnection(request) as! (any RemoteFileSystem & RemoteConnection)
        self.activeConnection = connection

        do {
            state = .connecting(step: "正在进行协商与握手...")
            _ = try await connection.handshake()

            state = .connecting(step: "正在验证身份...")
            _ = try await connection.authenticate(interactive: self)

            beginAppNapActivityIfNeeded()

            state = .connecting(step: "正在读取远程目录...")
            let targetPath: RemotePath
            if !bookmark.remotePath.trimmingCharacters(in: .whitespaces).isEmpty {
                targetPath = RemotePath(bookmark.remotePath)
            } else if let sftp = connection as? SFTPConnection {
                targetPath = try await sftp.homeDirectory()
            } else {
                targetPath = PathResolver.root
            }

            let rtt: Int64
            if let sftp = connection as? SFTPConnection {
                rtt = await sftp.measure.elapsedMs
            } else {
                rtt = 28
            }

            try await loadRemoteItems(from: targetPath, on: connection)
            await transferQueue.setBackend(transfer: connection, fileSystem: connection)

            state = .connected(
                siteName: bookmark.name.isEmpty ? bookmark.host : bookmark.name,
                protocolStr: bookmark.protocolType.rawValue,
                rttMs: max(rtt, 1)
            )
        } catch is CancellationError {
            state = .disconnected
            await transferQueue.setBackend(transfer: nil, fileSystem: nil)
            await connection.close()
            self.activeConnection = nil
            endAppNapActivity()
        } catch let remoteError as RemoteError {
            if case .hostKeyMismatch(let fingerprint) = remoteError {
                self.pendingHostKeyMismatch = HostKeyMismatchAlert(
                    endpoint: endpoint,
                    newFingerprint: fingerprint,
                    bookmark: bookmark
                )
            }
            state = .failed(message: Self.readableMessage(for: remoteError))
            await transferQueue.setBackend(transfer: nil, fileSystem: nil)
            await connection.close()
            self.activeConnection = nil
            endAppNapActivity()
        } catch {
            state = .failed(message: error.localizedDescription)
            await transferQueue.setBackend(transfer: nil, fileSystem: nil)
            await connection.close()
            self.activeConnection = nil
            endAppNapActivity()
        }
    }

    // MARK: - 切换字符集（即时重解码当前目录，R5）
    public func setCharset(_ charset: CharsetConverter.Charset) {
        currentCharset = charset
        if var bookmark = currentBookmark {
            bookmark.charset = charset
            currentBookmark = bookmark
            Task {
                await SiteStore.shared.upsert(bookmark)
            }
        }
        rebuildDisplayItems()
    }

    // MARK: - 切换与刷新远端目录
    public func navigateRemote(to path: RemotePath) async {
        guard let connection = activeConnection else { return }
        navigationErrorMessage = nil
        do {
            try await loadRemoteItems(from: path, on: connection)
        } catch let remoteError as RemoteError {
            navigationErrorMessage = Self.readableMessage(for: remoteError)
        } catch {
            navigationErrorMessage = error.localizedDescription
        }
    }

    public func navigateRemote(toPathString rawString: String) async throws {
        guard let connection = activeConnection else { return }
        let trimmed = rawString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        navigationErrorMessage = nil

        do {
            let home: RemotePath
            if let sftp = connection as? SFTPConnection {
                home = (try? await sftp.homeDirectory()) ?? PathResolver.root
            } else {
                home = PathResolver.root
            }
            let base = currentRemotePath ?? home
            let rawPath = RemotePath(wireBytes: Array(trimmed.utf8), isAbsolute: trimmed.hasPrefix("/"))
            let resolved = try PathResolver(homeDirectory: home).lexicalResolve(rawPath, relativeTo: base)
            try await loadRemoteItems(from: resolved, on: connection)
        } catch let remoteError as RemoteError {
            navigationErrorMessage = Self.readableMessage(for: remoteError)
            throw remoteError
        } catch {
            navigationErrorMessage = error.localizedDescription
            throw error
        }
    }

    public func refreshRemote() async {
        guard let current = currentRemotePath else { return }
        await navigateRemote(to: current)
    }

    public func navigateRemoteUp() async {
        guard let current = currentRemotePath else { return }
        let parent = current.parent
        await navigateRemote(to: parent)
    }

    public func createRemoteFolder(named name: String) async {
        guard let connection = activeConnection, let current = currentRemotePath else { return }
        let converter = CharsetConverter(charset: currentCharset)
        let nameBytes: [UInt8]
        if case .bytes(let encoded) = converter.encode(name) {
            nameBytes = encoded
        } else {
            nameBytes = Array(name.utf8)
        }
        guard let target = try? PathResolver.child(of: current, name: nameBytes) else { return }
        do {
            try await connection.mkdir(target, permissions: 0o755)
            await refreshRemote()
        } catch let remoteError as RemoteError {
            navigationErrorMessage = Self.readableMessage(for: remoteError)
        } catch {
            navigationErrorMessage = error.localizedDescription
        }
    }

    public func renameRemoteItem(_ item: RemoteDisplayItem, to newName: String) async -> (success: Bool, error: String?) {
        guard let connection = activeConnection else {
            return (false, "未连接到远程服务器")
        }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return (false, "名称不能为空")
        }
        guard !trimmed.contains("/") else {
            return (false, "名称不能包含 '/'")
        }
        if trimmed == item.name {
            return (true, nil)
        }

        let converter = CharsetConverter(charset: currentCharset)
        let nameBytes: [UInt8]
        if case .bytes(let encoded) = converter.encode(trimmed) {
            nameBytes = encoded
        } else {
            nameBytes = Array(trimmed.utf8)
        }

        guard let parent = try? PathResolver.parent(of: item.path),
              let target = try? PathResolver.child(of: parent, name: nameBytes) else {
            return (false, "无法解析目标路径")
        }

        do {
            try await connection.rename(item.path, to: target, overwrite: false)
            await refreshRemote()
            return (true, nil)
        } catch let remoteError as RemoteError {
            let readable = Self.readableMessage(for: remoteError)
            return (false, readable)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    public func deleteRemoteItem(_ item: RemoteDisplayItem) async -> (success: Bool, error: String?) {
        guard let connection = activeConnection else {
            return (false, "未连接到远程服务器")
        }
        do {
            try await connection.remove(item.path, recursive: true)
            await refreshRemote()
            return (true, nil)
        } catch let remoteError as RemoteError {
            let readable = Self.readableMessage(for: remoteError)
            return (false, readable)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    private func loadRemoteItems(from path: RemotePath, on connection: any RemoteFileSystem) async throws {
        var listing = try await connection.list(path)
        var resolutions: [RemotePath: RemoteDirectoryListing.LinkResolution] = [:]
        for rawItem in listing.entries where rawItem.kind == .symbolicLink {
            if let res = try? await connection.resolve(rawItem, in: &listing) {
                resolutions[rawItem.path] = res
            }
        }
        self.currentRemotePath = listing.directory
        self.cachedListing = listing
        self.cachedResolutions = resolutions
        self.remoteListingStaleCount = listing.staleResolutionCount
        rebuildDisplayItems()
    }

    private func rebuildDisplayItems() {
        guard let listing = cachedListing else {
            self.remoteItems = []
            return
        }
        let converter = CharsetConverter(charset: currentCharset)
        let items = listing.entries.map { rawItem in
            RemoteDisplayItem(
                item: rawItem,
                charsetConverter: converter,
                linkResolution: cachedResolutions[rawItem.path]
            )
        }
        self.remoteItems = items.sorted { a, b in
            if a.isDirectory != b.isDirectory {
                return a.isDirectory && !b.isDirectory
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

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

    private func promptConflict(item: FileConflictItem, total: Int, remaining: Int) async -> (ConflictDecision, Bool)? {
        self.pendingConflictContext = PendingConflictContext(item: item, totalCount: total, remainingCount: remaining)
        return await withCheckedContinuation { continuation in
            self.conflictContinuation = continuation
        }
    }

    // MARK: - M3/M4: 传输队列与任务派发（含冲突策略拦截）

    public func uploadFiles(_ localURLs: [URL], onComplete: (@MainActor () -> Void)? = nil) {
        guard let remoteDir = currentRemotePath else { return }
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

    // MARK: - 断开连接
    public func disconnect() async {
        transferTask?.cancel()
        transferTask = nil
        activeTransfer = nil
        await transferQueue.setBackend(transfer: nil, fileSystem: nil)
        if let connection = activeConnection {
            await connection.close()
            self.activeConnection = nil
        }
        endAppNapActivity()
        self.currentRemotePath = nil
        self.cachedListing = nil
        self.cachedResolutions = [:]
        self.remoteItems = []
        self.state = .disconnected
    }

    // MARK: - App Nap 防护
    private func beginAppNapActivityIfNeeded() {
        guard appNapActivity == nil else { return }
        appNapActivity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Ferry SFTP active session"
        )
    }

    private func endAppNapActivity() {
        if let token = appNapActivity {
            ProcessInfo.processInfo.endActivity(token)
            appNapActivity = nil
        }
    }

    // MARK: - 错误码到可读文案映射（v2.3 §472）
    public static func readableMessage(for error: RemoteError) -> String {
        switch error {
        case .network(let kind):
            switch kind {
            case .timeout: return "连接超时，请检查网络或防火墙设置"
            case .connectionRefused: return "目标端口拒绝连接，请确认服务已启动且端口正确"
            case .hostUnreachable: return "目标主机不可达，请检查网络或代理"
            case .dnsFailure: return "无法解析主机域名，请检查主机地址"
            case .connectionLost: return "连接被对端重置或中断"
            }
        case .auth(let failure):
            switch failure {
            case .badPassword: return "用户名或密码不正确"
            case .passphraseRequired: return "该私钥受密码保护，请输入私钥口令"
            case .passphraseIncorrect: return "私钥口令不正确，无法解密私钥"
            case .keyRejected: return "服务器拒绝了该公钥，请检查 authorized_keys 或算法白名单"
            case .agentUnavailable: return "本地 ssh-agent 不可用或未加载有效密钥"
            case .methodNotOffered: return "服务器不支持当前选择的认证方式"
            case .tooManyAuthAttempts: return "认证尝试次数超限，服务器已断开连接"
            }
        case .hostKeyMismatch(let fp):
            return "警告：服务器主机密钥已变更（\(fp)），已硬阻断连接以防中间人攻击"
        case .permissionDenied(let path):
            return "权限不足：无法访问 \(path.displayString())"
        case .notFound(let path):
            return "路径不存在：\(path.displayString())"
        case .keyCollision(let existing, let incoming):
            return "路径冲突：\(existing.displayString()) 与 \(incoming.displayString())"
        case .unsupported(let cap):
            return "当前服务器不支持该操作（\(cap)）"
        case .undecodablePath:
            return "文件名不是合法 UTF-8，请尝试在底部状态栏切换服务器字符编码"
        case .protocolViolation(let detail):
            return "协议协商或会话异常：\(detail)"
        case .localIO(let kind):
            switch kind {
            case .diskFull: return "本地磁盘空间不足"
            case .readFailed: return "读取本地文件失败"
            case .writeFailed: return "写入本地文件失败"
            }
        case .operationFailed(let op):
            return "远程操作失败（\(op.diagnosticCode)）"
        }
    }
}
