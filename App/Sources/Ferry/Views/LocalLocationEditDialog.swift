import AppKit
import SwiftUI

/// 本地位置添加与编辑弹窗视图
public struct LocalLocationEditDialog: View {
    @Binding var isPresented: Bool
    let initialLocation: LocalLocation?
    let defaultDirectory: URL?
    let onSave: (LocalLocation) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var name: String = ""
    @State private var selectedURL: URL
    @State private var selectedIcon: String = "folder"
    @FocusState private var isFieldFocused: Bool

    private var theme: FerryTheme {
        ThemeManager.shared.theme(for: colorScheme)
    }

    private var isEditing: Bool {
        initialLocation != nil
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isValid: Bool {
        !trimmedName.isEmpty && !selectedURL.path.isEmpty
    }

    private let availableIcons: [String] = [
        "folder",
        "house",
        "desktopcomputer",
        "doc",
        "arrow.down.circle",
        "briefcase",
        "hammer",
        "terminal",
        "photo",
        "film",
        "music.note",
        "archivebox",
        "externaldrive",
        "cloud",
        "star",
        "bookmark"
    ]

    public init(
        isPresented: Binding<Bool>,
        initialLocation: LocalLocation?,
        defaultDirectory: URL? = nil,
        onSave: @escaping (LocalLocation) -> Void
    ) {
        self._isPresented = isPresented
        self.initialLocation = initialLocation
        self.defaultDirectory = defaultDirectory
        self.onSave = onSave

        let startingURL = initialLocation?.url
            ?? defaultDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser

        _selectedURL = State(initialValue: startingURL)
        _name = State(initialValue: initialLocation?.name ?? "")
        _selectedIcon = State(initialValue: initialLocation?.iconName ?? "folder")
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 头部标题与图标
            HStack(spacing: 8) {
                Image(systemName: isEditing ? "pencil.circle.fill" : "folder.badge.plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(theme.accentColor)
                Text(isEditing ? L10n.tr("编辑本地位置", "Edit Location") : L10n.tr("添加本地位置", "Add Location"))
                    .font(FerryFont.bodyBold)
                    .foregroundColor(theme.text)
                Spacer()
            }

            // 目标文件夹选择展示卡片
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("文件夹路径：", "Folder Path:"))
                    .font(FerryFont.caption)
                    .foregroundColor(theme.text2)

                HStack(spacing: 8) {
                    Image(systemName: selectedIcon)
                        .font(.system(size: 13))
                        .foregroundColor(theme.accentColor)
                        .frame(width: 16)

                    Text(selectedURL.path)
                        .font(FerryFont.monoCaption)
                        .foregroundColor(theme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(selectedURL.path)

                    Spacer()

                    Button(L10n.tr("选择文件夹…", "Choose Folder…")) {
                        chooseFolder()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(theme.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(theme.line, lineWidth: 1)
                )
                .cornerRadius(6)
            }

            // 位置名称输入框
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.tr("显示名称：", "Display Name:"))
                    .font(FerryFont.caption)
                    .foregroundColor(theme.text2)

                TextField(L10n.tr("例如：开发工程、下载暂存", "e.g. Workspace, Downloads"), text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(FerryFont.body)
                    .focused($isFieldFocused)
                    .onSubmit {
                        save()
                    }
            }

            // 图标选择器
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.tr("选择图标：", "Choose Icon:"))
                    .font(FerryFont.caption)
                    .foregroundColor(theme.text2)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8), spacing: 6) {
                    ForEach(availableIcons, id: \.self) { icon in
                        Button(action: {
                            selectedIcon = icon
                        }) {
                            Image(systemName: icon)
                                .font(.system(size: 14))
                                .foregroundColor(selectedIcon == icon ? theme.accentColor : theme.icon)
                                .frame(maxWidth: .infinity, minHeight: 32)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(selectedIcon == icon ? theme.accentColor.opacity(0.12) : theme.panel)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(selectedIcon == icon ? theme.accentColor : theme.line, lineWidth: selectedIcon == icon ? 1.5 : 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // 底部按钮组
            HStack {
                Button(L10n.tr("取消", "Cancel")) {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(isEditing ? L10n.tr("保存", "Save") : L10n.tr("添加", "Add")) {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(theme.accentColor)
                .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(theme.bg)
        .onAppear {
            if !isEditing && name.isEmpty {
                name = selectedURL.lastPathComponent
            }
            isFieldFocused = true
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = L10n.tr("选择", "Select")
        panel.directoryURL = selectedURL
        if panel.runModal() == .OK, let url = panel.url {
            selectedURL = url
            if trimmedName.isEmpty {
                name = url.lastPathComponent
            }
        }
    }

    private func save() {
        guard isValid else { return }
        isPresented = false
        let loc = LocalLocation(
            id: initialLocation?.id ?? UUID().uuidString,
            name: trimmedName,
            iconName: selectedIcon,
            url: selectedURL
        )
        onSave(loc)
    }
}
