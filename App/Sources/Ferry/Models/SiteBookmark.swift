import Foundation

public enum ProtocolType: String, CaseIterable, Identifiable, Sendable {
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

public enum SiteAuthType: String, CaseIterable, Identifiable, Sendable {
    case password = "密码"
    case privateKey = "SSH 密钥"
    case sshAgent = "ssh-agent"
    case anonymous = "匿名"

    public var id: String { rawValue }
}

public struct SiteBookmark: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var protocolType: ProtocolType
    public var host: String
    public var port: Int
    public var username: String
    public var authType: SiteAuthType
    public var password: String
    public var privateKeyPath: String
    public var passphrase: String
    public var savePasswordInKeychain: Bool
    public var allowWeakAlgorithms: Bool
    public var remotePath: String
    public var localPath: String

    public init(id: UUID = UUID(),
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
                localPath: String = "") {
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
        self.localPath = localPath
    }

    /// 设计稿与环境预设站点
    public static let samplePresets: [SiteBookmark] = [
        SiteBookmark(name: "测试容器 · SFTP (2202)",
                     protocolType: .sftp,
                     host: "127.0.0.1",
                     port: 2202,
                     username: "ferry",
                     authType: .password,
                     password: "ferry",
                     remotePath: "",
                     localPath: FileManager.default.homeDirectoryForCurrentUser.path),
        SiteBookmark(name: "生产 Web",
                     protocolType: .sftp,
                     host: "prod.example.com",
                     port: 22,
                     username: "deploy",
                     authType: .privateKey,
                     remotePath: "/var/www/html",
                     localPath: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Projects").path),
        SiteBookmark(name: "预发布",
                     protocolType: .sftp,
                     host: "staging.example.com",
                     port: 22,
                     username: "deploy",
                     authType: .password,
                     remotePath: "/var/www/staging",
                     localPath: FileManager.default.homeDirectoryForCurrentUser.path),
        SiteBookmark(name: "备份 NAS",
                     protocolType: .ftp,
                     host: "nas.local",
                     port: 21,
                     username: "backup",
                     authType: .password,
                     remotePath: "/volume1/backup",
                     localPath: FileManager.default.homeDirectoryForCurrentUser.path),
        SiteBookmark(name: "静态资源",
                     protocolType: .ftps,
                     host: "static.cdn.internal",
                     port: 990,
                     username: "cdn-user",
                     authType: .password,
                     remotePath: "/cdn/assets",
                     localPath: FileManager.default.homeDirectoryForCurrentUser.path)
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
