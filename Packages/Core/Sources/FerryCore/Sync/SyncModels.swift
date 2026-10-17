import Foundation

/// 同步上次确认一致时的快照记录条目（v2.3 §390）。
/// 本地与远端分别记录 stat，因为上传后远端 mtime 不等于本地 mtime。
public struct SyncBaseEntry: Codable, Sendable, Hashable {
    public let key: ComparisonKey
    public let relativePath: String
    public var localSize: Int64?
    public var localMTime: Date?
    public var remoteSize: Int64?
    public var remoteMTime: Date?
    public var remoteMTimeIsReliable: Bool
    /// 内容哈希（SHA-256 十六进制字符串，可选，ADR-0000 I3）。
    public var contentHash: String?

    public init(
        key: ComparisonKey,
        relativePath: String,
        localSize: Int64? = nil,
        localMTime: Date? = nil,
        remoteSize: Int64? = nil,
        remoteMTime: Date? = nil,
        remoteMTimeIsReliable: Bool = true,
        contentHash: String? = nil
    ) {
        self.key = key
        self.relativePath = relativePath
        self.localSize = localSize
        self.localMTime = localMTime
        self.remoteSize = remoteSize
        self.remoteMTime = remoteMTime
        self.remoteMTimeIsReliable = remoteMTimeIsReliable
        self.contentHash = contentHash
    }
}

/// 某次同步基线快照（v2.3 §388）。
public struct SyncBaseSnapshot: Codable, Sendable {
    public var id: UUID
    public var localRootPath: String
    public var remoteRootPath: String
    public var entries: [ComparisonKey: SyncBaseEntry]
    public var lastSyncTime: Date

    public init(
        id: UUID = UUID(),
        localRootPath: String,
        remoteRootPath: String,
        entries: [ComparisonKey: SyncBaseEntry] = [:],
        lastSyncTime: Date = Date()
    ) {
        self.id = id
        self.localRootPath = localRootPath
        self.remoteRootPath = remoteRootPath
        self.entries = entries
        self.lastSyncTime = lastSyncTime
    }
}

/// 冲突原因枚举（v2.3 §411-424）。
public enum SyncConflictReason: String, Codable, Sendable {
    case bothModifiedContentDifferent = "两侧同时修改且内容不同"
    case bothCreatedContentDifferent = "两侧同时新建且内容不同"
    case deletedAndModified = "一侧已删除而另一侧已修改"
    case kindMismatch = "类型冲突（一侧为文件，另一侧为目录）"
    case keyCollision = "大小写或字符归一化碰撞冲突"
}

/// 计划建议的操作（v2.3 §411-424 完整真值表）。
public enum SyncAction: String, Codable, Sendable {
    case none = "无需操作"
    case upload = "上行上传"
    case download = "下行下载"
    case deleteRemote = "远端删除"
    case deleteLocal = "本地删除"
    case conflict = "存在冲突"
    case needsVerification = "需比对内容"
}

/// 用户在冲突时的解决决策（v2.3 §428）。
public enum SyncConflictResolution: String, Codable, Sendable, CaseIterable {
    case useLocal = "以本地为准"
    case useRemote = "以远端为准"
    case keepBoth = "保留双份"
    case skip = "跳过此项"
}

/// 同步时某侧条目的轻量快照。
public struct SyncItemSnapshot: Codable, Sendable, Hashable {
    public let relativePath: String
    public let isDirectory: Bool
    public let size: Int64?
    public let modificationDate: Date?
    public let mtimeIsReliable: Bool
    public var contentHash: String?

    public init(
        relativePath: String,
        isDirectory: Bool,
        size: Int64?,
        modificationDate: Date?,
        mtimeIsReliable: Bool,
        contentHash: String? = nil
    ) {
        self.relativePath = relativePath
        self.isDirectory = isDirectory
        self.size = size
        self.modificationDate = modificationDate
        self.mtimeIsReliable = mtimeIsReliable
        self.contentHash = contentHash
    }
}

/// 差异计划中的单项（v2.3 §432）。
public struct SyncDiffItem: Identifiable, Sendable, Codable {
    public var id: String { relativePath }
    public let relativePath: String
    public let comparisonKey: ComparisonKey
    public let localItem: SyncItemSnapshot?
    public let remoteItem: SyncItemSnapshot?
    public let baseEntry: SyncBaseEntry?
    public var action: SyncAction
    public var conflictReason: SyncConflictReason?
    public var userResolution: SyncConflictResolution?

    public init(
        relativePath: String,
        comparisonKey: ComparisonKey,
        localItem: SyncItemSnapshot?,
        remoteItem: SyncItemSnapshot?,
        baseEntry: SyncBaseEntry?,
        action: SyncAction,
        conflictReason: SyncConflictReason? = nil,
        userResolution: SyncConflictResolution? = nil
    ) {
        self.relativePath = relativePath
        self.comparisonKey = comparisonKey
        self.localItem = localItem
        self.remoteItem = remoteItem
        self.baseEntry = baseEntry
        self.action = action
        self.conflictReason = conflictReason
        self.userResolution = userResolution
    }
}

/// 同步选项配置（v2.3 §429）。
public struct SyncOptions: Sendable {
    /// 是否允许删除操作（默认 false，必须由用户显式开启，v2.3 §429）。
    public var allowDeletions: Bool
    /// 是否强制比对所有可疑文件内容（默认 false，ADR-0000 I3）。
    public var forceCompareHash: Bool
    /// 路径比较策略。
    public var pathPolicy: PathPolicy

    public init(
        allowDeletions: Bool = false,
        forceCompareHash: Bool = false,
        pathPolicy: PathPolicy = .posix
    ) {
        self.allowDeletions = allowDeletions
        self.forceCompareHash = forceCompareHash
        self.pathPolicy = pathPolicy
    }
}

/// 差异计划整体模型（v2.3 §432）。
public struct DiffPlan: Codable, Sendable {
    public let localRootURL: URL
    public let remoteRootPath: RemotePath
    public var items: [SyncDiffItem]
    public let createdAt: Date

    public init(
        localRootURL: URL,
        remoteRootPath: RemotePath,
        items: [SyncDiffItem],
        createdAt: Date = Date()
    ) {
        self.localRootURL = localRootURL
        self.remoteRootPath = remoteRootPath
        self.items = items
        self.createdAt = createdAt
    }

    public var uploadCount: Int {
        items.filter { $0.action == .upload }.count
    }

    public var downloadCount: Int {
        items.filter { $0.action == .download }.count
    }

    public var deleteRemoteCount: Int {
        items.filter { $0.action == .deleteRemote }.count
    }

    public var deleteLocalCount: Int {
        items.filter { $0.action == .deleteLocal }.count
    }

    public var conflictCount: Int {
        items.filter { $0.action == .conflict }.count
    }

    public var unchangedCount: Int {
        items.filter { $0.action == .none }.count
    }

    public var totalActionableCount: Int {
        items.filter { $0.action != .none }.count
    }
}
