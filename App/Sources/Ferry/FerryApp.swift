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
                Button("关于 Ferry") {
                    NSApplication.shared.orderFrontStandardAboutPanel(
                        options: [
                            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "Copyright © 2026 Johnny Boy Studio. All rights reserved.",
                            NSApplication.AboutPanelOptionKey.applicationName: "Ferry",
                            NSApplication.AboutPanelOptionKey.applicationVersion: "1.0.0-beta.1",
                            NSApplication.AboutPanelOptionKey.version: "100",
                            NSApplication.AboutPanelOptionKey.credits: NSAttributedString(
                                string: "专为 macOS 设计的现代化、高韧性 SFTP / FTP / FTPS 双栏文件传输客户端\n遵循 MIT 协议开源",
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
                Button("新建连接…") {
                    NotificationCenter.default.post(name: .ferryOpenNewConnection, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .appSettings) {
                Button("偏好设置与导入…") {
                    NotificationCenter.default.post(name: .ferryOpenPreferences, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu("导航") {
                Button("前往文件夹…") {
                    NotificationCenter.default.post(name: .ferryOpenGoToFolder, object: nil)
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])

                Button("切换显示隐藏文件") {
                    NotificationCenter.default.post(name: .ferryToggleHiddenFiles, object: nil)
                }
                .keyboardShortcut(".", modifiers: [.command, .shift])
            }
            CommandMenu("视图") {
                Button("切换传输队列面板") {
                    NotificationCenter.default.post(name: .ferryToggleTransferQueue, object: nil)
                }
                .keyboardShortcut("j", modifiers: .command)
            }
            CommandGroup(replacing: .help) {
                Button("Ferry 帮助与使用指南") {
                    NotificationCenter.default.post(name: .ferryOpenHelp, object: nil)
                }
                .keyboardShortcut("?", modifiers: .command)

                Button("键盘快捷键速查") {
                    NotificationCenter.default.post(name: .ferryOpenShortcuts, object: nil)
                }
                .keyboardShortcut("/", modifiers: [.command, .shift])

                Divider()

                Button("导出脱敏诊断报告…") {
                    NotificationCenter.default.post(name: .ferryExportDiagnosticReport, object: nil)
                }

                Button("访问 GitHub 开源仓库") {
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
}
