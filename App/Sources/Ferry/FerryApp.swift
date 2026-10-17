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
        }
    }
}

extension Notification.Name {
    public static let ferryOpenNewConnection = Notification.Name("ferryOpenNewConnection")
    public static let ferryOpenGoToFolder = Notification.Name("ferryOpenGoToFolder")
    public static let ferryToggleHiddenFiles = Notification.Name("ferryToggleHiddenFiles")
    public static let ferryOpenPreferences = Notification.Name("ferryOpenPreferences")
    public static let ferryRefreshLocalPane = Notification.Name("ferryRefreshLocalPane")
}
