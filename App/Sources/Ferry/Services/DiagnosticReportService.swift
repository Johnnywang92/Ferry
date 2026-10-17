import FerryCore
import Foundation

/// 诊断日志分级
public enum DiagnosticLogLevel: String, Codable, Sendable {
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"
}

/// 诊断事件记录
public struct DiagnosticLogEntry: Identifiable, Codable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let level: DiagnosticLogLevel
    public let category: String
    public let message: String
    public let diagnosticCode: String?
    public let suggestedAdvice: String?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        level: DiagnosticLogLevel = .info,
        category: String,
        message: String,
        diagnosticCode: String? = nil,
        suggestedAdvice: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
        self.diagnosticCode = diagnosticCode
        self.suggestedAdvice = suggestedAdvice
    }
}

/// 诊断环形日志缓冲器（内存保留最近 N 条，v2.3 §470-471）。
public actor DiagnosticLogger {
    public static let shared = DiagnosticLogger()
    public static let maxEntries: Int = 300

    private var buffer: [DiagnosticLogEntry] = []

    public init() {}

    public func log(
        level: DiagnosticLogLevel = .info,
        category: String,
        message: String,
        diagnosticCode: String? = nil,
        suggestedAdvice: String? = nil
    ) {
        let entry = DiagnosticLogEntry(
            timestamp: Date(),
            level: level,
            category: category,
            message: message,
            diagnosticCode: diagnosticCode,
            suggestedAdvice: suggestedAdvice
        )
        buffer.append(entry)
        if buffer.count > Self.maxEntries {
            buffer.removeFirst(buffer.count - Self.maxEntries)
        }
    }

    public func entries() -> [DiagnosticLogEntry] {
        buffer
    }

    public func clear() {
        buffer.removeAll()
    }
}

/// 导出的诊断报告完整模型（v2.3 §470-472）。
public struct DiagnosticReport: Codable, Sendable {
    public let appVersion: String
    public let buildNumber: String
    public let osVersion: String
    public let machineArchitecture: String
    public let generatedAt: Date

    // 脱敏连接配置
    public struct ConnectionSnapshot: Codable, Sendable {
        public let protocolType: String
        public let host: String
        public let port: Int
        public let usernameMasked: String
        public let authType: String
        public let charset: String
        public let allowWeakAlgorithms: Bool
        public let currentState: String
    }
    public let connection: ConnectionSnapshot?

    // 协商参数
    public struct SessionSnapshot: Codable, Sendable {
        public let keyExchange: String
        public let hostKey: String
        public let encryption: String
        public let roundTripTimeMs: Int64?
    }
    public let session: SessionSnapshot?

    // 传输队列状态
    public struct QueueSnapshot: Codable, Sendable {
        public let totalTasks: Int
        public let runningCount: Int
        public let failedCount: Int
        public let pendingCount: Int
        public let uploadSpeedKBps: Double
        public let downloadSpeedKBps: Double
    }
    public let queue: QueueSnapshot

    // 事件日志
    public let logs: [DiagnosticLogEntry]
}

/// 诊断报告生成与错误建议映射服务（M6 交付，v2.3 §470-472）。
@MainActor
public final class DiagnosticReportService {
    public static let shared = DiagnosticReportService()

    public static let appVersion = "1.0.0-beta.1"
    public static let buildNumber = "100"

    private init() {}

    // MARK: - 错误码到可读建议映射表（v2.3 §472）

    public static func actionableAdvice(for error: RemoteError) -> String {
        error.actionableAdvice
    }

    // MARK: - 用户名与私密信息脱敏规则（v2.3 §471）

    public static func maskUsername(_ username: String) -> String {
        let trimmed = username.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "(空)" }
        if trimmed.count <= 2 {
            return String(trimmed.prefix(1)) + "*"
        }
        let prefix = String(trimmed.prefix(2))
        let suffix = String(trimmed.suffix(1))
        return "\(prefix)***\(suffix)"
    }

    // MARK: - 生成诊断报告

    public func buildReport(
        connectionService: ConnectionService,
        logs: [DiagnosticLogEntry]
    ) -> DiagnosticReport {
        let osVer = ProcessInfo.processInfo.operatingSystemVersionString
        #if arch(arm64)
        let arch = "Apple Silicon (arm64)"
        #elseif arch(x86_64)
        let arch = "Intel (x86_64)"
        #else
        let arch = "Unknown"
        #endif

        let connSnapshot: DiagnosticReport.ConnectionSnapshot?
        if let bookmark = connectionService.currentBookmark {
            connSnapshot = DiagnosticReport.ConnectionSnapshot(
                protocolType: bookmark.protocolType.rawValue,
                host: bookmark.host,
                port: bookmark.port,
                usernameMasked: Self.maskUsername(bookmark.username),
                authType: bookmark.authType.rawValue,
                charset: bookmark.charset.displayName,
                allowWeakAlgorithms: bookmark.allowWeakAlgorithms,
                currentState: connectionService.stateDescription
            )
        } else {
            connSnapshot = nil
        }

        let sessionSnapshot: DiagnosticReport.SessionSnapshot?
        if case .connected(_, let proto, let rtt) = connectionService.state {
            sessionSnapshot = DiagnosticReport.SessionSnapshot(
                keyExchange: proto,
                hostKey: "verified",
                encryption: "active",
                roundTripTimeMs: rtt
            )
        } else {
            sessionSnapshot = nil
        }

        let (run, fail, pend) = connectionService.queueSummary
        let (upSpeed, downSpeed) = connectionService.aggregateSpeed
        let total = connectionService.queueTasks.count

        let queueSnapshot = DiagnosticReport.QueueSnapshot(
            totalTasks: total,
            runningCount: run,
            failedCount: fail,
            pendingCount: pend,
            uploadSpeedKBps: upSpeed / 1024.0,
            downloadSpeedKBps: downSpeed / 1024.0
        )

        return DiagnosticReport(
            appVersion: Self.appVersion,
            buildNumber: Self.buildNumber,
            osVersion: osVer,
            machineArchitecture: arch,
            generatedAt: Date(),
            connection: connSnapshot,
            session: sessionSnapshot,
            queue: queueSnapshot,
            logs: logs
        )
    }

    public func exportReportJSON(report: DiagnosticReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(report)
    }
}

private extension ConnectionService {
    var stateDescription: String {
        switch state {
        case .disconnected: return "disconnected"
        case .connecting(let step): return "connecting(\(step))"
        case .connected(let name, let proto, let rtt): return "connected(\(name), \(proto), \(rtt)ms)"
        case .failed(let msg): return "failed(\(msg))"
        }
    }
}
