# Mac SFTP/FTP 客户端 · 方案演进与变更速查（v2.2 终版）

> 完整方案详见主方案文档：[`sftp-client-plan-v2.md`](file:///Users/yifanwang/workspace/Ferry/sftp-client-plan-v2.md) / [`sftp-client-plan-v2.2.md`](file:///Users/yifanwang/workspace/Ferry/sftp-client-plan-v2.2.md)。  
> 审查报告详见：[`sftp-client-plan-v2.1-review.md`](file:///Users/yifanwang/workspace/Ferry/sftp-client-plan-v2.1-review.md)。

---

## 方案演进总览

```
v1.0 (初始设计)
 └── 缺陷：无横切层、无契约测试、协议混装连接、缺少安全基线
v2.0 (全面重构)
 └── 贡献：引入三大横切层、协议与生命周期解耦、三方快照同步引擎、全量测试矩阵
v2.1 (专家首审)
 └── 贡献：代码级 Swift 6 actor 规范、外部编辑父目录防抖、排期聚焦
v2.2 (Johnny Wang 终审关键纠偏)
 └── 核心突破：
     1. 纠偏 SSH 多通道物理事实：多 Session 连接池是为了多核并行加密与突破 TCP BDP 吞吐，而非协议限制；
     2. 消除 Swift 协作线程池饥饿：非阻塞 poll 循环边界检查取消，避免阻塞 C 调用霸占协作线程；
     3. 修复句柄独占访问崩溃：RemoteReader/Writer 升级为 Sendable 引用语义，提供 `read(into:)` 原生缓冲复用；
     4. 解决 RemotePath 与 Linux 冲突：保留原生 wireBytes，仅派生 NFC 比较键；增加 APFS 大小写碰撞拦截；
     5. 修正同步引擎全量下载哈希陷阱：参考 git index 机制，双侧独立记录 Stat，实现免下载极速判重与完备真值表；
     6. 规范 Crypto 后端与算法白名单：静态打包 OpenSSL 3.x，原生解析 openssh-key-v1，补齐 CBC 兼容模式；
     7. 工期严谨核算：全职 16~19.5 周（业余 32~50 周），M0' 前置 xcframework 构建，契约测试提前至 M1。
```

---

## v2.2 核心纠偏对照清单

| 模块 | 原理解 / 前期缺陷 | v2.2 终版纠偏方案 | 核心价值 / 避坑依据 |
|---|---|---|---|
| **并发模型** | 误以为单 Session 无法开多个 SFTP 通道 | 纠正为 RFC 4254 事实。主推多 Session 连接池，理由是**多核并行加解密与突破单 TCP 流吞吐瓶颈** | 避免 Spike 目标偏离；M0' 首日 10 分钟验证同一 Session 多 channel |
| **Swift 线程安全** | 阻塞 C 调用直接跑在 `async` 函数中 | 采用**非阻塞模式 + poll/select 事件循环**，循环边界检查 `Task.checkCancellation()` | 彻底防止 Swift 协作线程池饥饿（Thread Starvation）导致 UI 假死 |
| **句柄独占访问** | 句柄声明为 `mutating struct` | 读写句柄定义为 `AnyObject & Sendable` 引用语义，原生支持 `read(into:)` 缓冲槽填充 | 杜绝并发调用 `cancel()` 触发 Swift 运行时独占访问冲突 Crash |
| **路径与编码** | 强制把路径字节转成 NFC | **原始 wireBytes 与 NFC 比较键分离**；保留原生字节发往远端；增加 APFS 大小写碰撞拦截 | 防止 Linux 上同形异码文件被错误合并；防止远端同名不同大小写覆盖 APFS |
| **同步判重** | <64MB 文件默认哈希 | **参考 git index 机制**：base 分别记录本地纳秒 Stat 与远端秒级 Stat，Stat 一致直接判未变 | SFTP v3 无远端哈希命令，避免为算哈希每次全量下载几万个小文件 |
| **同步真值表** | 缺少边缘状态定义 | 补全「双端同改一致性收敛」、「修改 vs 删除」、「新建同名」、「类型互换」等完整真值表 | 逻辑严密，防止正常改动误报冲突 |
| **Crypto 后端** | 误设想有 Apple Security 后端，Swift 层预转 PKCS#8 | 澄清官方无 Apple 后端，静态打包 **OpenSSL 3.x**；由 libssh2 原生解析 openssh-key-v1 | 消除虚假选型；避免私钥明文暴露在 Swift 托管堆内存扩大攻击面 |
| **SSH 算法白名单** | 出现稀有算法 `aes256-cfb`，弱算法口径矛盾 | 移除 CFB，加入老旧设备刚需的 `aes128-cbc`、`aes256-cbc`；支持弱算法用户开关 | 保证老旧 NAS/嵌入式 Linux 真实可连 |
| **双向原子性** | 仅下载侧提了 `.part` | **下载侧 `.part` + 上传侧 `.upload-part` + 远端原子 rename**（posix-rename 扩展） | 保证两端均不残留损坏或截断文件 |
| **契约测试排期** | 排在 M6 偏晚 | 提前至 **M1** 伴随核心开发启动（使用 SFTP 后端和内存 Fake） | 尽早构建防腐屏障，防止核心抽象被破坏 |
| **工期与执行顺序** | M1 才打包库，M0' 无法执行 | M0' 第一步前置编写 `build-libssh2-openssl.sh` 编译 xcframework；全职 16~19.5 周 | 消除依赖倒置，保证 Spike 第一天可执行 |

---

## 里程碑时间线（v2.2 全职口径）

* **M0'（2~2.5 周）**：xcframework 自动化打包 + 协议与横切层 + 非阻塞 poll Spike + OpenSSH 仿真环境
* **M1'（2.5~3 周）**：连接与认证（OpenSSL 原生私钥解析 + ssh-agent）+ 契约测试基座搭建 + 算法白名单
* **M2（2~3 周）**：双栏纯 AppKit UI + SwiftUI 外壳 + `.ssh/config` 导入 + known_hosts + 隐藏文件
* **M3（3~4 周）**：传输队列状态机 + 双向临时文件原子 rename + 续传置信度双采样 + 引用句柄缓冲复用
* **M4（2 周）**：拖拽 5 行矩阵 + 外部编辑父目录防抖监听 + Quick Look + 冲突策略
* **M5（2.5~3 周）**：FTP/FTPS 后端 + 多方言容器 + git-index 机制同步引擎
* **M6（2 周）**：双后端契约测试全绿 + 诊断报告 + Sparkle 自动更新 + 公证打包
* **总计**：全职 **16 ~ 19.5 周**（业余开发按 2~3 倍折算，约 32 ~ 50 周）。