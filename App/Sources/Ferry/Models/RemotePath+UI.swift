import FerryCore
import Foundation

extension RemotePath: @retroactive CustomStringConvertible {
    public var description: String {
        displayString()
    }

    public init(_ string: String) {
        let isAbs = string.hasPrefix("/")
        self.init(wireBytes: Array(string.utf8), isAbsolute: isAbs)
    }

    public var parent: RemotePath {
        // 根目录
        if wireBytes == [0x2F] { return self }

        var bytes = wireBytes
        // 去除尾部斜杠
        while bytes.count > 1 && bytes.last == 0x2F {
            bytes.removeLast()
        }

        if let lastSlash = bytes.lastIndex(of: 0x2F) {
            if lastSlash == 0 {
                return RemotePath(wireBytes: [0x2F], isAbsolute: true)
            }
            return RemotePath(wireBytes: Array(bytes[..<lastSlash]), isAbsolute: isAbsolute)
        }
        return RemotePath(wireBytes: [0x2F], isAbsolute: true)
    }
}
