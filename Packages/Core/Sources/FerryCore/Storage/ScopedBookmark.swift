import Foundation

/// 本地路径与可选安全作用域书签数据（ADR-0000 D1、v2.3 §阻塞决策与分发）。
///
/// 数据层从第一天起把本地路径存为 `ScopedBookmark`（`path` + 可选 `bookmarkData`）：
/// - 非沙盒模式（D1=A）下直接以 `path` 访问，用户在 `NSOpenPanel` 选目录时一并尝试生成书签数据；
/// - 未来升级沙盒模式（D1=B）时无需迁移数据模型，仅需对 `bookmarkData == nil` 或失效的条目触发重授权。
public struct ScopedBookmark: Codable, Hashable, Sendable {
    public var path: String
    public var bookmarkData: Data?

    public init(path: String, bookmarkData: Data? = nil) {
        self.path = path
        self.bookmarkData = bookmarkData
    }

    public init(url: URL, includeBookmarkData: Bool = false) {
        self.path = url.path
        if includeBookmarkData {
            self.bookmarkData = try? url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } else {
            self.bookmarkData = nil
        }
    }

    public var isEmpty: Bool {
        path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 展开 `~` 后的本地路径字符串。
    public var expandedPath: String {
        (path as NSString).expandingTildeInPath
    }

    /// 解析为本地 `URL`；若带有 `bookmarkData` 则优先用书签解析并报告是否陈旧。
    public func resolveURL() -> (url: URL, isStale: Bool) {
        if let data = bookmarkData {
            var stale = false
            if let resolved = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                return (resolved, stale)
            }
        }
        return (URL(fileURLWithPath: expandedPath), false)
    }
}
