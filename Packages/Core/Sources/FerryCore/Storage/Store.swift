import Darwin
import Foundation

/// 原子 JSON 持久化容器（v2.3 §存储）。
///
/// MVP 不使用数据库，站点列表、偏好与后续传输队列快照均经由本 Actor 序列化读写，
/// 避免并发写入与 `.atomic` 临时文件 rename 瞬间的读写竞态（Swift 6 严格并发）。
/// 父目录权限固定 `0700`、落盘文件固定 `0600`。
public actor Store<T: Codable & Sendable> {
    public let url: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(url: URL) {
        self.url = url
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
    }

    public func read() throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try decoder.decode(T.self, from: data)
    }

    public func write(_ value: T) throws {
        let dir = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
        _ = Darwin.chmod(url.path, mode_t(0o600))
    }

    public func delete() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
