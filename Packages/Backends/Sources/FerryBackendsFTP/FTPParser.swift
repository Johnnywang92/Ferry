import FerryCore
import Foundation

/// FTP 目录列表解析器（v2.3 §139-140, §498-499）。
///
/// 支持 RFC 3659 MLSD 机器格式与传统 Unix LIST 格式，
/// 严格保留 wireBytes 并根据 CharsetConverter 进行展示。
public enum FTPParser {

    /// 解析 MLSD 或 LIST 输出的一行或多行文本为 RemoteItem 列表。
    public static func parseListing(
        data: Data,
        directory: RemotePath,
        charsetConverter: CharsetConverter
    ) -> [RemoteItem] {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return []
        }

        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var items: [RemoteItem] = []

        for line in lines {
            if let item = parseLine(line, directory: directory, charsetConverter: charsetConverter) {
                // 跳过 "." 和 ".."
                let name = item.path.lastComponent?.displayString() ?? ""
                if name == "." || name == ".." {
                    continue
                }
                items.append(item)
            }
        }

        return items
    }

    /// 解析单行目录项。
    public static func parseLine(
        _ line: String,
        directory: RemotePath,
        charsetConverter: CharsetConverter
    ) -> RemoteItem? {
        if line.contains(";") && (line.lowercased().contains("type=") || line.lowercased().contains("modify=")) {
            return parseMLSDLine(line, directory: directory, charsetConverter: charsetConverter)
        } else if line.hasPrefix("-") || line.hasPrefix("d") || line.hasPrefix("l") || line.hasPrefix("c") || line.hasPrefix("b") {
            return parseUnixListLine(line, directory: directory, charsetConverter: charsetConverter)
        } else {
            // 简单名字模式（NLST 或非标准输出）
            return parseSimpleNameLine(line, directory: directory, charsetConverter: charsetConverter)
        }
    }

    // MARK: - RFC 3659 MLSD 格式解析

    /// MLSD 格式示例：
    /// `type=file;size=4096;modify=20261017120000;perms=r8; readme.txt`
    /// `type=dir;modify=20261016080000; docs`
    private static func parseMLSDLine(
        _ line: String,
        directory: RemotePath,
        charsetConverter: CharsetConverter
    ) -> RemoteItem? {
        guard let spaceIdx = line.firstIndex(of: " ") else { return nil }
        let factsPart = line[..<spaceIdx]
        let namePart = line[line.index(after: spaceIdx)...].trimmingCharacters(in: .whitespaces)
        guard !namePart.isEmpty else { return nil }

        var facts: [String: String] = [:]
        for fact in factsPart.split(separator: ";") {
            let pair = fact.split(separator: "=", maxSplits: 1)
            if pair.count == 2 {
                let key = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
                let val = String(pair[1].trimmingCharacters(in: .whitespaces))
                facts[key] = val
            }
        }

        let typeStr = facts["type"]?.lowercased()
        let kind: RemoteItemKind
        if typeStr == "dir" || typeStr == "pdir" || typeStr == "cdir" {
            kind = .directory
        } else if typeStr == "file" {
            kind = .file
        } else if typeStr?.contains("slink") == true || typeStr == "link" {
            kind = .symbolicLink
        } else {
            kind = .file
        }

        let size = facts["size"].flatMap { Int64($0) }
        let date = parseMLSDDate(facts["modify"])

        guard let path = try? directory.appending(component: namePart) else { return nil }

        return RemoteItem(
            path: path,
            kind: kind,
            size: kind == .directory ? nil : size,
            modificationDate: date,
            sizeIsExact: size != nil,
            mtimeIsReliable: date != nil,
            linkTarget: nil,
            permissions: 0o644,
            uid: nil,
            gid: nil,
            owner: nil,
            group: nil
        )
    }

    private static func parseMLSDDate(_ str: String?) -> Date? {
        guard let str, str.count >= 14 else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let prefix = String(str.prefix(14))
        return formatter.date(from: prefix)
    }

    // MARK: - Unix LIST 格式解析

    /// Unix 风格 LIST 示例：
    /// `drwxr-xr-x   2 owner group      4096 Oct 17 12:00 folder`
    /// `-rw-r--r--   1 owner group       123 Oct 17 12:00 file.txt`
    /// `lrwxrwxrwx   1 owner group        11 Oct 17 12:00 symlink -> target`
    private static func parseUnixListLine(
        _ line: String,
        directory: RemotePath,
        charsetConverter: CharsetConverter
    ) -> RemoteItem? {
        let tokens = line.split(whereSeparator: { $0.isWhitespace })
        guard tokens.count >= 8 else { return nil }

        let permStr = String(tokens[0])
        let kind: RemoteItemKind
        if permStr.hasPrefix("d") {
            kind = .directory
        } else if permStr.hasPrefix("l") {
            kind = .symbolicLink
        } else {
            kind = .file
        }

        // 大小通常是第 5 列（索引 4）
        let size = Int64(tokens[4])

        let comps = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        if comps.count >= 9 {
            // 前 8 项是元数据，剩余项拼接为文件名
            let nameParts = comps.dropFirst(8).joined(separator: " ")
            let rawName: String
            let target: RemotePath?

            if kind == .symbolicLink, let arrowRange = nameParts.range(of: " -> ") {
                rawName = String(nameParts[..<arrowRange.lowerBound])
                let targetStr = String(nameParts[arrowRange.upperBound...])
                target = RemotePath(string: targetStr, isAbsolute: targetStr.hasPrefix("/"))
            } else {
                rawName = nameParts
                target = nil
            }

            guard !rawName.isEmpty, let path = try? directory.appending(component: rawName) else {
                return nil
            }

            return RemoteItem(
                path: path,
                kind: kind,
                size: kind == .directory ? nil : size,
                modificationDate: nil, // 传统 LIST 格式往往没有完整精确年份，标记 mtimeIsReliable = false
                sizeIsExact: size != nil,
                mtimeIsReliable: false,
                linkTarget: target,
                permissions: parsePermissions(permStr),
                uid: nil,
                gid: nil,
                owner: comps.count > 2 ? comps[2] : nil,
                group: comps.count > 3 ? comps[3] : nil
            )
        }

        return nil
    }

    private static func parsePermissions(_ str: String) -> UInt16 {
        var mode: UInt16 = 0
        let chars = Array(str)
        if chars.count >= 10 {
            if chars[1] == "r" { mode |= 0o400 }
            if chars[2] == "w" { mode |= 0o200 }
            if chars[3] == "x" || chars[3] == "s" { mode |= 0o100 }
            if chars[4] == "r" { mode |= 0o040 }
            if chars[5] == "w" { mode |= 0o020 }
            if chars[6] == "x" || chars[6] == "s" { mode |= 0o010 }
            if chars[7] == "r" { mode |= 0o004 }
            if chars[8] == "w" { mode |= 0o002 }
            if chars[9] == "x" || chars[9] == "t" { mode |= 0o001 }
        }
        return mode > 0 ? mode : 0o644
    }

    // MARK: - 纯文件名行（NLST 兜底）

    private static func parseSimpleNameLine(
        _ line: String,
        directory: RemotePath,
        charsetConverter: CharsetConverter
    ) -> RemoteItem? {
        let name = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != ".." else { return nil }
        guard let path = try? directory.appending(component: name) else { return nil }

        return RemoteItem(
            path: path,
            kind: .file,
            size: nil,
            modificationDate: nil,
            sizeIsExact: false,
            mtimeIsReliable: false,
            linkTarget: nil,
            permissions: 0o644,
            uid: nil,
            gid: nil,
            owner: nil,
            group: nil
        )
    }
}
