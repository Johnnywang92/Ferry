# M0b-01 · PathResolver 与服务器 `realpath` 对照

这项不在方案的 M0a spike 清单（#1–#8）里，是给 M0b 路径层出口标准补的实测：
方案只要求"必须有独立单测"，但路径错了全盘错，单测证明不了"和服务器一致"。

日期：2026-10-15
被测：`Packages/Core/Sources/FerryCore/CrossCutting/PathResolver.swift`（提交 3598427）
预言机：`libssh2_sftp_realpath()`，三台服务器各跑同一套 26 条用例
测量：`Spike/Sources/SpikeRunner/PathOracleSpike.swift`，`spike paths`

| 端口 | 镜像 | 服务端 | 备注 |
|---|---|---|---|
| 2201 | `atmoz/sftp:latest` | OpenSSH_8.4p1 Debian（amd64/Rosetta） | 用户被 chroot 到 `/home/tester`，SFTP 视图根即家目录 |
| 2202 | 自建 openssh（modern） | OpenSSH_9.7p1 Alpine | 登录目录 `/home/tester` |
| 2203 | 自建 openssh（legacy） | OpenSSH_9.7p1 Alpine | 同 2202，只换算法档位 |

验收标准原文："词法解析与软链 realpath 两套 API 分离……必须有独立单测；两个后端共用，出错就是全盘错"。
单测（12 例）只证明算法自洽，证明不了"和 OpenSSH 的实现一样"，所以补本轮服务器对照。

---

## 0. 结论先说

| # | 结论 | 影响 |
|---|---|---|
| 1 | **26 条用例在三台服务器上一字不差：20 条一致、0 条不一致、1 条双方都拒绝、5 条仅服务器拒绝**。三台结果完全相同，`PathResolver` 不需要按服务器分叉。 | M0b 路径层出口达标。剩下 5 条"仅服务器拒绝"全是语义差不是算法差，见 §2 |
| 2 | **服务器 `realpath` 拒绝相对路径**：`abs/f.txt`、`../m0b-maze/rel/f.txt` 在 2201/2202/2203 上全部返回拒绝，而 `PathResolver` 按基准目录解析出正确绝对路径。 | 后端绝不能把 UI 里未解析的相对路径直接发给 `realpath`，也不该发给任何请求。统一先过 `PathResolver`，这是唯一的相对路径处理点 |
| 3 | **服务器 `realpath` 不展开 `~`**：`~/upload/m0b-maze/rel/f.txt` 三台都拒绝。家目录只有客户端登录后 `realpath(".")` 那一次能拿到。 | 方案里"`~` 展开"这条需求只能由客户端实现，`PathResolver.homeDirectory` 的来源必须锁定为登录时的 `realpath(".")`（SFTP）/`PWD`（FTP） |
| 4 | **`realpath` 要求路径存在**：断链的下一级 `broken/deeper`、不存在的 `nope/x.txt` 都被拒。`PathResolver.resolve` 不查存在性，照词法给出结果。 | 上传前解析目标目录**必须用 `lexicalResolve`**，不能用 `realpath`：新文件、新目录一定"不存在"，用服务器解析等于每次上传先失败一次 |
| 5 | **软链成环时双方都拒绝，但代价差一个数量级**：`loopa↔loopb` 服务器 1 个包回 `LINK_LOOP`，`PathResolver` 为撞满 40 次上限花了 **43 次 lstat 往返**（实测 17 ms，跨洋按 800 ms RTT 折 34 s）。 | 环检测只能靠上限，没有别的办法；但同步引擎绝不能对每个条目都跑软链解析。需要遍历目录时用 `lexicalResolve`，只有落地/比对才用 `resolve` |
| 6 | **SSH_FXP_SYMLINK 参数顺序：libssh2 宏顺序（目标在前）在三台上都建出了正确的链**，不必按服务器切换顺序。但 **`libssh2_sftp_symlink_ex` 的返回码恒为 `-31 LIBSSH2_ERROR_SFTP_PROTOCOL`，`last_error` 恒为 71–134 这类非法值（合法上界是 21）**——16 条全部建成功也是 16 个 `-31`，故意往不存在的目录建链同样是 `-31`。 | 后端建链**不能信返回码**，必须 `lstat`+`readlink` 回读判定（本轮 16/16 都靠回读确认）。这是 libssh2 侧的问题，**换 #14 锁定 commit 的静态库后必须重测** |
| 7 | **单次软链解析 4–11 次往返**（迷宫深链 11 次），普通无链路径也要 2 次起。对照 M0a-04"逐条 stat = 52–54× readdir"，这是同一类按 RTT 计费的操作。 | 同步引擎的路径解析结果必须缓存在目录清单上，不允许每比对一个条目重新走一遍链；池模型里解析任务与传输任务共用并发额度 |

> **计数更正（2026-10-15，M0b-03 这轮）**：本文件初版结论 1 写"21 条一致"，那是 `spike paths`
> 汇总行的 bug——它按 `行数 − 硬失败 − 仅服务器拒绝` 算"一致"，漏减了 1 条"双方都拒绝"，
> 26 行被算成 27。逐行统计是 **20 / 0 / 0 / 1 / 5**，与下面 §1 表格的行数才对得上。代码已修，结论不变。

## 1. 对照表（2201，2202/2203 除路径前缀外逐格相同）

迷宫目录 `/upload/m0b-maze`，含绝对链、相对链、`..` 链、二级链、目录内自指链、尾部 `/`、`//`、`dir2/../dir1`、文件链、断链、环、GBK 名字节文件与指向它的链。

| 用例 | 服务器 realpath | PathResolver | 判定 | 往返 |
|---|---|---|---|---|
| `…/abs/f.txt`（绝对链） | `…/dir1/f.txt` | 同 | 一致 | 7 |
| `…/rel/f.txt`（相对链） | `…/dir1/f.txt` | 同 | 一致 | 5 |
| `…/up/f.txt`（`../m0b-maze/dir1`） | `…/dir1/f.txt` | 同 | 一致 | 6 |
| `…/chain1/f.txt`（二级链） | `…/dir1/f.txt` | 同 | 一致 | 6 |
| `…/nested/a/f.txt`（链中 `..`） | `…/dir1/f.txt` | 同 | 一致 | 6 |
| `…/trailing/f.txt`（目标带尾 `/`） | `…/dir1/f.txt` | 同 | 一致 | 5 |
| `…/doubleslash/f.txt`（目标带 `//`） | `…/dir1/f.txt` | 同 | 一致 | 7 |
| `…/dotdot/f.txt`（目标 `dir2/../dir1`） | `…/dir1/f.txt` | 同 | 一致 | 6 |
| `…/abs/../dir2`（链后再 `..`） | `…/dir2` | 同 | 一致 | 7 |
| `…/rel/..` | `…/m0b-maze` | 同 | 一致 | 4 |
| `…/abs/./f.txt` | `…/dir1/f.txt` | 同 | 一致 | 7 |
| `…/m0b-maze//abs//f.txt` | `…/dir1/f.txt` | 同 | 一致 | 7 |
| `//upload/…/abs/f.txt`（前导双斜杠） | `…/dir1/f.txt` | 同 | 一致 | 7 |
| `…/abs/`（尾部斜杠是链） | `…/dir1` | 同 | 一致 | 6 |
| `…/filelink`（文件链） | `…/dir1/f.txt` | 同 | 一致 | 5 |
| `…/broken`（断链本身） | `…/nowhere` | 同 | 一致 | 4 |
| `…/broken/deeper`（断链再往下） | 拒绝 | `…/nowhere/deeper` | 仅服务器拒绝 | 5 |
| `…/loopa/f.txt`（环） | 拒绝（LINK_LOOP） | 抛 `tooManySymlinkExpansions(40)` | 双方拒绝 | 43 |
| GBK 字节名 `\xca\xd6` | 原字节 | 原字节 | 一致 | 2 |
| `…/gbklink`（指向 GBK 名） | `\x2f…\xca\xd6` | 同 | 一致 | 4 |
| `…/nope/x.txt`（父不存在） | 拒绝 | `…/nope/x.txt` | 仅服务器拒绝 | 4 |
| `abs/f.txt`（相对，基准=迷宫目录） | 拒绝 | `…/dir1/f.txt` | 仅服务器拒绝 | 7 |
| `../m0b-maze/rel/f.txt`（相对带 `..`） | 拒绝 | `…/dir1/f.txt` | 仅服务器拒绝 | 6 |
| `~/upload/m0b-maze/rel/f.txt` | 拒绝 | `…/dir1/f.txt` | 仅服务器拒绝 | 5 |
| `.` | `/` | `/` | 一致 | 0 |
| `/` | `/` | `/` | 一致 | 0 |

GBK 那两行是**字节级比对**：`\xca\xd6` 不是合法 UTF-8，服务器原样回吐，`PathResolver` 也原样透传，`displayString()` 退化成 `\xca\xd6` 转义显示。这正是 Core 里"字节权威、显示层降级"的设计要保住的东西——一旦中间任何环节把路径转成 `String` 再转回来，这两行就会变成不一致。

## 2. "仅服务器拒绝"的 5 条为什么不算分歧

这 5 条服务器给不出结果、我们能给出结果，全部源于两条协议语义：`realpath` 要求路径存在、且不处理相对路径与 `~`。我们这边是纯词法+软链展开，不查存在性——**这是设计要求，不是漏洞**：

- 上传一个新文件，目标路径必然"尚不存在"，此时唯一正确的行为是客户端自己算出绝对路径；
- 若这里改用服务器解析，每次新建路径都会先吃一个 `NO_SUCH_FILE`，还得再发一次请求问父目录。

所以两套 API 分离（`lexicalResolve` 供显示与队列命名，`resolve` 供与服务器对齐的软链展开）在本轮数据下是成立的。

## 3. chroot 视图：路径基准必须先问服务器

2201 的 `realpath(".")` 返回 `/`，但同一目录在容器里实际是 `/home/tester`，且 `/` 只读、可写的只有 `/upload`。这带来两个必须写进后端的约束：

1. **登录目录不能假设成 `/`，也不能假设成家目录名字**：atmoz 视图根是 `/`，自建镜像视图根是 `/home/tester`。基准目录只能来自登录后那一次 `realpath(".")`。
2. **拼路径必须走 `PathResolver.child`**：视图根是 `/` 时，任何 `string + "/" + name` 的手拼都会产出 `//upload/…`。本轮第一版就直接在 `//m0b-maze` 上 `mkdir` 失败（`rc=-31`）才暴露这个问题——`readdir` 回来的名字拼进根目录，就是这个形状。

## 4. 软链创建的真实形态（给 SFTP 后端）

```
libssh2_sftp_symlink_ex(sftp, orig, orig_len, linkpath, linkpath_len, LIBSSH2_SFTP_SYMLINK)
```

- 三台服务器都按 libssh2 宏的顺序接受，不需要像坊间说的那样为 OpenSSH 交换参数；
- 返回值不可用：成功与失败都是 `-31`。唯一判据是 `lstat` 拿到 `S_IFLNK` 再 `readlink` 比对目标字节；
- `LIBSSH2_SFTP_S_IFMT` 一类的 `S_ISLNK()` 是函数宏，Swift 侧导不进来，只能用 `permissions & 0o170000 == 0o120000`；
- 这条结论绑在 Homebrew 的开发版 libssh2 上，**#14 换静态 xcframework 后必须重跑**（与 ADR-0001 §6 的复测清单同批）。

## 5. 对 M0b/M1 的约束

| 约束 | 出处 |
|---|---|
| 发给服务器的路径一律先经 `PathResolver`，禁止裸相对路径与裸 `~` | §0 结论 2、3 |
| 上传/新建路径用 `lexicalResolve`；只在需要与服务器落地结果对齐时用 `resolve` | §0 结论 4 |
| 目录遍历不逐条做软链解析；解析结果缓存在 `RemoteItem` 上 | §0 结论 5、7 |
| `readdir` 拼路径只允许 `PathResolver.child` | §3 约束 2 |
| 建链后回读判定成功 | §4 |
| 家目录来源锁定 `realpath(".")` / `PWD` | §0 结论 3 |

## 6. 复现

```bash
cd Spike && swift build
docker compose up -d                       # 2201/2202/2203
.build/debug/SpikeRunner paths             # 默认 2201
SPIKE_PORT=2202 .build/debug/SpikeRunner paths
SPIKE_PORT=2203 .build/debug/SpikeRunner paths
```

退出码：出现"不一致"或"解析失败"为 1，其余 0。三台本轮均为 0。
迷宫建在服务器的 `/upload/m0b-maze`（或登录目录下 `m0b-maze`），每次运行先清后建，可以在测试机上留档手查。

## 7. 未覆盖

- **FTP 侧对照**：FTP 没有 `realpath`，`PathResolver` 与 FTP 的 `CWD`/`PASV` 语义对齐要在 M1' FTP 后端落地时另开一轮，届时 `~` 与相对路径的处理路径不同（FTP 的路径本身是相对当前目录的字符串）。
- **Windows/Serv-U 类服务器**：`atmoz` 与自建镜像都是 OpenSSH 内核。非 OpenSSH 的 SFTP 服务器（尤其是把 `\` 当分隔符的）未覆盖，M3 兼容性阶段补。
- **`realpath` 对不存在路径的父目录回退**：OpenSSH 拒绝整条路径，但某些实现会返回已存在的最长前缀。本轮三台都是拒绝，样本不够，留待接真实服务器时验证。
