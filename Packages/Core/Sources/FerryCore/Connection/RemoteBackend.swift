import Foundation

/// 一次远端连接的生命周期阶段。
///
/// `aborted` 与 `closed` 分开是 ADR-0001 D6 的直接后果：被取消打断的 session
/// 里 C 调用返回什么取决于卡在哪个调用（实测 -36 / -43 / `Unable to startup channel`），
/// 它只能丢弃；正常关闭的 session 理论上还能重连复用。两者混成一个状态，
/// 连接池就会把已经废掉的 session 发回去。
public enum ConnectionPhase: String, Sendable, Hashable, CaseIterable {
    case idle
    case connecting
    case ready
    case aborted
    case closed
}

/// 建一条连接需要的全部输入。凭据在内，所以照旧不能 `dump()`。
public struct ConnectionRequest: Sendable, Hashable {
    public let endpoint: Endpoint
    public let authentication: AuthenticationMethod
    public let policy: ConnectionPolicy

    public init(endpoint: Endpoint, authentication: AuthenticationMethod, policy: ConnectionPolicy) {
        self.endpoint = endpoint
        self.authentication = authentication
        self.policy = policy
    }
}

/// 连接的生命周期契约。M1'-2 交握手（TCP + 密钥交换 + 主机密钥判定），
/// 认证在 M1'-4 接进同一协议，文件系统操作在 M1'-5 由
/// `RemoteFileSystem` 提供——刻意不在这里就要求 `fileSystem`，
/// 免得拿一个抛"未实现"的壳冒充契约的一部分。
public protocol RemoteConnection: Actor {
    nonisolated var endpoint: Endpoint { get }

    /// TCP 连接 + 密钥交换 + 主机密钥信任判定。返回本次真正谈成的参数。
    /// 超时抛 `.network(.timeout)`，主机密钥不被信任抛 `.hostKeyMismatch`。
    func handshake() async throws -> NegotiatedSession

    /// 只置原子标志，立即返回，可从任意线程调用（ADR-0001 D3）。
    /// 正在进行的调用由 session 线程在下一个 poll 边界观察到并抛 `CancellationError`，
    /// 阶段转为 `aborted`；取消路径禁止体面关闭（D4）。
    nonisolated func cancel()

    var phase: ConnectionPhase { get async }

    /// 正常收尾：走协议关闭再释放。与 `cancel()` 的硬拆是两条路。
    func close() async
}

/// 后端入口。`declaredCapabilities` 是后端固有上限，
/// 本次会话的可用集要等握手与扩展探测完才知道，属 M1'-5。
public protocol RemoteBackend: Sendable {
    var declaredCapabilities: RemoteCapabilities { get }
    func makeConnection(_ request: ConnectionRequest) -> any RemoteConnection
}
