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

@Observable
@MainActor
public final class ConnectionService: HostKeyTrustPrompt, KeyboardInteractiveResponder {
    public static let shared = ConnectionService()

    public var state: ActiveConnectionState = .disconnected
    public var activeConnection: SFTPConnection?
    public var currentBookmark: SiteBookmark?
    public var currentRemotePath: RemotePath?
    public var remoteItems: [RemoteDisplayItem] = []
    public var remoteListingStaleCount: Int = 0

    // MARK: - TOFU 与 键盘交互 弹窗挂起点
    public var pendingHostKeyQuestion: HostKeyQuestion?
    private var hostKeyContinuation: CheckedContinuation<HostKeyDecision, Never>?

    public var pendingKeyboardRequest: KeyboardInteractiveRequest?
    private var keyboardContinuation: CheckedContinuation<[String]?, Never>?

    public init() {}

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
            state = .failed(message: "\(bookmark.protocolType.rawValue) 后端将在后续里程碑接入，当前支持 SFTP")
            return
        }

        state = .connecting(step: "准备连接...")
        currentBookmark = bookmark

        // 构建 Endpoint
        let endpoint = Endpoint(host: bookmark.host, port: bookmark.port, username: bookmark.username)

        // 解析认证方式
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

        // 弱算法偏好配置
        var policy = ConnectionPolicy.standard
        if bookmark.allowWeakAlgorithms {
            // S6：老设备兼容开启
            policy.algorithms = AlgorithmPreferences(
                keyExchange: ["curve25519-sha256", "ecdh-sha2-nistp256", "diffie-hellman-group14-sha256", "diffie-hellman-group14-sha1", "diffie-hellman-group1-sha1"],
                hostKey: ["ssh-ed25519", "ecdsa-sha2-nistp256", "rsa-sha2-512", "rsa-sha2-256", "ssh-rsa", "ssh-dss"],
                encryption: ["chacha20-poly1305@openssh.com", "aes128-gcm@openssh.com", "aes256-gcm@openssh.com", "aes256-ctr", "aes192-ctr", "aes128-ctr", "aes256-cbc", "aes128-cbc", "3des-cbc"],
                mac: ["hmac-sha2-256-etm@openssh.com", "hmac-sha2-512-etm@openssh.com", "hmac-sha2-256", "hmac-sha2-512", "hmac-sha1"]
            )
        }

        let request = ConnectionRequest(
            endpoint: endpoint,
            authentication: authMethod,
            policy: policy
        )

        // 配置自建 HostKey 存储路径
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let ferryDir = appSupport.appendingPathComponent("Ferry", isDirectory: true)
        try? FileManager.default.createDirectory(at: ferryDir, withIntermediateDirectories: true)
        let storeURL = ferryDir.appendingPathComponent("known_hosts")

        let hostKeyConfig = HostKeyStoreConfig.standard(storeURL: storeURL)
        let hostKeyStore = HostKeyStore(config: hostKeyConfig, prompt: self)
        let backend = SFTPBackend(hostKeyTrust: hostKeyStore)

        let connection = backend.makeConnection(request) as! SFTPConnection
        self.activeConnection = connection

        do {
            state = .connecting(step: "正在进行密钥协商...")
            _ = try await connection.handshake()

            state = .connecting(step: "正在验证身份...")
            _ = try await connection.authenticate(interactive: self)

            state = .connecting(step: "正在读取远程目录...")
            let targetPath: RemotePath
            if !bookmark.remotePath.trimmingCharacters(in: .whitespaces).isEmpty {
                targetPath = RemotePath(bookmark.remotePath)
            } else {
                targetPath = try await connection.homeDirectory()
            }

            self.currentRemotePath = targetPath
            let measure = await connection.measure
            let rtt = measure.elapsedMs

            // 加载目录内容
            try await loadRemoteItems(from: targetPath, on: connection)

            state = .connected(
                siteName: bookmark.name.isEmpty ? bookmark.host : bookmark.name,
                protocolStr: bookmark.protocolType.rawValue,
                rttMs: max(rtt, 1)
            )
        } catch is CancellationError {
            state = .disconnected
            await connection.close()
            self.activeConnection = nil
        } catch {
            state = .failed(message: error.localizedDescription)
            await connection.close()
            self.activeConnection = nil
        }
    }

    // MARK: - 切换与刷新远端目录
    public func navigateRemote(to path: RemotePath) async {
        guard let connection = activeConnection else { return }
        do {
            try await loadRemoteItems(from: path, on: connection)
            self.currentRemotePath = path
        } catch {
            // 保留当前目录，并可在界面展示错误
            print("读取目录失败：\(error)")
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

    private func loadRemoteItems(from path: RemotePath, on connection: SFTPConnection) async throws {
        var listing = try await connection.list(path)
        let converter = await connection.charsetConverter

        var items: [RemoteDisplayItem] = []
        for rawItem in listing.entries {
            let res: RemoteDirectoryListing.LinkResolution?
            if rawItem.kind == .symbolicLink {
                res = try? await connection.resolve(rawItem, in: &listing)
            } else {
                res = nil
            }
            items.append(RemoteDisplayItem(item: rawItem, charsetConverter: converter, linkResolution: res))
        }

        // 排序：目录排前，随后名称字母升序
        self.remoteItems = items.sorted { a, b in
            if a.isDirectory != b.isDirectory {
                return a.isDirectory && !b.isDirectory
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        self.remoteListingStaleCount = listing.staleResolutionCount
    }

    // MARK: - 断开连接
    public func disconnect() async {
        if let connection = activeConnection {
            await connection.close()
            self.activeConnection = nil
        }
        self.currentRemotePath = nil
        self.remoteItems = []
        self.state = .disconnected
    }
}
