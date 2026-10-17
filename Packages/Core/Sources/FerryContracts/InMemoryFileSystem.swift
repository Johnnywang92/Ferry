import Foundation
import FerryCore

/// M1' 契约测试框架的第二个被测对象：一个完全内存里的 POSIX 语义文件系统。
///
/// 它存在的理由不是"少一个要连服务器的被测对象"。v2.3《测试策略》说契约测试是
/// 防止"FTP 少个功能，我加个 if 把抽象破掉"的唯一办法，而做到"同一套用例跑两个后端"
/// 需要两边都能**在任意时刻构造出同样的树**。真机那份做不到：语料得先铺、
/// 上一轮用例留下的文件得先清、中间崩了就得手工恢复——于是"契约绿"这件事
/// 只在 CI 全绿的那几分钟成立，开发者本地一改就没人敢信。
///
/// 这个 fake 把整套契约用例变成秒级、可重入、不依赖 Docker 的东西。它的第二份价值
/// 更直接：**它是 POSIX 语义的参照答案**。契约用例里凡是说"后端必须怎样"的断言，
/// 在这里都由一个独立的实现给出——如果 SFTP 的结果和 fake 不一致，那是 SFTP 错了，
/// 而不是"fake 只是照着 SFTP 写的"。M5 接 FTP 时这个参照还在，那时就能看出 FTP 缺了什么。
///
/// 存储是**扁平字典**（绝对路径字节 → 节点）而不是真的树：契约要验的是后端对外
/// 的行为（list 返回什么、stat 判成什么类型），不是存储效率。一棵树会逼出
/// `mkdir -p`、父目录回溯、graft 之类几十行与契约无关的代码，而这类代码正是
/// "自己骗自己"的高发区。
///
/// 不实现的：软链的完整内核语义（相对目标按 POSIX 规则拼）、权限强制、字符集协商。
/// 这些缺的地方一律让用例**显式跳过**，而不是伪造一个能过的假象——
/// 契约测试最怕的就是"两端都能过，但都是假的"。
public actor InMemoryFileSystem: RemoteFileSystem {

    // MARK: - 存储

    /// 节点按**规范化后的绝对路径字节**索引。根恒在，恒为目录。
    fileprivate enum Node {
        case directory(permissions: UInt16)
        /// `permissionPresent == false` 表示服务器没给权限位，输出时 `permissions == nil`。
        case file(contents: Data, permissions: UInt16, permissionPresent: Bool,
                  modification: Date?, mtimeReliable: Bool)
        case symlink(target: [UInt8], permissions: UInt16)

        var kind: RemoteItemKind {
            switch self {
            case .directory: .directory
            case .file: .file
            case .symlink: .symbolicLink
            }
        }

        var permissions: UInt16 {
            switch self {
            case .directory(let mode), .file(_, let mode, _, _, _), .symlink(_, let mode): mode
            }
        }

        var permissionPresent: Bool {
            switch self {
            case .directory: true
            case .file(_, _, let present, _, _): present
            case .symlink: true
            }
        }

        var isDirectory: Bool {
            if case .directory = self { return true }
            return false
        }

        /// 只有文件才有 size 与 mtime；目录与链一律 nil。
        var fileSize: Int64? {
            if case .file(let contents, _, _, _, _) = self { return Int64(contents.count) }
            return nil
        }

        var modification: Date? {
            if case .file(_, _, _, let date, _) = self { return date }
            return nil
        }
    }

    private var nodes: [RemotePath: Node] = [PathResolver.root: .directory(permissions: 0o755)]

    /// 声明的能力上限。默认不含 `reliableMTime`：那格只在"字段缺失要降级"的用例里打开。
    public nonisolated let declaredCapabilities: RemoteCapabilities
    public nonisolated let pathPolicy: PathPolicy
    public nonisolated let charsetConverter: CharsetConverter

    public init(
        declaredCapabilities: RemoteCapabilities = [.permissions, .symbolicLinks, .lstat,
                                                    .atomicRenameOverwrite, .ownership],
        pathPolicy: PathPolicy = .posix,
        charset: CharsetConverter.Charset = .gbk
    ) {
        self.declaredCapabilities = declaredCapabilities
        self.pathPolicy = pathPolicy
        self.charsetConverter = CharsetConverter(charset: charset)
    }

    // MARK: - 夹具

    public struct Seed: Sendable {
        /// 无前导斜杠的相对形式（`dir/a.txt`），与 shell 习惯一致。
        public let path: String
        public let kind: Kind
        /// 文件=内容，链=目标（原始字节，按 POSIX 存相对目标）。
        public let payload: [UInt8]?
        /// 权限位。`permissionPresent == false` 时这一格被忽略，输出 `permissions == nil`——
        /// 那就是"服务器压根没给这一位"。
        ///
        /// 刻意不用 `UInt16?`：Optional 表达不了"没指定"与"明确缺席"的区别，
        /// 而契约里"权限位缺席时类型判 unknown"那一格只有靠后者才验得到。
        public let permissions: UInt16
        public let permissionPresent: Bool
        /// nil 时 `modificationDate` 也是 nil——模拟 FTP 服务器不给 MDTM。
        public let modification: Date?
        public let mtimeReliable: Bool

        public enum Kind: Sendable { case directory, file, symlink }

        public init(_ path: String, kind: Kind, payload: [UInt8]? = nil,
                    permissions: UInt16? = nil, modification: Date? = nil,
                    mtimeReliable: Bool = true) {
            self.path = path
            self.kind = kind
            self.payload = payload
            self.permissions = permissions ?? 0
            // 显式传 0 视为"这一位是 0"（`--x` 之类）；只有不传才是"缺席"。
            self.permissionPresent = permissions != nil
            self.modification = modification
            self.mtimeReliable = mtimeReliable
        }

        /// "服务器没给权限位"那条语料：类型必须落 `.unknown`。
        public static func withoutPermission(_ path: String) -> Seed {
            Seed(path, kind: .file, permissions: nil, modification: Date(timeIntervalSince1970: 1_700_000_000))
        }

        /// "服务器没给 mtime"那条语料。
        public static func withoutModification(_ path: String) -> Seed {
            Seed(path, kind: .file, permissions: 0o644, modification: nil, mtimeReliable: false)
        }

        /// 少写一遍 `Array(str.utf8)`。
        public static func text(_ path: String, _ content: String) -> Seed {
            Seed(path, kind: .file, payload: Array(content.utf8))
        }
    }

    /// 铺一棵夹具树。中间目录自动补齐（等价 `mkdir -p`），但只在夹具里这么做——
    /// 公开的 `mkdir` 必须遵守 POSIX 的"已存在即失败"，那正是契约要验的一格。
    public func seed(_ seeds: [Seed]) throws {
        for entry in seeds {
            let absolute = try normalized(RemotePath(wireBytes: Array("/\(entry.path)".utf8),
                                                    isAbsolute: true))
            // 从浅到深补齐缺失的祖先：根在前，`ancestors(of:)` 就是这个顺序。
            for ancestor in Self.ancestors(of: absolute) where nodes[ancestor] == nil {
                nodes[ancestor] = .directory(permissions: 0o755)
            }
            switch entry.kind {
            case .directory:
                nodes[absolute] = .directory(permissions: entry.permissions ?? 0o755)
            case .file:
                // permissions == nil 就是"服务器没给这一位"（存 0），
                // 不许用 `?? 0o644` 兜回默认值——那会让夹具没法表达缺席，
                // 于是契约里"缺席时判 unknown"那一格永远验不到。
                nodes[absolute] = .file(contents: Data(entry.payload ?? []),
                                        permissions: entry.permissionPresent ? entry.permissions : 0o644,
                                        permissionPresent: entry.permissionPresent,
                                        modification: entry.modification,
                                        mtimeReliable: entry.mtimeReliable)
            case .symlink:
                nodes[absolute] = .symlink(target: entry.payload ?? [], permissions: 0o777)
            }
        }
    }

    /// 按原始字节铺语料。
    ///
    /// `Seed.path` 是 `String`，于是**铺不出** GBK 名（`"\u{CE}"` 在 Swift 里非法）
    /// 与 NFC 名（编译器会把它规范化掉）。而契约里"非 ASCII 名按字节寻址"那两格
    /// 恰恰要靠它们才验得到——所以夹具这一层也得能接字节，
    /// 否则契约就会因为"夹具表达不了"而永远跳过。
    public struct ByteSeed: Sendable {
        public let path: [UInt8]
        public let kind: Seed.Kind
        public let payload: [UInt8]?
        public let permissions: UInt16
        public let permissionPresent: Bool
        public let modification: Date?
        public let mtimeReliable: Bool

        public init(_ path: [UInt8], kind: Seed.Kind, payload: [UInt8]? = nil,
                    permissions: UInt16 = 0o644, permissionPresent: Bool = true,
                    modification: Date? = Date(timeIntervalSince1970: 1_700_000_000),
                    mtimeReliable: Bool = true) {
            self.path = path
            self.kind = kind
            self.payload = payload
            self.permissions = permissions
            self.permissionPresent = permissionPresent
            self.modification = modification
            self.mtimeReliable = mtimeReliable
        }
    }

    /// 铺字节路径的语料。路径按 `/` 分段补齐中间目录，与 `seed(_:)` 同一套规则。
    public func seedBytes(_ seeds: [ByteSeed]) throws {
        for entry in seeds {
            let absolute = try normalized(RemotePath(wireBytes: entry.path, isAbsolute: true))
            for ancestor in Self.ancestors(of: absolute) where nodes[ancestor] == nil {
                nodes[ancestor] = .directory(permissions: 0o755)
            }
            switch entry.kind {
            case .directory:
                nodes[absolute] = .directory(permissions: entry.permissions)
            case .file:
                nodes[absolute] = .file(contents: Data(entry.payload ?? []),
                                        permissions: entry.permissions,
                                        permissionPresent: entry.permissionPresent,
                                        modification: entry.modification,
                                        mtimeReliable: entry.mtimeReliable)
            case .symlink:
                nodes[absolute] = .symlink(target: entry.payload ?? [], permissions: 0o777)
            }
        }
    }

    /// 把契约语料倒空。测试之间不该靠"上一轮留下什么"活着。
    public func reset() {
        nodes = [PathResolver.root: .directory(permissions: 0o755)]
    }

    // MARK: - 路径

    private func normalized(_ path: RemotePath) throws -> RemotePath {
        try PathResolver(homeDirectory: nil).lexicalResolve(path, relativeTo: PathResolver.root)
    }

    /// `/a/b/c` → `[/a, /a/b]`，含根、不含自身。
    private static func ancestors(of path: RemotePath) -> [RemotePath] {
        var result: [RemotePath] = [PathResolver.root]
        var bytes = path.wireBytes
        while bytes.count > 1 {
            guard let slash = bytes.lastIndex(of: 0x2F), slash > 0 else { break }
            // `bytes[...slash]` **含**尾分隔符，会得到 `/a/`——而节点键一律是
            // 规范化过的（`normalized()` 会去掉尾斜杠），于是补出来的父目录存不进去，
            // 后面查父目录一律 notFound。必须把那一个斜杠去掉。
            bytes = Array(bytes[..<slash])
            result.append(RemotePath(wireBytes: bytes, isAbsolute: true))
        }
        return result
    }

    private func parent(of path: RemotePath) -> RemotePath? {
        let bytes = path.wireBytes
        guard let slash = bytes.lastIndex(of: 0x2F) else { return nil }
        return slash == 0 ? PathResolver.root
                         : RemotePath(wireBytes: Array(bytes[..<slash]), isAbsolute: true)
    }

    /// 直接子项：父目录是它的那些键。
    private func children(of directory: RemotePath) -> [RemotePath: Node] {
        var result: [RemotePath: Node] = [:]
        for (path, node) in nodes where path != directory && parent(of: path) == directory {
            result[path] = node
        }
        return result
    }

    /// 相对目标按 POSIX 拼：基准是**链自己所在的目录**，不是调用方的当前目录。
    private func absoluteTarget(_ target: [UInt8], of link: RemotePath) throws -> RemotePath {
        if target.first == 0x2F {
            return RemotePath(wireBytes: target, isAbsolute: true)
        }
        guard let base = parent(of: link) else {
            return RemotePath(wireBytes: target, isAbsolute: false)
        }
        // 必须拼完再词法归一：`PathResolver.child` 只是把名字段接上去，
        // `../dir/file` 里的 `..` 会被原样保留，于是查表时得到
        // `/links/../dir/file` 这么一条永远不存在的键。相对目标要按内核那样
        // 先跟随再回退（`resolve(_:relativeTo:linkTarget:)` 走的就是这条路）。
        return try normalized(RemotePath(wireBytes: base.wireBytes + [0x2F] + target,
                                         isAbsolute: true))
    }

    /// `stat` 跟链；返回落到的那一项的路径。成环按 ELOOP 抛。
    private func follow(_ start: RemotePath) throws -> (path: RemotePath, node: Node) {
        var cursor = start
        var hops = 0
        while true {
            guard let node = nodes[cursor] else { throw RemoteError.notFound(path: start) }
            guard case .symlink(let target, _) = node else { return (cursor, node) }
            hops += 1
            guard hops <= 40 else {
                throw PathResolutionError.tooManySymlinkExpansions(limit: 40)
            }
            cursor = try absoluteTarget(target, of: cursor)
        }
    }

    /// 组装对外的条目。
    ///
    /// 这一格是契约里"权限与字段缺失时的降级"的**参照实现**：权限位缺席时类型必须是
    /// `.unknown` 而不是 `.file`。写成 `.file` 看着无害——sync 引擎会去读一个其实是
    /// 目录的条目，或者判成"文件"递归下去；判成 `.directory` 又会递归进一个文件。
    /// 契约测试第一轮就抓到了这里的假实现（M1' 契约框架自检）。
    private func item(_ path: RemotePath, _ node: Node) -> RemoteItem {
        switch node {
        case .directory(let mode):
            return RemoteItem(path: path, kind: .directory, size: nil, modificationDate: nil,
                              sizeIsExact: true, mtimeIsReliable: false, permissions: mode)
        case .file(let contents, let mode, let present, let date, let reliable):
            // 权限位缺席时类型无从判断——不许拿"内容存在"倒推成 file。
            let kind: RemoteItemKind = present ? .file : .unknown
            return RemoteItem(path: path, kind: kind, size: Int64(contents.count),
                              modificationDate: date, sizeIsExact: true,
                              mtimeIsReliable: reliable && date != nil,
                              permissions: present ? mode : nil)
        case .symlink(let target, let mode):
            return RemoteItem(path: path, kind: .symbolicLink, size: nil, modificationDate: nil,
                              sizeIsExact: true, mtimeIsReliable: false,
                              linkTarget: RemotePath(wireBytes: target, isAbsolute: target.first == 0x2F),
                              permissions: mode == 0 ? nil : mode)
        }
    }

    private func fail(_ operation: RemoteOperation, _ path: RemotePath, code: Int32 = -1) -> RemoteError {
        RemoteError.operationFailed(OperationFailure(
            kind: .undetermined, operation: operation, path: path, rc: code))
    }

    // MARK: - RemoteFileSystem：读

    public func list(_ path: RemotePath) async throws -> RemoteDirectoryListing {
        let directory = try normalized(path)
        let (_, node) = try follow(directory)
        guard node.isDirectory else { throw fail(.list, path) }
        // 顺序按字节排：POSIX 的 readdir 顺序由文件系统决定，契约不能建立在它上面。
        // 另一条理由是这条顺序必须可重入——同一份语料两次列要逐条相同。
        let entries = children(of: directory)
            .sorted { Self.lexicographicallyPrecedes($0.key.wireBytes, $1.key.wireBytes) }
            .map { item($0.key, $0.value) }
        return RemoteDirectoryListing(directory: directory, entries: entries)
    }

    public func stat(_ path: RemotePath) async throws -> RemoteItem {
        let requested = try normalized(path)
        let (_, landed) = try follow(requested)
        // 路径保持调用方给的那条，类型取**目标**的，`linkTarget` 仍填链自己的：
        // POSIX 的 `stat` 三件事都这么干，契约要能分辨它与 `lstat` 的差别。
        guard case .symlink = nodes[requested] else { return item(requested, landed) }
        // 走一遍 `item` 之外还得留住链自己的 linkTarget，所以这里手拼一条。
        // 类型与降级规则必须和 `item` 一致——另写一份就是下一个不一致的来源，
        // 而契约测试第一轮已经抓到过一次（fake 硬编码 `.file`）。
        let base = item(requested, landed)
        return RemoteItem(path: requested, kind: base.kind, size: base.size,
                          modificationDate: base.modificationDate,
                          sizeIsExact: base.sizeIsExact, mtimeIsReliable: base.mtimeIsReliable,
                          linkTarget: try await readlink(requested),
                          permissions: base.permissions)
    }

    public func lstat(_ path: RemotePath) async throws -> RemoteItem {
        let requested = try normalized(path)
        guard let node = nodes[requested] else { throw RemoteError.notFound(path: path) }
        return item(requested, node)
    }

    public func resolve(_ item: RemoteItem, in listing: inout RemoteDirectoryListing)
        async throws -> RemoteDirectoryListing.LinkResolution?
    {
        // 命中缓存时必须是 0 次查询——M1'-5 §4 的度量口径就是这一个数。
        if let cached = listing.resolution(for: item) { return cached }
        guard item.kind == .symbolicLink else {
            listing.noteProbe(item.path, target: nil)
            return nil
        }
        guard case .symlink(let target, _) = nodes[item.path] else {
            listing.noteProbe(item.path, target: nil)
            return nil
        }
        let absolute = try absoluteTarget(target, of: item.path)
        // 断链照样给 `resolved`：**目标不存在不等于目标不知道**（M0b-01 §1）。
        // 那条实测是服务器 realpath 对断链也返回词法结果，所以客户端不该
        // 因为"最后一段找不到"就把整条链的解析结果丢成 nil——
        // UI 靠这一格把"链指向一个不存在的东西"显示成可点击的路径。
        //
        // 只有**成环**才留 nil：那种情况下没有"最终落点"可言，
        // 而 ELOOP 本身就是调用方要看的信号。
        var resolved: RemotePath?
        do {
            resolved = try follow(absolute).path
        } catch let error as PathResolutionError {
            guard case .tooManySymlinkExpansions = error else { throw error }
            resolved = nil
        } catch let error as RemoteError {
            guard case .notFound = error else { throw error }
            resolved = absolute
        }
        let resolution = RemoteDirectoryListing.LinkResolution(
            target: RemotePath(wireBytes: target, isAbsolute: target.first == 0x2F),
            resolved: resolved, segmentsLookedUp: 1)
        listing.noteProbe(item.path, target: resolution.target)
        listing.note(resolution, for: item)
        return resolution
    }

    public func readlink(_ path: RemotePath) async throws -> RemotePath {
        let target = try normalized(path)
        guard case .symlink(let raw, _) = nodes[target] else { throw fail(.readlink, path) }
        return RemotePath(wireBytes: raw, isAbsolute: raw.first == 0x2F)
    }

    public func statvfs(_ path: RemotePath) async throws -> RemoteVolumeInfo {
        _ = try follow(try normalized(path))
        return RemoteVolumeInfo(totalBytes: 100_000_000, availableBytes: 50_000_000)
    }

    // MARK: - RemoteFileSystem：写

    public func mkdir(_ path: RemotePath, permissions: UInt16?) async throws {
        let directory = try normalized(path)
        guard nodes[directory] == nil else { throw fail(.mkdir, path) }
        _ = try requiredParent(of: directory, for: path)
        nodes[directory] = .directory(permissions: permissions ?? 0o755)
    }

    /// 父目录必须存在且是目录——POSIX 的 `mkdir` 不建中间层（那是 `-p` 的活）。
    private func requiredParent(of target: RemotePath, for reported: RemotePath) throws -> RemotePath {
        guard let base = parent(of: target), nodes[base]?.isDirectory == true else {
            throw RemoteError.notFound(path: parent(of: target) ?? reported)
        }
        return base
    }

    public func remove(_ path: RemotePath, recursive: Bool) async throws {
        let target = try normalized(path)
        guard target != PathResolver.root else { throw fail(.remove, path) }
        guard let node = nodes[target] else { throw RemoteError.notFound(path: path) }
        // 非空目录不递归就是失败：POSIX rmdir 与 unlink 在这一格上同一个语义。
        if node.isDirectory {
            let kids = children(of: target)
            if !recursive, !kids.isEmpty { throw fail(.remove, path) }
            for child in kids.keys { nodes.removeValue(forKey: child) }
        }
        nodes.removeValue(forKey: target)
    }

    public func rename(_ from: RemotePath, to: RemotePath, overwrite: Bool) async throws {
        let source = try normalized(from)
        let destination = try normalized(to)
        guard let node = nodes[source] else { throw RemoteError.notFound(path: from) }
        guard let destinationParent = parent(of: destination),
              nodes[destinationParent]?.isDirectory == true else {
            throw RemoteError.notFound(path: parent(of: destination) ?? to)
        }
        if let existing = nodes[destination] {
            guard overwrite else { throw fail(.rename, to) }
            // 目录覆写非空目录在 POSIX 上是 ENOTEMPTY：不许悄悄换掉，
            // 否则同步引擎会把"没删成"读成"删成了"。
            if existing.isDirectory, !children(of: destination).isEmpty { throw fail(.rename, to) }
            if existing.isDirectory {
                for child in children(of: destination).keys { nodes.removeValue(forKey: child) }
            }
        }
        // 目录搬家要连子树一起搬，否则移过去的是一个空壳。
        // 先把要搬的节点抓出来再删，否则删完就再也读不到了。
        var moved: [(RemotePath, Node)] = []
        if node.isDirectory {
            moved = children(of: source).sorted {
                Self.lexicographicallyPrecedes($0.key.wireBytes, $1.key.wireBytes)
            }
        }
        nodes.removeValue(forKey: source)
        nodes[destination] = node
        for (child, childNode) in moved {
            nodes.removeValue(forKey: child)
            let rewritten = child.wireBytes.count >= source.wireBytes.count
                ? destination.wireBytes + child.wireBytes.dropFirst(source.wireBytes.count)
                : destination.wireBytes
            nodes[RemotePath(wireBytes: rewritten, isAbsolute: true)] = childNode
        }
    }

    public func symlink(target: RemotePath, at path: RemotePath) async throws {
        let link = try normalized(path)
        guard nodes[link] == nil else { throw fail(.symlink, path) }
        _ = try requiredParent(of: link, for: path)
        nodes[link] = .symlink(target: target.wireBytes, permissions: 0o777)
    }

    public func chmod(_ path: RemotePath, _ mode: UInt16) async throws {
        let target = try normalized(path)
        guard let node = nodes[target] else { throw RemoteError.notFound(path: path) }
        switch node {
        case .directory: nodes[target] = .directory(permissions: mode)
        case .file(let contents, _, let present, let date, let reliable):
            nodes[target] = .file(contents: contents, permissions: mode, permissionPresent: true,
                                  modification: date, mtimeReliable: reliable)
        case .symlink(let raw, _): nodes[target] = .symlink(target: raw, permissions: mode)
        }
    }

    // MARK: - RemoteTransfer

    public func openRead(_ path: RemotePath) async throws -> any RemoteReader {
        try await openRead(path, offset: 0)
    }

    public func openRead(_ path: RemotePath, offset: Int64) async throws -> any RemoteReader {
        guard offset >= 0 else { throw fail(.openRead, path) }
        let (_, node) = try follow(try normalized(path))
        guard case .file(let contents, _, _, _, _) = node else {
            // 目录能开但读不了第一段：POSIX 的 open(O_RDONLY) 对目录是 EISDIR。
            throw node.isDirectory ? fail(.openRead, path) : RemoteError.notFound(path: path)
        }
        let start = min(Int(offset), contents.count)
        return InMemoryReader(contents: Data(contents.suffix(from: start)), reportedSize: Int64(contents.count))
    }

    public func createWrite(_ path: RemotePath, offset: Int64) async throws -> any RemoteWriter {
        let target = try normalized(path)
        guard offset >= 0 else { throw fail(.createWrite, path) }
        _ = try requiredParent(of: target, for: path)
        // offset == 0 必须截断。不截断的话"新文件比旧的短"会在尾巴上留下旧字节，
        // 那是静默损坏（RemoteTransfer 契约里写明的那条）。
        //
        // 注意这里**不立刻建文件**：`commit` 才落盘，"开了没提交的写"不该被 `stat`
        // 看见——这正是 `abort` 存在的理由，半途失败留下的半份文件会被同步引擎
        // 当成成品。截断语义靠"offset > 0 时只保留前 offset 字节"来兑现。
        var initial = Data()
        if offset > 0, case .file(let existing, _, _, _, _)? = nodes[target] {
            initial = Data(existing.prefix(Int(offset)))
        }
        return InMemoryWriter(fs: self, path: target, initial: initial)
    }

    /// writer 的 `commit` 落盘用。只在 commit 时写进树——"没 commit 的写不该被 stat 看见"
    /// 正是 `abort` 存在的理由。
    public func storeWrite(path: RemotePath, contents: Data) {
        nodes[path] = .file(contents: contents, permissions: 0o644, permissionPresent: true,
                            modification: Date(timeIntervalSince1970: 1_700_000_900),
                            mtimeReliable: true)
    }

    private static func lexicographicallyPrecedes(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        for (left, right) in zip(lhs, rhs) where left != right { return left < right }
        return lhs.count < rhs.count
    }
}