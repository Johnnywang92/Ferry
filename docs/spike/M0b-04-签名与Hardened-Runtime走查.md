# M0b-04 · 签名与 Hardened Runtime 走查（ad-hoc）

日期：2026-10-15
出口标准：ADR-0000 §2 改写后的"**逐层 ad-hoc 签名 + Hardened Runtime 下本地产物可启动**"（公证移出本期范围）
环境：macOS 26.6.2（25G83）、arm64、`spctl --status` = assessments enabled、Homebrew libssh2 1.11.1_7 在场（用作"非系统 dylib"的样本）
产物：M0b-03 的静态 xcframework 路线（`FerrySSH.a` + OpenSSL 静态归档），无嵌套动态库

---

## 0. 结论

| # | 事实 | 对设计的影响 |
|---|---|---|
| 1 | **ad-hoc + Hardened Runtime 的产物能构建、能签名、能启动**。`codesign --verify --strict` 通过，"satisfies its Designated Requirement"，`open` rc=0 **且有启动戳**（探针真跑过），`flags=0x10002(adhoc,runtime)`、`TeamIdentifier=not set` | M0b 出口标准达成 |
| 2 | **全静态链接让"逐层签名"这一层空转**：bundle 里嵌套代码 0 个，由内向外的循环天然没有对象，**不需要 `disable-library-validation`** | 静态链接不是"省事"，是 ad-hoc 阶段唯一能让第三方库进产物的形状（见结论 3） |
| 3 | **Library validation 拦的是"Team ID 不同"，不是"在不在 bundle 里"**：把 Homebrew 的 `libssh2.1.dylib` 复制进 `Contents/Frameworks/` 并由内向外重新 ad-hoc 签名，dlopen 仍被拒（"mapping process and mapped file (non-platform) have different Team IDs"） | 任何将来引入 dylib 的方案（典型：Sparkle 的 dylib、libcurl dylib 化）在 ad-hoc 下**必须**加 `disable-library-validation` 才能加载；这条要写进 SecurityBaseline |
| 4 | **Keychain 两种钥匙串的行为完全分叉**：登录钥匙串（file-based）在 ad-hoc 下可用，而且**换 cdhash、换 entitlements、换签名 Identifier、甚至完全不带 bundle 都能读回同一条目**；data-protection 钥匙串一律 `err -34018`（errSecMissingEntitlement），**补 `keychain-access-groups` entitlement 会让进程在 exec 阶段被 SIGKILL（rc=137，一行输出都没有）** | ADR-0000 §2 最后一条的预期一半作废一半加重（详见 §6）：M2 若坚持用 data-protection 钥匙串，ad-hoc 阶段根本存不进去，不是"重建后失效"的问题 |
| 5 | **Hardened Runtime 不影响真实 SFTP 数据路径**：把 spike 可执行体按同一条配方签成 ad-hoc+HR 再跑 `paths`@2202，判定分布与 M0b-03 未签名那轮**逐字相同**（一致 20，不一致 0，解析失败 0，双方都拒绝 1，仅服务器拒绝 5；单次解析最多往返 45 次）；建链 16 条的 rc/status 分布串与 2201 基线**逐字符相同**（`-31/103×1 -31/107×1 … -31/99×1`）；`keys` 子命令（读私钥文件 + bcrypt + ssh-agent socket）也全通 | HR 与我们的库/网络/文件路径无冲突，M1' 不必为它留缓冲 |
| 6 | **本机测不出"未公证被 Gatekeeper 拦"这个分发代价**：带隔离位的 ad-hoc+HR 副本直接跑起来了（`0002/0081/0083/0181` 四种 flag 值、两个从未启动过的 bundle id 都试了，`open` 全 rc=0 有启动戳），而 `spctl --assess --type execute` 对同一份产物报 **rejected**；对照组（**同一份产物去掉签名** + 隔离位）确实被拦（`Launchd job spawn failed`，POSIX 163） | 结论只能是"本机 Gatekeeper 的'未识别开发者'这一层没在起作用"，**不能**写成"分发体验已验证"。ADR-0000 §2 的放行说明照写，但真实体验必须在干净机器/VM 上复测（§9 待核 1） |

---

## 1. 走查怎么做成的

新增 `App/` 子工程（**M0b 的签名底座，不是 M1 的 App target**）：

| 文件 | 作用 |
|---|---|
| `App/Package.swift` | executableTarget `Ferry`，依赖 `FerrySSHShim` + `FerryBackendsSFTP`（即真实后端的静态产物），证明签名走查打在真链接上而不是 hello-world |
| `App/Sources/Ferry/main.swift` | 运行期探针：静态 libssh2 可调、dlopen 三类库、TCP + banner、私钥/钥匙串，任何 unexpected FAIL 让退出码非 0 |
| `App/Support/Info.plist.in` | `__BUNDLE_ID__` 模板，`LSUIElement=true`（探针不该在 Dock 占位） |
| `App/Support/Ferry.entitlements` | **故意是空 `<dict/>`**：文件里写清了 HR 下我们不需要任何 entitlement，并且**禁止**提前塞 `disable-library-validation` / `app-sandbox` |
| `App/Support/Ferry.debug.entitlements` | `get-task-allow`，给调试场景（§5 证明它对 DYLD 注入没用） |
| `App/build-and-sign.sh` | 七步走查脚本，见下 |

脚本七步：构建 → 组 bundle → **由内向外逐个签嵌套代码，最后签主 App，全程不用 `--deep`** → 验签（`--verify --strict` / `-dvvv` / entitlements dump / `otool -L` 非系统路径过滤 / `spctl --assess`）→ 直接 exec 拿探针结论 → `open` 拿 LaunchServices 的真实结果 → 另存一份贴隔离位再 `open`，外加**无签名对照组**。

两个方法学上的坑，都是本轮踩过之后写进脚本注释的：

- **`open` rc=0 不等于进程跑起来过**。探针每次运行先往 `$FERRY_STAMP` 盖一个戳（pid / bundle id / 路径 / 时间），脚本用"戳在不在"判定。没有这个戳，`open` 的 0 与"静默被拦"两种情况长得一模一样。
- **隔离位必须贴在没被系统记录过的新副本上**。原地 `xattr -w` 到一个已经被 `open` 过的 bundle，测出来一定是"放行"，那个"放行"是假的。

---

## 2. 签名与验签事实

`App/build-and-sign.sh --skip-keychain`（出口标准那一轮，rc=0）：

```
== 3. 由内向外签名（不用 --deep）
  嵌套代码 0 个（全静态）
== 4. 验签
  valid on disk
  satisfies its Designated Requirement
  Identifier=local.ferry.Ferry
  CodeDirectory v=20500 size=1202 flags=0x10002(adhoc,runtime) hashes=27+7 location=embedded
  CDHash=505ce007bc55ec1ebf6d5f5ab0bff6f336daad55
  Signature=adhoc
  TeamIdentifier=not set
  entitlements：<dict></dict>
  动态依赖：全部来自 /usr 或 /System
  Gatekeeper 评估：rejected
```

- `v=20500` 是带 entitlements 槽的 CodeDirectory 版本；换掉 entitlements 会让 cdhash 变（§6 用这一点做身份实验）。
- debug 构建 451 200 B / release 构建 307 272 B，两者签名结论相同；`flags` 从 debug 到 release 都是 `0x10002(adhoc,runtime)`。
- `--timestamp` 不能用：ad-hoc 拿不到 secure timestamp，脚本只在 `$FERRY_SIGN_IDENTITY != "-"` 时才加。
- `spctl --assess` rejected 与 `open` 成功并存 —— 这是本轮最需要标注环境的一条（§4）。

对照 Apple 自带 App 做的阳性对照：`spctl --assess --type execute -vv /System/Applications/Calculator.app` → `accepted, source=Apple System`，说明 spctl 本身在这台机器上是工作的，rejected 不是工具坏了。

## 3. 探针在签名产物里的逐项结果

| 检查 | 结果 | 说明 |
|---|---|---|
| 静态 libssh2 可调用 | PASS | `1.11.1_DEV`、`NUM 68353`、crypto engine `openSSL` —— M0b-03 的产物在签名后仍然链的是我们自己那份 |
| dlopen `/usr/lib/libz.1.dylib` | PASS | Apple 签名，library validation 放行 |
| dlopen `/opt/homebrew/lib/libssh2.1.dylib` | 按预期被拒 | `different Team IDs` |
| dlopen **bundle 内并重签过**的同名 dylib | 仍被拒 | 同一个 `different Team IDs`（§0 结论 3） |
| TCP + SSH banner | PASS | `127.0.0.1:2202` → `SSH-2.0-OpenSSH_9.7`，非沙盒 + HR 下出网不受限 |
| 登录钥匙串 | PASS | 读/写/复读都通（§6） |
| data-protection 钥匙串 | **FAIL -34018** | ad-hoc 无 Team ID → 无 application-identifier（§6） |

## 4. 分发场景：能测出的与测不出

| 场景 | `open` 结果 | 启动戳 |
|---|---|---|
| ad-hoc+HR 副本，隔离位 flag `0002` | rc=0 | 有 |
| 同上，flag `0081`（Safari 真实值） | rc=0 | 有 |
| 同上，flag `0083` / `0181` | rc=0 | 有 |
| 签名 Identifier 换成 `local.ferry.OTHER` / `local.ferry.never2026`（从未启动过）+ `0081` | rc=0 | 有 |
| **同一份产物 `codesign --remove-signature` + `0081`** | **rc=1** | **无** —— `Launchd job spawn failed`，POSIX 163 |

最后一行是本轮加进脚本的**对照组**：它证明隔离位与签名检查在这台机器上确实生效，所以上面那些"放行"是有效测量而不是测试没跑起来。也就是说，本机绕过的是 Gatekeeper 的"未识别开发者/未公证"这一层弹窗，不是整个启动链路。

⇒ **ADR-0000 §2 的"用户需手动放行"在本机不可复现**，本期按"待核 + README 照写放行说明"处理。

## 5. DYLD 环境变量注入（决定我们怎么调试自己的库）

用一个真会留证据的注入体（`__attribute__((constructor))` 往 `/tmp` 落一个文件），而不是看 `DYLD_PRINT_LIBRARIES`：

| 配置 | 注入结果 |
|---|---|
| ad-hoc + HR（默认空 entitlements） | 被挡 |
| ad-hoc，**不开 HR** | **成功** —— 证明"被挡"确实来自 HR |
| ad-hoc + HR + `get-task-allow` | 被挡 |
| ad-hoc + HR + `allow-dyld-environment-variables` | **仍被挡** |
| ad-hoc + HR + `allow-dyld-environment-variables` **+ `disable-library-validation`** | **成功** |

结论两条：(a) 要在 HR 产物上做 DYLD 注入，两个开关都得开，只开环境变量那个没用（环境变量留下了，注入体过不了 library validation）；(b) `Ferry.debug.entitlements` 的 `get-task-allow` 帮不上这个忙，调试第三方库的正路是**用静态归档 + 符号断点**，不要指望注入。

顺带记一条方法学：**macOS 26.6 上 `DYLD_PRINT_LIBRARIES` 连不开 HR 的产物都不打印任何 `dyld:` 行**，不能用它判断环境变量有没有被剥离。

## 6. Keychain：这轮最需要修正预期的地方

`local.ferry.idtest1` 这个 service 名是本轮新加的 `FERRY_KC_SERVICE` 覆盖项，为的是**从"只有上一个签名身份写过"的干净命名空间开始**，不复用前几轮留下的条目，也不去删用户钥匙串里的东西。

| 轮次 | 身份变化 | cdhash | 登录钥匙串 | data-protection |
|---|---|---|---|---|
| A（debug 构建） | 基线，首次写 | `505ce007…` | 首次读=没有条目，写=ok，复读=ok | 写=err **-34018** |
| B（release 构建） | **二进制变了 → cdhash 变** | `413e65d9…` | **首次读=已存在**，写=ok，复读=ok | err -34018 |
| C | 同一二进制，entitlements 换成 `get-task-allow` | `52045c79…` | 首次读=已存在 | err -34018 |
| D | 同一二进制，签名 Identifier 换成 `local.ferry.OTHER` | `cfc94f9e…` | 首次读=已存在 | err -34018 |
| E | 完全脱离 bundle 的 SwiftPM 直出二进制（linker-signed，无 HR，`flags=0x20002`） | `9242e791…` | 首次读=已存在 | err -34018 |

另外，`/usr/bin/security find-generic-password -s local.ferry.idtest1 -a probe` 不弹窗就读到了这条目（keychain = `~/Library/Keychains/login.keychain-db`，class `genp`），指向同一个方向：**本机登录钥匙串对 ad-hoc 产物建立的条目没有做 code requirement 绑定**。ACL 的实际形状没读（`security dump-keychain -a` 要逐条弹窗）——列为待核 2。

于是 ADR-0000 §2 最后那条决策要改口径：

- 原本担心的"**每次重建后 Keychain 条目失效**"——登录钥匙串这条路在本机**没有发生**，四种身份变化都读得回来。
- 更严重的是另一面：**data-protection 钥匙串在 ad-hoc 下完全不可用**，而且不能靠补 entitlement 解决 —— 加 `keychain-access-groups`（值写 `local.ferry.signing`）后签名本身能吃下这个 entitlement，但进程在 exec 阶段被 **SIGKILL（rc=137）**，探针一行都没打印，也没有崩溃报告；同一份二进制换回空 entitlements 立刻恢复正常。
- ⇒ **M2 的凭据存储只有两种活路**：(1) 用登录钥匙串（`kSecUseDataProtectionKeychain=false`），代价是没有数据保护类、可被备份/迁移带走；(2) 先把正式签名身份搞到手再上 data-protection。这是 SecurityBaseline 要定的第一个问题。
- "用固定自签证书（非 ad-hoc）做 Keychain 测试"这条决策本轮**没有执行**：往用户钥匙串里塞自签代码签名身份属于改系统状态，需要单独点头。

## 7. 真实 SFTP 路径在 HR 下的复测

把 spike 可执行体按同一条配方签名（`codesign --force --sign - --options runtime`，`CDHash=37d3cae5…`，`flags=0x10002(adhoc,runtime)`）后跑：

- `SPIKE_PORT=2202 spike-hr paths` → `一致 20，不一致 0，解析失败 0，双方都拒绝 1，仅服务器拒绝 5`；`迷宫建链 16 条全部回读确认，rc/status 分布 -31/103×1 -31/107×1 … -31/99×1`（16 个值，步长 +4，起点 71）；`SSH_FXP_SYMLINK 参数顺序：目标在前（建链成功时 libssh2 回 rc=-31）`；单次解析最多往返 45 次。
  判定分布与往返数和 M0b-03 §7 记录的未签名 2202 基线逐字相同；rc/status 那串与 2201 基线日志逐字符相同（2202 那份老日志在捕获时把该行截断在 `-31/` 上了，只能对到 2201）。
  ⇒ **签名与 HR 不改变路径解析、realpath 往返、软链语义的任何一条结论**。
- `spike-hr keys` → ed25519/rsa openssh 与老式 PEM 各格式解析结论不变（例：`ed25519+bcrypt 有口令 fromfile rc=0 412.6 ms 可解析`；口令错误 `-16`；文件不存在 `-16`），私钥文件从 `/tmp/ferry-keys` 读没被挡；`SSH_AUTH_SOCK` 还在，`agent_connect rc=0`、`agent_list_identities rc=0`（身份 0 个）。

## 8. 与出口标准对照

| 出口标准（ADR-0000 §2 改写版） | 状态 |
|---|---|
| 逐层 ad-hoc 签名（由内向外，不用 `--deep`） | 达成 —— 循环存在且实测空转；一旦有嵌套代码，§4 的对照组会告诉我们能不能签进去 |
| Hardened Runtime 开启 | 达成，`flags=0x10002` |
| 本地产物可启动 | 达成 —— `open` rc=0 **且有启动戳**，直接 exec 与 LaunchServices 两条路都通 |
| 公证 | 本期范围外（无账号） |
| 分发体验（"未公证会被拦"） | **本机不可复现**，转 M6 前复测（待核 1） |

## 9. 待核

1. **真实 Gatekeeper 体验**：需要一台没被我们这类副本"训练"过的干净机器或 VM，用 `0081` 隔离位跑一次 §4 表。当前只能确定本机拦不住 ad-hoc+HR，拦得住无签名。
2. **登录钥匙条目 ACL 的实际形状**：`security dump-keychain -a`（逐条弹窗，得在有授权的终端做），或用一条非 ad-hoc 身份写入的条目做交叉读取。§6 的"没做 code requirement 绑定"目前是实测行为推的，不是读 ACL 读出来的。
3. **正式签名身份下的 data-protection 钥匙串**：需要真实 `Apple Development` 身份（要动用户钥匙串里的私钥，可能弹授权窗），本轮刻意没试。若通过，M2 的凭据方案才可能同时拿到"数据保护类"和"跨重建稳定"。
4. **Sparkle 的 dylib 需求**：若 M6 真引入，§0 结论 3 与 §5 的矩阵说明我们必须二选一 —— 加 `disable-library-validation`，或换 Sparkle 的静态/无 dylib 形态。

## 10. 复现

```bash
# 出口标准那一轮（4 项 PASS，rc=0）
App/build-and-sign.sh --skip-keychain

# 含 Keychain 的完整一轮（data-protection 会 FAIL，脚本 rc=1 —— 那是结论不是事故）
App/build-and-sign.sh

# 身份变化实验（§6 表 B/C/D/E 的做法）
FERRY_CONFIG=release App/build-and-sign.sh --skip-keychain
FERRY_KC_SERVICE=local.ferry.idtest1 App/build/Ferry.app/Contents/MacOS/Ferry

# 真实 SFTP 路径在 HR 下的复测（§7）
cp Spike/.build/out/Products/Debug/SpikeRunner /tmp/spike-hr
codesign --remove-signature /tmp/spike-hr
codesign --force --sign - --options runtime /tmp/spike-hr
SPIKE_PORT=2202 /tmp/spike-hr paths
/tmp/spike-hr keys

# 环境变量：FERRY_BUNDLE_ID / FERRY_SIGN_IDENTITY / FERRY_HARDENED=0 /
#           FERRY_CONFIG / FERRY_ENTITLEMENTS / FERRY_QUARANTINE_FLAGS / FERRY_STAMP /
#           FERRY_KC_SERVICE / FERRY_DLOPEN_PATH
```
