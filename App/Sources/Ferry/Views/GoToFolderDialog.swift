import SwiftUI

/// `⌘⇧G` 前往文件夹弹窗（M2 交付，v2.3 §357 / §520）。
public struct GoToFolderDialog: View {
    public enum TargetPane: String, CaseIterable, Identifiable {
        case local = "本地目录"
        case remote = "远程目录"

        public var id: String { rawValue }
    }

    @Binding var isPresented: Bool
    let isRemoteConnected: Bool
    let initialLocalPath: String
    let initialRemotePath: String
    let onGoLocal: (String) throws -> Void
    let onGoRemote: (String) async throws -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var targetPane: TargetPane
    @State private var pathInput: String
    @State private var errorMessage: String?
    @State private var isNavigating = false

    private var theme: FerryTheme {
        ThemeManager.shared.theme(for: colorScheme)
    }

    public init(
        isPresented: Binding<Bool>,
        isRemoteConnected: Bool,
        initialLocalPath: String,
        initialRemotePath: String,
        onGoLocal: @escaping (String) throws -> Void,
        onGoRemote: @escaping (String) async throws -> Void
    ) {
        self._isPresented = isPresented
        self.isRemoteConnected = isRemoteConnected
        self.initialLocalPath = initialLocalPath
        self.initialRemotePath = initialRemotePath
        self.onGoLocal = onGoLocal
        self.onGoRemote = onGoRemote

        let defaultTarget: TargetPane = isRemoteConnected ? .remote : .local
        self._targetPane = State(initialValue: defaultTarget)
        self._pathInput = State(initialValue: defaultTarget == .remote ? initialRemotePath : initialLocalPath)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "folder.badge.gearshape")
                    .font(.system(size: 18))
                    .foregroundColor(theme.accentColor)
                Text("前往文件夹 (⌘⇧G)")
                    .font(FerryFont.bodyBold)
                    .foregroundColor(theme.text)
                Spacer()
            }

            if isRemoteConnected {
                Picker("目标面板", selection: $targetPane) {
                    ForEach(TargetPane.allCases) { pane in
                        Text(pane.rawValue).tag(pane)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: targetPane) { _, newValue in
                    errorMessage = nil
                    pathInput = (newValue == .remote) ? initialRemotePath : initialLocalPath
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(targetPane == .remote ? "输入远程路径（支持 ~、相对路径与绝对路径）：" : "输入本地路径（支持 ~ 展开与相对路径）：")
                    .font(FerryFont.caption)
                    .foregroundColor(theme.text2)

                TextField(targetPane == .remote ? "/var/www/html 或 ~/spike" : "~/Projects", text: $pathInput)
                    .textFieldStyle(.roundedBorder)
                    .font(FerryFont.monoBody)
                    .onSubmit {
                        submit()
                    }
            }

            if let err = errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(theme.errorRed)
                    Text(err)
                        .font(FerryFont.caption)
                        .foregroundColor(theme.errorRed)
                }
            }

            HStack {
                Spacer()
                Button("取消") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button(isNavigating ? "前往中..." : "前往") {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(theme.accentColor)
                .disabled(isNavigating || pathInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
        .background(theme.bg)
    }

    private func submit() {
        errorMessage = nil
        let trimmed = pathInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        switch targetPane {
        case .local:
            do {
                try onGoLocal(trimmed)
                isPresented = false
            } catch {
                errorMessage = error.localizedDescription
            }
        case .remote:
            isNavigating = true
            Task {
                do {
                    try await onGoRemote(trimmed)
                    isNavigating = false
                    isPresented = false
                } catch {
                    isNavigating = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
