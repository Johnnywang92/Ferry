import FerryCore
import SwiftUI

public struct ToolbarView: View {
    @Binding var showingNewConnection: Bool
    @Binding var searchText: String
    var onUpload: () -> Void
    var onDownload: () -> Void
    var onNewFolder: () -> Void
    var onRefresh: () -> Void
    var onDisconnect: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    private var connectionService: ConnectionService { ConnectionService.shared }

    private var theme: FerryTheme {
        ThemeManager().theme(for: colorScheme)
    }

    public var body: some View {
        HStack(spacing: 12) {
            // 左侧交通灯预留区域（216px，与左侧边栏对齐）
            HStack(spacing: 8) {
                AppIconView(size: 20)
                    .padding(.leading, 76) // 为交通灯留空
                Text("Ferry")
                    .font(FerryFont.bodyBold)
                    .foregroundColor(theme.text)
                Spacer()
            }
            .frame(width: 216)

            Divider()
                .frame(height: 28)
                .background(theme.barLine)

            // 中间主要动作按钮组（上传 / 下载 / 新建文件夹 / 刷新 / 同步 / 断开连接）
            HStack(spacing: 4) {
                toolbarButton(icon: "arrow.up.circle", label: "上传", action: onUpload)
                    .disabled(!isConnected)

                toolbarButton(icon: "arrow.down.circle", label: "下载", action: onDownload)
                    .disabled(!isConnected)

                toolbarButton(icon: "folder.badge.plus", label: "新建文件夹", action: onNewFolder)
                    .disabled(!isConnected)

                toolbarButton(icon: "arrow.clockwise", label: "刷新", action: onRefresh)

                toolbarButton(icon: "arrow.triangle.swap", label: "同步", action: {})
                    .disabled(true) // M5 前未实现
                    .help("同步比较功能将于后续里程碑开放")

                if isConnected {
                    toolbarButton(icon: "bolt.slash.circle", label: "断开连接", action: onDisconnect)
                } else {
                    toolbarButton(icon: "plus.circle.fill", label: "新建连接", action: { showingNewConnection = true })
                }
            }

            Spacer()

            // 右侧：连接状态胶囊
            connectionCapsule

            // 搜索框
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(theme.text3)
                TextField("搜索文件…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(FerryFont.caption)
                    .foregroundColor(theme.text)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(width: 150)
            .background(theme.field)
            .cornerRadius(FerryRadius.r6)
            .overlay(
                RoundedRectangle(cornerRadius: FerryRadius.r6)
                    .stroke(theme.line, lineWidth: 1)
            )
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .background(theme.bar)
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(theme.barLine),
            alignment: .bottom
        )
    }

    private var isConnected: Bool {
        if case .connected = connectionService.state { return true }
        return false
    }

    private func toolbarButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 17))
                    .frame(height: 20)
                Text(label)
                    .font(FerryFont.caption)
            }
            .frame(width: 56, height: 44)
            .foregroundColor(theme.icon)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // 连接胶囊：`● 生产 Web` + `SFTP · 已连接 · 32 ms`（根据 UI-REFERENCE.md §3）
    private var connectionCapsule: some View {
        HStack(spacing: 8) {
            switch connectionService.state {
            case .disconnected:
                Circle()
                    .fill(Color.gray.opacity(0.6))
                    .frame(width: 8, height: 8)
                Text("未连接")
                    .font(FerryFont.captionMedium)
                    .foregroundColor(theme.text2)

            case .connecting(let step):
                ProgressView().controlSize(.mini)
                Text(step)
                    .font(FerryFont.caption)
                    .foregroundColor(theme.text2)

            case .connected(let name, let proto, let rtt):
                Circle()
                    .fill(theme.successGreen)
                    .frame(width: 8, height: 8)
                Text(name)
                    .font(FerryFont.captionBold)
                    .foregroundColor(theme.text)
                Text("·")
                    .foregroundColor(theme.text3)
                Text("\(proto) · 已连接 · \(rtt) ms")
                    .font(FerryFont.caption)
                    .foregroundColor(theme.text2)

            case .failed(let msg):
                Circle()
                    .fill(theme.errorRed)
                    .frame(width: 8, height: 8)
                Text("连接失败：\(msg)")
                    .font(FerryFont.caption)
                    .foregroundColor(theme.errorRed)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(theme.panel)
        .cornerRadius(FerryRadius.r18)
        .overlay(
            RoundedRectangle(cornerRadius: FerryRadius.r18)
                .stroke(theme.pillRing, lineWidth: 1)
        )
    }
}
