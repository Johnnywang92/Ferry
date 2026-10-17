import SwiftUI

public struct DualPaneView: View {
    @Binding var currentLocalURL: URL
    @Binding var selectedLocalIDs: Set<String>
    @Binding var selectedRemoteIDs: Set<String>
    @Binding var showingNewConnection: Bool
    var searchText: String
    var onUploadSelected: () -> Void
    var onDownloadSelected: () -> Void
    var onNewLocalFolder: () -> Void
    var onNewRemoteFolder: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    private var theme: FerryTheme {
        ThemeManager.shared.theme(for: colorScheme)
    }

    public var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                // 左侧本地栏
                LocalPaneView(
                    currentURL: $currentLocalURL,
                    selectedIDs: $selectedLocalIDs,
                    searchText: searchText,
                    onUploadSelected: onUploadSelected,
                    onNewLocalFolder: onNewLocalFolder
                )
                .frame(width: (geometry.size.width - 1) / 2)

                // 中间垂直分割线
                Rectangle()
                    .frame(width: 1)
                    .foregroundColor(theme.line)

                // 右侧远程栏
                RemotePaneView(
                    selectedIDs: $selectedRemoteIDs,
                    showingNewConnection: $showingNewConnection,
                    searchText: searchText,
                    onDownloadSelected: onDownloadSelected,
                    onNewRemoteFolder: onNewRemoteFolder
                )
                .frame(width: (geometry.size.width - 1) / 2)
            }
        }
    }
}
