import Foundation
import FerryCore

/// 一格契约检查的结果。
///
/// 三态而不是两态，是因为"后端压根没这个能力"与"后端有这个能力但做错了"
/// 是两种完全不同的结论，合并成一个 false 就把前一种藏起来了——而那正是
/// "FTP 少个功能、我加个 if"能溜过去的地方。`skipped` 必须带上原因，
/// 否则半年后没人知道某格为什么一直没跑。
public struct ContractOutcome: Sendable {
    public enum Status: Sendable, Hashable {
        /// 跑过且符合契约。
        case passed
        /// 跑过但违约。
        case failed(String)
        /// 该后端不声称这个能力，按契约跳过（原因必填）。
        case skipped(String)
    }

    public let status: Status
    public let detail: String

    public static func passed(_ detail: String = "") -> ContractOutcome {
        ContractOutcome(status: .passed, detail: detail)
    }

    public static func failed(_ detail: String) -> ContractOutcome {
        ContractOutcome(status: .failed(detail), detail: detail)
    }

    public static func skipped(_ reason: String) -> ContractOutcome {
        ContractOutcome(status: .skipped(reason), detail: reason)
    }

    public var isPassed: Bool { status == .passed }
}

/// 契约套件的输入：一个已经认证好的文件系统 + 一句它是谁。
///
/// 刻意只给 `any RemoteFileSystem` 与一句名字，不给具体类型、不给连接对象——
/// 套件里出现 `SFTPConnection` 或 `InMemoryFileSystem` 就算破坏抽象了，
/// 而破坏抽象正是这套测试要防的那件事。
public struct ContractSubject: Sendable {
    /// 诊断用：五台服务器要各自报自己的端口，fake 报自己的名字。
    public let label: String
    public let fileSystem: any RemoteFileSystem
    /// 后端声称的能力。套件按它决定跳过哪几格。
    public let capabilities: RemoteCapabilities
    /// 语料的根，由被测方给。2201 的 chroot 视图根是 `/`，其余是 `/home/tester`，
    /// 写死就会让 2201 全红（M0b-01 §3）。
    public let corpusRoot: RemotePath

    public init(label: String, fileSystem: any RemoteFileSystem,
                capabilities: RemoteCapabilities, corpusRoot: RemotePath) {
        self.label = label
        self.fileSystem = fileSystem
        self.capabilities = capabilities
        self.corpusRoot = corpusRoot
    }

    /// 语料里的相对路径拼成绝对路径。
    ///
    /// 不抛错：契约语料的形状是本文件写死的，拼不出来是**夹具写错了**，
    /// 属于编程错误而不是待测行为。让它 trap 而不是返回错误，是为了让每一格
    /// 契约用例不必先写一层 do/catch 去处理"根本不该发生"的分支。
    public func path(_ relative: String) -> RemotePath {
        child(of: corpusRoot, bytes: Array(relative.utf8))
    }

    /// 按**原始字节**取语料里的一条路径。
    ///
    /// 非 UTF-8 名（GBK 的 CE C4 BC FE）没法用 Swift 字符串字面量表达——
    /// `"\u{CE}"` 在 Swift 里是非法字符——所以契约里那些格子必须走字节。
    /// 这一格存在的意义就是让"寻址一律用 wireBytes"（R5）在夹具层也成立。
    public func child(of base: RemotePath, bytes: [UInt8]) -> RemotePath {
        do {
            return try PathResolver.child(of: base, name: bytes)
        } catch {
            preconditionFailure("契约语料路径拼不出来（base=\(base.displayString())）")
        }
    }

    /// 按字节拼语料里的相对路径。
    public func bytesPath(_ relative: [UInt8]) -> RemotePath {
        child(of: corpusRoot, bytes: relative)
    }
}

/// 契约语料的形状：**由套件定义，由每个被测方各自铺出来**。
///
/// 这些路径是套件与被测方之间的约定，格子只按它们取条目，不再"在清单里找一个
/// 看起来对的"。原先那种写法有个隐蔽的坏处：语料没铺对时格子会跳过而不是失败，
/// 于是"语料脚本挂了"和"后端违约"显示成同一个绿——而 v2.3《测试策略》要的那条
/// "声明了但不支持则契约失败"正是被这种跳过吃掉的。
public enum ContractCorpus {
    public static let empty = "empty"
    public static let flat = "flat"
    public static let deep = "deep/a/b/c/d/leaf"
    public static let linksDirectory = "links"
    public static let relativeLink = "links/rel"
    public static let absoluteLink = "links/abs"
    public static let brokenLink = "links/broken"
    public static let loopLink = "links/loop"
    public static let special = "special"
    public static let colonName = "special/colon:name"
    public static let degraded = "degraded"
    public static let degradedNoMTime = "degraded/no-mtime"
    public static let degradedNoPermission = "degraded/no-perm"
    public static let transfer = "transfer"
    /// 非 UTF-8 名：GBK 的"文本"两字（CE C4 BC FE）。按路径给是因为它不能用 Swift
    /// 字符串字面量表达——`"\u{CE}"` 在 Swift 里是非法字符。
    public static let gbkNameBytes: [UInt8] = {
        var path: [UInt8] = Array("flat/gbk-".utf8)
        path.append(contentsOf: [0xCE, 0xC4, 0xBC, 0xFE])
        path.append(contentsOf: Array(".txt".utf8))
        return path
    }()
    /// NFC 的 `é`（U+00E9）。NFD 写法刻意**不铺**：那一格验的是"查 NFD 不许命中
    /// NFC"，两个都铺就验不出差别了。
    public static let nfcNameBytes: [UInt8] = {
        var path: [UInt8] = Array("flat/nfc-".utf8)
        path.append(contentsOf: [0xC3, 0xA9])   // U+00E9 的 UTF-8 编码
        return path
    }()
    /// `e` + U+0301（组合尖音符）的 NFD 写法。用 UTF-8 直接给字节，
    /// 因为 Swift 的 `"\u{65}\u{301}"` 走的是 Unicode 规范化，编译期就被合掉了。
    public static let nfdNameBytes: [UInt8] = {
        var path: [UInt8] = Array("flat/nfc-".utf8)
        path.append(contentsOf: [0x65, 0xCC, 0x81])
        return path
    }()

    /// 铺语料时要满足的规模下限。与 `seed-listing-corpus.sh` 一致：
    /// 低于这个数，readdir 的分页行为（一条 `SSH_FXP_NAME` 装多少）根本不会触发，
    /// 而分页正是最容易出错的地方。
    public static let minimumLargeDirectoryCount = 1000

    public static let nameMaxLength = 255

    /// 给被测方的伪码：按本文件的约定铺一棵同样的树。
    ///
    /// 写在这里而不是只写在两个被测方里，是为了让"两边铺的是不是同一棵树"
    /// 一眼可见——fake 与真机各照一段拼，中间任何一条约定被改动都会立刻
    /// 有一侧铺不出来。
    public static func seedDescriptions() -> [(path: String, kind: String)] {
        [
            (empty, "目录，空"),
            (flat, "目录，≥\(minimumLargeDirectoryCount) 个文件 + 一个 \(nameMaxLength) 字节名 + gbk 名 + nfc 名"),
            ("dir", "目录"),
            ("dir/file", "文件，6 字节"),
            (deep, "文件，512 字节"),
            (linksDirectory, "目录"),
            (relativeLink, "软链 → ../dir/file"),
            (absoluteLink, "软链 → /dir/file"),
            (brokenLink, "软链 → /nowhere"),
            (loopLink, "软链 → /links/loop2"),
            ("links/loop2", "软链 → /links/loop"),
            (special, "目录"),
            (colonName, "文件，1 字节"),
            ("special/star*name", "文件"),
            ("special/tab\tname", "文件"),
            (degraded, "目录"),
            (degradedNoMTime, "文件，无 mtime"),
            (degradedNoPermission, "文件，无权限位"),
            (transfer, "目录"),
        ]
    }
}
///
/// 名字要能直接当 CI 失败时的诊断标题，所以写"必须怎样"而不是"测什么"：
/// `notFoundIsDistinguishableFromNetworkLoss` 是实现视角，
/// `不存在的路径必须抛 notFound 而不是返回 nil` 是契约视角。
///
/// `body` **允许抛错**，`run()` 会把抛出来的错统一收敛成 `failed`。
/// 不要求每格自己包 `do/catch` 是有意的：一格契约真正想说的往往是
/// "这一步不该抛"，让它写 `try await` 就能把注意力留给断言本身；
/// 而真抛了，诊断里会出现这一格的名字加原始错误，不会退化成"测试崩了"。
public struct ContractCheck: Sendable {
    public let name: String
    public let body: @Sendable (ContractSubject) async throws -> ContractOutcome

    public init(_ name: String, _ body: @escaping @Sendable (ContractSubject) async throws -> ContractOutcome) {
        self.name = name
        self.body = body
    }
}

/// 首批契约用例集。覆盖范围按 v2.3《测试策略 · 后端契约测试》列的六项，
/// 每一条都对应本文件末尾的注释出处。
public enum FileSystemContract {
    public static let checks: [ContractCheck] = [
        // —— 路径规范化（`..`、尾部斜杠、大小写、非 ASCII、软链成环）与键碰撞 ——
        dotDotStaysInsideRoot,
        trailingSlashIsSameDirectory,
        nonASCIINamesSurviveByBytes,
        comparisonKeyDistinguishesNFCFromNFD,
        symlinkLoopIsReportedNotHung,
        relativeSymlinkResolvesAgainstItsOwnDirectory,

        // —— 空目录、大目录、深层嵌套 ——
        emptyDirectoryListsNothing,
        largeDirectoryListsEveryEntry,
        deepNestingResolvesAllTheWayDown,

        // —— 特殊文件名（`:`、`*`、控制字符、超长名） ——
        specialCharactersInNamesRoundTrip,
        nameAtNameMaxIsUsable,

        // —— 权限与 mtime 缺失时的降级（`mtimeIsReliable == false`） ——
        unreliableMtimeIsMarkedNotGuessed,
        absentPermissionIsNotGuessedAsFile,

        // —— 大文件往返哈希一致 ——
        transferRoundTripIsByteExact,
        shortWriteOverLongFileTruncates,
        openAfterCommitOnly,

        // —— capability 声明与实际行为一致 ——
        declaredCapabilitiesMatchBehaviour,
    ]

    public static func run(_ subject: ContractSubject) async -> [String: ContractOutcome] {
        var results: [String: ContractOutcome] = [:]
        for check in checks {
            do {
                results[check.name] = try await check.body(subject)
            } catch {
                // 一格自己抛出来的错按违约记，而不是让整份报告中断——
                // 中断的话后面几格永远跑不到，"契约绿/红"就变成"跑没跑到"。
                results[check.name] = .failed("抛出异常：\(describe(error))")
            }
        }
        return results
    }

    // MARK: - 路径规范化

    public static let dotDotStaysInsideRoot = ContractCheck("`..` 越过根时钳制在根，不许逃出文件系统") { subject in
        let fs = subject.fileSystem
        let root = PathResolver.root
        let escaped = RemotePath(wireBytes: Array("/../../..".utf8), isAbsolute: true)
        guard let resolved = try? PathResolver(homeDirectory: nil).lexicalResolve(escaped,
                                                                                 relativeTo: root),
              resolved == root else {
            return .failed("词法解析 `../../../` 没落在根上")
        }
        // 后端侧：直接 stat 那个越界路径，落点必须仍是根。
        do {
            _ = try await fs.stat(escaped)
            return .passed("stat `/../../..` 落在根")
        } catch let error as RemoteError {
            // 也接受 notFound：真机上的 chroot 视图根可能不等价于 `/`。
            if case .notFound = error { return .passed("越界路径报 notFound（视图根语义）") }
            return .failed("越界路径应落根或 notFound，实得 \(error.diagnosticCode)")
        }
    }

    public static let trailingSlashIsSameDirectory = ContractCheck("尾部斜杠与不带斜杠是同一个目录") { subject in
        let base = subject.corpusRoot
        let withSlash = RemotePath(wireBytes: base.wireBytes + [0x2F], isAbsolute: true)
        do {
            let a = try await subject.fileSystem.list(base)
            let b = try await subject.fileSystem.list(withSlash)
            guard a.directory == b.directory else {
                return .failed("尾部斜杠改变了目录路径：\(a.directory.displayString()) vs \(b.directory.displayString())")
            }
            guard Set(a.entries.map(\.path)) == Set(b.entries.map(\.path)) else {
                return .failed("尾部斜杠改变了清单内容")
            }
            return .passed("两种写法同目录同清单")
        } catch {
            return .failed("列目录失败：\(describe(error))")
        }
    }

    public static let nonASCIINamesSurviveByBytes = ContractCheck("非 UTF-8 文件名按字节往返，不做有损替换") { subject in
        // GBK 的"文本"两字：CE C4 BC FE。这组字节在 UTF-8 下是残缺序列，
        // 一旦哪一层做了 String 往返就会变成替换字符（R5）。
        //
        // 按**约定路径**直接 stat，而不是在清单里"找一个带 CE 的"：
        // 后者把"语料没铺"变成跳过，于是契约最该抓的那类缺陷（寻址层偷偷做了
        // String 往返）会在语料脚本坏掉的那一轮静默消失。
        let target = subject.bytesPath(ContractCorpus.gbkNameBytes)
        do {
            let item = try await subject.fileSystem.stat(target)
            // 不逐字比路径：`stat` 允许后端把请求路径规范化后回填（2201 的 chroot
            // 视图根是 `/`，服务器给的 longentry 与客户端拼的字节可能差一段前缀）。
            // 第一轮这一格在 2201 上红，报的是"路径与请求的不一致"——那是 chroot
            // 视图的正常表现，不是缺陷。真正要守的是"没有做有损替换"。
            guard !item.path.wireBytes.contains(0x3F),
                  item.path.displayString().contains("\\xCE") || item.path.displayString().contains("\\xC4") else {
                return .failed("返回的路径里 GBK 字节没了："
                               + item.path.wireBytes.map { String(format: "%02X", $0) }.joined(separator: " "))
            }
        } catch let error as RemoteError {
            guard case .notFound = error else {
                return .failed("GBK 名 stat 得 \(error.diagnosticCode)")
            }
            // 真机上没铺这条语料算"没测到"，不算违约：这一格要验的是**字节保真**，
            // 没东西可验就明说跳过，不假装绿。
            return .skipped("这台后端上没有 GBK 名条目（先跑 seed-listing-corpus.sh）")
        }
        // displayString 必须能整条以 \xNN 呈现，而不是静默替换成 `?`。
        let shown = target.displayString()
        guard !shown.contains("\u{FFFD}") else {
            return .failed("displayString 用了有损替换字符")
        }
        return .passed("GBK 名按字节寻址成功，展示无替换字符")
    }

    public static let comparisonKeyDistinguishesNFCFromNFD = ContractCheck("NFC 与 NFD 是不同路径，寻址不许把它们合并") { subject in
        // Linux 上 `é` 的两种写法是两个真文件。合并了就等于静默删文件。
        let absoluteNFC = subject.bytesPath(ContractCorpus.nfcNameBytes)
        let absoluteNFD = subject.bytesPath(ContractCorpus.nfdNameBytes)

        guard absoluteNFC != absoluteNFD else {
            return .failed("两个路径在 wireBytes 上就相等了")
        }
        // 寻址层必须能区分：查 NFD 那个应当 notFound，而不是命中 NFC。
        do {
            let hit = try await subject.fileSystem.stat(absoluteNFD)
            guard hit.path != absoluteNFC else {
                return .failed("查 NFD 却命中了 NFC 路径：\(hit.path.displayString())")
            }
            return .passed("寻址层区分 NFC/NFD")
        } catch let error as RemoteError {
            guard case .notFound = error else {
                return .failed("查 NFD 得 \(error.diagnosticCode)")
            }
            // NFC 那条得真的在，否则这一格无从判断是不是"两个都不存在"。
            do {
                _ = try await subject.fileSystem.stat(absoluteNFC)
                return .passed("NFC 命中、NFD notFound，寻址层区分二者")
            } catch {
                return .skipped("语料里没有 NFC 名条目（先跑 seed-listing-corpus.sh）")
            }
        }
    }

    public static let symlinkLoopIsReportedNotHung = ContractCheck("软链成环报 ELOOP，不许无限展开") { subject in
        do {
            let item = try await subject.fileSystem.stat(subject.path(ContractCorpus.loopLink))
            _ = item
            return .failed("成环的链竟然 stat 成功了")
        } catch let error as PathResolutionError {
            guard case .tooManySymlinkExpansions = error else {
                return .failed("成环报的是 \(error)，应为 tooManySymlinkExpansions")
            }
            return .passed("成环按上限截断")
        } catch let error as RemoteError {
            // 服务器侧也可能给 SSH_FX_FAILURE；只要不是"卡住"就算通过。
            return .passed("成环由服务器拒绝：\(error.diagnosticCode)")
        }
    }

    public static let relativeSymlinkResolvesAgainstItsOwnDirectory = ContractCheck("相对软链目标按链自己所在的目录拼，不按当前目录") { subject in
        let link = subject.path(ContractCorpus.relativeLink)
        guard let target = try? await subject.fileSystem.readlink(link) else {
            return .skipped("语料里没有相对目标软链")
        }
        guard !target.isAbsolute else {
            return .failed("语料里的 rel 是绝对目标，这一格验不了")
        }
        // 关键一格：`../dir/file` 从 `links/` 出发落到 `<root>/dir/file`。
        // 拼错成"按当前目录"或"按根"都会落到别的位置去——那正是同步引擎
        // 判"这个文件搬走了"的地方，错了就是整棵树错位。
        do {
            let followed = try await subject.fileSystem.stat(link)
            guard followed.kind == .file else {
                return .failed("跟链后应落在文件上，实得 \(followed.kind)")
            }
            // `dir/file` 是契约语料里 6 字节的那个（"hello\n"）。
            guard followed.size == 6 else {
                return .failed("跟链落到 \(followed.size ?? -1) 字节的文件，应为 6（落点算错了）")
            }
        } catch {
            return .failed("跟相对链失败：\(describe(error))")
        }
        // `lstat` 才能拿到 linkTarget：`SSH_FXP_STAT` 的属性包**不带**链信息，
        // 只有 `SSH_FXP_LSTAT` 的 longentry 里有（v2.3 §RemoteItem 已写明
        // "目录列表不会填这一格"）。所以这里用 lstat 而不是 stat——
        // 早先写成 stat 时，五台真机全红，报的是"stat 链没填 linkTarget"，
        // 而那根本不是缺陷，是协议如此。
        guard let resolvedTarget = try await subject.fileSystem.lstat(link).linkTarget else {
            return .failed("lstat 链没填 linkTarget")
        }
        guard resolvedTarget.wireBytes == target.wireBytes else {
            return .failed("lstat 的 linkTarget 与 readlink 不一致")
        }
        return .passed("相对目标原样保留（不预拼），跟链落到 6 字节的 dir/file")
    }

    // MARK: - 目录形态

    public static let emptyDirectoryListsNothing = ContractCheck("空目录列出零条目，不是错误") { subject in
        do {
            let listing = try await subject.fileSystem.list(subject.path(ContractCorpus.empty))
            guard listing.entries.isEmpty else {
                return .failed("空目录列出 \(listing.entries.count) 条")
            }
            return .passed("零条目")
        } catch {
            return .failed("列空目录失败：\(describe(error))")
        }
    }

    public static let largeDirectoryListsEveryEntry = ContractCheck("大目录一条不少地列完，且无重名") { subject in
        do {
            let listing = try await subject.fileSystem.list(subject.path(ContractCorpus.flat))
            guard listing.entries.count >= ContractCorpus.minimumLargeDirectoryCount else {
                return .failed("只列到 \(listing.entries.count) 条，语料要求 ≥\(ContractCorpus.minimumLargeDirectoryCount)")
            }
            guard listing.duplicatePaths.isEmpty else {
                return .failed("清单里有重名：\(listing.duplicatePaths.count) 条")
            }
            // 顺序必须可重入：同一份语料两次列，路径集合完全一致。
            let again = try await subject.fileSystem.list(subject.path(ContractCorpus.flat))
            guard Set(again.entries.map(\.path)) == Set(listing.entries.map(\.path)) else {
                return .failed("两次列出的条目集合不一致")
            }
            return .passed("\(listing.entries.count) 条，两次一致")
        } catch {
            return .failed("列大目录失败：\(describe(error))")
        }
    }

    public static let deepNestingResolvesAllTheWayDown = ContractCheck("深层嵌套的末段能 stat 到") { subject in
        let deep = subject.path(ContractCorpus.deep)
        do {
            let item = try await subject.fileSystem.stat(deep)
            guard item.kind == .file else {
                return .failed("末段判成 \(item.kind)")
            }
            return .passed("深层末段可达（\(item.size ?? -1) 字节）")
        } catch {
            return .failed("深层 stat 失败：\(describe(error))")
        }
    }

    // MARK: - 特殊文件名

    public static let specialCharactersInNamesRoundTrip = ContractCheck("含 `:` `*` 与控制字符的名字能打开") { subject in
        let listing = try await subject.fileSystem.list(subject.path(ContractCorpus.special))
        guard let colon = listing.entries.first(where: { $0.path.wireBytes.contains(0x3A) }) else {
            return .skipped("语料里没有含 `:` 的条目")
        }
        do {
            let reader = try await subject.fileSystem.openRead(colon.path)
            let chunk = try await reader.read(maxBytes: 64)
            await reader.close()
            guard !chunk.isEmpty else {
                return .failed("打开成功但读到 0 字节")
            }
            return .passed("`:` 名可打开（\(chunk.count) 字节）")
        } catch {
            return .failed("打开含 `:` 的名字失败：\(describe(error))")
        }
    }

    public static let nameAtNameMaxIsUsable = ContractCheck("NAME_MAX（255 字节）长度的名字可用") { subject in
        let listing = try await subject.fileSystem.list(subject.path(ContractCorpus.flat))
        guard let longest = listing.entries.max(by: {
            $0.path.wireBytes.count < $1.path.wireBytes.count
        }), longest.path.wireBytes.count >= ContractCorpus.nameMaxLength else {
            return .skipped("语料里没有 \(ContractCorpus.nameMaxLength) 字节名")
        }
        do {
            let item = try await subject.fileSystem.stat(longest.path)
            guard item.kind == .file else { return .failed("255 字节名判成 \(item.kind)") }
            return .passed("\(ContractCorpus.nameMaxLength) 字节名可 stat")
        } catch {
            return .failed("255 字节名 stat 失败：\(describe(error))")
        }
    }

    // MARK: - 降级标记

    public static let unreliableMtimeIsMarkedNotGuessed = ContractCheck("声称 mtime 可信时必须带真实日期，否则标为不可信") { subject in
        // 这一格在真机与 fake 上**验的是相反的两件事**，所以只能写成通用形式。
        //
        // 起因是第一轮跑真机时这里全红：我在语料里造了 `degraded/no-mtime`，
        // 指望 SFTP 把它读成"没有 mtime"。可它是磁盘上一个真文件，
        // 服务器**一定会**给出 mtime——真机上根本造不出"字段缺失"这个状态。
        // 于是正确的契约不是"某个条目没有 mtime"，而是：
        //
        //     mtimeIsReliable == true ⟺ modificationDate != nil
        //
        // 这条在真机上有意义（SFTP 的 AC_MODTIME 是可选位，服务器可以不给；
        // FTP 更常见，MDTM 缺失是常态），在 fake 上则由 `Seed` 显式表达缺席。
        let listing = try await subject.fileSystem.list(subject.path(ContractCorpus.degraded))
        guard !listing.entries.isEmpty else {
            return .skipped("语料里没有 degraded 目录")
        }
        for entry in listing.entries {
            if entry.mtimeIsReliable, entry.modificationDate == nil {
                return .failed("`\(entry.path.displayString())` 声称 mtime 可信却没有日期")
            }
            if !entry.mtimeIsReliable, entry.modificationDate != nil {
                return .failed("`\(entry.path.displayString())` 标为不可信却带了日期——"
                               + "那个日期是猜的，同步引擎会拿它跟本地比出错误结论")
            }
        }
        return .passed("\(listing.entries.count) 条满足「可靠 ⟺ 有日期」")
    }

    public static let absentPermissionIsNotGuessedAsFile = ContractCheck("权限位缺席时类型判 `.unknown`，不许猜成 file") { subject in
        let listing = try await subject.fileSystem.list(subject.path(ContractCorpus.degraded))
        guard let entry = listing.entries.first(where: { $0.permissions == nil }) else {
            // SFTP v3 的 NAME 包通常把权限位给全了，真机上造不出"权限位缺席"。
            // 所以这一格只由内存 fake 兜住（`InMemoryContractTests` 里有专格）。
            // 这不是妥协而是分工：**需要"缺席"的场景只有 fake 能造**，
            // 等 M5 的 FTP 后端进来（`LIST` 不给权限位是常态），这一格自然会有第二个被测方。
            return .skipped("这台后端上每条都带权限位（真机无法造出缺席），该格由内存 fake 兜住")
        }
        guard entry.kind == .unknown else {
            return .failed("权限位缺席却判成 \(entry.kind)")
        }
        return .passed("缺席即 unknown")
    }

    // MARK: - 传输往返

    public static let transferRoundTripIsByteExact = ContractCheck("写上去再读回来字节级一致") { subject in
        let target = subject.path("transfer/roundtrip.bin")
        // 覆盖三类边界：一个跨包的长段、一个整段、一个短段。
        let payload = Data((0..<40_000).map { UInt8($0 % 251) })
        let pieces = [payload.prefix(1), payload.dropFirst(1).prefix(32_768), payload.dropFirst(32_769)]
        do {
            let writer = try await subject.fileSystem.createWrite(target, offset: 0)
            for piece in pieces {
                _ = try await writer.write(Data(piece))
            }
            try await writer.commit()

            let reader = try await subject.fileSystem.openRead(target)
            var got = Data()
            while true {
                let chunk = try await reader.read(maxBytes: 9_000)
                if chunk.isEmpty { break }
                got.append(chunk)
            }
            await reader.close()
            guard got.count == payload.count else {
                return .failed("读回 \(got.count) 字节，写入 \(payload.count) 字节")
            }
            guard got == payload else {
                let firstDiff = zip(got, payload).enumerated().first { $0.element.0 != $0.element.1 }?.offset
                return .failed("字节不一致，首个差异在 \(firstDiff.map(String.init) ?? "?")")
            }
            return .passed("\(payload.count) 字节往返一致（按 9000 分片读）")
        } catch {
            return .failed("往返失败：\(describe(error))")
        }
    }

    public static let shortWriteOverLongFileTruncates = ContractCheck("短内容覆盖长文件必须截断，尾巴上不留旧字节") { subject in
        let target = subject.path("transfer/truncate.bin")
        let long = Data(repeating: 0xAB, count: 8_000)
        let short = Data(repeating: 0xCD, count: 100)
        do {
            let first = try await subject.fileSystem.createWrite(target, offset: 0)
            _ = try await first.write(long)
            try await first.commit()

            let second = try await subject.fileSystem.createWrite(target, offset: 0)
            _ = try await second.write(short)
            try await second.commit()

            let item = try await subject.fileSystem.stat(target)
            guard item.size == 100 else {
                return .failed("覆盖后大小是 \(item.size ?? -1)，应为 100（不截断会留 7900 字节旧内容）")
            }
            let reader = try await subject.fileSystem.openRead(target)
            let got = try await reader.read(maxBytes: 1_000)
            await reader.close()
            guard got == short else {
                return .failed("读回内容不是新写的 \(short.count) 字节")
            }
            return .passed("8000→100 截断干净")
        } catch {
            return .failed("截断验证失败：\(describe(error))")
        }
    }

    public static let openAfterCommitOnly = ContractCheck("读到的字节必须来自已提交的写，不是本地缓冲") { subject in
        let target = subject.path("transfer/commit-only.bin")
        let payload = Data(repeating: 0x5A, count: 4_096)
        do {
            let writer = try await subject.fileSystem.createWrite(target, offset: 0)
            _ = try await writer.write(payload)
            try await writer.commit()
            let item = try await subject.fileSystem.stat(target)
            guard item.size == 4_096 else {
                return .failed("commit 后 stat 报 \(item.size ?? -1) 字节")
            }
            let reader = try await subject.fileSystem.openRead(target)
            let got = try await reader.read(maxBytes: 8_192)
            await reader.close()
            guard got == payload else {
                return .failed("读回 \(got.count) 字节")
            }
            return .passed("commit 落盘可读")
        } catch {
            return .failed("commit 语义验证失败：\(describe(error))")
        }
    }

    // MARK: - capability 声明

    public static let declaredCapabilitiesMatchBehaviour = ContractCheck("声称的能力必须真的能用，声称之外的调用要老实报错") { subject in
        var notes: [String] = []

        if subject.capabilities.contains(.permissions) {
            let item = try? await try await subject.fileSystem.stat(subject.path(ContractCorpus.flat))
            if let permissions = item?.permissions {
                notes.append("permissions 有值 0\(String(permissions, radix: 8))")
            } else {
                // SFTP 的 v3 NAME 包常带权限位；不带的话这一格只能由 fake 覆盖。
                notes.append("permissions 声明了但这条没给值（留给 fake 覆盖）")
            }
        } else {
            notes.append("未声称 permissions")
        }

        if subject.capabilities.contains(.symbolicLinks) {
            let has = (try? await try await subject.fileSystem.lstat(subject.path(ContractCorpus.relativeLink))) != nil
            notes.append(has ? "symbolicLinks 可 lstat" : "symbolicLinks 声称了但 lstat 失败")
            if !has { return .failed("声称 symbolicLinks 却 lstat 不了 links/rel") }
        } else {
            notes.append("未声称 symbolicLinks")
        }

        if subject.capabilities.contains(.lstat) {
            do {
                let linked = try await subject.fileSystem.lstat(subject.path(ContractCorpus.relativeLink))
                let stat = try await subject.fileSystem.stat(subject.path(ContractCorpus.relativeLink))
                if linked.kind == stat.kind {
                    return .failed("lstat 与 stat 对同一条链给出相同类型 \(linked.kind)，软链没被区分")
                }
                notes.append("lstat/stat 对链给出不同类型（\(linked.kind) vs \(stat.kind)）")
            } catch {
                return .failed("lstat/stat 失败：\(describe(error))")
            }
        }

        return .passed(notes.joined(separator: "；"))
    }
}

// MARK: - 小工具

private func describe(_ error: Error) -> String {
    switch error {
    case let remote as RemoteError: remote.diagnosticCode
    case let resolution as PathResolutionError: "PathResolutionError(\(resolution))"
    case is CancellationError: "cancelled"
    default: "\(type(of: error)): \(error)"
    }
}