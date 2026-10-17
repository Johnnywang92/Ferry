import FerryCore
import Foundation

public enum ProtocolType: String, CaseIterable, Codable, Identifiable, Sendable {
    case sftp = "SFTP"
    case ftp = "FTP"
    case ftps = "FTPS"

    public var id: String { rawValue }

    public var defaultPort: Int {
        switch self {
        case .sftp: return 22
        case .ftp: return 21
        case .ftps: return 990
        }
    }
}

public enum SiteAuthType: String, CaseIterable, Codable, Identifiable, Sendable {
    case password = "密码"
    case privateKey = "SSH 密钥"
    case sshAgent = "ssh-agent"
    case anonymous = "匿名"

    public var id: String { rawValue }
}

public struct SiteBookmark: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var protocolType: ProtocolType
    public var host: String
    public var port: Int
    public var username: String
    public var authType: SiteAuthType
    /// 仅驻留内存或存入 Keychain，绝不序列化进 `sites.json`（ADR-0000 I4、v2.3 §460）。
    public var password: String
    public var privateKeyPath: String
    /// 仅驻留内存或存入 Keychain，绝不序列化进 `sites.json`。
    public var passphrase: String
    public var savePasswordInKeychain: Bool
    public var allowWeakAlgorithms: Bool
    public var remotePath: String
    /// 本地目录存为 `ScopedBookmark`（`path` + 可选 `bookmarkData`），兼容未来沙盒升级（ADR-0000 D1）。
    public var localBookmark: ScopedBookmark
    /// 远端文件名字符集（默认 UTF-8）。
    public var charset: CharsetConverter.Charset
    /// 从 `~/.ssh/config` 导入时保留的 `ProxyJump` 配置（v1.1+ 支持实际跳转）。
    public var proxyJump: String?

    public var localPath: String {
        get { localBookmark.path }
        set { localBookmark.path = newValue }
    }

    public var hasUnsupportedProxyJump: Bool {
        guard let proxyJump else { return false }
        return !proxyJump.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case protocolType
        case host
        case port
        case username
        case authType
        case privateKeyPath
        case savePasswordInKeychain
        case allowWeakAlgorithms
        case remotePath
        case localBookmark
        case charset
        case proxyJump
    }

    public init(
        id: UUID = UUID(),
        name: String,
        protocolType: ProtocolType = .sftp,
        host: String,
        port: Int = 22,
        username: String,
        authType: SiteAuthType = .password,
        password: String = "",
        privateKeyPath: String = "",
        passphrase: String = "",
        savePasswordInKeychain: Bool = true,
        allowWeakAlgorithms: Bool = false,
        remotePath: String = "",
        localPath: String = "",
        localBookmark: ScopedBookmark? = nil,
        charset: CharsetConverter.Charset = .utf8,
        proxyJump: String? = nil
    ) {
        self.id = id
        self.name = name
        self.protocolType = protocolType
        self.host = host
        self.port = port
        self.username = username
        self.authType = authType
        self.password = password
        self.privateKeyPath = privateKeyPath
        self.passphrase = passphrase
        self.savePasswordInKeychain = savePasswordInKeychain
        self.allowWeakAlgorithms = allowWeakAlgorithms
        self.remotePath = remotePath
        self.localBookmark = localBookmark ?? ScopedBookmark(path: localPath)
        self.charset = charset
        self.proxyJump = proxyJump
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.protocolType = try container.decode(ProtocolType.self, forKey: .protocolType)
        self.host = try container.decode(String.self, forKey: .host)
        self.port = try container.decode(Int.self, forKey: .port)
        self.username = try container.decode(String.self, forKey: .username)
        self.authType = try container.decode(SiteAuthType.self, forKey: .authType)
        self.password = ""
        self.privateKeyPath = try container.decodeIfPresent(String.self, forKey: .privateKeyPath) ?? ""
        self.passphrase = ""
        self.savePasswordInKeychain = try container.decodeIfPresent(Bool.self, forKey: .savePasswordInKeychain) ?? true
        self.allowWeakAlgorithms = try container.decodeIfPresent(Bool.self, forKey: .allowWeakAlgorithms) ?? false
        self.remotePath = try container.decodeIfPresent(String.self, forKey: .remotePath) ?? ""
        self.localBookmark = try container.decodeIfPresent(ScopedBookmark.self, forKey: .localBookmark)
            ?? ScopedBookmark(path: FileManager.default.homeDirectoryForCurrentUser.path)
        self.charset = try container.decodeIfPresent(CharsetConverter.Charset.self, forKey: .charset) ?? .utf8
        self.proxyJump = try container.decodeIfPresent(String.self, forKey: .proxyJump)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(protocolType, forKey: .protocolType)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encode(username, forKey: .username)
        try container.encode(authType, forKey: .authType)
        try container.encode(privateKeyPath, forKey: .privateKeyPath)
        try container.encode(savePasswordInKeychain, forKey: .savePasswordInKeychain)
        try container.encode(allowWeakAlgorithms, forKey: .allowWeakAlgorithms)
        try container.encode(remotePath, forKey: .remotePath)
        try container.encode(localBookmark, forKey: .localBookmark)
        try container.encode(charset, forKey: .charset)
        try container.encodeIfPresent(proxyJump, forKey: .proxyJump)
    }

    /// 从 `~/.ssh/config` 解析条目构造站点书签。
    public static func from(sshEntry: SSHHostEntry) -> SiteBookmark {
        let firstKey = sshEntry.identityFiles.first ?? ""
        let auth: SiteAuthType = !firstKey.isEmpty ? .privateKey : .sshAgent
        return SiteBookmark(
            name: sshEntry.alias,
            protocolType: .sftp,
            host: sshEntry.hostName,
            port: sshEntry.port,
            username: sshEntry.user ?? NSUserName(),
            authType: auth,
            privateKeyPath: firstKey,
            savePasswordInKeychain: true,
            allowWeakAlgorithms: sshEntry.prefersWeakAlgorithms,
            remotePath: "",
            localPath: FileManager.default.homeDirectoryForCurrentUser.path,
            charset: .utf8,
            proxyJump: sshEntry.proxyJump
        )
    }

    /// 设计稿与本地仿真环境预设站点
    public static let samplePresets: [SiteBookmark] = [
        SiteBookmark(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000002202")!,
            name: "测试容器 · Modern (2202)",
            protocolType: .sftp,
            host: "127.0.0.1",
            port: 2202,
            username: "tester",
            authType: .password,
            password: "testpass",
            remotePath: "",
            localPath: FileManager.default.homeDirectoryForCurrentUser.path
        ),
        SiteBookmark(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000002204")!,
            name: "老设备仿真 · Legacy (2204)",
            protocolType: .sftp,
            host: "127.0.0.1",
            port: 2204,
            username: "tester",
            authType: .password,
            password: "testpass",
            allowWeakAlgorithms: true,
            remotePath: "",
            localPath: FileManager.default.homeDirectoryForCurrentUser.path
        ),
        SiteBookmark(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "生产 Web",
            protocolType: .sftp,
            host: "prod.example.com",
            port: 22,
            username: "deploy",
            authType: .privateKey,
            remotePath: "/var/www/html",
            localPath: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Projects").path
        ),
        SiteBookmark(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            name: "预发布",
            protocolType: .sftp,
            host: "staging.example.com",
            port: 22,
            username: "deploy",
            authType: .password,
            remotePath: "/var/www/staging",
            localPath: FileManager.default.homeDirectoryForCurrentUser.path
        ),
        SiteBookmark(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            name: "备份 NAS",
            protocolType: .ftp,
            host: "nas.local",
            port: 21,
            username: "backup",
            authType: .password,
            remotePath: "/volume1/backup",
            localPath: FileManager.default.homeDirectoryForCurrentUser.path
        ),
        SiteBookmark(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
            name: "静态资源",
            protocolType: .ftps,
            host: "static.cdn.internal",
            port: 990,
            username: "cdn-user",
            authType: .password,
            remotePath: "/cdn/assets",
            localPath: FileManager.default.homeDirectoryForCurrentUser.path
        )
    ]
}

/// 本地常用快速位置
public struct LocalLocation: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let iconName: String
    public let url: URL

    public static var defaults: [LocalLocation] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        return [
            LocalLocation(id: "home", name: "个人主目录", iconName: "house", url: home),
            LocalLocation(id: "desktop", name: "桌面", iconName: "desktopcomputer",
                          url: fm.urls(for: .desktopDirectory, in: .userDomainMask).first ?? home.appendingPathComponent("Desktop")),
            LocalLocation(id: "documents", name: "文稿", iconName: "doc",
                          url: fm.urls(for: .documentDirectory, in: .userDomainMask).first ?? home.appendingPathComponent("Documents")),
            LocalLocation(id: "downloads", name: "下载", iconName: "arrow.down.circle",
                          url: fm.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? home.appendingPathComponent("Downloads")),
            LocalLocation(id: "projects", name: "Projects", iconName: "folder",
                          url: home.appendingPathComponent("Projects"))
        ]
    }
}
