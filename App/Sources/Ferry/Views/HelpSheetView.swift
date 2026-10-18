import AppKit
import FerryCore
import SwiftUI

/// 帮助分类
public enum HelpTab: String, CaseIterable, Identifiable, Sendable {
    case gettingStarted = "快速上手"
    case fileOperations = "文件操作"
    case transferQueue = "传输队列"
    case syncEngine = "双向同步"
    case shortcuts = "快捷键速查"
    case troubleshooting = "排查与关于"

    public var id: String { rawValue }

    @MainActor
    public var displayName: String {
        switch self {
        case .gettingStarted: return L10n.tr("快速上手", "Getting Started")
        case .fileOperations: return L10n.tr("文件操作", "File Operations")
        case .transferQueue: return L10n.tr("传输队列", "Transfer Queue")
        case .syncEngine: return L10n.tr("双向同步", "Two-way Sync")
        case .shortcuts: return L10n.tr("快捷键速查", "Shortcuts")
        case .troubleshooting: return L10n.tr("排查与关于", "Troubleshooting & About")
        }
    }

    public var icon: String {
        switch self {
        case .gettingStarted: return "sparkles"
        case .fileOperations: return "folder"
        case .transferQueue: return "arrow.up.arrow.down"
        case .syncEngine: return "arrow.triangle.2.circlepath"
        case .shortcuts: return "keyboard"
        case .troubleshooting: return "wrench.and.screwdriver"
        }
    }
}

/// Ferry 原生帮助与使用指南弹窗
public struct HelpSheetView: View {
    @Binding var isPresented: Bool
    @State private var selectedTab: HelpTab

    @Environment(\.colorScheme) private var colorScheme
    private var themeManager: ThemeManager { ThemeManager.shared }

    private var theme: FerryTheme {
        themeManager.theme(for: colorScheme)
    }

    public init(initialTab: HelpTab = .gettingStarted, isPresented: Binding<Bool>) {
        self._selectedTab = State(initialValue: initialTab)
        self._isPresented = isPresented
    }

    public var body: some View {
        VStack(spacing: 0) {
            // 顶部栏
            HStack(spacing: 14) {
                AppIconView(size: 38)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(L10n.tr("Ferry 帮助与使用指南", "Ferry Help & User Guide"))
                            .font(FerryFont.titleBold)
                            .foregroundColor(theme.text)
                        Text("v1.0.0-beta.1")
                            .font(FerryFont.micro)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(theme.accentColor.opacity(0.15))
                            .foregroundColor(theme.accentColor)
                            .cornerRadius(FerryRadius.r4)
                    }
                    Text(L10n.tr("专为 macOS 设计的现代化高韧性 SFTP / FTP / FTPS 文件传输客户端", "Modern, resilient SFTP / FTP / FTPS file transfer client designed for macOS"))
                        .font(FerryFont.caption)
                        .foregroundColor(theme.text2)
                }

                Spacer()

                Button(L10n.tr("完成", "Done")) {
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(theme.accentColor)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)

            Divider().background(theme.line)

            // 分类切换 Picker
            HStack {
                Picker("", selection: $selectedTab) {
                    ForEach(HelpTab.allCases) { tab in
                        Label(tab.displayName, systemImage: tab.icon).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .background(theme.panel)

            Divider().background(theme.line)

            // 内容展示区
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch selectedTab {
                    case .gettingStarted:
                        gettingStartedView
                    case .fileOperations:
                        fileOperationsView
                    case .transferQueue:
                        transferQueueView
                    case .syncEngine:
                        syncEngineView
                    case .shortcuts:
                        shortcutsView
                    case .troubleshooting:
                        troubleshootingView
                    }
                }
                .padding(22)
            }

            Divider().background(theme.line)

            // 底部版权与外链栏
            HStack(spacing: 16) {
                Text("Copyright © 2026 Johnny Boy Studio. All rights reserved. (MIT License)")
                    .font(FerryFont.monoCaption)
                    .foregroundColor(theme.text3)

                Spacer()

                Button(action: {
                    if let url = URL(string: "https://github.com/yifanwang/Ferry") {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    Label(L10n.tr("GitHub 开源仓库", "GitHub Repository"), systemImage: "link")
                        .font(FerryFont.caption)
                }
                .buttonStyle(.link)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
            .background(theme.bar)
        }
        .frame(width: 720, height: 560)
        .background(theme.bg)
    }

    // MARK: - 子模块视图

    private var gettingStartedView: some View {
        VStack(alignment: .leading, spacing: 14) {
            helpCard(
                title: "1. 新建连接与全协议覆盖",
                icon: "network",
                content: """
                • **支持协议**：完整支持 **SFTP**（静态编译 libssh2 + OpenSSL 3）与 **FTP / FTPS**（基于 macOS 系统 libcurl 与 TLS 1.3）；
                • **快速创建**：点击工具栏「新建连接」或按 `⌘N`，输入主机、端口与用户身份；
                • **全模式认证**：支持密码认证（存入 macOS 钥匙串 Keychain）、私钥（OpenSSH/PEM，带口令解锁）、ssh-agent 本地代理与 Keyboard-Interactive 交互式认证。
                """
            )

            helpCard(
                title: "2. 站点书签与系统导入",
                icon: "bookmark",
                content: """
                • **站点存储**：连接时勾选「保存站点」，站点参数将安全落盘；
                • **导入配置**：前往「偏好设置 (⌘,)」可一键扫描并导入 `~/.ssh/config` 中的所有 Host 条目。
                """
            )

            helpCard(
                title: "3. 侧边栏本地快捷位置自定义",
                icon: "sidebar.left",
                content: """
                • 点击侧边栏「本地位置」旁边的「+」号，可任意添加常用本地文件夹；
                • 在任意自定义快捷位置上右键，可进行**重命名**、**重新指定目标路径**或**移除**；
                • 随时可以通过右键「恢复默认推荐位置」一键重置常用工作目录。
                """
            )
        }
    }

    private var fileOperationsView: some View {
        VStack(alignment: .leading, spacing: 14) {
            helpCard(
                title: "AppKit 原生双栏与全功能拖拽",
                icon: "square.split.2x1",
                content: """
                • **双向互拖**：选中文档直接从本地拖拽至远程列表发起上传，或从远程拖拽至本地目录发起下载；
                • **外部拖入/拖出**：支持直接从 Finder 或桌面拖拽文件进双栏，或将文件拖出至 Finder 暂存写回。
                """
            )

            helpCard(
                title: "新建文件夹、就地重命名与安全删除",
                icon: "doc.badge.ellipsis",
                content: """
                • **新建文件夹**：点击工具栏「新建文件夹」按钮，在当前选中的工作目录快速创建子文件夹；
                • **就地重命名**：选中文件或目录后，按 `Enter` 回车键或通过右键菜单选择「重命名…」；
                • **安全删除**：右键选择「删除」，系统将弹出二次确认警告弹窗，杜绝网络误操作误删文件。
                """
            )

            helpCard(
                title: "Quick Look 快速预览与外部编辑器监视",
                icon: "eye",
                content: """
                • **快速预览 (Quick Look)**：选中任意本地或远程文件，轻按 `Space` 空格键即可就地调起 macOS 原生预览；
                • **外部编辑器监视**：双击远端文本/脚本文件，Ferry 会自动调用系统默认应用打开，并在后台持续监视文件保存，保存后自动无感回传服务器。
                """
            )

            helpCard(
                title: "路径导航与精准字符集",
                icon: "character.cursor.ibeam",
                content: """
                • **路径栏输入**：双击顶部路径栏可直接编辑并输入绝对路径，按回车或失焦即可快速跳转；
                • **快捷跳转**：按 `⌘⇧G` 调起「前往文件夹」对话框；按 `⌘⇧.` 实时切换显示以 `.` 开头的隐藏文件；
                • **字符集切换**：底层寻址严格遵循原始 `wireBytes`，点击状态栏字符集标签可实时在 UTF-8、GBK、GB18030 与 Big5 间无缝切换，乱码时提供十六进制视图降级。
                """
            )
        }
    }

    private var transferQueueView: some View {
        VStack(alignment: .leading, spacing: 14) {
            helpCard(
                title: "弹性传输队列与调度",
                icon: "arrow.up.arrow.down.circle",
                content: """
                • **展开/收起面板**：点击工具栏传输队列胶囊徽标或按 `⌘J` 展开底部队列视图；
                • **并发控制**：默认 N=3 任务并发，支持单任务独立异常隔离与令牌桶平滑限速；
                • **即时反馈与防抖**：触发传输瞬间提供「准备中」状态提示，并内置防重复点击守卫屏障。
                """
            )

            helpCard(
                title: "暂停、取消与断点续传 (.part)",
                icon: "pause.circle",
                content: """
                • **暂停 (Pause)**：保留本地 `.part` 临时文件与已传输字节偏移，随时可一键继续断点续传；
                • **取消 (Cancel)**：200ms 内快速终止网络流，自动清理目标端未完成的临时碎片；
                • **续传置信度校验**：续传前自动比对远端文件大小与修改时间，避免服务器文件已被他人修改导致静默覆盖破坏；
                • **网络退避重试**：网络临时波动时自动触发 1s / 2s / 4s 指数退避重试，崩溃重启后自动安全转为暂停待续。
                """
            )
        }
    }

    private var syncEngineView: some View {
        VStack(alignment: .leading, spacing: 14) {
            helpCard(
                title: "3-Way 同步引擎与基准快照",
                icon: "arrow.triangle.2.circlepath",
                content: """
                • 点击工具栏「双向同步」按钮，即可对当前本地与远端文件夹进行智能比对；
                • 同步引擎基于本地与远端的基准快照 (Baseline Snapshot)，精准捕捉双端的文件新增、修改与删除事件；
                • 严格区分网络异常与文件删除（`notFound`），防止网络抖动导致的误删。
                """
            )

            helpCard(
                title: "DiffPlan 差异决策与冲突保护",
                icon: "slider.horizontal.3",
                content: """
                • **DiffPlan 预览**：执行前直观呈现上行、下行、删除及冲突总数统计；
                • **出口级冲突拦截**：双端同时修改同一文件时自动拦截为冲突，绝不静默覆盖；
                • **四种冲突裁决模式**：
                  1. `本地为准`：强制以上传覆盖远端；
                  2. `远端为准`：强制以下载覆盖本地；
                  3. `保留双份`：自动生成分流副本，双方修改均得以保全；
                  4. `跳过`：本次同步暂不处理该文件；
                • **安全删除**：删除动作默认关闭，开启需要显式勾选并二次确认。
                """
            )
        }
    }

    private var shortcutsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr("核心操作快捷键矩阵", "Core Keyboard Shortcuts"))
                .font(FerryFont.subheadlineBold)
                .foregroundColor(theme.text)

            VStack(spacing: 8) {
                shortcutRow(keys: "⌘ N", action: L10n.tr("新建连接对话框", "New Connection dialog"))
                shortcutRow(keys: "⌘ ,", action: L10n.tr("打开偏好设置与导入", "Open Preferences & Import"))
                shortcutRow(keys: "⌘ ⇧ G", action: L10n.tr("快速前往文件夹路径", "Go to Folder path"))
                shortcutRow(keys: "⌘ ⇧ .", action: L10n.tr("实时切换显示隐藏文件", "Toggle hidden files"))
                shortcutRow(keys: "⌘ J", action: L10n.tr("展开 / 收起传输队列面板", "Toggle transfer queue panel"))
                shortcutRow(keys: "Space (空格)", action: L10n.tr("Quick Look 快速预览选中文件", "Quick Look preview selected file"))
                shortcutRow(keys: "Enter (回车)", action: L10n.tr("就地重命名当前选中的文件或目录", "Rename selected item inline"))
                shortcutRow(keys: "⌘ ?", action: L10n.tr("调起本帮助与使用指南", "Open Help & User Guide"))
            }
            .padding(14)
            .background(theme.panel)
            .cornerRadius(FerryRadius.r8)
        }
    }

    private var troubleshootingView: some View {
        VStack(alignment: .leading, spacing: 14) {
            helpCard(
                title: L10n.tr("主机密钥信任 (TOFU) 与指纹变更警告", "Host Key Trust (TOFU) & Fingerprint Warning"),
                icon: "shield.lefthalf.filled",
                content: L10n.tr("""
                • 首次连接新服务器时，Ferry 会弹出公钥指纹询问（支持 MD5 / SHA-256 指纹展示）；
                • 若服务器重装或被中间人攻击导致公钥变更，系统会实施**硬阻断警告**，并提供一键移除旧信任记录的防呆机制。
                """, """
                • When connecting to a new server, Ferry displays public key fingerprints (MD5 / SHA-256);
                • If the host key changes unexpectedly, Ferry triggers a strict security warning and allows clearing stale trust records.
                """)
            )

            helpCard(
                title: L10n.tr("一键导出脱敏诊断报告", "Export Sanitized Diagnostic Report"),
                icon: "stethoscope",
                content: L10n.tr("""
                • 遇到连接超时、算法协商失败或传输异常时，可一键导出脱敏诊断报告；
                • 报告自动掩码敏感信息（用户名保护、密码与私钥绝不入日志），内置智能错误映射表指导排查。
                """, """
                • In case of timeouts, negotiation failures, or transfer issues, export a sanitized diagnostic report;
                • Sensitive data is masked (passwords/keys never logged) with smart troubleshooting recommendations.
                """)
            )

            HStack {
                Button(action: {
                    exportDiagnosticReport()
                }) {
                    Label(L10n.tr("立即导出脱敏诊断报告…", "Export Sanitized Diagnostic Report…"), systemImage: "square.and.arrow.up")
                        .font(FerryFont.captionBold)
                }
                .buttonStyle(.bordered)
                .tint(theme.accentColor)

                Spacer()
            }
            .padding(.top, 4)
        }
    }

    // MARK: - 辅助组件

    private func helpCard(title: String, icon: String, content: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(FerryFont.subheadlineBold)
                    .foregroundColor(theme.accentColor)
                Text(title)
                    .font(FerryFont.subheadlineBold)
                    .foregroundColor(theme.text)
            }
            Text(content)
                .font(FerryFont.caption)
                .foregroundColor(theme.text2)
                .lineSpacing(4)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.panel)
        .cornerRadius(FerryRadius.r8)
    }

    private func shortcutRow(keys: String, action: String) -> some View {
        HStack {
            Text(action)
                .font(FerryFont.captionMedium)
                .foregroundColor(theme.text)
            Spacer()
            Text(keys)
                .font(FerryFont.monoSmall)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(theme.field)
                .foregroundColor(theme.accentColor)
                .cornerRadius(FerryRadius.r4)
                .overlay(
                    RoundedRectangle(cornerRadius: FerryRadius.r4)
                        .stroke(theme.line, lineWidth: 1)
                )
        }
    }

    private func exportDiagnosticReport() {
        Task {
            let logs = await DiagnosticLogger.shared.entries()
            let report = DiagnosticReportService.shared.buildReport(
                connectionService: ConnectionService.shared,
                logs: logs
            )

            guard let data = try? DiagnosticReportService.shared.exportReportJSON(report: report) else {
                return
            }

            await MainActor.run {
                let panel = NSSavePanel()
                panel.title = "导出 Ferry 诊断报告"
                panel.nameFieldStringValue = "Ferry-Diagnostics-\(Int(Date().timeIntervalSince1970)).json"
                panel.allowedContentTypes = [.json]
                if panel.runModal() == .OK, let url = panel.url {
                    try? data.write(to: url)
                }
            }
        }
    }
}
