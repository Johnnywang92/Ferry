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
    /// 服务器在 `USERAUTH_FAILURE` 里列出的方式压根不含用户选的那一种。
    ///
    /// 由后端拿 `libssh2_userauth_list` 的结果合成，`ErrorTaxonomy.classifyAuth` 不产出它：
    /// 依据是对面的清单，不是错误码。把它算进 `badPassword` 会让用户反复重打一个
    /// 这台服务器压根不收的口令（M1-04 §5.2）。
    case methodNotOffered
    /// 用户选了 ssh-agent，而这台机器上没有可用的 agent（`SSH_AUTH_SOCK` 没设、agent 没在跑、
    /// socket 指向了不存在的路径）。
    ///
    /// libssh2 在 `libssh2_agent_connect` 阶段就回 `-39 LIBSSH2_ERROR_BAD_USE`（agent.c:182，
    /// 理由原文是"Unable to get socket name from environment variable"），压根没走到"这把钥匙
    /// 服务器认不认"。报成 `keyRejected` 会把用户支去查服务器上的 `authorized_keys`，
    /// 而真正要修的是本机那个环境变量。
    case agentUnavailable
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

    /// 出这个错之后，这条传输连接还能不能留给下一次尝试。
    ///
    /// `.auth` 与 `.localIO` **不在**里面：服务器回 `USERAUTH_FAILURE` 之后 libssh2 的认证状态机
    /// 干净地回到 idle，换个口令再调一次就免掉 TCP 建连、密钥交换和那次 `none` 探测
    /// （M1-04 §2.2 实测：同一条 2202 连接上第二次尝试 8 ms 就走完了）。加密私钥那一轮
    /// bcrypt 省不掉——每次 `frommemory` 都重付 0.4–0.6 s（M1-04 §3.1）。
    /// 这不等于"可以拿同一份凭据原地重试"——那是 `isRetryable` 管的，
    /// 认证失败一律不可自动重试，因为每发一次就烧掉服务器一格 `MaxAuthTries`。
    /// 被取消或超时打断的那趟也不在这里判：那抛的是 `CancellationError`，由后端硬拆。
    public var isFatalToSession: Bool {
        switch self {
        case .hostKeyMismatch, .protocolViolation:
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

    /// 错误码到可读排查建议映射表（v2.3 §472）。
    public var actionableAdvice: String {
        switch self {
        case .network(let kind):
            switch kind {
            case .connectionRefused:
                return "服务器拒绝连接。请检查服务器对应端口（SFTP 默认 22，FTP 默认 21）是否已开启并监听，或检查防火墙规则。"
            case .hostUnreachable:
                return "目标主机不可达。请检查本机网络或代理设置，并核对服务器 IP/域名是否正确。"
            case .timeout:
                return "网络操作超时。网络连接可能不稳定或服务器未及时响应，建议稍后重试。"
            case .connectionLost:
                return "网络连接意外中断。若发生在大文件传输过程中，Ferry 支持断点续传，重试将从当前进度继续。"
            case .dnsFailure:
                return "域名解析失败。请检查本机 DNS 设置或直接尝试使用服务器 IP 地址。"
            }

        case .auth(let failure):
            switch failure {
            case .badPassword:
                return "登录密码错误。请确认所填写的密码无误后重试。"
            case .keyRejected:
                return "服务器拒绝了提供的 SSH 密钥。请确认该公钥已添加至服务器的 ~/.ssh/authorized_keys 中。"
            case .passphraseRequired:
                return "该私钥文件已加密，需要输入口令（Passphrase）才能解锁。"
            case .passphraseIncorrect:
                return "私钥口令不正确。请重新输入正确的口令。"
            case .tooManyAuthAttempts:
                return "认证失败次数过多，已被服务器暂时断开。请稍候重试。"
            case .methodNotOffered:
                return "服务器不接受所选的认证机制。请检查服务器 sshd 配置。"
            case .agentUnavailable:
                return "无法连接到 ssh-agent。请确认 $SSH_AUTH_SOCK 环境变量已正确设置且 agent 正在运行。"
            }

        case .hostKeyMismatch(let fingerprint):
            return "【安全警示】服务器公钥指纹变更（\(fingerprint)）！可能存在中间人攻击或服务器已重装系统，请在偏好设置中核验并确认。"

        case .permissionDenied:
            return "服务器权限不足（Permission Denied）。请确认目标文件或目录具备相应读写权限。"

        case .notFound:
            return "指定的文件或目录不存在。可能已被移除或路径输入有误。"

        case .keyCollision:
            return "文件名大小写或 Unicode 归一化碰撞冲突（NFC/NFD）。为避免静默覆盖已有文件，操作已暂停。"

        case .undecodablePath:
            return "文件名不是合法 UTF-8。Ferry 已按原始字节安全保护，您可在站点设置中切换字符集（如 GBK/GB18030）。"

        case .unsupported:
            return "服务器不支持当前请求的操作功能。"

        case .protocolViolation(let msg):
            return "协议交互异常：\(msg)。"

        case .localIO(let kind):
            switch kind {
            case .diskFull:
                return "本地磁盘空间不足。请释放部分磁盘空间后重试。"
            case .writeFailed, .readFailed:
                return "本地文件读写失败。请检查本地目录访问权限。"
            }

        case .operationFailed(let op):
            return "服务器操作失败（\(op.diagnosticCode)）。请检查目标路径状态或查看详细日志。"
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
