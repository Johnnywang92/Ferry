import Foundation

public final class LocalFileSystemService: Sendable {
    public static let shared = LocalFileSystemService()

    public init() {}

    public func listContents(at url: URL, showHidden: Bool = true) throws -> [LocalItem] {
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]

        let options: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
        let fileURLs = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: options
        )

        var items: [LocalItem] = []
        for fileURL in fileURLs {
            let resourceValues = try? fileURL.resourceValues(forKeys: Set(keys))
            let isDir = resourceValues?.isDirectory ?? false
            let isLink = resourceValues?.isSymbolicLink ?? false
            let size = Int64(resourceValues?.fileSize ?? 0)
            let modDate = resourceValues?.contentModificationDate

            items.append(LocalItem(
                url: fileURL,
                isDirectory: isDir,
                isSymbolicLink: isLink,
                size: size,
                modificationDate: modDate
            ))
        }

        // 目录排前面，随后按名称升序（不区分大小写）
        return items.sorted { a, b in
            if a.isDirectory != b.isDirectory {
                return a.isDirectory && !b.isDirectory
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    public func createDirectory(named name: String, in parentURL: URL) throws -> URL {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else {
            throw NSError(domain: "dev.ferry.app", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "文件夹名称不能为空且不能包含 '/'"
            ])
        }
        let target = parentURL.appendingPathComponent(trimmed, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        return target
    }

    public func resolvePath(_ rawPath: String, relativeTo baseURL: URL) throws -> URL {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return baseURL }

        let expanded = (trimmed as NSString).expandingTildeInPath
        let targetURL: URL
        if expanded.hasPrefix("/") {
            targetURL = URL(fileURLWithPath: expanded).standardizedFileURL
        } else {
            targetURL = baseURL.appendingPathComponent(expanded).standardizedFileURL
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: targetURL.path, isDirectory: &isDir) else {
            throw NSError(domain: "dev.ferry.app", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "本地路径不存在：\(targetURL.path)"
            ])
        }
        return isDir.boolValue ? targetURL : targetURL.deletingLastPathComponent()
    }

    public func renameItem(at sourceURL: URL, to newName: String) throws -> URL {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "dev.ferry.app", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "名称不能为空"
            ])
        }
        guard !trimmed.contains("/") else {
            throw NSError(domain: "dev.ferry.app", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "名称不能包含 '/'"
            ])
        }
        if trimmed == sourceURL.lastPathComponent {
            return sourceURL
        }
        let targetURL = sourceURL.deletingLastPathComponent().appendingPathComponent(trimmed)
        if FileManager.default.fileExists(atPath: targetURL.path) {
            throw NSError(domain: "dev.ferry.app", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "目标名称已存在：\(trimmed)"
            ])
        }
        try FileManager.default.moveItem(at: sourceURL, to: targetURL)
        return targetURL
    }

    public func deleteItem(at url: URL) throws {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            try FileManager.default.removeItem(at: url)
        }
    }
}
