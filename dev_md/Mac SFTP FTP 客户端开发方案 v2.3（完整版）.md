# Mac SFTP/FTP 客户端开发方案 v2.2（完整版）

Oct 15, 2026 · @Johnny wang

## 概述与范围

本方案是一个 Swift 原生 macOS SFTP/FTP 客户端的完整开发方案，SFTP 优先，协议层复用成熟 C 库，不自研底层协议。状态：M0a 待启动，需先定 D1、D2。

### 范围

| 阶段 | 内容 |
| --- | --- |
| MVP（M0a\~M3） | SFTP 连接、双栏浏览、上传下载、传输队列（暂停 / 续传 / 恢复）、站点管理 + `.ssh/config` 导入、ssh-agent、隐藏文件开关、算法兼容矩阵 |
| v1.0（M4\~M6） | FTP/FTPS 后端、双向拖拽、Quick Look、外部编辑回传、三方同步引擎、诊断报告、契约测试、公证打包 |
| v1.1+ | 内置终端、ProxyJump 实际跳转、传输限速 / 定时、服务器间直传 |
| 不做 | 自研协议底层、File Provider 扩展、S3 / WebDAV（协议层预留但不实现） |

### 相对 v2.1 的主要修正

- 删除"单 session 只能开一个 SFTP 通道"的错误论断，并发方案改为三方案实测定案。
- 阻塞 C 调用改为每 session 专属 executor + 非阻塞 `poll` 循环，取消靠循环内检查。
- 路径保留 wire bytes，NFC 仅用于比较，并增加大小写与归一化碰撞检测。
- 加密后端只用 OpenSSL 3；删除 Security.framework 后端的说法和默认的 Swift 私钥预解析。
- 同步判重改为"stat 未变不读内容"，两侧分别记录 stat，补全真值表。
- CVE 清单全部标"待核"，须附 advisory 链接。
- 契约测试前移到 M1'；工期改为 20\~24 周（全职口径）。

## 阻塞决策与分发

M1 启动前必须定两项：D1 分发模式、D2 首要目标用户；它们改变数据模型和迁移成本，越晚定越贵。

### D1 · 分发模式

| 模式 | 沙盒 | 本地路径访问 | 结论 |
| --- | --- | --- | --- |
| A. Developer ID + 非沙盒 | 关 | 任意路径直读直写 | M0\~M5 选这个 |
| B. Developer ID + 沙盒 | 开 | NSOpenPanel 授权 + security-scoped bookmark | 后期可选 |
| C. Mac App Store | 强制开 | 同 B，审核更严 | 最后考虑 |

- 公证要求开启 Hardened Runtime（`-o runtime`）；App Sandbox 仅对 Mac App Store 强制。
- 不使用 `codesign --deep`，由内向外逐个签名内层组件，最后签主 App。
- 数据层从第一天起把本地路径存为 `ScopedBookmark`（`path` + 可选 `bookmarkData`），升级到模式 B 时数据结构不用改。
- bookmark 只能在用户通过 NSOpenPanel 授权时创建，模式 A 存下的纯路径在升级后需全部重新授权。M6 的 `SANDBOX-MIGRATION.md` 必须包含首次启动重新授权流程。

### D2 · 首要目标用户

| 场景 | 优先级上移 | 优先级下移 |
| --- | --- | --- |
| A. 自用 / 团队日常 | ssh-agent、`.ssh/config` 导入、隐藏文件、权限修改、⌘⇧G、错误提示质量 | FTP/FTPS 后端、拖拽 |
| B. 通用客户端发布 | 拖拽双向、Quick Look、同步预览、诊断报告 | ProxyJump |
| C. App Store 上架 | 沙盒、无障碍、本地化 | 自定义算法白名单 |

D2 未定前不要开始 M1：它决定算法兼容矩阵宽度，以及 ssh-agent 和 `.ssh/config` 导入是否必须。

推荐默认值：最低 macOS 14（`@Observable` 可用，避免大量条件编译）；MVP 不使用 SwiftData / GRDB。

## 依赖与安全基线

M0b 产出 `docs/SecurityBaseline.md`，每条依赖记录版本、commit hash、已知 CVE 及其 advisory 链接；没有链接的条目一律标"待核"，不进入结论。

### 依赖一览

| 依赖 | 用途 | 说明 |
| --- | --- | --- |
| libssh2 | SFTP | 固定上游某个 commit 构建并 vendor，记录 hash；不使用 Homebrew 版本 |
| OpenSSL 3.x | libssh2 加密后端 | 静态链接，与 libssh2 合并为 xcframework（arm64 + x86\_64），符号仅在 Backends target 内可见 |
| libcurl | FTP / FTPS | curl 许可证兼容闭源 |
| Citadel / swift-nio-ssh | 备选 SFTP | 仅在 spike 全部不通过时评估，需核对其实际修复版本与维护活跃度 |

### 加密后端与私钥

- libssh2 支持的后端是 OpenSSL、wolfSSL、mbedTLS、libgcrypt、WinCNG 等，没有 Security.framework 后端。
- libssh2 自己能解析 `openssh-key-v1`（含 bcrypt KDF 加密），配 OpenSSL 即可。不做 Swift 层预解密，避免解密后的私钥进入 Swift 内存；仅当 M1' 测试证明某类私钥确实解析失败，才加 `SSHKeyParser`，且只处理该类。
- 认证方式：密码、公钥（含 passphrase 回调）、ssh-agent、keyboard-interactive（2FA）。

### CVE 核实流程

- v2.1 列出的 CVE-2025-15661、CVE-2026-7598、CVE-2026-55199 / 55200、CVE-2026-43798 全部标"待核"（GHSA 编号被截断，部分描述可疑）。
- 逐条从 NVD 或项目 advisory 页取原文，确认受影响版本范围、是否影响客户端、修复 commit，写入 SecurityBaseline.md 并附链接。

### 算法白名单（M1' 交付，AlgorithmMatrix.md）

用 `libssh2_session_method_pref()` 逐项设置，UI 提供"允许弱算法"开关，开启时提示风险。

| 类别 | 默认启用 | 仅在"允许弱算法"下启用 | 始终关闭 |
| --- | --- | --- | --- |
| 主机密钥 | ssh-ed25519、rsa-sha2-256/512、ecdsa | ssh-rsa（SHA-1）、ssh-dss | — |
| KEX | curve25519、ecdh-sha2、diffie-hellman-group14-sha256 | diffie-hellman-group14-sha1、diffie-hellman-group1-sha1（仅老设备） | 小于 1024 位 DH |
| 加密 | aes128/256-ctr、chacha20-poly1305 | aes128-cbc、aes256-cbc | RC4、3DES、arcfour、blowfish、cast128 |
| MAC | hmac-sha2-256/512 | hmac-sha1 | md5、hmac-md5、ripemd160 |

具体取决于所选 libssh2 版本与 OpenSSL 的实际支持，以 M1' 的实测连通矩阵为准。

## 核心抽象

UI 和 Service 只面对协议，不知道具体后端；能力与生命周期分离，不支持的能力直接不在协议里，而不是塞进一个大协议再抛 unsupported。

### 三层协议

```swift
protocol RemoteFileSystemFactory: Sendable {
    var declaredCapabilities: RemoteCapabilities { get }   // 后端固有
    func makeConnection(_ config: SiteConfig) -> RemoteConnection
}

protocol RemoteConnection: Sendable {
    var negotiatedCapabilities: RemoteCapabilities { get } // 登录后协商
    func handshake() async throws
    func close() async
    var fileSystem: RemoteFileSystem { get }
}

protocol RemoteFileSystem: Sendable {
    func list(_ path: RemotePath) async throws -> [RemoteItem]
    func stat(_ path: RemotePath) async throws -> RemoteItem
    func lstat(_ path: RemotePath) async throws -> RemoteItem
    func openRead(_ path: RemotePath) async throws -> any RemoteReader
    func createWrite(_ path: RemotePath, offset: Int64) async throws -> any RemoteWriter
    func mkdir(_ path: RemotePath, permissions: UInt16?) async throws
    func remove(_ path: RemotePath, recursive: Bool) async throws
    func rename(_ from: RemotePath, to: RemotePath, overwrite: Bool) async throws
    func symlink(target: String, at path: RemotePath) async throws
    func readlink(_ path: RemotePath) async throws -> String
    func chmod(_ path: RemotePath, _ mode: UInt16) async throws
    func statvfs(_ path: RemotePath) async throws -> RemoteVolumeInfo
}
```

UI 拿到 `RemoteFileSystem` 时连接必然已就绪，所以协议里没有 `connect()`。

### RemoteItem 与可信度标记

```swift
struct RemoteItem: Sendable, Hashable {
    let path: RemotePath
    let kind: Kind                 // file / directory / symbolicLink / other
    let size: Int64?
    let modificationDate: Date?
    let sizeIsExact: Bool          // FTP 目录列表常给估算值
    let mtimeIsReliable: Bool      // 部分 FTP 无 MDTM；SFTP 为秒级
    let linkTarget: String?
    let permissions: UInt16?
    let owner: String?
    let group: String?
}
```

可信度标记必须第一天就有：同步引擎用 mtime 判断"未修改"，把不可信的 mtime 当可信，会产生"看起来没变、实际已改"的静默数据丢失。

### 读写句柄：actor + 调用方提供缓冲

```swift
protocol RemoteReader: Actor {
    var totalSize: Int64? { get }
    /// 读入调用方提供的缓冲，返回实际字节数；0 表示 EOF
    func read(into buffer: UnsafeMutableRawBufferPointer) async throws -> Int
    /// 可从任意任务调用，只置原子取消标志
    nonisolated func cancel()
    func close() async
}

protocol RemoteWriter: Actor {
    func write(_ buffer: UnsafeRawBufferPointer) async throws -> Int  // 实际写入数
    func commit() async throws
    func abort() async
}
```

- 句柄是 actor，`cancel()` 为 `nonisolated`，由并发模型一节的 `poll` 循环观察，避免 `mutating` 值类型与取消并发时违反独占访问。
- `TransferEngine.pump` 持有 2\~3 块固定缓冲（默认 256KB）循环复用；复用先作为可测量的优化，M3 用 Instruments 对比后再决定是否硬性。

### Capability（declared + negotiated）

| 能力 | SFTP | FTP/FTPS | 备注 |
| --- | --- | --- | --- |
| 断点续传下载 | 可 | REST，支持度参差 |  |
| 断点续传上传 | 可 | APPE 不可靠，默认关闭 | 需 negotiated 确认 |
| 覆盖式 rename | 取决于 `posix-rename@openssh.com` 及 libssh2 是否暴露 | 需先 DELE，非原子 | M0a 查 API 后定 |
| 服务端内复制 | 不支持 | 少数服务器 SITE CPFR |  |
| 权限位 / 属主 / 软链 / lstat | 可 | 基本不可 |  |
| 文件哈希 | 无（SFTP v3） | 无 | 影响同步判重 |
| charset | 固定 UTF-8 | OPTS UTF8 / FEAT，服务器常谎报 | 需可配置 |

UI 据此决定权限列显示什么、上传是续传还是整体传、rename 是否提示"非原子"。FTP 的 FEAT 经常不实，危险能力默认关闭，需协商确认才启用。

### 错误分类

```swift
enum RemoteError: Error {
    case network(NetworkKind)                  // 可重试
    case auth(AuthFailure)
    case hostKeyMismatch(fingerprint: String)  // 强警告，须人工确认
    case permissionDenied(path: RemotePath)
    case notFound(path: RemotePath)
    case unsupported(RemoteCapabilities)       // UI 降级，不报错
    case undecodablePath(bytes: [UInt8])
    case protocolViolation(String)
    case localIO(LocalIOKind)
}
```

只有 `.network` 可重试；`.auth`、`.hostKeyMismatch`、`.protocolViolation` 对会话致命。`notFound` 必须是可识别类型：同步引擎靠它区分"远端已删"与"网络故障"，混淆会在网络抖动时误删本地文件。UI 把不同成因的错误分别呈现，不用同一句文案。

## 路径与编码

路径的权威表示是服务器返回的原始字节，NFC 只用于比较，不用于寻址；否则 Linux 上并存的 NFC 与 NFD 同形文件会被合并成一个。

```swift
struct RemotePath: Hashable, Sendable {
    let wireBytes: [UInt8]          // 权威表示；发往服务器的操作只用它
    let isAbsolute: Bool
    /// 仅用于展示。非法 UTF-8 以 \xNN 呈现，不做有损替换
    func displayString(using: CharsetDecoder) -> String
}

struct ComparisonKey: Hashable {
    let bytes: [UInt8]              // wireBytes 经 NFC（及可选大小写折叠）派生
}

struct PathPolicy: Sendable {      // 属于连接 / 文件系统，不属于单个路径
    let caseSensitive: Bool
    let normalizeForCompare: Bool
    func key(for path: RemotePath) -> ComparisonKey
}
```

### 规则

- `stat`、`rename`、`remove` 等一律使用 `wireBytes`，永不用比较键回写。
- 本地与远端对齐、diff、去重只用 `ComparisonKey`。同一目录下两个不同 `wireBytes` 映射到同一键时记为"键碰撞"，UI 报警并跳过自动操作。
- 大小写策略属于连接：远端 Linux 大小写敏感，本地 APFS 默认不敏感，两侧分别比较。

### 必须覆盖的碰撞场景

- 远端同时有 `Foo.txt` 与 `foo.txt`，下载到 APFS：检测并提示，不允许后者静默覆盖前者。
- 远端同时有 NFC 与 NFD 写法的同名文件：保留为两个文件，同步时标碰撞。
- 远端文件名不是合法 UTF-8（如 GBK）：保留原字节，展示用十六进制或所选 charset 解码，不转成 `String` 后再回写。

### PathResolver 范围

POSIX 根、`~` 展开、`.` / `..` 回退（不越过根）、空路径、重复分隔符、尾部 `/`、软链展开深度上限。M0b 交付，必须有独立单测；两个后端共用，出错就是全盘错。

## 架构分层与项目结构

依赖自上而下：UI 和 Service 只面对 `RemoteFileSystem` 协议，不知道具体后端；Core 零 C 依赖，C 库只出现在 Backends。

&#91;embedded content: 分层架构 · 7 层，Core 与 Backends 隔离\]

### Package 划分

- **Core Package**：协议、模型、横切层、Services，只依赖 Foundation，单测可在任意环境秒级运行，CI 快，也不必处理 modulemap 和头文件问题。
- **Backends Package**：SFTP 与 FTP 两个后端及其 C 依赖；libssh2 + OpenSSL 的 xcframework 打包成本关在这一个 target 里。
- **App Package**：UI 与 Infra，依赖 Core。

未来若要出命令行版，只需依赖 Core 加一个后端，不带 UI。

### 项目结构

```text
SFTPClient/
├─ Packages/
│  ├─ Core/
│  │  ├─ Protocol/      RemoteFileSystem / RemoteConnection / Factory
│  │  ├─ Model/         RemoteItem / RemotePath / Capabilities
│  │  ├─ CrossCutting/  PathResolver / CharsetConverter / ErrorTaxonomy
│  │  ├─ Transfer/      TransferQueue / ResumePolicy / RetryPolicy
│  │  ├─ Sync/          SyncEngine / BaseSnapshot / DiffPlan
│  │  └─ Connection/    ConnectionManager / Heartbeat / Backoff
│  └─ Backends/
│     ├─ SFTP/          libssh2 + OpenSSL xcframework
│     └─ FTP/           libcurl
├─ App/
│  ├─ UI/               Browser(AppKit) / Shell / Queue / Sites / Sync
│  └─ Infra/            Keychain / Store / ScopedBookmark / HostKeyStore
├─ Spike/               M0a 技术验证，独立可删
├─ docs/                SecurityBaseline / AlgorithmMatrix / SANDBOX-MIGRATION / ADR
└─ Tests/               CoreTests / ContractTests / IntegrationTests
```

## 并发模型与连接管理

每个 libssh2 session 由一个专属串行 executor 拥有，session 内所有 C 调用只在该 executor 上执行，使用非阻塞模式加 `poll` 循环；取消通过循环内检查标志实现。

### 设计原因

- libssh2 的 session 不是线程安全的，同一 session 的调用必须串行。
- 在 async 函数里直接调阻塞的 libssh2，会占住 Swift 协作线程池（线程数约等于核数），3 个并发传输加 UI 刷新就可能把线程池饿死。
- 阻塞调用无法被 `Task.cancel()` 打断，会出现"UI 显示已取消、网络仍在传"。

### 实现要点

1. 每个 session 一个自定义 `SerialExecutor`，session 与句柄 actor 通过 `unownedExecutor` 绑定到它。
2. session 设为非阻塞。C 调用返回 `LIBSSH2_ERROR_EAGAIN` 时，用 `libssh2_session_block_directions()` 判断等读还是等写，再对 socket 调 `poll`，超时 50\~100ms。
3. 每次 `poll` 返回后检查原子取消标志，置位则抛 `CancellationError` 并走 `abort()`。取消响应时间上限约为一个 `poll` 周期加一次 chunk 处理。
4. 备用：从另一线程 `shutdown(socket)`。代价是同 session 的所有 channel 一起失败，需在 spike 中量化。
5. 不把 `libssh2_session_set_abort_fn()` 作为方案前提，spike 先确认所选 commit 里是否存在。

### 并发传输方案

| 方案 | 说明 | 取舍 |
| --- | --- | --- |
| A. 多 session 连接池（主选） | 控制面 1 个 session，每个并发传输一个独立 session | 并行加密、多条 TCP 流；受服务端 `MaxStartups` / `MaxSessions` 限制，需实测 |
| B. 单 session 多 channel | 同一 session 上多次 `libssh2_sftp_init()` | 需先验证；省连接，但共享一条加密流与 window，吞吐上限更低 |
| C. 单通道请求流水线 | 不等 ACK 连续发多个 `SSH_FXP_READ` / `WRITE` | 高延迟链路跑满的关键；`libssh2_sftp_read` 自带预读，先测默认表现再决定是否自建 |

### 连接管理

- 控制面与数据面分离：每站点 1 条控制 session 负责目录浏览、stat、心跳。
- 心跳用 `libssh2_keepalive_send()`，超时用 `libssh2_session_set_timeout()`。
- 断线重连用指数退避（1s、2s、4s，上限 30s，带抖动），重连后恢复当前目录。
- 传输进行中不自动重连，交给传输队列走续传逻辑，避免静默重试产生坏文件。
- 存在活动连接时持有 `ProcessInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, ...)`，防止 App Nap 节流心跳；最后一条连接关闭时释放。
- 主机指纹首次连接弹窗确认，存入本地记录，也可复用 `~/.ssh/known_hosts`；指纹变更强警告。

## 传输队列

传输队列是一个 actor，UI 只订阅状态，不直接碰网络层；暂停与取消语义分离，所有写入先落临时名，校验后再原子 rename。

### 状态机

`pending` → `running` → `completed`；`running` 可转 `paused`、`failed`、`cancelled`；`paused` 可回到 `pending` 续传。`failed` 分可重试与不可重试，只有 `.network` 类错误自动重试。

| 操作 | 语义 |
| --- | --- |
| 暂停 | 保留 `.part` 与已传 offset，断开连接；之后由队列重建连接并从 offset 续传 |
| 取消 | `abort()` 远端句柄，删除 `.part`，清理状态 |

### 临时名与原子替换

- 下载写 `<target>.part`，校验通过后原子 rename 到目标名；中断留下的 `.part` 不能被当成完整文件。
- 上传先写 `<name>.part-<随机后缀>`，完成并通过大小校验后 rename 到目标名；残留的临时文件在下次连接时列出，由用户确认清理。
- 目标已存在且 SFTP 覆盖式 rename 不可用时：先把旧文件 rename 为备份名，再 rename 新文件，最后删除备份，任一步失败则回滚。FTP 非原子，UI 提示。

### 续传置信度校验

- 记录续传起点 `(size, mtime, mtimeIsReliable)`，完成后复查，不一致则标记低置信度完成并告知用户，可配置自动重传。
- `mtimeIsReliable == false` 时禁用上传续传；下载续传至少要求 size 精确匹配。
- 原因：SFTP mtime 可能只有秒级，只比 mtime 无法区分"没变"与"同秒内被改过"。

### 调度与恢复

- 全局并发默认 3，可按站点限流；失败分类决定是否重试。
- 文件夹传输先递归展开为文件任务再入队；递归中必须检查取消，10 万文件的目录否则会让取消按钮无响应。
- 队列状态落 JSON，状态变化后 500ms 防抖写盘，进度变化不触发写盘，仅在暂停、完成、失败、退出时落盘。
- 崩溃恢复：启动时把中断的 `running` 全部转为 `paused`，`.part` 保留，不自动续传，避免启动即传错。
- 取消贯穿所有长循环：chunk 循环、目录递归、哈希计算、差异计算、批量 chmod。

## 浏览、拖拽与外部编辑

文件管理器的工作量主体是浏览、拖拽和回传，这三块交互要先把冲突与覆盖行为定死，否则 UI 逻辑会反复改。

### 文件浏览

- 目录懒加载：先渲染缓存再刷新，缓存用 LRU，上限可配。
- 大目录分批追加（每批约 500 项），用 `NSOutlineView` 的增量更新而不是全量 `reloadData()`。
- 隐藏文件默认显示（服务器上 `.env`、`.git`、`.htaccess` 是刚需），提供快捷键切换。
- ⌘⇧G 前往路径，路径栏可编辑；列排序和列头拖拽由 AppKit 提供。
- 本地目录用 `FileManager` 加监听变化；远端靠手动或定时刷新。

### 拖拽矩阵

| 源 → 目标 | 机制 | 备注 |
| --- | --- | --- |
| 远端 → 本地面板 | 内部拖拽 | 建下载任务 |
| 本地 → 远端面板 | 内部拖拽 | 建上传任务 |
| Finder → 远端面板 | `NSFilePromiseReceiver` | 拖入文件落下后上传 |
| 远端 → Finder | `NSFilePromiseProvider` | 拖的是 promise，落下才下载 |
| 远端 → 远端 | v1.1+ | 协议层直传，不落盘 |

冲突策略早定：N 个文件拖入已存在的同名目录时，目录合并，文件按预设策略处理（默认询问：覆盖 / 跳过 / 全部重命名）。

### Quick Look

下载到临时目录后交给 `QLPreviewPanel`，临时文件在关闭预览或退出时清理。

### 外部编辑回传

- 下载到临时目录，用 `NSWorkspace.open` 打开，`FSEvents` 监听。
- 监听父目录而不是单个文件：主流编辑器保存时先写临时文件再 rename 覆盖，只监听目标文件会漏掉保存事件。
- 防抖 500\~1000ms：一次保存通常触发 3\~5 个事件，不防抖会重复上传，甚至上传未写完的文件。
- 默认不自动上传：用显式开关，加醒目的"正在监视"状态条，也可手动触发上传。
- 上传前比对远端 mtime，已变更则停下询问，不静默覆盖。

## 同步引擎

同步判重采用"stat 未变则不读内容，可疑才比内容"，base 快照分别记录本地与远端两侧的 stat。"小文件默认哈希"在 SFTP 上等于每次同步下载所有小文件，1 万文件的仓库不可用。

### base 快照

base 是上次同步后双方一致的快照，存本地。每个文件按 `ComparisonKey` 存一条：

- 本地侧：size、mtime（纳秒）、inode（可选）
- 远端侧：size、mtime（秒级）、`mtimeIsReliable`
- 内容哈希：上次确认两侧一致时计算

上传后远端 mtime 不等于本地 mtime，所以两侧不能共用一份 mtime。

### 判重策略

| 情形 | 判定 | 代价 |
| --- | --- | --- |
| 某侧 `(size, mtime)` 与 base 一致且 mtime 可靠 | 该侧未变 | 零内容读取 |
| size 不同 | 已变 | 零内容读取 |
| size 相同但 mtime 变了，或 mtime 不可靠 | 可疑：本地算哈希与 base 比；远端需下载比较，是否自动执行由用户设置 | 仅对可疑文件读内容 |
| FTP 且 `mtimeIsReliable == false` | 同步前要求人工确认，或强制比较内容 | 较高，UI 标注置信度 |

### 完整真值表

本地、远端栏表示相对 base 的状态，"变"含新增与内容修改。

| 本地 | 远端 | 结果 |
| --- | --- | --- |
| 未变 | 未变 | 无操作 |
| 变 | 未变 | 上行 |
| 未变 | 变 | 下行 |
| 变 | 变，且内容相同 | 无操作，更新 base（不算冲突） |
| 变 | 变，内容不同 | 冲突 |
| 删除 | 未变 | 远端删除（需开启删除选项，先预览） |
| 未变 | 删除 | 本地删除（同上） |
| 删除 | 变 | 冲突 |
| 变 | 删除 | 冲突 |
| 两侧同时新建，内容相同 |  | 无操作，写入 base |
| 两侧同时新建，内容不同 |  | 冲突 |
| 一侧为文件、另一侧为目录 |  | 冲突，不自动处理 |

### 其他规则

- 冲突不自动解决，写入预览列表，用户选"以本地为准 / 以远端为准 / 保留双份"。
- 删除默认关闭，开启要二次确认，并先出预览。
- `notFound` 与网络错误必须区分：网络错误一律放弃本次同步，不当作"远端已删"。
- 比较键碰撞的条目标为冲突，不自动处理。
- 输出 `DiffPlan`，用户确认后才生成 `TransferTask`；`DiffPlan` 可序列化导出，便于复核。
- 以 `(ComparisonKey, size)` 为主键建索引，避免 O(n²) 比较。

## 存储、UI 与可观测性

MVP 不使用数据库，所有持久化用 Codable 加原子写 JSON；文件列表用纯 AppKit，其余界面用 SwiftUI，中间不做同步层。

### 存储

```swift
actor Store<T: Codable & Sendable> {
    private let url: URL
    init(url: URL) { self.url = url }

    func read() throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }

    func write(_ value: T) throws {
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
}
```

- 用 actor 序列化读写，避免写入原子替换瞬间的读写竞态，符合 Swift 6 严格并发。
- MVP 的传输历史只用于重启恢复和查看最近记录，都是全量读取，不需要索引；每天几千条的量级 JSON 足够。
- 历史超过 10 万条或出现按站点 / 时间 / 状态筛选需求，再引入 GRDB；保留最近 N 条加未完成任务，超阈值裁剪。
- 站点密码与密钥口令存 Keychain。macOS 的 login keychain 在登录期间一般不因锁屏而锁定，不照搬 iOS 的 `AfterFirstUnlock` 经验；若使用 data-protection keychain，需要对应 entitlement 和 profile。

### UI 切法

- 文件列表：纯 AppKit `NSOutlineView`（多列），dataSource 与 delegate 直连 ViewModel。拖拽、多选、列排序、右键菜单、就地重命名、Quick Look 这些行为用 AppKit 才可靠，SwiftUI `Table` 的短板在这里，而不是性能。
- 窗口框架、工具栏、传输队列面板、站点管理、设置、同步预览：SwiftUI（`@Observable`）。
- 两者通过 `@MainActor` 的 `BrowserController` 交界，ViewModel 是唯一真相，不用 `NSViewRepresentable` 做双向数据同步。

### 可观测性

- 诊断报告一键导出：连接参数（脱敏）、libssh2 / libcurl verbose 日志、每步耗时、最终错误码。
- 日志分级；密码、私钥内容绝不落盘；用户名是否算 PII 需明确规则。
- 错误码到可读建议的映射表，例如 `EHOSTUNREACH` 对应"检查网络或代理"，`EACCES` 对应"服务器权限不足"，`undecodablePath` 对应"文件名不是合法 UTF-8，已按服务器编码解释"。

## 测试策略

同一套契约测试跑在两个后端上，是防止"FTP 少个功能，我加个 if"把抽象破掉的唯一办法，所以从 M1' 就开始建，不等到 M6。

### 后端契约测试

覆盖范围：

- 路径规范化（`..`、尾部斜杠、大小写、非 ASCII、软链成环）与键碰撞
- 空目录、大目录、深层嵌套
- 特殊文件名（`:`、`*`、控制字符、超长名）
- 权限与 mtime 缺失时的降级（`mtimeIsReliable == false`）
- 大文件往返哈希一致
- capability 声明与实际行为一致，声明了但不支持则契约失败

M1' 先用 SFTP 后端和内存 fake 建框架；M5 接入 FTP 后端后同一套用例直接复用。

### Docker 环境

| 服务 | 目的 | 引入阶段 |
| --- | --- | --- |
| atmoz/sftp | SFTP 主测试环境 | M0a |
| OpenSSH 官方镜像 | 对照组，行为可能与 atmoz 不同 | M0a |
| 老算法 sshd 配置 | 只支持 ssh-rsa / CBC 的老设备仿真 | M1' |
| vsftpd / pure-ftpd / proftpd | FTP 三种方言 | M5 |
| pyftpdlib 改造 fixture | 构造 GBK / Big5 文件名、畸形 MDTM、谎报 FEAT | M5 |

### 单元与故障注入

- Core 单测纯 Swift、秒级，重点是 `PathResolver`、`CharsetConverter`、续传策略、同步引擎。
- 传输队列用假的 `RemoteFileSystem` 注入故障（中途断线、写失败、超时、磁盘满）验证状态机。
- 手工用例：中文文件名、超长路径、软链成环、权限不足、磁盘满、WiFi 与有线切换、锁屏、休眠唤醒。

### CI

上述测试全部跑在 CI 上（macOS runner 加 Docker 服务容器），本地绿不算绿。

## 里程碑与 M0a spike 清单

合计 20\~24 周（全职口径），业余时间按 2\~3 倍估算。M0 拆为 M0a 与 M0b，xcframework 构建放在 spike 之后、M1' 之前。

| 阶段 | 周期 | 交付 | 出口标准 |
| --- | --- | --- | --- |
| M0a | 2 周 | 工程骨架；协议与模型；Docker SFTP 环境；spike（下表），spike 阶段可临时链接开发用 libssh2 | 并发方案与取消机制定案，写入 ADR |
| M0b | 1.5 周 | libssh2 + OpenSSL 3 静态 xcframework 构建脚本（固定 commit）；PathResolver、CharsetConverter、ErrorTaxonomy 及单测；逐个签名 + Hardened Runtime + 公证跑通；SecurityBaseline.md 骨架 | xcframework 可被 Backends target 链接；签名公证产物可启动 |
| M1' | 3 周 | 连接；密码 / 公钥 / ssh-agent / keyboard-interactive；目录列表；单文件上下传；AlgorithmMatrix.md；契约测试框架 | 连上至少 3 个不同年代的服务器，含一个只支持 ssh-rsa 的老设备；契约测试首批用例全绿 |
| M2 | 3 周 | 双栏 UI；站点管理；`.ssh/config` 导入；Keychain；复用 `~/.ssh/known_hosts`；隐藏文件开关；⌘⇧G | 中文文件名、超长路径、特殊字符名三项手工用例通过 |
| M3 | 4 周 | 传输队列；暂停 / 取消分离；上传临时名；续传置信度；崩溃恢复；限速；取消贯穿递归 | 杀进程重启后任务状态与 .part 一致；传输中点取消 200ms 内停 |
| M4 | 2 周 | 拖拽矩阵；冲突策略 UI；Quick Look；外部编辑回传 | 拖拽矩阵 5 行全部可用 |
| M5 | 3 周 | FTP/FTPS 后端；同步引擎 | 双端同时修改同一文件被识别为冲突 |
| M6 | 2 周 | 契约测试覆盖两个后端；诊断报告；SANDBOX-MIGRATION.md；自动更新（Sparkle）；Beta | 同一套契约测试全绿，两后端零特判 |

可砍项：内置终端，以及 ProxyJump 的实际跳转（导入 `ProxyJump` 配置项可保留，标注暂不支持）。不要砍 M0a spike 和 M3 的续传置信度校验。

### M0a spike 清单

| # | 验证项 | 验收标准 |
| --- | --- | --- |
| 1 | 同一 session 上两次 `libssh2_sftp_init()`（第 1 天，约 10 分钟） | 记录是否成功，以及超过 `MaxSessions` 时的失败行为 |
| 2 | 方案 A：1 个控制 session + 3 个并发传输 session | 跑满局域网带宽；记录对 `MaxStartups` 的容忍度 |
| 3 | 方案 B / C：单 session 多 channel，及单通道请求流水线 | 对比方案 A 的吞吐与 CPU；记录默认预读表现 |
| 4 | 非阻塞 + `poll` 取消 | `Task.cancel()` 后 200ms 内真正停止网络传输 |
| 5 | 备用取消：shutdown socket | 量化"同 session 其他 channel 一起失败"的代价 |
| 6 | 1000 个 1KB 文件批量往返 | 记录总耗时与内存峰值，确认瓶颈是 round-trip 还是 UI 刷新 |
| 7 | `posix-rename@openssh.com`、`set_abort_fn` 等 API | 在所选 commit 的头文件中确认是否存在 |
| 8 | 加密后端对 `openssh-key-v1` + bcrypt 私钥的解析 | 解析成功则不做 Swift 预解析 |

出口：方案 A、B、C 至少一个跑通且取消验收通过，则定案并写入 ADR；全部不通过则评估 Citadel。

## 风险与待办

| # | 风险 | 应对 |
| --- | --- | --- |
| R1 | 并发架构选型（连接池 / 单 session 多 channel / 流水线）选错导致返工 | M0a 第 1 项先验证事实，再比较三方案；全部不通过评估 Citadel |
| R2 | FTP 上传续传写坏文件 | 默认关闭，仅在 negotiated 确认后开启；写后校验 size |
| R3 | 同步引擎误判导致静默丢数据 | stat 未变才判未变，可疑才比内容；冲突绝不自动解决 |
| R4 | 老服务器因算法默认关闭连不上 | AlgorithmMatrix.md + 用户可见的弱算法开关 |
| R5 | 编码转换有损 | wire bytes 权威，无法解码时走十六进制视图 |
| R6 | 取消不打断阻塞调用 | 非阻塞 + `poll` + 取消标志；spike 第 4 项验收 |
| R7 | 沙盒升级成本 | `ScopedBookmark` 预留；M6 文档含重新授权流程 |
| R8 | 依赖 CVE 无上游 release，清单未核实 | 固定 commit；SecurityBaseline.md 逐条附 advisory 链接，未核实标"待核" |
| R9 | FTP 方言兼容地狱导致 M5 超期 | 至少 3 种方言 + pyftpdlib fixture；必要时把 FTP 移出 MVP |
| R10 | 传输历史 JSON 随时间变大 | 阈值裁剪；超阈值才迁 GRDB |
| R11 | 私钥格式兼容 | 以 libssh2 + OpenSSL 实测为准；失败才加 Swift 预解析 |
| R12 | 路径归一化合并不同文件，或大小写碰撞静默覆盖 | wire bytes 权威 + 比较键 + 碰撞检测 |
| R13 | 同步判重在 SFTP 上全量下载 | stat 未变不读内容；base 分别记录两侧 stat |
| R14 | 时间估算为全职口径，业余易低估 | 业余时间按 2\~3 倍规划 |

### 下一步

- [ ] 定 D1（推荐模式 A）
- [ ] 定 D2
- [ ] 开始 M0a，第 1 天先做 spike 第 1 项
- [ ] 逐条核实 CVE 并附链接
