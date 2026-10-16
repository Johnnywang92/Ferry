import Foundation

/// 服务器在 keyboard-interactive 里发来的一条询问（`SSH_MSG_USERAUTH_INFO_REQUEST` 的 prompt）。
///
/// `echo` 是线路上带的标志，不是我们猜的：OpenSSH 的 PAM 把口令那条标成 `false`、
/// 把"你的验证码是多少"那条标成 `true`。UI 按它决定遮不遮输入框。
public struct KeyboardInteractivePrompt: Sendable, Hashable {
    public let text: String
    public let echo: Bool

    public init(text: String, echo: Bool) {
        self.text = text
        self.echo = echo
    }
}

/// 一轮询问。一次认证里服务器可以发多轮（2FA 就是常见的两轮），
/// 所以这个类型是"每轮一个新实例"，不是"整个会话一个"。
public struct KeyboardInteractiveRequest: Sendable, Hashable {
    /// 询问是哪个端点的，应答者通常是共享的 UI 对象，要靠它把对话框挂回正确的连接上。
    public let endpoint: Endpoint
    /// 线路上的 name 字段。OpenSSH 在这里放"PAM authentication"一类的来源标识。
    public let name: String
    /// 线路上的 instruction 字段，可能是"请把手机上的码填进来"这种人该读的话。
    public let instruction: String
    public let prompts: [KeyboardInteractivePrompt]

    public init(endpoint: Endpoint, name: String, instruction: String,
                prompts: [KeyboardInteractivePrompt]) {
        self.endpoint = endpoint
        self.name = name
        self.instruction = instruction
        self.prompts = prompts
    }
}

/// 逐条回答询问的人（真实实现是 UI）。
///
/// **调用点在 session 线程的 C 回调里被同步等住**（ADR-0000 §12 H11）：libssh2 的
/// kbdint 状态机没有"挂起—恢复"的口子，回调返回时答案必须已经填好。等待期间
/// 每 50 ms 回顶部查一次取消标志，所以 D3 的取消粒度保住的是"置标志到退出等待"，
/// 不是"置标志到 C 调用返回"。
///
/// 由此有一条硬约束：实现方**不许绕回同一条 session 执行器**（比如再调回这条连接的
/// actor），那等于自己等自己。走 MainActor 或任意别的执行器都安全。
public protocol KeyboardInteractiveResponder: Sendable {
    /// 返回的条数必须与 `request.prompts` 一致。少了或多了一条，连接层判协议违规、
    /// 不会把半截答案发出去——但要清楚：**一次空应答还是已经发出去了**（回调没有返回
    /// 错误的路，M1-04 §4.4），服务器上照样记一次失败认证。所以"别多答也别少答"
    /// 是实现方的责任，这一格我们兜不住。
    /// 返回 nil 是用户关掉对话框：连接层抛 `CancellationError`，
    /// 与主机密钥那层的 `decline` 同形（ADR-0000 §11 H6）。
    func respond(to request: KeyboardInteractiveRequest) async -> [String]?
}
