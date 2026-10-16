# M1-03：M1'-3 主机密钥 —— TOFU、known_hosts 只读兼容、与真 OpenSSH 的互认

对应任务 #19。出口标准（ADR-0000 §9 N3）：自建存储 + 首次询问（TOFU），known_hosts 默认只读兼容；覆盖哈希主机名（`|1|` 行）、同一主机多算法多行（挑与本次协商一致的那条，否则误报密钥变更）、文件权限、并发写；`@cert-authority` 与主机证书按未知主机处理；"密钥已变"必须硬阻断、不可一键跳过；带单测。

## 0. 结论

1. **查表键是 `wireType`（blob 头部里的算法名），不是协商名。** RSA 上两者必然分家：本次签名谈成 `rsa-sha2-512`，blob 头部与 known_hosts 第三字段仍是 `ssh-rsa`。用协商名查表会在 RSA 主机上永远查不到同类型的行，把正常重连误判成"这台只有别的算法"。实测两格：2201 默认（ed25519，两边同名）与 2201 强制 `rsa-sha2-512`（`algorithm` ≠ `wireType`）。
2. **只读兼容是双向量出来的**，不是我们自己说兼容：
   - ssh 亲手写的行 → Ferry 拿来当只读名单，**0 次弹窗**直接可信，且那个文件一个字节没变（2201/2202）；
   - Ferry 写的行 → `ssh-keygen -F` 查得到、指纹一致，`StrictHostKeyChecking=yes` 的真 ssh 拿它当唯一信任来源，一路走到认证（`Permission denied`），不打任何主机密钥警告（2202）。
3. **`.otherAlgorithm` 这一格不是防御性设计，是被 OpenSSH 的行为逼出来的。** 实测：表里只有 `ssh-rsa` 行时 ssh 谈成 `rsa-sha2-512`，只有 ed25519 行时谈成 `ssh-ed25519`，只有 ecdsa 行时谈成 `ecdsa-sha2-nistp256`——OpenSSH 会**按 known_hosts 已有的类型重排 KEXINIT 的主机密钥偏好**；libssh2 根本不读表，谈成哪个算哪个。所以"表里有别的算法"对我们是常态而不是异常，只能问用户，不能报"密钥已变"。
4. **主机证书：两个客户端在同一台服务器上信的是两把不同的密钥。** 带 `HostCertificate` 的那台（一次性容器 2299）：OpenSSH 10.3 的默认偏好把全部 `*-cert-v01@openssh.com` 排在最前，CA 不受信时打 `No matching CA found. Retry with plain key`，然后**把证书里的叶子公钥当普通密钥写进 known_hosts**（`[127.0.0.1]:2299 ssh-ed25519 …`，指纹 `SHA256:64yFpb9y…`）；libssh2 的 KEXINIT 里一个证书算法都不通告，服务器于是改发普通密钥，我们拿到的是 **ecdsa** 那把（`SHA256:pr+Xfe2H…`）。Ferry 不做"证书降级成叶子"这一步（N3 定的），代价就是这一格差异——所以 §5 把它钉成实测而不是推断。
5. **策略里写证书算法名不会走到信任判定**：普通服务器 `-5 KEX_FAILURE`，证书服务器 `-8 KEY_EXCHANGE_FAILURE`。libssh2 认这些名字（`hostkey_methods[]` 里有，但 `init`/`sig_verify` 是 NULL），所以它不像 M1-02 §6.2 那些不认识的名称那样被静默剔掉后回 `-33`，而是走到 KEX 里才失败。判定层因此保留一条"证书呈上即协议违规"的硬拒绝，但它是**兜底**而不是主路径。
6. **哈希行按 `ssh-keygen -H` 的真实形状实现**：salt 20 字节（不能按 16 硬编码），被哈希的主机串就是查询用的那个串——默认端口 `host`，非默认端口 `[host]:port`，方括号和端口都在哈希输入里。四个向量由 `ssh-keygen -H` 产出、逐条用独立实现的 HMAC-SHA1 反算对上。
7. **处置表六格全都有实测依据**（§2）。"密钥已变"和"`@revoked`"是硬阻断：不询问、不改文件、没有跳过——容器实测 `@revoked` 行的密钥与呈上的完全一致时，`ask` / `accept-new` / `yes` 三种 `StrictHostKeyChecking` 全部拒连，报 `WARNING: REVOKED HOST KEY DETECTED!`。
8. **写入纪律**：目录 0700、临时文件 0600 后 `rename`；写之前检查目标是普通文件、非软链、`mode & 0o077 == 0`、属主是当前 euid，任一不满足直接拒写。known_hosts 一旦能被别人改，"密钥变了"这个判定就失去意义，所以这里宁可失败也不写。
9. 测试：Core 81 条全绿（本轮新增 `KnownHostsTests` + `HostKeyStoreTests`）；Backends 17 条，`FERRY_LIVE_SERVERS=1` 全跑，不带时 7 跑 10 跳（其中 5 条是本轮的 OpenSSH 对照）。
10. 用户的 `~/.ssh` 本轮一个字节都没动过：所有外部 `ssh` 都带 `-F /dev/null` + 临时 `HOME` + `UserKnownHostsFile` 指到本次测试自己的临时文件，`SSH_AUTH_SOCK` 从环境里剥掉。

## 1. 形状

`Packages/Core/Sources/FerryCore/Connection/`：

| 文件 / 类型 | 职责 |
|---|---|
| `KnownHosts.swift` `KnownHostMarker` | 只有 `@cert-authority` / `@revoked` 两个标记，别的 `@xxx` 算解析失败 |
| ↳ `HashedHostName` | `|1|b64(salt)|b64(HMAC-SHA1(key=salt, msg=主机串))`；`matches(host:)` 用常量时间比较 |
| ↳ `KnownHostKey` | `keyType` + `blob`；`isCertificate` = 类型名含 `-cert-` |
| ↳ `KnownHostLine` / `KnownHostsFile.parse` | 一行一对象 + `failures: [KnownHostParseFailure]`；解析失败的行**不静默丢弃** |
| ↳ `HostKeyVerdict` + `lookupHostKey` | 六格处置表；整表扫完按优先级裁决：撤销 > 精确命中 > 同类型不同密钥 > 只有别的算法 > 只有证书行 > 未知 |
| ↳ `hostCandidates` | 查询一台主机要试的两个串：`host` 与 `[host]:port` |
| `HostKeyStore.swift` | `HostKeyDecision`（accept / acceptAndWriteKnownHosts / decline）、`HostKeyQuestionReason`、`HostKeyTrustPrompt`、`HostKeyStoreConfig`、`HostKeyStore: HostKeyTrust`（actor） |
| `HostKey.swift` | 新增 `wireType` / `isCertificate` / `knownHostsKeyFields` / `fingerprint(of:)`；`init` 改为 `throws` |

三处有意的形状决定：

- **`HostKey.init` 现在会抛。** blob 头部读不出算法名就判协议违规，不猜一个类型：猜错会直接落到"密钥变了 / 未知主机"这两条性质完全不同的分支上。后端调用点跟着改成 `try`（`SFTPConnection` 一行）。
- **`HostKeyQuestionReason` 由后端给事实，不由 UI 猜。** "这台在表里只有 ed25519，这次谈成了 rsa"和"从没见过这台"在弹窗里必须长得不一样，所以 `hostKnownWithOtherAlgorithms(knownTypes:source:)` 带着命中来源路径，用户能自己去那个文件里核对。
- **`HostKeyStore` 是 actor 而不是纯函数。** 写盘是"重新读 → 合并 → 原子替换"，不串行就会让两个并发连接互相盖掉对方刚加的那一行（有单测盯这条）。

## 2. 六格处置表

| `HostKeyVerdict` | Ferry 的处置 | 依据 |
|---|---|---|
| `.trusted(source:line:keyType:)` | 直接放行，不弹窗 | `hostKeyInterop.sshStoredRowUsesFerryLookupKey`：ssh 写的行 0 弹窗 |
| `.keyChanged(...)` | **硬阻断**：抛 `.hostKeyMismatch(线路上的指纹)`，不问、不写、没有跳过 | OpenSSH 9.7 容器同形状拒连；`otherAlgorithmAndKeyChangeDifferOnLiveServer` 第 (2) 格用 2202 的密钥冒充 2201，弹窗 0 次、只读文件字节不变 |
| `.revoked(source:line:)` | 硬阻断，且**优先于任何合法行** | man 原文 "must not ever be accepted"；容器实测三种 `StrictHostKeyChecking` 全拒（§9 命令） |
| `.otherAlgorithm(sources:knownTypes:)` | 问用户，接受才落盘 | §0.3 的三格 KEX 转向实测；`HostKeyStoreTests.otherAlgorithmIsNotKeyChange` |
| `.certificateOnly(sources:)` | 问用户，原因写明"这台只有 CA / 证书行，本期不校验证书" | 2299 实测：`@cert-authority` 行 + `yes` 时服务器呈普通密钥会 `Host key verification failed` |
| `.unknown` | 问用户（TOFU），拒绝 ⇒ `CancellationError` | `tofuFirstContact` / `tofuDecline` |

`decline` 抛 `CancellationError` 而不是 `hostKeyMismatch`：用户主动中止与"这台主机的密钥变了"是两件事，UI 不该因为前者弹中间人警告。

## 3. 与真 OpenSSH 的互认实测

跑法见 §9，全部在临时 `HOME` 与临时 known_hosts 上做。

### 3.1 查表键

| 案例 | 协商到的签名算法 | blob 头部 / 表里的 keytype | 与 `ssh-keyscan` 那行是否同名 | 指纹是否相同 |
|---|---|---|---|---|
| 2201 默认 | `ssh-ed25519` | `ssh-ed25519` | 是 | `SHA256:lqhc0xWG…` |
| 2201 强制 `rsa-sha2-512` | `rsa-sha2-512` | **`ssh-rsa`** | 是 | `SHA256:bqRvbdXwqPhXbWacv6AOl+kBXtRH4NRAqw82LBjPsIM`（4096 位 RSA） |
| 2202 默认 | `ecdsa-sha2-nistp256` | `ecdsa-sha2-nistp256` | 是 | `SHA256:HdRVWTd2…` |
| 2205 默认 | `ecdsa-sha2-nistp256` | `ecdsa-sha2-nistp256` | 是 | `SHA256:8ajU8an…` |

第二行是本轮的坑本体：`NegotiatedAlgorithms.hostKey`（协商维度）与 `HostKey.wireType`（known_hosts 的第三字段）在 RSA 主机上是两个值，前者进协商事实表，后者才是查表键。

### 3.2 ssh → Ferry

对 2201、2202 各跑一遍：`ssh -o StrictHostKeyChecking=accept-new -o HostKeyAlgorithms=<本次 Ferry 谈成的签名算法>` 写一行进临时文件，然后

| 观测 | 结果 |
|---|---|
| 那一行的主机字段 | `[127.0.0.1]:<port>`（非 22 端口一律方括号，端口在方括号**外面**） |
| 那一行的 keytype | 等于 Ferry 的 `wireType` |
| `ssh-keygen -l` 的指纹 | 等于 `HostKey.fingerprintSHA256` |
| 把该文件当只读名单，Ferry 握手 | 不抛错、弹窗 0 次 |
| 该文件在握手前后 | 内容与 mtime 都不变 |

`HostKeyAlgorithms` 那一步是必要的：不固定就会两边谈成不同密钥类型，比的不再是同一把。

### 3.3 Ferry → ssh

固定 `ssh-ed25519`（本机 ssh 默认也挑这个）让 Ferry TOFU 写一行，然后：

| 观测 | 结果 |
|---|---|
| 落盘文本 | `[127.0.0.1]:2202 ssh-ed25519 AAAA…` |
| `ssh-keygen -F "[127.0.0.1]:2202" -l` | 命中，指纹与我们算的一致 |
| 新实例读同一文件再握手 | 弹窗 0 次（不依赖内存缓存） |
| `ssh -o StrictHostKeyChecking=yes` 用它当唯一信任来源 | 走到 `Permission denied`，输出里没有 `Permanently added` / `WARNING` / `Host key verification failed` |

最后一条是本轮最强的一条外部断言：真 OpenSSH 在"绝不新增记录"的模式下认可 Ferry 写的行。

## 4. 只读兼容与写入纪律

| 项 | 实现 | 单测 |
|---|---|---|
| 文件顺序 | 自己的存储 → `~/.ssh/known_hosts` → `~/.ssh/known_hosts2` → `/etc/ssh/ssh_known_hosts(2)`，照本机 `ssh -G`（OpenSSH_10.3p1）抄 | `multipleFilesPriority` |
| 只读 | 只有 `.acceptAndWriteKnownHosts` 才动 `writableKnownHosts`；只读名单里的文件永远只读 | `readOnlyKnownHostsIsHonored`、§3.2 |
| 权限 | 父目录 0700；临时文件 0600 → `rename`；目标为软链 / 组或其他可读 / 非本 euid ⇒ 拒写 | `writesSetPermissionsAndRefuseUnsafeTargets` |
| 并发 | actor 串行 + 每次写前重新读盘（缓存只服务查表） | `concurrentAcceptsDoNotClobberEachOther` |
| 幂等 | 同主机同类型同密钥不重复写 | `idempotentWritesAndExplicitKnownHostsConsent` |
| 外部改动 | 缓存签名 = `mtime|size`，变了就重读 | `externalEditInvalidatesTheCache` |
| 哈希存储 | `hashStoredHostNames` 默认关；写了哈希行 `ssh-keygen -F` 照样能查 | `hashedStorageRoundTrip` |
| 撤销与恢复路径 | `removeRecords(host:port:keyType:)` 只动自己的存储；"删除记录"是用户主动动作，与"跳过警告"不是一回事 | `keyChangeIsHardBlock` |

`.accept` 与 `.acceptAndWriteKnownHosts` 分成两个值是 N3 的直接后果：**"同意连这台"和"同意顺手写进 OpenSSH 的文件"是两次同意**。

## 5. 主机证书实测（一次性容器 2299）

镜像同一个 `ferry-sftp-modern`，容器内自签 CA → `ssh-keygen -s -h` 签主机 ed25519 公钥 → `HostCertificate` 写进 `/etc/ssh/sshd_config` → `kill -HUP 1`。该容器测完已删除，命令留在 §9。

| # | 观测 | 结果 |
|---|---|---|
| 1 | 服务器广告的 host key 算法（`HostKeyAlgorithms=` 打错时 ssh 回显的 "Their offer"） | `rsa-sha2-512, rsa-sha2-256, ecdsa-sha2-nistp256, ssh-ed25519, ssh-ed25519-cert-v01@openssh.com` |
| 2 | 客户端默认偏好（`ssh -vv` 的 `debug2: host key algorithms`） | 全部 `*-cert-v01@openssh.com` 排在最前 |
| 3 | 空表 + `accept-new` | 谈成 `ssh-ed25519-cert-v01@openssh.com`；`No matching CA found. Retry with plain key`；写入 **`[127.0.0.1]:2299 ssh-ed25519 <叶子公钥>`**，用户侧只看到 `Permanently added … (ED25519)` |
| 4 | 表里有 `@cert-authority * <CA公钥>` + `yes` | `Host '[127.0.0.1]:2299' is known and matches the ED25519-CERT host certificate.`，走到认证，文件不追加 |
| 5 | 表里只有 CA 行、但服务器呈普通密钥（未开 `HostCertificate`） | `Host key verification failed` |
| 6 | Ferry（libssh2）默认偏好打 2299 | `ecdsa-sha2-nistp256`，`SHA256:pr+Xfe2HwtNoxtZz/TRXq+vot9MJjcFIGsaetdP8ytU`，blob 104 B —— **与 #3 里 ssh 信的那把不是同一把** |
| 7 | Ferry 策略 `hostKey: ["ssh-ed25519-cert-v01@openssh.com"]` 打 2299 | `-8 KEY_EXCHANGE_FAILURE`（`kex.c:4161`），判定层 0 次 |
| 8 | 同一份策略打 2201 / 2202 | `-5 KEX_FAILURE`，判定层 0 次 |

表里 #3/#6 那两个指纹属于那台一次性容器，重建即换密钥，**不作固定向量**；可复用的结论是"两把不是同一把"这个形状。

#6 是本轮对基线影响最大的一条：**共存场景下"同一个主机的信任记录"并不是同一件事**。#3 那个降级（证书 → 叶子公钥存成普通行）是 OpenSSH 的既有行为，Ferry 刻意不做——因为一旦做了，"CA 换了叶子没换"这类情况会给出错误结论，而本期没有任何证书链校验能力。N3 说的"证书按未知主机处理"落到实现里就是 #4/#5 对应的 `.certificateOnly`（表里只有 CA/证书行 → 问用户并说明原因）与 #6/#7/#8 对应的"证书进不了判定层，进来了就硬拒绝"。

## 6. 三个不能靠猜的解析细节

- **`\r\n` 在 Swift 里是一个字素簇**，所以 `split(separator: "\n")` 对 CRLF 文件一次都不切：整行连着 `\r\n` 送去 base64 解码，每个有效行都被判成坏行。分隔符改成 `\r\n` / `\n` / `\r` 三态谓词。这条是写测试时踩到的，不是读文档读出来的。
- **base64 缺填充要能补**。手改过的 known_hosts 里常见去掉 `=` 的行；解码策略是先按原样，失败再补填充。测试里那个 49 字节的截断 blob（51−2，除以 3 余 1）末尾正好两个填充位，就是这条形状的依据。
- **方括号只包主机名，端口在外面**：`[127.0.0.1]:2201`。写成 `[127.0.0.1:2201]` 的行 `ssh-keygen -F` 不认，`ssh` 也永远不会往文件里写那种形状；哈希行的哈希输入用的同样是带方括号与端口的那个串。落盘侧曾经把括号写成 `[host:port]`，那样写出来的行永远匹配不上——`renderLine` 与 `hostCandidates` 必须共用一种形状，这条现在由 §3.3 的 `ssh-keygen -F` 直接盯着。

## 7. 出口标准对照

| 任务 #19 的要求 | 交付 | 证据 |
|---|---|---|
| 自建存储 + 首次询问（TOFU） | `HostKeyStore`（actor）+ `HostKeyTrustPrompt`；拒绝 ⇒ `CancellationError`，且文件不产生 | `tofuFirstContact` / `tofuDecline` |
| known_hosts 默认只读兼容 | `readOnlyKnownHosts` 只读；双向量：ssh 写的行直接可信、Ferry 写的行 `ssh-keygen -F` 与真 `ssh` 都认 | §3.2 / §3.3 |
| 哈希主机名（`|1|` 行） | `HashedHostName` + 20 字节 salt + 主机串含端口；写侧可选开关 | 四个 `ssh-keygen -H` 向量、`hashedPortIsPartOfTheHash`、`hashedReadOnlyRowIsTrusted` |
| 同一主机多算法多行，挑与本次协商一致的那条，否则误报密钥变更 | 查表键 = `wireType`；`keyType` 相同才比 blob，不同只进 `.otherAlgorithm` | §0.1、`multipleAlgorithmsPerHost`、`sameTypeDifferentKeyIsChange` |
| 文件权限 | 0700 目录 / 0600 文件 / 临时文件 + `rename`；不安全目标拒写 | `writesSetPermissionsAndRefuseUnsafeTargets` |
| 并发写 | actor 串行 + 写前重读 | `concurrentAcceptsDoNotClobberEachOther` |
| `@cert-authority` 与主机证书按未知主机处理 | `.certificateOnly` 询问并说明原因；线路呈上证书 ⇒ 硬拒绝；策略写证书名 ⇒ `-5`/`-8` 且判定层不调 | §5 全表、`certificateOnlyRowsPrompt`、`presentedCertificateIsRefused`、`certificateAlgorithmInPolicyNeverYieldsTrustedSession` |
| "密钥已变"硬阻断、不可一键跳过 | `.keyChanged` ⇒ 抛 `.hostKeyMismatch`，prompt 一次都不调；`removeRecords` 是唯一恢复路径 | `keyChangeIsHardBlock`、§3.2 的第 (2) 格（真服务器上弹窗 0 次、文件不动） |
| 带单测 | Core 81 条（本轮 +`KnownHostsTests` 13 条、+`HostKeyStoreTests` 16 条）；Backends +`HostKeyInteropTests` 5 条真机对照 | §9 |

## 8. 待核

接 `docs/SecurityBaseline.md` §8，本轮新开 17–21。

| # | 项 | 方法 | 阻塞什么 |
|---|---|---|---|
| 17 | 主机证书校验（读 `@cert-authority` 并验签、比 principal 与有效期）本期没做，本期只做"不降级" | 需要 libssh2 之外的验签路径（`ssh-ed25519`/`rsa-sha2-*` 手工验证书签名）；先定它落在哪一期 | 与 OpenSSH 共存时的信任一致性（§5 #6）；企业客户如果发证书登录，这一格必须先答 |
| 18 | 系统级 `/etc/ssh/ssh_known_hosts` 只做过顺序照抄，没有实测：本机不存在该文件，也没有可读性/权限语义的样本 | 造一个只读系统级文件 + 一台真机，验证 `ssh -G` 顺序与我们的一致 | 不阻塞：读不到时按"跳过该文件"处理，与 ssh 一致 |
| 19 | 弹窗文案与强调级别没定：`unknownHost` / `hostKnownWithOtherAlgorithms` / `certificateOnly` 三种原因在 UI 上是否用不同颜色、要不要显示命中文件路径与行号 | #25 连接对话框一起做；`HostKeyStore.verdict(for:hostKey:)` 已经把 `source`/`line` 留着给 UI | #25 |
| 20 | Ferry 自己的存储放哪没定（`~/Library/Application Support/Ferry/known_hosts` 还是容器内路径），以及 M2 沙盒开启后是否仍可读用户的 `~/.ssh/known_hosts` | M2 沙盒方案定案时一起测；`HostKeyStoreConfig.standard(storeURL:)` 已把路径做成参数 | M2 |
| 21 | 并发只测了单进程内（actor 串行）。两个 Ferry 进程同时写同一个文件没测——会不会发生取决于 #20 | 若 #20 定案为共享路径，加一条跨进程写测试；否则加 flock | 视 #20 |

## 9. 复现

```bash
swift test --package-path Packages/Core                          # 81 条
docker compose up -d                                             # 五台，2201–2205
FERRY_LIVE_SERVERS=1 swift test --package-path Packages/Backends  # 17 条，含 §3 的全部对照

# §3.1 查表键（2201 强制 rsa-sha2-512 那一格）
ssh-keyscan -t rsa -p 2201 127.0.0.1 2>/dev/null | grep -v '^#' | ssh-keygen -lf -

# §0.3 known_hosts 驱动 KEX 转向：在 2202 容器里跑，只用 /tmp
docker compose exec -T sftp-modern sh -c '
  export HOME=/tmp/steer; rm -rf /tmp/steer; mkdir -p /tmp/steer/.ssh; chmod 700 /tmp/steer/.ssh
  for t in rsa ed25519 ecdsa; do
    ssh-keyscan -t $t -p 22 127.0.0.1 2>/dev/null | grep -v "^#" > /tmp/steer/.ssh/known_hosts
    chmod 600 /tmp/steer/.ssh/known_hosts
    ssh -vv -F /dev/null -p 22 -o StrictHostKeyChecking=no -o GlobalKnownHostsFile=/dev/null \
      -o UserKnownHostsFile=/tmp/steer/.ssh/known_hosts -o PreferredAuthentications=none \
      tester@127.0.0.1 true 2>&1 | grep "kex: host key algorithm"
  done'

# §2 撤销行的三种 StrictHostKeyChecking（容器内，/tmp）
docker compose exec -T sftp-modern sh -c '
  export HOME=/tmp/rv; rm -rf /tmp/rv; mkdir -p /tmp/rv/.ssh; chmod 700 /tmp/rv/.ssh
  KEY=$(ssh-keyscan -t ed25519 -p 22 127.0.0.1 2>/dev/null | grep -v "^#" | awk "{print \$2\" \"\$3}")
  for m in ask accept-new yes; do
    printf "@revoked 127.0.0.1 %s\n" "$KEY" > /tmp/rv/.ssh/known_hosts; chmod 600 /tmp/rv/.ssh/known_hosts
    ssh -F /dev/null -p 22 -o StrictHostKeyChecking=$m -o BatchMode=yes -o PreferredAuthentications=none \
      -o UserKnownHostsFile=/tmp/rv/.ssh/known_hosts tester@127.0.0.1 true 2>&1 | head -4
  done'

# §5 证书服务器（一次性容器，测完删）
docker run -d --name ferry-cert -p 2299:22 ferry-sftp-modern:latest
docker exec ferry-cert sh -c '
  mkdir -p /tmp/ca && ssh-keygen -q -t ed25519 -N "" -f /tmp/ca/ca_key
  ssh-keygen -q -s /tmp/ca/ca_key -I host-2299 -h -n 127.0.0.1,localhost -V +52w /etc/ssh/ssh_host_ed25519_key.pub
  printf "\nHostCertificate /etc/ssh/ssh_host_ed25519_key-cert.pub\n" >> /etc/ssh/sshd_config
  sshd -t && kill -HUP 1'
cd Spike && swift build
SPIKE_PORTS=2299 .build/debug/SpikeRunner handshake                              # §5 #6
SPIKE_PREFS=cert SPIKE_PORTS="2299 2201 2202" .build/debug/SpikeRunner handshake # §5 #7 #8
CA=$(docker exec ferry-cert cat /tmp/ca/ca_key.pub)
rm -rf /tmp/certhome && mkdir -p /tmp/certhome && printf "@cert-authority * %s\n" "$CA" > /tmp/certhome/kh
HOME=/tmp/certhome ssh -vv -F /dev/null -p 2299 -o UserKnownHostsFile=/tmp/certhome/kh \
  -o GlobalKnownHostsFile=/dev/null -o StrictHostKeyChecking=yes -o BatchMode=yes \
  -o PreferredAuthentications=none tester@127.0.0.1 true 2>&1 | grep -E "host certificate|matches"   # §5 #4
docker rm -f ferry-cert
```
