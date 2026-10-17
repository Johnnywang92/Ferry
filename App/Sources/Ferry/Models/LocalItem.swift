import Foundation

public enum BrowserSortField: String, CaseIterable, Sendable {
    case name
    case modificationDate
    case size
    case permissions
}

public struct LocalItem: Identifiable, Hashable, Sendable {
    public var id: String { url.path }
    public let name: String
    public let url: URL
    public let isDirectory: Bool
    public let isSymbolicLink: Bool
    public let size: Int64
    public let modificationDate: Date?

    public var isHidden: Bool {
        name.hasPrefix(".")
    }

    public init(url: URL, isDirectory: Bool, isSymbolicLink: Bool = false, size: Int64 = 0, modificationDate: Date? = nil) {
        self.url = url
        self.name = url.lastPathComponent
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
        self.size = size
        self.modificationDate = modificationDate
    }

    /// 格式化大小展示
    public var formattedSize: String {
        if isDirectory { return "--" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    /// 格式化时间展示（符合 UI-REFERENCE.md：当天显示 今天 09:12，当年显示 10月13日 21:05，更早显示 9月28日）
    public var formattedDate: String {
        guard let date = modificationDate else { return "--" }
        return FerryDateFormatter.format(date)
    }
}

public enum FerryDateFormatter {
    private static let timeOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let thisYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M月d日 HH:mm"
        return f
    }()

    private static let olderFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy年M月d日"
        return f
    }()

    public static func format(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "今天 \(timeOnlyFormatter.string(from: date))"
        } else if calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
            return thisYearFormatter.string(from: date)
        } else {
            return olderFormatter.string(from: date)
        }
    }
}
