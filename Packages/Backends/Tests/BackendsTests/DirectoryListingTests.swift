import CLibssh2
import FerryCore
import Foundation
import Testing

@testable import FerryBackendsSFTP

/// M1'-5 的验收：目录列表只经 `opendir` + `readdir`（ADR-0001 D8），三个 M0b 模块
/// 在正式路径上真的接上了，软链的解析结果缓存回这张清单。
///
///     swift test --package-path Packages/Backends                        # 属性映射，不联网
///     FERRY_LIVE_SERVERS=1 swift test --package-path Packages/Backends   # 再加五台真机
///
/// 真机组断言的 1002 条、13 条链、255 字节名和那个 GBK 名，全部来自
/// `Spike/Scripts/seed-listing-corpus.sh` 铺的语料；跑之前先铺（docs/spike/M1-05 §2）。
/// 字符集默认按 GBK 配置——这一层要证的正是"名字按字节走、显示才按配置解"（R5）。
private let liveServersEnabled = ProcessInfo.processInfo.environment["FERRY_LIVE_SERVERS"] == "1"
private let goodPassword = "testpass"
private let allPorts = [2201, 2202, 2203, 2204, 2205]

private struct TestFailure: Error, CustomStringConvertible {
    let detail: String
    init(_ detail: String) { self.detail = detail }
    var description: String { detail }
}

private struct AcceptAllTrust: HostKeyTrust {
    func evaluate(endpoint: Endpoint, hostKey: HostKey) async throws {}
}

// MARK: - 夹具

private func attributes(flags: UInt, size: UInt64 = 0, uid: UInt = 0, gid: UInt = 0,
                        permissions: UInt = 0, mtime: UInt = 0) -> LIBSSH2_SFTP_ATTRIBUTES {
    var attrs = LIBSSH2_SFTP_ATTRIBUTES()
    attrs.flags = flags
    attrs.filesize = size
    attrs.uid = uid
    attrs.gid = gid
    attrs.permissions = permissions
    attrs.mtime = mtime
    attrs.atime = mtime
    return attrs
}

private func at(_ text: String, absolute: Bool = true) -> RemotePath {
    guard let path = RemotePath(string: text, isAbsolute: absolute) else {
        preconditionFailure("夹具里的路径拼不出来：\(text)")
    }
    return path
}

/// 语料里的目录都挂在登录目录下（2201 的 chroot 视图根是 `/`，同一份语料在那儿是
/// `/spike/list`，所以基准必须由服务器给，不能写死）。
private func child(_ parent: RemotePath, _ name: String) throws -> RemotePath {
    try PathResolver.child(of: parent, name: Array(name.utf8))
}

/// 路径的最后一段。名字比对一律按字节，不比 `String`——GBK 名不是合法 UTF-8。
private func lastComponent(_ path: RemotePath) -> [UInt8] {
    guard let slash = path.wireBytes.lastIndex(of: 0x2F) else { return path.wireBytes }
    return Array(path.wireBytes[path.wireBytes.index(after: slash)...])
}

private func outcome(_ body: () async throws -> some Any) async -> String {
    do { _ = try await body(); return "ok" }
    catch is CancellationError { return "cancelled" }
    catch let error as RemoteError { return error.diagnosticCode }
    catch let error as PathResolutionError { return "lexical(\(error))" }
    catch { return "other(\(error))" }
}

private func connected(port: Int = 2202, charset: CharsetConverter.Charset = .gbk) async throws
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

// MARK: - 属性映射（不联网）

@Test("属性包没给的字段一律 nil：不许拿 0 当\"服务器说了 0\"")
func absentAttributeFieldsStayNil() {
    // 只给 SIZE 一位：权限没给，类型就判不出来；uid/gid/mtime 也没给。
    let onlySize = SFTPAttributes.item(
        path: at("/spike/a"),
        attrs: attributes(flags: SFTPAttributes.attrSize, size: 4096))
    #expect(onlySize.size == 4096 && onlySize.sizeIsExact)
    #expect(onlySize.permissions == nil)
    #expect(onlySize.kind == .unknown, "权限位缺席时不许猜成 file：\(onlySize.kind)")
    #expect(onlySize.modificationDate == nil && !onlySize.mtimeIsReliable)
    #expect(onlySize.uid == nil && onlySize.gid == nil)

    // 一个位都没给：整条都是"知道有这个东西"而已。
    let bare = SFTPAttributes.item(path: at("/spike/b"), attrs: attributes(flags: 0))
    #expect(bare.size == nil && !bare.sizeIsExact)
    #expect(bare.permissions == nil && bare.kind == .unknown)
    #expect(bare.modificationDate == nil)
}

@Test("类型靠 permissions & 0o170000 判出来：S_IS* 宏在 Swift 侧导不进来")
func kindComesFromFileTypeBits() {
    func kind(_ bits: UInt) -> RemoteItemKind {
        SFTPAttributes.item(path: at("/spike/x"),
                           attrs: attributes(flags: SFTPAttributes.attrPermissions,
                                             permissions: bits | 0o644)).kind
    }
    #expect(kind(SFTPAttributes.typeRegular) == .file)
    #expect(kind(SFTPAttributes.typeDirectory) == .directory)
    #expect(kind(SFTPAttributes.typeLink) == .symbolicLink)
    #expect(kind(SFTPAttributes.typeSocket) == .other)
    #expect(kind(SFTPAttributes.typeFifo) == .other)
    #expect(kind(SFTPAttributes.typeFileBlock) == .other)
    #expect(kind(SFTPAttributes.typeFileCharacter) == .other)
    // 表外的类型值不能悄悄变成 file 或 directory：那是 UI 拿去当"能打开"的依据。
    #expect(kind(0o160000) == .other)
    // setuid 等模式位与类型位共存，掩码必须只看高 4 位。
    #expect(kind(SFTPAttributes.typeRegular | 0o4000) == .file)
}

@Test("属主名拿不到：扩展段被 sftp_bin2attr 丢弃，只有数字 uid/gid")
func ownerAndGroupAreNeverDerived() {
    let entry = SFTPAttributes.item(path: at("/spike/x"), attrs: attributes(
        flags: SFTPAttributes.attrUidGid | SFTPAttributes.attrExtended,
        uid: 1500, gid: 1501, permissions: SFTPAttributes.typeRegular))
    #expect(entry.uid == 1500 && entry.gid == 1501)
    #expect(entry.owner == nil && entry.group == nil)
    #expect(SFTPAttributes.hasExtended(attrs: attributes(flags: SFTPAttributes.attrExtended)))
}

@Test("时间戳按秒给：mtimeIsReliable 说的是\"真来自服务器\"，不是精度")
func timestampsCarrySecondsPrecision() {
    let entry = SFTPAttributes.item(path: at("/spike/x"), attrs: attributes(
        flags: SFTPAttributes.attrAcModTime, mtime: 1_700_000_000))
    #expect(entry.modificationDate == Date(timeIntervalSince1970: 1_700_000_000))
    #expect(entry.mtimeIsReliable)
}

@Test("字符集与比较策略取自连接配置，不取自路径字节")
func charsetAndPolicyComeFromRequest() async {
    let gbk = SFTPConnection(request: ConnectionRequest(
        endpoint: Endpoint(host: "127.0.0.1", port: 2299, username: "tester"),
        authentication: .password(goodPassword),
        policy: .standard,
        charset: .gbk),
        hostKeyTrust: AcceptAllTrust())
    let converter = await gbk.charsetConverter
    let bytes = Array("/gbk-".utf8) + [0xCE, 0xC4, 0xBC, 0xFE]
    #expect(converter.displayString(bytes) == "/gbk-文件")
    // 比较策略也取自连接：SFTP 那台是 POSIX，默认区分大小写 + NFC 归一。
    let policy = await gbk.pathPolicy
    #expect(policy.caseSensitive && policy.normalizeForCompare)

    let utf8 = SFTPConnection(request: ConnectionRequest(
        endpoint: Endpoint(host: "127.0.0.1", port: 2299, username: "tester"),
        authentication: .password(goodPassword),
        policy: .standard,
        charset: .utf8),
        hostKeyTrust: AcceptAllTrust())
    // 同一串字节按 UTF-8 解不出，只能出替代形式——寻址用的字节一个都没动。
    #expect(await utf8.charsetConverter.displayString(bytes) == "\\x2f\\x67\\x62\\x6b\\x2d\\xce\\xc4\\xbc\\xfe")
}

@Test("没握手就发文件系统请求是调用方的错，且不许碰 transport")
func filesystemCallBeforeHandshakeIsProtocolViolation() async {
    let connection = SFTPConnection(request: ConnectionRequest(
        endpoint: Endpoint(host: "127.0.0.1", port: 2299, username: "tester"),
        authentication: .password(goodPassword),
        policy: .standard),
        hostKeyTrust: AcceptAllTrust())
    #expect(await outcome { try await connection.list(at("/spike")) } == "protocolViolation")
    #expect(await outcome { try await connection.stat(at("/spike")) } == "protocolViolation")
    #expect(await outcome { try await connection.readlink(at("/spike")) } == "protocolViolation")
    #expect(await connection.phase == .idle)
    #expect(await connection.measure.file.channelInits == 0)
}

// MARK: - 真机：登录目录与列表

@Test("登录目录由 realpath(\".\") 给，五台各自不同", .enabled(if: liveServersEnabled))
func loginDirectoryIsServerProvided() async throws {
    for port in allPorts {
        let connection = try await connected(port: port)
        let home = try await connection.homeDirectory()
        #expect(home.isAbsolute && home.wireBytes.first == 0x2F, "\(port): \(home)")
        // 缓存：第二次拿基准目录不许再发请求（涨档之外不该有额外往返）。
        let again = try await connection.homeDirectory()
        #expect(again == home, "\(port) 两次 realpath(\".\") 给的答案不一样")
        #expect(await connection.measure.file.channelInits == 1, "\(port) 开了不止一条通道")
        await connection.close()
    }
}

@Test("1002 条目录一次列完：readdir 之外一个请求都不发（D8）", .enabled(if: liveServersEnabled))
func listingUsesReaddirOnly() async throws {
    let connection = try await connected()
    let home = try await connection.homeDirectory()
    let flat = try child(home, "spike/list/flat")
    let before = await connection.measure

    let listing = try await connection.list(flat)
    let after = await connection.measure

    #expect(listing.entries.count == 1002, "语料 1002 条，实际 \(listing.entries.count) 条")
    #expect(listing.directory == flat)
    // `.` 与 `..` 由服务器发来、由我们丢掉：观测数比清单多 2 就是这件事的证据。
    #expect(after.file.entriesObserved - before.file.entriesObserved == 1004)
    #expect(listing.entries.allSatisfy {
        let leaf = lastComponent($0.path)
        return leaf != [0x2E] && leaf != [0x2E, 0x2E] })
    // D8 的硬指标：列目录期间既没有逐条 stat，也没有任何 readlink。
    #expect(after.file.statCalls - before.file.statCalls == 0)
    #expect(after.file.linkProbes - before.file.linkProbes == 0)
    // 一个包摊出几十条，而不是每条一个包。
    #expect(after.file.readdirPackets - before.file.readdirPackets <= 20)
    #expect(listing.duplicatePaths.isEmpty)
    await connection.close()
}

@Test("五台的 readdir 属性包都给得出五个字段", .enabled(if: liveServersEnabled))
func attributesPresentOnEveryServer() async throws {
    for port in allPorts {
        let connection = try await connected(port: port)
        let home = try await connection.homeDirectory()
        let listing = try await connection.list(child(home, "spike/list/flat"))
        let missing = listing.entries.filter {
            $0.size == nil || $0.permissions == nil || $0.modificationDate == nil
                || $0.uid == nil || $0.gid == nil
        }
        #expect(missing.isEmpty, "\(port) 有 \(missing.count) 条属性不全")
        #expect(listing.entries.allSatisfy { $0.kind == .file }, "\(port) 类型判错")
        // 属主名在协议上就给不出（扩展段被丢掉），这里把它钉成断言，防止日后"顺手补上"。
        #expect(listing.entries.allSatisfy { $0.owner == nil && $0.group == nil })
        await connection.close()
    }
}

@Test("软链：清单里没有目标，resolve 才去要；第二遍一个请求都不发",
    .enabled(if: liveServersEnabled))
func linkResolutionIsCachedOnTheListing() async throws {
    let connection = try await connected()
    let home = try await connection.homeDirectory()
    var listing = try await connection.list(child(home, "spike/list/links"))
    let links = listing.entries.filter { $0.kind == .symbolicLink }
    #expect(links.count == 13, "语料 13 条链，判出 \(links.count) 条")
    // readdir 的属性包不带目标：要拿目标必须一条一次往返，所以它不属于 list()。
    #expect(listing.entries.allSatisfy { $0.linkTarget == nil })

    let before = await connection.measure
    var resolutions: [RemotePath: RemoteDirectoryListing.LinkResolution] = [:]
    for link in links {
        guard let resolution = try await connection.resolve(link, in: &listing) else {
            throw TestFailure("\(link.path) 判为链却解析出 nil")
        }
        resolutions[link.path] = resolution
    }
    let pass1 = await connection.measure
    #expect(pass1.file.linkProbes - before.file.linkProbes > 0)
    #expect(pass1.file.linkCacheHits - before.file.linkCacheHits > 0,
            "13 条链共用同一段前缀，缓存却一次都没命中")
    #expect(listing.resolutions.count == 13)
    #expect(listing.staleResolutionCount == 0)

    // 第二遍只读缓存：查询数不许再涨，命中数按条数涨。
    let before2 = await connection.measure
    for link in links { _ = try await connection.resolve(link, in: &listing) }
    let pass2 = await connection.measure
    #expect(pass2.file.linkProbes - before2.file.linkProbes == 0, "同一张清单的第二遍又走了网络")
    #expect(pass2.file.linkCacheHits - before2.file.linkCacheHits == links.count)

    // 链上叠链要展开到底：`l_chain -> l_to_file -> ../dir/file`，两条必须落同一处。
    let name = { (path: RemotePath) in String(decoding: path.wireBytes, as: UTF8.self) }
    guard let chained = resolutions.first(where: { name($0.key).hasSuffix("l_chain") })?.value,
          let plain = resolutions.first(where: { name($0.key).hasSuffix("l_to_file") })?.value
    else { throw TestFailure("语料里没有 l_chain / l_to_file") }
    #expect(chained.resolved == plain.resolved, "\(chained.resolved?.wireBytes ?? []) != \(plain.resolved?.wireBytes ?? [])")
    #expect(chained.target != nil && plain.target != nil)

    // 断链：目标读得到，词法结果也给得出，只是那条东西不在对面。
    guard let broken = resolutions.first(where: { name($0.key).hasSuffix("l_broken") })?.value else {
        throw TestFailure("语料里没有 l_broken")
    }
    #expect(broken.target != nil && broken.resolved != nil)
    await connection.close()
}

@Test("`-38` 那一格只多花一次往返：1504 字节的目标要涨一档才装得下",
    .enabled(if: liveServersEnabled))
func oversizedTargetGrowsTheBufferAndRetries() async throws {
    let connection = try await connected()
    let home = try await connection.homeDirectory()
    let before = await connection.measure
    let target = try await connection.readlink(child(home, "spike/list/links/l_long"))
    let after = await connection.measure

    #expect(target.wireBytes.count == 1504, "拿到 \(target.wireBytes.count) 字节")
    #expect(after.file.bufferGrowths - before.file.bufferGrowths == 1)
    // 目标相对就留相对，绝不预先拼接（拼接属于 PathResolver）。
    #expect(target.isAbsolute)
    #expect(String(decoding: target.wireBytes.prefix(6), as: UTF8.self) == "/home/")
    await connection.close()
}

@Test("GBK 名按字节命中，显示按连接配置解（R5）", .enabled(if: liveServersEnabled))
func nonUtf8NameSurvivesAsBytes() async throws {
    let name = Array("gbk-".utf8) + [0xCE, 0xC4, 0xBC, 0xFE] + Array(".txt".utf8)
    let connection = try await connected(port: 2202, charset: .gbk)
    let home = try await connection.homeDirectory()
    let directory = try child(home, "spike/list/flat")
    let listing = try await connection.list(directory)
    guard let hit = listing.entries.first(where: { lastComponent($0.path) == name }) else {
        throw TestFailure("GBK 名按字节没找到：清单里最长名 "
                          + "\(listing.entries.map { lastComponent($0.path).count }.max() ?? 0) 字节")
    }
    // 字节进、字节出，一个都没被替代字符吃掉；NAME_MAX 255 的名字也照样完整回来。
    #expect(hit.path.wireBytes == directory.wireBytes + [0x2F] + name)
    let display = await connection.charsetConverter.displayString(hit.path.wireBytes)
    #expect(display.hasSuffix("gbk-文件.txt"))
    #expect(listing.entries.contains { lastComponent($0.path).count == 255 })
    await connection.close()
}

@Test("失败两类：服务器明说的失败之后连接还能用", .enabled(if: liveServersEnabled))
func serverSaidFailuresKeepTransport() async throws {
    for port in allPorts {
        let connection = try await connected(port: port)
        let home = try await connection.homeDirectory()
        let root = try child(home, "spike/list")

        #expect(await outcome { try await connection.list(child(root, "nope")) } == "notFound")
        #expect(await outcome { try await connection.stat(child(root, "nope")) } == "notFound")
        #expect(await outcome { try await connection.list(child(root, "noperm")) } == "permissionDenied")
        #expect(await connection.phase == .authenticated, "\(port) 被服务器拒绝之后就废了")

        // 相对路径与 `~` 在发出任何字节之前就被消化掉（M0b-01 §0 结论 2/3）。
        #expect(await outcome { try await connection.list(at("./spike/list/dir", absolute: false)) } == "ok")
        #expect(await outcome { try await connection.list(at("~")) } == "ok")
        #expect(await outcome { try await connection.list(at("./nope", absolute: false)) } == "notFound")
        #expect(await outcome { try await connection.list(RemotePath(wireBytes: [0x2F, 0x00], isAbsolute: true)) }
                    == "lexical(nulByte)")
        #expect(await outcome { try await connection.list(child(root, "dir")) } == "ok")
        await connection.close()
    }
}

@Test("`symlink_ex` 的失败只报 undetermined：那个\"状态码\"其实是请求 id",
    .enabled(if: liveServersEnabled))
func symlinkFamilyFailuresNeverFabricateAStatus() async throws {
    for port in allPorts {
        // 对照组先走一遍：同一台、同一批路径上，`sftp_stat()` 那条路照样给得出真码。
        let good = try await connected(port: port)
        let home = try await good.homeDirectory()
        let root = try child(home, "spike/list")
        #expect(await outcome { try await good.stat(child(root, "nope")) } == "notFound")
        #expect(await outcome { try await good.lstat(child(root, "nope")) } == "notFound")
        #expect(await outcome { try await good.list(child(root, "noperm")) } == "permissionDenied")
        let rawTarget = try await good.readlink(child(root, "links/l_to_file"))
        #expect(rawTarget.wireBytes == Array("../dir/file".utf8))
        #expect(await good.phase == .authenticated)
        await good.close()

        // 0008 补丁把 `sftp_symlink()` 的 STATUS 分支读成"type 之后第一个 u32"，而那一格
        // 是请求 id。id 落进 0…21 时分类器会把它当状态码读成 `noSuchFile(2)`、
        // `permissionDenied(3)`、`connectionLost(7)`、`noSuchPath(10)`：前两个会把同步引擎
        // 支去删本地文件，后一个把确定性失败变成可重试。所以这一族一律不采信状态，
        // 原始 C 的逐发实测见 docs/spike/M1-05 §9。
        let connection = try await connected(port: port)
        let home2 = try await connection.homeDirectory()
        let root2 = try child(home2, "spike/list")
        #expect(await outcome { try await connection.readlink(child(root2, "nope")) }
                    == "ssh/undetermined(rc=-31)@readlink")
        // 判不出成因 = 连"服务器到底说了什么"都不知道，这条 session 就不该留给下一次调用
        // （`keepsTransportAfter` 的既有规则，M1-04 §2 那套判据）。
        #expect(await connection.phase == .aborted)
    }
}

@Test("清单自带的类型位挡住非链条目；走链时每段一发 lstat、readlink 只给真是链的那段",
    .enabled(if: liveServersEnabled))
func segmentProbesChargeOneLstatPerSegment() async throws {
    let connection = try await connected()
    let home = try await connection.homeDirectory()

    // ① readdir 的包已经写着"这是普通文件"：`resolve` 再问服务器一次就是纯浪费。
    var dirListing = try await connection.list(child(home, "spike/list/dir"))
    guard let plain = dirListing.entries.first(where: { $0.kind == .file }) else {
        throw TestFailure("语料 dir 里没有普通文件条目：\(dirListing.entries.map(\.kind))")
    }
    let beforePlain = await connection.measure
    let onPlain = try await connection.resolve(plain, in: &dirListing)
    let afterPlain = await connection.measure
    #expect(onPlain == nil)
    #expect(afterPlain.file.linkSegmentStats == beforePlain.file.linkSegmentStats)
    #expect(afterPlain.file.linkProbes == beforePlain.file.linkProbes)

    // ② 走一条链：沿途每一段都要问，但只有真是链的那些段值得发 READLINK。
    //    `l_to_file -> ../dir/file` 这一路上只有末段是链，展开后的 `dir`/`file` 都不是。
    var links = try await connection.list(child(home, "spike/list/links"))
    guard let toFile = links.entries.first(where: { lastComponent($0.path) == Array("l_to_file".utf8) })
    else { throw TestFailure("语料 links 里没有 l_to_file") }
    let before = await connection.measure
    guard let resolution = try await connection.resolve(toFile, in: &links) else {
        throw TestFailure("l_to_file 判不出是链")
    }
    let after = await connection.measure
    #expect(after.file.linkSegmentStats - before.file.linkSegmentStats == resolution.segmentsLookedUp,
            "段数 \(resolution.segmentsLookedUp)，lstat 却发了 \(after.file.linkSegmentStats - before.file.linkSegmentStats) 次")
    #expect(after.file.linkProbes - before.file.linkProbes == 1)
    #expect(resolution.target?.wireBytes == Array("../dir/file".utf8))

    // "问过、答案是它不是链"也必须进缓存：那些段的值是 nil，但不许再问第二遍。
    let negatives = links.probes.values.filter { $0 == nil }.count
    #expect(negatives == resolution.segmentsLookedUp - 1)
    let beforeAgain = await connection.measure
    _ = try await connection.resolve(toFile, in: &links)
    let again = await connection.measure
    #expect(again.file.linkSegmentStats == beforeAgain.file.linkSegmentStats)
    #expect(again.file.linkProbes == beforeAgain.file.linkProbes)
    await connection.close()
}

@Test("真机文件调用的 C 调用不超过两条线程（D7）", .enabled(if: liveServersEnabled))
func filesystemCallsStayWithinTwoThreads() async throws {
    let connection = try await connected()
    let home = try await connection.homeDirectory()
    _ = try await connection.list(child(home, "spike/list/flat"))
    var listing = try await connection.list(child(home, "spike/list/links"))
    for link in listing.entries.filter({ $0.kind == .symbolicLink }) {
        _ = try await connection.resolve(link, in: &listing)
    }
    let measure = await connection.measure
    #expect(measure.executorThreads.count <= 2, "跨了 \(measure.executorThreads.count) 条线程")
    #expect(measure.file.channelInits == 1)
    await connection.close()
}
