import Foundation

/// 认证最终走的是哪条路。
///
/// `rawValue` 尽量取线路上的方法名，诊断报告里的 token 要能直接和抓包、和
/// `sshd -T` 的 `AuthenticationMethods` 对上。只有 `agent` 是我们自己的词：
/// 线路上它同样是 `publickey`，但私钥压根没经过 Ferry 的手，
/// 失败原因（agent 里没有可用的 key / agent 没在跑）和用户自己的密钥文件
/// 是两回事，混在一个 token 里没法定位。
public enum AuthenticatedMethod: String, Sendable, Hashable, CaseIterable {
    case password
    case publickey
    case agent
    case keyboardInteractive = "keyboard-interactive"
    /// 服务器在 `none` 探测里就给了 SUCCESS：这台不要凭据。
    /// 走到这条路时用户填的凭据一个字节都没发出去，所以不能记成 `password`/`publickey`。
    case none
}

/// 认证完成后的事实，和 `NegotiatedSession` 同样的理由放在一起：
/// 诊断报告要"一次连接一组自洽的参数"，分散取会拿到不同时刻的状态。
public struct AuthenticatedSession: Sendable, Hashable {
    public let method: AuthenticatedMethod
    /// 认证开始前服务器列出的可用方式（`libssh2_userauth_list` 的原文，按线路顺序）。
    /// 留着是因为最常见的用户问题是"这台到底收不收公钥"。实测五台在认证失败之后
    /// 重新列出来的清单与首次一字不差（M1-04 §1.3），所以后端只探一次就把它缓存下来——
    /// 每多探一次就多烧掉服务器一格 `MaxAuthTries`（M1-04 §1.4）。
    /// 注意"列了"不等于"会问"：2201 列了 `keyboard-interactive` 却一条提示都不发（M1-04 §5.2），
    /// 所以这份清单只能用来排除方式，不能用来承诺方式。
    public let serverOfferedMethods: [String]
    /// `agent` 路上成功那把的身份注释，即 `ssh-add -l` 打的尾列；其它方式为 nil。
    public let agentIdentity: String?

    public init(method: AuthenticatedMethod, serverOfferedMethods: [String],
                agentIdentity: String? = nil) {
        self.method = method
        self.serverOfferedMethods = serverOfferedMethods
        self.agentIdentity = agentIdentity
    }
}
