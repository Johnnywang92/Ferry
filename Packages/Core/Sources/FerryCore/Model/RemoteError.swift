import Foundation

/// `notFound` 必须可识别：同步引擎靠它区分"远端已删"与"网络故障"，
/// 混淆会在网络抖动时误删本地文件。
public enum RemoteError: Error, Sendable, Hashable {
    case network(NetworkKind)
    case auth(AuthFailure)
    /// 强警告，必须人工确认。
    case hostKeyMismatch(fingerprint: String)
    case permissionDenied(path: RemotePath)
    case notFound(path: RemotePath)
    /// 远端同目录下的两个不同 `wireBytes` 映射到同一比较键，或下载到 APFS 会静默覆盖。
    case keyCollision(existing: RemotePath, incoming: RemotePath)
    /// UI 应降级隐藏功能，而不是弹错误。
    case unsupported(RemoteCapabilities)
    /// UI 走十六进制视图。
    case undecodablePath(bytes: [UInt8])
    case protocolViolation(String)
    case localIO(LocalIOKind)
    /// 服务器报了失败，但成因不明确，或明确到不值得为它单开一个 case。
    ///
    /// 宁可保留原始码也不硬分类：`SSH_FX_FAILURE(4)` 实测同时是"rename 目标已存在"
    /// 与"路径写法服务器不接受"的回复（docs/spike/M0a-05 结论 3），
    /// 猜成 `notFound` 会让同步引擎把本地文件删掉。
    /// UI 按 `operation` + `kind` 出文案，同步引擎一律当"本操作失败、远端状态未知"。
    case operationFailed(OperationFailure)
}

/// 带 `String` 原始值是为了诊断 token 稳定：文案改得再狠，`network/timeout` 仍然是同一条。
public enum NetworkKind: String, Sendable, Hashable, CaseIterable {
    case connectionRefused
    case hostUnreachable
    case timeout
    case connectionLost
    case dnsFailure
}

public enum AuthFailure: String, Sendable, Hashable, CaseIterable {
    case badPassword
    case keyRejected
    case passphraseRequired
    case passphraseIncorrect
    case tooManyAuthAttempts
}

public enum LocalIOKind: String, Sendable, Hashable, CaseIterable {
    case diskFull
    case writeFailed
    case readFailed
}

extension RemoteError {
    /// 只有 `.network` 可重试。
    public var isRetryable: Bool {
        if case .network = self { return true }
        return false
    }

    public var isFatalToSession: Bool {
        switch self {
        case .auth, .hostKeyMismatch, .protocolViolation:
            return true
        default:
            return false
        }
    }

    /// 诊断报告与"错误码→可读建议"映射表用的稳定 token。不含路径内容——
    /// 报告里路径单独脱敏列出，token 要能当聚合键用。
    ///
    /// 只增不改：文案可以重写，但这个串一旦导出过就得能被日后翻出来的报告认出来。
    public var diagnosticCode: String {
        switch self {
        case .network(let kind): "network/\(kind.rawValue)"
        case .auth(let failure): "auth/\(failure.rawValue)"
        case .hostKeyMismatch: "hostKeyMismatch"
        case .permissionDenied: "permissionDenied"
        case .notFound: "notFound"
        case .keyCollision: "keyCollision"
        case .unsupported(let caps): "unsupported/\(caps.rawValue)"
        case .undecodablePath: "undecodablePath"
        case .protocolViolation: "protocolViolation"
        case .localIO(let kind): "localIO/\(kind.rawValue)"
        case .operationFailed(let failure): failure.diagnosticCode
        }
    }
}

extension OperationFailure {
    /// 形如 `sftp/SSH_FX_FAILURE@rename`、`ftp/550@list`、`ssh/-21@handshake`。
    public var diagnosticCode: String {
        let head: String
        switch kind {
        case .sftpStatus(let status): head = "sftp/\(status.symbolName)"
        case .ftpReply(let reply): head = "ftp/\(reply)"
        case .sessionCode(let rc): head = "ssh/\(rc)"
        case .undetermined: head = "ssh/undetermined(rc=\(rc))"
        }
        return "\(head)@\(operation.rawValue)"
    }
}
