import Foundation

/// 后端固有能力的静态声明与登录后协商的动态结果共用同一类型：
/// `declaredCapabilities` 是后端上限，`negotiatedCapabilities` 才是本次会话可用集。
public struct RemoteCapabilities: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let resumableDownload      = RemoteCapabilities(rawValue: 1 << 0)
    public static let resumableUpload        = RemoteCapabilities(rawValue: 1 << 1)
    public static let permissions            = RemoteCapabilities(rawValue: 1 << 2)
    public static let ownership              = RemoteCapabilities(rawValue: 1 << 3)
    public static let symbolicLinks          = RemoteCapabilities(rawValue: 1 << 4)
    public static let lstat                  = RemoteCapabilities(rawValue: 1 << 5)
    public static let directoryStat          = RemoteCapabilities(rawValue: 1 << 6)
    public static let atomicRenameOverwrite  = RemoteCapabilities(rawValue: 1 << 7)
    public static let serverSideCopy         = RemoteCapabilities(rawValue: 1 << 8)
    public static let reliableMTime          = RemoteCapabilities(rawValue: 1 << 9)
    public static let hashing                = RemoteCapabilities(rawValue: 1 << 10)
    public static let charsetNegotiation     = RemoteCapabilities(rawValue: 1 << 11)
}

public enum RemoteItemKind: UInt8, Sendable, Hashable {
    case file
    case directory
    case symbolicLink
    /// 既不是文件也不是目录也不是链的条目（FIFO、socket、设备节点）。
    /// 注意这与 `.unknown` 不同：那是"服务器没说"。
    case other
    /// 服务器这次压根没给权限位，也没有可降级用的 longentry，条目类型未知。
    ///
    /// 有这个格是因为不能拿猜测填类型：把未知判成 `file`，同步引擎会去读一个
    /// 其实是目录的条目；判成 `directory` 又会递归进一个文件。
    case unknown
}

/// 可信度标记第一天就有：同步引擎用 mtime 判断"未修改"，
/// 把不可信的 mtime 当可信会产生"看起来没变、实际已改"的静默数据丢失。
public struct RemoteItem: Sendable, Hashable {
    public let path: RemotePath
    public let kind: RemoteItemKind
    public let size: Int64?
    public let modificationDate: Date?

    /// FTP 目录列表常给估算值。
    public let sizeIsExact: Bool
    /// 部分 FTP 服务器不返回 MDTM；SFTP 只有秒级精度。
    public let mtimeIsReliable: Bool

    /// 软链指向的原文，未解析（相对目标就是相对目标）。非软链为 nil。
    ///
    /// 类型是 `RemotePath` 而不是 `String`：目标本身可能含非 UTF-8 字节
    /// （M0b-01 的迷宫里就有一条链指向那个 GBK 名字），一过硬编码字符集的 `String`
    /// 就把 R5 的"字节权威"破掉了。显示走 `displayString(using:)`。
    ///
    /// 目录列表**不会**填这一格：readdir 那一个包里根本没有目标，
    /// 要拿就得每条链一次 `readlink` 往返。填它的地方是
    /// `RemoteDirectoryListing` 的解析缓存（M1-05 §4）。
    public let linkTarget: RemotePath?
    public let permissions: UInt16?
    /// 数字 id。SFTP v3 只给数字，不给名字。
    ///
    /// `owner` / `group` 这两个 `String` 在 SFTP 侧一律是 nil：协议里没有名字映射，
    /// 而 `owner-name@openssh.com` 那套扩展属性被 libssh2 解析后直接丢掉
    /// （`sftp_bin2attr` 只把扩展段用来推进游标，见 sftp.c 的 EXTENDED 分支），
    /// 客户端拿不到。留着这两个字段是给 FTP 用的——`LIST` 里有用户名和组名。
    public let uid: UInt32?
    public let gid: UInt32?
    public let owner: String?
    public let group: String?

    public init(
        path: RemotePath,
        kind: RemoteItemKind,
        size: Int64?,
        modificationDate: Date?,
        sizeIsExact: Bool,
        mtimeIsReliable: Bool,
        linkTarget: RemotePath? = nil,
        permissions: UInt16? = nil,
        uid: UInt32? = nil,
        gid: UInt32? = nil,
        owner: String? = nil,
        group: String? = nil
    ) {
        self.path = path
        self.kind = kind
        self.size = size
        self.modificationDate = modificationDate
        self.sizeIsExact = sizeIsExact
        self.mtimeIsReliable = mtimeIsReliable
        self.linkTarget = linkTarget
        self.permissions = permissions
        self.uid = uid
        self.gid = gid
        self.owner = owner
        self.group = group
    }

    /// diff 的稳定标识：用原始字节而非展示串，避免非 UTF-8 文件名互相撞车。
    public var id: [UInt8] { path.wireBytes }
}

public struct RemoteVolumeInfo: Sendable, Hashable {
    public let totalBytes: Int64?
    public let availableBytes: Int64?

    public init(totalBytes: Int64?, availableBytes: Int64?) {
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
    }
}
