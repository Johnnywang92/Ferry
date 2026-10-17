import CLibcurl
import FerryCore
import Foundation

/// FTP/FTPS 连接实现（v2.3 §67, §271, §489）。
///
/// 基于 libcurl 实现，完整遵从 RemoteConnection、RemoteFileSystem 与 RemoteTransfer 契约。
public actor FTPConnection: RemoteConnection, RemoteFileSystem {

    public nonisolated let endpoint: Endpoint
    public nonisolated let pathPolicy: PathPolicy
    public nonisolated let charsetConverter: CharsetConverter
    private let request: ConnectionRequest
    private let isFTPS: Bool

    private var _phase: ConnectionPhase = .idle
    private let cancellationFlag = CancellationFlag()

    public var phase: ConnectionPhase {
        get async { _phase }
    }

    public init(request: ConnectionRequest, isFTPS: Bool = false) {
        self.request = request
        self.endpoint = request.endpoint
        self.pathPolicy = request.pathPolicy
        self.charsetConverter = CharsetConverter(charset: request.charset)
        self.isFTPS = isFTPS
    }

    // MARK: - RemoteConnection 契约

    public func handshake() async throws -> NegotiatedSession {
        guard _phase == .idle else {
            if _phase == .aborted || _phase == .closed {
                throw RemoteError.protocolViolation("连接已关闭或已终止")
            }
            throw RemoteError.protocolViolation("连接已在握手或握手已完成")
        }

        _phase = .connecting

        // 执行握手探测连通性
        let testURL = makeURL(for: nil)
        let curl = try createConfiguredCurl(url: testURL, timeout: 10)
        defer { ferry_curl_easy_cleanup(curl) }

        ferry_curl_set_nobody(curl, 1)

        let rc = ferry_curl_easy_perform(curl)
        if cancellationFlag.isSet {
            _phase = .aborted
            throw CancellationError()
        }

        // CURLE_LOGIN_DENIED 说明连通了控制通道，握手成功，等待认证
        if rc != CURLE_OK && rc != CURLE_LOGIN_DENIED {
            _phase = .aborted
            throw mapCurlError(rc, path: nil, operation: .handshake)
        }

        _phase = .ready

        let dummyBlob = Data([0, 0, 0, 4]) + Data("none".utf8)
        let hostKey = try! HostKey(algorithm: "none", blob: dummyBlob)
        let algs = NegotiatedAlgorithms(
            keyExchange: isFTPS ? "ftps-tls" : "ftp-control",
            hostKey: isFTPS ? "x509" : "none",
            encryptionClientToServer: isFTPS ? "TLSv1.3" : "none",
            encryptionServerToClient: isFTPS ? "TLSv1.3" : "none",
            macClientToServer: "none",
            macServerToClient: "none"
        )

        return NegotiatedSession(
            serverIdentification: "FTP Service (\(endpoint.host))",
            hostKey: hostKey,
            algorithms: algs
        )
    }

    public func authenticate(interactive: (any KeyboardInteractiveResponder)?) async throws -> AuthenticatedSession {
        guard _phase == .ready else {
            if _phase == .authenticated {
                throw RemoteError.protocolViolation("已经通过认证")
            }
            throw RemoteError.protocolViolation("必须先完成握手")
        }

        let testURL = makeURL(for: nil)
        let curl = try createConfiguredCurl(url: testURL, timeout: 15)
        defer { ferry_curl_easy_cleanup(curl) }

        ferry_curl_set_dirlistonly(curl, 1)
        ferry_curl_set_nobody(curl, 1)

        let rc = ferry_curl_easy_perform(curl)
        if cancellationFlag.isSet {
            _phase = .aborted
            throw CancellationError()
        }

        if rc != CURLE_OK {
            if rc == CURLE_LOGIN_DENIED {
                throw RemoteError.auth(.badPassword)
            }
            _phase = .aborted
            throw mapCurlError(rc, path: nil, operation: .authenticate)
        }

        _phase = .authenticated

        let method: AuthenticatedMethod
        switch request.authentication {
        case .anonymous:
            method = .none
        default:
            method = .password
        }

        return AuthenticatedSession(
            method: method,
            serverOfferedMethods: ["password"]
        )
    }

    public nonisolated func cancel() {
        cancellationFlag.cancel()
    }

    public func close() async {
        _phase = .closed
    }

    // MARK: - RemoteFileSystem 目录与文件操作

    public func list(_ path: RemotePath) async throws -> RemoteDirectoryListing {
        try ensureAuthenticated()

        let url = makeURL(for: path, isDirectory: true)
        let curl = try createConfiguredCurl(url: url)
        defer { ferry_curl_easy_cleanup(curl) }

        var outputData = Data()
        final class BufferBox: @unchecked Sendable {
            var data: Data = Data()
        }
        let box = BufferBox()
        let unmanaged = Unmanaged.passRetained(box)

        ferry_curl_set_write_callback(curl, { ptr, size, nmemb, userdata in
            guard let ptr, let userdata else { return 0 }
            let bytes = size * nmemb
            let b = Unmanaged<BufferBox>.fromOpaque(userdata).takeUnretainedValue()
            b.data.append(Data(bytes: ptr, count: bytes))
            return bytes
        }, unmanaged.toOpaque())

        let rc = ferry_curl_easy_perform(curl)
        outputData = box.data
        unmanaged.release()

        if cancellationFlag.isSet {
            _phase = .aborted
            throw CancellationError()
        }

        if rc != CURLE_OK {
            throw mapCurlError(rc, path: path, operation: .list)
        }

        let items = FTPParser.parseListing(
            data: outputData,
            directory: path,
            charsetConverter: charsetConverter
        )

        return RemoteDirectoryListing(directory: path, entries: items)
    }

    public func stat(_ path: RemotePath) async throws -> RemoteItem {
        try ensureAuthenticated()

        let url = makeURL(for: path)
        let curl = try createConfiguredCurl(url: url)
        defer { ferry_curl_easy_cleanup(curl) }

        ferry_curl_set_nobody(curl, 1)
        ferry_curl_set_filetime(curl, 1)

        let rc = ferry_curl_easy_perform(curl)
        if cancellationFlag.isSet {
            _phase = .aborted
            throw CancellationError()
        }

        if rc != CURLE_OK {
            throw mapCurlError(rc, path: path, operation: .stat)
        }

        let sizeVal = ferry_curl_get_content_length(curl)
        let timeVal = ferry_curl_get_filetime(curl)

        let size: Int64? = sizeVal >= 0 ? Int64(sizeVal) : nil
        let date = timeVal >= 0 ? Date(timeIntervalSince1970: TimeInterval(timeVal)) : nil

        return RemoteItem(
            path: path,
            kind: .file,
            size: size,
            modificationDate: date,
            sizeIsExact: size != nil,
            mtimeIsReliable: date != nil,
            linkTarget: nil,
            permissions: 0o644,
            uid: nil,
            gid: nil,
            owner: nil,
            group: nil
        )
    }

    public func lstat(_ path: RemotePath) async throws -> RemoteItem {
        // FTP 通常不解析链，等同于 stat
        try await stat(path)
    }

    public func resolve(_ item: RemoteItem, in listing: inout RemoteDirectoryListing) async throws -> RemoteDirectoryListing.LinkResolution? {
        if item.kind == .symbolicLink, let target = item.linkTarget {
            let res = RemoteDirectoryListing.LinkResolution(target: target, resolved: target, segmentsLookedUp: 1)
            listing = RemoteDirectoryListing(
                directory: listing.directory,
                entries: listing.entries,
                probes: listing.probes,
                resolutions: listing.resolutions.merging([item.path: res]) { _, new in new }
            )
            return res
        }
        return nil
    }

    public func mkdir(_ path: RemotePath, permissions: UInt16?) async throws {
        try ensureAuthenticated()

        let parent = try PathResolver.parent(of: path)
        let name = path.lastComponent?.displayString(using: charsetConverter) ?? ""
        let quoteCmd = "MKD \(name)"

        try await executeQuote(quoteCmd, at: parent, operation: .mkdir)
    }

    public func remove(_ path: RemotePath, recursive: Bool) async throws {
        try ensureAuthenticated()

        let parent = try PathResolver.parent(of: path)
        let name = path.lastComponent?.displayString(using: charsetConverter) ?? ""

        // 尝试按文件删除 DELE，若失败尝试按目录 RMD
        do {
            try await executeQuote("DELE \(name)", at: parent, operation: .remove)
        } catch {
            try await executeQuote("RMD \(name)", at: parent, operation: .remove)
        }
    }

    public func rename(_ from: RemotePath, to: RemotePath, overwrite: Bool) async throws {
        try ensureAuthenticated()

        let parent = try PathResolver.parent(of: from)
        let fromName = from.displayString(using: charsetConverter)
        let toName = to.displayString(using: charsetConverter)

        var list: UnsafeMutablePointer<curl_slist>? = nil
        list = ferry_curl_slist_append(list, "RNFR \(fromName)")
        list = ferry_curl_slist_append(list, "RNTO \(toName)")
        defer { ferry_curl_slist_free_all(list) }

        let url = makeURL(for: parent, isDirectory: true)
        let curl = try createConfiguredCurl(url: url)
        defer { ferry_curl_easy_cleanup(curl) }

        ferry_curl_set_quote(curl, list)
        ferry_curl_set_nobody(curl, 1)

        let rc = ferry_curl_easy_perform(curl)
        if rc != CURLE_OK {
            throw mapCurlError(rc, path: from, operation: .rename)
        }
    }

    public func symlink(target: RemotePath, at path: RemotePath) async throws {
        throw RemoteError.unsupported(.symbolicLinks)
    }

    public func readlink(_ path: RemotePath) async throws -> RemotePath {
        throw RemoteError.unsupported(.symbolicLinks)
    }

    public func chmod(_ path: RemotePath, _ mode: UInt16) async throws {
        let name = path.displayString(using: charsetConverter)
        let octalStr = String(format: "%o", mode)
        let parent = try PathResolver.parent(of: path)
        try await executeQuote("SITE CHMOD \(octalStr) \(name)", at: parent, operation: .chmod)
    }

    public func statvfs(_ path: RemotePath) async throws -> RemoteVolumeInfo {
        RemoteVolumeInfo(totalBytes: nil, availableBytes: nil)
    }

    // MARK: - RemoteTransfer 句柄

    public func openRead(_ path: RemotePath, offset: Int64) async throws -> any RemoteReader {
        try ensureAuthenticated()
        let statItem = try? await stat(path)
        let url = makeURL(for: path)
        return FTPFileReader(
            url: url,
            userpwd: credentialsString(),
            offset: offset,
            totalSize: statItem?.size
        )
    }

    public func createWrite(_ path: RemotePath, offset: Int64) async throws -> any RemoteWriter {
        try ensureAuthenticated()
        let url = makeURL(for: path)
        return FTPFileWriter(
            url: url,
            userpwd: credentialsString(),
            offset: offset
        )
    }

    // MARK: - 内部私有辅助

    private func ensureAuthenticated() throws {
        guard _phase == .authenticated else {
            throw RemoteError.protocolViolation("未认证连接禁止执行文件系统操作")
        }
    }

    private func makeURL(for path: RemotePath?, isDirectory: Bool = false) -> String {
        let scheme = isFTPS ? "ftps" : "ftp"
        let host = endpoint.host
        let port = endpoint.port

        var url = "\(scheme)://\(host):\(port)"
        if let path {
            let pathStr = path.displayString(using: charsetConverter)
            if !pathStr.hasPrefix("/") {
                url += "/"
            }
            url += pathStr
        } else {
            url += "/"
        }

        if isDirectory && !url.hasSuffix("/") {
            url += "/"
        }

        return url
    }

    private func credentialsString() -> String? {
        switch request.authentication {
        case .password(let pass):
            return "\(endpoint.username):\(pass)"
        case .anonymous:
            return "anonymous:anonymous@ferry.client"
        default:
            return "\(endpoint.username):"
        }
    }

    private func createConfiguredCurl(url: String, timeout: Int = 30) throws -> UnsafeMutableRawPointer {
        guard let curl = ferry_curl_easy_init() else {
            throw RemoteError.operationFailed(OperationFailure(kind: .sessionCode(-1), operation: .handshake, path: nil, rc: -1))
        }

        ferry_curl_set_url(curl, url)
        if let creds = credentialsString() {
            ferry_curl_set_userpwd(curl, creds)
        }

        ferry_curl_set_timeout(curl, Int(timeout))
        ferry_curl_set_connect_timeout(curl, 10)

        if isFTPS {
            ferry_curl_set_ssl_options(curl, 3) // CURLUSESSL_ALL
        }

        return curl
    }

    private func executeQuote(_ command: String, at dir: RemotePath, operation: RemoteOperation) async throws {
        var list: UnsafeMutablePointer<curl_slist>? = nil
        list = ferry_curl_slist_append(list, command)
        defer { ferry_curl_slist_free_all(list) }

        let url = makeURL(for: dir, isDirectory: true)
        let curl = try createConfiguredCurl(url: url)
        defer { ferry_curl_easy_cleanup(curl) }

        ferry_curl_set_quote(curl, list)
        ferry_curl_set_nobody(curl, 1)

        let rc = ferry_curl_easy_perform(curl)
        if rc != CURLE_OK {
            throw mapCurlError(rc, path: dir, operation: operation)
        }
    }

    nonisolated package func mapCurlError(_ code: CURLcode, path: RemotePath?, operation: RemoteOperation) -> RemoteError {
        switch code {
        case CURLE_LOGIN_DENIED:
            return .auth(.badPassword)
        case CURLE_COULDNT_CONNECT:
            return .network(.connectionRefused)
        case CURLE_OPERATION_TIMEDOUT:
            return .network(.timeout)
        case CURLE_REMOTE_FILE_NOT_FOUND:
            return .notFound(path: path ?? PathResolver.root)
        case CURLE_REMOTE_ACCESS_DENIED:
            return .permissionDenied(path: path ?? PathResolver.root)
        default:
            return .operationFailed(OperationFailure(kind: .ftpReply(Int32(code.rawValue)), operation: operation, path: path, rc: Int32(code.rawValue)))
        }
    }
}
