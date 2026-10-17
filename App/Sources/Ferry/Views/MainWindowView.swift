import FerryCore
import SwiftUI

public struct MainWindowView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var themeManager = ThemeManager()
    @State private var connectionService = ConnectionService.shared

    @State private var selectedBookmark: SiteBookmark?
    @State private var showingNewConnection: Bool = false
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
                searchText: $searchText,
                onUpload: handleUpload,
                onDownload: handleDownload,
                onNewFolder: handleNewFolder,
                onRefresh: handleRefresh,
                onDisconnect: handleDisconnect
            )

            // 主体区域：左侧栏 + 双栏列表
            HStack(spacing: 0) {
                // 左侧栏（220px）
                SidebarView(
                    selectedBookmark: $selectedBookmark,
                    showingNewConnection: $showingNewConnection,
                    onConnectSite: { site in
                        Task { await connectionService.connect(to: site) }
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
                    showingNewConnection: $showingNewConnection
                )
            }

            // 底部状态栏（26px）
            StatusBarView(
                localSelectedCount: selectedLocalIDs.count,
                localTotalCount: (try? LocalFileSystemService.shared.listContents(at: currentLocalURL).count) ?? 0,
                remoteSelectedCount: selectedRemoteIDs.count,
                remoteTotalCount: connectionService.remoteItems.count
            )
        }
        .frame(minWidth: 960, minHeight: 600)
        .background(theme.bg)
        .preferredColorScheme(themeManager.preferredColorScheme)
        // 新建连接弹窗
        .sheet(isPresented: $showingNewConnection) {
            ConnectionDialogView(
                isPresented: $showingNewConnection,
                initialBookmark: selectedBookmark,
                onConnect: { bookmark in
                    selectedBookmark = bookmark
                    Task { await connectionService.connect(to: bookmark) }
                }
            )
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
        .onReceive(NotificationCenter.default.publisher(for: .ferryOpenNewConnection)) { _ in
            showingNewConnection = true
        }
    }

    private func handleUpload() {
        // M1'-6 / M3 传输对接
    }

    private func handleDownload() {
        // M1'-6 / M3 传输对接
    }

    private func handleNewFolder() {
        // 创建新文件夹操作
    }

    private func handleRefresh() {
        // 刷新本地与远端
        Task {
            await connectionService.refreshRemote()
        }
    }

    private func handleDisconnect() {
        Task {
            await connectionService.disconnect()
        }
    }
}
