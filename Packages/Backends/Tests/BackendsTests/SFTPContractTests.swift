import CLibssh2
import FerryContracts
import FerryCore
import Foundation
import Testing

@testable import FerryBackendsSFTP

/// M1' 契约套件在 SFTP 后端上的第一次跑通。
///
/// 这一份与 `InMemoryContractTests` 里那一份 import 的是**同一个模块**
/// （`FerryContracts`），跑的是同一个 `FileSystemContract.checks`。这就是 v2.3
/// 《测试策略》说的"同一套契约测试跑在两个后端上"——而"同一套"在这里是类型层面的
/// 事实，不是两处约定小心保持一致。
///
/// 跑法：
///     Spike/Scripts/seed-contract-corpus.sh                        # 先铺语料
///     FERRY_LIVE_SERVERS=1 swift test --package-path Packages/Backends \
///         --filter SFTPContractTests
///     FERRY_LIVE_PORTS=2202,2205 FERRY_LIVE_SERVERS=1 ...          # 只跑指定几台
///
/// 默认不开真机：容器没起的时候整套会连不上并给出误导性的红。
private let liveServersEnabled = ProcessInfo.processInfo.environment["FERRY_LIVE_SERVERS"] == "1"
private let goodPassword = "testpass"

/// 五台仿真服务器（docs/spike/M1-01 §1）。2205 走 Rosetta，只做功能与兼容性
/// 验证，不参与吞吐对比——契约不看吞吐，所以它照跑不误。
private let defaultPorts = [2201, 2202, 2203, 2204, 2205]

private let selectedPorts: [Int] = {
    guard let raw = ProcessInfo.processInfo.environment["FERRY_LIVE_PORTS"] else {
        return defaultPorts
    }
    let parsed = raw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    return parsed.isEmpty ? defaultPorts : parsed
}()

private struct AcceptAllTrust: HostKeyTrust {
    func evaluate(endpoint: Endpoint, hostKey: HostKey) async throws {}
}

/// SFTP 后端**实际具备**的能力。
///
/// 刻意不包含还没实现的那些：`mkdir` / `remove` / `rename` / `symlink` / `chmod` /
/// `statvfs` 在 `RemoteFileSystem` 里已声明、在 `SFTPConnection` 上尚未实现
/// （见 `Protocol/RemoteFileSystem.swift` 顶上那段说明：SFTPConnection 还没
/// 声称 conform）。这里如实声明，于是契约里用到它们的那几格会**跳过并写明原因**，
/// 而不是拿一个"抛未实现"的壳硬撑成"通过"——后者正是这套框架要防的那件事本身。
///
/// `reliableMTime` 也不声明：SFTP v3 只给秒级精度，而契约里验的是"拿不到时必须标
/// 不可信"，不是"精度够不够"。
private let sftpCapabilities: RemoteCapabilities = [
    .permissions, .ownership, .symbolicLinks, .lstat, .resumableUpload, .resumableDownload,
]

/// 契约语料在服务器上的落点。由服务器自己给，不能写死——2201 的 chroot 视图根
/// 是 `/`，其余四台是 `/home/tester`（M0b-01 §3）。写死会让 2201 全红。
/// 契约语料相对登录目录的段。与 `ContractCorpus` 的路径分开拼，
/// 免得 `child(of: corpusRoot, name: "spike/contract/...")` 拼出 `//spike`。
private let corpusRelativeSegment = Array("spike/contract".utf8)

private func corpusRoot(of connection: SFTPConnection) async throws -> RemotePath {
    let home = try await connection.homeDirectory()
    // `RemotePath` 的字节构造器不返回 nil（NUL 在这里不可能出现），
    // 所以直接拼而不用 `RemotePath(string:isAbsolute:)` 的可选形式。
    return RemotePath(wireBytes: home.wireBytes + [0x2F] + corpusRelativeSegment, isAbsolute: true)
}

/// 语料里的某一条（相对 `corpusRoot`）。`name` 用 `/` 分段，
/// 交给 `PathResolver.child` 处理——它按字节拼，不会把 `..` 之类的语义搞错。
private func corpusEntry(_ connection: SFTPConnection, _ relative: String) async throws -> RemotePath {
    try await PathResolver.child(of: corpusRoot(of: connection), name: Array(relative.utf8))
}

private func connected(port: Int, charset: CharsetConverter.Charset = .gbk) async throws
    -> SFTPConnection
{
    let connection = SFTPConnection(request: ConnectionRequest(
        endpoint: Endpoint(host: "127.0.0.1", port: port, username: "tester"),
        authentication: .password(goodPassword),
        policy: .standard,
        charset: charset),
        hostKeyTrust: AcceptAllTrust())
    _ = try await connection.handshake()
    _ = try await connection.authenticate(interactive: nil)
    return connection
}

@Suite("契约套件 × SFTP 后端", .serialized,
       .enabled(if: liveServersEnabled, "真机契约要显式开启：FERRY_LIVE_SERVERS=1（并先跑 seed-contract-corpus.sh）"))
struct SFTPContractTests {

    /// 五台真机各跑一遍同一套用例。
    ///
    /// `.serialized` 是必需的：五台共享同一份语料目录，而契约里有写操作
    /// （`transfer/roundtrip.bin` 那几格）。并行跑会让一台的截断验证读到另一台
    /// 刚写进去的内容，结论随机翻转——那比红还难查。
    @Test("首批契约用例在 SFTP 后端上全绿")
    func contractSuitePassesOnLiveServers() async throws {
        var report: [String] = []
        var failures: [String] = []

        for port in selectedPorts {
            let connection: SFTPConnection
            do {
                connection = try await connected(port: port)
            } catch {
                failures.append("\(port)：连不上（\(error)）")
                continue
            }
            defer { Task { await connection.close() } }

            let root: RemotePath
            do {
                root = try await corpusRoot(of: connection)
            } catch {
                failures.append("\(port)：取不到语料根（\(error)）")
                continue
            }

            let subject = ContractSubject(label: "sftp:\(port)",
                                          fileSystem: SFTPContractAdapter(connection),
                                          capabilities: sftpCapabilities, corpusRoot: root)
            let results = await FileSystemContract.run(subject)
            let passed = results.values.filter { $0.isPassed }.count
            let skipped = results.filter { if case .skipped = $0.value.status { return true } else { return false } }
            let failed = results.filter { if case .failed = $0.value.status { return true } else { return false } }

            report.append("""
            ── \(port) ── 通过 \(passed)/\(results.count)，跳过 \(skipped.count)，违约 \(failed.count)
            \(results.sorted { $0.key < $1.key }.map { "  \($0.key)：\($0.value.status)" }.joined(separator: "\n"))
            """)
            for (name, outcome) in failed {
                failures.append("\(port) · \(name)：\(outcome.detail)")
            }
        }

        let text = report.joined(separator: "\n")
        print(text)
        // `#expect` 的消息参数是 `Comment?`（`#require` 那个是 `String`，两者不一致，
        // 写错了编译器会直接报"不能把 String 转成 Comment"）。
        let summary = "契约违约 \(failures.count) 条：\n" + failures.joined(separator: "\n")
        #expect(failures.isEmpty, Comment(rawValue: summary))
    }

    /// 语料缺失必须让**依赖语料的格子**失败或跳过。
    ///
    /// 这一格是给整套框架上的一把锁：契约里多数格子写"没语料就跳过"，
    /// 那在真机上是合理的（SFTP 给不出"权限位缺席"这种条目），可一旦语料脚本
    /// 整个挂了，全部格子一起跳过，报告就是一片绿——比红更危险。
    ///
    /// 第一版这里断言"一格 passed 都不该有"，跑出来是红的：`..` 越界钳制与尾部斜杠
    /// 那两格**对任何根都成立**，它们本来就该绿。所以正确的断言是"绝大多数格子
    /// 没法绿"——留一个下限，让"语料整个没铺"和"语料缺一小块"能区分开。
    @Test("语料整体缺失时依赖语料的格子不会假装全绿")
    func missingCorpusIsVisible() async throws {
        let connection = try await connected(port: selectedPorts.first ?? 2202)
        defer { Task { await connection.close() } }

        // 指向一个必定不存在的目录。
        let absent = try PathResolver.child(of: try await connection.homeDirectory(),
                                            name: Array("spike/contract-absent-\(UUID().uuidString)".utf8))
        let subject = ContractSubject(label: "sftp:absent-corpus",
                                      fileSystem: SFTPContractAdapter(connection),
                                      capabilities: sftpCapabilities, corpusRoot: absent)
        let results = await FileSystemContract.run(subject)

        let passed = results.values.filter { $0.isPassed }.count
        #expect(passed < results.count / 2,
                "语料不存在却有 \(passed)/\(results.count) 格通过——契约在骗人")

        // 具体地说：列目录那一格必须拿到失败或跳过，绝不能是"零条目"通过。
        let empty = results[FileSystemContract.emptyDirectoryListsNothing.name]
        guard let empty else {
            Issue.record("连空目录那一格都没跑到")
            return
        }
        #expect(!empty.isPassed, "对着不存在的目录列目录竟报通过")
    }

    /// 同一份语料两次列必须逐条相同。
    ///
    /// 这条不是重复劳动：契约套件是**并发**跑的（传输那几格会真的写文件），
    /// 所以要确认清单本身不随时间变化——否则"大目录一条不少"那格在有并发写的
    /// 时候测的是一个不断变化的集合，绿了也不知道绿的是什么。
    @Test("清单可重入：两次列出的条目集合完全一致")
    func listingIsRepeatable() async throws {
        let connection = try await connected(port: selectedPorts.first ?? 2202)
        defer { Task { await connection.close() } }

        let flat = try await corpusEntry(connection, ContractCorpus.flat)
        let first = try await connection.list(flat)
        let second = try await connection.list(flat)
        #expect(first.directory == second.directory)
        #expect(Set(first.entries.map(\.path)) == Set(second.entries.map(\.path)))
        #expect(first.entries.count >= ContractCorpus.minimumLargeDirectoryCount,
                "语料不足 \(ContractCorpus.minimumLargeDirectoryCount) 条，先跑 seed-contract-corpus.sh")
    }

    /// `stat` 与 `lstat` 对同一条链必须给出不同类型。
    ///
    /// SFTP 的 `SSH_FXP_LSTAT` 与 `SSH_FXP_STAT` 是两个 opcode，libssh2 分别映射；
    /// 这一格防的是"两边都走了同一个 opcode"这种退化——它在 UI 上的表现是
    /// 软链永远显示成目标，而同步引擎按这个类型去递归或去读。
    @Test("stat 与 lstat 对软链给出不同类型")
    func statFollowsLinksButLstatDoesNot() async throws {
        let connection = try await connected(port: selectedPorts.first ?? 2202)
        defer { Task { await connection.close() } }

        let link = try await corpusEntry(connection, ContractCorpus.relativeLink)
        let linked = try await connection.lstat(link)
        let followed = try await connection.stat(link)
        #expect(linked.kind == .symbolicLink, "lstat 应给出链本身")
        #expect(followed.kind == .file, "stat 应跟到目标文件，实得 \(followed.kind)")
        #expect(followed.path == link, "stat 不该把路径改写成目标")
    }
}
