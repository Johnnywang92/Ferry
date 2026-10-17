import Foundation
import FerryCore
import FerryContracts
import Testing

/// 契约套件在内存 fake 上的第一次跑通。
///
/// 这是整套框架的自检：fake 是 POSIX 语义的**独立实现**，它挂了要么是 fake 有 bug，
/// 要么是契约本身写错了（把某个后端的实现细节当成契约）。两种都该在这一轮暴露，
/// 而不是等到 FTP 进来才发现"原来这条一直是假的"。
///
/// 语料形状与 `Spike/Scripts/seed-listing-corpus.sh` 铺的五台真机保持一致——
/// 同一份契约语料跑在 fake 与真机上，两边的结论才有可比性。
@Suite("契约套件 × 内存 fake")
struct InMemoryContractTests {

    /// 按 `ContractCorpus` 的约定铺一棵与真机同形的语料。
    ///
    /// 路径全部引用约定常量而不是写字面量：两边（fake 与真机）铺的必须是同一棵
    /// 树，字面量各写一份迟早会漂，而漂了之后契约的"跳过"就会掩盖真实缺失。
    /// 1000 条这个下限来自 `ContractCorpus.minimumLargeDirectoryCount`，
    /// 与 `seed-listing-corpus.sh` 同值——低于它，readdir 的分页根本不会触发。
    private static func seeded(_ withLargeDirectory: Bool = false) async throws -> InMemoryFileSystem {
        let fs = InMemoryFileSystem()
        let C = ContractCorpus.self
        var seeds: [InMemoryFileSystem.Seed] = [
            .init(C.empty, kind: .directory),
            .init("dir", kind: .directory),
            .init("dir/file", kind: .file, payload: Array("hello\n".utf8), permissions: 0o644,
                  modification: Date(timeIntervalSince1970: 1_700_000_000)),
            .init("deep/a/b/c/d", kind: .directory),
            .init(C.deep, kind: .file, payload: Array(String(repeating: "L", count: 512).utf8),
                  permissions: 0o644, modification: Date(timeIntervalSince1970: 1_700_000_000)),
            .init(C.linksDirectory, kind: .directory),
            .init(C.relativeLink, kind: .symlink, payload: Array("../dir/file".utf8)),
            .init(C.absoluteLink, kind: .symlink, payload: Array("/dir/file".utf8)),
            .init(C.brokenLink, kind: .symlink, payload: Array("/nowhere".utf8)),
            .init(C.loopLink, kind: .symlink, payload: Array("/links/loop2".utf8)),
            .init("links/loop2", kind: .symlink, payload: Array("/links/loop".utf8)),
            .init(C.special, kind: .directory),
            .init(C.colonName, kind: .file, payload: Array("c".utf8), permissions: 0o644,
                  modification: Date(timeIntervalSince1970: 1_700_000_000)),
            .init("special/star*name", kind: .file, payload: Array("s".utf8), permissions: 0o644,
                  modification: Date(timeIntervalSince1970: 1_700_000_000)),
            .init("special/tab\tname", kind: .file, payload: Array("t".utf8), permissions: 0o644,
                  modification: Date(timeIntervalSince1970: 1_700_000_000)),
            .init(C.degraded, kind: .directory),
            // 两条降级语料：mtime 拿不到、权限位拿不到。它们在真机上**验不了**
            // （SFTP v3 的 NAME 包通常把字段给全了），所以只能靠 fake 覆盖——
            // 而"只能在 fake 上验"的那几格正是这套框架要保住的东西：
            // 等 M5 的 FTP 后端进来，没有 MDTM 的服务器会把这两格变成真的缺陷。
            .withoutModification(C.degradedNoMTime),
            .withoutPermission(C.degradedNoPermission),
            .init(C.transfer, kind: .directory),
            .init(C.flat, kind: .directory),
            .init("flat/plain", kind: .file, payload: Array("p".utf8), permissions: 0o644,
                  modification: Date(timeIntervalSince1970: 1_700_000_000)),
        ]
        if withLargeDirectory {
            for index in 0..<C.minimumLargeDirectoryCount {
                seeds.append(.init("flat/\(String(format: "e%04d", index))", kind: .file,
                                   payload: [], permissions: 0o644,
                                   modification: Date(timeIntervalSince1970: 1_700_000_000)))
            }
            seeds.append(.init("flat/\(String(repeating: "n", count: C.nameMaxLength))",
                               kind: .file, payload: [], permissions: 0o644,
                               modification: Date(timeIntervalSince1970: 1_700_000_000)))
        }
        // GBK 名与 NFC 名必须按**字节**铺：它们在 Swift 里都不是合法字符串字面量
        // （`"\u{CE}"` 编译不过），而这正是"寻址走 wireBytes"（R5）要考的。
        try await fs.seed(seeds)
        try await fs.seedBytes([
            .init(ContractCorpus.gbkNameBytes, kind: .file, payload: [],
                  permissions: 0o644, modification: Date(timeIntervalSince1970: 1_700_000_000)),
            .init(ContractCorpus.nfcNameBytes, kind: .file, payload: [],
                  permissions: 0o644, modification: Date(timeIntervalSince1970: 1_700_000_000)),
        ])
        return fs
    }

    private static func subject(_ fs: InMemoryFileSystem) -> ContractSubject {
        ContractSubject(label: "in-memory-fake", fileSystem: fs,
                        capabilities: fs.declaredCapabilities, corpusRoot: PathResolver.root)
    }

    @Test("首批契约用例在内存 fake 上全绿")
    func contractSuitePassesOnFake() async throws {
        let fs = try await Self.seeded(true)
        let results = await FileSystemContract.run(Self.subject(fs))

        let failures = results.filter { if case .failed = $0.value.status { return true } else { return false } }
        let skipped = results.filter { if case .skipped = $0.value.status { return true } else { return false } }
        let report = results.sorted { $0.key < $1.key }
            .map { "\($0.key)：\($0.value.status)" }
            .joined(separator: "\n")
        #expect(failures.isEmpty, "契约违约 \(failures.count) 条：\n\(report)")
        // fake 声称了全部能力，所以没有格子该被跳过——有跳过就说明契约与
        // 声明不自洽（v2.3《测试策略》最后一条）。
        let skippedNames = skipped.keys.sorted().joined(separator: "、")
        #expect(skipped.isEmpty, "fake 上不该有跳过项：\(skippedNames)")
        #expect(results.count == FileSystemContract.checks.count)
    }

    @Test("fake 与真机看到同一套契约语料时，结论不因后端而异")
    func fakeAgreesWithDeclaredCapabilities() async throws {
        let fs = try await Self.seeded()
        // fake 必须真的实现了它声称的东西：`lstat` 对链给 symbolicLink 而
        // `stat` 给 file。这一格是"声明与行为一致"在 fake 上的自证。
        let link = try PathResolver.child(of: PathResolver.root, name: Array("links/rel".utf8))
        let viaLstat = try await fs.lstat(link)
        let viaStat = try await fs.stat(link)
        #expect(viaLstat.kind == .symbolicLink)
        #expect(viaStat.kind == .file, "stat 应跟链到目标文件")
        #expect(viaStat.path == link, "stat 不该把路径改写成目标：路径保持调用方给的那条")
        #expect(viaLstat.linkTarget != nil)
    }

    @Test("fake 的软链相对目标按链自己的目录拼")
    func fakeResolvesRelativeLinkAgainstItsOwnDirectory() async throws {
        let fs = try await Self.seeded()
        // /links/rel → ../dir/file，落点 /dir/file。这两个都在根下，
        // 所以"按链所在目录拼"与"按根拼"会给出不同答案，能分辨。
        let link = try PathResolver.child(of: PathResolver.root, name: Array("links/rel".utf8))
        let resolved = try await fs.stat(link)
        #expect(resolved.kind == .file)
        #expect(resolved.size == 6, "hello\\n 是 6 字节")
    }

    @Test("fake 的断链照样给出 resolved，成环按 ELOOP 抛")
    func fakeHandlesBrokenAndLoopingLinks() async throws {
        let fs = try await Self.seeded()
        // 列 links 目录而不是根：`links/broken` 是 links 的子项，
        // 在根的清单里找它永远找不到——而"找不到"看着像"语料没铺"，最会骗人。
        let linksDir = try PathResolver.child(of: PathResolver.root, name: Array("links".utf8))
        let listing = try await fs.list(linksDir)
        let brokenName = Array("broken".utf8)
        let brokenItem = listing.entries.first { Array($0.path.wireBytes.suffix(brokenName.count)) == brokenName }
        #expect(brokenItem?.kind == .symbolicLink, "断链在 lstat 视角下仍是链")

        // 断链：目标不存在不等于目标不知道
        let broken = try PathResolver.child(of: linksDir, name: brokenName)
        do {
            _ = try await fs.stat(broken)
            Issue.record("断链不该 stat 成功")
        } catch let error as RemoteError {
            guard case .notFound = error else {
                Issue.record("断链应报 notFound，实得 \(error.diagnosticCode)")
                return
            }
        }

        // `resolve` 对断链仍要给出 resolved（M0b-01 §1：目标不存在不等于目标不知道）
        var cached = try await fs.list(linksDir)
        if let item = brokenItem {
            let resolution = try await fs.resolve(item, in: &cached)
            #expect(resolution?.resolved != nil, "断链的 resolved 仍应有值")
            #expect(resolution?.resolved?.wireBytes.last == 0x65, "落点是 /nowhere 的最后一个字节")
        }

        // 成环：必须抛上限，而不是无限展开
        let loop = try PathResolver.child(of: linksDir, name: Array("loop".utf8))
        do {
            _ = try await fs.stat(loop)
            Issue.record("成环不该 stat 成功")
        } catch let error as PathResolutionError {
            guard case .tooManySymlinkExpansions = error else {
                Issue.record("成环应报 tooManySymlinkExpansions，实得 \(error)")
                return
            }
        }
    }

    @Test("fake 的未提交写对 stat 不可见")
    func fakeHidesUncommittedWrites() async throws {
        let fs = try await InMemoryFileSystem()
        try await fs.seed([.init("dir", kind: .directory)])
        let target = try PathResolver.child(of: PathResolver.root, name: Array("dir/pending.bin".utf8))

        let writer = try await fs.createWrite(target, offset: 0)
        _ = try await writer.write(Data(repeating: 0x11, count: 512))
        // 半途失败：abort。文件不该在树里出现。
        await writer.abort()

        do {
            _ = try await fs.stat(target)
            Issue.record("abort 之后文件仍可见")
        } catch let error as RemoteError {
            guard case .notFound = error else {
                Issue.record("abort 后应报 notFound，实得 \(error.diagnosticCode)")
                return
            }
        }
    }

    @Test("fake 覆盖权限位缺席与 mtime 不可信两格（真机验不了的两条降级）")
    func fakeCoversDegradationPaths() async throws {
        // fake 的 Seed 允许 permissions/modification 都是 nil，正是这两格。
        let fs = InMemoryFileSystem()
        try await fs.seed([
            .init("degraded/bare", kind: .file, payload: Array("x".utf8),
                  permissions: nil, modification: nil, mtimeReliable: false),
        ])
        let listing = try await fs.list(try PathResolver.child(of: PathResolver.root,
                                                              name: Array("degraded".utf8)))
        let bare = try #require(listing.entries.first)
        #expect(bare.permissions == nil)
        #expect(bare.modificationDate == nil)
        #expect(!bare.mtimeIsReliable, "拿不到 mtime 时必须标不可信，否则同步引擎会漏判修改")
    }
}