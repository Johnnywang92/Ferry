# Spike #7/#8 · API 存在性、posix-rename 语义与私钥格式解析

日期：2026-10-15
环境：arm64 macOS，libssh2 1.11.1（Homebrew，`libssh2_crypto_engine() = openssl`，bottle 链接 OpenSSL 4.0.3）
服务器：`sftp-modern`（OpenSSH 9.7，2202）与 `sftp-legacy`（OpenSSH legacy profile，2203）
测量：`Spike/Scripts/api-probe.sh`（链接期探针）、`Spike/Sources/SpikeRunner/RenameSpike.swift`（`spike rename`）、
`Spike/Sources/SpikeRunner/KeySpike.swift` + `Spike/Scripts/keys.sh`（`spike keys`）

---

## 0. 结论先说

| # | 结论 | 影响 |
|---|---|---|
| 1 | **`libssh2_session_set_abort_fn()` 不存在**（头文件无声明，dylib 无符号）。同样不存在的还有 `libssh2_transport_set_sendsize()`。 | v2.3 §296"不把它作为方案前提"是对的，且现在可以定死：**取消只能靠非阻塞 poll + `shutdown(socket)`**（spike #4/#5 已量化）。M0b 不用为它留抽象位 |
| 2 | **`posix-rename@openssh.com` 在 1.11.1 里有原生入口且实测可用**：`libssh2_sftp_posix_rename_ex()` 在 modern 与 legacy 两台 OpenSSH 上，目标存在/不存在两种情况都 `rc=0`、源消失、目标就位（原子覆盖）。 | 上传重名冲突要"原子替换"时，直接调它。不需要自己拼 SSH_FXP_EXTENDED |
| 3 | **不要依赖 `libssh2_sftp_rename_ex()` 的 flags 语义**：目标已存在时，`NATIVE`、`OVERWRITE\|ATOMIC`、以及便利宏 `OVERWRITE\|ATOMIC\|NATIVE` 三种都返回 `rc=-31 / SSH_FX_FAILURE(4)`——**给了 OVERWRITE 也不会覆盖**。 | "覆盖重命名"必须显式走 `posix_rename_ex`；`sftp_rename` 宏看起来像"全能默认值"，实际会在覆盖场景失败，这是个会踩的坑 |
| 4 | **加密后端（OpenSSL）能完整解析 `openssh-key-v1` + bcrypt，且有 `frommemory` 入口**：ed25519 / rsa3072 / ecdsa256 三种 openssh 新格式带口令私钥，`frommemory` 与 `fromfile` 都 `rc=0`（认证成功）。老式 PEM+口令也通过。 | **不需要写 Swift 预解析器**（v2.3 的判定条件满足）。Keychain 取出的字节可以直接喂 `libssh2_userauth_publickey_frommemory` |
| 5 | **bcrypt 解锁的代价是 450–500 ms，比明文/老式 PEM 高 20 倍**（ed25519 明文 26–32 ms，老式 PEM 口令 23 ms）。 | 认证一次后必须复用 session；每次重连都重新解析私钥会让"重连"变成半秒级操作。这也再次压向方案 A 的长连接池 |
| 6 | **`libssh2_agent_init(NULL)` 直接段错误**（`_libssh2_calloc` 解引用 session 的 allocator）。传一个已建好的 session 后 `agent_connect` rc=0，`list_identities` rc=0 可正常枚举。 | M2 接 ssh-agent 时的硬约束：**agent句柄必须挂在 session 上创建**，不能先建 agent 再连。这是本轮唯一发现的"会崩而非报错"的 API |
| 7 | 25 个候选 API 里 **23 个可用**；`keepalive_config/send`、`session_methods`、`session_banner_get`、`knownhost_addc/checkp`、`sftp_fsync`、`sftp_statvfs`、`keyboard_interactive`、`agent_*` 全套都在 | M1/M2 的功能清单不会因为"libssh2 没这个 API"而砍项 |

## 1. #7 链接期探针（不是只看头文件）

`Spike/Scripts/api-probe.sh` 对每个符号生成 `void *p = (void*)&sym;` 的 C 文件，
**真编译真链接**当前这份 dylib；编译失败=头文件没声明，链接失败=库里没符号。

```
可用 23 / 不可用 2
不可用：libssh2_session_set_abort_fn（头文件里没有声明）
不可用：libssh2_transport_set_sendsize（头文件里没有声明）
```

函数式宏（`libssh2_sftp_posix_rename`、`libssh2_sftp_rename`、`libssh2_userauth_password` 等）
在头文件里只是宏，Swift 导不到——探针刻意用 `_ex` 真函数名，避免"宏在、Swift 用不了"的误判。
另注意两个易错真名：`libssh2_userauth_publickey_frommemory`（**没有** `_ex` 版本）、
`libssh2_session_banner_get`（不是 `libssh2_banner_get`）。

## 2. #7 运行时：posix-rename 与 rename flags（两台服务器结果完全一致）

```
posix_rename，目标不存在                  rc=0   源已消失，目标存在
posix_rename，目标已存在                  rc=0   源已消失，目标存在
rename_ex NATIVE，目标不存在              rc=0   源已消失，目标存在
rename_ex NATIVE，目标已存在              rc=-31 源仍在，目标存在；sftp_last_error=4 (SSH_FX_FAILURE)
rename_ex OVERWRITE|ATOMIC|NATIVE，目标已存在  rc=-31 同上
rename_ex OVERWRITE|ATOMIC，目标已存在        rc=-31 同上
```

- `sftp_last_error=4` 是 OpenSSH 对"重命名到已存在目标"的通用失败；
  libssh2 即使收到 `OVERWRITE|ATOMIC` 也没走 posix-rename 模拟，说明**它的 flags 模拟路径在 1.11.1 上不可信**。
- Core 的 `RemoteFileService.rename` 需要两个显式入口：`renameNative`（POSIX 语义，目标存在即失败）
  与 `replaceAtomically`（`posix_rename_ex`）。方案 v2.3 里"上传完成后临时文件→正式名"要用后者。
- **未覆盖的情况**：不支持 posix-rename 扩展的服务器。三台仿真机（atmoz / modern / legacy）都是 OpenSSH，
  都带这个扩展。真实设备（某些厂商 SFTP、Win32-OpenSSH 旧版）不带时 `posix_rename_ex` 返回什么，
  留到 M1 用真机补测；实现上应先探测再退化到"native rename + 目标已存在则按冲突策略处理"。

## 3. #8 私钥格式解析（含 Keychain 路径）

| 私钥 | 入口 | rc | 耗时 ms | 判定 |
|---|---|---|---|---|
| ed25519 `openssh-key-v1` + bcrypt + aes256-ctr（有口令） | frommemory | 0 | 471.4 | 解析并认证成功 |
| 同上 | fromfile | 0 | 504.1 | 同上 |
| ed25519 `openssh-key-v1` 明文 | frommemory / fromfile | 0 | 26.4 / 32.5 | 成功 |
| rsa3072 `openssh-key-v1` + bcrypt | frommemory / fromfile | 0 | 481.9 / 458.2 | 成功 |
| ecdsa256 `openssh-key-v1` + bcrypt | frommemory / fromfile | 0 | 448.0 / 444.4 | 成功 |
| rsa2048 老式 PEM + 口令（3DES/MD5 KDF） | frommemory / fromfile | 0 | 22.9 / 23.2 | 成功 |
| ed25519 bcrypt，**口令错误** | frommemory | -16 | 220.7 | `Unsupported private key file format` |
| 同上 | fromfile | -16 | 215.2 | `Wrong passphrase or invalid/unrecognized private key file format` |
| 文件不存在 | fromfile | -16 | 0.0 | `Unable to open private key file` |

要点：
1. `rc=0` 意味着**认证成功**（公钥由 `Spike/Scripts/keys.sh` 装进了容器 `authorized_keys`），
   所以从"解出私钥"到"签名被服务器接受"整条链路都通，不只是解析。
2. **口令错与格式不支持共用 `-16 (LIBSSH2_ERROR_FILE)`**，而且 `frommemory` 的文案会把"口令错"说成
   "Unsupported private key file format"。⇒ Core 的错误分类**不能信 libssh2 的字符串**，
   要自己区分：文件读不到（我们还没进 libssh2）/ 能读到字节但解不开（多半是口令错）/
   解开了但服务器拒绝（`-18 AUTHENTICATION_FAILED`）。这是 M2 凭据表单的验收项。
3. bcrypt 一轮 KDF ≈ 0.22 s（失败也要跑完），成功路径 ≈ 0.45–0.5 s。
   UI 上"选择私钥文件"要按一次解锁的预算设计（显示进度而非静默卡顿），
   且**同一 session 生命周期内只解析一次**。

## 4. 对 M0b / M2 的落地约束

1. 取消机制定案不再需要 `set_abort_fn` 分支（§1）。
2. `RemoteFileService` 的重命名接口拆成两个语义，覆盖替换只走 `posix_rename_ex`（§2）。
3. 认证器优先 `frommemory`（Keychain 出来的是字节），`fromfile` 只用于用户直接指路径的场景。
4. 凭据错误分类自己实现，不映射 libssh2 文案（§3 要点 2）。
5. agent 路径可用但必须在 session 之后创建（§0 结论 6）。
6. **全部结果需在 M0b 锁定的 OpenSSL 3.x xcframework 上重跑一遍**：
   本机 bottle 链接的是 OpenSSL 4.0.3，crypto backend 换了以后 §1 的符号集与 §3 的格式支持都可能漂移。

## 5. 复现

```bash
./Spike/Scripts/api-probe.sh                 # 符号存在性（编译+链接）
./Spike/Scripts/keys.sh                      # 生成 5 种私钥并把公钥装进容器
cd Spike && swift build
.build/debug/SpikeRunner rename              # 2202
SPIKE_PORT=2203 .build/debug/SpikeRunner rename   # 2203（需先 mkdir /home/tester/spike/upload）
SPIKE_PORT=2203 .build/debug/SpikeRunner keys      # 同上，容器内需有对应公钥
```
