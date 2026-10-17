import FerryCore
import SwiftUI

public struct MainWindowView: View {
    @Environment(\.colorScheme) private var colorScheme
    private var themeManager: ThemeManager { ThemeManager.shared }
    private var connectionService: ConnectionService { ConnectionService.shared }

    @State private var selectedBookmark: SiteBookmark?
    @State private var showingNewConnection: Bool = false
    @State private var showingPreferences: Bool = false
    @State private var showingGoToFolder: Bool = false
    @State private var showingSyncSheet: Bool = false
    @State private var showingNewFolderSheet: Bool = false
    @State private var newFolderName: String = ""
    @State private var newFolderTargetIsRemote: Bool = false
    @State private var searchText: String = ""

    // 本地路径与选择
    @State private var currentLocalURL: URL = FileManager.default.homeDirectoryForCurrentUser
    @State private var selectedLocalIDs: Set<String> = []

    // 远程选择
    @State private var selectedRemoteIDs: Set<String> = []

    private var theme: FerryTheme {
        themeManager.theme(for: colorScheme)
    }

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            // 顶部工具栏（56px）
            ToolbarView(
                showingNewConnection: $showingNewConnection,
                showingGoToFolder: $showingGoToFolder,
                searchText: $searchText,
                onUpload: handleUpload,
                onDownload: handleDownload,
                onNewFolder: {
                    if case .connected = connectionService.state {
                        newFolderTargetIsRemote = true
                    } else {
                        newFolderTargetIsRemote = false
                    }
                    newFolderName = ""
                    showingNewFolderSheet = true
                },
                onRefresh: handleRefresh,
                onSync: {
                    showingSyncSheet = true
                },
                onDisconnect: handleDisconnect
            )

            // M4: 外部编辑“正在监视”状态条（v2.3 §381）
            ExternalEditMonitoringBanner()

            // 主体区域：左侧栏 + 双栏列表
            HStack(spacing: 0) {
                // 左侧栏（220px）
                SidebarView(
                    selectedBookmark: $selectedBookmark,
                    showingNewConnection: $showingNewConnection,
                    showingPreferences: $showingPreferences,
                    onConnectSite: { site in
                        connectToSite(site)
                    },
                    onSelectLocalLocation: { url in
                        currentLocalURL = url
                        selectedLocalIDs.removeAll()
                    }
                )

                // 中央双栏
                DualPaneView(
                    currentLocalURL: $currentLocalURL,
                    selectedLocalIDs: $selectedLocalIDs,
                    selectedRemoteIDs: $selectedRemoteIDs,
                    showingNewConnection: $showingNewConnection,
                    searchText: searchText,
                    onUploadSelected: handleUpload,
                    onDownloadSelected: handleDownload,
                    onNewLocalFolder: {
                        newFolderTargetIsRemote = false
                        newFolderName = ""
                        showingNewFolderSheet = true
                    },
                    onNewRemoteFolder: {
                        newFolderTargetIsRemote = true
                        newFolderName = ""
                        showingNewFolderSheet = true
                    }
                )
            }

            // 传输队列面板（行高 44px，头部 28px，UI-REFERENCE.md §2.3）
            if connectionService.isQueuePanelPresented {
                TransferQueuePanelView()
            }

            // 底部状态栏（26px）
            StatusBarView(
                localSelectedCount: selectedLocalIDs.count,
                localTotalCount: (try? LocalFileSystemService.shared.listContents(
                    at: currentLocalURL,
                    showHidden: themeManager.showHiddenFiles
                ).count) ?? 0,
                remoteSelectedCount: selectedRemoteIDs.count,
                remoteTotalCount: connectionService.remoteItems.filter {
                    themeManager.showHiddenFiles || !$0.isHidden
                }.count
            )
        }
        .frame(minWidth: 960, minHeight: 600)
        .background(theme.bg)
        .preferredColorScheme(themeManager.preferredColorScheme)
        // 新建/编辑连接弹窗
        .sheet(isPresented: $showingNewConnection) {
            ConnectionDialogView(
                isPresented: $showingNewConnection,
                initialBookmark: selectedBookmark,
                onConnect: { bookmark in
                    selectedBookmark = bookmark
                    connectToSite(bookmark)
                }
            )
        }
        // 偏好设置与 SSH 导入弹窗
        .sheet(isPresented: $showingPreferences) {
            PreferencesSheetView(isPresented: $showingPreferences)
        }
        // 前往文件夹弹窗 (⌘⇧G)
        .sheet(isPresented: $showingGoToFolder) {
            GoToFolderDialog(
                isPresented: $showingGoToFolder,
                isRemoteConnected: isRemoteConnected,
                initialLocalPath: currentLocalURL.path,
                initialRemotePath: connectionService.currentRemotePath?.description ?? "/",
                onGoLocal: { rawPath in
                    let resolved = try LocalFileSystemService.shared.resolvePath(rawPath, relativeTo: currentLocalURL)
                    currentLocalURL = resolved
                    selectedLocalIDs.removeAll()
                },
                onGoRemote: { remotePath in
                    try await connectionService.navigateRemote(toPathString: remotePath)
                    selectedRemoteIDs.removeAll()
                }
            )
        }
        // 新建文件夹弹窗
        .sheet(isPresented: $showingNewFolderSheet) {
            newFolderDialog
        }
        // TOFU 主机密钥询问弹窗
        .sheet(isPresented: Binding(
            get: { connectionService.pendingHostKeyQuestion != nil },
            set: { if !$0 { connectionService.resolveHostKeyDecision(.decline) } }
        )) {
            if let question = connectionService.pendingHostKeyQuestion {
                HostKeyPromptDialog(question: question) { decision in
                    connectionService.resolveHostKeyDecision(decision)
                }
            }
        }
        // 主机密钥变更阻断与自助移除弹窗
        .sheet(isPresented: Binding(
            get: { connectionService.pendingHostKeyMismatch != nil },
            set: { if !$0 { connectionService.dismissHostKeyMismatch() } }
        )) {
            if let alert = connectionService.pendingHostKeyMismatch {
                HostKeyMismatchDialog(
                    alert: alert,
                    onDismiss: {
                        connectionService.dismissHostKeyMismatch()
                    },
                    onRemoveAndReconnect: {
                        Task { await connectionService.removeMismatchedHostKeyAndReconnect() }
                    }
                )
            }
        }
        // 键盘交互认证弹窗
        .sheet(isPresented: Binding(
            get: { connectionService.pendingKeyboardRequest != nil },
            set: { if !$0 { connectionService.resolveKeyboardResponse(nil) } }
        )) {
            if let request = connectionService.pendingKeyboardRequest {
                KeyboardInteractiveDialog(request: request) { answers in
                    connectionService.resolveKeyboardResponse(answers)
                }
            }
        }
        // M4: 文件冲突策略解决弹窗（UI-REFERENCE.md §5）
        .sheet(isPresented: Binding(
            get: { connectionService.pendingConflictContext != nil },
            set: { if !$0 { connectionService.cancelConflict() } }
        )) {
            if let ctx = connectionService.pendingConflictContext {
                FileConflictDialogView(
                    conflict: ctx.item,
                    totalConflicts: ctx.totalCount,
                    remainingConflicts: ctx.remainingCount,
                    onResolve: { decision, applyToAll in
                        connectionService.resolveConflict(decision: decision, applyToAll: applyToAll)
                    },
                    onCancel: {
                        connectionService.cancelConflict()
                    }
                )
            }
        }
        // M5: 文件夹双向同步与 DiffPlan 弹窗（v2.3 §384-434, U4）
        .sheet(isPresented: $showingSyncSheet) {
            if let remotePath = connectionService.currentRemotePath,
               let fileSystem = connectionService.activeConnection {
                SyncSheetView(
                    isPresented: $showingSyncSheet,
                    localURL: currentLocalURL,
                    remotePath: remotePath,
                    fileSystem: fileSystem
                )
            }
        }

        .onReceive(NotificationCenter.default.publisher(for: .ferryOpenNewConnection)) { _ in
            selectedBookmark = nil
            showingNewConnection = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .ferryOpenGoToFolder)) { _ in
            showingGoToFolder = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .ferryToggleHiddenFiles)) { _ in
            themeManager.toggleHiddenFiles()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ferryOpenPreferences)) { _ in
            showingPreferences = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .ferryToggleTransferQueue)) { _ in
            connectionService.isQueuePanelPresented.toggle()
        }
        // M4: 空格键触发快速预览（Quick Look，v2.3 §374）
        .background(
            Button("") {
                handleQuickLook()
            }
            .keyboardShortcut(.space, modifiers: [])
            .opacity(0)
        )
        .onDisappear {
            QuickLookService.shared.cleanUpTempFiles()
            ExternalEditService.shared.closeAllSessions()
        }
    }

    private func handleQuickLook() {
        if let remoteId = selectedRemoteIDs.first,
           let item = connectionService.remoteItems.first(where: { $0.id == remoteId }) {
            QuickLookService.shared.togglePreview(
                remoteItem: item,
                connection: connectionService.activeConnection
            )
        } else if let localId = selectedLocalIDs.first {
            let url = URL(fileURLWithPath: localId)
            QuickLookService.shared.togglePreview(localURL: url)
        }
    }


    private var isRemoteConnected: Bool {
        if case .connected = connectionService.state { return true }
        return false
    }

    private var newFolderDialog: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(newFolderTargetIsRemote ? "新建远程文件夹" : "新建本地文件夹")
                .font(FerryFont.bodyBold)
                .foregroundColor(theme.text)

            if isRemoteConnected {
                Picker("位置", selection: $newFolderTargetIsRemote) {
                    Text("本地 (\(currentLocalURL.lastPathComponent))").tag(false)
                    Text("远程 (\(connectionService.currentRemotePath?.description ?? "/"))").tag(true)
                }
                .pickerStyle(.segmented)
            }

            TextField("文件夹名称", text: $newFolderName)
                .textFieldStyle(.roundedBorder)
                .font(FerryFont.body)
                .onSubmit {
                    confirmCreateFolder()
                }

            HStack {
                Button("取消") {
                    showingNewFolderSheet = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("创建") {
                    confirmCreateFolder()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(theme.accentColor)
                .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .background(theme.bg)
    }

    private func confirmCreateFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        showingNewFolderSheet = false
        if newFolderTargetIsRemote {
            Task {
                await connectionService.createRemoteFolder(named: name)
            }
        } else {
            _ = try? LocalFileSystemService.shared.createDirectory(named: name, in: currentLocalURL)
            NotificationCenter.default.post(name: .ferryRefreshLocalPane, object: nil)
        }
    }

    private func connectToSite(_ site: SiteBookmark) {
        let resolved = site.localBookmark.resolveURL()
        if FileManager.default.fileExists(atPath: resolved.url.path) {
            currentLocalURL = resolved.url
            selectedLocalIDs.removeAll()
        }
        Task {
            await connectionService.connect(to: site)
        }
    }

    private func handleUpload() {
        let urls = selectedLocalIDs.map { URL(fileURLWithPath: $0) }
        guard !urls.isEmpty else { return }
        connectionService.uploadFiles(urls)
    }

    private func handleDownload() {
        let chosen = connectionService.remoteItems.filter { selectedRemoteIDs.contains($0.id) }
        guard !chosen.isEmpty else { return }
        let destDir = currentLocalURL
        connectionService.downloadItems(chosen, to: destDir) {
            NotificationCenter.default.post(name: .ferryRefreshLocalPane, object: nil)
        }
    }

    private func handleRefresh() {
        NotificationCenter.default.post(name: .ferryRefreshLocalPane, object: nil)
        Task {
            await connectionService.refreshRemote()
        }
    }

    private func handleDisconnect() {
        Task {
            await connectionService.disconnect()
            selectedRemoteIDs.removeAll()
        }
    }
}
