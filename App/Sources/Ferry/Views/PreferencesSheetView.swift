import AppKit
import FerryCore
import SwiftUI

/// 偏好设置与 `.ssh/config` 导入、`known_hosts` 管理弹窗（M2 交付，覆盖 ADR-0000 D5/D6 与 v2.3 §520）。
public struct PreferencesSheetView: View {
    @Binding var isPresented: Bool

    @Environment(\.colorScheme) private var colorScheme
    private var themeManager: ThemeManager { ThemeManager.shared }
    private var languageManager: LanguageManager { LanguageManager.shared }
    private var siteStore: SiteStore { SiteStore.shared }

    @State private var sshEntries: [SSHHostEntry] = []
    @State private var selectedAliases: Set<String> = []
    @State private var sshStatusMessage: String?
    @State private var knownHostsSummary: String = ""

    private var theme: FerryTheme {
        themeManager.theme(for: colorScheme)
    }

    public init(isPresented: Binding<Bool>) {
        self._isPresented = isPresented
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L10n.tr("偏好设置与导入", "Preferences & Imports"))
                    .font(FerryFont.bodyBold)
                    .foregroundColor(theme.text)
                Spacer()
                Button(L10n.tr("完成", "Done")) {
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(theme.accentColor)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)

            Divider().background(theme.line)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // 1. 外观、语言与强调色（ADR-0000 D5 / D6）
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L10n.tr("外观与语言（即时生效）", "Appearance & Language"))
                            .font(FerryFont.subheadlineBold)
                            .foregroundColor(theme.text)

                        // 界面语言
                        HStack {
                            Text(L10n.tr("界面语言", "Language"))
                                .font(FerryFont.captionMedium)
                                .foregroundColor(theme.text2)
                                .frame(width: 90, alignment: .leading)

                            Picker("", selection: Bindable(languageManager).currentLanguage) {
                                ForEach(AppLanguage.allCases) { lang in
                                    Text(lang.displayName).tag(lang)
                                }
                            }
                            .pickerStyle(.segmented)
                        }

                        // 外观模式
                        HStack {
                            Text(L10n.tr("外观模式", "Appearance"))
                                .font(FerryFont.captionMedium)
                                .foregroundColor(theme.text2)
                                .frame(width: 90, alignment: .leading)

                            Picker("", selection: Bindable(themeManager).appearanceMode) {
                                ForEach(FerryAppearanceMode.allCases) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                        }

                        // 强调色
                        HStack {
                            Text(L10n.tr("强调色", "Accent Color"))
                                .font(FerryFont.captionMedium)
                                .foregroundColor(theme.text2)
                                .frame(width: 90, alignment: .leading)

                            HStack(spacing: 12) {
                                ForEach(FerryAccentOption.allCases) { option in
                                    Button(action: {
                                        themeManager.accentOption = option
                                    }) {
                                        HStack(spacing: 6) {
                                            Circle()
                                                .fill(option.color)
                                                .frame(width: 14, height: 14)
                                            Text(option.label)
                                                .font(FerryFont.caption)
                                                .foregroundColor(theme.text)
                                        }
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(
                                            RoundedRectangle(cornerRadius: FerryRadius.r5)
                                                .fill(themeManager.accentOption == option ? theme.field : Color.clear)
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: FerryRadius.r5)
                                                .stroke(themeManager.accentOption == option ? option.color : theme.line, lineWidth: 1)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        Toggle(L10n.tr("显示以 `.` 开头的隐藏文件（快捷键 ⌘⇧.）", "Show hidden files starting with `.` (⌘⇧.)"), isOn: Bindable(themeManager).showHiddenFiles)
                            .font(FerryFont.subheadline)
                            .foregroundColor(theme.text)
                            .toggleStyle(.checkbox)
                            .padding(.top, 2)
                    }
                    .padding(14)
                    .background(theme.panel)
                    .cornerRadius(FerryRadius.r8)

                    // 2. ~/.ssh/config 站点导入（M2 交付）
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(L10n.tr("从 ~/.ssh/config 导入站点", "Import Sites from ~/.ssh/config"))
                                .font(FerryFont.subheadlineBold)
                                .foregroundColor(theme.text)
                            Spacer()
                            Button(L10n.tr("选择其他配置文件…", "Choose Other Config…")) {
                                pickCustomSSHConfig()
                            }
                            .font(FerryFont.caption)

                            Button(L10n.tr("重新扫描 ~/.ssh/config", "Rescan ~/.ssh/config")) {
                                scanDefaultSSHConfig()
                            }
                            .font(FerryFont.caption)
                        }

                        if sshEntries.isEmpty {
                            Text(sshStatusMessage ?? L10n.tr("未在 ~/.ssh/config 中发现可导入的具体 Host 条目。", "No importable Host entries found in ~/.ssh/config."))
                                .font(FerryFont.caption)
                                .foregroundColor(theme.text3)
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(sshEntries) { entry in
                                    HStack(spacing: 8) {
                                        Toggle("", isOn: Binding(
                                            get: { selectedAliases.contains(entry.alias) },
                                            set: { checked in
                                                if checked { selectedAliases.insert(entry.alias) }
                                                else { selectedAliases.remove(entry.alias) }
                                            }
                                        ))
                                        .toggleStyle(.checkbox)
                                        .labelsHidden()

                                        Text(entry.alias)
                                            .font(FerryFont.captionBold)
                                            .foregroundColor(theme.text)

                                        Text("\(entry.user ?? NSUserName())@\(entry.hostName):\(entry.port)")
                                            .font(FerryFont.monoCaption)
                                            .foregroundColor(theme.text2)

                                        if entry.prefersWeakAlgorithms {
                                            Text(L10n.tr("老算法", "Legacy"))
                                                .font(FerryFont.micro)
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 1)
                                                .background(theme.warningOrange.opacity(0.2))
                                                .foregroundColor(theme.warningOrange)
                                                .cornerRadius(FerryRadius.r3)
                                        }

                                        if let jump = entry.proxyJump {
                                            Text("ProxyJump: \(jump)（v1.1+）")
                                                .font(FerryFont.micro)
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 1)
                                                .background(theme.pill)
                                                .foregroundColor(theme.text3)
                                                .cornerRadius(FerryRadius.r3)
                                        }

                                        Spacer()
                                    }
                                }

                                HStack {
                                    if let msg = siteStore.lastImportSummary ?? sshStatusMessage {
                                        Text(msg)
                                            .font(FerryFont.micro)
                                            .foregroundColor(theme.text2)
                                    }
                                    Spacer()
                                    Button(L10n.format("导入所选 (%d)", "Import Selected (%d)", selectedAliases.count)) {
                                        let chosen = sshEntries.filter { selectedAliases.contains($0.alias) }
                                        Task {
                                            _ = await siteStore.importSSHConfigEntries(chosen)
                                        }
                                    }
                                    .disabled(selectedAliases.isEmpty)
                                }
                                .padding(.top, 4)
                            }
                        }
                    }
                    .padding(14)
                    .background(theme.panel)
                    .cornerRadius(FerryRadius.r8)

                    // 3. 已知主机库（TOFU + ~/.ssh/known_hosts）
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(L10n.tr("主机密钥信任库（TOFU & ~/.ssh/known_hosts）", "Host Key Trust (TOFU & ~/.ssh/known_hosts)"))
                                .font(FerryFont.subheadlineBold)
                                .foregroundColor(theme.text)
                            Spacer()
                            Button(L10n.tr("清空 Ferry 自建信任记录", "Clear Ferry Trust Records")) {
                                try? FileManager.default.removeItem(at: ConnectionService.ferryKnownHostsURL)
                                refreshKnownHostsSummary()
                            }
                            .font(FerryFont.caption)
                        }

                        Text(knownHostsSummary)
                            .font(FerryFont.monoCaption)
                            .foregroundColor(theme.text2)
                    }
                    .padding(14)
                    .background(theme.panel)
                    .cornerRadius(FerryRadius.r8)

                    // 4. 自动更新（M6 Sparkle 集成，v2.3 §524）
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(L10n.tr("软件更新", "Software Update"))
                                .font(FerryFont.subheadlineBold)
                                .foregroundColor(theme.text)
                            Spacer()
                            Button(L10n.tr("检查更新…", "Check for Updates…")) {
                                Task {
                                    await UpdaterService.shared.checkForUpdates()
                                }
                            }
                            .disabled(UpdaterService.shared.isChecking)
                        }

                        HStack {
                            Toggle(L10n.tr("自动检查更新", "Automatically check for updates"), isOn: Bindable(UpdaterService.shared).isAutoCheckEnabled)
                                .font(FerryFont.subheadline)
                                .foregroundColor(theme.text)
                                .toggleStyle(.checkbox)

                            Spacer()

                            if let msg = UpdaterService.shared.statusMessage {
                                Text(msg)
                                    .font(FerryFont.caption)
                                    .foregroundColor(theme.text2)
                            }
                        }
                    }
                    .padding(14)
                    .background(theme.panel)
                    .cornerRadius(FerryRadius.r8)

                    // 5. 诊断报告一键导出（M6 可观测性，v2.3 §470-472）
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L10n.tr("诊断报告与故障排查", "Diagnostic Report & Troubleshooting"))
                                    .font(FerryFont.subheadlineBold)
                                    .foregroundColor(theme.text)
                                Text(L10n.tr("导出包含系统环境、连接状态（已脱敏密码/私钥）、队列状况与错误码建议的 JSON 报告。", "Export a sanitized JSON report containing system environment, connection state, queue status, and advice."))
                                    .font(FerryFont.caption)
                                    .foregroundColor(theme.text3)
                            }
                            Spacer()
                            Button(L10n.tr("导出诊断报告…", "Export Diagnostic Report…")) {
                                exportDiagnosticReport()
                            }
                        }
                    }
                    .padding(14)
                    .background(theme.panel)
                    .cornerRadius(FerryRadius.r8)
                }
                .padding(24)
            }
        }
        .frame(width: 580, height: 500)
        .background(theme.bg)
        .onAppear {
            scanDefaultSSHConfig()
            refreshKnownHostsSummary()
        }
    }

    private func scanDefaultSSHConfig() {
        do {
            let found = try siteStore.previewSSHConfig()
            sshEntries = found
            selectedAliases = Set(found.map(\.alias))
            sshStatusMessage = found.isEmpty ? "在 ~/.ssh/config 中未检测到具体 Host 条目" : "扫描到 \(found.count) 个主机条目"
        } catch {
            sshEntries = []
            sshStatusMessage = "读取 ~/.ssh/config 失败：\(error.localizedDescription)"
        }
    }

    private func pickCustomSSHConfig() {
        let panel = NSOpenPanel()
        panel.title = "选择 SSH 配置文件 (ssh_config)"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let found = try siteStore.previewSSHConfig(at: url)
                sshEntries = found
                selectedAliases = Set(found.map(\.alias))
                sshStatusMessage = "从 \(url.lastPathComponent) 扫描到 \(found.count) 个主机条目"
            } catch {
                sshStatusMessage = "解析失败：\(error.localizedDescription)"
            }
        }
    }

    private func refreshKnownHostsSummary() {
        let ferryURL = ConnectionService.ferryKnownHostsURL
        let userURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/known_hosts")

        let ferryCount = (try? String(contentsOf: ferryURL, encoding: .utf8))
            .map { KnownHostsFile.parse($0, source: ferryURL.path).lines.count } ?? 0
        let userCount = (try? String(contentsOf: userURL, encoding: .utf8))
            .map { KnownHostsFile.parse($0, source: userURL.path).lines.count } ?? 0

        knownHostsSummary = """
        Ferry 独立记录：\(ferryCount) 条（\(ferryURL.path)）
        系统只读兼容：\(userCount) 条（~/.ssh/known_hosts）
        """
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
