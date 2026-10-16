import Foundation
import Testing
@testable import FerryCore

/// M1'-5：目录清单的缓存模型。
///
/// 这一层没有网络，但它管的正是"哪一段可以不再问服务器"——错一格就是同步引擎
/// 拿着上一次的解析结果比对现在的内容（`RemoteDirectoryListing` 顶部那段理由）。
/// 所以这里的用例全部围绕三件事：命中判据、作废时机、撞名可见。

private func path(_ text: String) -> RemotePath {
    RemotePath(string: text, isAbsolute: true)!
}

private func item(_ text: String, kind: RemoteItemKind = .symbolicLink) -> RemoteItem {
    RemoteItem(path: path(text), kind: kind, size: nil, modificationDate: nil,
               sizeIsExact: false, mtimeIsReliable: false)
}

@Test("probes 分得清\"没问过\"与\"问过、它不是链\"")
func probeCacheDistinguishesAbsentFromNegative() {
    var listing = RemoteDirectoryListing(directory: path("/spike"), entries: [])
    let dir = path("/spike/dir1")

    #expect(!listing.hasProbe(for: dir))
    #expect(listing.probedTarget(for: dir) == nil)

    listing.noteProbe(dir, target: nil)          // 问过：这段是普通目录
    #expect(listing.hasProbe(for: dir))
    #expect(listing.probedTarget(for: dir) == nil)   // 值仍然是 nil，但含义已经变了

    listing.noteProbe(path("/spike/link"), target: path("/spike/dir1/file"))
    #expect(listing.probedTarget(for: path("/spike/link")) == path("/spike/dir1/file"))
    #expect(listing.probes.count == 2)
}

@Test("解析结果按条目路径存进清单，重新列一次就是全新的一张")
func resolutionsAreStoredPerEntryAndDieWithTheListing() {
    let link = item("/spike/link")
    var listing = RemoteDirectoryListing(directory: path("/spike"), entries: [link])
    #expect(listing.resolution(for: link) == nil)

    let resolution = RemoteDirectoryListing.LinkResolution(
        target: path("/spike/dir1/file"), resolved: path("/spike/dir1/file"), segmentsLookedUp: 2)
    listing.note(resolution, for: link)
    #expect(listing.resolution(for: link)?.segmentsLookedUp == 2)

    // 重新列目录：新清单不带任何缓存，否则远端改了链指向也看不出来。
    let relisted = RemoteDirectoryListing(directory: path("/spike"), entries: [link])
    #expect(relisted.resolution(for: link) == nil)
    #expect(relisted.probes.isEmpty)
    #expect(relisted.staleResolutionCount == 0)

    // 只有"把旧缓存并到新清单"这种用法才需要这个计数：它不为 0 就说明里面
    // 有上一次清单的条目，调用方得自己决定要不要留。
    var carried = relisted
    carried.note(resolution, for: link)
    #expect(carried.staleResolutionCount == 0)
    var carriedAway = relisted
    carriedAway.note(resolution, for: item("/spike/gone"))
    #expect(carriedAway.staleResolutionCount == 1)
}

@Test("同一绝对路径出现两次要能被检出来，静默覆盖是最坏的失效方式")
func duplicatePathsAreVisible() {
    let a = item("/spike/x", kind: .file)
    let b = item("/spike/x", kind: .directory)
    let listing = RemoteDirectoryListing(directory: path("/spike"), entries: [a, b, a])
    #expect(listing.duplicatePaths == [path("/spike/x")])
    #expect(listing.entries.count == 3)
    // 撞三遍也只列一次：这一格答的是"哪些名字撞了"，不是"撞了几手"。
    let thrice = RemoteDirectoryListing(directory: path("/spike"), entries: [a, a, a, b])
    #expect(thrice.duplicatePaths == [path("/spike/x")])
}

@Test("断链有 resolved 没有 target 也行；成环才是两个都拿不到")
func linkResolutionFieldsAreIndependent() {
    // 断链：目标读到了，只是那条目标不在文件系统里——词法结果照样给得出。
    let broken = RemoteDirectoryListing.LinkResolution(
        target: path("/spike/nowhere"), resolved: path("/spike/nowhere"), segmentsLookedUp: 1)
    #expect(broken.target != nil && broken.resolved != nil)

    // 相对目标保持相对：缓存里不预先拼接，拼接属于 PathResolver。
    let relative = RemoteDirectoryListing.LinkResolution(
        target: RemotePath(wireBytes: [0x2E, 0x2F, 0x66], isAbsolute: false),
        resolved: nil, segmentsLookedUp: 0)
    #expect(relative.target?.isAbsolute == false)
    #expect(relative.segmentsLookedUp == 0)
}

@Test("条目 id 用原始字节，非 UTF-8 名字既不撞车也不会被显示层吃掉")
func itemIdUsesWireBytes() {
    // 0xC4 0xE3 是 GBK 的"你"，同时在 UTF-8 下是残缺序列——正是 M0b-02 迷宫里那一类名字。
    let gbk = RemoteItem(path: RemotePath(wireBytes: [0x2F, 0xC4, 0xE3], isAbsolute: true),
                         kind: .file, size: nil, modificationDate: nil,
                         sizeIsExact: false, mtimeIsReliable: false)
    let other = RemoteItem(path: RemotePath(wireBytes: [0x2F, 0xC4, 0xE4], isAbsolute: true),
                           kind: .file, size: nil, modificationDate: nil,
                           sizeIsExact: false, mtimeIsReliable: false)

    #expect(gbk.id == [0x2F, 0xC4, 0xE3])
    #expect(gbk.id != other.id)

    // 按 UTF-8 配置：两条都只能按字节看，但转义结果仍然彼此不同——不会有"看着一样其实是两个"。
    let asUTF8 = CharsetConverter(charset: .utf8)
    #expect(gbk.path.displayString(using: asUTF8) == "\\x2f\\xc4\\xe3")
    #expect(other.path.displayString(using: asUTF8) != gbk.path.displayString(using: asUTF8))

    // 按 GBK 配置：解得开，而 wireBytes 一个字节都没动（R5：解码只影响显示）。
    let asGBK = CharsetConverter(charset: .gbk)
    #expect(asGBK.displayString(gbk.path.wireBytes) == "/你")
    #expect(gbk.path.wireBytes == [0x2F, 0xC4, 0xE3])
}
