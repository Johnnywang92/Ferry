import FerryCore
import SwiftUI

public struct FileConflictDialogView: View {
    public let conflict: FileConflictItem
    public let totalConflicts: Int
    public let remainingConflicts: Int
    public let onResolve: (ConflictDecision, _ applyToAll: Bool) -> Void
    public let onCancel: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    private var theme: FerryTheme {
        ThemeManager.shared.theme(for: colorScheme)
    }

    public enum SelectionMode: Hashable {
        case overwrite
        case skip
        case rename
        case overwriteIfNewer
    }

    @State private var selectedMode: SelectionMode = .overwrite
    @State private var customRenameText: String = ""
    @State private var applyToAll: Bool = false

    public init(
        conflict: FileConflictItem,
        totalConflicts: Int,
        remainingConflicts: Int,
        onResolve: @escaping (ConflictDecision, Bool) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.conflict = conflict
        self.totalConflicts = totalConflicts
        self.remainingConflicts = remainingConflicts
        self.onResolve = onResolve
        self.onCancel = onCancel
        _customRenameText = State(initialValue: conflict.suggestedRename)
    }

    private var isUpload: Bool {
        conflict.direction == .upload
    }

    private var targetLocationName: String {
        isUpload ? "远程" : "本地"
    }

    private var sourceLocationName: String {
        isUpload ? "本地" : "远程"
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 标题与说明（UI-REFERENCE.md §5）
            VStack(alignment: .leading, spacing: 4) {
                Text("\(targetLocationName)已存在\"\(conflict.fileName)\"")
                    .font(FerryFont.titleBold)
                    .foregroundColor(theme.text)

                let desc: String = {
                    let action = isUpload ? "上传" : "下载"
                    if totalConflicts > 1 {
                        return "\(action)会遇到同名文件。请选择如何处理，这次传输共有 \(totalConflicts) 个冲突。"
                    } else {
                        return "\(action)会遇到同名文件。请选择如何处理。"
                    }
                }()

                Text(desc)
                    .font(FerryFont.caption)
                    .foregroundColor(theme.text2)
            }

            // 对比区两栏（两栏卡片，源 vs 目标）
            HStack(spacing: 12) {
                // 源方卡片
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("\(sourceLocationName)（要\(isUpload ? "上传" : "下载")的）")
                            .font(FerryFont.captionMedium)
                            .foregroundColor(theme.text2)
                        Spacer()
                        if conflict.isSourceNewer {
                            Text("较新")
                                .font(FerryFont.micro)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(theme.accentColor.opacity(0.18))
                                .foregroundColor(theme.accentColor)
                                .cornerRadius(FerryRadius.r3)
                        }
                    }

                    Text(formattedSize(conflict.sourceSize))
                        .font(FerryFont.monoSmall)
                        .foregroundColor(theme.text)

                    Text(formattedDate(conflict.sourceDate))
                        .font(FerryFont.caption)
                        .foregroundColor(theme.text3)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.panel)
                .cornerRadius(FerryRadius.r6)
                .overlay(
                    RoundedRectangle(cornerRadius: FerryRadius.r6)
                        .stroke(conflict.isSourceNewer ? theme.accentColor.opacity(0.4) : theme.line, lineWidth: 1)
                )

                // 目标方卡片
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("\(targetLocationName)（\(isUpload ? "服务器" : "本地磁盘")上的）")
                            .font(FerryFont.captionMedium)
                            .foregroundColor(theme.text2)
                        Spacer()
                        if !conflict.isSourceNewer && conflict.sourceDate != nil && conflict.destinationDate != nil && conflict.sourceDate! < conflict.destinationDate! {
                            Text("较新")
                                .font(FerryFont.micro)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(theme.accentColor.opacity(0.18))
                                .foregroundColor(theme.accentColor)
                                .cornerRadius(FerryRadius.r3)
                        }
                    }

                    Text(formattedSize(conflict.destinationSize))
                        .font(FerryFont.monoSmall)
                        .foregroundColor(theme.text)

                    Text(formattedDate(conflict.destinationDate))
                        .font(FerryFont.caption)
                        .foregroundColor(theme.text3)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.panel)
                .cornerRadius(FerryRadius.r6)
                .overlay(
                    RoundedRectangle(cornerRadius: FerryRadius.r6)
                        .stroke(theme.line, lineWidth: 1)
                )
            }

            Divider().background(theme.line)

            // 四策略单选（UI-REFERENCE.md §5）
            VStack(alignment: .leading, spacing: 10) {
                strategyOption(
                    mode: .overwrite,
                    title: "覆盖",
                    subtitle: "用\(sourceLocationName)文件替换\(targetLocationName)文件"
                )

                strategyOption(
                    mode: .skip,
                    title: "跳过",
                    subtitle: "保留\(targetLocationName)文件，不\(isUpload ? "上传" : "下载")"
                )

                strategyOption(
                    mode: .rename,
                    title: "重命名",
                    subtitle: "以新文件名保存"
                ) {
                    if selectedMode == .rename {
                        TextField("新文件名", text: $customRenameText)
                            .textFieldStyle(.plain)
                            .font(FerryFont.monoSmall)
                            .foregroundColor(theme.text)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(theme.field)
                            .cornerRadius(FerryRadius.r4)
                            .overlay(
                                RoundedRectangle(cornerRadius: FerryRadius.r4)
                                    .stroke(theme.accentColor, lineWidth: 1)
                            )
                            .padding(.top, 2)
                    }
                }

                strategyOption(
                    mode: .overwriteIfNewer,
                    title: "仅在较新时覆盖",
                    subtitle: "\(sourceLocationName)文件更新才替换，否则跳过"
                )
            }

            // 批量应用复选框
            if remainingConflicts > 0 {
                Toggle(isOn: $applyToAll) {
                    Text("对其余 \(remainingConflicts) 个冲突执行相同操作")
                        .font(FerryFont.captionMedium)
                        .foregroundColor(theme.text)
                }
                .toggleStyle(.checkbox)
                .padding(.top, 2)
            }

            // 底部操作按钮
            HStack {
                Button("取消传输") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("继续") {
                    commitDecision()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(theme.accentColor)
                .disabled(selectedMode == .rename && customRenameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 480)
        .background(theme.bg)
    }

    @ViewBuilder
    private func strategyOption<ExtraContent: View>(
        mode: SelectionMode,
        title: String,
        subtitle: String,
        @ViewBuilder extra: () -> ExtraContent = { EmptyView() }
    ) -> some View {
        Button {
            selectedMode = mode
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .strokeBorder(selectedMode == mode ? theme.accentColor : theme.text3, lineWidth: selectedMode == mode ? 4 : 1.5)
                    .background(Circle().fill(Color.clear))
                    .frame(width: 14, height: 14)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(FerryFont.bodyBold)
                            .foregroundColor(theme.text)
                        Text("— \(subtitle)")
                            .font(FerryFont.caption)
                            .foregroundColor(theme.text2)
                    }
                    extra()
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func commitDecision() {
        let decision: ConflictDecision
        switch selectedMode {
        case .overwrite:
            decision = .overwrite
        case .skip:
            decision = .skip
        case .rename:
            let name = customRenameText.trimmingCharacters(in: .whitespacesAndNewlines)
            decision = .rename(newName: name.isEmpty ? conflict.suggestedRename : name)
        case .overwriteIfNewer:
            decision = .overwriteIfNewer
        }
        onResolve(decision, applyToAll)
    }

    private func formattedSize(_ bytes: Int64?) -> String {
        guard let b = bytes, b >= 0 else { return "--" }
        return ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    private func formattedDate(_ date: Date?) -> String {
        guard let d = date else { return "--" }
        let cal = Calendar.current
        if cal.isDateInToday(d) {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            return "今天 \(formatter.string(from: d))"
        } else if cal.isDate(d, equalTo: Date(), toGranularity: .year) {
            let formatter = DateFormatter()
            formatter.dateFormat = "M月d日 HH:mm"
            return formatter.string(from: d)
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy年M月d日"
            return formatter.string(from: d)
        }
    }
}
