import Foundation

/// 连接目标。刻意不含凭据：站点配置要能落盘，而密码和私钥材料只能来自钥匙串
/// 或用户当次输入（SecurityBaseline §存储）。
public struct Endpoint: Sendable, Hashable {
    /// 主机名或字面 IP，不含 scheme 与端口。
    public let host: String
    public let port: Int
    public let username: String

    public init(host: String, port: Int, username: String) {
        self.host = host
        self.port = port
        self.username = username
    }

    /// 日志、诊断报告与 UI 副标题都用它：用户名是排查权限问题必需的，
    /// 但这一串永远不含密码或密钥材料。
    public var displayString: String { "\(username)@\(host):\(port)" }
}

/// 一次连接的可调参数。放在 Core 是因为"超时属于契约"——
/// UI 要按它决定进度条多久算失败，后端只是执行者。
public struct ConnectionPolicy: Sendable, Hashable {
    /// DNS + TCP 建立的上限。
    public var connectTimeout: Duration
    /// 密钥交换的上限。老设备常在几百毫秒内回 banner 却把 kex 拖到十几秒。
    public var handshakeTimeout: Duration
    /// 一次认证尝试的上限。keyboard-interactive 等用户答题的时间**不算在内**
    /// （后端每次网络往返单独计），否则用户找验证码的 40 秒会被判成网络超时。
    public var authenticationTimeout: Duration
    /// 单个文件系统请求（开目录、读完一个包、一次 stat）的上限。
    ///
    /// 计时单位是**单个请求而不是整份清单**：一次大目录列表由几十个包拼成，
    /// 按整份限就会让"目录有一万条"变成超时理由，而按单包限只挡真卡死的那一个包。
    ///
    /// 这一格给默认值而其余三格不给：握手与认证测试永远不会发文件系统请求，
    /// 在那里写 `fileOperationTimeout` 只是噪音（本依赖集里有 12 个这样的调用点）。
    public var fileOperationTimeout: Duration

    /// 默认的单请求上限。`standard` 用的就是它（不重复写数字）。
    public static let defaultFileOperationTimeout: Duration = .seconds(15)

    /// 算法偏好。全部为空表示"用 libssh2 的默认顺序"。
    public var algorithms: AlgorithmPreferences

    public init(connectTimeout: Duration, handshakeTimeout: Duration,
                authenticationTimeout: Duration,
                fileOperationTimeout: Duration = ConnectionPolicy.defaultFileOperationTimeout,
                algorithms: AlgorithmPreferences) {
        self.connectTimeout = connectTimeout
        self.handshakeTimeout = handshakeTimeout
        self.authenticationTimeout = authenticationTimeout
        self.fileOperationTimeout = fileOperationTimeout
        self.algorithms = algorithms
    }

    public static let standard = ConnectionPolicy(
        connectTimeout: .seconds(10),
        handshakeTimeout: .seconds(30),
        authenticationTimeout: .seconds(30),
        algorithms: .libraryDefault
    )
}

/// 算法偏好，按 SSH 的五个协商维度给。填进去的是 libssh2 认得的算法名，
/// 顺序即优先级；libssh2 会把不在它编译列表里的名字直接判为不支持。
///
/// 加密与 MAC 各自同时作用于双向：服务器端配置是对称的，
/// 而 v2.3 §算法白名单 的设备清单里没有一个按方向不对称配置。
public struct AlgorithmPreferences: Sendable, Hashable {
    public var keyExchange: [String]
    public var hostKey: [String]
    public var encryption: [String]
    public var mac: [String]

    public init(keyExchange: [String] = [], hostKey: [String] = [], encryption: [String] = [], mac: [String] = []) {
        self.keyExchange = keyExchange
        self.hostKey = hostKey
        self.encryption = encryption
        self.mac = mac
    }

    public static let libraryDefault = AlgorithmPreferences()

    public var isEmpty: Bool {
        keyExchange.isEmpty && hostKey.isEmpty && encryption.isEmpty && mac.isEmpty
    }
}
