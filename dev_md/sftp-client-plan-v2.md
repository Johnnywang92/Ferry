# Mac SFTP/FTP 客户端开发方案 v2.2

> 本版基于 Johnny Wang 审查意见修订。修正了 SFTP 单 session 并发通道认知偏差、Swift 协作线程池饥饿、句柄独占访问漏洞、RemotePath NFC 破坏 Linux 同形文件、同步引擎判重与真值表缺陷，重构了 Crypto 后端与算法白名单。主要变化见 §12 差异清单。
> 状态：**M0 待启动**。有 2 个阻塞决策需先定（§1），其余在 M0' 内由 spike 产出。

---

## 1. 阻塞决策：启动前必须定

这两项不是"以后再说"，它们会改变数据模型和迁移成本，越晚定越贵。

### D1 · 分发模式

| 模式 | 沙盒 | 本地路径访问 | 本地存储要求 | 结论 |
|---|---|---|---|---|
| **A. Developer ID + 非沙盒** | 关 | 任意路径直读直写 | 存 path 即可 | **MVP 选这个** |
| B. Developer ID + 沙盒 | 开 | `NSOpenPanel` 授权 + bookmark | 存 `URL.bookmarkData()` | 需迁移 |
| C. Mac App Store | 强制开 | 同 B + 更严审核 | 同 B | 最后考虑 |

**规则与签名澄清**：
1. **Hardened Runtime**（`-o runtime`，防代码注入、动态库劫持）是苹果公证（Notarization）的强制要求，但苹果**并未强制 Developer ID 应用开启 App Sandbox**（App Sandbox 仅对 Mac App Store 上架强制要求）。
2. **代码签名卫生**：禁止使用已被弃用且易出错的 `codesign --deep`，必须对 Frameworks、XPC、二进制插件从内向外逐层签名。

**v2.2 的做法**：
- M0~M5 明确走模式 A：开启 Hardened Runtime，逐层组件签名并公证，暂不启用 `com.apple.security.app-sandbox`。
- **数据层抽象与沙盒迁移现实**：
  - 本地路径采用 `ScopedBookmark` 抽象封装（`path` + `bookmarkData?` 双字段）。
  - **关键现实**：Security-Scoped Bookmark 只能在用户通过 `NSOpenPanel` 显式交互授权时创建。未来若升级至模式 B（沙盒），模式 A 存下的纯绝对路径**无法静默自动转换为有效 Bookmark**，必须设计平滑的“重新授权引导交互”，由用户一次性确认常用本地目录访问权（详见 `docs/SANDBOX-MIGRATION.md`，M6 产出）。

```swift
struct ScopedBookmark: Codable, Hashable {
    let path: String
    var bookmarkData: Data?      // mode A 为 nil，mode B 授权后补齐
    let isDirectory: Bool
    let createdAt: Date
}

final class ScopedResource: Sendable {
    private let url: URL
    private let didStart: Bool

    init?(_ url: URL) {
        self.url = url
        self.didStart = url.startAccessingSecurityScopedResource()
        if !self.didStart {
            // mode A (非沙盒) 下通常返回 false，属于预期行为，仍可正常访问
        }
    }

    deinit {
        if didStart {
            url.stopAccessingSecurityScopedResource()
        }
    }
}
```

### D2 · 首要目标用户

决定优先级排序，不是决定功能清单。选定后更新 §9 里程碑的优先级列。

| 场景 | 特征 | 优先级上移 | 优先级下移 |
|---|---|---|---|
| **A. 自用/团队日常**（传配置、代码） | 用 `~/.ssh`、大量小文件、几乎不用 FTP | `.ssh/config` 导入、`ssh-agent` 集成、隐藏文件、权限修改、`⌘⇧G`、错误提示质量 | FTP/FTPS 后端、拖拽 |
| **B. 通用客户端发布** | 陌生用户、混合文件、大文件多 | 拖拽双向、Quick Look、同步预览、诊断报告 | ProxyJump 隧道 |
| **C. App Store 上架** | 审核合规优先 | 沙盒、无障碍、本地化 | 自定义算法白名单 |

**D2 未定前不要开始 M1** —— 它决定 M1 的算法兼容矩阵宽度、`ssh-agent` 支持度与 `.ssh/config` 导入是否必须。

### 非阻塞的推荐默认值

| 项 | 推荐值 | 理由 |
|---|---|---|
| 最低 macOS | **14 (Sonoma)** | `@Observable` 完备可用；macOS 15 已普及，定 12/13 会引入大量条件编译 |
| SwiftData / GRDB | **都不用** | 见 §7.4，`actor Store` + 原子写 JSON |
| 分发签名基线 | Developer ID + Hardened Runtime | 见 D1，公证必需，暂不上沙盒 |

---

## 2. 目标与范围

**MVP（M0'~M3，约 8~9 周）**
SFTP 连接、双栏浏览、上传/下载、传输队列（暂停/续传/恢复）、站点管理 + `.ssh/config` 导入、隐藏文件开关、算法兼容矩阵。

**v1.0（M4~M6，约 6~8 周）**
FTP/FTPS 后端、双向拖拽、Quick Look、外部编辑回传、三方同步引擎、诊断报告、契约测试、公证打包。

**v1.1+**
内置终端、ProxyJump、传输限速/定时、服务器↔服务器直传、拖拽回传（远端→远端）。

**不做**
自研协议底层、File Provider 扩展（避免提前引入 sandbox 约束）、S3/WebDAV（协议层已预留但不实现）。

---

## 3. 依赖与安全基线（v2 新增）

v1 完全没核对依赖版本与 CVE。本节为**强制交付物**，M0' 产出 `docs/SecurityBaseline.md`，此后每个 PR 更新。

### 3.1 libssh2

| 项 | 状态 |
|---|---|
| 上游最新 | **1.11.1（2024-10-16），已两年无新 tag** |
| 获取方式 | **从 git main 构建 + vendor**，锁定固定 commit hash（如 `git rev-parse HEAD`）并写入基线；禁止用 Homebrew 的 1.11.1 |
| 关键修复跟踪 | 持续核对官方 Advisory（如 SFTP 响应解析越界、长用户名整数溢出等上游 PR）并在 `docs/SecurityBaseline.md` 中逐条附带完整 NVD/GHSA 官方链接 |
| 打包 | 自建 `libssh2.xcframework`（静态），仅由 `Backends` target 链接 |

**加密后端（Crypto Backend）与私钥解析选型（v2.2 澄清）**：
`libssh2` 官方原生支持的加密后端包括 OpenSSL、wolfSSL、mbedTLS、libgcrypt、WinCNG 等（**官方并无 Apple `Security.framework` 后端**）。现实选型是 **OpenSSL 3.x** 对比 **mbedTLS**：
- **选型结论：静态打包 OpenSSL 3.x**。功能最为完备，原生支持现代算法及全部老旧兼容算法。
- **私钥解析支持**：`libssh2` 配合 OpenSSL 自身即原生支持 `openssh-key-v1`（含 bcrypt KDF 加密的 `-----BEGIN OPENSSH PRIVATE KEY-----`）解析，**无需在 Swift 层画蛇添足做前置解密转 PKCS#8**。这样做还能避免明文私钥长时间暴露在 Swift 托管堆内存中，缩小攻击面。
- **构建策略**：在 M0' 第一步编写自动化脚本（`Scripts/build-libssh2-openssl.sh`），将 libssh2 + OpenSSL 3.x 静态合并打包为通用的 `libssh2.xcframework`（macOS arm64 / x86_64 胖二进制），符号严格内敛在 `Backends` target，避免与系统或三方符号冲突。

**算法白名单（`M1` 交付物）**：libssh2 1.11 起默认关闭大量老旧弱算法。安全上是好事，但老设备/嵌入式 NAS 会连不上。需在握手前显式配置：

| 类别 | 放开（兼容老设备） | 保持关闭（严重安全风险） |
|---|---|---|
| 主机密钥 | `ssh-rsa`、`ssh-dss` | — |
| KEX | `diffie-hellman-group14-sha1`、`diffie-hellman-group1-sha1`（1024位） | 弱 DH < 1024 位 |
| 加密/MAC | `aes128-ctr`、`aes256-ctr`、**`aes128-cbc`、`aes256-cbc`** | **RC4、3DES、arcfour、blowfish、cast128** |
| MAC | `hmac-sha1`、`hmac-sha2-256`、`hmac-sha2-512` | **md5、hmac-md5、ripemd160** |

实现方式：`libssh2_session_method_pref()` 逐项设置。**UI 必须暴露"允许弱算法"开关**，因为放开 CBC/SHA1 是需要用户知情的安全决策。

### 3.2 SwiftNIO SSH（备选方案，仅当选 Citadel）

- **NIO-SSH 漏洞跟踪**：必须 `>= 0.14.1`（修复栈越界风险）。在 `docs/SecurityBaseline.md` 中核实完整 Advisory 链接。
- 作为客户端远程利用门槛较高，但需持续跟踪 NIO 生态安全响应。选型前实际核对 Citadel 上游提交与维护状态。

### 3.3 其他

| 依赖 | 用途 | 备注 |
|---|---|---|
| libcurl | FTP/FTPS | curl license，兼容闭源 |
| GRDB | 后期可选 | MVP 不用 |

---

## 4. 核心抽象（v2 重写）

v1 的 `RemoteFileSystem` 有三个问题：`RemoteItem` 未定义、无 capability 协商、协议混杂了连接生命周期。

### 4.1 分层：能力与生命周期分离

```swift
protocol RemoteFileSystemFactory: Sendable {
    var declaredCapabilities: RemoteCapabilities { get }   // 静态，后端固有
    func makeConnection(_ config: SiteConfig) -> RemoteConnection
}

protocol RemoteConnection: Sendable {
    var negotiatedCapabilities: RemoteCapabilities { get } // 动态，登录后协商（FTP FEAT 等）
    func handshake() async throws
    func close() async
    var fileSystem: RemoteFileSystem { get }
}

protocol RemoteFileSystem: Sendable {
    func list(_ path: RemotePath) async throws -> [RemoteItem]
    func stat(_ path: RemotePath) async throws -> RemoteItem
    func lstat(_ path: RemotePath) async throws -> RemoteItem
    func openRead(_ path: RemotePath) async throws -> RemoteReader
    func createWrite(_ path: RemotePath, offset: Int64) async throws -> RemoteWriter
    func mkdir(_ path: RemotePath, permissions: UInt16?) async throws
    func remove(_ path: RemotePath, recursive: Bool) async throws
    func rename(_ from: RemotePath, to: RemotePath, overwrite: Bool) async throws
    func symlink(target: String, at path: RemotePath) async throws
    func readlink(_ path: RemotePath) async throws -> String
    func chmod(_ path: RemotePath, _ mode: UInt16) async throws
    func statvfs(_ path: RemotePath) async throws -> RemoteVolumeInfo
}
```

改动要点：
- **连接生命周期移出协议**，`RemoteConnection` 承担。UI 拿到 `RemoteFileSystem` 时连接必然已就绪，无需 `connect()`。
- **显式 `stat` / `lstat`**，软链语义不再隐含。
- **`RemoteReader` / `RemoteWriter` 句柄**取代 v1 的 `read(path:offset:) -> AsyncThrowingStream<Data>` 与 `write(path:offset:data: AsyncStream<Data>)`。理由见 §4.4。
- **不支持的能力直接不在协议里**（`lstat` 只对支持软链的后端存在实现），而不是全部塞进一个大协议再抛 unsupported。

### 4.2 `RemoteItem` 完整定义（v1 缺失）

```swift
struct RemoteItem: Sendable, Hashable, Identifiable {
    var id: String { path.encodedKey }   // 用于 diff 的稳定标识

    let path: RemotePath
    let displayName: String

    let kind: Kind                 // .file / .directory / .symbolicLink / .other
    let size: Int64?
    let modificationDate: Date?

    // ↓ 可信度标记 —— v2 关键新增
    let sizeIsExact: Bool          // FTP 目录列表常给估算值
    let mtimeIsReliable: Bool      // 部分 FTP 服务器不返回 MDTM；SFTP 为秒级精度

    let linkTarget: String?
    let permissions: UInt16?       // SFTP 有；FTP 基本无 → nil
    let owner: String?
    let group: String?
}
```

**为什么可信度标记必须在第一天就有**：SyncEngine 会用 mtime 判断"未修改"。若把不可信的 mtime 当可信，会产生"看起来没变、实际内容已改"的静默数据丢失 —— 这类 bug 极难定位，一旦上线就很难修。宁可 `mtimeIsReliable == false` 时强制走哈希。

### 4.3 Capability 协商（v1 缺失）

SFTP 与 FTP 的能力差异是**结构性的**，不是"某个功能没实现"：

| 能力 | SFTP | FTP/FTPS |
|---|---|---|
| 断点续传下载 | 可（`sftp_read` offset） | 可（`REST`），支持度参差 |
| 断点续传上传 | 可（seek + write） | 靠 `APPE`，**部分服务器静默写坏** → 默认关闭，需协商开启 |
| 权限位 | 可 | 基本不可 |
| 属主 | 可 | 基本不可 |
| 符号链接 | 可 | 基本不可 |
| 服务端内复制 | 可 | 仅部分（`SITE CPFR`） |
| 原子覆盖 rename | 可（`RENAME_ATOMIC`） | 需先 `DELE` → 非原子 |
| `lstat` | 可 | 不可 |
| 目录 stat | 可 | 不可（只能 LIST 父目录匹配） |
| 文件哈希 | 无（SFTP v3） | 无 |
| charset 协商 | 固定 UTF-8 | `OPTS UTF8 ON` / `FEAT`，**服务器常谎报** |

```swift
struct RemoteCapabilities: OptionSet, Sendable {
    static let resumableDownload, resumableUpload, permissions, ownership
    static let symbolicLinks, atomicRenameOverwrite, serverSideCopy
    static let directoryStat, reliableMTime, hashing, charsetNegotiation
}
```

UI 必须读它决定：权限列显示什么、上传按钮是续传还是整体传、rename 是否提示"非原子"。

**两层能力**：`declared`（后端固有）与 `negotiated`（登录后协商，FTP 的 `FEAT` 经常不实）。上传续传这类危险能力默认关闭，需在 `negotiated` 中显式确认才启用。

### 4.4 流式读写：改用句柄 + chunk 语义

v1 的 `read` 返回 `AsyncThrowingStream<Data, Error>`，有两个问题：
### 4.4 流式读写：改用句柄 + 原生缓冲复用（Swift 6 独占访问安全）

v1 的 `read` 返回 `AsyncThrowingStream<Data, Error>` 有背压缺失与取消无法打断底层的问题。但若简单设计为 `mutating struct` 句柄，当后台 Task 正在执行 `read` 时外部并发调用 `cancel()`，会直接触发 Swift 运行时**独占访问冲突崩溃（Exclusive Access Violation Crash）**。

v2.2 将读写句柄定义为**引用语义（`actor` 或 `final class: Sendable`）**，并原生支持高效缓冲复用：

```swift
/// 读句柄：必须是 Sendable 引用类型（actor 或内部线程安全的 final class），杜绝并发独占访问冲突
protocol RemoteReader: AnyObject, Sendable {
    var totalSize: Int64? { get }

    /// 高性能缓冲复用接口：直接填充调用方预分配的缓冲槽，返回实际读取字节数（0 = EOF）
    func read(into buffer: UnsafeMutableRawBufferPointer) async throws -> Int

    /// 取消操作：安全并发打断底层阻塞或非阻塞轮询，不产生独占访问违规
    func cancel() async
}

/// 写句柄：必须是 Sendable 引用类型
protocol RemoteWriter: AnyObject, Sendable {
    /// 写入指定切片，返回实际写入字节数供断点续传精确校验
    @discardableResult
    func write(from buffer: UnsafeRawBufferPointer) async throws -> Int

    func commit() async throws
    func abort() async                                // 释放远端句柄，清理远端临时文件
}
```

调用方循环（结合预分配缓冲槽）：

```swift
let reader = try await fs.openRead(path)
let bufferSize = 256 * 1024
let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: bufferSize, alignment: 16)
defer { buffer.deallocate() }

while true {
    try Task.checkCancellation()
    let bytesRead = try await reader.read(into: buffer)
    if bytesRead == 0 { break } // EOF
    let chunkView = UnsafeRawBufferPointer(rebasing: buffer[0..<bytesRead])
    try await localWriter.write(from: chunkView)
    await progress(.advance(by: bytesRead))
}
```

收益：
- **独占访问与并发安全**：引用类型隔离状态，`cancel()` 可随时并发安全调用。
- **天然背压与取消点**：拉取式调用，每次轮询检查 `Task.checkCancellation()`。
- **零额外堆内存分配**：单文件传输全生命周期复用同一段连续内存，彻底消除高带宽下的内存尖峰。

### 4.5 路径与编码：字节规范与 NFC 派生分离（跨端同形防御）

v1 用 `path: String` 一路到底，导致大小写敏感性丢失与非 UTF-8 字符永久损坏。然而，**直接将路径字节统一归一化为 NFC 同样是严重错误**：在 Linux 服务端（ext4/xfs）上，NFC 与 NFD 同形但不同编码的文件名**是作为两个完全独立的文件合法并存的**。若将原始字节强转为 NFC，会把远端两个独立文件强行折叠，导致后续 `stat` / `rename` 打到错误路径。

v2.2 的双轨设计：**原始传输字节（Wire Bytes）与规范化比较键（Comparison Key）分离**。

```swift
struct RemotePath: Hashable, Comparable, Sendable {
    /// 规范表示：严格保留远端下发的原生字节（wire bytes）。直接以此作为发往服务端的绝对真实路径。
    let rawBytes: [UInt8]
    let components: [Component]
    let isAbsolute: Bool

    /// 十六进制稳定键，用于字典精确索引，不发生任何信息损失
    var hexEncodedKey: String { rawBytes.map { String(format: "%02x", $0) }.joined() }

    /// 跨端对齐比较键（派生字段）：将合法 UTF-8 序列转为 Unicode NFC 标准形式。
    /// 仅供 SyncEngine 对齐与本地 APFS 文件比对使用，绝不回写给远端！
    var nfcComparisonKey: String

    /// 仅用于展示与 UI 边界。非法序列以 \xNN 呈现，不做有损替换。
    func displayString(using decoder: CharsetDecoder) -> String

    /// 发往服务器的字节（按协商 charset 编码）
    func wireBytes(using encoder: CharsetEncoder) throws -> [UInt8]
}
```

关键防御规则：
1. **Unicode 同形异构碰撞报警**：当 `PathResolver` 在远端同一目录下发现两个文件的 `rawBytes` 不同但 `nfcComparisonKey` 相同（即 Linux 存在同形异码文件），立即向用户发出强警告，禁止执行双向同步，防止本地覆盖。
2. **APFS 大小写碰撞拦截（Case Collision Detection）**：
   - macOS APFS 是“保留大小写但不区分大小写”（Case-Preserving, Case-Insensitive）。
   - 若 Linux 远端同一目录下同时存在 `Foo.txt` 和 `foo.txt`，一旦下载到本地 APFS 会发生**静默破坏性覆盖**！
   - 下载引擎与 `SyncEngine` 必须在计划执行前做**大小写碰撞预检**，发现碰撞直接拦截并弹窗要求用户选择重命名策略，绝不静默放行。
   - `casePolicy`（大小写策略）提升至 `RemoteFileSystem` / 会话配置层面声明，不冗余挂在每个 `RemotePath` 实例上。

`PathResolver` 负责：POSIX 根、`~` 展开、`.` / `..` 回退（不越过根）、空路径、重复分隔符、尾部 `/` 归一、派生 NFC 比对键、软链展开深度上限（防环）。**M1 交付物，且必须有独立单测**。

### 4.6 错误分类（v1 缺失）

```swift
enum RemoteError: Error {
    case network(NetworkKind)                      // retryable
    case auth(AuthFailure)                         // 不 retry：密码错 / 密钥拒
    case hostKeyMismatch(fingerprint: String)       // 强警告，必须人工确认
    case permissionDenied(path: RemotePath)        // 不 retry
    case notFound(path: RemotePath)                // 不 retry，但 SyncEngine 需区分于 network
    case caseCollision(existing: String, incoming: String) // APFS 大小写碰撞阻断
    case unsupported(RemoteCapabilities)           // 不 retry，UI 应降级而非报错
    case undecodablePath(bytes: [UInt8])           // UI 走十六进制视图
    case protocolViolation(String)
    case localIO(LocalIOKind)
}

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

`notFound` 必须是可识别类型：SyncEngine 靠它区分"远端已删 → 记为待删除"与"网络故障 → 放弃本次同步"。混淆两者会让引擎在网络抖动时误删本地文件。

UI 按 `isRetryable` 分三类呈现：可重试的给重试按钮；不可重试的给具体原因；`.unsupported` 直接降级隐藏功能而非弹错误。

---

## 5. 架构分层

```
┌──────────────────────────────────────────────────────────┐
│ UI                                                       │
│  NSOutlineView 文件列表 │ SwiftUI：工具栏/队列/站点/同步预览 │
├──────────────────────────────────────────────────────────┤
│ ViewModel（@MainActor @Observable，UI 侧不做状态同步）      │
│   BrowserController ──┘                                 │
├──────────────────────────────────────────────────────────┤
│ Services                                                 │
│  ├ ConnectionManager（连接池 / 心跳 / 指数退避重连）        │
│  ├ TransferQueue（actor，调度 + 限流 + 续传策略）          │
│  ├ SyncEngine（base 三方比较 → DiffPlan → TransferTask）  │
│  └ EditSession（FSEvents 监听 → 冲突检测）                │
├──────────────────────────────────────────────────────────┤
│ 横切层（v2 新增，跨后端共用，必须先于后端完成）             │
│  ├ PathResolver     路径规范化 + 大小写策略                │
│  ├ CharsetConverter Data ⇄ 字节，可失败可回显              │
│  └ ErrorTaxonomy    分类 + 可重试性 + 用户可读建议          │
├──────────────────────────────────────────────────────────┤
│ RemoteFileSystem 协议 / RemoteItem / RemoteCapabilities   │
├──────────────────────────────────────────────────────────┤
│ Backends（唯一链接 C 库的地方）                            │
│  ├ SFTPBackend   └ libssh2（C，xcframework）              │
│  └ FTPBackend    └ libcurl（C）                           │
├──────────────────────────────────────────────────────────┤
│ Infra                                                    │
│  Keychain │ ScopedBookmark │ Store(Codable JSON)          │
│  Logger(脱敏) │ HostKeyStore │ SecurityBaseline           │
└──────────────────────────────────────────────────────────┘

Core Package = 协议 + 模型 + 横切层 + Services  （零 C 依赖）
Backends Package = 两个后端 + C 依赖            （xcframework 的痛关在这里）
App Package = UI                                （依赖 Core）
```

**`Core` 零 C 依赖是硬约束**：单测可在任意平台跑、CI 快、无需处理 modulemap/CocoaPods 头文件地狱。libssh2 打包本身要花几天，隔离在一个 target 才能把成本关起来。

---

## 6. 关键模块设计

### 6.1 连接管理与并发策略

- **控制面与数据面分离**：每站点维护 1 条用于目录浏览、元数据 stat、心跳保活的控制面连接（`RemoteConnection`）。
- **SFTP 并发传输的真实物理约束与架构解法（v2.2 澄清）**：
  - **纠正协议误区**：SSH-2 协议规范（RFC 4254）原本就支持在单条连接上复用多个 Channel；OpenSSH 服务端默认限制是 `MaxSessions`（默认 10）。在同一 Session 上多次调用 `libssh2_sftp_init()` 是合法的工业界常规做法。
  - **真正的物理约束**：
    1. **句柄线程不安全**：`libssh2` 的 Session 句柄不支持多线程并发重入（Thread-safe: just do not share handles simultaneously），必须做串行化调度；
    2. **单核 CPU 加密瓶颈**：单条 TCP 连接上的 SSH 加密解密流由单核处理，单连接无法吃满万兆多核带宽；
    3. **TCP 窗口与 BDP 限制**：在高延迟长肥管道下，单通道的 SSH 窗口与分包大小会压制吞吐。
  - **并发架构选型**：
    - **主选方案（多 Session 连接池）**：控制面 1 条 Session，并发传输各开独立 Session。理由是**“并行多核加密与多 TCP 流跑满带宽”**（而非协议限制）。
    - **备选方案（单通道异步 Pipelining）**：单通道利用 `libssh2` 内部预读或并发 Flight 窗口发出读写请求，节省服务端 Session 资源。
- **Swift 协作线程池防饥饿（Thread Starvation Prevention）**：
  - 在 Swift `async` 函数中直接调用阻塞式的 `libssh2` C API，会长时间霸占 Swift 协作线程池（线程数约等于 CPU 核数）。并发传输极易造成**协作线程池饥饿**，导致 UI 响应假死与后台任务停滞。
  - **落地约束**：底层必须采用**非阻塞模式 + poll/select 循环**（在 poll 循环边界主动检查 `Task.checkCancellation()`，这也是取消在 200ms 内生效的最可靠保障）；或使用独立的底层串行 GCD 队列进行执行隔离。
- 心跳 `libssh2_keepalive_send()`，超时 `libssh2_session_set_timeout()`。
- 断线重连用指数退避（1s→2s→4s→最大 30s，带抖动），重连后恢复当前目录。
- 传输进行中不自动重连 —— 交给 `TransferQueue` 走续传逻辑，避免静默重试产生坏文件。

**App Nap 防护**：macOS 后台会节制定时器，导致心跳延迟、连接被系统挂断。存在活动连接时持 `ProcessInfo.beginActivity(.userInitiatedAllowingIdleSystemSleep)` token，最后一条连接关闭时释放。

### 6.2 传输队列

状态机（v2 增加 `paused` 的明确语义）：

```
pending ──► running ──► completed
   ▲          │  ▲          ▲
   │          ▼  │          │
   └──── paused  retryableError
              │  │
              ▼  ▼
        failed(可重试/不可重试分类)     cancelled ──► 清理 .part
```

- **暂停 ≠ 取消**：
  - `paused`：保留已传 offset 与临时分块文件；`disconnect()`；下次由队列重建连接并从 offset 续传。
  - `cancelled`：`abort()` 远端/本地句柄，**删除临时分块文件**，清理状态。
- **双向原子性保护（下载与上传）**：
  - **下载侧**：先写入本地 `<target>.part`，校验通过后**原子 rename** 到目标文件名。
  - **上传侧**：先上传至远端临时文件 `<target>.upload-part`，完成且校验通过后再执行远端原子重命名。
  - **原子覆盖语义**：SFTP v3 的原生 `SSH_FXP_RENAME` 默认不覆盖已存在文件，覆盖重命名需依赖 OpenSSH 扩展 `posix-rename@openssh.com`。
- **续传置信度校验**：
  1. 记录续传起点 `(size, mtime, mtimeIsReliable)`
  2. 传输完成后再取 `(size, mtime)`，与第 1 步比对
  3. 不一致 → 标记**低置信度完成**并主动告知（可配置自动重传）
  4. `mtimeIsReliable == false` 时（部分 FTP 服务器不返回 `MDTM`）→ 默认禁用续传上传；下载侧至少要求 size 精确匹配
- 并发：全局默认 3，按站点再限流。
- 文件夹传输先递归展开为文件任务再入队；**递归必须检查 `Task.checkCancellation()`**。
- 崩溃恢复：队列落 JSON，启动时把中断的 `running` 全部转为 `paused`，临时文件保留待用户确认续传（**不自动续传**，避免启动即传错）。

### 6.3 文件浏览

- 目录懒加载：先渲染缓存再刷新。缓存用 `LRU`，上限可配。
- 大目录分批追加（每批 ~500 项），配合 `NSOutlineView` 的 `reloadItems` 而非全量 `reloadData()`。
- **隐藏文件开关**：macOS 惯例默认隐藏点文件，但服务器上 `.env` / `.git` / `.htaccess` 是刚需 → 默认显示，附快捷键切换。
- `⌘⇧G` 前往路径 + 可编辑路径栏。
- 列排序 + 列头拖拽（AppKit 侧几乎免费）。

### 6.4 拖拽

| 源 → 目标 | 机制 | 备注 |
|---|---|---|
| 远端 → 本地面板 | 内部拖拽 | 建上传任务 |
| 本地 → 远端面板 | 内部拖拽 | 建下载任务 |
| Finder → 远端面板 | `NSFilePromiseProvider` + `NSFilePromiseReceiver` | 拖的是 promise，落下才下载 |
| 远端 → Finder | `NSFilePromiseProvider` | 拖的是 promise，落下才下载 |
| 远端 → 远端 | v1.1 | 纯协议层 `RemoteReader → RemoteWriter`，不落盘 |

必须早定的冲突策略：`N 个文件拖进已存在且同名的目录` → 业界默认"合并目录，文件按预设策略（默认询问）"。

### 6.5 外部编辑回传

- 下载到临时目录 → `NSWorkspace.open` → `FSEvents` 监听。
- **监控父目录而非单个文件句柄**：现代编辑器（VSCode / Sublime / TextEdit）在保存时普遍采用**原子保存**（先在同级父目录下写入随机临时文件，再通过 `rename` 系统调用覆盖目标）。若仅监听目标文件本身，在 `rename` 替换的微秒瞬间极易丢失文件句柄，甚至完全漏掉保存事件。因此监听器**必须挂载在临时文件所在的父目录**，并匹配目标文件名与 rename 相关 flags。
- **强制 500ms~1000ms 防抖（Debounce）**：编辑器在保存过程中通常会连续触发 3~5 次 FSEvents（写入 temp、修改元数据、原子 rename、清理缓存）。缺乏防抖机制会导致瞬间触发多次重复上传，甚至在临时文件未写完时上传空文件或截断文件。
- **默认不自动上传**，改为显式开关 + 明显的"正在监视"状态条 + 手动触发上传。
- 上传前比远端 mtime；若远端已变更 → **停下并询问**，不静默覆盖。

### 6.6 同步引擎：参考 git index 的三方快照与完备真值表

v1 盲目采用双向 rsync 导致冲突检测失效；v2.1 设想的“<64MB 默认哈希”在 SFTP v3（无远端哈希命令）下会导致全量下载瘫痪。

v2.2 采用**参考 git index 的快照判重机制与双侧独立 Stat 记录**：

#### 1. base 快照结构（双侧分别记录）
本地 APFS 具备纳秒级 mtime（`timespec`），远端 SFTP 通常为秒级精度（`time_t`）。上传后远端 mtime 绝不会与本地纳秒完全相等。因此 base 必须分别记录双侧 stat：
```swift
struct BaseEntry: Codable, Sendable {
    let rawPathBytes: [UInt8]
    let localStat: FileStatSnapshot   // 本地 size, mtime (纳秒), inode
    let remoteStat: FileStatSnapshot  // 远端 size, mtime (秒级), permissions
    let contentHash: String           // 上次同步确认时的 SHA-256
}
```

#### 2. 高性能判重策略（防全量下载）
1. **轻量比对**：比对当前 `local` 与 `base.localStat`，比对当前 `remote` 与 `base.remoteStat`。
2. **免哈希确认**：若两边的 `(size, mtime)` 分别与 base 快照一致且 `mtimeIsReliable == true`，**直接判定为无修改**，避免下载任何远端文件！
3. **内容核验**：仅当某侧 `(size, mtime)` 发生变化、或 `mtimeIsReliable == false` 时，才读取本地或下载可疑远端文件计算哈希二次确认。

#### 3. 完备三方比对真值表

| 本地状态 vs base | 远端状态 vs base | 内容比较 | 引擎动作 / 判定 | 说明 |
|---|---|---|---|---|
| 未修改 | 未修改 | — | **无变化** | 保持 |
| 已修改 | 未修改 | — | **单向上行** | 上传本地至远端 |
| 未修改 | 已修改 | — | **单向下行** | 下载远端至本地 |
| **已修改** | **已修改** | **相同**（`L == R != B`） | **一致性收敛** | **非冲突！** 双端做了相同改动，仅更新 base 快照 |
| **已修改** | **已修改** | **不同**（`L != R != B`） | **内容修改冲突** | 弹窗提供本地/远端/双份选择 |
| 未修改 | 已删除 | — | **本地待删除** | 需用户确认后删除本地 |
| 已删除 | 未修改 | — | **远端待删除** | 需用户确认后删除远端 |
| **已修改** | **已删除** | — | **「修改 vs 删除」冲突** | 必须人工确认 |
| **已删除** | **已修改** | — | **「删除 vs 修改」冲突** | 必须人工确认 |
| 两侧均新建 | 两侧均新建 | 相同 | **一致性收敛** | 仅记录入 base |
| 两侧均新建 | 两侧均新建 | 不同 | **「新建同名」冲突** | 需用户选择覆盖或重命名 |
| 类型互换 | 任意 | — | **「类型互换」冲突** | 如本地为同名文件夹而远端为文件 |

- **删除默认关闭**，开启要二次确认，且先出预览。
- 输出 `DiffPlan`（`[DiffEntry]`），用户确认后才生成 `TransferTask`。DiffPlan 可序列化为文件。

---

## 7. 实现约束与并发细节

### 7.1 并发模型与协作线程池防饥饿

| 路径 | 特征与后果 | 架构定性 |
|---|---|---|
| 阻塞 + 串行队列 | 阻塞 C 调用占用 Swift 协作线程，且一次阻塞读卡死全 Session | 否定 |
| 阻塞 + 多 Session 连接池 | 每个传输独立会话，但若在 `async` 函数中直接阻塞调用仍会占满协作线程池导致饥饿 | 需独立 GCD 串行 Executor 隔离 |
| **非阻塞 + poll 事件循环（推荐）** | 每个调用返回 `LIBSSH2_ERROR_EAGAIN` 时由 poll 调度，在循环边界检查 `Task.checkCancellation()` | **M0' Spike 核心目标**，高吞吐且 200ms 内可靠打断 |
| 单通道异步 Pipelining | 单 SFTP channel 内并行发送未确认读写请求（利用 libssh2 内部预读或滑动窗口） | M0' 备选对比验证 |

**Spike 验收标准（跑通即定库）**

1. **第一天（10分钟验证）**：在 `atmoz/sftp` 仿真环境下，对同一 Session 连续调用两次 `libssh2_sftp_init()`，实测 OpenSSH `MaxSessions` 表现。
2. **非阻塞事件循环与打断验证**：验证非阻塞 poll 模式，在网络传输过程中触发 `Task.cancel()`，能在 **200ms 内真正打断**底层轮询并释放资源。
3. **并发吞吐与连接池开销**：实测 3 个并发 Worker（连接池模式 vs Pipelining 模式）跑满局域网带宽的 CPU 与内存占用。
4. **1000 个 1KB 小文件**批量往返耗时与内存峰值。

> v1 说"用 1GB 文件跑基准"是反的：大文件对封装开销不敏感，1000 个小文件才暴露问题（每文件一次 round-trip 的延迟 + 每次刷新 UI 的开销）。

### 7.2 Core 零 C 依赖

`Core` 只放协议、模型、横切层、`SyncEngine`、`TransferQueue`，依赖纯 Foundation/Algorithms。libssh2 / libcurl 放 `Backends`（`binaryTarget`）。xcframework 打包的痛关在一个 target 里。

### 7.3 取消贯穿所有循环

`try Task.checkCancellation()` 必须出现在：传输 chunk 循环、**目录递归展开**、哈希计算、差异计算、chmod 批量应用中。最容易漏的是递归展开 —— 这是"点了取消没反应"的主要来源。

### 7.4 存储：MVP 全用 `Codable` + 原子写 JSON（Swift 6 actor）

v1 写"SwiftData 或 GRDB"，但传输历史是高频写入 + 复杂查询场景 —— SwiftData 在大量小写入上性能不可靠且早期 schema migration 很痛。

**v2.1 的反直觉建议：MVP 一个数据库都不用，且全面拥抱 Swift 6 actor。**

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

设计考量：
- **消灭 GCD 读写竞态**：最低目标定在 macOS 14，全面废除 `DispatchQueue` 封装。所有读写由 `actor` 域内序列化隔离执行，彻底避免写入原子替换瞬间的读写脱节与死锁风险，原生符合 Swift 6 严格并发（Strict Concurrency）。
- **全量读取场景**：传输历史在 MVP 唯一用途是"重启恢复未完成任务"和"看最近发生了什么"，**都是全量读取，不需要索引**。
- 每天几千条的量级 JSON 绰绰有余。
- 换来零迁移成本、零 schema 演进、可版本控制、可导出。

等真出现"按站点/时间/状态筛选"或"历史超 10 万条"，再上 GRDB —— 那时 schema 你已经清楚了。

`TransferQueue` 持久化同理（`[TransferTask]` Codable），但要注意：写盘频率要节流（状态变更时 500ms 防抖），否则长传输会高频小写。

### 7.5 UI 切法：不做中间同步层

v1 说"SwiftUI 做外壳，文件列表用 AppKit 包装"，措辞会诱导用 `NSViewRepresentable` 在中间做双向数据同步 —— 那是 bug 温床（`updateNSView` 的 diff、selection 回环、滚动位置丢失）。

**v2 的切法**：
- **文件列表 → 纯 AppKit**。用 `NSOutlineView`（多列版），不要同时上 `NSTableView`（前者是后者子集）。dataSource / delegate **直连 ViewModel**。
- **窗口框架 / 工具栏 / 传输队列面板 / 站点管理 / 设置 / 同步预览 → SwiftUI**（`@Observable` + `@State`）。
- 二者通过 `BrowserController`（`@MainActor`）交界。**数据流单向**：ViewModel 是唯一真相，两边都直接读它，无中间同步。

v1 结论对（不要用 SwiftUI `Table`），但理由应改为：它的短板不是性能，是**拖拽、多选、列排序、右键菜单、就地重命名、Quick Look 这些行为要么不提供、要么要手写还不一定对** —— 而这些正是文件管理器的工作量主体。

### 7.6 可观测性（v1 只有 `Logger`）

这类产品 90% 的 bug 是环境相关的（某服务器某参数）。M6 交付：

- **诊断报告一键导出**：连接参数（脱敏）+ libcurl/libssh2 verbose log + 每步耗时 + 最终错误码。这是最好的客服替代品。
- **日志分级 + 显式脱敏规则**：密码、私钥内容绝不落盘；用户名是否算 PII 需定规矩。
- **错误码 → 可读建议映射表**：`EHOSTUNREACH` → "检查网络/代理"；`EACCES` → "服务器权限不足，联系管理员"；`.undecodablePath` → "该文件名不是合法 UTF-8，已按服务器编码解释"。

---

## 8. 项目结构

```
SFTPClient/
├─ Packages/
│  ├─ Core/                        # 零 C 依赖，可独立单测
│  │  ├─ Protocol/                 # RemoteFileSystem / RemoteConnection / Factory
│  │  ├─ Model/                    # RemoteItem / RemotePath / Capabilities / VolumeInfo
│  │  ├─ CrossCutting/             # PathResolver / CharsetConverter / ErrorTaxonomy
│  │  ├─ Transfer/                 # TransferQueue / TransferTask / ResumePolicy / RetryPolicy
│  │  ├─ Sync/                     # SyncEngine / BaseSnapshot / DiffPlan / ConflictPolicy
│  │  └─ Connection/               # ConnectionManager / Heartbeat / Backoff
│  └─ Backends/                    # 唯一链接 C 库
│     ├─ SFTP/                     # libssh2 xcframework
│     └─ FTP/                      # libcurl
├─ App/
│  ├─ App/                         # 入口、窗口、菜单、签名配置
│  ├─ UI/
│  │  ├─ Browser/                  # NSOutlineView + BrowserController（纯 AppKit）
│  │  ├─ Shell/                    # 工具栏、路径栏（SwiftUI）
│  │  ├─ Queue/                    # 传输队列面板
│  │  ├─ Sites/                    # 站点管理 + .ssh/config 导入
│  │  └─ Sync/                     # 同步预览（diff 列表）
│  └─ Infra/
│     ├─ Keychain/                 # 注意 kSecAttrAccessibleAfterFirstUnlock
│     ├─ Store/                    # Codable + 原子写
│     ├─ ScopedBookmark/           # mode A→B 迁移预留
│     └─ HostKeyStore/             # known_hosts
├─ Spike/                          # M0' 技术验证，独立可删
├─ docs/
│  ├─ SecurityBaseline.md
│  ├─ SANDBOX-MIGRATION.md
│  └─ AlgorithmMatrix.md
└─ Tests/
   ├─ CoreTests/                   # 纯 Swift，秒级
   ├─ ContractTests/               # ★ 同一套跑两个 backend
   └─ IntegrationTests/            # Docker 真实服务
```

`Core` 与 `Backends` 分 Package 的直接收益：一个未来出 CLI（传输、rsync-like 批处理）只需依赖 `Core` + 一个后端，不带 UI。

---

## 9. 里程碑（v2.2 修正）

| 阶段 | 周期（全职） | 交付 | 出口标准 |
|---|---|---|---|
| **M0'** | **2~2.5 周** | **前置：`build-libssh2-openssl.sh` 打包 xcframework**；工程骨架；协议与模型；`PathResolver`（保留 wireBytes + 派生 NFC 键 + APFS 大小写碰撞拦截） + `CharsetConverter` + `ErrorTaxonomy`；**Spike 攻坚**（第 1 天 10 分钟在 `atmoz/sftp` 验证同一 Session 多次 `sftp_init()`；非阻塞 poll 循环与 200ms 取消打断；小文件吞吐）；OpenSSH 仿真环境；`SecurityBaseline.md`（固定 commit hash 与官方 Advisory 链接） | **Spike 验证非阻塞 poll 循环与 200ms 打断通过 → 架构定死**，写进 ADR |
| **M1'** | 2.5~3 周 | 连接与认证（密码/密钥/passphrase，libssh2+OpenSSL 原生解析 `openssh-key-v1`）；**`ssh-agent` 集成（支持 1Password / macOS 原生代理）**；目录列表；单文件上下传；**契约测试基座搭建（从 M1 伴随启动）**；算法白名单与弱算法开关；`App Nap` 防护；非沙盒路径访问走 `ScopedResource` | 能连上至少 3 个不同年代的真实/仿真服务器（含一个只支持 CBC/SHA1 的老设备） |
| **M2** | 2~3 周 | 双栏 UI（`NSOutlineView` + SwiftUI 混合切法）；站点管理 + **`.ssh/config` 导入**（解析并展示 ProxyJump 配置；实际跳转放 v1.1+）；复用 `~/.ssh/known_hosts`；Keychain；主机指纹；隐藏文件开关；`⌘⇧G` | 中文文件名 + 超长路径 + 特殊字符名三项手工用例通过 |
| **M3** | 3~4 周 | 传输队列（暂停/取消语义分离）；**双向原子性保护（下载 `.part` + 上传 `.upload-part` 原子 rename，posix-rename@openssh.com）**；进度与 ETA；重试分类；续传置信度双采样；崩溃恢复；取消贯穿递归；**读写句柄引用语义与原生缓冲复用（`read(into:)`）** | 杀进程重启后任务状态与临时文件一致；传输中点取消 200ms 内停 |
| **M4** | 2 周 | **左右互拖 + Finder 双向拖入**；冲突策略 UI；Quick Look；外部编辑回传（显式开关式 + **父目录监听 + 500~1000ms 防抖** + 冲突询问） | 拖拽矩阵 5 行全部可用 |
| **M5** | 2.5~3 周 | FTP/FTPS 后端（charset 协商，**引入 vsftpd / pure-ftpd / pyftpdlib 容器环境**）；**git index 机制同步引擎（双侧独立 stat + base 快照 + 免哈希快速判重 + 完备真值表）** | 双端修改相同内容自动收敛；双端冲突被正确识别并提示 |
| **M6** | 2 周 | **契约测试跑通两个 backend**；诊断报告导出；`docs/SANDBOX-MIGRATION.md`（含重新授权流程）；**Sparkle 自动更新集成**；公证打包；Beta | 同一套 `ContractTests` 全绿，两 backend 零特判 |

**周期核算说明**：
- **MVP（M0'~M3）**：9.5 ~ 12.5 周。
- **v1.0 全量（M0'~M6）**：**16 ~ 19.5 周**。
- **工期口径提示**：以上均为**专业工程师全职投入口径**。业余时间开发请按 **2 ~ 3 倍折算**（约需 32 ~ 50 周）。

---

## 10. 测试策略

### 10.1 后端契约测试（提前至 M1 启动）

**同一套 conformance suite 跑在 SFTP 和 FTP 两个 backend 上。**

从 **M1 起伴随搭建**（初期使用 SFTP 后端与内存 Fake），而不是拖到 M6：
- 路径规范化（`..`、尾部斜杠、大小写、wireBytes 保留与 NFC 派生键、软链成环）
- APFS 大小写碰撞拦截预检
- 空目录 / 大目录 / 深层嵌套
- 权限与 mtime 缺失时的降级（`mtimeIsReliable == false` 走二次核验）
- 大文件往返哈希一致与缓冲复用性能
- capability 声明与实际行为一致

### 10.2 Docker 环境

环境按阶段引入，避免前期范围过载：

| 服务 | 目的 | 引入阶段 |
|---|---|---|
| `atmoz/sftp` | SFTP 主测试环境（第 1 天验证同一 session 多 channel） | **M0'** |
| OpenSSH 官方镜像 | 对照组（行为可能与 atmoz 不同） | **M0'** |
| `vsftpd` | FTP 方言 A | **M5** |
| `pure-ftpd` | FTP 方言 B（行为与 vsftpd 差异明显） | **M5** |
| proftpd | FTP 方言 C（模块化特性差异） | **M5** |
| **pyftpdlib 改造 fixture** | 构造 GBK / Big5 文件名、畸形 `MDTM`、谎报 `FEAT` | **M5** |

### 10.3 单元与故障注入

- Core 单测：纯 Swift，秒级，`PathResolver` / `CharsetConverter` / `ResumePolicy` / `SyncEngine` 是重点。
- 传输队列：假 `RemoteFileSystem` 注入故障（中途断线、写失败、超时、磁盘满）验证状态机。
- 手工用例清单：中文文件名、超长路径、符号链接成环、权限不足、磁盘满、网络切换（WiFi ↔ 有线）、锁屏、休眠唤醒。

### 10.4 CI

macOS runner + Docker 容器，所有测试进 CI 自动化。

---

## 11. 风险清单

| # | 风险 | 影响 | 应对 |
|---|---|---|---|
| R1 | libssh2 异步并发模型与取消机制 | **架构级返工** | M0' spike 验证非阻塞 poll 循环与取消打断，量化多 Session 连接池开销；验收不过就切 Citadel |
| R2 | 上传续传在 FTP 上写坏文件 | **数据损坏** | 默认关闭，仅在 `negotiated` 确认后开启；写后校验 size |
| R3 | 同步引擎全量下载哈希导致卡死 | **功能不可用** | 参考 git index 机制：优先比对双侧 stat，一致直接判定未修改，避免全量下载 |
| R4 | 老服务器连不上（算法默认关闭） | 功能不可用 | `AlgorithmMatrix.md` + CBC/SHA1 支持 + 用户可见弱算法开关 |
| R5 | 编码转换有损与 Linux 同形文件冲突 | 路径永久损坏 | `RemotePath` 保留原生 wireBytes，仅派生 NFC 键；同形异码冲突时报警 |
| R6 | 取消不打断阻塞调用与线程池饥饿 | UI 假死与挂起 | 非阻塞 poll 循环边界检查取消，避免占用 Swift 协作线程池 |
| R7 | 沙盒迁移用户权限断裂 | 中等 | D1 预留 `ScopedBookmark`，设计升级沙盒时清晰的 `NSOpenPanel` 重新授权引导流程 |
| R8 | 依赖 CVE 无上游 release | 安全暴露 | 锁定固定 commit hash + `docs/SecurityBaseline.md` 跟踪官方 Advisory |
| R9 | FTP 方言兼容地狱 | M5 超期 | ≥3 方言 + pyftpdlib fixture；解耦至 M5 集中攻坚；必要时把 FTP 移出 MVP |
| R10 | APFS 大小写覆盖破坏 | 数据被覆写 | 下载与同步前执行大小写碰撞检测（Case Collision Detection），阻断并提示 |

---

## 12. 与前期版本的差异清单

| # | 前期版本 | v2.2 修订 | 纠偏原因 |
|---|---|---|---|
| 1 | 库选型放 M1 之后、用 1GB 文件跑基准 | **M0' spike 前置定库**，用 1000 个 1KB 文件跑基准 | 并发模型决定 Core 层写法；大文件对封装开销不敏感 |
| 2 | 无依赖安全核对 | §3 `SecurityBaseline.md` 锁定 commit hash + 官方 Advisory 链接 | 消除模糊编号，保证安全基线可溯源 |
| 3 | 只把"文件名编码"列为风险 | 编码升为**横切层**，路径用字节规范表示 | 非 UTF-8 转 String 会不可逆损坏 |
| 4 | 无大小写策略与碰撞预检 | 增加 APFS 大小写碰撞拦截检测 | APFS 不敏感，远端同时存在 `Foo.txt` 与 `foo.txt` 下载会发生静默覆盖 |
| 5 | 无 `PathResolver` | M1 交付，独立单测 | 两个后端共用，错则全盘错 |
| 6 | `path: String` | `RemotePath`（保留 wireBytes + 派生 NFC 键） | 强转 NFC 会把 Linux 上同形异码的两个合法文件错误折叠 |
| 7 | `RemoteItem` 未定义 | 完整定义 + `sizeIsExact` / `mtimeIsReliable` | 不可信 mtime 会导致静默丢数据 |
| 8 | 协议无 capability 协商 | `declared` + `negotiated` 两层 | 能力差异是结构性的；FTP `FEAT` 常谎报 |
| 9 | `read/write` 流式为 mutating 结构体 | 读写句柄定义为 `AnyObject & Sendable` 引用语义 + 原生缓冲复用 | mutating 句柄在并发取消时会触发 Swift 运行时独占访问违规 Crash |
| 10 | 阻塞 C 调用占用 Swift 并发线程 | 非阻塞模式 + poll 事件循环 | 避免霸占 Swift 协作线程池导致 UI 假死与线程饥饿 |
| 11 | 设想单 Session 无法开多个 SFTP 通道 | 纠正为 RFC 4254 真实语义：多 Session 连接池理由是**“多核并行加密与突破单 TCP 吞吐”** | OpenSSH 本身支持多 Session 复用，真正瓶颈在单核加解密与 BDP |
| 12 | 设想 libssh2 有 Apple 原生加密后端 | 澄清官方无 Apple Security.framework 后端，确定使用 OpenSSL 3.x 静态打包 | 避免虚假选型，OpenSSL 3.x 原生支持现代及历史全部算法 |
| 13 | Swift 层预先解密私钥转 PKCS#8 | 移除 Swift 冗余预转，由 libssh2+OpenSSL 直接原生解析 openssh-key-v1 | 避免明文私钥长时间滞留在 Swift 托管堆内存，缩小攻击面 |
| 14 | 同步引擎默认对 <64MB 文件算哈希 | **参考 git index 机制**：优先比对双侧独立 stat，避免全量下载 | SFTP v3 没有远端哈希命令，每次算哈希会导致网络全量下载瘫痪 |
| 15 | base 快照只存单一 mtime | base 分别记录本地纳秒 stat 与远端秒级 stat | APFS 与远端时间精度不同，单 mtime 必然误判 |
| 16 | 同步真值表缺失边缘情况 | 补全「双端同改一致性收敛」、「修改 vs 删除」、「类型互换」等完整状态 | 避免双端做了相同改动却误报冲突 |
| 17 | 上传中断未防范残缺文件 | 增加远端临时文件（`.upload-part`）与原子 rename | 保证上传侧与下载侧同样具备原子性 |
| 18 | 契约测试排在 M6 偏晚 | 提前至 **M1** 伴随核心开发启动 | 尽早构建测试屏障，防止核心抽象被破坏 |
| 19 | 依赖构建顺序倒置 | M0' 第一步前置编写 `build-libssh2-openssl.sh` 构建脚本 | 库先编译出来，后续 Spike 与原型才能执行 |
| 20 | 缺失生产级日常功能 | 明确纳入 `ssh-agent`、`keyboard-interactive` (2FA)、Sparkle 自动更新 | 满足日常团队高频使用要求 |
| 21 | 代码签名使用 `codesign --deep` | 逐层组件签名 + Hardened Runtime 公证 | 遵循苹果现代签名规范 |
| 22 | 沙盒升级“零迁移”夸大 | 明确模式 A 升级模式 B 必须经由用户重新授权 | Security-Scoped Bookmark 无法脱离用户交互静默创建 |
| 23 | 周期波浪线丢失与工期不符 | 纠正全职口径为 16 ~ 19.5 周（业余 32 ~ 50 周） | 修复排版，提供严谨的全职/业余工期折算 |

---

## 13. 立即可执行的下一步

1. **定 D1（分发模式）** —— 明确 Developer ID + Hardened Runtime，数据层按 `ScopedBookmark` 写。
2. **定 D2（首要目标用户）** —— 优先锁定“团队自用日常”（确定支持 `ssh-agent` 与 `.ssh/config` 导入）。
3. **启动 M0' 第一天任务**：
   - 执行 `Scripts/build-libssh2-openssl.sh` 编译 `libssh2.xcframework`；
   - 在 `atmoz/sftp` Docker 仿真环境下对同一 Session 连续调用两次 `libssh2_sftp_init()` 快速验证；
   - 验证非阻塞 poll 循环与 200ms 取消打断，敲定最终并发架构。