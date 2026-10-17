import FerryCore
import SwiftUI

public struct StatusBarView: View {
    let localSelectedCount: Int
    let localTotalCount: Int
    let remoteSelectedCount: Int
    let remoteTotalCount: Int

    @Environment(\.colorScheme) private var colorScheme
    private var connectionService: ConnectionService { ConnectionService.shared }

    private var theme: FerryTheme {
        ThemeManager.shared.theme(for: colorScheme)
    }

    private var formattedUploadSpeed: String {
        let speed = connectionService.aggregateSpeed.upload
        guard speed > 0 else { return "0 KB/s" }
        return ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file) + "/s"
    }

    private var formattedDownloadSpeed: String {
        let speed = connectionService.aggregateSpeed.download
        guard speed > 0 else { return "0 KB/s" }
        return ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file) + "/s"
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

            // 中：实时聚合传输速率指示与队列入口（UI-REFERENCE.md §2.4: `↑ 8.4 MB/s  ↓ 0 KB/s`，U7）
            Button(action: {
                connectionService.isQueuePanelPresented.toggle()
            }) {
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Text("↑ \(formattedUploadSpeed)")
                            .foregroundColor(connectionService.aggregateSpeed.upload > 0 ? theme.accentColor : theme.text3)
                        Text("↓ \(formattedDownloadSpeed)")
                            .foregroundColor(connectionService.aggregateSpeed.download > 0 ? theme.accentColor : theme.text3)
                    }
                    .font(FerryFont.monoCaption)

                    let summary = connectionService.queueSummary
                    if summary.running > 0 {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text("\(summary.running) 项进行中")
                                .font(FerryFont.caption)
                                .foregroundColor(theme.text2)
                        }
                    } else if summary.failed > 0 {
                        Text("\(summary.failed) 项失败")
                            .font(FerryFont.caption)
                            .foregroundColor(theme.errorRed)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("点击展开/收起传输队列")

            Spacer()

            // 右：远端状态 + 字符集实时切换菜单
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
                    Menu {
                        ForEach(CharsetConverter.Charset.allCases) { cs in
                            Button(action: {
                                connectionService.setCharset(cs)
                            }) {
                                HStack {
                                    Text(cs.displayName)
                                    if connectionService.currentCharset == cs {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        Text(connectionService.currentCharset.displayName)
                            .font(FerryFont.captionMedium)
                            .foregroundColor(theme.accentColor)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("切换远端文件名解码字符集（零网络往返实时重解码）")
                case .connecting:
                    Text("连接握手中…")
                case .failed(let err):
                    Text("错误：\(err)")
                        .foregroundColor(theme.errorRed)
                        .lineLimit(1)
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
