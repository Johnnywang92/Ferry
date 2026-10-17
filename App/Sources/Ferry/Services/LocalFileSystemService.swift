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
}
