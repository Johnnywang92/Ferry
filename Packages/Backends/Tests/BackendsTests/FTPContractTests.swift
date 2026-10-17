import CLibcurl
import FerryContracts
import FerryCore
import Foundation
import Testing

@testable import FerryBackendsFTP

/// M6: 契约测试覆盖 FTP/FTPS 后端（同一套契约测试全绿，两后端零特判，v2.3 §524）。
///
/// 与 `SFTPContractTests` 及 `InMemoryContractTests` 共享同一份 `FileSystemContract.checks`。
/// 契约在两个真实后端上复用，不针对 FTP 增加特判分支，完全由 `RemoteCapabilities` 与 `RemoteFileSystem` 契约约束。
///
/// 跑法（启动本地测试 FTP 服务如 pyftpdlib 后）：
///     FERRY_LIVE_FTP=1 swift test --package-path Packages/Backends --filter FTPContractTests
private let liveFTPEnabled = ProcessInfo.processInfo.environment["FERRY_LIVE_FTP"] == "1"
private let liveFTPPort = Int(ProcessInfo.processInfo.environment["FERRY_LIVE_FTP_PORT"] ?? "2121") ?? 2121

@Suite("契约套件 × FTP 后端", .serialized)
struct FTPContractTests {

    @Test("FTPBackend 能力声明与 RemoteFileSystem 契约协议一致（零特判）")
    func backendCapabilitiesConsistency() {
        let backend = FTPBackend(isFTPS: false)
        #expect(backend.declaredCapabilities.contains(.resumableDownload))
        #expect(backend.declaredCapabilities.contains(.resumableUpload))
        #expect(backend.declaredCapabilities.contains(.reliableMTime))
        #expect(backend.declaredCapabilities.contains(.charsetNegotiation))

        // FTP 协议不支持符号链接与目录 stat，契约应显式不包含
        #expect(!backend.declaredCapabilities.contains(.symbolicLinks))
        #expect(!backend.declaredCapabilities.contains(.lstat))
    }

    @Test("FTP 错误分类与 RemoteError 映射契约（v2.3 §472）")
    func errorMappingContract() {
        let req = ConnectionRequest(
            endpoint: Endpoint(host: "127.0.0.1", port: 2121, username: "anonymous"),
            authentication: .anonymous,
            policy: .standard
        )
        let conn = FTPConnection(request: req, isFTPS: false)

        let missingPath = RemotePath(string: "/missing.txt", isAbsolute: true)!
        // CURLE_REMOTE_FILE_NOT_FOUND (19) 必须映射为 notFound
        let notFoundErr = conn.mapCurlError(CURLE_REMOTE_FILE_NOT_FOUND, path: missingPath, operation: .stat)
        if case .notFound(let path) = notFoundErr {
            #expect(path.displayString() == "/missing.txt")
        } else {
            Issue.record("CURLE_REMOTE_FILE_NOT_FOUND 必须映射为 RemoteError.notFound")
        }

        let secretPath = RemotePath(string: "/secret.txt", isAbsolute: true)!
        // CURLE_REMOTE_ACCESS_DENIED (9) 必须映射为 permissionDenied
        let permErr = conn.mapCurlError(CURLE_REMOTE_ACCESS_DENIED, path: secretPath, operation: .read)
        if case .permissionDenied(let path) = permErr {
            #expect(path.displayString() == "/secret.txt")
        } else {
            Issue.record("CURLE_REMOTE_ACCESS_DENIED 必须映射为 RemoteError.permissionDenied")
        }

        // CURLE_COULDNT_CONNECT (7) 必须映射为 connectionRefused
        let connErr = conn.mapCurlError(CURLE_COULDNT_CONNECT, path: nil, operation: .handshake)
        if case .network(.connectionRefused) = connErr {
            // 正确
        } else {
            Issue.record("CURLE_COULDNT_CONNECT 必须映射为 RemoteError.network(.connectionRefused)")
        }

        // CURLE_OPERATION_TIMEDOUT (28) 必须映射为 network(.timeout)
        let timeoutErr = conn.mapCurlError(CURLE_OPERATION_TIMEDOUT, path: nil, operation: .read)
        if case .network(let reason) = timeoutErr {
            #expect(reason == .timeout)
        } else {
            Issue.record("CURLE_OPERATION_TIMEDOUT 必须映射为 RemoteError.network(.timeout)")
        }
    }

    @Test(
        "首批契约用例在 FTP 后端上全绿（真机环境）",
        .enabled(if: liveFTPEnabled, "真机契约要显式开启：FERRY_LIVE_FTP=1")
    )
    func contractSuitePassesOnLiveFTPServer() async throws {
        let req = ConnectionRequest(
            endpoint: Endpoint(host: "127.0.0.1", port: liveFTPPort, username: "tester"),
            authentication: .password("testpass"),
            policy: .standard,
            charset: .utf8
        )
        let conn = FTPConnection(request: req, isFTPS: false)
        _ = try await conn.handshake()
        _ = try await conn.authenticate(interactive: nil)
        defer { Task { await conn.close() } }

        let corpusRoot = PathResolver.root
        let capabilities = FTPBackend(isFTPS: false).declaredCapabilities
        let subject = ContractSubject(
            label: "ftp:\(liveFTPPort)",
            fileSystem: conn,
            capabilities: capabilities,
            corpusRoot: corpusRoot
        )

        let results = await FileSystemContract.run(subject)
        let failures = results.filter { if case .failed = $0.value.status { return true } else { return false } }

        var report: [String] = []
        for (name, outcome) in results.sorted(by: { $0.key < $1.key }) {
            report.append("  \(name): \(outcome.status)")
        }
        print("FTP 契约测试结果：\n" + report.joined(separator: "\n"))

        #expect(failures.isEmpty, Comment(rawValue: "FTP 契约违约 \(failures.count) 项"))
    }
}
