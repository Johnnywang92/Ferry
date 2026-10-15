# Mac SFTP/FTP 客户端开发方案 v2.1 审查意见

> **评审日期**：2026年10月15日  
> **评审人**：@Johnny wang  
> **评审对象**：`Mac SFTP/FTP 客户端开发方案 v2.1`  
> **总体评价**：整体结构扎实，但 v2.1 新增的几处"纠偏"本身有误，而且恰好落在最关键的并发、路径、加密和同步四处，建议修正后再启动 M0'。

---

## 一、 认同的设计

1. **横切层优先**：`PathResolver`、`CharsetConverter`、`ErrorTaxonomy` 先于后端完成。
2. **两层能力表达**：`declaredCapabilities`（静态固有）与 `negotiatedCapabilities`（动态协商）。
3. **三方比较同步引擎**：引入 `base` 快照做三方对比，彻底告别单向/双向 rsync 盲猜。
4. **错误分类设计**：`notFound` 与网络抖动明确分离，避免重试与误删。
5. **契约测试保障**：一套测试跑通多后端，防止抽象被特定协议的特判击穿。
6. **架构分包解耦**：`Core` 零 C 依赖，C 库及其痛点全部隔离在 `Backends`。

---

## 二、 严重问题（建议 M0' 启动前修正）

### 1. "SFTP 单 session 只能开一个 SFTP 通道"是错的
* **问题剖析**：
  * SSH 本来就在一条连接上复用多个 channel，RFC 4254 从未限制单 session 只能有一个 SFTP channel。
  * OpenSSH 服务端的限制是 `MaxSessions`（默认 10），使用 `ControlMaster` 复用多个 sftp 会话是标准工业界常规用法。在同一 session 上多次调用 `libssh2_sftp_init()` 完全可行，只有超出 `MaxSessions` 时才会收到 `SSH_MSG_CHANNEL_OPEN_FAILURE`。
  * **真正的物理约束**：
    1. `libssh2` 的 session 句柄**非线程安全**（必须客户端自行做串行化调度）；
    2. 单条 TCP 连接上的 SSH 加密流（AES/ChaCha20）受限于单核 CPU 计算性能；
    3. SSH channel window 与分包大小会在长肥管道（BDP，高延迟大带宽链路）下压制单连接传输吞吐。
* **修正建议**：
  * 多 Session 连接池作为并发主选方案仍然成立，但理由必须从“协议不允许”纠正为**“并行多核加密与多 TCP 流跑满带宽”**。
  * 方案 B 的 pipelining 中，`libssh2` 的 `sftp_read` 本身带内部预读缓存，不必从零自建全部流水线逻辑。
  * 纠正原文档在 §6.1、§7.1、R1、差异 #31 中的错误表述。M0' 第一天在 `atmoz/sftp` 上对同一 session 连续调用两次 `libssh2_sftp_init()` 即可 10 分钟快速验证。

### 2. 阻塞 C 调用与 Swift 并发的冲突未处理（严重并发隐患）
* **问题剖析**：
  * 在 Swift `async` 函数中直接调用阻塞式的 `libssh2` C API，会长时间占满 Swift 协作线程池（Cooperative Thread Pool，线程数约等于 CPU 核心数）。3 个并发传输加上元数据拉取和 UI 交互，极易造成**线程池饥饿（Thread Starvation）**导致 UI 假死或任务挂起。
  * 原文档中提到的 `libssh2_session_set_abort_fn()` 在标准 libssh2 API 中**并不存在**。
  * **独占访问破坏（Exclusive Access Violation）**：原接口设计中 `RemoteReader` 声明为 `mutating func readChunk(...)` 和 `func cancel()`。如果在后台 Task 正在执行 `readChunk` 时外部并发调用 `cancel()`，直接触发 Swift 的独占访问违规导致 Crash。
* **修正建议**：
  * 读写句柄必须声明为 **`actor` 或 `final class: Sendable`**，绝不能是 mutating 值类型。
  * 采用**非阻塞模式 + poll/select 事件循环**：在 poll 循环边界主动检查 `Task.isCancelled`，这是取消操作在 200ms 内真正生效的最可靠机制；或者为每个 session 分配独立的底层串行 GCD 队列做执行隔离。

### 3. RemotePath：字节规范表示与 NFC 归一化互相矛盾
* **问题剖析**：
  * 在 Linux 服务端文件系统（ext4/xfs）上，**NFC 与 NFD 的同形文件名是作为两个完全独立的文件合法并存的**。
  * 若强制将 `rawBytes` 预先归一化为 NFC，会把远端两个不同文件强行折叠成一个，后续的 `stat`、`read`、`rename` 会直接打到错误或不存在的路径。
* **修正建议**：
  * `RemotePath` 必须**完整保留原始下发的 wire bytes**（`rawBytes`）。
  * 另外派生一个独立的 `nfcComparisonKey`（仅用于本地对齐、搜索索引和差异比对）。若发现同一目录下出现键碰撞，主动告警提示。
  * **补齐大小写碰撞检测（Case Collision）**：macOS APFS 大小写不敏感，远端同时存在 `Foo.txt` 与 `foo.txt` 时下载到本地会发生**静默覆盖破坏**。下载与同步引擎必须强制加入大小写碰撞阻断检测，不能只写“以远端为准”。
  * `casePolicy` 属于连接或文件系统能力，不应挂在每个 `RemotePath` 实例上。

### 4. Crypto Backend 一节有不实之处
* **问题剖析**：
  * `libssh2` 官方原生支持的加密后端包括 OpenSSL、wolfSSL、mbedTLS、libgcrypt、WinCNG 等，**官方根本不存在 Apple `Security.framework`（OSStatus）后端**。实际选型应是 OpenSSL 3.x vs mbedTLS。
  * `libssh2` 配合 OpenSSL 自身即完整支持 `openssh-key-v1`（含 bcrypt KDF 加密）的解析。
  * Swift 层预先解密并转 PKCS#8 是画蛇添足，还会导致解密后的敏感明文私钥长时间滞留在 Swift 托管内存中，扩大攻击面。
* **修正建议**：
  * 明确直接采用 **libssh2 + OpenSSL 3.x** 静态打包方案。
  * 删去 Swift 层前置解密转 PKCS#8 的冗余设计。

### 5. 同步引擎的判重默认值与真值表缺陷
* **问题剖析**：
  * 原方案“文件 < 64MB 默认哈希”极其危险：SFTP v3 协议**没有远端哈希计算命令**，这意味着每次同步都要把几万个小文件全部下载到本地算哈希，同步大项目直接不可用。
  * base 快照只存一份 mtime 不够：本地 APFS 是纳秒精度，远端 SFTP 是秒级精度，上传后远端 mtime 绝不等于本地 mtime。
* **修正建议**：
  * **参考 git index 机制**：base 快照分别记录 `localStat`（size, mtime）与 `remoteStat`（size, mtime）以及 content hash。同步时只要 `(size, mtime)` 与 base 一致且 mtime 可靠，即判定为未修改；仅在可疑或强制核验时才比对内容。
  * **补全三方比对真值表**：
    * 两侧同时改成相同内容（`local == remote != base`）→ **不应算冲突，判定为收敛一致，更新 base**；
    * 一侧删除，另一侧修改 → 报告「修改 vs 删除」冲突；
    * 两侧同时新建同名文件 → 内容相同收敛一致，内容不同报告「新建冲突」；
    * 文件与目录类型互换（同名文件变目录）→ 报告「类型互换冲突」。

### 6. CVE 编号与基线核实
* 文中引用的部分 CVE / GHSA 编号（如 CVE-2026-43798、GHSA-998x-vgv…）需核对官方原始 advisory 链接，避免凭记忆引入未确认条目。
* 从 git main 构建 libssh2 时，必须锁定明确的 commit hash 并写入基线。

---

## 三、 中等问题（对应里程碑前修正）

| 项目 | 问题原因 | 修正建议 |
|---|---|---|
| **Buffer 复用** | `readChunk` 返回 `Data` 无法真正复用缓冲；256KB 内存碎片被夸大 | 改造接口为 `read(into: UnsafeMutableRawBufferPointer) async throws -> Int`；先实测再优化，不作为 M3 阻塞指标 |
| **沙盒迁移** | "升沙盒无需迁移"夸大：Security-Scoped Bookmark 只能由用户通过 `NSOpenPanel` 交互生成 | 明确模式 A 存下的路径升级后需全部重新授权，补充重新授权引导交互流程 |
| **Keychain 策略** | `kSecAttrAccessibleAfterFirstUnlock` 针对 iOS 数据保护；macOS 登录钥匙串锁屏后默认不锁定 | 明确该属性在 macOS 下的使用边界，优先兼容标准 login keychain |
| **SSH 算法表** | `aes256-cfb` 极少使用，老设备刚需 `aes128-cbc` / `aes256-cbc`；`diffie-hellman-group1-sha1` 本身就是 1024 位 | 重构算法表，纠正弱算法口径，加入 CBC 模式支持 |
| **能力表核对** | SFTP v3 `rename` 默认不覆盖；服务端内复制在标准 SFTP v3/OpenSSH 中不原生支持 | 依赖 `posix-rename@openssh.com` 扩展；服务端内复制标为“不可用” |
| **上传 `.part`** | 原方案只写了下载侧；上传中断会在远端留下残缺文件 | 上传侧同样先写入远端临时文件名（如 `.upload-part`），传输完成原子 rename |
| **契约测试排期** | 原方案将核心保障的契约测试排在 M6 偏晚 | 提前至 **M1**，用 SFTP 后端和内存 Fake 开始伴随构建 |
| **ProxyJump** | §2、M2、可砍项之间口径冲突 | 统一口径：M2 支持解析与展示 `.ssh/config` 中的 ProxyJump；实际多跳隧道连接放 v1.1+ |
| **遗漏生产级特性** | 缺少日常高频功能 | 补充规划：`ssh-agent`（含 1Password 集成）、`keyboard-interactive` (2FA)、复用 `~/.ssh/known_hosts`、Sparkle 自动更新 |

---

## 四、 工期计算与文档卫生

1. **工期纠偏**：
   * 原文档各里程碑下限合计 16 周、上限 19.5 周，文档正文计算存在出入；且该时间为全职口径，业余时间开发需按 2~3 倍折算。
   * M0' 与 M1' 依赖顺序修正：将 `libssh2 + OpenSSL` 的 xcframework 自动化构建脚本前置为 M0' 的第一项任务（库编译不出来则后续 Spike 无法开展）。
2. **文档卫生**：
   * 修复文本排版中波浪线丢失导致的数字粘连（如 `8~9周`、`16~19.5周`）。
   * 消除差异清单中的重复项（#23 与 #24 重复提及 App Nap，#17 与 #3~#6 重复）。
   * 移除正文中的私人语境调侃（如 llama.cpp 相关文案）。
   * 修正代码签名指引：不再推荐 `codesign --deep`，应采用从内到外逐层组件签名；Hardened Runtime 为公证（Notarization）必须项。

---

## 五、 修订落地指引（v2.2 执行顺序）

1. **§6.1 / §7.1**：重写并发模型与取消（非阻塞 poll 循环 + 自定义 executor，纠正单 session 多通道为多核加密与带宽优化）。
2. **§4.4**：读写句柄协议改为 `final class: Sendable` 或 `actor`，提供 `read(into:)` 原生缓冲复用接口。
3. **§4.5**：`RemotePath` 保留原始 `wireBytes`，另派生 `nfcComparisonKey`，加入本地 APFS 大小写碰撞阻断。
4. **§6.6**：同步引擎全面参考 git index，双侧分别记录 stat，补全 4 类边缘情况真值表。
5. **M0' Spike 清单**：第 1 天先验证同一 session 连续 `sftp_init()`，再测非阻塞并发与 200ms 取消。
6. **基线核验**：固定 main 分支 commit hash，补齐所有 CVE 的官方链接。
