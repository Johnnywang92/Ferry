import AppKit
import FerryBackendsFTP
import FerryBackendsSFTP
import FerryCore
import SwiftUI

public struct ConnectionDialogView: View {
    @Binding var isPresented: Bool
    var initialBookmark: SiteBookmark?
    var onConnect: (SiteBookmark) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var bookmark: SiteBookmark
    @State private var isTesting = false
    @State private var testResult: String?
    @State private var testSuccess: Bool = false

    private var theme: FerryTheme {
        ThemeManager.shared.theme(for: colorScheme)
    }

    public init(isPresented: Binding<Bool>,
                initialBookmark: SiteBookmark? = nil,
                onConnect: @escaping (SiteBookmark) -> Void) {
        self._isPresented = isPresented
        self.initialBookmark = initialBookmark
        self.onConnect = onConnect

        let defaultBookmark = initialBookmark ?? SiteBookmark(
            name: "",
            protocolType: .sftp,
            host: "127.0.0.1",
            port: 2202,
            username: "tester",
            authType: .password,
            password: "testpass",
            remotePath: "",
            localPath: FileManager.default.homeDirectoryForCurrentUser.path
        )
        self._bookmark = State(initialValue: defaultBookmark)
    }

    public var body: some View {
        VStack(spacing: 0) {
            // 头部标题与副标题
            VStack(alignment: .leading, spacing: 4) {
                Text(initialBookmark == nil ? L10n.tr("新建连接", "New Connection") : L10n.tr("编辑站点", "Edit Site"))
                    .font(FerryFont.bodyBold)
                    .foregroundColor(theme.text)
                Text(L10n.tr("连接到 SFTP、FTP 或 FTPS 服务器。", "Connect to SFTP, FTP, or FTPS servers."))
                    .font(FerryFont.caption)
                    .foregroundColor(theme.text2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 14)

            Divider().background(theme.line)

            // 表单滚动区域
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // 名称
                    formRow(label: L10n.tr("名称", "Name")) {
                        TextField(L10n.tr("例：生产 Web", "e.g. Production Web"), text: $bookmark.name)
                            .textFieldStyle(.roundedBorder)
                    }

                    // 协议
                    formRow(label: L10n.tr("协议", "Protocol")) {
                        Picker("", selection: $bookmark.protocolType) {
                            ForEach(ProtocolType.allCases) { proto in
                                Text(proto.rawValue).tag(proto)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: bookmark.protocolType) { _, newProto in
                            bookmark.port = newProto.defaultPort
                        }
                    }

                    // 主机与端口
                    formRow(label: L10n.tr("主机", "Host")) {
                        HStack(spacing: 8) {
                            TextField("127.0.0.1", text: $bookmark.host)
                                .textFieldStyle(.roundedBorder)

                            Text(L10n.tr("端口", "Port"))
                                .font(FerryFont.captionMedium)
                                .foregroundColor(theme.text2)

                            TextField("22", value: $bookmark.port, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 64)
                        }
                    }

                    // 认证方式
                    formRow(label: L10n.tr("认证方式", "Auth")) {
                        Picker("", selection: $bookmark.authType) {
                            ForEach(SiteAuthType.allCases) { auth in
                                Text(auth.displayName).tag(auth)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    // 用户名
                    if bookmark.authType != .anonymous {
                        formRow(label: L10n.tr("用户名", "Username")) {
                            TextField("username", text: $bookmark.username)
                                .textFieldStyle(.roundedBorder)
                        }
                    }

                    // 密码 / 密钥
                    switch bookmark.authType {
                    case .password:
                        formRow(label: L10n.tr("密码", "Password")) {
                            SecureField("••••••••", text: $bookmark.password)
                                .textFieldStyle(.roundedBorder)
                        }
                    case .privateKey:
                        formRow(label: L10n.tr("私钥文件", "Private Key")) {
                            HStack(spacing: 8) {
                                TextField("~/.ssh/id_ed25519", text: $bookmark.privateKeyPath)
                                    .textFieldStyle(.roundedBorder)
                                Button(L10n.tr("选择…", "Browse…")) {
                                    pickKeyFile()
                                }
                            }
                        }
                        formRow(label: L10n.tr("私钥口令", "Passphrase")) {
                            SecureField(L10n.tr("若无密码保护可留空", "Leave empty if not encrypted"), text: $bookmark.passphrase)
                                .textFieldStyle(.roundedBorder)
                        }
                    case .sshAgent:
                        formRow(label: "ssh-agent") {
                            Text(L10n.tr("连接时将直接查询本地 $SSH_AUTH_SOCK 提供的密钥身份。", "Uses SSH identities provided by local $SSH_AUTH_SOCK directly."))
                                .font(FerryFont.caption)
                                .foregroundColor(theme.text3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    case .anonymous:
                        formRow(label: L10n.tr("匿名", "Anonymous")) {
                            Text(L10n.tr("以 anonymous 匿名身份连接（适用于只读 FTP 公开服务器）。", "Connect anonymously (suitable for public read-only FTP servers)."))
                                .font(FerryFont.caption)
                                .foregroundColor(theme.text3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    // 钥匙串复选
                    if bookmark.authType == .password || bookmark.authType == .privateKey {
                        HStack {
                            Text("").frame(width: 80)
                            Toggle(L10n.tr("将密码保存到钥匙串", "Save password in Keychain"), isOn: $bookmark.savePasswordInKeychain)
                                .font(FerryFont.subheadline)
                                .toggleStyle(.checkbox)
                        }
                    }

                    // 弱算法兼容
                    HStack {
                        Text("").frame(width: 80)
                        Toggle(L10n.tr("允许弱算法（兼容老设备 CBC、ssh-rsa 等）", "Allow legacy algorithms (CBC, ssh-rsa, etc.)"), isOn: $bookmark.allowWeakAlgorithms)
                            .font(FerryFont.caption)
                            .foregroundColor(theme.text2)
                            .toggleStyle(.checkbox)
                    }

                    Divider().background(theme.line).padding(.vertical, 2)

                    // 文件名字符集
                    formRow(label: L10n.tr("字符集", "Encoding")) {
                        Picker("", selection: $bookmark.charset) {
                            ForEach(CharsetConverter.Charset.allCases) { cs in
                                Text(cs.displayName).tag(cs)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // 远程目录
                    formRow(label: L10n.tr("远程目录", "Remote Path")) {
                        TextField(L10n.tr("默认为登录目录，如 /var/www/html", "Default login directory, e.g. /var/www/html"), text: $bookmark.remotePath)
                            .textFieldStyle(.roundedBorder)
                    }

                    // 本地目录
                    formRow(label: L10n.tr("本地目录", "Local Path")) {
                        HStack(spacing: 8) {
                            Text(bookmark.localPath.isEmpty ? L10n.tr("未指定", "Not specified") : bookmark.localPath)
                                .font(FerryFont.caption)
                                .foregroundColor(theme.text)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(6)
                                .background(theme.field)
                                .cornerRadius(FerryRadius.r4)

                            Button(L10n.tr("选择…", "Browse…")) {
                                pickLocalFolder()
                            }
                        }
                    }

                    if let proxy = bookmark.proxyJump, !proxy.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(theme.warningOrange)
                            Text(L10n.format("该站点配置了 ProxyJump (%@)，暂不支持代理跳板直连。", "Site configured with ProxyJump (%@), jump hosts are not supported yet.", proxy))
                                .font(FerryFont.caption)
                                .foregroundColor(theme.warningOrange)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.field)
                        .cornerRadius(FerryRadius.r4)
                    }

                    // 测试结果提示
                    if let result = testResult {
                        HStack(spacing: 8) {
                            Image(systemName: testSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundColor(testSuccess ? theme.successGreen : theme.warningOrange)
                            Text(result)
                                .font(FerryFont.caption)
                                .foregroundColor(testSuccess ? theme.text : theme.errorRed)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.field)
                        .cornerRadius(FerryRadius.r4)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
            .frame(maxHeight: 480)

            Divider().background(theme.line)

            // 底部动作栏
            HStack {
                Button(action: testConnection) {
                    if isTesting {
                        ProgressView().controlSize(.small)
                            .padding(.trailing, 4)
                        Text(L10n.tr("测试中...", "Testing..."))
                    } else {
                        Text(L10n.tr("测试连接", "Test Connection"))
                    }
                }
                .disabled(isTesting || bookmark.host.isEmpty)

                Spacer()

                Button(L10n.tr("取消", "Cancel")) {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button(L10n.tr("保存", "Save")) {
                    var toSave = bookmark
                    if toSave.name.trimmingCharacters(in: .whitespaces).isEmpty {
                        toSave.name = toSave.host
                    }
                    Task { await SiteStore.shared.upsert(toSave) }
                    isPresented = false
                }
                .disabled(bookmark.host.isEmpty)

                Button(L10n.tr("连接", "Connect")) {
                    var toConnect = bookmark
                    if toConnect.name.trimmingCharacters(in: .whitespaces).isEmpty {
                        toConnect.name = toConnect.host
                    }
                    Task { await SiteStore.shared.upsert(toConnect) }
                    isPresented = false
                    onConnect(toConnect)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(theme.accentColor)
                .disabled(bookmark.host.isEmpty)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(theme.bar)
        }
        .frame(width: 520)
        .background(theme.bg)
    }

    private func formRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label)
                .font(FerryFont.captionMedium)
                .foregroundColor(theme.text2)
                .frame(width: 80, alignment: .trailing)

            content()
        }
    }

    private func pickKeyFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            bookmark.privateKeyPath = url.path
        }
    }

    private func pickLocalFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            bookmark.localBookmark = ScopedBookmark(url: url, includeBookmarkData: true)
        }
    }

    private func testConnection() {
        isTesting = true
        testResult = nil

        Task {
            let start = DispatchTime.now().uptimeNanoseconds
            let endpoint = Endpoint(host: bookmark.host, port: bookmark.port, username: bookmark.username)
            let authMethod: AuthenticationMethod
            switch bookmark.authType {
            case .password:
                authMethod = .password(bookmark.password)
            case .privateKey:
                if let data = try? Data(contentsOf: URL(fileURLWithPath: (bookmark.privateKeyPath as NSString).expandingTildeInPath)) {
                    authMethod = .privateKey(PrivateKeyMaterial(keyData: data, passphrase: bookmark.passphrase.isEmpty ? nil : bookmark.passphrase))
                } else {
                    testResult = L10n.tr("无法读取私钥文件", "Failed to read private key file")
                    testSuccess = false
                    isTesting = false
                    return
                }
            case .sshAgent:
                authMethod = .sshAgent
            case .anonymous:
                if bookmark.protocolType == .sftp {
                    testResult = L10n.tr("SFTP 暂不支持匿名认证", "SFTP does not support anonymous login")
                    testSuccess = false
                    isTesting = false
                    return
                }
                authMethod = .anonymous
            }

            var policy = ConnectionPolicy.standard
            if bookmark.allowWeakAlgorithms {
                policy.algorithms = AlgorithmPreferences(
                    keyExchange: ["curve25519-sha256", "ecdh-sha2-nistp256", "diffie-hellman-group14-sha256", "diffie-hellman-group14-sha1", "diffie-hellman-group1-sha1"],
                    hostKey: ["ssh-ed25519", "ecdsa-sha2-nistp256", "rsa-sha2-512", "rsa-sha2-256", "ssh-rsa", "ssh-dss"],
                    encryption: ["chacha20-poly1305@openssh.com", "aes128-gcm@openssh.com", "aes256-gcm@openssh.com", "aes256-ctr", "aes192-ctr", "aes128-ctr", "aes256-cbc", "aes128-cbc"],
                    mac: ["hmac-sha2-256-etm@openssh.com", "hmac-sha2-512-etm@openssh.com", "hmac-sha2-256", "hmac-sha1"]
                )
            }

            let req = ConnectionRequest(
                endpoint: endpoint,
                authentication: authMethod,
                policy: policy,
                charset: bookmark.charset,
                pathPolicy: .posix
            )

            let conn: any RemoteConnection
            if bookmark.protocolType == .sftp {
                let dummyTrust = AutoAcceptHostKeyTrust()
                conn = SFTPConnection(request: req, hostKeyTrust: dummyTrust)
            } else {
                let isFTPS = bookmark.protocolType == .ftps
                conn = FTPConnection(request: req, isFTPS: isFTPS)
            }

            do {
                _ = try await conn.handshake()
                _ = try await conn.authenticate(interactive: nil)
                let elapsedMs = (DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                await conn.close()
                await MainActor.run {
                    self.testSuccess = true
                    self.testResult = L10n.format("连接测试成功！往返耗时 %d ms", "Connection successful! RTT: %d ms", elapsedMs)
                    self.isTesting = false
                }
            } catch {
                await conn.close()
                await MainActor.run {
                    self.testSuccess = false
                    self.testResult = L10n.format("连接失败：%@", "Connection failed: %@", error.localizedDescription)
                    self.isTesting = false
                }
            }
        }
    }
}

/// 仅用于测试连接时跳过交互询问的临时信任判定
private final class AutoAcceptHostKeyTrust: HostKeyTrust, @unchecked Sendable {
    func evaluate(endpoint: Endpoint, hostKey: HostKey) async throws {
        // 放行
    }
}
