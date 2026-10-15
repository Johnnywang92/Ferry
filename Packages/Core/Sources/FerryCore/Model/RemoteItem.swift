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
    case other
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

    public let linkTarget: String?
    public let permissions: UInt16?
    public let owner: String?
    public let group: String?

    public init(
        path: RemotePath,
        kind: RemoteItemKind,
        size: Int64?,
        modificationDate: Date?,
        sizeIsExact: Bool,
        mtimeIsReliable: Bool,
        linkTarget: String? = nil,
        permissions: UInt16? = nil,
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
