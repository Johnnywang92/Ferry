# Mac SFTP/FTP 客户端方案审核报告（v2 审阅意见）

> 评审对象：`Mac SFTP/FTP 客户端开发方案 v2`
> 评审结论：质量极高，立论扎实、视野开阔。精准击中了底层边界，但存在 3 处核心协议与依赖认知陷阱、3 处 Swift 6 并发代码缺陷、以及系统级细节需在 M0' 前修正。
> 修订落地：已全部吸纳并更新至 `sftp-client-plan-v2.md` 及 `sftp-client-plan-v2.1.md`。

---

## 一、 关键技术盲点与隐患（需在 M0' 前修正）

### 1. SFTP “单 Session 多通道” 的协议认知陷阱（严重）
* **方案现状**（原 §7.1 & §9 M0' Spike 验收标准 1）：
  > “单 session 3 个并发 SFTP 通道跑满带宽”
* **技术隐患**：
  在 SSH-2 协议规范（RFC 4254）与标准 OpenSSH `sshd` 实现中，**单个 SSH Session 默认只允许打开一个 `subsystem sftp` 逻辑通道（Channel）**。如果客户端尝试在同一个 SSH Session 上再次 `libssh2_sftp_init()` 开启第二个 SFTP 通道，主流服务端会直接拒绝通道请求（`SSH_MSG_CHANNEL_OPEN_FAILURE`）或挂断。
* **修正建议**：
  必须将 Spike 验收标准从“单 session 多 SFTP 通道”调整为以下两种真实方案之一：
  1. **方案 A（多 Session 连接池，业界最通用）**：控制面 1 条 Session，并发传输各开独立 Session（需要测试不同服务端对 `MaxStartups` / `MaxSessions` 的并发容忍度）。
  2. **方案 B（单通道异步 Pipelining）**：在单个 SFTP 通道内，不等上一个包的 ACK 就发出多个 `SSH_FXP_READ` / `SSH_FXP_WRITE` 请求。这是 FileZilla / Cyberduck 跑满高延迟宽带的核心手段，但 `libssh2` 的高层 API 对此支持较弱，需在 Spike 中重点求证。

### 2. libssh2 编译依赖链黑盒：加密后端与 OpenSSH 私钥解析
* **方案现状**（原 §3.1 & §9 M1'）：
  > “passphrase 回调 / OpenSSH 新格式私钥 `-----BEGIN OPENSSH PRIVATE KEY-----`，libssh2 不直接支持，需解析或转 PKCS#8”
* **技术隐患**：
  `libssh2` 自身只负责 SSH 协议封包，其底层加密与密钥解析完全委托给加密后端（Backend）。在 macOS 上打包 `xcframework` 时：
  * 若选择 Apple 原生 `Security.framework`（OSStatus）：它对 OpenSSH 新格式私钥（bcrypt KDF）**完全不支持**，也无法灵活配置旧算法白名单。
  * 若选择 OpenSSL 3.x 或 mbedTLS：你必须**同时把 OpenSSL/mbedTLS 一起编译进 xcframework**，这会显著增加构建矩阵复杂度和二进制体积。
* **修正建议**：
  在 §3.1 中明确 **libssh2 的 Crypto Backend 选型**（推荐静态打包 `OpenSSL 3.x` 或专门引入轻量 Swift 私钥解析库如 `SwiftyRSA`/`CryptoKit` 扩展，先在 Swift 层把 OpenSSH 格式转成标准 PKCS#8 DER 再喂给 libssh2）。

### 3. 分发模式与沙盒概念澄清（澄清）
* **方案现状**（原 §1 D1）：
  > “v1 的错误：认为 Developer ID 默认无沙盒。实际上 Developer ID 分发的 app 同样默认启用 `com.apple.security.app-sandbox`。”
* **技术澄清**：
  Developer ID 必须强制开启的是 **Hardened Runtime**（`-o runtime`，防代码注入、动态库劫持），但**苹果并未强制 Developer ID 应用开启 App Sandbox**。不过，**方案提倡从第一天就按 `ScopedBookmark` 抽象数据层是非常明智且具有远见的**，建议保留该设计，但修正对苹果规则的描述。

---

## 二、 方案中 Swift 代码片段的 Bug 与 Swift 6 并发漏洞

### 1. `ScopedResource` 内存泄漏与编译错误
* **问题**：`url` 未保存为实例属性，`deinit` 中无法引用；且标记为 `@MainActor` 会导致在后台 I/O 线程操作或释放时报并发隔离错误。
* **修正后代码**：
```swift
final class ScopedResource: Sendable {
    private let url: URL
    private let didStart: Bool

    init?(_ url: URL) {
        self.url = url
        self.didStart = url.startAccessingSecurityScopedResource()
        if !self.didStart {
            // mode A (非沙盒) 下通常返回 false，属于预期行为
        }
    }

    deinit {
        if didStart {
            url.stopAccessingSecurityScopedResource()
        }
    }
}
```

### 2. `Store<T>` 读写竞争与混用 GCD
* **问题**：
  1. `write` 中使用 `ioQueue.async` 闭包并不是 `async/await` 的原生写法，会导致任务脱节；
  2. `read()` 在 `ioQueue` 之外直接通过 `Data(contentsOf: url)` 读取，写入原子替换瞬间可能产生竞态；
  3. 项目既然最低定在 macOS 14，**应当全面废除 `DispatchQueue` 封装，改用原生 Swift `actor`**。
* **修正后代码**：
```swift
actor Store<T: Codable> {
    private let url: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(url: URL) {
        self.url = url
    }

    func read() throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try decoder.decode(T.self, from: data)
    }

    func write(_ value: T) throws {
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }
}
```

### 3. `RemoteError` 属性非法语法
* **问题**：`var isFatalToSession: Bool { auth / hostKeyMismatch / protocolViolation }` 是非法语法。
* **修正**：写为标准的 Swift pattern match：
```swift
extension RemoteError {
    var isRetryable: Bool {
        if case .network = self { true } else { false }
    }
    var isFatalToSession: Bool {
        switch self {
        case .auth, .hostKeyMismatch, .protocolViolation:
            return true
        default:
            return false
        }
    }
}
```

---

## 三、 容易被忽视的 macOS 系统级细节

1. **外部编辑监听（§6.5）的防抖与父目录监控**：
   * 现代编辑器（VSCode / Sublime / TextEdit）执行原子保存时，是在目标文件的**所在目录**生成临时文件后 `rename` 覆盖。如果只监视单个文件的 FSEvent，可能会在 `rename` 瞬间丢失句柄。
   * **必须增加 500ms~1000ms 的防抖（Debounce）**：编辑器在保存时往往触发多达 3~5 次连续的 `FSEvents` 事件（写入 temp、修改元数据、rename），无防抖会引发多次重复上传或上传不完整文件。
2. **APFS 与 Unicode 归一化（NFC vs NFD）**：
   * 方案提到了大小写敏感性（Case Policy），但遗漏了 **Unicode 归一化**。
   * macOS HFS+ 历史强推 NFD，APFS 虽然是 Normalization-Preserving，但很多 macOS 框架输出仍然偏向 NFD；而 Linux 服务器（ext4/xfs）文件名绝大多数是 UTF-8 NFC。
   * 在 `PathResolver` 中，`RemotePath` 比较与本地 APFS 路径对齐时，必须声明归一化策略（推荐比较前统一做 Unicode NFC 转换），否则同一个带声调字母或日韩文字符在两边比对会永远显示为“已修改/不一致”。
3. **大文件传输的内存压迫与 Buffer 复用**：
   * §4.4 中 `while let chunk = try await reader.readChunk(maxBytes: 256 * 1024)`：在千兆/万兆带宽下，每秒可能分配数千次 256KB 的 `Data`，在 Swift 异步运行时下会导致严重的内存碎片和高水位内存占用。
   * 建议在 `TransferEngine.pump` 内部实现定长环形缓冲区或 `ByteBuffer` 复用，避免频繁 malloc/free。

---

## 四、 里程碑与排期评估（§9）

| 阶段 | 计划工时 | 评估反馈 | 建议调整 |
|---|---|---|---|
| **M0'** | 1.5 周 | **范围严重过载**：包含了协议、3个横切层、libssh2 非阻塞 Spike、4 个 Docker 服务、签名、安全基线。1.5 周根本做不完。 | 建议调整为 **2~2.5 周**，或将 Docker FTP 方言测试后移到 M5，M0' 仅聚焦 SFTP Spike。 |
| **M1'~M3** | 7.5~10 周 | 估算扎实，把传输队列与原子 rename 放在重心（3~4 周）非常合理。 | 保持。 |
| **M4~M6** | 6.5~7 周 | 契约测试和三方比较同步引擎放在后半程，边界清晰。 | 保持。 |

---

## 落地状态

以上所有意见与代码已全部合并入：
- 完整开发方案：[`sftp-client-plan-v2.md`](file:///Users/yifanwang/workspace/Ferry/sftp-client-plan-v2.md) / [`sftp-client-plan-v2.1.md`](file:///Users/yifanwang/workspace/Ferry/sftp-client-plan-v2.1.md)
- 核心变更速查：[`sftp-client-plan-v2-changelog.md`](file:///Users/yifanwang/workspace/Ferry/sftp-client-plan-v2-changelog.md)
