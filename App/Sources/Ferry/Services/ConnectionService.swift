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

// MARK: - M4/UI-REFERENCE §6: 传输失败独立弹窗上下文
public struct TransferFailureContext: Identifiable, Sendable {
    public let id: UUID
    public let taskID: UUID
    public let fileName: String
    public let direction: TransferDirection
    public let remotePath: String
    public let localPath: String
    public let bytesDone: Int64
    public let totalBytes: Int64?
    public let errorMessage: String
    public let errorDetails: [String]
    public let isRetryable: Bool
    public let supportsResume: Bool

    public init(
        id: UUID = UUID(),
        taskID: UUID,
        fileName: String,
        direction: TransferDirection,
        remotePath: String,
        localPath: String,
        bytesDone: Int64,
        totalBytes: Int64?,
        errorMessage: String,
        errorDetails: [String] = [],
        isRetryable: Bool = true,
        supportsResume: Bool = true
    ) {
        self.id = id
        self.taskID = taskID
        self.fileName = fileName
        self.direction = direction
        self.remotePath = remotePath
        self.localPath = localPath
        self.bytesDone = bytesDone
        self.totalBytes = totalBytes
        self.errorMessage = errorMessage
        self.errorDetails = errorDetails
        self.isRetryable = isRetryable
        self.supportsResume = supportsResume
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
    var cachedListing: RemoteDirectoryListing?
    var cachedResolutions: [RemotePath: RemoteDirectoryListing.LinkResolution] = [:]

    // MARK: - TOFU、密钥变更硬阻断与键盘交互弹窗挂起点
    public var pendingHostKeyQuestion: HostKeyQuestion?
    var hostKeyContinuation: CheckedContinuation<HostKeyDecision, Never>?

    public var pendingHostKeyMismatch: HostKeyMismatchAlert?

    public var pendingKeyboardRequest: KeyboardInteractiveRequest?
    var keyboardContinuation: CheckedContinuation<[String]?, Never>?

    // MARK: - M4: 文件冲突弹窗挂起点
    public struct PendingConflictContext: Identifiable, Sendable {
        public let id = UUID()
        public let item: FileConflictItem
        public let totalCount: Int
        public let remainingCount: Int
    }
    public var pendingConflictContext: PendingConflictContext?
    var conflictContinuation: CheckedContinuation<(ConflictDecision, Bool)?, Never>?

    public var pendingFailureContext: TransferFailureContext?
    public var suppressedFailureTaskIDs: Set<UUID> = []

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
                    var newlyFailedTask: TransferTaskState? = nil

                    for s in states {
                        switch s.status {
                        case .running:
                            r += 1
                            if s.direction == .upload { up += s.speedBytesPerSec }
                            else { down += s.speedBytesPerSec }
                        case .failed:
                            f += 1
                            if newlyFailedTask == nil && !self.suppressedFailureTaskIDs.contains(s.id) {
                                newlyFailedTask = s
                            }
                        case .pending:
                            p += 1
                        default:
                            break
                        }
                    }
                    self.queueSummary = (r, f, p)
                    self.aggregateSpeed = (up, down)

                    // 遇到传输失败且弹窗未开启时，根据规范调出 TransferFailureDialog
                    if self.pendingFailureContext == nil, let failed = newlyFailedTask {
                        self.pendingFailureContext = self.makeFailureContext(for: failed)
                    }
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
