import SwiftUI

public struct DualPaneView: View {
    @Binding var currentLocalURL: URL
    @Binding var selectedLocalIDs: Set<String>
    @Binding var selectedRemoteIDs: Set<String>
    @Binding var showingNewConnection: Bool

    @Environment(\.colorScheme) private var colorScheme
    private var theme: FerryTheme {
        ThemeManager().theme(for: colorScheme)
    }

    public var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                // 左侧本地栏
                LocalPaneView(currentURL: $currentLocalURL, selectedIDs: $selectedLocalIDs)
                    .frame(width: (geometry.size.width - 1) / 2)

                // 中间垂直分割线
                Rectangle()
                    .frame(width: 1)
                    .foregroundColor(theme.line)

                // 右侧远程栏
                RemotePaneView(selectedIDs: $selectedRemoteIDs, showingNewConnection: $showingNewConnection)
                    .frame(width: (geometry.size.width - 1) / 2)
            }
        }
    }
}
