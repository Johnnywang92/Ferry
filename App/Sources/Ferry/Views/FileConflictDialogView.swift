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
        isUpload ? L10n.tr("远程", "Remote") : L10n.tr("本地", "Local")
    }

    private var sourceLocationName: String {
        isUpload ? L10n.tr("本地", "Local") : L10n.tr("远程", "Remote")
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 标题与说明（UI-REFERENCE.md §5）
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.format("\"%@\" 已在 %@ 存在", "\"%@\" already exists on %@", conflict.fileName, targetLocationName))
                    .font(FerryFont.titleBold)
                    .foregroundColor(theme.text)

                let desc: String = {
                    let action = isUpload ? L10n.tr("上传", "Upload") : L10n.tr("下载", "Download")
                    if totalConflicts > 1 {
                        return L10n.format("%@会遇到同名文件。请选择如何处理，这次传输共有 %d 个冲突。", "%@ encountered an existing file. Please choose how to proceed (%d conflicts in total).", action, totalConflicts)
                    } else {
                        return L10n.format("%@会遇到同名文件。请选择如何处理。", "%@ encountered an existing file. Please choose how to proceed.", action)
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
                        Text(L10n.format("%@（要%@的）", "%@ (to %@)", sourceLocationName, isUpload ? L10n.tr("上传", "upload") : L10n.tr("下载", "download")))
                            .font(FerryFont.captionMedium)
                            .foregroundColor(theme.text2)
                        Spacer()
                        if conflict.isSourceNewer {
                            Text(L10n.tr("较新", "Newer"))
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
                        Text(L10n.format("%@（%@上的）", "%@ (on %@)", targetLocationName, isUpload ? L10n.tr("服务器", "server") : L10n.tr("本地磁盘", "local disk")))
                            .font(FerryFont.captionMedium)
                            .foregroundColor(theme.text2)
                        Spacer()
                        if !conflict.isSourceNewer && conflict.sourceDate != nil && conflict.destinationDate != nil && conflict.sourceDate! < conflict.destinationDate! {
                            Text(L10n.tr("较新", "Newer"))
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
                    title: L10n.tr("覆盖", "Overwrite"),
                    subtitle: L10n.format("用%@文件替换%@文件", "Replace %@ file with %@ file", targetLocationName, sourceLocationName)
                )

                strategyOption(
                    mode: .skip,
                    title: L10n.tr("跳过", "Skip"),
                    subtitle: L10n.format("保留%@文件，不%@", "Keep %@ file, do not %@", targetLocationName, isUpload ? L10n.tr("上传", "upload") : L10n.tr("下载", "download"))
                )

                strategyOption(
                    mode: .rename,
                    title: L10n.tr("重命名", "Rename"),
                    subtitle: L10n.tr("以新文件名保存", "Save with a new file name")
                ) {
                    if selectedMode == .rename {
                        TextField(L10n.tr("新文件名", "New file name"), text: $customRenameText)
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
                    title: L10n.tr("仅在较新时覆盖", "Overwrite if Newer"),
                    subtitle: L10n.format("%@文件更新才替换，否则跳过", "Replace only if %@ file is newer, otherwise skip", sourceLocationName)
                )
            }

            // 批量应用复选框
            if remainingConflicts > 0 {
                Toggle(isOn: $applyToAll) {
                    Text(L10n.format("对其余 %d 个冲突执行相同操作", "Apply to remaining %d conflicts", remainingConflicts))
                        .font(FerryFont.captionMedium)
                        .foregroundColor(theme.text)
                }
                .toggleStyle(.checkbox)
                .padding(.top, 2)
            }

            // 底部操作按钮
            HStack {
                Button(L10n.tr("取消传输", "Cancel Transfer")) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(L10n.tr("继续", "Continue")) {
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
