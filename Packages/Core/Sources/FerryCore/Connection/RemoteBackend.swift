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
    /// 密钥交换与主机密钥判定完成，认证还没成功。这条路能收 userauth 包，但开不了通道。
    case ready
    /// 认证通过，可以开 SFTP 通道了。与 `ready` 分开是因为连接池不许把
    /// "握手完了但凭据没过"的连接当可用的发出去（M1'-4）。
    case authenticated
    case aborted
    case closed
}

/// 建一条连接需要的全部输入。凭据在内，所以照旧不能 `dump()`。
public struct ConnectionRequest: Sendable, Hashable {
    public let endpoint: Endpoint
    public let authentication: AuthenticationMethod
    public let policy: ConnectionPolicy
    /// 文件名的显示字符集（R5）。默认 UTF-8。
    ///
    /// 只能是连接上的配置，不能自动探测：M0b-02 实测同一份 GBK 字节
    /// `D6 D0 CE C4` 有九个候选都"解得出来"，命中多个不构成证据。
    /// 它只影响显示，`RemotePath.wireBytes` 一个字节都不动。
    public let charset: CharsetConverter.Charset
    /// 大小写与归一化策略，属于连接（见 `RemoteFileSystem.pathPolicy`）。
    public let pathPolicy: PathPolicy

    public init(endpoint: Endpoint, authentication: AuthenticationMethod, policy: ConnectionPolicy,
                charset: CharsetConverter.Charset = .utf8, pathPolicy: PathPolicy = .posix) {
        self.endpoint = endpoint
        self.authentication = authentication
        self.policy = policy
        self.charset = charset
        self.pathPolicy = pathPolicy
    }
}

/// 连接的生命周期契约。M1'-2 交握手（TCP + 密钥交换 + 主机密钥判定），
/// M1'-4 交认证，文件系统操作在 M1'-5 由 `RemoteFileSystem` 提供——
/// 刻意不在这里就要求 `fileSystem`，免得拿一个抛"未实现"的壳冒充契约的一部分。
public protocol RemoteConnection: Actor {
    nonisolated var endpoint: Endpoint { get }

    /// TCP 连接 + 密钥交换 + 主机密钥信任判定。返回本次真正谈成的参数。
    /// 超时抛 `.network(.timeout)`，主机密钥不被信任抛 `.hostKeyMismatch`。
    func handshake() async throws -> NegotiatedSession

    /// 认证。必须在 `handshake()` 之后：libssh2 的 userauth 要求 transport 已就绪，
    /// 而主机密钥的信任判定必须先于凭据发出（ADR-0000 §10 H4）。
    ///
    /// `interactive` 只有 keyboard-interactive 会用；选别的方式时传 nil。
    /// 选了 keyboard-interactive 又传 nil 是调用方的错，在**碰到网络之前**就抛协议违规。
    ///
    /// 失败分两类，走向不同（M1-04 §2）：
    /// - `.auth(...)`：凭据问题，transport 完好，会话停在 `.ready`，
    ///   换一份凭据再调一次就行——省掉 TCP 建连、密钥交换和那次 `none` 探测。
    ///   但私钥的 bcrypt 那 0.4–0.6 s 每调一次 `frommemory` 都要重付，会话保留省不了它（M1-04 §3.1）。
    /// - 其它（取消、超时、socket 断了）：会话状态不可信，硬拆并转 `.aborted`。
    func authenticate(interactive: (any KeyboardInteractiveResponder)?) async throws -> AuthenticatedSession

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
