import Foundation
import Testing
@testable import FerryCore

private func path(_ string: String) -> RemotePath {
    RemotePath(wireBytes: Array(string.utf8), isAbsolute: string.hasPrefix("/"))
}

private func lexicalPath(_ input: String, base: String = "/", home: String? = nil) throws -> RemotePath {
    let resolver = PathResolver(homeDirectory: home.map(path))
    return try resolver.lexicalResolve(path(input), relativeTo: path(base))
}

private func lexical(_ input: String, base: String = "/", home: String? = nil) throws -> String {
    try lexicalPath(input, base: base, home: home).displayString()
}

/// 用字典模拟远端软链，顺带记录 `linkTarget` 被调用了几次：
/// 每多一次就是一次真实往返，调用次数必须可控。
private final class FakeLinks {
    let table: [String: String]
    var lookedUp: [String] = []

    init(table: [String: String]) { self.table = table }

    func target(_ p: RemotePath) -> [UInt8]? {
        lookedUp.append(p.displayString())
        return table[p.displayString()].map { Array($0.utf8) }
    }
}

private func realpath(_ input: String, base: String = "/", links: FakeLinks, limit: Int = 40) throws -> String {
    let resolver = PathResolver(homeDirectory: nil, maxSymlinkExpansions: limit)
    let resolved = try resolver.resolve(path(input), relativeTo: path(base)) { links.target($0) }
    return resolved.displayString()
}

@Test("根、重复分隔符与尾部斜杠合并成唯一形态")
func separatorsCollapse() throws {
    #expect(try lexical("/") == "/")
    #expect(try lexical("//") == "/")
    #expect(try lexical("///a///b///") == "/a/b")
    #expect(try lexical("/a/b/") == "/a/b")
    // 空路径就是基准目录本身
    #expect(try lexical("", base: "/a/b") == "/a/b")
}

@Test("`.` 丢弃，`..` 就地消解且不越过根")
func dotSegments() throws {
    #expect(try lexical("/a/./b") == "/a/b")
    #expect(try lexical("/a/b/../c") == "/a/c")
    #expect(try lexical("/..") == "/")
    #expect(try lexical("/a/../../b") == "/b")
    #expect(try lexical("/a/../../../..") == "/")
    #expect(try lexical("./a") == "/a", "基准为根时 ./a 不会多出一段")
}

@Test("相对路径以已解析的基准目录为前缀")
func relativeAgainstBase() throws {
    #expect(try lexical("a", base: "/home/u") == "/home/u/a")
    #expect(try lexical("../a", base: "/home/u/projects") == "/home/u/a")
    #expect(try lexical("a/..", base: "/home/u") == "/home/u")
    #expect(try lexical("/etc", base: "/home/u") == "/etc", "绝对输入忽略基准目录")
    #expect(try lexical("b/c/", base: "/home/u/../v") == "/home/v/b/c")
}

@Test("基准目录不是绝对路径或含 NUL 属于调用方 bug，必须在发出请求前报错")
func invalidInputRejects() {
    _ = #expect(throws: PathResolutionError.baseNotAbsolute) { try lexical("a", base: "home/u") }
    _ = #expect(throws: PathResolutionError.nulByte) { try lexical("/a\u{0}b") }
    _ = #expect(throws: PathResolutionError.nulByte) { try lexical("a", base: "/a\u{0}b") }
}

@Test("`~` 与 `~/` 展开成家目录，`~user` 拒绝猜测")
func tildeExpansion() throws {
    #expect(try lexical("~", home: "/home/u") == "/home/u")
    #expect(try lexical("~/../etc", home: "/home/u") == "/home/etc")
    #expect(try lexical("~/", home: "/home/u/") == "/home/u")
    // 名字真以 ~ 开头的条目要写成 ./~foo，语义与 shell 一致：`.` 挡住了展开
    #expect(try lexical("./~foo", base: "/home/u", home: "/home/u") == "/home/u/~foo")
    // 只有位置 0 的 ~ 才有展开含义
    #expect(try lexical("/~bob/x", home: "/home/u") == "/~bob/x")

    _ = #expect(throws: PathResolutionError.homeExpansionUnsupported(text: "~bob/x")) {
        try lexical("~bob/x", home: "/home/u")
    }
    _ = #expect(throws: PathResolutionError.homeExpansionUnsupported(text: "~bob")) {
        try lexical("~bob", home: "/home/u")
    }
    _ = #expect(throws: PathResolutionError.homeDirectoryUnknown) { try lexical("~/x") }
}

@Test("解析只动分隔符，非 UTF-8 字节与 NFD 组合序列原样保留")
func bytesAreNeverRewritten() throws {
    let gbk = try PathResolver().lexicalResolve(
        RemotePath(wireBytes: [0x2F, 0xCA, 0xD6], isAbsolute: true),
        relativeTo: PathResolver.root
    )
    #expect(gbk.wireBytes == [0x2F, 0xCA, 0xD6])
    // displayString 是整条路径级降级：一个坏字节就让整条按 \xNN 呈现，不做有损替换
    #expect(gbk.displayString() == "\\x2f\\xca\\xd6")

    // Swift 的 `String ==` 按 Unicode 标准等价判等，会把 NFD 与 NFC 判成相等：
    // 想证明"字节没被改写"只能比 wireBytes，比字符串会给出假的通过。
    let nfd = try lexicalPath("/\u{65}\u{301}/")
    let precomposed = try lexicalPath("/\u{E9}")
    #expect(nfd.wireBytes == Array("/\u{65}\u{301}".utf8), "NFC 只属于 ComparisonKey，绝不能用于寻址")
    #expect(nfd.wireBytes != precomposed.wireBytes)
}

@Test("拼接条目名不会产生 `//name`，也不会吞掉根")
func childJoining() throws {
    let root = PathResolver.root
    #expect(try PathResolver.child(of: root, name: Array("a".utf8)).wireBytes == [0x2F, 0x61])
    #expect(try PathResolver.child(of: path("/a"), name: Array("b".utf8)).wireBytes == [0x2F, 0x61, 0x2F, 0x62])
    _ = #expect(throws: PathResolutionError.emptyComponentName) {
        try PathResolver.child(of: root, name: [])
    }
    _ = #expect(throws: PathResolutionError.nulByte) {
        try PathResolver.child(of: root, name: [0x61, 0x00])
    }
    // 尾部斜杠的父路径不能拼出 `//name`
    #expect(try PathResolver.child(of: path("/a/"), name: Array("b".utf8)).wireBytes == [0x2F, 0x61, 0x2F, 0x62])
    // 父路径不绝对时拼出的"伪绝对"路径会把错误推迟到远端，必须当场拒绝
    _ = #expect(throws: PathResolutionError.baseNotAbsolute) {
        try PathResolver.child(of: path("a"), name: Array("b".utf8))
    }
}

@Test("软链目标为绝对路径时整段前缀重置")
func symlinkAbsoluteTarget() throws {
    let links = FakeLinks(table: ["/a": "/b"])
    #expect(try realpath("/a/c", links: links) == "/b/c")
    // 只查推进到的前缀：/a 命中软链，/b 与 /b/c 是随后推进的两段
    #expect(links.lookedUp == ["/a", "/b", "/b/c"])
}

@Test("软链目标为相对路径时接在软链所在目录上")
func symlinkRelativeTarget() throws {
    let nested = FakeLinks(table: ["/x/a": "y/z"])
    #expect(try realpath("/x/a", links: nested) == "/x/y/z")

    // /x/a -> ../sibling 的内核结果就是 /sibling：回退发生在软链所在目录
    let upward = FakeLinks(table: ["/x/a": "../sibling"])
    #expect(try realpath("/x/a/b", links: upward) == "/sibling/b")
}

@Test("`..` 在软链之后回退的是软链解析出的目录")
func parentAfterSymlink() throws {
    let links = FakeLinks(table: ["/b": "/x/y"])
    #expect(try realpath("/b/..", links: links) == "/x")
    // 词法解析先消掉 ..，同一条路径会得 /：两个 API 的差别必须可测
    #expect(try lexical("/b/..") == "/")
}

@Test("软链链式展开会一路跟到底，末段软链同样展开")
func symlinkChain() throws {
    let links = FakeLinks(table: ["/l1": "/l2", "/l2": "/l3", "/l3": "final"])
    #expect(try realpath("/l1", links: links) == "/final")
    #expect(links.lookedUp == ["/l1", "/l2", "/l3", "/final"])

    let trailing = FakeLinks(table: ["/a": "/b"])
    #expect(try realpath("/a", links: trailing) == "/b", "与 open 语义一致，保留软链本身要另走 lstat")
}

@Test("成环软链在深度上限处停止而不是死循环")
func symlinkLoopIsBounded() {
    let links = FakeLinks(table: ["/loop": "/loop"])
    _ = #expect(throws: PathResolutionError.tooManySymlinkExpansions(limit: 3)) {
        try realpath("/loop", links: links, limit: 3)
    }
    #expect(links.lookedUp.count == 4, "第 4 次查表时越界即抛，之后不再推进")

    let chain = FakeLinks(table: ["/l1": "/l2", "/l2": "/l3", "/l3": "/l4", "/l4": "/l5", "/l5": "/done"])
    _ = #expect(throws: PathResolutionError.tooManySymlinkExpansions(limit: 4)) {
        try realpath("/l1", links: chain, limit: 4)
    }

    // 服务器返回含 NUL 的软链目标：POSIX 会在 NUL 处截断，必须报错而不是静默截短
    _ = #expect(throws: PathResolutionError.nulByte) {
        try realpath("/l1", links: FakeLinks(table: ["/l1": "/\u{0}"]), limit: 4)
    }
}

@Test("家目录展开与基准目录共用同一套规则，软链照常解析")
func symlinkWithBaseAndHome() throws {
    let links = FakeLinks(table: ["/home/u": "/srv/data"])
    let resolver = PathResolver(homeDirectory: path("/home/u"))
    let resolved = try resolver.resolve(path("~/x"), relativeTo: path("/tmp")) { links.target($0) }
    #expect(resolved.displayString() == "/srv/data/x")
    #expect(links.lookedUp == ["/home", "/home/u", "/srv", "/srv/data", "/srv/data/x"])
}
