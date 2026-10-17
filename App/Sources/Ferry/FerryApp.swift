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
        }
    }
}

extension Notification.Name {
    public static let ferryOpenNewConnection = Notification.Name("ferryOpenNewConnection")
}
