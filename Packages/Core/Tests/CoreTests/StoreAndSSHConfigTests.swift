import Darwin
import FerryContracts
import FerryCore
import Foundation
import Testing

@Suite("M2 基础层与退出条件：Store、ScopedBookmark、SSHConfigParser 与三类边界路径传输")
struct StoreAndSSHConfigTests {

    private struct SampleRecord: Codable, Equatable, Sendable {
        let id: String
        let name: String
        let count: Int
    }

    @Test("Store 原子写 JSON，父目录 0700、文件 0600，往返一致")
    func storeAtomicReadWriteAndPermissions() async throws {
        let baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ferry-store-test-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("nested", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseDir.deletingLastPathComponent()) }

        let fileURL = baseDir.appendingPathComponent("sites.json")
        let store = Store<[SampleRecord]>(url: fileURL)

        let initial = try await store.read()
        #expect(initial == nil)

        let payload = [
            SampleRecord(id: "1", name: "生产环境 · 中文站点", count: 42),
            SampleRecord(id: "2", name: "special:star*name", count: 7)
        ]
        try await store.write(payload)

        let loaded = try await store.read()
        #expect(loaded == payload)

        // 核验目录 0700、文件 0600
        let dirPerm = ((try? FileManager.default.attributesOfItem(atPath: baseDir.path))?[.posixPermissions] as? NSNumber)?.intValue
        #expect(dirPerm == 0o700)

        let filePerm = ((try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.posixPermissions] as? NSNumber)?.intValue
        #expect(filePerm == 0o600)

        try await store.delete()
        #expect(try await store.read() == nil)
    }

    @Test("ScopedBookmark 保存路径与展开 ~，支持无 bookmarkData 的模式 A 直读")
    func scopedBookmarkResolution() throws {
        let bookmark = ScopedBookmark(path: "~/Projects/demo")
        #expect(!bookmark.isEmpty)
        #expect(bookmark.expandedPath.hasSuffix("/Projects/demo"))
        #expect(!bookmark.expandedPath.hasPrefix("~"))

        let resolved = bookmark.resolveURL()
        #expect(resolved.url.path == bookmark.expandedPath)
        #expect(resolved.isStale == false)
    }

    @Test("SSHConfigParser：多别名、通配块继承、~ 与 %h 展开、引号路径、ProxyJump 与弱算法识别")
    func sshConfigParsingComprehensive() {
        let configText = """
        # 顶层全局默认（在第一个 Host 之前）
        ServerAliveInterval 60

        Host *
            User globaluser
            Port 2222
            IdentityFile ~/.ssh/id_default

        Host prod staging *.corp.internal !blocked.corp.internal
            User deploy
            Port = 22022
            IdentityFile "~/.ssh/keys/my prod key" # 行尾注释但引号内空格保留

        Host prod
            HostName %h.corp.internal
            IdentitiesOnly yes

        Host legacy-box
            HostName 10.0.0.4
            User oldadmin
            HostKeyAlgorithms +ssh-rsa
            Ciphers +aes128-cbc
            ProxyJump bastion.corp.internal:22

        Host *.corp.internal
            IdentityFile ~/.ssh/id_corp
        """

        let entries = SSHConfigParser.parse(configText, homeDirectory: "/Users/tester")
        // 只有具体别名（prod, staging, legacy-box）进结果，通配符 *.corp.internal 和 !blocked 不进
        #expect(entries.map(\.alias) == ["prod", "staging", "legacy-box"])

        let prod = entries[0]
        #expect(prod.hostName == "prod.corp.internal")
        #expect(prod.user == "deploy")
        #expect(prod.port == 22022)
        #expect(prod.identitiesOnly == true)
        #expect(prod.proxyJump == nil)
        #expect(prod.prefersWeakAlgorithms == false)
        // 具体块优先于通配块，IdentityFile 按顺序累积去重
        #expect(prod.identityFiles == [
            "/Users/tester/.ssh/keys/my prod key",
            "/Users/tester/.ssh/id_default"
        ])

        let staging = entries[1]
        #expect(staging.hostName == "staging")
        #expect(staging.user == "deploy")
        #expect(staging.port == 22022)
        #expect(staging.identitiesOnly == false)

        let legacy = entries[2]
        #expect(legacy.hostName == "10.0.0.4")
        #expect(legacy.user == "oldadmin")
        #expect(legacy.port == 2222) // 继承自 Host *
        #expect(legacy.proxyJump == "bastion.corp.internal:22")
        #expect(legacy.prefersWeakAlgorithms == true)
        #expect(legacy.identityFiles == ["/Users/tester/.ssh/id_default"])
    }

    @Test("SSHConfigParser：否定模式 !pattern 阻止通配块命中")
    func sshConfigNegatedPattern() {
        let configText = """
        Host app-prod app-dev
            HostName %h.example.com

        Host app-* !app-prod
            User devops
            Port 2022
        """
        let entries = SSHConfigParser.parse(configText, homeDirectory: "/Users/tester")
        #expect(entries.count == 2)

        let prod = entries.first { $0.alias == "app-prod" }!
        let dev = entries.first { $0.alias == "app-dev" }!

        #expect(prod.user == nil)
        #expect(prod.port == 22)
        #expect(dev.user == "devops")
        #expect(dev.port == 2022)
    }

    // MARK: - M2 退出条件三项验收：中文名、超长路径、特殊字符名

    @Test("M2 退出条件 1：中文文件名（UTF-8 与 GBK 原始字节寻址、零网络往返重解码与上下传字节一致）")
    func chineseFilenameCharsetAndTransfer() async throws {
        let fs = InMemoryFileSystem(charset: .gbk)
        // "文件.txt" 的 GBK 字节：0xCE 0xC4 0xBC 0xFE . t x t
        let gbkNameBytes: [UInt8] = [0xCE, 0xC4, 0xBC, 0xFE, 0x2E, 0x74, 0x78, 0x74]
        let gbkFullBytes: [UInt8] = [0x2F] + gbkNameBytes
        let expectedData = Data("中文内容与 GBK 原始字节保真验证\n".utf8)

        try await fs.seedBytes([
            .init(gbkFullBytes, kind: .file, payload: Array(expectedData))
        ])

        let listing = try await fs.list(PathResolver.root)
        #expect(listing.entries.count == 1)
        let entry = listing.entries[0]

        // 1. UTF-8 解码时降级为十六进制，但原始字节完整保留；切换 GBK 立即还原为 "/文件.txt"
        let utf8Conv = CharsetConverter(charset: .utf8)
        #expect(utf8Conv.decode(gbkNameBytes) == .hexadecimal)
        #expect(entry.path.displayString(using: utf8Conv).contains("\\xce\\xc4"))

        let gbkConv = CharsetConverter(charset: .gbk)
        #expect(gbkConv.decode(gbkNameBytes) == .charset("文件.txt"))
        #expect(entry.path.displayString(using: gbkConv) == "/文件.txt")

        // 2. 用原始 wireBytes 下载与重上传（含 UTF-8 中文名），核对字节完全相等
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ferry-m2-zh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let downloadedURL = tempDir.appendingPathComponent("下载_文件_副本.txt")
        _ = try await TransferEngine.download(entry.path, to: downloadedURL, using: fs)
        #expect(try Data(contentsOf: downloadedURL) == expectedData)

        let utf8RemotePath = RemotePath(string: "/上传_中文报表_2026（终版）.txt", isAbsolute: true)!
        _ = try await TransferEngine.upload(from: downloadedURL, to: utf8RemotePath, using: fs)
        let statUploaded = try await fs.stat(utf8RemotePath)
        #expect(statUploaded.size == Int64(expectedData.count))
    }

    @Test("M2 退出条件 2：超长路径（12 层深层目录嵌套 + 255 字节 NAME_MAX 文件名导航与上下传）")
    func ultraLongPathNavigationAndTransfer() async throws {
        let fs = InMemoryFileSystem()
        let segments = (1...12).map { "level_\(String(format: "%02d", $0))_segment_dir" }
        // 构造恰好 255 字节的单段文件名（POSIX NAME_MAX = 255）
        let prefix = "long_"
        let suffix = ".dat"
        let fillerCount = 255 - prefix.utf8.count - suffix.utf8.count
        let maxFileName = prefix + String(repeating: "x", count: fillerCount) + suffix
        #expect(maxFileName.utf8.count == 255)

        let fullPathString = "/" + segments.joined(separator: "/") + "/" + maxFileName
        let payload = Data((0..<4096).map { UInt8($0 & 0xFF) })
        try await fs.seed([
            .init(String(fullPathString.dropFirst()), kind: .file, payload: Array(payload), permissions: 0o644)
        ])

        let deepDirPath = RemotePath(string: "/" + segments.joined(separator: "/"), isAbsolute: true)!
        let listing = try await fs.list(deepDirPath)
        #expect(listing.entries.count == 1)
        #expect(listing.entries[0].path.wireBytes == Array(fullPathString.utf8))

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ferry-m2-long-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let localFile = tempDir.appendingPathComponent(maxFileName)
        _ = try await TransferEngine.download(listing.entries[0].path, to: localFile, using: fs)
        #expect(try Data(contentsOf: localFile) == payload)
    }

    @Test("M2 退出条件 3：特殊字符文件名（含空格、星号、方括号、引号及前缀点隐藏文件）浏览与上下传")
    func specialCharacterFilenameAndTransfer() async throws {
        let fs = InMemoryFileSystem()
        let specialRemoteNames = [
            "report 2026 [final] *draft* 'v1'.txt",
            ".hidden_env_config"
        ]
        let sampleBytes = Array("special-chars-payload-ok\n".utf8)
        for name in specialRemoteNames {
            try await fs.seed([.init(name, kind: .file, payload: sampleBytes, permissions: 0o600)])
        }

        let listing = try await fs.list(PathResolver.root)
        #expect(listing.entries.count == 2)

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ferry-m2-special-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        for entry in listing.entries {
            let fullDisplay = entry.path.displayString(using: CharsetConverter(charset: .utf8))
            let name = String(fullDisplay.dropFirst())
            let localDest = tempDir.appendingPathComponent(name)
            _ = try await TransferEngine.download(entry.path, to: localDest, using: fs)
            #expect(try Array(Data(contentsOf: localDest)) == sampleBytes)
        }
    }
}
