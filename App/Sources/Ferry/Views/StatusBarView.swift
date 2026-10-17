import SwiftUI

public struct StatusBarView: View {
    let localSelectedCount: Int
    let localTotalCount: Int
    let remoteSelectedCount: Int
    let remoteTotalCount: Int

    @Environment(\.colorScheme) private var colorScheme
    private var connectionService: ConnectionService { ConnectionService.shared }

    private var theme: FerryTheme {
        ThemeManager().theme(for: colorScheme)
    }

    public var body: some View {
        HStack(spacing: 12) {
            // 左：本地选择状态
            HStack(spacing: 4) {
                if localSelectedCount > 0 {
                    Text("本地 已选 \(localSelectedCount) 项 · 共 \(localTotalCount) 项")
                } else {
                    Text("本地 共 \(localTotalCount) 项")
                }
            }
            .font(FerryFont.caption)
            .foregroundColor(theme.text2)

            Spacer()

            // 中：实时网络速率指示
            HStack(spacing: 8) {
                Text("↑ 0 KB/s")
                Text("↓ 0 KB/s")
            }
            .font(FerryFont.monoCaption)
            .foregroundColor(theme.text3)

            Spacer()

            // 右：远端状态
            HStack(spacing: 6) {
                switch connectionService.state {
                case .connected:
                    if remoteSelectedCount > 0 {
                        Text("远程 已选 \(remoteSelectedCount) 项 · 共 \(remoteTotalCount) 项")
                    } else {
                        Text("远程 共 \(remoteTotalCount) 项")
                    }
                    Text("·")
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9))
                    Text("加密连接")
                    Text("·")
                    Text("UTF-8")
                case .connecting:
                    Text("连接握手中…")
                case .failed(let err):
                    Text("错误：\(err)")
                        .foregroundColor(theme.errorRed)
                case .disconnected:
                    Text("远程未连接")
                        .foregroundColor(theme.text3)
                }
            }
            .font(FerryFont.caption)
            .foregroundColor(theme.text2)
        }
        .padding(.horizontal, 16)
        .frame(height: 26)
        .background(theme.bar)
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(theme.barLine),
            alignment: .top
        )
    }
}
