import Foundation

/// 续传置信度等级（v2.3 §334）。
///
/// 方案红线："不要砍 M3 的续传置信度校验"。
/// SFTP 的 mtime 通常只有秒级（uint32），仅靠时间比对可能无法识别同秒内的变动。
/// 必须通过起点双采样与终点复查，精确判定续传是否完整可信。
public enum ResumeConfidence: Sendable, Codable, Hashable, Equatable {
    /// 高置信度：两端采样严格自洽、校验全部一致。
    case high
    /// 低置信度：存在潜在不确定性（例如 mtime 不可靠、同秒内变动可疑），但数据传输无致命冲突。
    case low(reason: String)
    /// 续传无效：元数据矛盾（例如远端源文件变小、被删除、内容被截断），不能续传，必须重头开始。
    case invalid(reason: String)
}

/// 续传起点快照（双采样中的第一采样）。
public struct ResumeSnapshot: Sendable, Codable, Hashable, Equatable {
    public let size: Int64
    public let modificationDate: Date?
    public let mtimeIsReliable: Bool

    public init(size: Int64, modificationDate: Date?, mtimeIsReliable: Bool) {
        self.size = size
        self.modificationDate = modificationDate
        self.mtimeIsReliable = mtimeIsReliable
    }
}

/// 传输方向。
public enum TransferDirection: String, Sendable, Codable, CaseIterable {
    case upload = "上传"
    case download = "下载"
}

/// 传输状态机（v2.3 §319）。
///
/// `pending` → `running` → `completed`；
/// `running` 可转 `paused`、`failed`、`cancelled`；
/// `paused` 可回到 `pending` 续传。
///
/// `failed` 区分可重试与不可重试：只有 `.network` 类错误可自动重试。
public enum TransferStatus: Sendable, Codable, Hashable, Equatable {
    case pending
    case running
    case paused
    case completed(confidence: ResumeConfidence)
    case failed(message: String, isRetryable: Bool)
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .completed, .cancelled: return true
        default: return false
        }
    }

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    public var isPaused: Bool {
        if case .paused = self { return true }
        return false
    }

    public var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    public var isCompleted: Bool {
        if case .completed = self { return true }
        return false
    }
}

/// 传输任务持久化记录（用于 JSON 存储与崩溃恢复，v2.3 §344）。
public struct TransferTaskRecord: Identifiable, Sendable, Codable, Equatable {
    public let id: UUID
    public let direction: TransferDirection
    public let localURL: URL
    public let remotePath: RemotePath
    public var status: TransferStatus
    public var bytesDone: Int64
    public var totalBytes: Int64?
    public var partFileName: String?
    public var initialSnapshot: ResumeSnapshot?
    public var retryCount: Int
    public let createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(),
                direction: TransferDirection,
                localURL: URL,
                remotePath: RemotePath,
                status: TransferStatus = .pending,
                bytesDone: Int64 = 0,
                totalBytes: Int64? = nil,
                partFileName: String? = nil,
                initialSnapshot: ResumeSnapshot? = nil,
                retryCount: Int = 0,
                createdAt: Date = Date(),
                updatedAt: Date = Date()) {
        self.id = id
        self.direction = direction
        self.localURL = localURL
        self.remotePath = remotePath
        self.status = status
        self.bytesDone = bytesDone
        self.totalBytes = totalBytes
        self.partFileName = partFileName
        self.initialSnapshot = initialSnapshot
        self.retryCount = retryCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 文件显示名。
    public var fileName: String {
        switch direction {
        case .upload:
            return localURL.lastPathComponent
        case .download:
            return remotePath.lastComponent?.displayString() ?? remotePath.displayString()
        }
    }
}

/// 运行时传输快照（带速率、ETA 估算与进度，供 UI 订阅与展示，U8/U11）。
public struct TransferTaskState: Identifiable, Sendable, Equatable {
    public let record: TransferTaskRecord
    public let speedBytesPerSec: Double
    public let etaSeconds: TimeInterval?

    public var id: UUID { record.id }
    public var direction: TransferDirection { record.direction }
    public var fileName: String { record.fileName }
    public var status: TransferStatus { record.status }
    public var bytesDone: Int64 { record.bytesDone }
    public var totalBytes: Int64? { record.totalBytes }

    public init(record: TransferTaskRecord, speedBytesPerSec: Double = 0, etaSeconds: TimeInterval? = nil) {
        self.record = record
        self.speedBytesPerSec = speedBytesPerSec
        self.etaSeconds = etaSeconds
    }

    public var progressFraction: Double {
        guard let total = totalBytes, total > 0 else {
            return record.status.isCompleted ? 1.0 : 0.0
        }
        return min(max(Double(bytesDone) / Double(total), 0.0), 1.0)
    }

    public var formattedSpeed: String {
        guard speedBytesPerSec > 0 else { return "0 KB/s" }
        let formatted = ByteCountFormatter.string(fromByteCount: Int64(speedBytesPerSec), countStyle: .file)
        return "\(formatted)/s"
    }

    public var formattedETA: String? {
        guard let eta = etaSeconds, eta > 0 else { return nil }
        if eta < 60 {
            return "剩余 \(Int(eta.rounded())) 秒"
        } else if eta < 3600 {
            let minutes = Int(eta / 60)
            let seconds = Int(eta.truncatingRemainder(dividingBy: 60))
            return "剩余 \(minutes) 分 \(seconds) 秒"
        } else {
            let hours = Int(eta / 3600)
            let minutes = Int((eta.truncatingRemainder(dividingBy: 3600)) / 60)
            return "剩余 \(hours) 小时 \(minutes) 分"
        }
    }
}
