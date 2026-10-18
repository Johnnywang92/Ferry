import SwiftUI

public struct FerryApp: App {
    public init() {}

    public var body: some Scene {
        WindowGroup("Ferry") {
            MainWindowView()
                .frame(minWidth: 960, idealWidth: 1280, minHeight: 600, idealHeight: 800)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            SidebarCommands()
            CommandGroup(replacing: .appInfo) {
                Button(L10n.tr("关于 Ferry", "About Ferry")) {
                    NSApplication.shared.orderFrontStandardAboutPanel(
                        options: [
                            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "Copyright © 2026 Johnny Boy Studio. All rights reserved.",
                            NSApplication.AboutPanelOptionKey.applicationName: "Ferry",
                            NSApplication.AboutPanelOptionKey.applicationVersion: "1.0.0-beta.1",
                            NSApplication.AboutPanelOptionKey.version: "100",
                            NSApplication.AboutPanelOptionKey.credits: NSAttributedString(
                                string: L10n.tr(
                                    "专为 macOS 设计的现代化、高韧性 SFTP / FTP / FTPS 双栏文件传输客户端\n遵循 MIT 协议开源",
                                    "Modern, resilient dual-pane SFTP / FTP / FTPS file transfer client for macOS\nOpen source under MIT License"
                                ),
                                attributes: [
                                    .font: NSFont.systemFont(ofSize: 11),
                                    .foregroundColor: NSColor.secondaryLabelColor
                                ]
                            )
                        ]
                    )
                }
            }
            CommandGroup(replacing: .newItem) {
                Button(L10n.tr("新建连接…", "New Connection…")) {
                    NotificationCenter.default.post(name: .ferryOpenNewConnection, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .appSettings) {
                Button(L10n.tr("偏好设置与导入…", "Preferences & Import…")) {
                    NotificationCenter.default.post(name: .ferryOpenPreferences, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu(L10n.tr("导航", "Navigate")) {
                Button(L10n.tr("前往文件夹…", "Go to Folder…")) {
                    NotificationCenter.default.post(name: .ferryOpenGoToFolder, object: nil)
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])

                Button(L10n.tr("切换显示隐藏文件", "Toggle Hidden Files")) {
                    NotificationCenter.default.post(name: .ferryToggleHiddenFiles, object: nil)
                }
                .keyboardShortcut(".", modifiers: [.command, .shift])
            }
            CommandMenu(L10n.tr("视图", "View")) {
                Button(L10n.tr("切换传输队列面板", "Toggle Transfer Queue Panel")) {
                    NotificationCenter.default.post(name: .ferryToggleTransferQueue, object: nil)
                }
                .keyboardShortcut("j", modifiers: .command)
            }
            CommandMenu(L10n.tr("语言", "Language")) {
                Button(L10n.tr("跟随系统", "System Default")) {
                    LanguageManager.shared.currentLanguage = .system
                }
                Button("简体中文 (Simplified Chinese)") {
                    LanguageManager.shared.currentLanguage = .zh
                }
                Button("English") {
                    LanguageManager.shared.currentLanguage = .en
                }
            }
            CommandMenu(L10n.tr("传输", "Transfers")) {
                Button(L10n.tr("服务器间直传…", "Server-to-Server Relay…")) {
                    NotificationCenter.default.post(name: .ferryOpenServerRelay, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Button(L10n.tr("定时计划任务…", "Scheduled Tasks…")) {
                    NotificationCenter.default.post(name: .ferryOpenScheduledTasks, object: nil)
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .help) {
                Button(L10n.tr("Ferry 帮助与使用指南", "Ferry Help & User Guide")) {
                    NotificationCenter.default.post(name: .ferryOpenHelp, object: nil)
                }
                .keyboardShortcut("?", modifiers: .command)

                Button(L10n.tr("键盘快捷键速查", "Keyboard Shortcuts")) {
                    NotificationCenter.default.post(name: .ferryOpenShortcuts, object: nil)
                }
                .keyboardShortcut("/", modifiers: [.command, .shift])

                Divider()

                Button(L10n.tr("导出脱敏诊断报告…", "Export Sanitized Diagnostic Report…")) {
                    NotificationCenter.default.post(name: .ferryExportDiagnosticReport, object: nil)
                }

                Button(L10n.tr("访问 GitHub 开源仓库", "Visit GitHub Repository")) {
                    if let url = URL(string: "https://github.com/yifanwang/Ferry") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}

extension Notification.Name {
    public static let ferryOpenNewConnection = Notification.Name("ferryOpenNewConnection")
    public static let ferryOpenGoToFolder = Notification.Name("ferryOpenGoToFolder")
    public static let ferryToggleHiddenFiles = Notification.Name("ferryToggleHiddenFiles")
    public static let ferryOpenPreferences = Notification.Name("ferryOpenPreferences")
    public static let ferryRefreshLocalPane = Notification.Name("ferryRefreshLocalPane")
    public static let ferryToggleTransferQueue = Notification.Name("ferryToggleTransferQueue")
    public static let ferryOpenHelp = Notification.Name("ferryOpenHelp")
    public static let ferryOpenShortcuts = Notification.Name("ferryOpenShortcuts")
    public static let ferryExportDiagnosticReport = Notification.Name("ferryExportDiagnosticReport")
    public static let ferryOpenServerRelay = Notification.Name("ferryOpenServerRelay")
    public static let ferryOpenScheduledTasks = Notification.Name("ferryOpenScheduledTasks")
}

