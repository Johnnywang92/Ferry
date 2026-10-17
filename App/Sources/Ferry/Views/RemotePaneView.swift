import FerryCore
import SwiftUI

public struct RemotePaneView: View {
    @Binding var selectedIDs: Set<String>
    @Binding var showingNewConnection: Bool

    @Environment(\.colorScheme) private var colorScheme
    private var connectionService: ConnectionService { ConnectionService.shared }

    @State private var sortAscending: Bool = true

    private var theme: FerryTheme {
        ThemeManager().theme(for: colorScheme)
    }

    public var body: some View {
        VStack(spacing: 0) {
            // 栏头：远程标签 + 路径栏 + 上一级 + 刷新
            HStack(spacing: 8) {
                // `远程` 标签
                Text("远程")
                    .font(FerryFont.micro)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(theme.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(FerryRadius.r3)

                // 路径栏
                HStack(spacing: 4) {
                    Image(systemName: "network")
                        .font(.system(size: 11))
                        .foregroundColor(theme.text3)
                    Text(currentRemotePathString)
                        .font(FerryFont.monoSmall)
                        .foregroundColor(theme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(theme.panel)
                .cornerRadius(FerryRadius.r4)
                .overlay(
                    RoundedRectangle(cornerRadius: FerryRadius.r4)
                        .stroke(theme.line, lineWidth: 1)
                )

                // 返回上一级
                Button(action: {
                    Task { await connectionService.navigateRemoteUp() }
                }) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.icon)
                        .frame(width: 24, height: 24)
                        .background(theme.panel)
                        .cornerRadius(FerryRadius.r4)
                }
                .buttonStyle(.plain)
                .help("上一级")
                .disabled(!isConnected || connectionService.currentRemotePath?.description == "/")

                // 刷新
                Button(action: {
                    Task { await connectionService.refreshRemote() }
                }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                        .foregroundColor(theme.icon)
                        .frame(width: 24, height: 24)
                        .background(theme.panel)
                        .cornerRadius(FerryRadius.r4)
                }
                .buttonStyle(.plain)
                .help("刷新远程目录")
                .disabled(!isConnected)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(theme.bar)
            .overlay(
                Rectangle()
                    .frame(height: 1)
                    .foregroundColor(theme.line),
                alignment: .bottom
            )

            // 表头：名称 ↑ / 修改时间 / 大小 / 权限
            HStack(spacing: 0) {
                HStack(spacing: 4) {
                    Text("名称")
                        .font(FerryFont.captionBold)
                        .foregroundColor(theme.text2)
                    Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
                        .font(.system(size: 9))
                        .foregroundColor(theme.text3)
                }
                .padding(.leading, 12)
                .frame(maxWidth: .infinity, alignment: .leading)

                Text("修改时间")
                    .font(FerryFont.captionBold)
                    .foregroundColor(theme.text2)
                    .frame(width: 120, alignment: .leading)

                Text("大小")
                    .font(FerryFont.captionBold)
                    .foregroundColor(theme.text2)
                    .frame(width: 75, alignment: .trailing)

                Text("权限")
                    .font(FerryFont.captionBold)
                    .foregroundColor(theme.text2)
                    .frame(width: 90, alignment: .center)
                    .padding(.trailing, 12)
            }
            .frame(height: 26)
            .background(theme.panel)
            .overlay(
                Rectangle()
                    .frame(height: 1)
                    .foregroundColor(theme.line),
                alignment: .bottom
            )

            // 文件列表或未连接空状态
            if !isConnected {
                unconnectedPlaceholder
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(connectionService.remoteItems) { item in
                            remoteRow(item)
                        }
                    }
                }
                .background(theme.bg)
            }
        }
    }

    private var isConnected: Bool {
        if case .connected = connectionService.state { return true }
        return false
    }

    private var currentRemotePathString: String {
        if let path = connectionService.currentRemotePath {
            return path.description
        }
        return "未连接"
    }

    private var unconnectedPlaceholder: some View {
        VStack(spacing: 14) {
            AppIconView(size: 56)

            Text("未连接到远程服务器")
                .font(FerryFont.bodyBold)
                .foregroundColor(theme.text)

            Text("点击下方按钮新建连接，或在左侧选择站点连接。")
                .font(FerryFont.caption)
                .foregroundColor(theme.text2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)

            Button("新建连接…") {
                showingNewConnection = true
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.accentColor)
            .controlSize(.regular)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bg)
    }

    private func remoteRow(_ item: RemoteDisplayItem) -> some View {
        let isSelected = selectedIDs.contains(item.id)

        return HStack(spacing: 0) {
            // 图标与名称
            HStack(spacing: 6) {
                Image(systemName: item.isDirectory ? "folder.fill" : (item.isSymbolicLink ? "arrow.turn.up.right" : "doc"))
                    .font(.system(size: 13))
                    .foregroundColor(item.isDirectory ? (isSelected ? .white : theme.accentColor) : (isSelected ? .white : theme.icon))

                Text(item.name)
                    .font(FerryFont.subheadline)
                    .foregroundColor(isSelected ? .white : theme.text)
                    .lineLimit(1)

                if let target = item.linkTarget {
                    Text("→ \(target)")
                        .font(FerryFont.micro)
                        .foregroundColor(isSelected ? .white.opacity(0.8) : theme.text3)
                        .lineLimit(1)
                }
            }
            .padding(.leading, 12)
            .frame(maxWidth: .infinity, alignment: .leading)

            // 修改时间
            Text(item.formattedDate)
                .font(FerryFont.monoSmall)
                .foregroundColor(isSelected ? .white.opacity(0.9) : theme.text2)
                .frame(width: 120, alignment: .leading)

            // 大小
            Text(item.formattedSize)
                .font(FerryFont.monoSmall)
                .foregroundColor(isSelected ? .white.opacity(0.9) : theme.text2)
                .frame(width: 75, alignment: .trailing)

            // 权限位（等宽）
            Text(item.permissionsString)
                .font(FerryFont.monoCaption)
                .foregroundColor(isSelected ? .white.opacity(0.9) : theme.text2)
                .frame(width: 90, alignment: .center)
                .padding(.trailing, 12)
        }
        .frame(height: 28)
        .background(
            Rectangle()
                .fill(isSelected ? theme.accentSelected : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if selectedIDs.contains(item.id) {
                selectedIDs.remove(item.id)
            } else {
                selectedIDs = [item.id]
            }
        }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                if item.isDirectory {
                    Task {
                        await connectionService.navigateRemote(to: item.path)
                        selectedIDs.removeAll()
                    }
                }
            }
        )
    }
}
