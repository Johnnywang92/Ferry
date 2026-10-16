# M1-01：M1' 环境 —— 五台服务器与临时 ssh-agent

对应任务 #17（M1'-1）。ADR-0000 §9 N2（老设备仿真题式）与 N4（ssh-agent 测试环境）在这一节落地。
做完之后 M1' 的连通矩阵（#24）不再需要动环境，只需要跑测量。

## 0. 结论

1. **五台全部可用**：`2201/2202/2203/2204/2205` 都能完成 kex，都能用同一把临时 RSA 密钥**经临时 agent** 认证成功，SFTP subsystem 实测可用（`pwd`/`ls -l /` 出结果）。
2. **2204 生效的方式和 2203 不同，而且差得很关键**：2203 谈成了 `diffie-hellman-group14-sha256`（配置里 sha1 只是并列可选项），2204 只有 `diffie-hellman-group14-sha1` 一条路 —— 客户端不放开 SHA-1 KEX 就**根本连不上**（`no matching key exchange method found`）。矩阵要的"这一格是算法本身挡住，还是恰好能绕"，靠这两台的差值区分。
3. **`sshd -T` 不等于线路 offer**（2205 实测）：`-T` 打的是这台 sshd **编译支持**的全集，线路上发的是**默认启用子集**。jessie 的 6.7p1 `-T` 里有 `arcfour/3des-cbc/*-cbc/hmac-md5/diffie-hellman-group1-sha1`，实际 offer 里一个都没有。**#24 只能按线路实测，不能拿 `-T` 当矩阵输入。**
4. **`ssh-dss` 只有 2205 能给，而且只能从容器里测**：Alpine 9.7 的 `ssh-keygen -A` 只生成 RSA/ECDSA/ED25519（日志原话），本机 macOS 的 OpenSSH 10.3 已经把 DSA 整个编译掉（`-oHostKeyAlgorithms=+ssh-dss` → `Bad key types`，命令行直接退出）。容器里的 9.7 客户端强制 `HostKeyAlgorithms=ssh-dss` 谈得成 ⇒ 2205 确实发 DSA 主机密钥，这台是唯一能填这格的服务器。
5. **老算法里有一批没有任何一台服务器默认提供**：`diffie-hellman-group1-sha1`、`hmac-md5`、`3des-cbc`、`arcfour`、`ssh-dss`。要测这些格子，只能给某台加显式配置（那它就变成配置版仿真），或者标未测。这是 #24 开工前的一次决策，不是环境缺陷（见 §7 待核 3）。
6. **`ls -l` 的属性完整度按服务器版本变**：同一台 Mac 客户端，对 2201(8.4p1) 拿到硬链接数 `3`，对 2205(6.7p1) 拿到 `2`，对 2202/2203/2204(9.7p1) 全是 `?`。⇒ 目录列表（#21）不能假设 stat 字段齐全，契约测试（#23）要有一台"回不全"的。机制未查证，见 §7 待核 4。

## 1. 五台是什么

| 端口 | 容器 | banner / sshd | 定位 | 认证方法（线路实测） |
|---|---|---|---|---|
| 2201 | `ferry-sftp-atmoz` | OpenSSH_8.4p1 Debian-5+deb11u3（OpenSSL 1.1.1w） | atmoz/sftp 主测试环境，chroot 到用户目录 | publickey, password, keyboard-interactive |
| 2202 | `ferry-sftp-modern` | OpenSSH_9.7（OpenSSL 3.3.7） | 现代对照组，能挂 `tc netem` | publickey, password |
| 2203 | `ferry-sftp-legacy` | OpenSSH_9.7 | 老算法仿真，**留了 sha256 兜底** | publickey, password |
| 2204 | `ferry-sftp-oldalgo` | OpenSSH_9.7 | **本轮新增**：每个维度只剩一条 SHA-1/CBC 老路 | publickey, password |
| 2205 | `ferry-sftp-oldos` | OpenSSH_6.7p1 Debian-5+deb8u4（OpenSSL 1.0.1t） | **本轮新增**：真老发行版，算法一律不挑，跑它自己的默认 | publickey, password, keyboard-interactive |

2201 的 sshd 是 8.4p1 而不是"很老的东西"——`atmoz/sftp:latest` 现在是 Debian 11 基础镜像。M0a 拿它当主环境没问题，但它不能充当"老设备"，本轮之前这一点在文档里没有明说。

## 2. 两台新服务器怎么搭的

### 2204（`docker/openssh/sshd/sshd_oldalgo.conf`）

关键不在于"配了老算法"，而在于**每个维度只留一个选项，且用整值赋值而不是 `+` 追加**：

```
HostKeyAlgorithms ssh-rsa
PubkeyAcceptedAlgorithms ssh-rsa          # 不是 +ssh-rsa ⇒ 非 RSA 的用户密钥必须被拒
RequiredRSASize 1024
KexAlgorithms diffie-hellman-group14-sha1 # 没有 sha256 兜底
Ciphers aes128-cbc,aes256-cbc
MACs hmac-sha1,hmac-sha1-96
```

`RequiredRSASize 1024` 是为了能吃下老设备那种 1024 位密钥（OpenSSH 8.8 起默认拒）；这台自己的主机密钥是 3072 位（`ssh-keygen -A` 的默认），1024 那格还没实测。

### 2205（`docker/oldos/`）

`FROM debian:jessie` + `openssh-server`。四个坑，都是构建期真实踩到的：

| 坑 | 现象 | 处理 |
|---|---|---|
| jessie 已 EOL | 主仓库与 security 仓库都下线，`apt-get update` 拿不到索引 | sources 指向 `archive.debian.org`，`[trusted=yes]`（索引密钥早过期），命令行 `-o Acquire::Check-Valid-Until=false`（apt 1.0 不认 sources 里的 `check-valid-until` 选项，只能在命令行给） |
| 索引没有翻译文件 | 一批 `Packages.gz` 之外的下载必然失败 | `-o Acquire::Languages=none` |
| 容器里起不来 | jessie 默认 `UsePrivilegeSeparation sandbox` 要特权命名空间，没给 `CAP_SYS_ADMIN` 直接退出 | sshd_config 写 `UsePrivilegeSeparation no` |
| 想要 keyboard-interactive | 老版本走 PAM 才发得出来，且关键字有两个名字 | `UsePAM yes` + `ChallengeResponseAuthentication yes`；线路上确实发来了 keyboard-interactive（§1 表）。顺带量了一件事：这台 6.7p1 对 `KbdInteractiveAuthentication` 也认（`sshd -t` 不报错，而对乱写的 `BogusKeyword` 会报 `Bad configuration option`），所以"新名要 7.x 才可用"这种说法在本依赖集上不能当依据 |

主机密钥四种类型全部显式生成，`ssh-dss` 那把是 1024 位（`ssh-keygen` 对 DSA 的固定长度）——这正是 2204 那台给不出来的东西。

官方镜像只有 `386/arm/amd64`，**没有 arm64** ⇒ 本机走转译。和 atmoz 一样的老问题（M0a-01 记过 `sftp_init` 慢约 200 倍）：**2205 的延迟类数字不能和 2202/2203/2204 并排比**。

## 3. 协商实测：客户端默认 vs 放开老算法

工具：`Spike/Scripts/negotiation-probe.sh`（每台三份日志）。客户端是 macOS 系统 OpenSSH 10.3p1。
"放开"用的是 `+` 追加，不整值替换 —— 否则测到的是我们强喂的算法，不是"客户端愿意接受时会选什么"。

| 端口 | 默认：kex | 默认：主机密钥 | 默认结果 | 放开后：kex / hostkey / cipher+MAC |
|---|---|---|---|---|
| 2201 | curve25519-sha256 | ssh-ed25519 | 通 | 同默认（没有老算法可放） |
| 2202 | sntrup761x25519-sha512@openssh.com | ssh-ed25519 | 通 | 同默认 |
| 2203 | diffie-hellman-group14-sha256 | **(no match)** | **挡**：`no matching host key type found. Their offer: ssh-rsa` | dh-group14-sha256 / ssh-rsa / aes128-cbc + hmac-sha1 |
| 2204 | **(no match)** | 未到 | **挡**：`no matching key exchange method found. Their offer: diffie-hellman-group14-sha1,ext-info-s,kex-strict-s-v00@openssh.com` | dh-group14-sha1 / ssh-rsa / aes128-cbc + hmac-sha1 |
| 2205 | curve25519-sha256@libssh.org | ssh-ed25519 | 通 | 同默认 |

三点值得单独记住：

- 2202/2203/2204 是同一个 OpenSSH 9.7，但 2202 的 `HostKeyAlgorithms` 默认列表里**已经没有 `ssh-rsa`**（`sshd -T` 输出里查不到它）。所以"服务器是新版"不等于"给得出 ssh-rsa 主机密钥"，也不等于"给不出"——是配置决定的。
- 2203 那一行是本轮最有价值的一行：kex 谈成了 `group14-sha256`，说明配置里的 `diffie-hellman-group14-sha1` 从没被选中过；M0a 用 2203 得到的"老设备可连"结论里，SHA-1 KEX 那部分实际没被测到。2204 就是为补这个洞加的。
- 2205 在**客户端完全不放开**的情况下就能连（curve25519 + ed25519 + chacha20 是 6.7 的默认能力）。"年代老"不等于"算法老到连不上"，这两件事必须分开测——正好是 N2 说的那个第二变量列。

## 4. `sshd -T` 与线路 offer 的差（2205）

同一台 2205，两个来源给的清单不一样：

| 维度 | `sshd -T`（编译支持全集） | 线路 offer（强制失配法实测三次，一致） |
|---|---|---|
| kex | 含 `diffie-hellman-group1-sha1`（还重复出现两次）、`diffie-hellman-group-exchange-sha1` | `curve25519-sha256@libssh.org, ecdh-sha2-nistp256/384/521, diffie-hellman-group-exchange-sha256, diffie-hellman-group14-sha1`（6 项，无 group1、无 gex-sha1） |
| cipher | 含 `3des-cbc, blowfish-cbc, cast128-cbc, arcfour*, aes*-cbc, rijndael-cbc@lysator.liu.se` | `aes128/192/256-ctr, aes128/256-gcm@openssh.com, chacha20-poly1305@openssh.com`（6 项，**无任何 CBC**） |
| MAC | 含 `hmac-md5, hmac-md5-96, hmac-ripemd160*, hmac-sha1-96*` | `umac-64/128-etm, hmac-sha2-256/512-etm, hmac-sha1-etm, umac-64/128, hmac-sha2-256/512, hmac-sha1`（10 项，无 md5、无 -96） |
| 主机密钥 | `-T` 里没有这个关键字（6.7 没有服务端 `HostKeyAlgorithms`），密钥文件给出 `ssh-dss ecdsa-sha2-nistp256 ssh-ed25519 ssh-rsa` | 强制 `HostKeyAlgorithms=ssh-dss` 谈成 ⇒ **ssh-dss 真的在发**（从容器里的 9.7 客户端测；Mac 10.3 不支持 DSA，测不了这一格） |

差集是哪一版关掉的、按什么规则关的，没有查上游记录，不在这里下结论（§7 待核 1）。
对本项目的直接含义只有一条：**矩阵的服务器列必须来自线路实测**。

顺带把三个客户端的编译支持面量了（`ssh -Q`，注意这是"这个客户端会不会用"，不是"服务器发不发"）：

| 客户端 | CBC/3DES | arcfour | group1-sha1 / gex-sha1 | md5 与 -96 MAC | ssh-dss |
|---|---|---|---|---|---|
| macOS OpenSSH 10.3p1（LibreSSL） | `3des-cbc, aes128/192/256-cbc` | 无 | 都有 | 都有（含 6 个 etm 变体） | **无**：`-Q key` 里根本没有，`+ssh-dss` 直接 `Bad key types` |
| Alpine 容器 OpenSSH 9.7p1（OpenSSL 3.3.7） | 同上 | 无 | 都有 | 都有 | 有 |
| jessie 容器 OpenSSH 6.7p1（OpenSSL 1.0.1t） | 上述 + `blowfish-cbc, cast128-cbc, rijndael-cbc@lysator.liu.se` | **有**（arcfour/128/256） | 都有 | 都有 | 有 |

⇒ `arcfour` 只有真老的那台客户端会讲；`ssh-dss` 只有本机的新 ssh 不会讲。客户端能不能用某算法 ≠ 服务器会不会发它，两边都要查，矩阵才解释得了"谈不成"是谁的锅。

## 5. 临时 ssh-agent

工具：`Spike/Scripts/ssh-agent-test.sh`。隔离面：临时 HOME + 临时 socket + 只加载自己生成的两把明文密钥（RSA 2048 + ed25519）。不 `launchctl setenv`，不读也不写调用方的 `SSH_AUTH_SOCK`（进来之时的值原样打印一次，跑完仍是那个值）。

结果：**五台全部 `Authenticated to ... using "publickey"`，key 来源都是 `(agent)`**，用的都是那把 RSA（客户端先试 RSA，ed25519 没轮到）。

反向对照（这一步才让上面那句有意义）：把 agent 清成**只剩 ed25519** ——

| 端口 | 预期（按配置推） | 实测 |
|---|---|---|
| 2203 | 可用（`PubkeyAcceptedAlgorithms +ssh-rsa` 是追加，现代列表仍在） | rc=0，`Authenticated ... using "publickey"` |
| 2204 | 被拒（整值赋值 `ssh-rsa`，非 RSA 一律不收） | rc=255，`Permission denied (publickey,password)` |

⇒ 2204 那行配置确实在拦，不是注释。#20 测公钥认证时要拿这个当基准。

三个环境坑（都写进脚本注释了，因为它们的报错形状会骗人）：

1. **换掉 `HOME` 之后 docker 说"守护进程没在跑"**：docker CLI 用 HOME 找 context 与 socket（本机在 `~/.docker/run/docker.sock`），HOME 一换它退化成 `/var/run/docker.sock` 报连不上——看着像五台容器全挂了。脚本在换 HOME 之前先把 `DOCKER_HOST` 固化。
2. **atmoz 的 `chown tester:tester` 失败**：它的运行期建用户把组名做成 `group_1001`，用户主组不是同名组。脚本改用 `id -u/-g` 的数字形式。
3. **"命令跑不通"≠"认证失败"**：2201 的 `tester` shell 是 `/bin/false`（SFTP-only 设备的常态），认证通过后远程命令必然 rc=1；另外 `/home/tester/.ssh` 归 root 时公钥认证过不了，把属主改成 tester 自己就过了。判据因此定在 `Authenticated to` 那一行，不是退出码。SFTP-only 的服务器只支持 subsystem，正是我们产品的用法。
4. **`Spike/Scripts/keys.sh` 会覆盖 `authorized_keys`**（它是 `cat > authorized_keys`，不是追加），跑完它，本轮装进去的临时 agent 公钥就没了，`ssh-agent-test.sh` 要重跑一次补回去。#20 同时用两套密钥时这是个真会撞上的顺序依赖。
5. **反过来那一侧也得裁剪**：`ssh-agent-test.sh` 每跑一次都新生成一对 `ferry-agent-test` 密钥，纯 append 会让 2202 的 `authorized_keys` 只增不减（本轮实测跑到 47 行）。脚本现在先摘掉自己上一轮那些以 ` ferry-agent-test` 结尾的行再装新的，`keys.sh` 那五把语料公钥一行都不动。这不只是整洁问题：#20 的 `MaxAuthTries` 预算实测（M1-04 §2.3）算的是"一条连接上能试几轮"，而 agent 路上**每把钥匙都是一次完整尝试**，表里堆几十行就会让"哪把被拒"这件事和"额度用尽"混成同一个 `-18`。

## 6. 出口标准对照

| 要求（任务 #17） | 状态 | 证据 |
|---|---|---|
| 2204：新版 sshd 限老算法集合（ssh-rsa + dh-group14-sha1 + aes*-cbc + hmac-sha1） | 达成 | §3 表 2204 行；默认被挡、放开后四个维度全落在老集合上 |
| 2205：真老发行版跑真老 openssh | 达成，**没有顶替** | OpenSSH_6.7p1 Debian-5+deb8u4 / OpenSSL 1.0.1t；`docker compose build sftp-oldos` 走通 |
| 拉不动就标未测 | 未触发 | jessie 镜像可拉，构建成功 |
| 临时 ssh-agent 脚本，不动本机登录会话 | 达成 | §5，五台 + 反向对照 |
| 五台都能被 OpenSSH 客户端连通，并记下协商到的参数 | 达成 | `Spike/Scripts/negotiation-probe.sh` 汇总"0 台谈不成 kex"；参数见 §3、§4 |
| SFTP subsystem 可用（顺带，#22/#21 要用） | 达成 | 2201/2202/2203/2204/2205 `pwd`+`ls -l /` 出结果；2204/2205 见 §0.6 的属性差异 |

还没做的（不属于本节出口标准，留到用到时）：2204/2205 上没有 spike 语料（`docker compose exec -u root sftp-oldalgo /seed-corpus.sh`；2205 那个镜像里没有这个脚本，#22 要用再拷），以及 2205 走转译、延迟数字不可比。

## 7. 待核

| # | 项 | 影响 |
|---|---|---|
| 1 | 6.7p1 的 `sshd -T` 与线路 offer 差集是谁关的、按什么规则 | 只影响"要不要相信 `-T`"这个工具选择，结论已经够用：**矩阵按线路实测** |
| 2 | 2204 的 `RequiredRSASize 1024` 是否真能接受 1024 位 RSA 用户密钥 | #20 测老密钥时要单独造一把 1024 位 RSA，现在只有配置意图，没有实测 |
| 3 | `dh-group1-sha1`、`hmac-md5`、`3des-cbc`、`arcfour`、`ssh-dss` 这五类**没有任何一台服务器默认发** | #24 开工前要决定：加一台"显式打开全集"的服务器（那就不是默认老设备，是算法夹具），还是这几格标未测。两个选择都合法，但要在矩阵里写清是哪一种 |
| 4 | 9.7 的 internal-sftp 在 `ls -l` 里不回硬链接数（`?`），8.4 和 6.7 回 | #21 的 stat 映射要允许字段缺失；#23 契约测试拿 9.7 和 6.7 各一台做正反例 |
| 5 | 2205 走转译，`sftp_init` 等延迟数据不可与原生 arm64 那几台比较 | 沿用 M0a-01 对 atmoz 的同一条纪律：吞吐/延迟基准只用 2202 |

## 8. 复现

```bash
docker compose up -d sftp-oldalgo sftp-oldos          # 首次会自动 build
Spike/Scripts/negotiation-probe.sh                    # 五台的协商事实，日志落 /tmp/ferry-negotiation
Spike/Scripts/ssh-agent-test.sh                       # 临时 agent：五台认证 + 反向对照
Spike/Scripts/ssh-agent-test.sh -- <cmd…>             # 在同一 agent 下跑任意命令（矩阵、sftp 都好用）

# §4 的 ssh-dss 那一格只能从容器测（Mac 的 10.3 没有 DSA）：
docker exec ferry-sftp-modern-1 ssh -vv -oBatchMode=yes -oStrictHostKeyChecking=no \
    -oUserKnownHostsFile=/dev/null -oHostKeyAlgorithms=ssh-dss \
    -oKexAlgorithms=diffie-hellman-group14-sha1 -oCiphers=aes128-cbc -oMACs=hmac-sha1 \
    -p 2205 tester@host.docker.internal true        # 期望：kex: host key algorithm: ssh-dss

# §4 的"线路 offer"用整值赋值强制失配，让 sshd 把它的清单打在错误里：
ssh -p 2205 -oKexAlgorithms=diffie-hellman-group1-sha1 tester@127.0.0.1 true   # Their offer: …
```
