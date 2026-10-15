# Spike #1 · 同一 session 上多次 `libssh2_sftp_init()`

日期:2026-10-15
执行人:M0a 第 1 天验证项
被测:`libssh2 1.11.1`（Homebrew 开发版，见文末基线说明）

---

## 结论

**v2.1/v2.2 的纠偏成立：SSH-2 单 session 可以开多个 SFTP channel，限制来自服务端 `MaxSessions`，不是协议。**

两台服务器都在第 11 次 `sftp_init()` 失败，错误码 `-21 = LIBSSH2_ERROR_CHANNEL_FAILURE`，消息 `Unable to startup channel`，与容器里显式配置的 `MaxSessions 10` 完全吻合。

这条事实的直接后果：**"多 Session 连接池"这个主选方案的立项理由必须换成"多核并行加解密 + 突破单 TCP 流 BDP 限制"**，而不是"协议不允许"。方案文档 v2.2 差异清单 #11 已这么写，本次实测予以确认。

## 数据

| 服务器 | 端口 | 架构 | 前 10 次 `sftp_init` 单次耗时 | 第 11 次 |
|---|---|---|---|---|
| 自建 OpenSSH 9.7（modern） | 2202 | linux/arm64 原生 | 1~4 ms | `-21` 失败 |
| `atmoz/sftp:latest` | 2201 | **linux/amd64，走 Rosetta 转译** | 390~433 ms | `-21` 失败 |

两台都成功建立 10 个 channel，会话与认证均正常。

## 对测试环境的修正

`atmoz/sftp` 官方镜像只出 amd64。在本机（纯 arm64、且已定为唯一产物架构）它跑在 Rosetta 下，**单次 `sftp_init` 慢约 200 倍**。因此：

- `atmoz/sftp` 只用于**功能/兼容性**验证（目录语义、权限位、OpenSSH 扩展行为）。
- **spike #2/#3 的吞吐与 CPU 测量、spike #6 的 1000 小文件基准，必须改用原生 arm64 的 `sftp-modern`（2202）**，否则测出来的是转译开销，会系统性误导并发方案选型。

这一条已写进 `docker-compose.yml` 的注释要求，M0a 后续 spike 按此执行。

## 顺带发现的工程事实

Swift 无法导入 libssh2 的函数式宏，`Backends` 层必须自带薄封装，不能用"直觉 API 名"直接调：

- `libssh2_session_init()` → 需 `libssh2_session_init_ex(nil, nil, nil, nil)`
- `libssh2_userauth_password()` → 需 `libssh2_userauth_password_ex()` 并自传 `strlen`
- `libssh2_session_disconnect()` → 需 `libssh2_session_disconnect_ex()`
- `libssh2_sftp_shutdown` 等 SFTP 符号在 `libssh2_sftp.h`，`libssh2.h` 不含它 → modulemap 需要 umbrella header

## 基线与待复核

本 spike 链接的是 Homebrew `libssh2 1.11.1_7`，而该 bottle 被链到 **OpenSSL 4.0.3**，不是最终要用的 OpenSSL 3.x。

- 本条结论（多 channel 与 `MaxSessions`）与加密后端无关，**可直接采信**。
- spike #7（`posix-rename@openssh.com`、`set_abort_fn` 的 API 存在性）与 #8（`openssh-key-v1` + bcrypt 私钥解析）**受 OpenSSL 版本影响，M0b 用锁定 commit + 静态 OpenSSL 3.x 的 xcframework 后必须重跑**。

## 复现方式

```bash
docker compose up -d --build
cd Spike && swift build
SPIKE_PORT=2202 .build/debug/SpikeRunner 12   # 原生 arm64 对照组
SPIKE_PORT=2201 .build/debug/SpikeRunner 12   # atmoz，仅功能验证
```
