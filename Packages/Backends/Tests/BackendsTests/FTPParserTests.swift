import FerryBackendsFTP
import FerryCore
import Foundation
import Testing

@Suite("M5: FTP 目录与解析器测试")
struct FTPParserTests {

    private let rootPath = RemotePath(string: "/remote/dir", isAbsolute: true)!
    private let converter = CharsetConverter(charset: .utf8)

    @Test("MLSD 格式解析：文件、文件夹与时间戳精确解析")
    func testMLSDParsing() throws {
        let mlsdData = """
        type=file;size=2048;modify=20261017143000; document.pdf
        type=dir;modify=20261016100000; assets
        type=cdir;modify=20261016100000; .
        type=pdir;modify=20261016100000; ..
        """.data(using: .utf8)!

        let items = FTPParser.parseListing(data: mlsdData, directory: rootPath, charsetConverter: converter)

        #expect(items.count == 2)

        let file = try #require(items.first { $0.path.lastComponent?.displayString() == "document.pdf" })
        #expect(file.kind == .file)
        #expect(file.size == 2048)
        #expect(file.sizeIsExact == true)
        #expect(file.mtimeIsReliable == true)

        let dir = try #require(items.first { $0.path.lastComponent?.displayString() == "assets" })
        #expect(dir.kind == .directory)
        #expect(dir.size == nil)
    }

    @Test("Unix LIST 格式解析：权限、大小、日期与软链解析")
    func testUnixListParsing() throws {
        let listData = """
        drwxr-xr-x   3 tester staff      4096 Oct 17 12:00 folder
        -rw-r--r--   1 tester staff       512 Oct 17 12:00 script.sh
        lrwxrwxrwx   1 tester staff        12 Oct 17 12:00 link.sh -> script.sh
        drwxr-xr-x   2 tester staff      4096 Oct 17 12:00 .
        drwxr-xr-x   2 tester staff      4096 Oct 17 12:00 ..
        """.data(using: .utf8)!

        let items = FTPParser.parseListing(data: listData, directory: rootPath, charsetConverter: converter)

        #expect(items.count == 3)

        let folder = try #require(items.first { $0.path.lastComponent?.displayString() == "folder" })
        #expect(folder.kind == .directory)
        #expect(folder.permissions == 0o755)

        let script = try #require(items.first { $0.path.lastComponent?.displayString() == "script.sh" })
        #expect(script.kind == .file)
        #expect(script.size == 512)
        #expect(script.permissions == 0o644)

        let link = try #require(items.first { $0.path.lastComponent?.displayString() == "link.sh" })
        #expect(link.kind == .symbolicLink)
        #expect(link.linkTarget?.displayString() == "script.sh")
    }

    @Test("FTPBackend 能力声明")
    func testFTPBackendCapabilities() {
        let backend = FTPBackend(isFTPS: false)
        #expect(backend.declaredCapabilities.contains(.resumableDownload))
        #expect(backend.declaredCapabilities.contains(.resumableUpload))
        #expect(backend.declaredCapabilities.contains(.reliableMTime))
        #expect(backend.declaredCapabilities.contains(.charsetNegotiation))
        #expect(!backend.declaredCapabilities.contains(.symbolicLinks))
    }
}
