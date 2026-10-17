import Foundation

/// 词法解析失败。这些错误全部来自调用方的输入或配置，不需要访问远端就能判定，
/// 因此必须在发出任何请求之前抛出：路径出错就是全盘错。
public enum PathResolutionError: Error, Hashable, Sendable {
    /// POSIX 以 NUL 截断路径，含 NUL 的字节序列不能发给服务器。
    case nulByte
    /// 基准目录不带前导 `/`，说明调用方把未解析的相对路径当成了当前目录。
    case baseNotAbsolute
    /// `~` 开头的路径需要家目录，但登录后的家目录尚未确定。
    case homeDirectoryUnknown
    /// `~user` 形式的家目录客户端无从得知。既不猜也不交给服务器展开，
    /// 因为词法结果会与远端 realpath 不一致。要寻址名字真以 `~` 开头的条目，写 `./~foo`。
    case homeExpansionUnsupported(text: String)
    /// 软链展开次数超过上限（POSIX ELOOP），链上有环。
    case tooManySymlinkExpansions(limit: Int)
    /// 空名字拼不出路径，是调用方 bug。
    case emptyComponentName
}

/// SFTP 与 FTP 共用的路径词法层：不访问远端、不读磁盘、不做字符集转换。
///
/// 一切寻址依据是 `RemotePath.wireBytes`。这里**不**做 NFC，也不折叠大小写：
/// 归一化只属于 `ComparisonKey`，一旦用于寻址，Linux 上并存的 NFC/NFD 同形文件
/// 会被合并成一个。`isAbsolute` 只是元数据，字节里有没有前导 `/` 才是权威；
/// 两者矛盾时以字节为准（当成相对路径处理）。
public struct PathResolver: Sendable {
    static let separator: UInt8 = 0x2F
    static let nul: UInt8 = 0x00
    private static let tilde: UInt8 = 0x7E
    private static let singleDot: [UInt8] = [0x2E]
    private static let doubleDot: [UInt8] = [0x2E, 0x2E]

    public static let root = RemotePath(wireBytes: [separator], isAbsolute: true)

    /// 登录后由服务器给出的家目录（SFTP 用 `realpath(".")`，FTP 用 `PWD`）。
    public let homeDirectory: RemotePath?

    /// Linux 内核的 SYMLOOP_MAX 是 40，取同量级默认值。
    public let maxSymlinkExpansions: Int

    public init(homeDirectory: RemotePath? = nil, maxSymlinkExpansions: Int = 40) {
        self.homeDirectory = homeDirectory
        self.maxSymlinkExpansions = max(0, maxSymlinkExpansions)
    }

    /// 纯词法解析：合并重复分隔符、丢弃 `.`、就地消解 `..`（不越过根）、去掉尾部 `/`。
    ///
    /// 已知局限：`..` 遇到软链时词法结果与内核结果不同（内核先跟随软链再回退）。
    /// 需要与服务器一致时用 `resolve(_:relativeTo:linkTarget:)`。
    public func lexicalResolve(_ path: RemotePath, relativeTo base: RemotePath) throws -> RemotePath {
        Self.absolutePath(components: try walk(path, relativeTo: base, collapseParent: true))
    }

    /// 与远端 `realpath` 对齐的解析：每推进一段就用 `linkTarget` 检查该前缀是否软链，
    /// 是则把目标就地展开成新的待处理段，目标内部的软链会被继续展开。
    /// `linkTarget` 收到的一定是绝对路径前缀，返回 nil 表示"不是软链"（含不存在）。
    ///
    /// 结果会把末段软链也展开——与 `open` 语义一致；要保留软链本身请走 `lstat`。
    public func resolve(
        _ path: RemotePath,
        relativeTo base: RemotePath,
        linkTarget: (RemotePath) throws -> [UInt8]?
    ) throws -> RemotePath {
        // 这里必须留着 `..` 交给下面的循环处理：软链展开后再回退才是内核行为，
        // 词法先消掉 `..` 会让 `/symlinkdir/..` 得到错误的答案。
        var pending = Array(try walk(path, relativeTo: base, collapseParent: false).reversed())
        var stack: [[UInt8]] = []
        var expansions = 0

        while let component = pending.popLast() {
            // 软链目标自带 `//`、尾部 `/` 或 `.` 都要能咽下去，否则空段会拼出 `//`。
            if component.isEmpty || component == Self.singleDot { continue }
            if component == Self.doubleDot {
                if !stack.isEmpty { stack.removeLast() }
                continue
            }
            stack.append(component)
            guard let target = try linkTarget(Self.absolutePath(components: stack)) else { continue }
            guard !target.contains(Self.nul) else { throw PathResolutionError.nulByte }

            expansions += 1
            guard expansions <= maxSymlinkExpansions else {
                throw PathResolutionError.tooManySymlinkExpansions(limit: maxSymlinkExpansions)
            }
            stack.removeLast()
            let split = Self.components(of: target)
            if split.absolute { stack = [] }
            pending.append(contentsOf: split.joined.reversed())
        }
        return Self.absolutePath(components: stack)
    }

    /// 拼接父目录与条目名。`readdir` 回来的名字必须走这里，
    /// 各后端自行 `string + "/" + name` 会在根目录下产出 `//name`。
    public static func child(of parent: RemotePath, name: [UInt8]) throws -> RemotePath {
        guard !name.isEmpty else { throw PathResolutionError.emptyComponentName }
        guard !name.contains(nul), !parent.wireBytes.contains(nul) else { throw PathResolutionError.nulByte }
        // 拼出来的路径标成绝对，父路径就必须真是绝对的；否则后端会拿着 isAbsolute==true
        // 的伪绝对路径去寻址，错误被推迟到远端才暴露。
        guard parent.wireBytes.first == separator else { throw PathResolutionError.baseNotAbsolute }
        var bytes = parent.wireBytes
        if bytes.last == separator { bytes = Array(bytes.dropLast()) }   // 容忍 "/a/" 这种父路径
        bytes.append(separator)
        bytes.append(contentsOf: name)
        return RemotePath(wireBytes: bytes, isAbsolute: true)
    }

    /// 获取路径的父目录。若已是根目录 `/`，返回根目录自身。
    public static func parent(of path: RemotePath) throws -> RemotePath {
        guard !path.wireBytes.contains(nul) else { throw PathResolutionError.nulByte }
        guard path.wireBytes.first == separator else { throw PathResolutionError.baseNotAbsolute }
        var bytes = path.wireBytes
        while bytes.count > 1 && bytes.last == separator {
            bytes.removeLast()
        }
        guard let lastSlash = bytes.lastIndex(of: separator) else {
            return root
        }
        if lastSlash == 0 {
            return root
        }
        return RemotePath(wireBytes: Array(bytes[0..<lastSlash]), isAbsolute: true)
    }


    /// 走一遍段序列：基准目录必须先规范化，再作为已解析前缀接上输入。
    /// `collapseParent == false` 时保留 `..`，交给软链循环处理。
    private func walk(_ path: RemotePath, relativeTo base: RemotePath, collapseParent: Bool) throws -> [[UInt8]] {
        guard base.wireBytes.first == Self.separator else { throw PathResolutionError.baseNotAbsolute }
        guard !base.wireBytes.contains(Self.nul), !path.wireBytes.contains(Self.nul) else { throw PathResolutionError.nulByte }

        var (absolute, components) = Self.components(of: path.wireBytes)
        if let expanded = try expandHome(path.wireBytes, absolute: absolute) {
            (absolute, components) = expanded
        }

        var resolved = absolute ? [] : Self.normalizedAbsoluteComponents(base.wireBytes)
        for component in components {
            if component.isEmpty || component == Self.singleDot { continue }
            if component == Self.doubleDot {
                // 钳制在根之后，再多的 `..` 仍是根；不钳制时留给软链循环处理。
                if collapseParent {
                    if !resolved.isEmpty { resolved.removeLast() }
                } else {
                    resolved.append(component)
                }
                continue
            }
            resolved.append(component)
        }
        return resolved
    }

    /// 基准目录一定已是解析过的绝对路径，按同一套词法规则再走一遍即可幂等。
    private static func normalizedAbsoluteComponents(_ bytes: [UInt8]) -> [[UInt8]] {
        var resolved: [[UInt8]] = []
        for component in components(of: bytes).joined {
            if component.isEmpty || component == singleDot { continue }
            if component == doubleDot {
                if !resolved.isEmpty { resolved.removeLast() }
                continue
            }
            resolved.append(component)
        }
        return resolved
    }

    /// 只有整条路径的第一段以 `~` 开头才尝试展开；`/~foo` 里的 `~` 是普通文件名字节。
    private func expandHome(_ bytes: [UInt8], absolute: Bool)
        throws -> (absolute: Bool, joined: [[UInt8]])?
    {
        guard !absolute, bytes.first == Self.tilde else { return nil }
        guard bytes.count == 1 || bytes[1] == Self.separator else {
            throw PathResolutionError.homeExpansionUnsupported(text: String(decoding: bytes, as: UTF8.self))
        }
        guard let home = homeDirectory else { throw PathResolutionError.homeDirectoryUnknown }
        // `~` 整条就是家目录；`~/x` 把 `/x` 接在家目录段之后。家目录可能正是根，
        // 交给 normalizedAbsoluteComponents 统一处理尾部分隔符。
        var joined = Self.normalizedAbsoluteComponents(home.wireBytes)
        joined.append(contentsOf: Self.components(of: Array(bytes.dropFirst())).joined)
        return (true, joined)
    }

    /// 两个后端都把 `//` 当 `/`，所以连同前导分隔符一起合并，不给调用方留歧义。
    private static func components(of bytes: [UInt8]) -> (absolute: Bool, joined: [[UInt8]]) {
        var result: [[UInt8]] = []
        var current: [UInt8] = []
        for byte in bytes {
            if byte == separator {
                result.append(current)
                current = []
            } else {
                current.append(byte)
            }
        }
        result.append(current)
        return (bytes.first == separator, result)
    }

    private static func absolutePath(components: [[UInt8]]) -> RemotePath {
        var bytes: [UInt8] = [separator]
        for (index, component) in components.enumerated() {
            if index > 0 { bytes.append(separator) }
            bytes.append(contentsOf: component)
        }
        return RemotePath(wireBytes: bytes, isAbsolute: true)
    }
}
