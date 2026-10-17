import Foundation

/// 用户选的认证方式。M1'-4 实现，M1'-2 只把它接进契约——
/// 握手的产物（主机密钥、协商算法）要在认证之前就有地方放。
///
/// 含密钥材料，所以 `CustomStringConvertible` 一律脱敏。
/// 注意这层保护只对 `\(x)` 和 `print` 有效：`dump()` 走反射，
/// 会把 `password` 与 `passphrase` 原文打出来，诊断报告绝不许 dump 这个类型。
public enum AuthenticationMethod: Sendable, Hashable {
    case password(String)
    /// 私钥交给 `libssh2_userauth_publickey_frommemory`，Swift 层不解密（ADR-0000 I1、v2.3 §加密后端与私钥）。
    case privateKey(PrivateKeyMaterial)
    /// 外部 ssh-agent。libssh2 的 agent API 必须挂在已存在的 session 上，
    /// 传 NULL 直接段错误（ADR-0001 §4.6）。
    case sshAgent
    /// 服务器发 prompt、UI 逐条应答。应答通道是异步回调，进不了 Hashable，
    /// 所以 M1'-4 用单独的回调参数传，这里只表示"方式是这个"。
    case keyboardInteractive
    /// FTP 匿名登录（UI-REFERENCE.md U10）。
    case anonymous
}

public struct PrivateKeyMaterial: Sendable, Hashable {
    public let keyData: Data
    public let passphrase: String?

    public init(keyData: Data, passphrase: String?) {
        self.keyData = keyData
        self.passphrase = passphrase
    }
}

extension AuthenticationMethod: CustomStringConvertible {
    public var description: String {
        switch self {
        case .password: "password(已隐藏)"
        case .privateKey(let material):
            "privateKey(\(material.keyData.count) B, \(material.passphrase == nil ? "无口令" : "口令已隐藏"))"
        case .sshAgent: "sshAgent"
        case .keyboardInteractive: "keyboardInteractive"
        case .anonymous: "anonymous"
        }
    }
}
