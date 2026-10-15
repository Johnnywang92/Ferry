# Mac SFTP/FTP 客户端开发方案 v2.1

> 本版基于 v2 架构审查与代码级审查修订。纠正了 SFTP 单 session 协议认知陷阱、Swift 6 并发缺陷、Crypto Backend 选型、Unicode 归一化与排期过载问题。主要变化见 §12 差异清单。
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

**规则澄清**：Developer ID 分发必须强制开启的是 **Hardened Runtime**（`-o runtime`，防代码注入、动态库劫持），但苹果**并未强制 Developer ID 应用开启 App Sandbox**（App Sandbox 仅对 Mac App Store 上架强制要求）。

**v2.1 的做法**：
- M0~M5 明确走模式 A：开启 Hardened Runtime（`codesign --deep -o runtime`），暂不启用 `com.apple.security.app-sandbox`。
- **但数据层从第一天就按模式 B 的要求写**：所有本地路径一律存为 `ScopedBookmark`（`path` + `bookmarkData?` 双字段），读写统一走 `ScopedResource` 封装。这样升模式 B 时只需补 `startAccessingSecurityScopedResource()`，无需任何数据迁移。
- 升模式 B 时的具体步骤写进 `docs/SANDBOX-MIGRATION.md`（M6 产出）。

```swift
struct ScopedBookmark: Codable, Hashable {
    let path: String
    var bookmarkData: Data?      // mode A 为 nil，mode B 补齐
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
| **A. 自用/团队日常**（传配置、代码） | 用 `~/.ssh`、大量小文件、几乎不用 FTP | `.ssh/config` 导入、隐藏文件、权限修改、`⌘⇧G`、错误提示质量 | FTP/FTPS 后端、拖拽 |
| **B. 通用客户端发布** | 陌生用户、混合文件、大文件多 | 拖拽双向、Quick Look、同步预览、诊断报告 | ProxyJump |
| **C. App Store 上架** | 审核合规优先 | 沙盒、无障碍、本地化 | 自定义算法白名单 |

**D2 未定前不要开始 M1** —— 它决定 M1 的算法兼容矩阵宽度和 `.ssh/config` 导入是否必须。

### 非阻塞的推荐默认值

| 项 | 推荐值 | 理由 |
|---|---|---|
| 最低 macOS | **14 (Sonoma)** | `@Observable` + `AsyncThrowingStream(unfolding:)`（拉取式背压）均可用；macOS 15 已普及，定 12/13 会引入大量条件编译 |
| SwiftData / GRDB | **都不用** | 见 §7.4，`Codable` + 原子写 JSON |
| 最低部署目标 | 非沙盒 Developer ID | 见 D1 |

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
| 获取方式 | **从 git main 构建 + vendor**，禁止用 Homebrew 的 1.11.1 |
| 必须修补的 CVE | **CVE-2025-15661**：SFTP 响应解析导致信息泄露 + DoS —— **直接命中本产品攻击面**（客户端持续解析远端 SFTP 响应） |
| 其他 | CVE-2026-7598（超长 username/password 整数溢出，上游 PR #1858）、CVE-2026-55200、CVE-2026-55199 |
| 打包 | 自建 xcframework（静态），仅由 `Backends` target 链接 |

**加密后端（Crypto Backend）与私钥解析选型（v2.1 关键明确）**：
`libssh2` 自身只负责 SSH 协议封包与通道状态机，底层加密算法与密钥解析完全委托给加密后端（Backend）。在 macOS 上打包 xcframework 时面临关键选型：
- **Apple 原生 `Security.framework`（OSStatus 后端）的缺陷**：对 OpenSSH 新格式私钥（`-----BEGIN OPENSSH PRIVATE KEY-----`，特别是带 bcrypt KDF 加密）**完全不支持**，且无法灵活按需开放老旧 KEX/算法白名单。
- **OpenSSL 3.x 静态打包方案（推荐）**：功能完备，原生支持现代算法及全部历史兼容算法。
  - **构建策略**：采用脚本自动化将 **libssh2 + OpenSSL 3.x 静态合并打包**为统一的 `libssh2.xcframework`（包含 macOS arm64/x86_64 胖二进制），符号全部内敛在 `Backends` target 中，杜绝与系统或上层符号污染。
  - **Swift 私钥解析前置兜底**：在 Swift Infra 层构建轻量 `SSHKeyParser`（结合 Apple `CryptoKit`），若遇到复杂私钥编码，可在 Swift 层先将 OpenSSH/PKCS#1 格式解密并转换为标准化 PKCS#8 DER 格式后再提交给 libssh2，彻底规避底层 C 库解析格式单一的短板。

**算法白名单（`M1` 交付物）**：libssh2 1.11 起默认不编译大量老算法。安全上是好事，但一批老服务器/嵌入式 NAS 会连不上。需显式配置：

| 类别 | 放开 | 保持关闭 |
|---|---|---|
| 主机密钥 | `ssh-rsa`、`ssh-dss`（老设备必需） | — |
| KEX | `diffie-hellman-group14-sha1`、`diffie-hellman-group1-sha1` | 弱 DH < 1024 |
| 加密/MAC | `aes128-ctr`、`aes256-cfb` | **RC4、3DES、arcfour、blowfish、cast128** |
| MAC | `hmac-sha1`、`hmac-sha2-256/512` | **md5、hmac-md5、ripemd160** |

实现方式：`libssh2_session_method_pref()` 逐项设置。**UI 必须暴露"允许弱算法"开关**，因为放开弱算法是一个需要用户知情的安全决策。

### 3.2 SwiftNIO SSH（仅当选 Citadel）

- **CVE-2026-43798：Swift-NIO-SSH 栈写入导致代码执行，修复版本 0.14.1**（Apple advisory GHSA-998x-vgv…）。必须 `>= 0.14.1`。
- 主要影响暴露 SSH 服务端的应用；作为客户端远程可利用性有限，但它说明 NIO SSH 的安全响应节奏需长期跟踪 —— 这对一个要维护多年的客户端是持续成本。
- Citadel 上游活跃度需在选型前实际查看提交历史，不能凭印象。

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
1. **无背压控制**，生产者可无限缓冲 → 大文件内存爆炸。
2. **取消不打断底层**：Task 取消只是停止消费，阻塞在 `libssh2_sftp_read()` 的 C 调用继续跑 → UI 显示已取消，网络仍在传。

v2 用句柄 + 显式 chunk 循环：

```swift
protocol RemoteReader: Sendable {
    var totalSize: Int64? { get }
    mutating func readChunk(maxBytes: Int) async throws -> Data?   // nil = EOF
    func cancel() async                                            // 打断底层阻塞调用
}

protocol RemoteWriter: Sendable {
    @discardableResult
    mutating func writeChunk(_ data: Data) async throws -> Int       // 返回实际写入数，供续传校验
    func commit() async throws
    func abort() async                                              // 释放远端句柄，.part 由调用方决定存废
}
```

调用方循环：

```swift
var reader = try await fs.openRead(path)
while let chunk = try await reader.readChunk(maxBytes: 256 * 1024) {
    try Task.checkCancellation()          // 循环内必须检查，否则大文件取消无响应
    try await localWriter.write(chunk)
    await progress(.advance(by: chunk.count))
}
```

收益：
- **天然背压**：拉不到就不产，不需要 buffering policy。
- **取消点明确**：每 chunk 一次检查，响应在 256KB 之内。
- **进度/限速/暂停**都有统一挂载点。
- `writeChunk` 返回实际写入数 → 续传偏移量精确，不靠累加估算。

代价：chunk 循环样板代码。用一个内部 helper `TransferEngine.pump(...)` 收敛，协议层保持笨拙是对的。

**大文件传输的内存压迫与 Buffer 复用（v2.1 性能约束）**：
在千兆/万兆高带宽网络下，`while let chunk = try await reader.readChunk(maxBytes: 256 * 1024)` 若每次循环都动态分配新的 256KB `Data` 对象，每秒会产生数千次堆内存分配（Heap Allocation），在 Swift 异步运行时（Task context）下极易引发严重的内存碎片与内存高水位峰值（Memory Footprint Spikes）。
- **解法**：在 `TransferEngine.pump` 内部实现定长双缓冲池或循环复用的 `ByteBuffer`（结合 `ContiguousArray<UInt8>` 或预分配 UnsafeBufferPointer），读取时向固定槽位填充，写入消费后立即复用该槽位，避免传输路径上的高频 malloc/free。

### 4.5 路径与编码：v1 完全缺失的两个横切层

v1 的 `path: String` 一路到底，有三个躲不掉的坑。

**坑一 · 大小写敏感性**
macOS APFS 默认**不区分大小写**，Linux 服务器**区分**。所以本地 `/Users/x/Foo.txt` 与远端 `/home/x/foo.txt` 在同步对齐时指向同一个本地文件但不同远端文件 → 产生"本地看起来只删了一个大小写不同的文件"这类极难解释的行为。

**坑二 · 非 UTF-8 文件名不可逆损坏**
若远端返回的字节序列不是合法 UTF-8，转成 Swift `String` 时会插入替换符 `U+FFFD`。**此时路径已永久损坏**，后续所有 rename / stat 都作用在错误路径上。而老 FTP 服务器的 GBK/Big5 是真实存在的。

**坑三 · APFS 与 Unicode 归一化（NFC vs NFD，v2.1 关键新增）**
- macOS HFS+ 历史强推 **NFD**（Decomposed，拆分声调与字符），APFS 虽声称 Normalization-Preserving，但大量 macOS 系统级框架 API（如 `FileManager`、`URL`）返回的路径依然倾向于 NFD；而 Linux 服务器（ext4/xfs）上的文件名绝大多数是 UTF-8 **NFC**（Precomposed）。
- 若直接比对两端的原始字节（`rawBytes`），同一个含声调字母（如 `é`）或日韩汉字在两端会被计算出完全不同的字节哈希键，导致 `SyncEngine` 跨端三方对比永远显示"已修改/假冲突"！
- **解法**：`PathResolver` 在跨端索引、比较与差异对齐时，**强制统一按 Unicode NFC 标准规范化**（使用 `precomposedStringWithCanonicalMapping` / ICU 算法），生成规范的比对键；仅在发往远端时保留其原生编码。

v2 的解法：路径的规范表示是字节，不是 String。

```swift
struct RemotePath: Hashable, Comparable {
    let rawBytes: [UInt8]              // 规范表示；直接可 Hash/Equatable，供 SyncEngine 对齐
    let components: [Component]
    let isAbsolute: Bool
    let casePolicy: CasePolicy         // .sensitive / .insensitive —— 由连接配置声明

    var encodedKey: String { rawBytes.map { String(format: "%02x", $0) }.joined() }

    /// 仅用于展示与 UI 边界。非法序列以 \xNN 呈现，不做有损替换。
    func displayString(using decoder: CharsetDecoder) -> String

    /// 发往服务器的字节（按协商 charset 编码）
    func wireBytes(using encoder: CharsetEncoder) throws -> [UInt8]
}
```

`rawBytes` 是 `[UInt8]` 而非 String 的额外好处：SyncEngine 的路径对齐、diff、去重的键比较天然按字节进行，配合 NFC 规范化后，不需要反复做复杂的编码猜测。

`PathResolver` 负责：POSIX 根、`~` 展开、`.` / `..` 回退（不越过根）、空路径、重复分隔符、尾部 `/` 归一、**Unicode NFC 规范化**、软链展开深度上限（防环）。**M1 交付物，且必须有独立单测** —— 两个后端共用它，出错就是全盘错。

### 4.6 错误分类（v1 缺失）

```swift
enum RemoteError: Error {
    case network(NetworkKind)                      // retryable
    case auth(AuthFailure)                         // 不 retry：密码错 / 密钥拒
    case hostKeyMismatch(fingerprint: String)       // 强警告，必须人工确认
    case permissionDenied(path: RemotePath)        // 不 retry
    case notFound(path: RemotePath)                // 不 retry，但 SyncEngine 需区分于 network
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

> 这与记忆里 iOS 端 llama.cpp 那条经验同源：**把不同成因的错误用同一句文案呈现，会诱导用户做完全错误的操作**（比如让人重下 1GB 模型，而真因只是依赖没链接）。

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
- **SFTP 并发传输的协议限制与架构解法（v2.1 关键纠偏）**：
  - **协议认知陷阱**：在 SSH-2 协议规范（RFC 4254）与标准 OpenSSH `sshd` 实现中，**单个 SSH Session 默认只允许打开一个 `subsystem sftp` 逻辑通道（Channel）**。若在同一 Session 上再次调用 `libssh2_sftp_init()` 开第二个通道，服务端会直接拒绝（`SSH_MSG_CHANNEL_OPEN_FAILURE`）或挂断。
  - **并发实现双轨方案（由 M0' Spike 实际验证定死）**：
    1. **方案 A（多 Session 连接池，主选推荐）**：控制面 1 条 Session，并发传输 Worker 各开独立 SSH Session。构建轻量会话池与握手复用策略，需在 Spike 中实测各大服务端对 `MaxStartups` / `MaxSessions` 的容忍度。
    2. **方案 B（单通道异步 Pipelining 流水线）**：单个 SFTP 通道内不等上一块 ACK 即连续发出多个 `SSH_FXP_READ` / `SSH_FXP_WRITE` 请求窗口（In-flight 飞行请求）。这是高延时宽带跑满的核心技术，需在 Spike 验证 libssh2 非阻塞 API 的复杂度与支持度。
- 心跳 `libssh2_keepalive_send()`，超时 `libssh2_session_set_timeout()`。
- 断线重连用指数退避（1s→2s→4s→最大 30s，带抖动），重连后恢复当前目录。
- 传输进行中不自动重连 —— 交给 `TransferQueue` 走续传逻辑，避免静默重试产生坏文件。

**App Nap 防护**：macOS 后台会节制定时器，导致心跳延迟、连接被系统挂断。存在活动连接时持 `ProcessInfo.beginActivity(.userInitiatedAllowingIdleSystemSleep)` token，最后一条连接关闭时释放。（v1 完全没提，踩了会很隐蔽。）

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
  - `paused`：保留 `.part` + 已传 offset；`disconnect()`；下次由队列重建连接并从 offset 续传。
  - `cancelled`：`abort()` 远端句柄，**删除 `.part`**，清理状态。
  - v1 没区分这两者，实践中必然出现"暂停后临时文件被删"的 bug。
- **`.part` 原子性**：下载中写 `<target>.part`，校验通过后**原子 rename** 到目标名。中断留下的 `.part` 绝不能出现在用户目标目录里被误当完整文件。
- **续传置信度校验**（v1 的"校验大小或修改时间"不够）：
  1. 记录续传起点 `(size, mtime, mtimeIsReliable)`
  2. 传输完成后再取 `(size, mtime)`，与第 1 步比对
  3. 不一致 → 标记**低置信度完成**并主动告知（可配置自动重传）
  4. `mtimeIsReliable == false` 时（部分 FTP 服务器不返回 `MDTM`）→ 默认禁用续传上传；下载侧至少要求 size 精确匹配

  原因：SFTP mtime 可能只有秒级，部分嵌入式 NAS 更差；只比 mtime 无法区分"没变"和"同秒内被改过"。
- 并发：全局默认 3，按站点再限流。上传续传因 `APPE` 不可靠而默认关闭。
- 文件夹传输先递归展开为文件任务再入队；**递归必须检查 `Task.checkCancellation()`** —— 10 万文件的目录递归会让取消按钮毫无反应。
- 崩溃恢复：队列落 JSON，启动时把中断的 `running` 全部转为 `paused`，`.part` 保留待用户确认续传（**不自动续传**，避免启动即传错）。

### 6.3 文件浏览

- 目录懒加载：先渲染缓存再刷新。缓存用 `LRU`，上限可配。
- 大目录分批追加（每批 ~500 项），配合 `NSOutlineView` 的 `reloadItems` 而非全量 `reloadData()`。
- **隐藏文件开关**：macOS 惯例默认隐藏点文件，但服务器上 `.env` / `.git` / `.htaccess` 是刚需 → 默认显示，附快捷键切换。
- `⌘⇧G` 前往路径 + 可编辑路径栏。
- 列排序 + 列头拖拽（AppKit 侧几乎免费）。

### 6.4 拖拽（v1 只写了一半）

v1 只写了"拖出到 Finder 用 `NSFilePromiseProvider`"，漏了双栏的定义性交互 —— 左右互拖。完整矩阵：

| 源 → 目标 | 机制 | 备注 |
|---|---|---|
| 远端 → 本地面板 | 内部拖拽 | 建上传任务 |
| 本地 → 远端面板 | 内部拖拽 | 建下载任务 |
| Finder → 远端面板 | `NSFilePromiseProvider` + `NSFilePromiseReceiver` | 拖的是 promise，落下才下载 |
| 远端 → Finder | `NSFilePromiseProvider` | 拖的是 promise，落下才下载 |
| 远端 → 远端 | v1.1 | 纯协议层 `RemoteReader → RemoteWriter`，不落盘 |

**必须早定的冲突策略**，否则 UI 逻辑反复改：`N 个文件拖进已存在且同名的目录` → 合并目录 / 覆盖 / 跳过 / 全部重命名？业界默认"合并目录，文件按预设策略（默认询问）"。

建议拆成独立里程碑（M4），不要和 Quick Look、外部编辑挤在一起。

### 6.5 外部编辑回传

- 下载到临时目录 → `NSWorkspace.open` → `FSEvents` 监听。
- **监控父目录而非单个文件句柄**：现代编辑器（VSCode / Sublime / TextEdit）在保存时普遍采用**原子保存**（先在同级父目录下写入随机临时文件，再通过 `rename` 系统调用覆盖目标）。若仅监听目标文件本身，在 `rename` 替换的微秒瞬间极易丢失文件句柄，甚至完全漏掉保存事件。因此监听器**必须挂载在临时文件所在的父目录**，并匹配目标文件名与 rename 相关 flags。
- **强制 500ms~1000ms 防抖（Debounce）**：编辑器在保存过程中通常会连续触发 3~5 次 FSEvents（写入 temp、修改元数据、原子 rename、清理缓存）。缺乏防抖机制会导致瞬间触发多次重复上传，甚至在临时文件未写完时上传空文件或截断文件。
- **默认不自动上传**，改为显式开关 + 明显的"正在监视"状态条 + 手动触发上传。
- 上传前比远端 mtime；若远端已变更 → **停下并询问**，不静默覆盖（v1 未定义冲突时的行为）。

### 6.6 同步引擎（v2 重写）

v1 写的是"两侧递归扫描，按相对路径对齐" —— 那是双向 rsync，不是同步，防不住最重要的双端同时修改。v2 引入 **base 快照**：

```
base   （上次同步后双方一致的快照，存本地）
local  （当前本地）
remote （当前远端）

local == base && remote == base   → 无变化
local != base && remote == base   → 单向上行
local == base && remote != base   → 单向下行
local != base && remote != base   → 冲突
```

`base` 只存 `(相对路径字节键, size, mtime, mtimeIsReliable, 可选哈希)`，成本很低，但它是"冲突"这个概念能存在的前提。

**判重策略分三档**（v1 是"默认 size+mtime，可选哈希"，粒度太粗）：

| 档 | 条件 | 依据 |
|---|---|---|
| 哈希（默认） | 文件 < 阈值（建议 64MB）且可读 | 正确性优先 —— 本产品用户传的是代码和配置，误判"没变化"会静默丢改动 |
| size + mtime | 大文件 / 大量文件 | 快，但接受 mtime 精度风险，UI 标注置信度 |
| 强制哈希 / 标记低置信度 | FTP 且 `mtimeIsReliable == false` | 同步前要求人工确认 |

- `Hash` 比较用 `(相对路径字节键, size)` 做主键索引，避免 O(n²)。
- **删除默认关闭**，开启要二次确认，且先出预览。
- 冲突不自动解决：一律写入预览列表，用户选择「以本地为准 / 以远端为准 / 保留双份」。
- 输出 `DiffPlan`（`[DiffEntry]`），用户确认后才生成 `TransferTask`。**DiffPlan 可序列化为文件，便于复核与分享**。

---

## 7. v2 新增的实现约束

### 7.1 并发模型：M0' spike 的唯一目的

在 SSH-2 规范（RFC 4254）与标准 OpenSSH 服务端实现中，**单个 SSH Session 默认只允许开启一个 SFTP 子系统逻辑通道**。因此"并发传输"在底层必须面对真实的协议路径权衡：

| 路径 | 后果 |
|---|---|
| 阻塞 + 串行队列 | 最简单，但一次阻塞 read 卡住整个 session → **实际并发 = 1** |
| 阻塞 + 多 Session 连接池 | 可靠，每个传输开独立 Session；需连接池复用，受服务端 `MaxStartups`/`MaxSessions` 约束 |
| 单通道异步 Pipelining | 单个 SFTP 通道内，不等上一个包 ACK 即发出一组未确认读写请求窗口；技术门槛高，但极其节省 Session 资源 |
| 非阻塞 + 自建 event loop | 配合连接池，每个调用可能返回 `LIBSSH2_ERROR_EAGAIN`，需 `libssh2_session_block_directions()` + `poll()` 后重试 |

> 这条差异比"集成省事 vs 吞吐"大得多，**它决定 Core 层所有代码的写法**，也决定 libssh2 vs Citadel 怎么选（NIO 帮你写好了这一层）。

**Spike 验收标准（跑通即定库）**

1. **并发吞吐方案求证（二选一跑通）**：
   - **方案 A（多 Session 连接池，主选）**：控制面 1 session + 3 个并发传输独立 session，跑满本地/局域网带宽，验证连接池复用平滑度与服务端 `MaxStartups` 容忍度。
   - **方案 B（单通道异步 Pipelining）**：在单个 SFTP channel 内验证 libssh2 是否能支持 In-flight 飞行请求流水线跑满带宽。
2. `Task.cancel()` 能在 **200ms 内真正打断**阻塞在 libssh2 里的调用（不只是 Swift 层取消）。
   - 阻塞模式下的可行手段：另一线程 shutdown socket（代价：同 session 所有通道一起失败，正好量化这个代价）；或 `libssh2_session_set_abort_fn()`（**需在 spike 中确认当前 main 分支可用性**，不要预设存在）。
3. **1000 个 1KB 小文件**批量往返耗时与内存峰值。

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

## 9. 里程碑（v2.1 修正）

| 阶段 | 周期 | 交付 | 出口标准 |
|---|---|---|---|
| **M0'** | **2~2.5 周**（**上调与聚焦**） | 工程骨架；`RemoteFileSystem` 协议（含 `RemoteItem` 完整定义 + capability）；`PathResolver`（含大小写策略 + **Unicode NFC 归一化**） + `CharsetConverter` + `ErrorTaxonomy`；**libssh2 异步 Spike（多 Session 连接池 vs 单通道 Pipelining、打断机制、小文件基准）**；OpenSSH / atmoz SFTP 仿真环境；非沙盒 Hardened Runtime 签名跑通；`SecurityBaseline.md` 与 Crypto Backend 验证 | **spike 两套并发方案之一跑通 + 取消打断通过 → 库定死**，写进 ADR |
| **M1'** | 2.5~3 周 | 连接；认证（密码 / 密钥 / **passphrase 回调 / OpenSSH 新格式私钥**，libssh2 + OpenSSL 静态 xcframework 打包与 Swift 层前置解析）；目录列表；单文件上下传；**`AlgorithmMatrix.md`**；`App Nap` 防护；非沙盒路径访问走 `ScopedResource` | 能连上至少 3 个不同年代的真实/仿真服务器（含一个只支持 `ssh-rsa` 的老设备） |
| **M2** | 2~3 周 | 双栏 UI（`NSOutlineView` + SwiftUI 混合切法）；站点管理 + **`.ssh/config` 导入**（`Host/HostName/Port/User/IdentityFile/ProxyJump`）；Keychain；主机指纹；隐藏文件开关；`⌘⇧G` | 中文文件名 + 超长路径 + 特殊字符名三项手工用例通过 |
| **M3** | 3~4 周 | 传输队列（暂停/取消语义分离）；进度 + ETA；重试分类；**`.part` + 原子 rename + 续传置信度校验**；崩溃恢复；限速；取消贯穿递归；**Buffer 复用避免内存高水位** | 杀进程重启后任务状态与 `.part` 一致；传输中点取消 200ms 内停 |
| **M4** | 2 周 | **左右互拖 + Finder 双向拖入**；冲突策略 UI；Quick Look；外部编辑回传（显式开关式 + **父目录监听 + 500~1000ms 防抖** + 冲突询问） | 拖拽矩阵 5 行全部可用 |
| **M5** | 2.5~3 周 | FTP/FTPS 后端（charset 协商，**引入 vsftpd / pure-ftpd / pyftpdlib 容器环境**）；同步引擎（**base 快照 + 三方比较 + 三档判重 + 冲突列表**） | 双端同时修改同一文件被正确识别为冲突而非静默覆盖 |
| **M6** | 2 周 | **契约测试跑通两个 backend**；诊断报告导出；`SANDBOX-MIGRATION.md`；崩溃恢复验证；公证打包；Beta | 同一套 `ContractTests` 全绿，两 backend 零特判 |

**合计 16~18.5 周**（v1 估 11~12 周，v2 估 15~17.5 周）。M0' 放宽至 2~2.5 周，确保彻底吃透 libssh2 异步并发模型与连接池开销；FTP 多方言 Docker 容器解耦后移至 M5 随 FTP 模块开发，避免前期范围严重过载。

**若要砍：砍内置终端和 ProxyJump（挪 v1.1+）。不要砍 M0' spike 和 M3 的续传置信度校验** —— 这两块是返工成本最高的。

---

## 10. 测试策略

### 10.1 后端契约测试（v2 新增，最高优先级）

**同一套 conformance suite 跑在 SFTP 和 FTP 两个 backend 上。**

不做这件事，"UI 和 Service 不知道具体协议"这个好抽象会在三个月内因为"FTP 少个功能，我加个 if"而破掉。

覆盖：
- 路径规范化（`..`、尾部斜杠、大小写、非 ASCII、软链成环）
- 空目录 / 大目录 / 深层嵌套
- 文件名冲突与特殊字符（`:`、`/`、`*`、控制字符、超长名）
- 权限与 mtime 缺失时的降级（`mtimeIsReliable == false` 走哈希）
- 大文件往返哈希一致
- capability 声明与实际行为一致（声明了但不支持 → 契约失败）

### 10.2 Docker 环境

v1 只提了 `atmoz/sftp`，不够。为防 M0' 严重过载，环境按阶段引入：M0' 优先准备 SFTP 对照环境，M5 引入 FTP 多方言测试环境：

| 服务 | 目的 | 引入阶段 |
|---|---|---|
| `atmoz/sftp` | SFTP 主测试环境 | **M0'** |
| OpenSSH 官方镜像 | 对照组（行为可能与 atmoz 不同） | **M0'** |
| `vsftpd` | FTP 方言 A | **M5** |
| `pure-ftpd` | FTP 方言 B（行为与 vsftpd 差异明显） | **M5** |
| proftpd | FTP 方言 C（模块化特性差异） | **M5** |
| **pyftpdlib 改造 fixture** | 构造 GBK / Big5 文件名、畸形 `MDTM`、谎报 `FEAT` —— 这类 bug 不可能靠真实服务器碰运气碰到 | **M5** |

**FTP 的行为差异大到必须多方言测试**，解耦至 M5 集中攻坚是保障主线节奏的关键。

### 10.3 单元与故障注入

- Core 单测：纯 Swift，秒级，`PathResolver` / `CharsetConverter` / `ResumePolicy` / `SyncEngine` 是重点。
- 传输队列：假 `RemoteFileSystem` 注入故障（中途断线、写失败、超时、磁盘满）验证状态机。
- 手工用例清单：中文文件名、超长路径、符号链接成环、权限不足、磁盘满、**网络切换（WiFi ↔ 有线）**、锁屏、休眠唤醒。

### 10.4 CI

上述全部跑在 CI 上（macOS runner + Docker 服务容器）。本地绿不算绿。

---

## 11. 风险清单

| # | 风险 | 影响 | 应对 |
|---|---|---|---|
| R1 | SFTP 协议单通道限制与并发架构选型 | **架构级返工** | M0' spike 前置验证多 Session 连接池 vs 单通道 Pipelining，量化连接池与服务端 `MaxStartups` 限制；验收不过就切 Citadel |
| R2 | 上传续传在 FTP 上写坏文件 | **数据损坏** | 默认关闭，仅在 `negotiated` 确认后开启；写后校验 size |
| R3 | 同步引擎误判导致静默丢数据 | **数据丢失** | 默认哈希判重；冲突绝不自动解决 |
| R4 | 老服务器连不上（算法默认关闭） | 功能不可用 | `AlgorithmMatrix.md` + 用户可见弱算法开关 |
| R5 | 编码转换有损 | 路径永久损坏 | `RemotePath` 字节规范表示 + 无法解码时走十六进制视图 |
| R6 | 取消不打断阻塞调用 | "点了取消还在传" | spike 验收项 2；句柄 `cancel()` + chunk 循环检查 |
| R7 | 沙盒迁移成本 | 中等 | D1 决策 + `ScopedBookmark` 预留，M0 起执行 |
| R8 | 依赖 CVE 无上游 release | 安全暴露 | vendor main 分支 + `SecurityBaseline.md` 跟踪 |
| R9 | FTP 方言兼容地狱 | M5 超期 | ≥3 方言 + pyftpdlib fixture；解耦至 M5 集中攻坚；必要时把 FTP 移出 MVP |
| R10 | 传输历史 JSON 随时间变大 | 启动变慢 | 阈值裁剪（保留最近 N 条 + 未完成任务）；超阈值才迁 GRDB |
| R11 | OpenSSH 新私钥与 Crypto Backend 兼容性 | 认证失败 | 明确采用 OpenSSL 3.x 静态合并打包 xcframework，并在 Swift 层做 PKCS#8 预处理兜底 |
| R12 | macOS NFD 与 Linux NFC 编码差异 | 跨端比对假冲突 | `PathResolver` 跨端比较与差异计算前统一强制执行 Unicode NFC 规范化 |

---

## 12. 与 v1 的差异清单

| # | v1 | v2 | 原因 |
|---|---|---|---|
| 1 | 库选型放 M1 之后、用 1GB 文件跑基准 | **M0' spike 前置定库**，用 1000 个 1KB 文件跑基准 | 并发模型决定 Core 层写法；大文件对封装开销不敏感 |
| 2 | 无依赖安全核对 | §3 `SecurityBaseline.md` + CVE 清单 + 算法白名单 | CVE-2025-15661 直接命中攻击面 |
| 3 | 只把"文件名编码"列为风险 | 编码升为**横切层**，路径用字节规范表示 | 非 UTF-8 转 String 会不可逆损坏 |
| 4 | 无大小写策略 | `RemotePath.casePolicy` + SyncEngine 以远端为准 | APFS 不敏感 vs Linux 敏感 |
| 5 | 无 `PathResolver` | M1 交付，独立单测 | 两个后端共用，错则全盘错 |
| 6 | `path: String` | `RemotePath`（字节规范 + 编码策略） | 同上 |
| 7 | `RemoteItem` 未定义 | 完整定义 + **`sizeIsExact` / `mtimeIsReliable`** | 不可信 mtime 会导致静默丢数据 |
| 8 | 协议无 capability 协商 | `declared` + `negotiated` 两层 | 能力差异是结构性的；FTP `FEAT` 常谎报 |
| 9 | `read/write` 流式 | 句柄 + chunk 语义 | 无背压 + 取消不打断底层 |
| 10 | 无错误分类 | `RemoteError` 分类 + `isRetryable` | 不同成因用同一文案会诱导错误操作 |
| 11 | 协议含 `connect/disconnect` | 拆出 `RemoteConnection` | 生命周期与能力分离 |
| 12 | 暂停/取消未区分 | 语义分离 + `.part` 存废策略不同 | 否则"暂停后临时文件被删" |
| 13 | 续传只比 size/mtime | 起点-终点双采样 + 低置信度提示 | 同秒修改无法区分 |
| 14 | `.part` 未提原子 rename | 强制原子 rename | 中断的 `.part` 不能出现在目标目录 |
| 15 | SyncEngine = 双向 rsync | **base 快照 + 三方比较 + 三档判重** | 防不住双端同时修改 |
| 16 | 拖拽只写拖出 | 完整 5 行拖拽矩阵 | 左右互拖是双栏定义性交互 |
| 17 | 无大小写/编码横切层 | `CharsetConverter` + `ErrorTaxonomy` | — |
| 18 | SwiftData / GRDB | **`Codable` + 原子写 JSON** | MVP 全量读取场景，DB 是过度设计 |
| 19 | "SwiftUI 做外壳 + AppKit 包装" | 文件列表纯 AppKit 直连 ViewModel | 避免 `NSViewRepresentable` 同步层 |
| 20 | 无契约测试 | **同一套跑两个 backend** | 抽象不腐化的唯一保障 |
| 21 | Docker 仅 `atmoz/sftp` | SFTP + 3 个 FTP 方言 + pyftpdlib fixture | FTP 差异必须多方言测 |
| 22 | 无 CI | 全部进 CI | 本地绿不算绿 |
| 23 | 未提 App Nap | `beginActivity(.userInitiated…)` | 后台节流导致心跳延迟/连接挂断 |
| 24 | 未提 App Nap | Keychain `AfterFirstUnlock` | 默认值会让锁屏后传输中断 |
| 25 | 未提原子保存 | FSEvents 监听 rename 类事件 | 现代编辑器写 tmp + rename |
| 26 | 自动上传回传 | 默认显式开关 + 冲突询问 | 防覆盖他人改动 |
| 27 | 分发/沙盒理解错误 | D1 决策 + `ScopedBookmark` 预留 | Developer ID 默认也有沙盒 |
| 28 | 未提 `.ssh/config` 导入 | 进 M2 | 成本极低，决定产品定位 |
| 29 | 外部编辑回传未定冲突行为 | 停下询问，不静默覆盖 | — |
| 30 | 周期 11~12 周 | **16~18.5 周** | 充实 M0' 为 2~2.5 周，留足 spike 与连接池验证时间；FTP Docker 矩阵解耦至 M5 |
| 31 | 设想单 Session 多 SFTP 通道 | 纠正为 RFC 4254 真实语义：多 Session 连接池 vs 单通道 Pipelining | OpenSSH 会拒绝同一 Session 开启第二个 SFTP 通道 |
| 32 | libssh2 加密后端与私钥解析模糊 | 静态打包 OpenSSL 3.x 至 xcframework + Swift 密钥预处理 | 避开 Apple Security.framework 不支持 OpenSSH 新私钥的致命缺陷 |
| 33 | Swift 伪代码并发与语法缺陷 | 修复 `ScopedResource` 属性与 Sendable；`Store` 改为 `actor`；修复 `RemoteError` pattern match | 满足 Swift 6 严格并发与编译器类型安全检查 |
| 34 | 遗漏 Unicode 规范化 | `PathResolver` 引入 **Unicode NFC 归一化** | 消除 macOS NFD 与 Linux NFC 导致的跨端文件名比对假冲突 |
| 35 | 外部编辑监听易丢事件 | 监听父目录 + 500~1000ms 防抖 | 防范编辑器原子保存（temp+rename）丢失句柄或上传截断空文件 |
| 36 | 高带宽下频繁分配 Data | `TransferEngine.pump` 引入双缓冲池与 `ByteBuffer` 复用 | 避免每秒数千次 malloc 产生严重内存高水位与堆碎片 |

---

## 13. 立即可执行的下一步

1. **定 D1（分发模式）** —— 明确 Developer ID + 非沙盒（Hardened Runtime），数据层按 `ScopedBookmark` 写。
2. **定 D2（首要用户）** —— 决定 M1 的算法矩阵宽度和 `.ssh/config` 是否必须。
3. **跑 M0' spike** —— 重点验证非阻塞多 Session 连接池与单通道 Pipelining，测量 Task 取消打断与小文件延迟，跑通即敲定最终后端库。