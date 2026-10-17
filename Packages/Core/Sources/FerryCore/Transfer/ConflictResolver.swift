import Foundation

/// 冲突处理策略（v2.3 §370, UI-REFERENCE.md §5）。
public enum ConflictDecision: Sendable, Hashable, Equatable {
    /// 覆盖：用源文件替换目标文件
    case overwrite
    /// 跳过：保留目标文件，不传输
    case skip
    /// 重命名：以指定的新文件名存储
    case rename(newName: String)
    /// 仅在源文件较新时覆盖：本地更新才替换（若目标更新或相同则跳过）
    case overwriteIfNewer
}

/// 冲突项元数据（用于 UI 对比展示与策略决议）。
public struct FileConflictItem: Identifiable, Sendable, Hashable, Equatable {
    public let id: UUID
    public let fileName: String
    public let direction: TransferDirection
    public let sourcePath: String
    public let sourceSize: Int64?
    public let sourceDate: Date?
    public let destinationPath: String
    public let destinationSize: Int64?
    public let destinationDate: Date?
    public let suggestedRename: String

    public init(
        id: UUID = UUID(),
        fileName: String,
        direction: TransferDirection,
        sourcePath: String,
        sourceSize: Int64?,
        sourceDate: Date?,
        destinationPath: String,
        destinationSize: Int64?,
        destinationDate: Date?,
        suggestedRename: String
    ) {
        self.id = id
        self.fileName = fileName
        self.direction = direction
        self.sourcePath = sourcePath
        self.sourceSize = sourceSize
        self.sourceDate = sourceDate
        self.destinationPath = destinationPath
        self.destinationSize = destinationSize
        self.destinationDate = destinationDate
        self.suggestedRename = suggestedRename
    }

    /// 源文件是否比目标文件更新。
    public var isSourceNewer: Bool {
        guard let sDate = sourceDate, let dDate = destinationDate else {
            return false
        }
        return sDate > dDate
    }
}

/// 冲突处理执行结果。
public enum ConflictResolutionOutcome: Sendable, Equatable {
    /// 继续传输，保持原路径（覆盖）
    case proceedOriginal
    /// 继续传输，使用新文件名（重命名）
    case proceedRenamed(newName: String)
    /// 放弃传输此文件
    case skipped
}

/// 冲突解决器算法工具集。
public enum ConflictResolver {
    /// 为冲突文件建议递增的新文件名。
    ///
    /// 规则：
    /// `main.css` -> `main_1.css` -> `main_2.css`
    /// `README` -> `README_1` -> `README_2`
    /// `archive.tar.gz` -> `archive.tar_1.gz`
    public static func suggestRename(for fileName: String, existingNames: Set<String> = []) -> String {
        let ns = NSString(string: fileName)
        let ext = ns.pathExtension
        let base = ns.deletingPathExtension

        var counter = 1
        while true {
            let candidate: String
            if ext.isEmpty {
                candidate = "\(base)_\(counter)"
            } else {
                candidate = "\(base)_\(counter).\(ext)"
            }
            if !existingNames.contains(candidate) {
                return candidate
            }
            counter += 1
        }
    }

    /// 根据决议计算具体操作结果。
    public static func resolve(
        item: FileConflictItem,
        decision: ConflictDecision
    ) -> ConflictResolutionOutcome {
        switch decision {
        case .overwrite:
            return .proceedOriginal
        case .skip:
            return .skipped
        case .rename(let newName):
            let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == item.fileName {
                return .proceedOriginal
            }
            return .proceedRenamed(newName: trimmed)
        case .overwriteIfNewer:
            if item.isSourceNewer {
                return .proceedOriginal
            } else {
                return .skipped
            }
        }
    }
}
