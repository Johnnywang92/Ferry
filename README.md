# Ferry

<p align="center">
  <img src="App/Support/AppIcon.png" width="128" height="128" alt="Ferry Icon" />
</p>

<p align="center">
  <strong>专为 macOS 设计的现代化、高韧性 SFTP / FTP / FTPS 双栏文件传输客户端</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Platform-macOS%2015%2B%20(Apple%20Silicon)-blue" alt="macOS 15+" />
  <img src="https://img.shields.io/badge/Language-Swift%206%20(Strict%20Concurrency)-orange" alt="Swift 6" />
  <img src="https://img.shields.io/badge/Version-1.0.0--beta.1-green" alt="Version 1.0.0-beta.1" />
  <img src="https://img.shields.io/badge/Status-Beta%20Ready-success" alt="Beta Ready" />
</p>

---

## 📖 项目简介

Ferry 是一款遵循 Apple 现代化设计哲学的高性能文件传输工具。项目以 **“核心零 C 依赖、传输严格防御、用户数据零丢失”** 为核心准则，从底层协议契约、并发传输队列到三方同步引擎全面采用 Swift 6 严格并发架构构建。

---

## ✨ 核心特性

### 1. 多协议连接与安全认证
- **协议覆盖**：完整支持 **SFTP**（基于静态内联编译的 `libssh2 1.11.1` + `OpenSSL 3` xcframework，无外部动态库污染）与 **FTP / FTPS**（基于 macOS 系统级 `libcurl` 与 TLS 1.3）；
- **全模式认证矩阵**：
  - 密码认证（登录密码安全存入 macOS 登录钥匙串 Keychain）；
  - 私钥认证（支持 OpenSSH 新格式、PEM、加密私钥口令解锁，并预读头部识别形态）；
  - `ssh-agent` 本地密钥代理转发与直连；
  - 键盘交互认证（Keyboard-Interactive 动态多步弹窗交互）；
  - FTP 匿名身份（`anonymous`）快速接入；
- **主机密钥信任（TOFU）**：首连询问录入、复用与维护 `~/.ssh/known_hosts`；遇到公钥指纹变更实施硬阻断警告，并提供一键自助移除防呆能力。

### 2. 双栏原生交互与设计系统
- **AppKit + SwiftUI 双栈融合**：
  - 中央双栏文件树采用高性能 AppKit 原生渲染，支持完整拖拽矩阵（外部文件拖入/双栏互拖/拖出回写）、空格键 Quick Look 极速预览、文件就地重命名与外部编辑器监视实时回传保存；
  - 窗口框架、工具栏、队列面板与弹窗全面采用 SwiftUI 现代响应式设计，适配深浅双色与可配置 4 档强调色；
- **精准字符集与路径词法**：
  - 寻址永远遵从底层 `wireBytes`，文件名解码支持 UTF-8、GBK、GB18030 与 Big5 切换，对非规范字节提供十六进制视图降级，绝不出现截断或乱码覆写；
  - 支持 `⌘⇧G` 快速前往路径与 `⌘⇧.` 隐藏文件实时切换；
  - 顶部即时搜索框实现双栏列表毫秒级过滤（零额外网络往返）。

### 3. 弹性传输引擎 (TransferQueue)
- **调度与并发控制**：默认 N=3 任务并发，单任务异常隔离，支持平滑令牌桶限速；
- **暂停与取消语义严格解耦**：
  - **暂停**：保留本地 `.part` 临时文件与已传输字节偏移，支持断点续传；
  - **取消**：200ms 内立即打断阻塞传输，自动清理目标端临时残片并转置状态；
- **续传置信度自检**：续传前自动校验远端文件大小与修改时间，避免服务器文件变更导致的静默写入损坏；
- **网络退避重试**：精准区分网络抖动与协议错误，仅对可恢复网络异常执行 1s / 2s / 4s 指数退避重试；
- **崩溃自动恢复**：500ms 防抖落盘，重启后自动将未决任务安全转为暂停待续。

### 4. 三方同步引擎 (3-Way Sync Engine & DiffPlan)
- **基线快照对齐**：本地与服务器分别记录 stat，通过基准快照精准捕捉双端变更；
- **真值表判定与冲突识别**：严格区分 `notFound` 与网络中断，避免网络抖动误判删除；
- **出口级冲突拦截**：双端同时修改同一文件精准标记冲突，绝不静默覆盖；
- **DiffPlan 可视化预览**：同步前呈现上行、下行、删除与冲突统计，支持行内决断（以本地为准 / 以远端为准 / 保留双份 / 跳过），支持导出 DiffPlan JSON 审计；
- **安全删除策略**：删除默认强制关闭，开启需显式二次确认。

### 5. 可观测性与维护保障
- **脱敏诊断报告**：一键导出包含软硬件环境、脱敏连接参数（密码与私钥绝不记录、用户名掩码保护）、协商算法与队列快照的报告；
- **智能错误映射表**：内置常见错误（`EHOSTUNREACH`、`ECONNRESET`、`EACCES`、`keyCollision`、`undecodablePath` 等）至用户可读排查建议的转换；
- **自动更新**：支持遵循 Sparkle 2 规范的在线检测与静默升级；
- **沙盒平滑迁移预留**：全系统使用 [`ScopedBookmark`](docs/SANDBOX-MIGRATION.md) 封装本地路径，无损平滑切换 Mac App Store 沙盒环境。

---

## 🛠 构建与测试

### 系统要求
- macOS 15.0+ (Sequoia) 及以上
- Apple Silicon (arm64) 架构
- Xcode 16.0+ 或 Swift 6.0+ 工具链

### 1. 运行单元与契约测试
```bash
# 运行 Core 核心组件测试（包含同步引擎、传输队列、冲突策略、SSH/已知主机库等 124 项测试）
swift test --package-path Packages/Core

# 运行 Backends 协议后端测试（包含 SFTP/FTP 契约检查、格式解析等 60 项测试）
swift test --package-path Packages/Backends
```

### 2. 编译并打包 DMG
```bash
# 一键编译、Hardened Runtime 签名并打包 DMG、ZIP 与 Sparkle appcast
./App/package-dmg.sh
```
产物将输出至 `App/build/dist/`：
- `Ferry-1.0.0-beta.1.dmg` (安装镜像，自带 Applications 快捷链接)
- `Ferry-1.0.0-beta.1.zip` (分发归档)
- `appcast.xml` (更新源元数据)

---

## 🛡️ Gatekeeper 首次启动说明

由于 Beta 版本采用独立自签名与 Hardened Runtime 打包（未加入 Apple 商业开发者计划签名公证），macOS Gatekeeper 在首次打开通过浏览器下载的 DMG 时可能提示“无法验证开发者”。

您可以通过以下方式正常放行打开：
1. **系统偏好设置放行**：打开应用提示被拦截后，前往 **“系统设置” -> “隐私与安全性”**，在最下方找到 Ferry 并点击 **“仍要打开”**；
2. **终端移除隔离属性**（推荐）：
   ```bash
   xattr -cr /Applications/Ferry.app
   ```

---

## 📂 架构文档索引

- [docs/ADR-0000-启动前决策.md](docs/ADR-0000-启动前决策.md)：项目前置决策、架构原则与里程碑划分
- [docs/UI-REFERENCE.md](docs/UI-REFERENCE.md)：Ferry 原生调色板、布局尺寸规范与交互参考
- [docs/SANDBOX-MIGRATION.md](docs/SANDBOX-MIGRATION.md)：App Sandbox 安全作用域书签迁移与上架指引
- [dev_md/Mac SFTP FTP 客户端开发方案 v2.3（完整版）.md](dev_md/Mac%20SFTP%20FTP%20%E5%AE%A2%E6%88%B7%E7%AB%AF%E5%BC%80%E5%8F%91%E6%96%B9%E6%A1%88%20v2.3%EF%BC%88%E5%AE%8C%E6%95%B4%E7%89%88%EF%BC%89.md)：方案规范全集

---

## 📄 开源许可证

本项目遵循 MIT 协议开源。
