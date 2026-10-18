import Foundation

/// 定时计划周期频次。
public enum ScheduleFrequency: Codable, Sendable, Equatable, Hashable {
    case hourly(minute: Int)
    case daily(hour: Int, minute: Int)
    case intervalMinutes(Int)
    case manual

    @MainActor
    public var displayName: String {
        switch self {
        case .hourly(let m):
            return L10n.format("每小时（第 %02d 分）", "Hourly (at :%02d)", m)
        case .daily(let h, let m):
            return L10n.format("每天 %02d:%02d", "Daily at %02d:%02d", h, m)
        case .intervalMinutes(let min):
            return L10n.format("每隔 %d 分钟", "Every %d min", min)
        case .manual:
            return L10n.tr("仅手动触发", "Manual only")
        }
    }
}

/// 定时同步模式。
public enum ScheduledSyncMode: String, Codable, Sendable, CaseIterable {
    case uploadMirror = "上传镜像（覆盖远端）"
    case downloadMirror = "下载镜像（覆盖本地）"
    case bidirectional = "双向增量同步"

    @MainActor
    public var displayName: String {
        switch self {
        case .uploadMirror: return L10n.tr("上传镜像（本地覆盖远端）", "Upload Mirror (Local overrides Remote)")
        case .downloadMirror: return L10n.tr("下载镜像（远端覆盖本地）", "Download Mirror (Remote overrides Local)")
        case .bidirectional: return L10n.tr("双向增量同步", "Two-way Incremental Sync")
        }
    }
}

/// 定时同步与备份计划模型。
public struct ScheduledTask: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    /// 源端书签 ID（nil 表示本地目录）
    public var sourceBookmarkID: UUID?
    public var sourcePath: String
    /// 目标端书签 ID（nil 表示本地目录）
    public var destinationBookmarkID: UUID?
    public var destinationPath: String

    public var frequency: ScheduleFrequency
    public var syncMode: ScheduledSyncMode
    public var isEnabled: Bool

    public var lastRunTime: Date?
    public var lastRunStatus: String?
    public var nextRunTime: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        sourceBookmarkID: UUID? = nil,
        sourcePath: String,
        destinationBookmarkID: UUID? = nil,
        destinationPath: String,
        frequency: ScheduleFrequency = .daily(hour: 3, minute: 0),
        syncMode: ScheduledSyncMode = .uploadMirror,
        isEnabled: Bool = true,
        lastRunTime: Date? = nil,
        lastRunStatus: String? = nil,
        nextRunTime: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.sourceBookmarkID = sourceBookmarkID
        self.sourcePath = sourcePath
        self.destinationBookmarkID = destinationBookmarkID
        self.destinationPath = destinationPath
        self.frequency = frequency
        self.syncMode = syncMode
        self.isEnabled = isEnabled
        self.lastRunTime = lastRunTime
        self.lastRunStatus = lastRunStatus
        self.nextRunTime = nextRunTime ?? Self.calculateNextRunTime(for: frequency, from: Date())
    }

    /// 根据频次推算下次触发时间
    public static func calculateNextRunTime(for freq: ScheduleFrequency, from date: Date = Date()) -> Date? {
        let calendar = Calendar.current
        switch freq {
        case .manual:
            return nil
        case .intervalMinutes(let mins):
            return date.addingTimeInterval(TimeInterval(max(1, mins) * 60))
        case .hourly(let minute):
            var comps = calendar.dateComponents([.year, .month, .day, .hour], from: date)
            comps.minute = minute
            comps.second = 0
            if let target = calendar.date(from: comps) {
                return target > date ? target : calendar.date(byAdding: .hour, value: 1, to: target)
            }
            return date.addingTimeInterval(3600)
        case .daily(let hour, let minute):
            var comps = calendar.dateComponents([.year, .month, .day], from: date)
            comps.hour = hour
            comps.minute = minute
            comps.second = 0
            if let target = calendar.date(from: comps) {
                return target > date ? target : calendar.date(byAdding: .day, value: 1, to: target)
            }
            return date.addingTimeInterval(86400)
        }
    }
}
