import FerryBackendsFTP
import FerryBackendsSFTP
import FerryCore
import SwiftUI

/// 服务器间直传流式中继对话框（Server-to-Server Relay Transfer / FXP 现代替代方案）。
public struct ServerRelayDialogView: View {
    let itemsToRelay: [RemoteDisplayItem]
    @Binding var isPresented: Bool

    @Environment(\.colorScheme) private var colorScheme
    private var themeManager: ThemeManager { ThemeManager.shared }
    private var theme: FerryTheme { themeManager.theme(for: colorScheme) }
    private var connectionService: ConnectionService { ConnectionService.shared }
    private var siteStore: SiteStore { SiteStore.shared }

    @State private var targetBookmarkId: UUID?
    @State private var targetDirectoryPath: String = "/"
    @State private var isRelaying: Bool = false
    @State private var relayProgress: RelayEngine.Progress?
    @State private var relayErrorMessage: String?
    @State private var isCompleted: Bool = false
    @State private var currentSpeedBytes: Double = 0
    @State private var relayTask: Task<Void, Never>?

    public init(itemsToRelay: [RemoteDisplayItem], isPresented: Binding<Bool>) {
        self.itemsToRelay = itemsToRelay
        self._isPresented = isPresented
    }

    private var availableTargetBookmarks: [SiteBookmark] {
        siteStore.bookmarks.filter { $0.id != connectionService.currentBookmark?.id }
    }

    private var targetBookmark: SiteBookmark? {
        availableTargetBookmarks.first(where: { $0.id == targetBookmarkId })
    }

    private var totalBytesToTransfer: Int64? {
        let sizes = itemsToRelay.compactMap { $0.size }
        if sizes.count == itemsToRelay.count {
            return sizes.reduce(0, +)
        }
        return nil
    }

    public var body: some View {
        VStack(spacing: 0) {
            // 头部
            HStack(spacing: 12) {
                Image(systemName: "arrow.left.arrow.right.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(theme.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.tr("服务器间直传 (Server-to-Server Relay)", "Server-to-Server Relay Transfer"))
                        .font(FerryFont.bodyBold)
                        .foregroundColor(theme.text)

                    Text(L10n.tr("通过本地内存高速中继，数据不写本地磁盘，直接将文件流式同步至目标服务器。",
                                 "Stream data directly between remote servers via RAM pipeline without writing to local disk."))
                        .font(FerryFont.caption)
                        .foregroundColor(theme.text2)
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider().background(theme.line)

            // 主体表单
            VStack(alignment: .leading, spacing: 16) {
                // 源端展示
                HStack(alignment: .top, spacing: 12) {
                    Text(L10n.tr("源端位置:", "Source:"))
                        .font(FerryFont.captionMedium)
                        .foregroundColor(theme.text2)
                        .frame(width: 80, alignment: .trailing)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(connectionService.currentBookmark?.name ?? connectionService.currentBookmark?.host ?? L10n.tr("当前连接", "Current Server"))
                            .font(FerryFont.captionBold)
                            .foregroundColor(theme.text)

                        Text(L10n.format("选定 %d 个项目（%@）", "Selected %d item(s) (%@)", itemsToRelay.count, itemsDescription))
                            .font(FerryFont.caption)
                            .foregroundColor(theme.text2)
                    }
                }

                // 目标端选择
                HStack(alignment: .top, spacing: 12) {
                    Text(L10n.tr("目标服务器:", "Destination:"))
                        .font(FerryFont.captionMedium)
                        .foregroundColor(theme.text2)
                        .frame(width: 80, alignment: .trailing)

                    VStack(alignment: .leading, spacing: 8) {
                        if availableTargetBookmarks.isEmpty {
                            Text(L10n.tr("暂无其他可用书签，请先在左侧边栏添加目标站点书签。", "No other bookmarks available. Please add destination site in sidebar."))
                                .font(FerryFont.caption)
                                .foregroundColor(theme.errorRed)
                        } else {
                            Picker("", selection: $targetBookmarkId) {
                                Text(L10n.tr("请选择目标站点书签…", "Select destination bookmark…")).tag(UUID?.none)
                                ForEach(availableTargetBookmarks) { bm in
                                    Text("\(bm.name.isEmpty ? bm.host : bm.name) (\(bm.protocolType.rawValue) - \(bm.host):\(bm.port))")
                                        .tag(UUID?.some(bm.id))
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .disabled(isRelaying)
                        }
                    }
                }

                // 目标路径
                HStack(alignment: .center, spacing: 12) {
                    Text(L10n.tr("目标目录:", "Target Dir:"))
                        .font(FerryFont.captionMedium)
                        .foregroundColor(theme.text2)
                        .frame(width: 80, alignment: .trailing)

                    TextField(L10n.tr("例如 /backup 或 /var/www/uploads", "e.g. /backup or /var/www/uploads"), text: $targetDirectoryPath)
                        .textFieldStyle(.roundedBorder)
                        .font(FerryFont.caption)
                        .disabled(isRelaying)
                }

                // 进度与状态
                if isRelaying || isCompleted || relayErrorMessage != nil {
                    VStack(alignment: .leading, spacing: 8) {
                        if let error = relayErrorMessage {
                            HStack {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundColor(theme.errorRed)
                                Text(L10n.format("直传失败：%@", "Relay failed: %@", error))
                                    .font(FerryFont.captionBold)
                                    .foregroundColor(theme.errorRed)
                            }
                        } else if isCompleted {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(theme.accentColor)
                                Text(L10n.tr("直传完成！已成功同步至目标服务器。", "Relay complete! Successfully transferred to destination."))
                                    .font(FerryFont.captionBold)
                                    .foregroundColor(theme.text)
                            }
                        } else {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.7)
                                Text(L10n.format("正在中继传输：%@ (%@/s)",
                                                 relayProgress?.currentItemName ?? "",
                                                 ByteCountFormatter.string(fromByteCount: Int64(currentSpeedBytes), countStyle: .file)))
                                    .font(FerryFont.caption)
                                    .foregroundColor(theme.text)
                            }

                            if let p = relayProgress {
                                let doneStr = ByteCountFormatter.string(fromByteCount: p.bytesDone, countStyle: .file)
                                let totalStr = p.totalBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? L10n.tr("未知", "Unknown")
                                Text("\(doneStr) / \(totalStr)")
                                    .font(FerryFont.caption)
                                    .foregroundColor(theme.text2)
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.field)
                    .cornerRadius(FerryRadius.r8)
                }
            }
            .padding(24)

            Divider().background(theme.line)

            // 底部操作栏
            HStack {
                Button(isCompleted ? L10n.tr("关闭", "Close") : L10n.tr("取消", "Cancel")) {
                    cancelOrClose()
                }
                .buttonStyle(.plain)
                .font(FerryFont.captionMedium)
                .foregroundColor(theme.text2)

                Spacer()

                if !isCompleted {
                    Button(action: { startRelay() }) {
                        Text(L10n.tr("开始流式直传", "Start Relay Transfer"))
                            .font(FerryFont.captionBold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(targetBookmarkId == nil || isRelaying ? Color.gray : theme.accentColor)
                            .cornerRadius(FerryRadius.r7)
                    }
                    .buttonStyle(.plain)
                    .disabled(targetBookmarkId == nil || isRelaying)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(theme.bar)
        }
        .frame(width: 520)
        .background(theme.bg)
        .onAppear {
            if targetBookmarkId == nil, let first = availableTargetBookmarks.first {
                targetBookmarkId = first.id
                if !first.remotePath.isEmpty {
                    targetDirectoryPath = first.remotePath
                }
            }
        }
    }

    private var itemsDescription: String {
        itemsToRelay.prefix(3).map { $0.name }.joined(separator: ", ") + (itemsToRelay.count > 3 ? "..." : "")
    }

    private func cancelOrClose() {
        relayTask?.cancel()
        relayTask = nil
        isPresented = false
    }

    private func startRelay() {
        guard let sourceConn = connectionService.activeConnection else {
            relayErrorMessage = "源服务器尚未连接"
            return
        }
        guard let destBookmark = targetBookmark else {
            relayErrorMessage = "请选择目标服务器"
            return
        }

        isRelaying = true
        relayErrorMessage = nil
        isCompleted = false

        relayTask = Task { @MainActor in
            let startTime = Date()

            do {
                // 1. 临时建立目标服务器连接
                let endpoint = Endpoint(host: destBookmark.host, port: destBookmark.port, username: destBookmark.username)
                let auth: AuthenticationMethod
                switch destBookmark.authType {
                case .password:
                    auth = .password(destBookmark.password)
                case .privateKey:
                    let keyUrl = URL(fileURLWithPath: (destBookmark.privateKeyPath as NSString).expandingTildeInPath)
                    let data = try Data(contentsOf: keyUrl)
                    let pass = destBookmark.passphrase.isEmpty ? nil : destBookmark.passphrase
                    auth = .privateKey(PrivateKeyMaterial(keyData: data, passphrase: pass))
                case .sshAgent:
                    auth = .sshAgent
                case .anonymous:
                    auth = .anonymous
                }

                let req = ConnectionRequest(endpoint: endpoint, authentication: auth, policy: .standard, charset: destBookmark.charset)
                let backend: any RemoteBackend
                if destBookmark.protocolType == .sftp {
                    backend = SFTPBackend(hostKeyTrust: connectionService.makeHostKeyStore())
                } else {
                    backend = FTPBackend(isFTPS: destBookmark.protocolType == .ftps)
                }

                let destConnection = backend.makeConnection(req) as! (any RemoteFileSystem & RemoteTransfer & RemoteConnection)
                _ = try await destConnection.handshake()
                _ = try await destConnection.authenticate(interactive: nil)

                let targetBaseDir = RemotePath(string: targetDirectoryPath.isEmpty ? "/" : targetDirectoryPath, isAbsolute: true) ?? PathResolver.root

                // 2. 逐项流式中继
                for item in itemsToRelay {
                    try Task.checkCancellation()
                    let targetSubPath = try PathResolver.child(of: targetBaseDir, name: item.path.wireBytes.split(separator: 0x2F).last.map(Array.init) ?? Array(item.name.utf8))

                    if item.isDirectory {
                        _ = try await RelayEngine.relayDirectory(
                            from: item.path,
                            using: sourceConn,
                            to: targetSubPath,
                            using: destConnection,
                            rateLimiter: nil,
                            onProgress: { p in
                                Task { @MainActor in
                                    self.relayProgress = p
                                    let elapsed = max(Date().timeIntervalSince(startTime), 0.1)
                                    self.currentSpeedBytes = Double(p.bytesDone) / elapsed
                                }
                            }
                        )
                    } else {
                        _ = try await RelayEngine.relayFile(
                            from: item.path,
                            using: sourceConn,
                            to: targetSubPath,
                            using: destConnection,
                            rateLimiter: nil,
                            onProgress: { p in
                                Task { @MainActor in
                                    self.relayProgress = p
                                    let elapsed = max(Date().timeIntervalSince(startTime), 0.1)
                                    self.currentSpeedBytes = Double(p.bytesDone) / elapsed
                                }
                            }
                        )
                    }
                }

                await destConnection.close()
                isRelaying = false
                isCompleted = true
            } catch is CancellationError {
                isRelaying = false
                relayErrorMessage = "用户取消了直传任务"
            } catch {
                isRelaying = false
                relayErrorMessage = error.localizedDescription
            }
        }
    }
}
