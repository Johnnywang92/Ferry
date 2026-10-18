import Foundation

/// 本地常用快速位置模型（支持自定义增删改与持久化）
public struct LocalLocation: Identifiable, Hashable, Sendable, Codable {
    public var id: String
    public var name: String
    public var iconName: String
    public var url: URL

    public init(
        id: String = UUID().uuidString,
        name: String,
        iconName: String = "folder",
        url: URL
    ) {
        self.id = id
        self.name = name
        self.iconName = iconName
        self.url = url
    }

    /// 初始默认常用位置
    public static var defaults: [LocalLocation] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        return [
            LocalLocation(id: "home", name: "个人主目录", iconName: "house", url: home),
            LocalLocation(
                id: "desktop",
                name: "桌面",
                iconName: "desktopcomputer",
                url: fm.urls(for: .desktopDirectory, in: .userDomainMask).first ?? home.appendingPathComponent("Desktop")
            ),
            LocalLocation(
                id: "documents",
                name: "文稿",
                iconName: "doc",
                url: fm.urls(for: .documentDirectory, in: .userDomainMask).first ?? home.appendingPathComponent("Documents")
            ),
            LocalLocation(
                id: "downloads",
                name: "下载",
                iconName: "arrow.down.circle",
                url: fm.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? home.appendingPathComponent("Downloads")
            ),
            LocalLocation(
                id: "projects",
                name: "Projects",
                iconName: "folder",
                url: home.appendingPathComponent("Projects")
            )
        ]
    }
}
