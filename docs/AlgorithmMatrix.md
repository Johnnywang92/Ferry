# Ferry 算法协商矩阵与出厂白名单（AlgorithmMatrix）

本文档记录 Ferry 在五台典型仿真服务器上的 SSH 算法协商测量结果（M1'-8 交付物），
确立**出厂默认安全基线（Modern Profile）**与**兼容老设备白名单（Legacy Profile）**，
并对齐 UI 上的“允许弱算法（CBC / SHA-1 / ssh-rsa）”开关语义。

日期：2026-10-17  
测量工具：`SpikeRunner handshake`（`SPIKE_PREFS=default/modern/legacy/bogus`）  
底层依赖：CLibssh2 1.11.1_DEV（带 10 条安全修补） + OpenSSL 3 静态链接  
架构决策归属：ADR-0000 §0 S6、ADR-0000 §9 N2、SecurityBaseline.md §1.2 / §7.4

---

## 1. 五台基准服务器画像

| 端口 | 标识 | 服务端版本 | 仿真目标 | 特性与算法局限 |
|---|---|---|---|---|
| **2201** | `sftp-atmoz` | OpenSSH_8.4p1 Debian-5+deb11u3 | 常见开源 SFTP 容器镜像（chroot） | 现代 OpenSSH，用户 chroot 到根目录 |
| **2202** | `sftp-modern` | OpenSSH_9.7p1 Alpine | 现代生产环境对照组 | 仅开强算法（Ed25519, ChaCha20, Curve25519） |
| **2203** | `sftp-legacy` | OpenSSH_9.7p1 Alpine | 仅留 DH-SHA1 / CBC 老路 | 模拟配置陈旧的堡垒机，禁用现代 KEX 与 AEAD |
| **2204** | `sftp-oldalgo` | OpenSSH_9.7p1 Alpine | 严格收窄：每维度只剩 1 种老算法 | 极端收敛老路：`dh-group14-sha1`, `ssh-rsa`, `aes256-cbc`, `hmac-sha1` |
| **2205** | `sftp-oldos` | OpenSSH_6.7p1 Debian 8 | 真实陈旧 Linux 发行版（非配置版） | 验证老系统原生支持面（OpenSSL 1.0.1t） |

---

## 2. 算法协商实测矩阵

### 2.1 现代安全模式（`Modern` · 出厂默认）

默认策略下，**拦截所有 SHA-1、CBC 和单向散列弱 MAC**，强制使用 Curve25519 / ChaCha20 / AES-CTR / ETM 认证加密。

| 端口 | 连通状态 | 耗时 | KEX 密钥交换 | 主机密钥 (HostKey) | 对称加密 (c→s / s→c) | 完整性 (MAC) | 主机指纹 (SHA-256) |
|---|---|---|---|---|---|---|---|
| **2201** | **PASS** | 148 ms | `curve25519-sha256` | `ssh-ed25519` | `chacha20-poly1305@openssh.com` | `hmac-sha2-512-etm@openssh.com` | `SHA256:lqhc0xWGheYgjqEAfMvQ0yd/fukq+FWSN21U335ignc` |
| **2202** | **PASS** | 21 ms | `curve25519-sha256` | `ssh-ed25519` | `chacha20-poly1305@openssh.com` | `hmac-sha2-512-etm@openssh.com` | `SHA256:WG3BjlCQHyChcmSQT9LFNa/hH7rGRh+RcNvvnZtYTcI` |
| **2203** | **BLOCKED** | 12 ms | *无匹配* | *无匹配* | *无匹配* | *无匹配* | 报 `protocolViolation (rc=-5)` |
| **2204** | **BLOCKED** | 7 ms | *无匹配* | *无匹配* | *无匹配* | *无匹配* | 报 `protocolViolation (rc=-5)` |
| **2205** | **PASS** | 163 ms | `curve25519-sha256@libssh.org` | `ssh-ed25519` | `chacha20-poly1305@openssh.com` | `hmac-sha2-512-etm@openssh.com` | `SHA256:8ECaEQzs7dJX4JJJKcY7SY1vX3MJ2fCLN+ZgbsghZrE` |

> **关键事实 1（2203 / 2204 被成功阻断）**：当服务器仅提供弱算法时，现代安全模式在 7~12 ms 内坚决拒连，绝不在默认状态下静默降级到 CBC 或 SHA-1。  
> **关键事实 2（老系统 2205 能跑现代算法）**：真老发行版（Debian 8 / OpenSSH 6.7p1）原生支持 `curve25519-sha256@libssh.org`、`ssh-ed25519` 与 `chacha20-poly1305`。**老服务器不等于必须用弱算法**，出厂默认现代模式对其完全可用。

---

### 2.2 兼容老设备模式（`Legacy` · 勾选“允许弱算法”）

当且仅当用户在连接对话框中显式开启“允许弱算法（CBC / SHA-1）”时激活此白名单。

| 端口 | 连通状态 | 耗时 | KEX 密钥交换 | 主机密钥 (HostKey) | 对称加密 (c→s / s→c) | 完整性 (MAC) | 主机指纹 (SHA-256) |
|---|---|---|---|---|---|---|---|
| **2201** | **PASS** | 165 ms | `diffie-hellman-group-exchange-sha256` | `ssh-rsa` | `aes128-ctr` | `hmac-sha1` | `SHA256:bqRvbdXwqPhXbWacv6AOl+kBXtRH4NRAqw82LBjPsIM` |
| **2202** | **PASS** | 44 ms | `diffie-hellman-group-exchange-sha256` | `ssh-ed25519` | `aes128-ctr` | `hmac-sha1` | `SHA256:WG3BjlCQHyChcmSQT9LFNa/hH7rGRh+RcNvvnZtYTcI` |
| **2203** | **PASS** | 16 ms | `diffie-hellman-group14-sha1` | `ssh-rsa` | `aes128-cbc` | `hmac-sha1` | `SHA256:89DaPf04+R2w5jsobu/CC3wbNMoo9XNYsqXl9Fzyays` |
| **2204** | **PASS** | 15 ms | `diffie-hellman-group14-sha1` | `ssh-rsa` | `aes128-cbc` | `hmac-sha1` | `SHA256:QQs8YZIqTo2RY1G7oGj0rXzDMAHyRRnyyg6YxMj1qa0` |
| **2205** | **PASS** | 179 ms | `diffie-hellman-group14-sha1` | `ssh-rsa` | `aes128-ctr` | `hmac-sha1` | `SHA256:ToFKwYQBl09YO215SEGXTBFmTYlxcYrdc81Suamoaqs` |

> **关键事实 3（全域连通兜底）**：开启 Legacy 之后，五台仿真环境 **100% 成功连通**。2203 / 2204 均能正常在 `diffie-hellman-group14-sha1` + `ssh-rsa` + `aes128-cbc` + `hmac-sha1` 上完成安全会话建链。

---

### 2.3 异常与非法算法探测（`Bogus`）

传入不存在的算法名称（`ferry-bogus-kex@example.com`）：

| 端口 | 连通状态 | 报错分类 | 返回码与耗时 | 表现 |
|---|---|---|---|---|
| **2201–2205** | **FAIL** | `RemoteError.protocolViolation` | `rc = -5`, 11~127 ms | 全部正确识别为会话层无公因子协商失败，无内存越界或挂起 |

---

## 3. 出厂白名单配置规范（Swift）

依据测量结论，`FerryCore.AlgorithmPreferences` 的出厂配置定义如下：

```swift
public struct AlgorithmPreferences: Sendable, Equatable {
    /// 出厂默认安全配置（强制强加密）
    public static let modern = AlgorithmPreferences(
        keyExchange: [
            "curve25519-sha256",
            "curve25519-sha256@libssh.org",
            "ecdh-sha2-nistp256",
            "diffie-hellman-group14-sha256"
        ],
        hostKey: [
            "ssh-ed25519",
            "rsa-sha2-512",
            "rsa-sha2-256",
            "ecdsa-sha2-nistp256"
        ],
        encryption: [
            "chacha20-poly1305@openssh.com",
            "aes256-gcm@openssh.com",
            "aes128-gcm@openssh.com",
            "aes256-ctr",
            "aes192-ctr",
            "aes128-ctr"
        ],
        mac: [
            "hmac-sha2-512-etm@openssh.com",
            "hmac-sha2-256-etm@openssh.com",
            "hmac-sha2-512",
            "hmac-sha2-256"
        ]
    )

    /// 兼容老设备配置（允许 CBC、SHA-1 与 ssh-rsa）
    public static let legacy = AlgorithmPreferences(
        keyExchange: [
            "curve25519-sha256",
            "curve25519-sha256@libssh.org",
            "diffie-hellman-group-exchange-sha256",
            "diffie-hellman-group14-sha256",
            "diffie-hellman-group14-sha1",
            "diffie-hellman-group1-sha1"
        ],
        hostKey: [
            "ssh-ed25519",
            "rsa-sha2-512",
            "rsa-sha2-256",
            "ecdsa-sha2-nistp256",
            "ssh-rsa"
        ],
        encryption: [
            "chacha20-poly1305@openssh.com",
            "aes256-ctr",
            "aes128-ctr",
            "aes256-cbc",
            "aes192-cbc",
            "aes128-cbc",
            "3des-cbc"
        ],
        mac: [
            "hmac-sha2-256",
            "hmac-sha1",
            "hmac-sha1-96",
            "hmac-md5"
        ]
    )
}
```

---

## 4. UI 呈现与用户交互契约

1. **默认状态**：所有新建站点与临时连接，默认采用 `modern` 白名单。
2. **弱算法开关**：连接对话框“高级设置”中提供 `允许弱算法（CBC / SHA-1 / ssh-rsa）` 复选框。
   - 未勾选时连接 2203/2204：连接弹窗明确提示“服务器仅提供不安全的旧式算法（CBC/SHA-1），已被安全策略拦截。如信任该内网设备，请在高级选项中勾选‘允许弱算法’后重试。”
   - 勾选后连接 2203/2204：连接成功，状态栏显示 `[弱算法]` 警示胶囊。
