import FerryCore
import SwiftUI

/// 待重命名的目标对象（区分本地与远程）
public enum RenameTarget: Identifiable, Sendable {
    case local(item: LocalItem)
    case remote(item: RemoteDisplayItem)

    public var id: String {
        switch self {
        case .local(let item): return "local:\(item.id)"
        case .remote(let item): return "remote:\(item.id)"
        }
    }

    public var isDirectory: Bool {
        switch self {
        case .local(let item): return item.isDirectory
        case .remote(let item): return item.isDirectory
        }
    }

    public var isRemote: Bool {
        switch self {
        case .local: return false
        case .remote: return true
        }
    }

    public var currentName: String {
        switch self {
        case .local(let item): return item.name
        case .remote(let item): return item.name
        }
    }

    public var locationDisplay: String {
        switch self {
        case .local(let item):
            return item.url.deletingLastPathComponent().path
        case .remote(let item):
            return (try? PathResolver.parent(of: item.path))?.description ?? "/"
        }
    }
}

/// 重命名弹窗视图（支持文件与文件夹、本地与远程、带字符校验与中段省略卡片）
public struct RenameDialog: View {
    let target: RenameTarget
    let onDismiss: () -> Void
    let onConfirmLocal: (LocalItem, String) throws -> Void
    let onConfirmRemote: (RemoteDisplayItem, String) async -> (success: Bool, error: String?)

    @Environment(\.colorScheme) private var colorScheme
    @State private var newName: String = ""
    @State private var errorMessage: String?
    @State private var isSubmitting: Bool = false
    @FocusState private var isFieldFocused: Bool

    private var theme: FerryTheme {
        ThemeManager.shared.theme(for: colorScheme)
    }

    private var trimmedName: String {
        newName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isNameChanged: Bool {
        trimmedName != target.currentName
    }

    private var hasInvalidChar: Bool {
        trimmedName.contains("/")
    }

    private var isValid: Bool {
        !trimmedName.isEmpty && !hasInvalidChar && isNameChanged
    }

    public init(
        target: RenameTarget,
        onDismiss: @escaping () -> Void,
        onConfirmLocal: @escaping (LocalItem, String) throws -> Void,
        onConfirmRemote: @escaping (RemoteDisplayItem, String) async -> (success: Bool, error: String?)
    ) {
        self.target = target
        self.onDismiss = onDismiss
        self.onConfirmLocal = onConfirmLocal
        self.onConfirmRemote = onConfirmRemote
        self._newName = State(initialValue: target.currentName)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 头部标题与图标
            HStack(spacing: 8) {
                Image(systemName: target.isDirectory ? "folder" : "doc")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(theme.accentColor)
                Text(target.isDirectory ? (target.isRemote ? L10n.tr("重命名远程文件夹", "Rename Remote Folder") : L10n.tr("重命名本地文件夹", "Rename Local Folder")) : (target.isRemote ? L10n.tr("重命名远程文件", "Rename Remote File") : L10n.tr("重命名本地文件", "Rename Local File")))
                    .font(FerryFont.bodyBold)
                    .foregroundColor(theme.text)
                Spacer()
            }

            // 所在位置展示卡片（防超长路径撑破布局）
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("所在目录：", "Directory:"))
                    .font(FerryFont.caption)
                    .foregroundColor(theme.text2)

                HStack(spacing: 6) {
                    Image(systemName: target.isRemote ? "server.rack" : "internaldrive")
                        .font(.system(size: 11))
                        .foregroundColor(theme.accentColor)

                    Text(target.locationDisplay)
                        .font(FerryFont.monoCaption)
                        .foregroundColor(theme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(target.locationDisplay)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(theme.line, lineWidth: 1)
                )
                .cornerRadius(6)
            }

            // 新名称输入框
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.tr("新名称：", "New Name:"))
                    .font(FerryFont.caption)
                    .foregroundColor(theme.text2)

                TextField(L10n.tr("输入新名称", "Enter new name"), text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .font(FerryFont.body)
                    .focused($isFieldFocused)
                    .onSubmit {
                        submit()
                    }

                if hasInvalidChar {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(theme.errorRed)
                        Text(L10n.tr("名称不能包含 “/”", "Name cannot contain '/'"))
                            .font(FerryFont.caption)
                            .foregroundColor(theme.errorRed)
                    }
                } else if !isNameChanged && !trimmedName.isEmpty {
                    Text(L10n.tr("名称未更改", "Name unchanged"))
                        .font(FerryFont.caption)
                        .foregroundColor(theme.text3)
                }
            }

            // 错误提示条
            if let err = errorMessage {
                HStack(spacing: 4) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(theme.errorRed)
                    Text(err)
                        .font(FerryFont.caption)
                        .foregroundColor(theme.errorRed)
                        .lineLimit(2)
                }
            }

            // 操作按钮组
            HStack {
                Button(L10n.tr("取消", "Cancel")) {
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isSubmitting)

                Spacer()

                Button(isSubmitting ? L10n.tr("正在重命名...", "Renaming...") : L10n.tr("重命名", "Rename")) {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(theme.accentColor)
                .disabled(!isValid || isSubmitting)
            }
        }
        .padding(20)
        .frame(width: 400)
        .background(theme.bg)
        .onAppear {
            isFieldFocused = true
        }
    }

    private func submit() {
        guard isValid, !isSubmitting else { return }
        errorMessage = nil
        isSubmitting = true

        switch target {
        case .local(let item):
            do {
                try onConfirmLocal(item, trimmedName)
                isSubmitting = false
                onDismiss()
            } catch {
                isSubmitting = false
                errorMessage = error.localizedDescription
            }
        case .remote(let item):
            Task {
                let result = await onConfirmRemote(item, trimmedName)
                isSubmitting = false
                if result.success {
                    onDismiss()
                } else {
                    errorMessage = result.error ?? L10n.tr("重命名失败", "Rename failed")
                }
            }
        }
    }
}
