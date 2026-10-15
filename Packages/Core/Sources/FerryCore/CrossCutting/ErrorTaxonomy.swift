import Foundation

/// 远端操作失败的原因。`RemoteError.operationFailed` 的载荷，保留原始码供诊断报告导出。
///
/// 服务器只给一个笼统失败码时不硬猜成因——猜错的代价由同步引擎付：
/// 把 `SSH_FX_FAILURE` 当 `notFound`，重命名冲突就会被翻译成"远端文件已删除"。
public struct OperationFailure: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// 服务器回了 SFTP 状态码。
        case sftpStatus(SFTPStatus)
        /// FTP 控制连接回了码。
        case ftpReply(Int32)
        /// 只有 libssh2 会话层错误码，没到 SFTP 协议层。
        case sessionCode(Int32)
        /// `rc` 非 0 却拿不到任何可判定的码（`status` 缺失或来自不可信的调用）。
        case undetermined
    }

    public let kind: Kind
    public let operation: RemoteOperation
    /// 出错的路径；rename 是源路径。
    public let path: RemotePath?
    /// rename 的目标路径，其余操作为 nil。
    public let target: RemotePath?
    public let rc: Int32

    public init(kind: Kind, operation: RemoteOperation, path: RemotePath?, target: RemotePath? = nil, rc: Int32) {
        self.kind = kind
        self.operation = operation
        self.path = path
        self.target = target
        self.rc = rc
    }
}

/// 一次远端调用的上下文。分类结果的可读性全靠它——同一个 `SSH_FX_PERMISSION_DENIED`，
/// `list` 时说"这个目录读不了"，`remove` 时说"没有删除权限"。
public enum RemoteOperation: String, Sendable, Hashable, CaseIterable {
    case list
    case stat
    case lstat
    case openRead
    case createWrite
    case read
    case write
    case close
    case mkdir
    case remove
    case rename
    case symlink
    case readlink
    case chmod
    case statvfs
    case realpath
    case handshake
    case authenticate
    case disconnect
}

/// 分类所需的信息，全部由后端在同一次调用里备齐。
public struct RemoteErrorContext: Sendable, Hashable {
    public let operation: RemoteOperation
    public let path: RemotePath?
    public let target: RemotePath?
    /// `OP_UNSUPPORTED` 要落到哪个能力上，UI 才知道该降级隐藏什么。
    public let capability: RemoteCapabilities?

    public init(
        operation: RemoteOperation,
        path: RemotePath? = nil,
        target: RemotePath? = nil,
        capability: RemoteCapabilities? = nil
    ) {
        self.operation = operation
        self.path = path
        self.target = target
        self.capability = capability
    }
}

/// 把后端原始码翻译成 `RemoteError`。Core 只认数字，不依赖任何 C 头文件，
/// 编号出处是 libssh2 1.11.1 的 `libssh2.h` / `libssh2_sftp.h`（#14 锁定 commit 后要复核）。
///
/// 三条规则都来自实测，不是保守起见：
///
/// 1. **不读 libssh2 的错误字符串**。口令错与"私钥格式不支持"共用 `-16 FILE`，
///    而它的文案会把前者说成文件读不了（docs/spike/M0a-05 结论 6）。字符串只进诊断报告。
/// 2. **`rc` 与 `status` 必须成对且即时**。`libssh2_sftp_last_error` 会被下一个请求覆盖，
///    也出现过 `rc=-31` 配 `status=0`（同 channel 并发请求，docs/spike/M0a-02 结论 1）
///    和 `rc=-31` 配 `status=71…134` 的非法值（`symlink_ex`，docs/spike/M0b-01 结论 6）。
///    后者尤其危险：那次是 16/16 全部建链成功，返回值却全是失败。
/// 3. **`notFound` 只认明确的存在性回复**。同步引擎靠它决定"远端已删"，
///    误判会删掉本地文件；`SSH_FX_FAILURE` 与 FTP 的 `550` 都不表达"不存在"。
public enum ErrorTaxonomy {
    // libssh2 会话层错误码（libssh2.h）
    static let file: Int32 = -16
    static let authenticationFailed: Int32 = -18
    static let publicKeyUnverified: Int32 = -19
    static let channelFailure: Int32 = -21
    static let channelRequestDenied: Int32 = -22
    static let channelClosed: Int32 = -26
    static let socketTimeout: Int32 = -30
    static let sftpProtocol: Int32 = -31
    static let methodNotSupported: Int32 = -33
    static let eagain: Int32 = -37
    static let socketNone: Int32 = -1
    static let socketSend: Int32 = -7
    static let socketRecv: Int32 = -43
    static let socketDisconnect: Int32 = -13
    static let timeout: Int32 = -9
    static let proto: Int32 = -14
    static let passwordExpired: Int32 = -15
    static let kexFailure: Int32 = -5
    static let keyExchangeFailure: Int32 = -8
    static let decrypt: Int32 = -12
    static let hostKeyInit: Int32 = -10
    static let knownHosts: Int32 = -46
    static let methodNone: Int32 = -17
    static let publicKeyProtocol: Int32 = -36
    static let agentProtocol: Int32 = -42
    static let keyfileAuthFailed: Int32 = -48
    static let algoUnsupported: Int32 = -51

    /// 非阻塞轮询下的"现在会阻塞"，不是错误。poll 循环必须先查这个再进 `classifySFTP`。
    ///
    /// 若当成错误丢给分类，返回的 `.network` 会被重试逻辑判为可重试，
    /// 于是每次 EAGAIN 都变成一次重连——ADR-0001 的取消与重试语义会直接乱掉。
    public static func isWouldBlock(rc: Int32) -> Bool { rc == eagain }

    /// SFTP 调用的分类。`status` 必须是**这次调用返回后立刻**取的 `libssh2_sftp_last_error`；
    /// 取不到就传 nil，此时 `rc != 0` 只能落到 `undetermined`，绝不猜成 `notFound`。
    public static func classifySFTP(rc: Int32, status: UInt32?, context: RemoteErrorContext) -> RemoteError? {
        if rc == 0 { return nil }
        if isWouldBlock(rc: rc) { return nil }

        // 会话层的网络/超时码优先：这时 last_error 里留着的是上一次的残值
        if let network = sessionNetworkError(rc: rc, context: context) { return network }

        guard rc == sftpProtocol else {
            // -21 之类通道层失败，或 -16/-14：没有 SFTP 状态码可依
            return failed(.sessionCode(rc), context: context, rc: rc)
        }

        guard let raw = status else {
            // 实测 M0a-02：rc=-31 且 last_error=0 确实存在（并发请求被 libssh2 拒绝）。
            // status=0 意思是 FX_OK，与"调用失败"矛盾，只能报"判不出原因"。
            return failed(.undetermined, context: context, rc: rc)
        }

        let code = SFTPStatus(raw: raw)
        switch code {
        case .ok:
            // rc 说失败、status 说成功：与上一条同理，不采信任何一边
            return failed(.undetermined, context: context, rc: rc)
        case .noSuchFile, .noSuchPath:
            guard let path = context.path ?? context.target else {
                return failed(.sftpStatus(code), context: context, rc: rc)
            }
            return .notFound(path: path)
        case .permissionDenied, .writeProtect, .unknownPrincipal:
            guard let path = context.path ?? context.target else {
                return failed(.sftpStatus(code), context: context, rc: rc)
            }
            return .permissionDenied(path: path)
        case .noConnection, .connectionLost:
            return .network(.connectionLost)
        case .opUnsupported:
            if let capability = context.capability { return .unsupported(capability) }
            return failed(.sftpStatus(code), context: context, rc: rc)
        case .badMessage:
            // 请求本身不成形，属于协议层分歧，后续请求不可信
            return .protocolViolation("SSH_FX_BAD_MESSAGE（rc=\(rc)）")
        case .endOfFile, .failure, .invalidHandle, .fileAlreadyExists, .noMedia,
             .noSpaceOnFileSystem, .quotaExceeded, .lockConflict, .dirNotEmpty,
             .notADirectory, .invalidFilename, .linkLoop:
            return failed(.sftpStatus(code), context: context, rc: rc)
        case .outOfRange:
            // 实测 M0b-01：symlink_ex 恒 rc=-31 且 last_error 落在 71–134，而链确实建成了。
            // 非法值不等于协议违规，判成致命会杀掉整个会话；交给调用方用回读定论。
            return failed(.sftpStatus(code), context: context, rc: rc)
        }
    }

    /// 会话层（握手、认证、开通道）的分类。
    public static func classifySession(rc: Int32, context: RemoteErrorContext) -> RemoteError? {
        if rc == 0 { return nil }
        if isWouldBlock(rc: rc) { return nil }
        if let network = sessionNetworkError(rc: rc, context: context) { return network }

        switch rc {
        case hostKeyInit, knownHosts:
            // 指纹由后端填入；这里只定性，避免 Core 承担主机密钥的存储与匹配
            return .hostKeyMismatch(fingerprint: "")
        case kexFailure, keyExchangeFailure, decrypt, proto:
            return .protocolViolation("libssh2 会话/加密层失败 rc=\(rc)")
        case algoUnsupported, methodNotSupported, methodNone:
            return .protocolViolation("算法协商失败 rc=\(rc)")
        case channelFailure:
            // 实测 M0a-01：MaxSessions 用满时两台服务器都在第 11 次 sftp_init 返回 -21。
            // 它可重试，但要等通道释放，不是立刻重连——重试策略由调用方按通道池决定。
            return .network(.connectionRefused)
        case channelRequestDenied, channelClosed:
            return .network(.connectionLost)
        case agentProtocol, publicKeyProtocol:
            return .auth(.keyRejected)
        default:
            return failed(.sessionCode(rc), context: context, rc: rc)
        }
    }

    /// 认证方式。同一个 `-16 FILE` 在不同方式下含义完全不同，光看码分不出来。
    public enum AuthMethod: Sendable, Hashable {
        case password
        /// 带了口令去解私钥。
        case encryptedKey
        /// 私钥不需要口令。
        case plainKey
        case agent
        case keyboardInteractive
    }

    /// 认证失败分类。口令错与"格式不支持"共用码时，这里宁可不细化：
    /// 谎报"口令错误"会让用户反复输错口令，而真实原因是密钥格式压根没被解析。
    ///
    /// libssh2 自己就把码合并了：`PUBLICKEY_UNRECOGNIZED` 是 `AUTHENTICATION_FAILED` 的别名，
    /// 两者同为 -18（libssh2.h:555）。`tooManyAuthAttempts` 没有对应码——服务器多半直接断开
    /// 连接（→ `.network`），只能由后端数完认证次数后合成，本函数不会产出它。
    public static func classifyAuth(rc: Int32, method: AuthMethod) -> RemoteError? {
        switch rc {
        case 0:
            return nil
        case passwordExpired:
            return .auth(.badPassword)
        case authenticationFailed, methodNone:
            switch method {
            case .password, .keyboardInteractive: return .auth(.badPassword)
            case .encryptedKey, .plainKey, .agent: return .auth(.keyRejected)
            }
        case publicKeyUnverified, keyfileAuthFailed:
            return .auth(.keyRejected)
        case file:
            // -16 实测同时覆盖"口令错"和"私钥格式不支持"，无法二选一。
            // 只有在确实带了口令去解密时才敢说 passphraseIncorrect，否则退回 keyRejected。
            return method == .encryptedKey ? .auth(.passphraseIncorrect) : .auth(.keyRejected)
        default:
            return nil
        }
    }

    /// FTP 回复码分类。FTP 没有存在性专用码，`550` 一字多用。
    public static func classifyFTP(reply: Int32, context: RemoteErrorContext) -> RemoteError? {
        switch reply {
        case 100..<400:
            return nil
        case 421, 425, 426:
            // 控制连接要断或已断，属可重试
            return .network(.connectionLost)
        case 430:
            return .auth(.badPassword)
        case 530:
            return .auth(.badPassword)
        case 550:
            // 同时被用来表达"不存在""没权限""是目录不是文件"。
            // 判成 notFound 会让同步引擎在服务器一句话之下删掉本地副本。
            return failed(.ftpReply(reply), context: context, rc: reply)
        case 400..<500, 500..<700:
            return failed(.ftpReply(reply), context: context, rc: reply)
        default:
            return failed(.ftpReply(reply), context: context, rc: reply)
        }
    }

    private static func sessionNetworkError(rc: Int32, context: RemoteErrorContext) -> RemoteError? {
        switch rc {
        case timeout, socketTimeout: return .network(.timeout)
        case socketNone, socketSend, socketRecv, socketDisconnect: return .network(.connectionLost)
        default: return nil
        }
    }

    private static func failed(_ kind: OperationFailure.Kind, context: RemoteErrorContext, rc: Int32) -> RemoteError {
        .operationFailed(OperationFailure(
            kind: kind,
            operation: context.operation,
            path: context.path,
            target: context.target,
            rc: rc
        ))
    }
}

/// SSH_FXP_STATUS 的 0–21。合法上界就是 21，超出的一律单列——
/// `libssh2_sftp_last_error` 返回过 71 与 131 这类值（docs/spike/M0b-01 结论 6）。
public enum SFTPStatus: Hashable, Sendable {
    case ok
    case endOfFile
    case noSuchFile
    case permissionDenied
    case failure
    case badMessage
    case noConnection
    case connectionLost
    case opUnsupported
    case invalidHandle
    case noSuchPath
    case fileAlreadyExists
    case writeProtect
    case noMedia
    case noSpaceOnFileSystem
    case quotaExceeded
    case unknownPrincipal
    case lockConflict
    case dirNotEmpty
    case notADirectory
    case invalidFilename
    case linkLoop
    /// 不在 0–21 内。不能当成功，也不能当某个具体失败。
    case outOfRange(raw: UInt32)

    public init(raw: UInt32) {
        switch raw {
        case 0: self = .ok
        case 1: self = .endOfFile
        case 2: self = .noSuchFile
        case 3: self = .permissionDenied
        case 4: self = .failure
        case 5: self = .badMessage
        case 6: self = .noConnection
        case 7: self = .connectionLost
        case 8: self = .opUnsupported
        case 9: self = .invalidHandle
        case 10: self = .noSuchPath
        case 11: self = .fileAlreadyExists
        case 12: self = .writeProtect
        case 13: self = .noMedia
        case 14: self = .noSpaceOnFileSystem
        case 15: self = .quotaExceeded
        case 16: self = .unknownPrincipal
        case 17: self = .lockConflict
        case 18: self = .dirNotEmpty
        case 19: self = .notADirectory
        case 20: self = .invalidFilename
        case 21: self = .linkLoop
        default: self = .outOfRange(raw: raw)
        }
    }

    /// 诊断报告里用的稳定符号名，与 libssh2 宏同名，便于对着上游源码查。
    public var symbolName: String {
        switch self {
        case .ok: "SSH_FX_OK"
        case .endOfFile: "SSH_FX_EOF"
        case .noSuchFile: "SSH_FX_NO_SUCH_FILE"
        case .permissionDenied: "SSH_FX_PERMISSION_DENIED"
        case .failure: "SSH_FX_FAILURE"
        case .badMessage: "SSH_FX_BAD_MESSAGE"
        case .noConnection: "SSH_FX_NO_CONNECTION"
        case .connectionLost: "SSH_FX_CONNECTION_LOST"
        case .opUnsupported: "SSH_FX_OP_UNSUPPORTED"
        case .invalidHandle: "SSH_FX_INVALID_HANDLE"
        case .noSuchPath: "SSH_FX_NO_SUCH_PATH"
        case .fileAlreadyExists: "SSH_FX_FILE_ALREADY_EXISTS"
        case .writeProtect: "SSH_FX_WRITE_PROTECT"
        case .noMedia: "SSH_FX_NO_MEDIA"
        case .noSpaceOnFileSystem: "SSH_FX_NO_SPACE_ON_FILESYSTEM"
        case .quotaExceeded: "SSH_FX_QUOTA_EXCEEDED"
        case .unknownPrincipal: "SSH_FX_UNKNOWN_PRINCIPAL"
        case .lockConflict: "SSH_FX_LOCK_CONFLICT"
        case .dirNotEmpty: "SSH_FX_DIR_NOT_EMPTY"
        case .notADirectory: "SSH_FX_NOT_A_DIRECTORY"
        case .invalidFilename: "SSH_FX_INVALID_FILENAME"
        case .linkLoop: "SSH_FX_LINK_LOOP"
        case .outOfRange(let raw): "SSH_FX_OUT_OF_RANGE(\(raw))"
        }
    }
}
