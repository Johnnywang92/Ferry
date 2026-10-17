# Mac SFTP/FTP 客户端方案评审

评审对象：`Mac SFTP/FTP 客户端开发方案`（Swift 原生 + SFTP 优先）

评审口径：以"能否在 2026-10 的 macOS 上，单人业余时间做出一个真能日用的工具"为基准。不评审 UI 美学，评审**架构前提、依赖安全基线、以及被漏掉的、会决定成败的环节**。

---

## 0. 总评

**结构判断是对的，落地方案有几处会返工的漏洞。**

对的部分（值得保留，不用改）：
- `RemoteFileSystem` 协议抽象 + UI/Service 与协议解耦 —— 方向正确，是这类项目唯一能活过两个后端的做法。
- 一开始就用 AppKit 封装文件列表，不赌 SwiftUI `Table` —— 结论正确（理由见 §3.1）。
- 流式 `read/write` + `offset` 参数支持大文件和续传 —— 正确。
- `Core` 拆独立 Swift Package 以便单测和将来出 CLI —— 正确，且应该更彻底（见 §4.6）。
- 传输队列是最容易做烂的部分 —— 判断正确，但低估了（见 §2.2）。

不对 / 缺失的部分（P0 和 P1 各 3~4 条，都在下面）。

---

## 1. P0：必须改，否则会返工

### 1.1 libssh2 的线程模型没有解决，而它决定了 Core 层所有代码的写法

方案说"SFTP 可以在一个会话里开多个 channel"，这句是对的，但漏了紧随其后的问题：

> libssh2 官方文档对线程安全的表述是：**"Thread-safe: just do not share handles simultaneously"** —— 同一个 session 的 handle 不能被多线程同时使用。

也就是说，你不能"3 个并发传输各开一个 task 直接打同一个 session"。三条现实路径，各有代价：

| 路径 | 后果 |
|---|---|
| 阻塞模式 + 串行队列 | 最简单，但**一次阻塞 read 会卡住整个 session** —— 一个慢文件会冻结其他所有通道。并发度实际=1。 |
| 阻塞模式 + 多 session | 简单可靠，但每个 session 一次 TCP + 握手 + 认证。传一个 500 文件的文件夹 = 500 次建连或 N 次。 |
| 非阻塞模式 + 自建 event loop | 唯一能拿到真实并发的路。但每个 `libssh2_*` 调用都可能返回 `LIBSSH2_ERROR_EAGAIN`，你要用 `libssh2_session_block_directions()` 判断该等 fd 可读还是可写、`poll()` 后重试。**这就是一个手写的事件循环**，也是整个项目技术风险最高的地方。 |

**方案完全没提这一层。** 而这直接决定了 `RemoteFileSystem.write(path:offset:data:)` 的实现形态、`TransferQueue` 的调度模型、以及"并发数默认 3"这个参数到底能不能真的并发。

更关键的是：这也决定了 `libssh2` vs `Citadel` 怎么选 —— Citadel 走 NIO，事件循环是 NIO 给你写好的；libssh2 要你自己写。**这个差异巨大到足以决定选型，而方案把选型理由写成了"集成省事 vs 吞吐"。**

**建议**：M0 就做一个 spike 定库，不要等到 M1 做完再回头。Spike 的验收标准（跑通即定库）：
1. 单 session 3 个并发 SFTP 通道跑满带宽；
2. 中途 `Task.cancel()` 能在 200ms 内真正打断阻塞在 libssh2 里的调用（不能只是 Swift 层的取消）；
3. 1000 个 1KB 小文件的批量往返 —— 这个比 1GB 大文件更能暴露封装开销和 NSTableView 刷新策略问题。方案里"用 1GB 文件跑基准"这个选择本身有问题，大文件对 libssh2 的封装开销不敏感。

### 1.2 `RemoteFileSystem` 协议缺能力协商，`RemoteItem` 根本没定义

协议正文列了 9 个方法，但：

**(a) `RemoteItem` 没有定义。** 整个 UI 和 SyncEngine 都依赖它，方案里它只是一个裸名字。至少需要：

```swift
struct RemoteItem {
    let path: String            // 规范化后
    let name: String            // 展示用，可能已被 charset 转换
    let size: Int64?
    let modificationDate: Date? // 精度必须显式声明：SFTP 秒级 / FTP 可能只有 MDTM / 有的服务器干脆不返回
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let linkTarget: String?
    let permissions: UInt16?    // SFTP 有，FTP 基本没有 → nil
    let owner: String?          // 同上
    let sizeIsExact: Bool       // FTP 目录列表里常是估算
}
```

`sizeIsExact` 和 `modificationDateIsReliable` 这类"可信度标记"必须从第一天就在模型里 —— 否则 SyncEngine 会用不可信的 mtime 做出错误的"未修改"判断，而这种 bug 极难定位。

**(b) 没有 capability 协商。** SFTP 和 FTP 的能力差异是**结构性的**，不是"某个功能 FTP 没实现"的差异：

| 能力 | SFTP | FTP/FTPS |
|---|---|---|
| 断点续传上传 | 可（seek + write） | 靠 `APPE`/`REST`，服务器支持度参差不齐，有的会静默写坏 |
| 权限位 / 属主 | 可 | 基本不可 |
| 符号链接 | 可（`readlink`/`symlink`） | 基本不可 |
| 服务端内复制 | 可 | 仅部分（`SITE CPFR`） |
| 原子 rename（覆盖） | 可（标准 rename 覆盖） | 需先 `DELE` → 非原子 |
| 文件哈希 | 无（SFTP v3） | 无 |
| 目录 stat | 可 | 不可（只能 LIST 父目录再匹配，或 `MLSD` 某一级） |
| 中文文件名 | UTF-8 | 需协商 charset，GBK/Big5 服务器仍存在 |

所以协议里必须有：

```swift
protocol RemoteFileSystem: Sendable {
    var capabilities: RemoteCapabilities { get }   // 静态能力
    // 不可用的能力调用时抛 .unsupported(capability)，而不是静默降级
}
```

并且 UI 必须读它来决定"权限列显示什么""上传按钮是断点续传还是整体重传"。**没有这一层，两个后端的差异会渗透进 UI，后期剥离成本翻倍。**

**(c) 缺符号链接的完整建模。** 方案说"文件夹传输先递归展开成文件任务"。那目录里有 symlink 呢？很多用户的 home 目录有 `~/.nvm`、`~/.local/bin` 这类软链，递归会**成环**或**无限膨胀**。而 `stat` 是否跟随软链也是个必须显式选择的语义（`stat` vs `lstat` 两个入口）。

**(d) 缺 `stat` 的错误语义。** `notFound` 必须是一个可识别的错误类型。SyncEngine 要靠它区分"远端被删了 → 记为待删除" 和 "网络故障了 → 放弃本次同步"。这两个混在一起会让同步引擎在网络抖动时误删本地文件。

**(e) 缺服务器↔服务器传输。** 方案把 S3/WebDAV 推到"以后"，但**站点 A ↔ 站点 B 的直传**是同类产品的核心卖点，而且它恰好是纯协议层能力（`read` 流直接喂给 `write`，不落盘），成本低、收益高。现在设计协议时留好口（`makeReader` / `makeWriter` 而不是绑死路径），以后几乎零成本。

**(f) `write(path:offset:data: AsyncStream<Data>)` 在 MVP 阶段是过度设计。** SFTP 和 FTP 的上传续传都不是"开箱就工作"的功能。建议：MVP 的 `write` 不带 `offset`（整体上传 + 失败重试），协议里保留但抛 `.unsupported`，比实现一半更诚实也更省时间。

**(g) 协议同时表达了"能力"和"生命周期"。** `connect()` / `disconnect()` 放在文件操作协议里，导致拿到实例时无法知道它处于什么状态。应该拆成 `RemoteFileSystemFactory.makeConnection(config:) -> RemoteConnection`，协议只描述文件操作，连接生命周期归连接对象。

### 1.3 依赖的安全基线没核对（这条最容易被忽略，但风险实打实）

方案在"技术选型"里列了 libssh2 和 Citadel，没有任何版本/安全说明。实际情况：

**libssh2**
- 最新上游 release 仍是 **1.11.1（2024-10-16）**，已两年无新 tag。
- 期间靠发行版/社区补丁修掉了多个 CVE，其中**直接命中本产品攻击面**的是 **CVE-2025-15661：SFTP 响应解析导致信息泄露与拒绝服务** —— 客户端正是持续解析远端 SFTP 响应的角色。
- 另有 CVE-2026-7598（超长 username/password 参数整数溢出，上游 PR #1858）、CVE-2026-55200 / CVE-2026-55199（Fedora 于 2026-06 补入 1.11.1-8/9）。
- 1.11 起大量老算法**默认不再编译**（`LIBSSH2_NO_MD5/HMAC_RIPEMD/DSA/RSA/RSA_SHA1/AES_CBC/AES_CTR/BLOWFISH/RC4/CAST/3DES`）。这对这个产品是**双刃**：安全上是好事，但大量老服务器/嵌入式 NAS 依赖 `ssh-rsa`(SHA-1) 主机密钥或 `diffie-hellman-group14-sha1` 做 KEX，**默认关掉会导致一批设备连不上**。
- → 结论：**从 git main 构建或 vendor 已打补丁的版本**，不要用 Homebrew 的 1.11.1。同时要有意识地做算法白名单（放开 `ssh-rsa`/`ssh-dss`/`group14-sha1`/`diffie-hellman-group1-sha1`，但保持 RC4/3DES/MD5 关闭）。**"算法兼容矩阵"应该作为 M1 的交付物之一**，因为它是这类产品的核心竞争力之一，方案只把"文件名编码"列进了风险，漏了算法。

**Citadel / SwiftNIO SSH**
- **CVE-2026-43798：Swift-NIO-SSH 栈写入导致代码执行，修复版本 0.14.1**（Apple 官方 advisory GHSA-998x-vgv…）。若走 NIO SSH，**必须 pin ≥ 0.14.1**。
- 作为客户端，该 CVE 的远程可利用性有限（主要影响暴露 SSH 服务端的应用），但它说明 NIO SSH 的安全响应节奏你需要跟踪，而这对一个长期维护的客户端是持续成本。
- Citadel 的上游维护活跃度也需要在选型前实际看一眼提交历史，不能凭印象。

**一条通用建议**：加一个 `SecurityBaseline.md` 到仓库，记录每个依赖的版本、下游 patch 状态、以及升级触发条件。这类客户端一年后一定会回来查这件事。

### 1.4 分发与沙盒的逻辑说反了，会影响本地存储层设计

方案原文："分发：先 Developer ID + 公证 / 沙盒下读写任意本地目录要处理授权，上架 App Store 放后面"，风险项又写"如果以后上 App Store，本地目录访问要用 security-scoped bookmark，现在设计本地路径时就别写死绝对路径"。

问题：**Developer ID 分发的 app 默认同样是沙盒的**（只要签了 `com.apple.security.app-sandbox`）。真正能自由访问 `~` 的做法是 Developer ID 签名 + **明确关闭沙盒**。所以"先 Developer ID 就没授权问题"是错的理解。真实的三个模式：

| 模式 | 沙盒 | 本地路径访问 | 适合 |
|---|---|---|---|
| Developer ID + 非沙盒 | 关 | 直接读写任意路径 | 最快出成果，功能最自由（**推荐的 MVP 模式**） |
| Developer ID + 沙盒 | 开 | NSOpenPanel 授权 + security-scoped **bookmark data** | 需要上架前迁移 |
| Mac App Store | 强制开 | 同上 + 更严的 entitlement 审核 | 最后考虑 |

方案的风险项结论对了（"别写死绝对路径"），但**没给出正确解法**：security-scoped 授权的载体是 **bookmark data（`URL.bookmarkData()`）而不是路径字符串**。如果本地存储层把路径存成 `String`，将来上沙盒就得做一次数据迁移 + 重新授权流程。

**现在就该做的**（成本几乎为零）：
- 本地存储里凡是本地路径，一律存 `bookmarkData`（或同时存 path + bookmark，迁移时可平滑）。
- `URL.startAccessingSecurityScopedResource()` 的成对调用封装在一个 `ScopedResource` 类型里，不要散落在业务代码里。
- **M0 就用非沙盒签名**跑通，别一开始就背沙盒的包袱。

---

## 2. P1：架构缺口

### 2.1 两条横切层在架构图里完全缺失

方案的架构图有 `Core/FileSystem`、`Transfer`、`Sync`、`Connection`，但缺了所有 SFTP/FTP 客户端都绕不开的两个模块。它们不是"以后再优化"，是 **M1 就要有**，因为它们决定协议方法的实现细节：

**① 路径规范化层（PathResolver）**

需要统一处理：POSIX 根、`~` 展开、`.` / `..` 回退、尾部 `/`、空路径、重复分隔符、**大小写敏感性差异**、symlink 展开深度限制。

最后一条是真正的坑：**macOS APFS 默认大小写不敏感，Linux 服务器敏感**。所以本地 `/Users/x/Foo.txt` 和远端 `/home/x/foo.txt` 在 SyncEngine 的路径对齐里会**指向同一个本地文件但不同远端文件**。这会让双向同步产生极难解释的行为（本地看起来"只删了一个大小写不同的文件"）。必须在 PathResolver 里显式声明两侧的大小写策略，并让 SyncEngine 的路径对齐**优先以远端为准**。

**② 字符集转换层（CharsetConverter）**

方案把"文件名编码"列为风险，但没进架构。它应该是统一入口，且要处理一个 UI 层的脏问题：**远端返回的字节序列不是合法 UTF-8 时，Swift `String` 会插入替换符 U+FFFD，此时路径已经不可逆地损坏了**（后续 rename / stat 全部会失败在错误的路径上）。

正确做法：在边界上把 `Data` 显式解码为目标 charset，**并对无法解码的序列保留原始字节**（UI 显示为 `\xNN` 转义或十六进制视图，路径操作走原始字节通道）。这要求路径类型不是 `String` 而是携带编码元数据的类型。方案里 `path: String` 一路到底，这个坑躲不掉。

### 2.2 取消 / 暂停的语义没有进协议

方案写了状态机 `pending → running → paused / failed / ...`，但没有定义**语义**。而这里有两个真问题：

**(a) 取消 Task 不会打断 libssh2。** `AsyncThrowingStream` 被 Task 取消时只是停止被消费，底层那个阻塞在 `libssh2_sftp_read()` 里的 C 调用**会继续跑**。表现为：点了取消，UI 上停了，网络上还在传，或者必须等它传完。这需要显式的打断机制（非阻塞模式下关闭 fd / `ssh2_channel_close`，或阻塞模式下用 `libssh2_session_set_timeout` + socket 超时）。

swift-ssh 的文档里那句 "task.cancel() 后 executed process will keep running on the server side" 就是这个问题的公开体现。

**(b) 暂停 ≠ 取消。** 暂停必须保留 `.part` 文件和已传 offset，且**下次续传要能验证远端没被改动**；取消则应删除 `.part`。方案里这两条没区分，实践中一定会出现"暂停后删了临时文件"的 bug。

建议协议里显式：

```swift
func transfer(from: RemoteHandle, to: LocalWriter, progress: @Sendable (TransferProgress) -> Void) async throws
// 取消 = 抛 CancellationError，调用方负责 .part 的存废策略
// 暂停 = 记下 offset，disconnect 后由 TransferQueue 重建并续传
```

### 2.3 SyncEngine 缺三方比较（base 快照），这是同步的核心难点

方案原文："两侧递归扫描，按相对路径对齐，生成差异：新增、修改、删除、冲突。"

这是**双向 rsync** 的思路，不是**同步**。它防不住最重要的情况：**本地改了 + 远端也改了**。没有 base 快照，引擎无法知道"这个差异是我造成的还是对方造成的"，于是要么静默覆盖一方（丢数据），要么把一切差异都标成冲突（不可用）。

正确模型：

```
base   (上次同步后双方一致的快照，存在本地 DB)
local  (当前本地)
remote (当前远端)

local == base && remote == base  → 无变化
local != base && remote == base  → 单向上行
local == base && remote != base  → 单向下行
local != base && remote != base  → **冲突**
```

`base` 里只需存 `(相对路径, size, mtime, 可选哈希)`，成本很低，但它是"冲突"这个概念存在的前提。方案没提 base，等于把同步引擎最难的部分留成了隐式假设。

**顺带**：判重策略应该分三档而不是"默认 size+mtime，可选哈希"：
- 默认：哈希（对中小文件），正确性优先 —— 因为本产品的用户是在传代码和配置，误判"没变化"会静默丢掉改动。
- 大文件 / 大量文件：size + mtime，但要接受 mtime 精度风险并明确告知。
- FTP 且服务器不返回可靠 mtime：强制哈希或标记为"低置信度，同步前请人工确认"。

### 2.4 双栏浏览的核心交互漏了：`NSFilePromiseProvider` 只覆盖了一半

方案第 4 节只写了"**拖出**到 Finder 用 `NSFilePromiseProvider`"。但双栏浏览的定义性交互是**左右互拖**：

- 从远端拖到本地面板 → 建上传任务
- 从本地拖到远端面板 → 建下载任务
- 从 Finder 拖入远端面板 → 建下载任务（这也是 `NSFilePromiseProvider` 的另一半，`filePromiseCoder` + `NSFilePromiseReceiver`）
- 从 Finder 拖入 → 拖的是**本地已有的文件**，这时不需要 file promise，直接读

漏掉的左右互拖是最大的工作量（要处理"拖到目录 vs 拖到文件"、批量、多选、冲突策略），却没进模块设计。这块建议单独排里程碑，别塞进 M4。

另外**多选拖拽的冲突策略**必须早定，不然 UI 逻辑会反复改：`3 个文件拖进一个已存在且同名的目录` → 合并 / 覆盖 / 跳过 / 全部重命名？业界默认是"合并目录，文件逐个询问或按预设策略"。

### 2.5 传输历史的存储选型：方案并列 SwiftData / GRDB 没给决策依据，且两者都可能过度设计

方案写"本地存储：SwiftData 或 SQLite（GRDB）"。但传输历史是**高频写入 + 复杂查询**的场景 —— SwiftData 在大量小写入上的性能不可靠，且早期迭代中 schema migration 很痛。

**我的建议是反直觉的：MVP 传输历史用 `Codable` + JSON 文件 + 原子替换（`Data.write(to:options:.atomic)`）**，根本不要数据库。理由：
- 传输历史在 MVP 阶段唯一的用途是"重启后恢复未完成的任务"和"看最近发生了什么"，都是**全量读取**场景，不需要索引和查询。
- JSON 文件对这个数据量（每天几千条）绰绰有余。
- 换来的是：零迁移成本、零 schema 演进、可版本控制、可导出。

等真的出现"按站点/时间/状态筛选"或"历史超过 10 万条"的需求，再上 GRDB —— 那时候你已经清楚 schema 长什么样了。

站点配置和收藏夹也建议先用 `Codable` JSON（或 SQLite），SwiftData 完全没必要引入。

### 2.6 测试策略缺了最关键的一项：后端契约测试

方案列了单测、注入故障、手工用例清单。但缺了保证这个架构**不腐化**的唯一手段：

> **同一套后端契约测试（conformance suite），跑在 SFTP 和 FTP 两个 backend 上。**

如果不这么做，"UI 和 Service 不知道具体协议"这个好抽象会在三个月内因为"FTP 少一个功能，我加个 if"而破掉。这套测试应该覆盖：
- 路径规范化（`..`、尾部斜杠、大小写、非 ASCII）
- 空目录 / 大目录 / 深层嵌套
- 文件名冲突与特殊字符（`:`、`/`、`*`、控制字符、超长名）
- 权限与 mtime 缺失时的降级行为
- 大文件往返一致性（哈希校验）

Docker 测试环境也不够。方案只提了 `atmoz/sftp`，至少还要有：OpenSSH 官方镜像（对照组）、`vsftpd` + `pure-ftpd`（不同 FTP 方言）、proftpd。**FTP 的行为差异大到必须多方言测试**，只测一个实现等于没测。另外需要一个 pyftpdlib 改造的 fixture 服务器，用来构造 GBK/Big5 文件名 —— 这类 bug 不可能靠真实服务器碰运气碰到。

再补一条 CI：这些测试必须跑在 CI 上，不能只在本地。集成测试挂了要能立刻知道。

---

## 3. P2：具体细节修正

### 3.1 文件列表：结论对，但建议不要"SwiftUI 做外壳"

方案："UI：SwiftUI 做外壳，文件列表用 AppKit 包装。"

"不要用 SwiftUI `Table`"的结论我完全同意 —— 但 SwiftUI `Table` 的问题不是性能，是**拖拽、多选、列头拖拽排序、右键菜单、Quick Look、就地重命名这些行为它要么不提供、要么要你手写一遍还不一定对**。这些恰恰是文件管理器的工作量主体。

"SwiftUI 做外壳"这个措辞会引导你用 `NSViewRepresentable` 在中间做一层双向数据同步 —— 这层是 bug 温床（`updateNSView` 里的 diff、selection 回环、滚动位置丢失）。

**建议的切法**（比"外壳 + 包装"更干净）：
- **文件列表 → 纯 AppKit**。`NSOutlineView`（不要同时上 `NSTableView` 和 `NSOutlineView`，前者是后者的子集，直接用 `NSOutlineView` 多列版就够），数据源直连 ViewModel。
- **窗口框架 / 工具栏 / 传输队列面板 / 站点管理 / 设置 / 同步预览 → SwiftUI**（`@Observable` + `@State`）。
- 二者通过一个明确的 `BrowserController`（`@MainActor`）交界，AppKit 侧不用 `NSViewRepresentable`，而是直接持有 ViewModel 引用。

理由：数据流是单向的（ViewModel 是唯一真相），`NSOutlineView` 的 dataSource 直接读它，SwiftUI 那半边也直接读它。没有中间同步层。

### 3.2 续传校验的判据不够

方案："续传前建议校验大小或修改时间，避免拼出损坏文件。"

不够。真实世界的 SFTP 服务器 mtime 精度可能是秒级（有些嵌入式 NAS 更差），FTP 的 `MDTM` 有的服务器根本不返回。**只看 mtime 无法区分"文件没变"和"文件在同秒内被改过"。**

可行的判据组合（写进代码注释里）：
1. 记录续传起点的 `(size, mtime)`。
2. 续传完成后再取一次 `(size, mtime)`，与第 1 步比对。
3. 不一致 → 标记"低置信度完成"并主动告知用户（可配置为自动重传）。
4. 若服务器支持哈希则直接校验（注意 SFTP v3 无哈希）。

另外：`.part` 文件应当在下载完成后**原子 rename** 到目标名。中断留下的 `.part` 绝不能出现在用户的目标目录里被误当成完整文件。

### 3.3 Keychain：三个具体的坑

1. **`kSecAttrAccessible` 会让后台传输在锁屏时崩。** 默认值是 `WhenUnlocked`，意味着用户锁屏后 Keychain 读取失败 → 传输中断。要用 `kSecAttrAccessibleAfterFirstUnlock`。
2. **只存口令，不存私钥内容。** 私钥引用 `~/.ssh` 里的文件路径（业界惯例，Transmit/ForkLift 都这么做），并支持 ssh-agent / 公钥类型。这样也避免了密钥导出风险。
3. **非沙盒 Developer ID 签名访问 Keychain 有身份一致性问题** —— app 重新签名后 ACL 失效，用户会突然发现"之前存的密码全没了"。需要处理这个 UX。

（这几条和你之前在 iOS 上遇到的"构建没链接 vs 模型文件有问题"是同一类错误的变体：**把不同成因的错误用同一句文案呈现，会诱导用户做完全错误的操作**。建议错误分类体系化：`.network / .auth / .hostKeyMismatch / .permissionDenied / .unsupported / .encoding / .localIO`，UI 分别呈现不同可操作提示。）

### 3.4 `Core` Package 应该完全不依赖 C 库

方案说"`Core` 拆成独立 Swift Package"。补一条：`Core` 里只放协议、模型、SyncEngine、TransferQueue（依赖纯 Foundation/Algorithms），**不要链接 libssh2/libcurl**。把它们放在上层 `Backends`（作为 `binaryTarget` 或 xcframework）。

理由：`Core` 无 C 依赖 → 单测可以在任意平台跑、CI 快、无需处理 modulemap/CocoaPods 的头文件地狱。libssh2 的 xcframework 打包本身就要花掉好几天，把它隔离在一个 target 里能把这个成本关起来。

### 3.5 断网/取消要贯穿所有循环

"可取消性"和"进度回调"在方案里只出现在传输路径。实际上**目录递归展开**（可能几千次 stat）、**哈希计算**（GB 级）、**差异计算**（几万条）这些循环里都必须检查 `try Task.checkCancellation()`。递归展开是最容易漏的 —— 一个 10 万文件的目录递归会让点取消按钮没反应。

### 3.6 外部编辑回传的 FSEvents 处理不完整

方案："下载到临时目录，用默认应用打开，`FSEvents` 监听文件修改，检测到保存后自动上传。"

问题：
- 现代编辑器普遍用**原子保存**（写临时文件 + rename），FSEvents 看到的是 rename 而不是 write。只监听 write flags 会漏。
- **默认自动上传是有风险的默认。** 如果远端在这期间被其他人改了，自动上传会覆盖别人的工作。方案提了"上传前对比远端修改时间"，但**冲突时怎么办没说**。正确行为是：检测到冲突 → 停止 → 明确询问，而不是"要么覆盖要么失败"。
- 建议改为"显式开关 + 明显的'正在监视'状态条 + 可手动触发上传"，比全自动体验更可控。

### 3.7 日志与可观测性被写成了 `Logger`

`Infra` 里只提了一个 Logger。这类产品 90% 的 bug 是环境相关的（某个服务器某个参数）。至少需要：

- **连接诊断报告**：一键导出（连接参数**脱敏后** + libcurl/libssh2 的 verbose log + 每步耗时 + 最终错误码）。这既是客服成本也是用户自助能力，比任何文档都有效。
- **日志分级 + 显式脱敏**：密码、私钥内容、以及"用户名是否算 PII"要定规矩。
- 错误码到人类可读建议的映射表（"EHOSTUNREACH → 检查网络/代理"）。

---

## 4. 被完全漏掉的功能（按"日用必需度"排序）

这些方案里一个字没提，但真实用户会立刻要：

| 功能 | 为什么重要 | 成本 |
|---|---|---|
| **`.ssh/config` 导入** | 解析 `Host / HostName / Port / User / IdentityFile / ProxyJump`。这是"日用工具"和"玩具"的分界线 —— 已有 SSH 配置的人零配置导入。 | 低（半天~一天） |
| **内置终端** | 大量 SFTP 用户其实想要 `ssh` 终端。libssh2 支持 exec channel + pty。但 macOS 上没有公开的 PTY API，得靠 `forkpty` + `Process`，工作量不小。 | **高（建议 v1.1）** |
| **隐藏文件开关** | macOS 惯例默认隐藏点文件，但服务器上 `.env`、`.git`、`.htaccess` 是刚需。必须默认显示或给一个显眼的开关。 | 极低 |
| **⌘⇧G 前往路径 / 可编辑路径栏** | 文件管理器基础能力，缺失很突兀。 | 低 |
| **权限/属主展示与修改** | SFTP 的核心价值之一（部署场景改 `chmod`）。FTP 侧置灰。 | 低（依赖 capability） |
| **列排序 + 列头拖拽** | AppKit 侧几乎免费。 | 极低 |
| **服务器 ↔ 服务器直传** | 见 §1.2(e)，纯协议层，成本低收益高。 | 低~中 |
| **ProxyJump / 跳板机** | 企业内网刚需。libssh2 有 `direct-tcpip` 支持但工作量不小，**必须明确排到 v1.0 之后，不能默认当作"有"**。 | 中~高 |
| **传输限速 / 定时条件传输** | 传大文件不QoS会影响日常网络。 | 低 |
| **站点分组 / 标签 / 最近连接** | 站点一多就必需。 | 低 |

**`.ssh/config` 导入我建议直接放进 MVP。** 它的成本（一个 INI parser + 字段映射）远低于它带来的用户满意度，而且它会顺带暴露你的认证设计是否想清楚了（`IdentityFile` 多条 → 多密钥尝试顺序 → passphrase 交互）。

---

## 5. 修正后的里程碑

原方案的 M0~M6 共 11~12 周。修正后的关键变化：**M0 增加技术 spike 并定死库**，M2 拆细，M3 承认它是最重的一块。

| 阶段 | 周期 | 交付 | 相对原方案的变化 |
|---|---|---|---|
| **M0'** | 1~1.5 周 | 工程骨架 + `RemoteFileSystem` 协议（含 capability + `RemoteItem` 完整定义）+ **libssh2 非阻塞封装 spike（3 并发通道 + 200ms 内打断 + 1000 小文件基准）→ 由此定死库** + Docker 测试环境（SFTP + 2 个 FTP 方言）+ **非沙盒签名跑通** + **算法兼容矩阵首版** | **新增 spike，这是最重要的改动** |
| **M1'** | 2~3 周 | 连接、认证（密码/密钥/**passphrase 回调/OpenSSH 新格式私钥**）、目录列表、单文件上传下载、`PathResolver` + `CharsetConverter` | 加密私钥解析（尤其 `-----BEGIN OPENSSH PRIVATE KEY-----` 这类新格式，libssh2 不直接支持）经常被低估，常见一周起步坑。文件名编码从"风险"提升为 M1 交付物 |
| **M2** | 2~3 周 | 双栏 UI（`NSOutlineView` + SwiftUI 混合切法）、站点管理 + **`.ssh/config` 导入**、Keychain（含 §3.3 三个坑）、主机指纹 | 增加 `.ssh/config`；指纹流程提前（它是连接流程的一部分，不是装饰） |
| **M3** | 3~4 周（**上调**） | 传输队列、状态机（含暂停/取消语义）、进度、ETA、重试、**`.part` + 原子 rename + 续传置信度校验**、崩溃恢复、限速 | 原估 2 周偏乐观。这是最容易做烂的部分，且依赖 M0' 的库定死结论 |
| **M4** | 2 周 | **左右互拖 + Finder 双向拖入**、Quick Look、外部编辑回传（显式开关式） | 拖拽拆出来单排，避免和其他功能挤在一起 |
| **M5** | 2~3 周 | FTP/FTPS 后端（含 charset 协商）、同步引擎（**base 快照 + 三方比较**） | 同步引擎工作量被严重低估（§2.3），需要真正的三方比较 |
| **M6** | 1~2 周 | **后端契约测试跑通两个 backend**、诊断报告导出、崩溃恢复验证、公证打包、Beta | 把契约测试提到 Beta 前，这是抽象不腐化的最后防线 |

**总量约 14~17 周**（原估 11~12 周）。多出来的 3~5 周买的是：库选型不再返工、不会出现"同步引擎静默丢数据"、能连上真实的老服务器。

**如果只能砍，我建议砍终端和 ProxyJump（挪到 v1.1+），不要砍 M0' 的 spike 和 M3 的续传置信度校验。** 后两个是"返工成本最高"的部分。

---

## 6. 需要你决策的问题（比原方案多，且更前置）

原方案的两个问题（库选型、最低系统版本）都问得太晚 —— 它们其实是 M0' spike 的**输出**而不是输入。建议改成：

**先定（阻塞 M0'）：**

1. **目标分发模式？** Developer ID + 非沙盒（推荐，最快）还是一开始就沙盒？这决定本地存储层是存路径还是存 bookmark data，改起来越晚越贵。

2. **首要目标用户是谁？** 这个问题的答案会显著改变优先级排序：
   - "我自己 + 团队日常传配置/代码" → `.ssh/config` 导入、权限修改、隐藏文件 权重要拉到最高，FTP 可以最后做甚至不做。
   - "要发布给大众的通用客户端" → 拖拽体验、Quick Look、同步预览权重要拉高。
   - "要在 App Store 上架" → 沙盒是第一天的事，原方案的整体节奏要重排。

3. **1GB 大文件 vs 1000 个小文件，哪个是你的真实主场景？** 这直接决定 M0' 基准测试怎么设计、原方案"用 1GB 文件跑基准"是否成立。

**M0' 结束时才能定（不要提前问）：**

4. libssh2（自建 event loop）vs Citadel/NIO SSH（现成 event loop）—— 取决于 spike 结果，不是"集成省事 vs 吞吐"。

5. **最低 macOS 版本。** 一个补充信息：原方案问这个是为了用不用 `@Observable`，但实际上还有个更硬的约束 —— **`NSOutlineView` + `NSTableView` 的很多现代 API（`diffableDataSource`、`selectionFollowsFocus` 之类）也需要 macOS 11+，`NSHostingView` 的行为在各版本有差异**。考虑到 macOS 15 已经普及，**建议直接定 macOS 14**（Sonoma）：`@Observable` 稳定可用，占用率已经足够高，能省掉大量条件编译。这比定 macOS 12/13 省事得多。

---

## 7. 一句话总结

**架构抽象（`RemoteFileSystem`）的方向是对的，但三个前提没解决：libssh2 的线程模型决定了 Core 层所有代码的写法、依赖的安全基线需要实际核对、分发模式决定本地路径怎么存。** 加上 SyncEngine 缺三方比较、双栏浏览缺左右互拖、以及传输历史的存储选型过度设计 —— 这五处是返工成本最高的。

最要紧的动作只有一个：**把 M0 从"搭骨架"改成"搭骨架 + 技术 spike 定库"**。这一条能省掉后面两周的架构返工。