# Ferry 沙盒升级与迁移方案 (SANDBOX-MIGRATION.md)

> **版本**：v1.0 (Beta)  
> **关联里程碑**：M6 (v2.3 §524, 风险项 R7, 启动决策 ADR-0000 D1)  
> **适用范围**：从模式 A（非沙盒开发版）向模式 B（App Sandbox / Mac App Store 上架版）的无损平滑迁移。

---

## 1. 架构背景与双模式设计

macOS 文件传输客户端的核心特点是需要频繁访问本地磁盘的任意目录与服务器进行双向传输。Ferry 从 M0 启动之初便在架构上确立了**双模式兼容战略**（见 `docs/ADR-0000-启动前决策.md` §13）：

| 模式 | 运行环境 | 权限机制 | 典型适用场景 |
|---|---|---|---|
| **模式 A** (当前) | Hardened Runtime (非沙盒) | 继承用户主目录 POSIX 权限直读，支持直接访问 `~/.ssh/config`、`~/.ssh/known_hosts` | 官方网站 DMG 分发、GitHub Releases、开发者本地编译调试 |
| **模式 B** (迁移后) | App Sandbox | 强制 `com.apple.security.app-sandbox`，所有本地目录必须持有 Security-Scoped Bookmark，网络出站走特权通道 | Mac App Store (MAS) 上架、高安全合规环境 |

为了避免在开启沙盒时重写数据模型或丢失用户已有站点配置，Ferry 从 M2 起便将所有本地路径抽象为 [`ScopedBookmark`](file:///Users/yifanwang/workspace/Ferry/Packages/Core/Sources/FerryCore/Storage/ScopedBookmark.swift)，提前完成了底层基础设施的对齐。

---

## 2. 安全作用域书签 (Security-Scoped Bookmark) 运作机制

在 App Sandbox 规范下，仅有通过系统标准文件选择器（`NSOpenPanel`）由用户显式批准的路径才可被 App 访问。为了使这种授权在 App 重启后依然有效，必须将 `URL` 编码为 Security-Scoped Bookmark：

```swift
// 1. 生成书签（在用户通过 NSOpenPanel 选择目录后）
let bookmarkData = try url.bookmarkData(
    options: [.withSecurityScope],
    includingResourceValuesForKeys: nil,
    relativeTo: nil
)

// 2. 解析书签并启动安全访问作用域
var isStale = false
let resolvedURL = try URL(
    resolvingBookmarkData: bookmarkData,
    options: [.withSecurityScope, .withoutUI],
    relativeTo: nil,
    bookmarkDataIsStale: &isStale
)

let accessGranted = resolvedURL.startAccessingSecurityScopedResource()
defer {
    if accessGranted {
        resolvedURL.stopAccessingSecurityScopedResource()
    }
}
```

- [`ScopedBookmark`](file:///Users/yifanwang/workspace/Ferry/Packages/Core/Sources/FerryCore/Storage/ScopedBookmark.swift) 同时序列化存储了明文 `path` 与二进制 `bookmarkData`。
- 在模式 A 下，直接以 `path` 展开 `~` 访问；在模式 B 下，优先校验并解析 `bookmarkData`。

---

## 3. 从模式 A 升级到模式 B 的重新授权流程

当用户安装了沙盒版本的 Ferry（如从 Mac App Store 下载）时，既有的 `sites.json` 仍包含本地目录路径，但可能缺少有效的 `bookmarkData`。此时必须提供顺畅的重新授权流程，避免由于 `EPERM` 导致静默失败。

### 3.1 状态检测契约
在站点加载或发起传输前，通过 [`ScopedBookmark.resolveURL()`](file:///Users/yifanwang/workspace/Ferry/Packages/Core/Sources/FerryCore/Storage/ScopedBookmark.swift#L40) 进行探测：

1. **有效 (`isValid`)**：`bookmarkData` 存在且成功解析，`isStale == false`，直接放行；
2. **陈旧 (`isStale == true`)**：文件系统发生了移动或重命名，立即后台重新生成并持久化；
3. **缺失或无权限 (`isMissingOrUnauthorized`)**：`bookmarkData == nil` 或解析失败（例如沙盒无法访问未授权的外部目录）。

### 3.2 交互重新授权步骤
1. **就地提示**：在双栏本地面板顶部或连接站点时，若检测到缺失授权，UI 呈现轻量警示条：
   > ⚠️ 该站点的本地同步目录（`~/Projects/web-dist`）尚未授予沙盒访问权限。
2. **一键授权**：用户点击“授权访问”，App 弹出预设路径的 `NSOpenPanel`：
   ```swift
   let panel = NSOpenPanel()
   panel.canChooseDirectories = true
   panel.canChooseFiles = false
   panel.allowsMultipleSelection = false
   panel.directoryURL = URL(fileURLWithPath: site.localBookmark.expandedPath)
   panel.prompt = "授予访问权限"
   panel.message = "请确认授予 Ferry 访问此目录以进行文件上传与下载："
   if panel.runModal() == .OK, let url = panel.url {
       site.localBookmark = ScopedBookmark(url: url, includeBookmarkData: true)
       await SiteStore.shared.upsert(site)
   }
   ```
3. **记忆化**：更新后的 `bookmarkData` 写回 `sites.json`，后续启动不再重复询问。

---

## 4. Entitlements 权限配置清单

升级至模式 B 时，在 `App/Support/Ferry.entitlements` 中启用以下沙盒权限集：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- 开启 App Sandbox -->
    <key>com.apple.security.app-sandbox</key>
    <true/>

    <!-- 出站网络连接：SFTP (22)、FTP (21/TLS)、HTTP/HTTPS (Sparkle) -->
    <key>com.apple.security.network.client</key>
    <true/>

    <!-- 用户通过 NSOpenPanel 选择的文件/目录读写授权 -->
    <key>com.apple.security.files.user-selected.read-write</key>
    <true/>

    <!-- 持久化安全作用域书签能力 -->
    <key>com.apple.security.files.bookmarks.app-scope</key>
    <true/>

    <!-- 钥匙串访问组：保证应用内钥匙串凭证存取隔离 -->
    <key>keychain-access-groups</key>
    <array>
        <string>$(TeamIdentifierPrefix)dev.ferry.app</string>
    </array>
</dict>
</plist>
```

---

## 5. 钥匙串与 SSH 兼容性迁移

### 5.1 Keychain 存储迁移
- **非沙盒环境**：调用 macOS 本地 `login` 钥匙串，无需访问组，各 App 隔离性较弱。
- **沙盒环境**：苹果要求沙盒 App 访问 Data Protection Keychain 或指定 `keychain-access-groups`。
- **平滑策略**：在首次启动沙盒版本时，若发现本地钥匙串无记录，使用统一的 `kSecAttrService = "dev.ferry.app"` 检索已有登录钥匙串项，并将其就地升级为沙盒访问组记录。

### 5.2 `~/.ssh/config` 与 `~/.ssh/known_hosts` 的处理
- 在沙盒模式下，App 无法直接隐式读取 `~/.ssh/` 隐藏目录。
- **解决方案**：
  1. `known_hosts`：在 `~/Library/Application Support/Ferry/known_hosts` 中维护 Ferry 专有的独立信任库（M2 已完全就绪，零依赖用户目录）；
  2. `config` 导入：偏好设置界面支持用户通过系统文件对话框显式选择 `~/.ssh/config` 进行单次解析与导入，完全符合苹果 App Store 审核准则。

---

## 6. 构建、签名与公证验证命令

发布沙盒与非沙盒版本时的流水线脚本调用指南：

```bash
# 1. 编译 App 可执行体
swift build --package-path App -c release

# 2. 组装 Ferry.app 并执行带 Hardened Runtime 与 Entitlements 的严格签名
codesign --force --sign "Developer ID Application: YourTeam (ID)" \
    --options runtime \
    --timestamp \
    --entitlements App/Support/Ferry.entitlements \
    App/build/Ferry.app

# 3. 严格验证签名有效性
codesign --verify --strict --verbose=2 App/build/Ferry.app
spctl --assess --type execute --verbose App/build/Ferry.app

# 4. 打包并提交 Apple 官方公证（Notarization）
ditto -c -k --keepParent App/build/Ferry.app Ferry.zip
xcrun notarytool submit Ferry.zip --keychain-profile "notary-profile" --wait

# 5. 公证凭据装订 (Staple)
xcrun stapler staple App/build/Ferry.app
```

---

## 7. 结论与就绪状态

Ferry 现有的数据架构（[`Store<T>`](file:///Users/yifanwang/workspace/Ferry/Packages/Core/Sources/FerryCore/Storage/Store.swift)、[`ScopedBookmark`](file:///Users/yifanwang/workspace/Ferry/Packages/Core/Sources/FerryCore/Storage/ScopedBookmark.swift)、[`KeychainService`](file:///Users/yifanwang/workspace/Ferry/App/Sources/Ferry/Services/KeychainService.swift)、[`SiteStore`](file:///Users/yifanwang/workspace/Ferry/App/Sources/Ferry/Services/SiteStore.swift)）**无需任何破坏性变更**即可无缝切入 App Sandbox，相关风险项 R7 已彻底闭环。
