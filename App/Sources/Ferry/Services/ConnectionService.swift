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
    public var activeConnection: SFTPConnection?
    public var currentBookmark: SiteBookmark?
    public var currentRemotePath: RemotePath?
    public var currentCharset: CharsetConverter.Charset = .utf8
    public var remoteItems: [RemoteDisplayItem] = []
    public var remoteListingStaleCount: Int = 0
    public var navigationErrorMessage: String?

    // 传输状态与取消控制
    public var activeTransfer: ActiveTransferInfo?
    private var transferTask: Task<Void, Never>?

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
        guard bookmark.protocolType == .sftp else {
            state = .failed(message: "\(bookmark.protocolType.rawValue) 后端将在 M5 接入，当前支持 SFTP")
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
            state = .failed(message: "SFTP 协议不支持匿名认证，请选择密码或密钥")
            return
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

        let hostKeyStore = makeHostKeyStore()
        let backend = SFTPBackend(hostKeyTrust: hostKeyStore)

        let connection = backend.makeConnection(request) as! SFTPConnection
        self.activeConnection = connection

        do {
            state = .connecting(step: "正在进行密钥协商...")
            _ = try await connection.handshake()

            state = .connecting(step: "正在验证身份...")
            _ = try await connection.authenticate(interactive: self)

            beginAppNapActivityIfNeeded()

            state = .connecting(step: "正在读取远程目录...")
            let targetPath: RemotePath
            if !bookmark.remotePath.trimmingCharacters(in: .whitespaces).isEmpty {
                targetPath = RemotePath(bookmark.remotePath)
            } else {
                targetPath = try await connection.homeDirectory()
            }

            let measure = await connection.measure
            let rtt = measure.elapsedMs

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

    /// 供 `⌘⇧G` 前往路径与路径栏编辑跳转使用（支持 `~`、相对路径与绝对路径）。
    public func navigateRemote(toPathString rawString: String) async throws {
        guard let connection = activeConnection else { return }
        let trimmed = rawString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let home = try await connection.homeDirectory()
        let base = currentRemotePath ?? home
        let rawPath = RemotePath(wireBytes: Array(trimmed.utf8), isAbsolute: trimmed.hasPrefix("/"))
        let resolved = try PathResolver(homeDirectory: home).lexicalResolve(rawPath, relativeTo: base)
        try await loadRemoteItems(from: resolved, on: connection)
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

    private func loadRemoteItems(from path: RemotePath, on connection: SFTPConnection) async throws {
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

    // MARK: - M3: 传输队列与任务派发

    public func uploadFiles(_ localURLs: [URL], onComplete: (@MainActor () -> Void)? = nil) {
        guard let remoteDir = currentRemotePath else { return }
        guard !localURLs.isEmpty else { return }
        isQueuePanelPresented = true

        Task {
            var scannedFiles: [DirectoryScanner.ScannedFile] = []
            for url in localURLs {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
                if isDir.boolValue {
                    if let scanned = try? DirectoryScanner.scanLocalDirectory(url, targetRemoteDir: remoteDir) {
                        scannedFiles.append(contentsOf: scanned)
                    }
                } else {
                    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                    let size = attrs?[.size] as? Int64
                    let targetName = url.lastPathComponent
                    if let targetRemote = try? PathResolver.child(of: remoteDir, name: Array(targetName.utf8)) {
                        scannedFiles.append(DirectoryScanner.ScannedFile(localURL: url, remotePath: targetRemote, size: size))
                    }
                }
            }
            if !scannedFiles.isEmpty {
                await transferQueue.addScannedBatch(scannedFiles, direction: .upload)
            }
            onComplete?()
        }
    }

    public func downloadItems(_ items: [RemoteDisplayItem], to localDirectory: URL, onComplete: (@MainActor () -> Void)? = nil) {
        guard let connection = activeConnection else { return }
        guard !items.isEmpty else { return }
        isQueuePanelPresented = true

        Task {
            var scannedFiles: [DirectoryScanner.ScannedFile] = []
            for item in items {
                if item.isDirectory {
                    let destFolder = localDirectory.appendingPathComponent(item.name)
                    if let scanned = try? await DirectoryScanner.scanRemoteDirectory(item.path, fileSystem: connection, targetLocalDir: destFolder) {
                        scannedFiles.append(contentsOf: scanned)
                    }
                } else {
                    let destination = localDirectory.appendingPathComponent(item.name)
                    scannedFiles.append(DirectoryScanner.ScannedFile(localURL: destination, remotePath: item.path, size: item.size))
                }
            }
            if !scannedFiles.isEmpty {
                await transferQueue.addScannedBatch(scannedFiles, direction: .download)
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
