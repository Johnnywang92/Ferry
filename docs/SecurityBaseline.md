# SecurityBaseline · 依赖与安全基线

状态：**M0b 骨架**（v2.3 §57 要求的产物）。已核实的内容在下面直接给结论；没核实的一律标 **待核** 并写明怎么核，**不进入结论**。
最后更新：2026-10-16

---

## 0. 这份文档的口径

- 每条依赖必须齐三样：**版本、钉死的 commit hash、已知 CVE 及其 advisory 链接**。缺链接的条目只能进"待核"列。
- CVE 原文只认 NVD 或项目 advisory 页；二手博客、扫描器报告不作依据。
- **advisory 的结构化字段不全 ≠ 没有修复 commit**。这条是被证伪过的教训，见 §4.3。
- 本文件的"结论"列只在实测或原文核过之后才填；否则填"待核 + 方法"。
- 依赖变化（升版、增删补丁）时，本文件与 `ThirdParty/versions.env`、`ThirdParty/patches/SHA256SUMS` 必须同批改；`versions.env` 的注释里已经写了这条要求。

---

## 1. 依赖清单

| 依赖 | 版本 | 钉死 commit / sha256 | 来源 | 用途 | 结论 |
|---|---|---|---|---|---|
| OpenSSL | `openssl-3.5.9`（3.5 LTS 分支） | `45e844fa2a14ec92d146bd8f5778ac130b6625fb` | `https://github.com/openssl/openssl.git` | libssh2 的 crypto 后端，静态链入 `FerrySSH.a` | 选 3.5 而非 3.6 的理由记在 `versions.env`：3.5 是 LTS（标准支持到 2030-04），3.6 是常规分支（到 2026-11）。**3.5.9 是否为该分支当时最新版：待核**（方法：`https://openssl-library.org/source/` 的 3.5 分支发布列表 + `https://openssl-library.org/news/vulnerabilities/` 逐条比对是否在 3.5.9 之前修复） |
| libssh2 | tag `libssh2-1.11.1` + 本地 10 条补丁 | 上游 commit `a312b43325e3383c865a87bb1d26cb52e3292641`；补丁集 sha256 `4d8d1f626103cce3445753ddff91296aa15121ea55a3dedc9ce5ac7c88cd6ead`；打完补丁的源码 tree `509f18c918deccf9731d15240b4642dcaf1124d8` | `https://github.com/libssh2/libssh2.git` | SSH/SFTP 协议栈 | **1.11.1 这个 tag 不带任何已知 CVE 修复**，10 条修复全在 master；靠 `ThirdParty/patches` 搬进来，见 §3 |
| CMake（仅构建期） | `3.31.12` | sha256 `799af7fd545db9bf1b9cfe72f8095880e727a2d4e0df0e3dffc3bc7b95c2d3b0`（官方随附 `cmake-3.31.12-SHA-256.txt`，不是下载后自算） | Kitware 官方 release 归档 | 交叉编译 OpenSSL/libssh2 | 不进产物：脚本下载到 `ThirdParty/build/tools`，不入包、不碰系统 PATH |
| Swift toolchain / SDK | 本机 Xcode，SDK 27.0，deployment target 15.0 | 未钉 | 本机 | 编译 | **待核**：构建可复现性目前锚在源码三件套（§6），工具链版本只在 `provenance.txt` 里记录不校验 |

架构与产物形态：fat（arm64 + x86_64）静态归档 `FerrySSH.a`（约 21 MB），**运行期不依赖任何第三方动态库**——这条是签名基线的前提，见 §7.1。
> `build-xcframework.sh` 默认出 arm64+x86_64 双切片（`--arch arm64` 可只出单切片），而 S3 决策是"交付仅 arm64"。两者不冲突但也没对上：留 x86_64 只是脚本默认值，不是安全决定，裁剪与否列 §8 待核 9。

## 2. 已知 CVE：v2.3 §78 列的那几条

v2.3 把 5 条 CVE 全标"待核"（GHSA 编号被截断、部分描述可疑）。本轮核完 4 条，纠正 1 条：

| CVE | v2.3 的怀疑 | 核实结果 |
|---|---|---|
| CVE-2025-15661 | 待核 | **libssh2，已搬**（补丁 0008，GHSA-3wqh-87fg-ffgg，High）。改的是 `sftp_symlink()`，**并且改变了返回值语义**，见 §5 |
| CVE-2026-7598 | 待核 | **libssh2，已搬**（补丁 0003，GHSA-jhp3-h4hp-2c3p，Medium，`src/userauth.c`，干净搬运） |
| CVE-2026-55199 | 待核 | **libssh2，已搬**（补丁 0004，GHSA-3cfq-4xx4-rmpg，High，`src/packet.c`） |
| CVE-2026-55200 | 待核 | **libssh2，已搬**（补丁 0001，GHSA-r8mh-x5qv-7gg2，Critical，`src/transport.c` 的 `ssh2_transport_read()` 越界写）。CVE 记录页摘录（本轮经搜索取得，页面原文未整页取回）为"libssh2 through 1.11.1, fixed in commit 7acf3df … out-of-bounds write in ssh2_transport_read()"⇒ 影响范围含 1.11.1，且是**客户端读服务器包**的路径。**该页把修复 commit 写成 `7acf3df`，这个 sha 在本地 clone 里解析不出**（不是任何对象的前缀），真实 commit 是 `97acf3dfda80…` ⇒ 原文本身就有笔误，不是我们读错（验证方式见 §4.1） |
| CVE-2026-43798 | 待核，描述可疑 | **不是 libssh2 的**：多个库（NVD 条目、Tenable、Vulners、Strix）一致标为 `swift-nio-ssh`（0.14.1 修复：单条构造的 SSH 消息造成越界栈写）。本项目不用 swift-nio-ssh ⇒ 对本依赖集不适用。**但 CVE 记录页原文本轮没取到（取回被限流），按本文件口径这条仍是待核**（§8 待核 2 覆盖它：开 `https://www.cve.org/CVERecord?id=CVE-2026-43798` 确认产品名与受影响范围后关闭）。**内部佐证**：废弃的 `sftp-client-plan-v2.2.md` §128 当时写的就是"NIO-SSH 漏洞跟踪：必须 `>= 0.14.1`（修复栈越界风险）"——和搜索结论对得上。也就是说 v2.3 §78 标"描述可疑"的那条，成因是 NIO 的需求被混进了 libssh2 的 CVE 清单，不是编号被截断 |

## 3. libssh2 补丁系列（10 条，全量搬运）

清单与手工适配细节的权威版本在 `ThirdParty/patches/README.md`；这里保留可核对的骨架与安全相关字段。等级取各条 advisory 页标注，**CVSS 向量未逐条从 NVD 复核 → 待核**。

| # | 补丁文件（sha 前 12 位为上游 commit） | GHSA | CVE | 等级 | 组件 | 核实状态 |
|---|---|---|---|---|---|---|
| 0001 | `0001-97acf3dfda80.patch` | [GHSA-r8mh-x5qv-7gg2](https://github.com/advisories/GHSA-r8mh-x5qv-7gg2) | 2026-55200 | Critical | `src/transport.c` | GHSA↔commit↔CVE 已对齐；NVD 原文 **待核** |
| 0002 | `0002-5e4776146552.patch` | [GHSA-83r8-6c29-8gwr](https://github.com/advisories/GHSA-83r8-6c29-8gwr) | 2026-66032 | High | `src/sftp.c` | 同上 |
| 0003 | `0003-256d04b60d80.patch` | [GHSA-jhp3-h4hp-2c3p](https://github.com/advisories/GHSA-jhp3-h4hp-2c3p) | 2026-7598 | Medium | `src/userauth.c` | 同上 |
| 0004 | `0004-17626857d20b.patch` | [GHSA-3cfq-4xx4-rmpg](https://github.com/advisories/GHSA-3cfq-4xx4-rmpg) | 2026-55199 | High | `src/packet.c` | 同上 |
| 0005 | `0005-a13bb6c773f0.patch` | [GHSA-6h6q-9mwg-r6x7](https://github.com/advisories/GHSA-6h6q-9mwg-r6x7) | 2026-66034 | High | `src/publickey.c` | 同上（advisory 结构化 `patches` 字段为空，commit 取自正文） |
| 0006 | `0006-a2ed82d40964.patch` | [GHSA-2g8c-wcg8-r65c](https://github.com/advisories/GHSA-2g8c-wcg8-r65c) | 2026-66033 | High | `src/openssl.c` | 同上（`patches` 字段亦为空） |
| 0007 | `0007-42e33d81577e.patch` | [GHSA-v6rf-8q4r-r495](https://github.com/advisories/GHSA-v6rf-8q4r-r495) | 2026-66035 | High | `src/transport.c` | 同上 |
| 0008 | `0008-2dae3024897e.patch` | [GHSA-3wqh-87fg-ffgg](https://github.com/advisories/GHSA-3wqh-87fg-ffgg) | 2025-15661 | High | `src/sftp.c` | 同上，且**行为变更**见 §5 |
| 0009 | `0009-34497525929b.patch` | [GHSA-mf77-5hj2-98w9](https://github.com/advisories/GHSA-mf77-5hj2-98w9) | 2026-58050 | High | `src/publickey.c` | 同上（曾误判为"无法搬运"，见 §4.3） |
| 0010 | `0010-a9758da45a52.patch` | [GHSA-c5f3-hwj2-xp5p](https://github.com/advisories/GHSA-c5f3-hwj2-xp5p) | 2026-58051 | High | `src/publickey.c` | 同上 |

搬运的完整性判据（不是"看起来都打了"）：

- `build-xcframework.sh` 先校验 tag 与 commit 一致，再按编号顺序 `git am`，**补丁集哈希变了就强制重编 libssh2**。
- 头文件没被动过（10 个补丁的 diff 清单里没有 `include/`），所以 API 面与原版 1.11.1 相同；`Spike/Scripts/api-probe.sh` 在打完补丁的产物上仍是**声明 23/25、定义 23/25**，缺的还是 `libssh2_session_set_abort_fn` 与 `libssh2_transport_set_sendsize`。
- **已知 CVE 清零**这句话只对"这 10 条公告"成立。新公告是否已发布、1.11.2 是否已出：**待核**（方法：`https://github.com/libssh2/libssh2/security/advisories` + OSV `https://osv.dev/list?ecosystem=OSS-Fuzz`/`gh api security-advisories`）。
- 上游 master 上还有 Homebrew 额外搬的 OSV/fuzz 修复（**不是 CVE**）。本期不搬；要不要搬是 M1 的一个决定，列 §8 待核。

## 4. 核实过程中踩到的坑（写下来是为了下次别照着 advisory 就下结论）

1. **CVE 记录页显示的 commit 可能是错的**：页面写 `7acf3df`，而 `git cat-file -e 7acf3df^{commit}` 在本地 clone 上**解析失败**；真实 commit 是 `97acf3dfda80c91c3a8c9f2372546301d4a1a7a8`（主题 `transport.c: Additional boundary checks for packet …`）。注意 `7acf3df` 是真实 sha 的**中段子串**（偏移 1 起），不是前缀 —— 所以拿它当 abbreviated sha 去查永远查不到，而肉眼看又"像是同一个"。以后按 advisory 页对 commit，先取整页链接指向的完整 sha，别取显示文本。
2. **tag 是附注标签**：`git ls-remote --tags --refs` 给的是 tag 对象的 sha，checkout 出来的是它指向的 commit，拿前者校验永远报"commit 不符"。正确取法 `git ls-remote <repo> "refs/tags/<tag>^{}"`（已写进 `versions.env` 注释）。
3. **"API 查不到 commit" ≠ "没有 commit"**：0009/0010 在 GitHub 结构化 `patches` 字段里是空的，早期结论因此写成"这两条无法搬运"——实际存在且能搬。**证伪方式是跨一个独立供应商的清单**：Homebrew `libssh2-1.11.1_7` formula 给这两条分别备了 backport patch 并标 `resolves`。
4. **"cherry-pick 成功" ≠ "编得过"**：0005、0009 都栽在 master 的助手名（`ssh2_err`）与宏（`LIBSSH2_UNCONST`、`SSH2_SAFEFREE`）在 1.11.1 不存在上。手工适配记在 `patches/README.md` 的"搬到 1.11.1"列。
5. **判据不能写死**：`spike paths` 曾把"symlink 返回码不可信"写死在代码里，换产物后（未打补丁 vs 打过补丁）结论直接说反话；现在按实测数据打判定。同类教训：M0b-01 的汇总行漏减"双方都拒绝"，把 20 条报成 21 条。

## 5. 补丁带来的行为变更（安全修复的副作用，必须进基线）

`libssh2_sftp_symlink_ex()`：**未打补丁的 1.11.1 建链成功回 `rc=0`；打上 0008（CVE-2025-15661）后成功也回 `rc=-31`，`sftp_last_error` 是 71–134 这类越界值（合法上界 21），而链实际建成了。**

- 实测范围：2201（atmoz chroot）/2202（Debian openssh）/2203 三台、16 条用例，判定分布一致，可复现。
- 后端约束：**建链不能信返回码，必须 `lstat` + `readlink` 回读判定**（`ErrorTaxonomy` 已按这条实现：越界 status 不判成协议违规，否则每次成功建链都会杀掉会话）。
- 这不是回归：越界读被修掉之后，原来"碰巧读到 0"的路径改成报错，属预期副作用。
- 换产物必须重测这一条（M0b-03 就是这么翻出来 0008 的语义影响的）。

**根因（2026-10-16，M1-05 §9 在五台上用原始 C 逐发实测定位）**：0008 重写后的 `sftp_symlink()`
在 `SSH_FXP_STATUS` 分支里、type 之后只 `_libssh2_get_u32` **一次**，而 wire 上 type 后面第一个
u32 是**请求 id**，状态码在它后面那一格；打补丁前的写法是 `_libssh2_ntohu32(data + 5)`（跳过 id）。
所以上面那串 71–134 就是请求序号，不是损坏的状态码。三个可复现后果：

| 后果 | 表现 | 安全含义 |
|---|---|---|
| 序号落进 `0…21` | `2` 被读成 `SSH_FX_NO_SUCH_FILE`、`3` 读成 `PERMISSION_DENIED`、`7` 读成 `CONNECTION_LOST` | **误判 `notFound` 会让同步引擎删掉本地文件**；误判 `connectionLost` 把确定性失败变成可重试 |
| 序号恰为 `0`（`symlink_ex` 是该 `LIBSSH2_SFTP` 的第一个请求） | 失败被读成 `SSH_FX_OK` → `rc=0` 的**假成功**，出参缓冲一格没写 | 调用方拿到"成功 + 空目标"，比报错更坏 |
| 序号 `>21` | 越界值（本轮的 71–134、生产路径的 33–45） | 无成因可报，只能判"不明确" |

`src/sftp.c` 里**只有这一处**状态分支被改坏：`stat/lstat/open/readdir/mkdir/rmdir/unlink/rename/statvfs`
仍是正确的 `data + 5`（上游 master 至今同样错，且比我们多错一格 NAME 分支，我们的补丁已修）。
因此本基线的处理边界是：**产品侧不采信 `symlink_ex` 那一族的任何状态码**（走链段探测 lstat 先行；
该族失败一律 `undetermined` 并硬拆连接），而不是把它当成可以靠重试或改分类绕过去的小毛病。
上游修复与本地补丁 0011 的取舍见 §8 待核 27。

## 6. 产物完整性与可复现性

- **可复现性锚在源码三件套**，不是产物哈希：tag+commit / 补丁集 sha256 / 打完补丁的源码 tree hash（值见 §1）。实测 `libtool -static` 会给归档成员写当下时间戳，同源码连跑三次 `FerrySSH.a` 哈希都不同 ⇒ `provenance.txt` 里那个 `b5791d13…` 只是**本次构建实例的 ID**，不能当校验和用，也不能用来判"两次构建等价"。
- 校验位置：`Packages/Backends/Vendor/provenance.txt`（构建时间、主机、SDK、三件套、cmake 哈希、产物大小）。
- **旧二进制风险**（真实事故，不是假想）：SwiftPM 的 `--build-path` 与既有 `buildPath` 配置叠加后，新产物落在 `.build/out/out`，执行的却是旧文件，导致一整轮"补丁版复测"实际跑在未打补丁的库上。防线是 `Spike/Scripts/verify-linkage.sh`：**拿补丁独有的字符串字面量比对 vendor 归档与二进制**（`ListFetch data too short` ← 0005、`username_len out out of bounds` ← 0001、`Too many publickey attributes` ← 0009），比内容不比时间。
- 产物不入库（`Vendor/` 已 gitignore），**构建脚本是唯一可信来源**。任何"我本地这份对不对"的问题以 `provenance.txt` + `verify-linkage.sh` 为准。

## 7. 运行时安全基线（签名 / Hardened Runtime / 凭据）

来自 `docs/spike/M0b-04-签名与Hardened-Runtime走查.md` 的实测，全部在 ad-hoc + HR、macOS 26.6.2（25G83）、`spctl --status` = assessments enabled 下测得。

### 7.1 签名

- 逐层由内向外签名，**不使用 `--deep`**；当前产物嵌套代码 0 个，循环空转。
- `App/Support/Ferry.entitlements` **必须是空 `<dict/>`**：文件里明确禁止提前加 `com.apple.security.cs.disable-library-validation` 与 `com.apple.security.app-sandbox`。加例外要有本节级别的实测理由，不接受"以后可能要"。
- HR 下 library validation 拦的是 **Team ID，不是文件位置**：第三方 dylib 复制进 bundle 并由内向外重新 ad-hoc 签名后 `dlopen` 仍被拒。⇒ 静态链接是当前唯一能装第三方代码进可运行产物的形状；任何 dylib 化依赖（典型：Sparkle）都需要先做一次"要不要开 `disable-library-validation`"的显式决定。
- DYLD 注入需要**两个**开关：只开 `allow-dyld-environment-variables` 仍被挡（注入体过不了 library validation），再加 `disable-library-validation` 才成功；`get-task-allow` 对此无用。
- `--timestamp` 不能对 ad-hoc 用（拿不到 secure timestamp），脚本只在有真身份时加。
- **Bundle ID 用临时值 `local.ferry.Ferry` 到 M2 前**（2026-10-16 定案）。它同时是 Keychain 条目的归属与 Sparkle 的更新标识，正式反域前缀到位后，M0b-04 §6 那种"换 Identifier 仍能读回"的便利**不能当作改名安全的依据**——见 §7.2 的代价清单。

### 7.2 凭据存储（已定案：登录钥匙串）

| 路径 | ad-hoc 下的实测 | 影响 |
|---|---|---|
| 登录钥匙串（file-based，`kSecUseDataProtectionKeychain=false`） | 读写通；换 cdhash / 换 entitlements / 换签名 Identifier / 脱离 bundle 四种身份变化后**都能读回同一条目** | 能用，但没有数据保护类，条目会随登录钥匙串被备份/迁移带走 |
| data-protection 钥匙串 | 一律 `err -34018`（errSecMissingEntitlement）；**补 `keychain-access-groups` 后签名能吃下这个 entitlement，但进程在 exec 阶段被 SIGKILL（rc=137，无输出、无崩溃报告）** | ad-hoc 阶段无解。要用它就必须有真实签名身份（`Apple Development`/`Developer ID`） |

⇒ "重建后 Keychain 条目失效"这个担心在登录钥匙串这条路**没被观察到**；真正卡住的是 data-protection 完全不可用。

**定案（2026-10-16，ADR-0000 §8 V3）**：M2 用**登录钥匙串**，`SecItem*` 一律不传 `kSecUseDataProtectionKeychain`（默认即登录钥匙串）。随这条定案一起接受的代价：

- 没有数据保护类可用，密码项会随登录钥匙串被备份、迁移到另一台机器；
- ACL 形状本轮没读到（§8 待核 6），"换 cdhash 仍读得回"是**行为观察**不是机制结论——换机器、macOS 升级或用户改钥匙串设置后不能假定照旧，M2 的凭据测试要**把这条重新跑一遍**而不是复用本节。
- 后续拿到真实签名身份时若要迁到 data-protection 钥匙串，得写**显式搬迁路径**（两个是不同的库，改 flag 不会带走已有条目），并先闭合 §8 待核 7。

### 7.3 分发（本期不可验证）

- 本机 `spctl --assess` 对 ad-hoc+HR 产物报 **rejected**，但带隔离位的**新副本** `open` 直接跑起来（flag 值 `0002/0081/0083/0181`、两个从未启动过的 bundle id 都试过）。
- 对照组：同一份产物**去掉签名** + 隔离位 → `open` 失败（launchd spawn failed，POSIX 163），说明隔离位与签名检查确实在工作 ⇒ 被绕过的是 Gatekeeper 的"未识别开发者"这一层，本机测不出真实分发体验。
- 本期按 ADR-0000 §5 走 GitHub Releases + Pages，**README 必须附未公证产物的 Gatekeeper 放行说明**；真实体验在 M6 前用干净机器/VM 复测。

### 7.4 网络与协议面

- **主机密钥：TOFU + 兼容 `~/.ssh/known_hosts`（2026-10-16 定案，ADR-0000 §9 N3）**。首次连接询问并写入自建存储；`known_hosts` **默认只读**，写入要用户显式同意。实现上要覆盖的真实形状：hash 主机名（`|1|` 行）、同一主机多算法多行（挑与本次协商一致的那条，否则误报"密钥变了"）、文件权限与并发写；`@cert-authority` 与 `certs@openssh.com` 主机密钥证书本期不支持 → 遇到时按未知主机处理并说明原因。**"密钥变了"必须是硬阻断且不可一键跳过**，这是 TOFU 模型唯一的价值所在。
  - **判定位置被 libssh2 定死**：它没有 hostkey 回调，密钥只能在 `libssh2_session_handshake()` 返回后用 `libssh2_session_hostkey()` 取（M1-02 §6.1）。所以信任判定只能落在"KEX 之后、认证之前"，实现照此摆放并有测试盯住（拒绝时 phase 转 `aborted`、握手不返回成功）。代价：中间人此时已能看到流量，但凭据一个字节都不发。
  - **查表键是 blob 头部的算法名（`wireType`），不是协商名**（M1-03 §3.1）。RSA 上两者必然分家：签名谈成 `rsa-sha2-512`，known_hosts 第三字段仍是 `ssh-rsa`。拿协商名查表会把 RSA 主机的正常重连误判成"这台只有别的算法"。
  - **与真 OpenSSH 双向互认已实测**（M1-03 §3.2/§3.3，两组都在 `FERRY_LIVE_SERVERS=1` 下跑）：`ssh` 亲手写的行 Ferry 0 弹窗直接可信且文件字节不变；Ferry 写的行 `ssh-keygen -F` 查得到，且 `StrictHostKeyChecking=yes` 的 `ssh` 拿它当唯一信任来源能一路走到认证、不打任何主机密钥警告。非 22 端口两边都写 `[host]:port`（端口在方括号外面）。
  - 指纹格式已与 OpenSSH 对齐：`SHA256:` + 线路 blob 的 SHA-256 去填充 base64，五台逐台与 `ssh-keygen -lf` 一致（M1-02 §3.4）。TOFU 对话框里显示的指纹因此可以直接和用户终端上 `ssh` 打印的对照。
  - `@revoked` 优先于任何合法行，容器实测三种 `StrictHostKeyChecking`（ask / accept-new / yes）全部拒连，Ferry 同样硬阻断（M1-03 §2）。
  - **与 OpenSSH 的两条有意行为分歧（本轮实测坐实，不是推测）**：① OpenSSH 会按 known_hosts 里已有的类型**重排 KEXINIT 的主机密钥偏好**（同一台 2202：表里只有 rsa 行 ⇒ 谈成 `rsa-sha2-512`，只有 ed25519 行 ⇒ `ssh-ed25519`，只有 ecdsa 行 ⇒ `ecdsa-sha2-nistp256`），libssh2 不读表，谈成哪个算哪个 ⇒ `.otherAlgorithm` 这一格必须存在，且它只是提示级别、不是密钥变更。② OpenSSH 客户端默认把全部 `*-cert-v01@openssh.com` 排在偏好最前，CA 不受信时打 `No matching CA found. Retry with plain key` 并把**证书里的叶子公钥当普通密钥写进 known_hosts**；Ferry 不做这个降级 ⇒ 同一台开证书的服务器上两个客户端信的**不是同一把密钥**M1-03 §5 那台一次性容器上测得 `ssh` 侧信 ed25519 叶子（`SHA256:64yFpb9y…`）、Ferry 侧拿到 ecdsa（`SHA256:pr+Xfe2H…`；两值随该容器重建而变，不作固定向量）。共存场景下"这台主机已被信任"对两边含义不同，列 §8 待核 17。
  - 交叉验证老服务器时注意：本机 OpenSSH 10.3 对 2203/2204 **`ssh-keyscan` 拿不到 key**（唯一那条 DH-SHA1 KEX 被本机拒绝），必须在容器内或用放开老算法的客户端配置验证，否则会误判成"服务器没密钥"。
- 弱算法（S6：CBC、`ssh-rsa`/`ssh-dss`、`hmac-sha1`、DH-SHA1）白名单 + "允许弱算法"UI 开关 → 实测矩阵写 `docs/AlgorithmMatrix.md`（M1' 产出，本文件只放指针）。老设备仿真题式有两条（配置白名单版 + 真老镜像版），两者结论分开记，不许互相顶替。**M1-02 实测把这条的前提改硬了**：libssh2 1.11.1 的**默认偏好集本身就允许四类弱算法**——不带任何策略时 2204 直接谈成 `dh-group14-sha1` + `ssh-rsa` + `aes256-cbc` + `hmac-sha1`（M1-02 §3.1）。所以白名单不能指望库来兜，必须由 Ferry 自带一份；且 `method_pref` 会**静默剔除**它不认识的名字（只有整串剔空才 `-33`），"写了策略"不等于"策略生效"⇒ 连接层加了事后反查：实际协商值越出策略就判协议违规（M1-02 §6.2）。反查只防"被放宽"，防不了"被抹掉一条偏好"，后者要靠待核 15。
- 另一条来自同一轮：**老服务器不等于必须弱算法**。真老发行版 2205（OpenSSH 6.7p1 / OpenSSL 1.0.1t）能谈成 `curve25519-sha256@libssh.org` + `ssh-ed25519` + `chacha20-poly1305` + `hmac-sha2-512-etm`。"兼容老设备"的承诺因此可以写成"默认现代 + 显式开关放开老算法"，而不是默认陪跑 SHA-1。
- 取消与超时的实测边界（M1-02 §4）：黑洞监听下置标志 → 握手抛出 3/37/48 ms（切片 50 ms），300 ms 预算 301 ms 生效，取消后 `close()` 0 ms（不补体面关闭，M0a-03 那条路 8.05 s）。这三格是 ADR-0001 D3/D4 在握手阶段的验收数字。
- **仿真环境已落地为五台**（2026-10-16，M1-01）：2201 atmoz(实际是 OpenSSH 8.4p1)、2202 modern(9.7)、2203 legacy(9.7，**留了 dh-group14-sha256 兜底**，所以它从没真正走过 SHA-1 KEX)、2204 oldalgo(9.7，每个维度只剩一条老路)、2205 oldos(**OpenSSH_6.7p1 Debian-5+deb8u4 / OpenSSL 1.0.1t，真老发行版**)。两条纪律由此而来：矩阵的服务器列**只能按线路实测**，`sshd -T` 给的是编译支持全集而非 offer（2205 上差集包含全部 CBC、`hmac-md5`、`dh-group1-sha1`）；`ssh-dss` 这一格只有 2205 能填，且必须从容器里的客户端测（本机 OpenSSH 10.3 已把 DSA 编译掉）。
- **认证层（M1-04）三条与凭据处理有关的基线**：
  - **探测服务器方式本身要花额度**：`libssh2_userauth_list` 每调一次就发一条 `USERAUTH_REQUEST(method=none)`，服务器按 `MaxAuthTries` 记账、不分方法（实测只调它，第 7 次被 `MaxAuthTries 6` 踢掉）。所以每条连接只探一次并把清单缓存在连接上（不跨连接复用）；实测这条让同一台 2202 上用户能犯的口令错误从 3 次变成 5 次。
  - **清单只能用来排除方式，不能用来承诺方式**：2201 的清单里有 `keyboard-interactive`，却一条 `INFO_REQUEST` 都不发（拿回 `-18`）；反过来"列出了 password"也不证明该账号存在（不存在的用户名照样列出同一份清单）。UI 若照着清单画"等待服务器提示"就会转圈到超时。
  - **认证失败不拆 transport**（`.auth` / `.localIO` ⇒ 会话留 `.ready`）：免掉 TCP + 密钥交换 + 那次探测，实测同连接第二次尝试 8 ms。但每发一次凭据就烧一格额度，所以 `.auth` 一律不进 `isRetryable`——"会话还能用"与"可以自动重试"是两件事。
- **私钥的码只有一枚**：两条入口（`frommemory` / `fromfile`）× 五种语料 × 三种口令共 31 格，凡是解析不出可用键一律 `-16 LIBSSH2_ERROR_FILE`；`-48 KEYFILE_AUTH_FAILED` 在本产物里**到不了**（`_libssh2_pub_priv_keyfilememory` 只看内层是否为 0，非 0 一律换成 `-16`；能把口令错单认出来的 `HAVE_SSLERROR_BAD_DECRYPT` 未定义）。⇒ 换 crypto 后端（mbedtls / 无后端）时这一枚会回来，`ErrorTaxonomy` 的 `-48` 三行为此保留。分流靠**只读头部**的探针，Swift 层不做任何预解密，也不把私钥写进临时文件；`libssh2` 的文案在两条入口下不同（`Unsupported private key file format` vs `Wrong passphrase or invalid/unrecognized…`），**不许拿文案做分类**。
- **ssh-agent 的已知取消上限（本期不修）**：`agent_connect` / `agent_list_identities` 走阻塞的 Unix socket（agent.c:110 明写未实现非阻塞）。实测对面只 listen 不回话时 `agent_connect` 照样回 0，`list_identities` 5 s 没返回 ⇒ agent 那条路上"置标志到停下"的粒度是"等这一步自己回来"，不是 50 ms 切片。产品对策：选 agent 登录时要有明确等待态与"改用密钥文件"的出口（#25）。失败码分开：无 `SSH_AUTH_SOCK` ⇒ `-39` ⇒ `agentUnavailable`（要修的是本机环境，不是服务器上的 `authorized_keys`）；socket 指向不存在的文件 ⇒ `-42`。
- **失败比成功慢得多这一格只在真老发行版上复现**：2205（五台里唯一 `UsePAM yes`）错口令 2356 / 2345 ms 两轮，同一次成功 346 ms；另外四台成败都在同一量级（2202 有一次 632 ms 未复现，不记为结论）。`authenticationTimeout` 30 s 装得下，但用户连错三次会看到约 7 秒的等待——对话框必须显示进行中，否则长得像卡死。
- 认证阶段的取消粒度实测（M1-04 §7）：bcrypt 解私钥期间置标志 → 抛出 135 ms（对照组认证本身 415 ms；纯 CPU 那一段没有 poll 边界，与 M0a-03 同一条上限）；等用户答题期间置标志 → 77 ms 返回（≈1.5 个切片），代价是那次空应答还是发出去了。
- FTP/FTPS 的 TLS 校验与明文传输风险：**未开工**，本节留空。
- 代理 / ProxyJump 的信任链变化：v1.1+ 范围，暂不适用。

## 8. 待核清单

| # | 项 | 方法 | 阻塞什么 |
|---|---|---|---|
| 1 | OpenSSL 3.5.9 是否仍是 3.5 LTS 最新，且 3.5.x 公告是否全部已含 | `openssl-library.org/source/` + `news/vulnerabilities/` 逐条比对修复版本 | M6 前的依赖刷新 |
| 2 | 10 条 CVE 的 NVD 原文（CVSS 向量、受影响版本范围、是否影响**客户端**侧） | 逐条开 NVD 页；GHSA 页已对齐 commit，但等级只取了 advisory 页标注 | 风险排序、Release Notes 的安全段落 |
| 3 | libssh2 是否有更新 tag / 新公告 | `github.com/libssh2/libssh2/security/advisories`、`gh api /repos/libssh2/libssh2/security/advisories`、OSV | 补丁系列是否要重做 |
| 4 | Homebrew 额外搬的 OSV/fuzz 修复是否纳入 | 与 `libssh2.rb` formula 对账 | M1 决定 |
| 5 | 真实 Gatekeeper 体验（未公证） | 干净机器/VM 上贴 `0081` 隔离位跑 M0b-04 §4 那张表 | M6 发布说明 |
| 6 | 登录钥匙串条目的 ACL 实际形状 | `security dump-keychain -a`（逐条弹窗）或非 ad-hoc 身份交叉读取 | §7.2 的"未绑定"目前是行为推断 |
| 7 | 真身份下 data-protection 钥匙串是否可用 | 需要 `Apple Development` 身份 + 用户钥匙串私钥授权 | **不再阻塞 M2**（M2 走登录钥匙串）；阻塞"账号到位后是否迁移到 data-protection"的评估 |
| 8 | 构建工具链版本对产物的影响 | 目前只在 provenance 记录不校验 | 长期可复现性 |
| 9 | x86_64 切片是否保留 | 与 S3"仅 arm64"对齐的产物裁剪决定 | 包体大小、签名走查覆盖面 |
| 10 | `dh-group1-sha1`、`hmac-md5`、`3des-cbc`、`arcfour`、`ssh-dss` 这五类，**五台仿真服务器没有一台默认发**（M1-01 §4、§7 待核 3） | #24 开工前的一次决策：加一台显式打开全集的"算法夹具"（那就承认它不是默认老设备，而是算法夹具），还是这几格标未测 | "允许弱算法"开关能划出的真实边界 |
| 11 | 6.7p1 的 `sshd -T` 与线路 offer 差集由哪一版、按什么规则关掉 | 上游 release notes / 提交记录（本轮未查） | 不阻塞：矩阵一律按线路实测 |
| 12 | OpenSSH 9.7 的 internal-sftp 在 `ls -l` 里不回硬链接数（8.4 回 `3`、6.7 回 `2`，9.7 三台全回 `?`） | 用 libssh2 直接读 `SSH_FXP_STAT` 的属性位比对 | #21 目录列表的字段缺失默认值、#23 契约测试的正反样本 |
| 13 | 2204 的 `RequiredRSASize 1024` 是否真能接受 1024 位 RSA 用户密钥 | 造一把 1024 位 RSA 去连（#20） | 对"老设备小密钥"的兼容承诺能不能写 |
| 14 | **出厂默认算法白名单写死哪一份**。M1-02 §3.1 只证明了"libssh2 的库默认太宽"（2204 四类弱算法全中），没定 Ferry 的默认集；`ConnectionPolicy.standard` 在定案前仍是 `libraryDefault`，只用于测试 | #24 矩阵出来后一次定案 | 弱算法开关的默认态、#25 连接对话框要不要暴露该开关 |
| 15 | 策略里的算法名是否全部真实编进了产物。`libssh2_session_supported_algs` 能列出支持表，但本轮没拿它做启动期校验；名字拼错现在只能靠"事后反查协商值"间接发现（它防放宽，不防被剔空） | 单测断言"策略集 ⊆ supported 列表"，覆盖四个维度 | 弱算法白名单有没有静默少一条 |
| 16 | 握手阶段的取消只测了"不发 banner"这一种慢；KEX 中途中断、`NEWKEYS` 之后停住等更细的形状没测 | 改造 `StallListener` 做分段延迟（或 `tc netem`） | 不阻塞：切片机制与阶段无关，M0a-03 已覆盖传输阶段 |
| 17 | **主机证书校验本期没做**：本期只做"不降级"。`@cert-authority` 行能读、能按未知主机处理，但验签、比 principal 与有效期全缺（M1-03 §5） | 需要 libssh2 之外的验签路径（证书 blob 自己解出来验 `ssh-ed25519`/`rsa-sha2-*` 签名）；先定它落在哪一期 | 与 OpenSSH 共存时的信任一致性（同一台服务器两边信的是两把密钥）；企业客户发证书登录时这一格必须先答 |
| 18 | 系统级 `/etc/ssh/ssh_known_hosts` 只按 `ssh -G` 抄了顺序，没实测：本机没这个文件，可读性与权限语义没有样本 | 造一个只读系统级文件 + 一台真机比对 | 不阻塞：读不到按"跳过该文件"处理，与 ssh 一致 |
| 19 | 弹窗文案与强调级别没定：`unknownHost` / `hostKnownWithOtherAlgorithms` / `certificateOnly` 三种原因要不要不同颜色、要不要显示命中文件与行号 | `HostKeyStore.verdict(for:hostKey:)` 已把 `source`/`line` 留给 UI，#25 一起定 | #25 |
| 20 | Ferry 自己的存储放哪没定（`~/Library/Application Support/Ferry/known_hosts` 还是别处），以及 M2 沙盒开启后还能不能读用户 `~/.ssh/known_hosts` | M2 沙盒方案定案时一起测；`HostKeyStoreConfig.standard(storeURL:)` 已把路径做成参数 | M2 |
| 21 | 并发写只测了单进程内（actor 串行 + 写前重读）；两个 Ferry 进程同时写同一文件没测 | 取决于待核 20；若路径共享则补跨进程测试或 `flock` | 视待核 20 |
| 22 | `USERAUTH_BANNER` 本期不取不显示：五台都没配（`libssh2_userauth_banner` 全回 `-50`），文案形状、显示位置、与 TOFU 弹窗的先后都没定 | 给一台配 `Banner` 看真实到达时机（它在 `userauth_list` 那趟里就被吃掉）；#25 定显示策略 | #25 连接对话框 |
| 23 | `.none` 直接认证成功那一格**没有复现服务器**（五台都要凭据）：`AuthenticatedMethod.none` 只有构造测试，线路形状只读过 `userauth.c:203` | 需要一台允许 none 的真实设备（老 Dropbear / NAS 固件常见），或确认能否造出 `AuthenticationMethods none` 的夹具 | 不阻塞：不影响其它分支的错误形状 |
| 24 | `agentAttemptLimit = 5` 是策略不是实测：agent 里挂 6 把以上时真服务器是先断线还是先回 FAILURE 没量过 | 临时 agent 里 add 8 把（只用脚本自己的密钥，不动用户 agent）打 2202 | "一把钥匙不行的用户"那条支持承诺能不能写 |
| 25 | 认证阶段的取消只测了 bcrypt 中与等人答题中两格。"签名请求已发出、服务器还没回"这一段的粒度没测 | 改造 `StallListener` 在 userauth 之后延迟回包 | 不阻塞：切片与阶段无关，M0a-03 已覆盖传输阶段 |
| 26 | `Measure.authAttempts` 与 sshd 日志的 `attempt N` 差一格（首次 `none` 探测不计入），诊断报告要哪个口径没定 | #23 契约测试定报告字段时一起定；必要时单开 `serverAttempts` | #23 |
| 27 | **0008 的上游缺陷本期只用产品侧纪律兜住，没改第三方**（§5 根因）。两个选项：① 保持现状（走链 lstat 先行 + `symlink_ex` 那一族失败一律 `undetermined` 并硬拆连接），代价是 `readlink`/`realpath` 的失败永远读不出成因；② 本地补一条补丁 0011 把 `sftp_symlink()` 的 STATUS 分支恢复成 `data + 5` 语义，重出签名产物、重跑 `verify-linkage.sh`、并在本文件记一次"我们改了上游没改的行为" | ② 的工作量已核实：改动是 sftp.c 里一格的读取顺序，重建走既有 `build-xcframework.sh`，ad-hoc 签名走查 M0b-04 已趟过一遍 | **需要用户拍板**（动签名产物与安全基线）。不阻塞 M1：现有纪律在五台上全部测得过 |

## 9. 变更记录

| 日期 | 内容 |
|---|---|
| 2026-10-15 | 建骨架。钉版三件套落地（OpenSSL 3.5.9 / libssh2 1.11.1 + 10 补丁 / cmake 3.31.12）；v2.3 §78 的 5 条"待核"关掉 4 条、纠正 1 条（CVE-2026-43798 属 swift-nio-ssh，对本依赖集不适用）；补 M0b-04 的签名/HR/Keychain 实测基线 |
| 2026-10-16 | 落两条决定：**M2 凭据走登录钥匙串**（§7.2，附接受的代价与迁移要求）、**Bundle ID 暂用 `local.ferry.Ferry` 到 M2 前**（§7.1）。待核 7 从"阻塞 M2"降级为"阻塞迁移评估"。同日填 §7.4 主机密钥定案（TOFU + `known_hosts` 只读兼容）与老设备仿真题式（配置白名单版 + 真老镜像版，结论分开记） |
| 2026-10-16（M1-01） | 仿真环境从三台扩到五台：新增 2204 oldalgo（每维度只剩一条 SHA-1/CBC 老路，2203 的 sha256 兜底被去掉）与 2205 oldos（Debian 8 / OpenSSH 6.7p1 / OpenSSL 1.0.1t，真老发行版）。§7.4 补两条测量纪律：`sshd -T` ≠ 线路 offer；`ssh-dss` 只能从容器客户端测。新开待核 10–13（弱算法夹具要不要造、`-T` 差集来源、9.7 的 `ls -l` 缺字段、1024 位 RSA 是否真被 `RequiredRSASize 1024` 接受） |
| 2026-10-16（M1-02） | 连接层落地并用正式实现打通五台（`docs/spike/M1-02`）。§7.4 三条改写：**libssh2 库默认就允许四类弱算法**（2204 实测全中，白名单不能指望库）＋ `method_pref` 静默剔除未知名字（连接层加事后反查）＋ 主机密钥判定位置被定死在 KEX 后/认证前（无回调）。新增事实：老服务器不必弱算法（2205 全现代）、指纹与 `ssh-keygen -lf` 逐台一致、握手阶段取消 3/37/48 ms 与 300 ms 超时 301 ms。新开待核 14–16 |
| 2026-10-16（M1-03） | 主机密钥层落地（`docs/spike/M1-03`）：`KnownHosts` 解析/匹配 + `HostKeyStore`（TOFU、只读兼容、六格处置表）+ 5 条与真 OpenSSH 的互认测试。§7.4 补三条实测事实：查表键是 `wireType` 而非协商名（RSA 上必然分家）、双向互认已由真 `ssh`/`ssh-keygen` 验证、`@revoked` 三种模式全拒。与 OpenSSH 的两条有意分歧坐实：它按 known_hosts 已有类型重排 KEX 偏好（libssh2 不看表），以及它把不受信证书的**叶子公钥**降级存成普通行（Ferry 不做，于是同一台开证书的服务器两边信的不是同一把）。新开待核 17–21 |
| 2026-10-16（M1-04） | 认证四类落地（`docs/spike/M1-04`，spike 为 `SpikeRunner auth`）：密码 / 公钥（两条入口，不做 Swift 层预解密）/ keyboard-interactive / ssh-agent（临时 agent）在五台上逐方式实测，Backends +17 条（共 34）。§7.4 补五条基线：`none` 探测每调一次占服务器一格 `MaxAuthTries`（清单因此只探一次并缓存，实测把同连接可犯的口令错误从 3 次抬到 5 次）、清单只用于排除方式（2201 列了 kbdint 却从不问）、`-16` 是私钥那 31 格里唯一的码且 `-48` 在本产物不可达、agent 的阻塞 Unix socket 是本期取消粒度上限（挂起 5 s 不返回）、2205 错口令 2.3 s 两次复现。新开待核 22–26 |
| 2026-10-16（M1-05） | 目录列表接入三模块（`docs/spike/M1-05`，spike 为 `SpikeRunner listing`，语料脚本 `seed-listing-corpus.sh`）：五台各 1002 条目录 = 11 包 / `stat` 增量 0、readdir 属性包五个字段全给得出而 `owner`/`group` 恒缺、13 条软链首遍 286 次请求而二遍 0 次、`-38` 涨档 1 次拿到 1504 字节目标、GBK 名按字节命中。§5 把 0008 的"越界 status"根因坐实为**读到了请求 id**（假成功、伪 `notFound`、值域外三种后果，五台逐字复现），产品侧因此走 lstat 先行 + `symlink_ex` 那一族不采信状态码。新开待核 27（要不要本地补 0011 重出签名产物，需用户拍板） |
