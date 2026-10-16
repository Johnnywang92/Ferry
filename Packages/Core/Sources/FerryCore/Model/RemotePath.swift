import Foundation

/// 路径的权威表示是服务器返回的原始字节。NFC 只用于比较，绝不用于寻址；
/// 否则 Linux 上并存的 NFC 与 NFD 同形文件会被错误合并成一个。
public struct RemotePath: Hashable, Sendable {
    /// 发往服务器的唯一依据；`stat`/`rename`/`remove` 一律使用它。
    public let wireBytes: [UInt8]

    public let isAbsolute: Bool

    public init(wireBytes: [UInt8], isAbsolute: Bool) {
        self.wireBytes = wireBytes
        self.isAbsolute = isAbsolute
    }

    /// 从 Swift 字符串构造。含 NUL 的路径在 POSIX 下不合法，直接拒绝。
    public init?(string: String, isAbsolute: Bool) {
        guard !string.utf8.contains(0) else { return nil }
        self.wireBytes = Array(string.utf8)
        self.isAbsolute = isAbsolute
    }

    /// 仅供展示。非法 UTF-8 或含 NUL 时整条以 `\xNN` 呈现，不做有损替换。
    public func displayString() -> String {
        displayString(using: CharsetConverter(charset: .utf8))
    }

    /// 按连接所选字符集展示。解码只影响显示，`wireBytes` 一个字节都不动。
    public func displayString(using converter: CharsetConverter) -> String {
        converter.displayString(wireBytes)
    }
}

/// 跨端对齐用的派生键，由 `wireBytes` 经 NFC（及可选大小写折叠）得到。
/// 永不回写远端。
public struct ComparisonKey: Hashable, Sendable {
    public let bytes: [UInt8]

    init(wireBytes: [UInt8], pathPolicy: PathPolicy) {
        let string = String(decoding: wireBytes, as: UTF8.self)
        let normalized = pathPolicy.normalizeForCompare
            ? string.precomposedStringWithCanonicalMapping
            : string
        let folded = pathPolicy.caseSensitive ? normalized : normalized.lowercased()
        self.bytes = Array(folded.utf8)
    }
}

/// 大小写与归一化策略属于连接/文件系统，不属于单个路径实例。
public struct PathPolicy: Sendable, Hashable {
    public let caseSensitive: Bool
    public let normalizeForCompare: Bool

    public init(caseSensitive: Bool, normalizeForCompare: Bool) {
        self.caseSensitive = caseSensitive
        self.normalizeForCompare = normalizeForCompare
    }

    /// POSIX 服务器（本次五台全是）。Windows/Serv-U 那类不区分大小写的
    /// 由站点配置覆盖，M3 兼容性阶段补。
    public static let posix = PathPolicy(caseSensitive: true, normalizeForCompare: true)

    public func key(for path: RemotePath) -> ComparisonKey {
        ComparisonKey(wireBytes: path.wireBytes, pathPolicy: self)
    }
}
