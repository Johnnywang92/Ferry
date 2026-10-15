import Foundation

/// `notFound` 必须可识别：同步引擎靠它区分"远端已删"与"网络故障"，
/// 混淆会在网络抖动时误删本地文件。
public enum RemoteError: Error, Sendable {
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
}

public enum NetworkKind: Sendable, Hashable {
    case connectionRefused
    case hostUnreachable
    case timeout
    case connectionLost
    case dnsFailure
}

public enum AuthFailure: Sendable, Hashable {
    case badPassword
    case keyRejected
    case passphraseRequired
    case passphraseIncorrect
    case tooManyAuthAttempts
}

public enum LocalIOKind: Sendable, Hashable {
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
}
