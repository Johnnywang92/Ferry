import Foundation
import Testing
@testable import FerryCore

@Test("wireBytes 保留 NFC 与 NFD 两种写法为不同路径")
func wireBytesAreAuthoritative() {
    let nfc = RemotePath(string: "\u{65}\u{301}".precomposedStringWithCanonicalMapping, isAbsolute: false)!
    let nfd = RemotePath(string: "\u{65}\u{301}", isAbsolute: false)!
    #expect(nfc.wireBytes != nfd.wireBytes)
    #expect(nfc != nfd)

    let policy = PathPolicy(caseSensitive: true, normalizeForCompare: true)
    #expect(policy.key(for: nfc) == policy.key(for: nfd))
}

@Test("大小写敏感策略下不折叠 Foo/foo，不敏感时折叠")
func casePolicyDerivesKey() {
    let foo = RemotePath(string: "Foo.txt", isAbsolute: false)!
    let lower = RemotePath(string: "foo.txt", isAbsolute: false)!

    let linux = PathPolicy(caseSensitive: true, normalizeForCompare: true)
    #expect(linux.key(for: foo) != linux.key(for: lower))

    let apfs = PathPolicy(caseSensitive: false, normalizeForCompare: true)
    #expect(apfs.key(for: foo) == apfs.key(for: lower))
}

@Test("非法 UTF-8 文件名按十六进制展示，不做有损替换")
func undecodablePathDisplaysHex() {
    let gbk = RemotePath(wireBytes: [0xCA, 0xD6], isAbsolute: false)
    #expect(gbk.displayString() == "\\xca\\xd6")
}

@Test("只有 network 类错误可重试；auth 与会话致命错误分类正确")
func errorTaxonomy() {
    #expect(RemoteError.network(.timeout).isRetryable)
    #expect(!RemoteError.notFound(path: RemotePath(wireBytes: [0x2f], isAbsolute: true)).isRetryable)
    #expect(!RemoteError.permissionDenied(path: RemotePath(wireBytes: [0x2f], isAbsolute: true)).isRetryable)
    #expect(!RemoteError.auth(.badPassword).isFatalToSession)
    #expect(RemoteError.hostKeyMismatch(fingerprint: "SHA256:x").isFatalToSession)
    #expect(!RemoteError.network(.connectionLost).isFatalToSession)
}

@Test("mtime 不可靠的条目保留可信度标记供同步引擎判定")
func credibilityFlagsSurvive() {
    let item = RemoteItem(
        path: RemotePath(wireBytes: [0x2f, 0x61], isAbsolute: true),
        kind: .file,
        size: 10,
        modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
        sizeIsExact: false,
        mtimeIsReliable: false
    )
    #expect(!item.sizeIsExact)
    #expect(!item.mtimeIsReliable)
}
