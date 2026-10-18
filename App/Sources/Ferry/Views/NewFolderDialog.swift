import SwiftUI

/// 新建文件夹弹窗视图（防长路径溢出，支持中段截断与规范校验）
public struct NewFolderDialog: View {
    @Binding var isPresented: Bool
    @Binding var isRemote: Bool
    let isRemoteConnected: Bool
    let localURL: URL
    let remotePathString: String
    let onCreateLocal: (String) -> Void
    let onCreateRemote: (String) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var folderName: String = ""
    @FocusState private var isFieldFocused: Bool

    private var theme: FerryTheme {
        ThemeManager.shared.theme(for: colorScheme)
    }

    private var trimmedName: String {
        folderName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasInvalidChar: Bool {
        trimmedName.contains("/")
    }

    private var isValid: Bool {
        !trimmedName.isEmpty && !hasInvalidChar
    }

    private var targetDirectoryDisplay: String {
        if isRemote {
            return remotePathString.isEmpty ? "/" : remotePathString
        } else {
            return localURL.path
        }
    }

    public init(
        isPresented: Binding<Bool>,
        isRemote: Binding<Bool>,
        isRemoteConnected: Bool,
        localURL: URL,
        remotePathString: String,
        onCreateLocal: @escaping (String) -> Void,
        onCreateRemote: @escaping (String) -> Void
    ) {
        self._isPresented = isPresented
        self._isRemote = isRemote
        self.isRemoteConnected = isRemoteConnected
        self.localURL = localURL
        self.remotePathString = remotePathString
        self.onCreateLocal = onCreateLocal
        self.onCreateRemote = onCreateRemote
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 头部标题与图标
            HStack(spacing: 8) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(theme.accentColor)
                Text(isRemote ? "新建远程文件夹" : "新建本地文件夹")
                    .font(FerryFont.bodyBold)
                    .foregroundColor(theme.text)
                Spacer()
            }

            // 目标面板切换（仅在已连接远程时展示）
            if isRemoteConnected {
                Picker("目标位置", selection: $isRemote) {
                    Text("本地目录").tag(false)
                    Text("远程目录").tag(true)
                }
                .pickerStyle(.segmented)
            }

            // 目标路径展示卡片（防超长路径撑破布局，使用中段省略和固定容器）
            VStack(alignment: .leading, spacing: 4) {
                Text("创建于以下目录：")
                    .font(FerryFont.caption)
                    .foregroundColor(theme.text2)

                HStack(spacing: 6) {
                    Image(systemName: isRemote ? "server.rack" : "internaldrive")
                        .font(.system(size: 11))
                        .foregroundColor(theme.accentColor)

                    Text(targetDirectoryDisplay)
                        .font(FerryFont.monoCaption)
                        .foregroundColor(theme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(targetDirectoryDisplay)
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

            // 文件夹名称输入框
            VStack(alignment: .leading, spacing: 6) {
                Text("文件夹名称：")
                    .font(FerryFont.caption)
                    .foregroundColor(theme.text2)

                TextField("输入文件夹名称", text: $folderName)
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
                        Text("文件夹名称不能包含 “/”")
                            .font(FerryFont.caption)
                            .foregroundColor(theme.errorRed)
                    }
                }
            }

            // 操作按钮组
            HStack {
                Button("取消") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("创建") {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(theme.accentColor)
                .disabled(!isValid)
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
        guard isValid else { return }
        isPresented = false
        if isRemote {
            onCreateRemote(trimmedName)
        } else {
            onCreateLocal(trimmedName)
        }
    }
}
