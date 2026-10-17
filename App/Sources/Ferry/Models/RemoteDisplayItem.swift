import FerryCore
import Foundation

public struct RemoteDisplayItem: Identifiable, Hashable, Sendable {
    public var id: String {
        path.wireBytes.map { String(format: "%02x", $0) }.joined()
    }
    public let name: String
    public let rawNameBytes: [UInt8]
    public let decodedOrigin: CharsetConverter.Decoded
    public let path: RemotePath
    public let isDirectory: Bool
    public let isSymbolicLink: Bool
    public let size: Int64?
    public let mtime: Date?
    public let permissionsString: String
    public let linkTarget: String?

    public var isHidden: Bool {
        rawNameBytes.first == 0x2E
    }

    public var modificationDate: Date? {
        mtime
    }


    public init(item: RemoteItem, charsetConverter: CharsetConverter, linkResolution: RemoteDirectoryListing.LinkResolution? = nil) {
        // 从 path.wireBytes 中提取文件名部分（权威字节，不做 String 往返）
        let wire = item.path.wireBytes
        let nameBytes: [UInt8]
        if let lastSlash = wire.lastIndex(of: 0x2F), lastSlash + 1 < wire.count {
            nameBytes = Array(wire[(lastSlash + 1)...])
        } else if wire == [0x2F] {
            nameBytes = [0x2F]
        } else {
            nameBytes = wire
        }

        self.rawNameBytes = nameBytes
        self.decodedOrigin = charsetConverter.decode(nameBytes)
        self.name = charsetConverter.displayString(nameBytes)
        self.path = item.path
        self.isDirectory = (item.kind == .directory)
        self.isSymbolicLink = (item.kind == .symbolicLink)
        self.size = item.size
        self.mtime = item.modificationDate

        if let perm = item.permissions {
            self.permissionsString = Self.formatPermissions(perm, isDirectory: self.isDirectory, isLink: self.isSymbolicLink)
        } else {
            self.permissionsString = "---------"
        }

        if let res = linkResolution {
            if let resolved = res.resolved {
                self.linkTarget = resolved.displayString(using: charsetConverter)
            } else if let target = res.target {
                self.linkTarget = "\(target.displayString(using: charsetConverter)) (成环或未展开)"
            } else {
                self.linkTarget = "(无法读取软链)"
            }
        } else {
            self.linkTarget = nil
        }
    }

    public var formattedSize: String {
        if isDirectory { return "--" }
        guard let size else { return "--" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    public var formattedDate: String {
        guard let date = mtime else { return "--" }
        return FerryDateFormatter.format(date)
    }

    public static func formatPermissions(_ mode: UInt16, isDirectory: Bool, isLink: Bool) -> String {
        let chars: [(UInt16, Character)] = [
            (0o400, "r"), (0o200, "w"), (0o100, "x"),
            (0o040, "r"), (0o020, "w"), (0o010, "x"),
            (0o004, "r"), (0o002, "w"), (0o001, "x")
        ]
        var s = ""
        for (mask, char) in chars {
            if (mode & mask) != 0 {
                s.append(char)
            } else {
                s.append("-")
            }
        }
        return s
    }
}
