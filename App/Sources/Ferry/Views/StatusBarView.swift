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

            // 中：实时传输状态或网络速率指示
            if let active = connectionService.activeTransfer {
                HStack(spacing: 8) {
                    ProgressView(value: active.progressFraction)
                        .progressViewStyle(.linear)
                        .frame(width: 90)
                        .tint(theme.accentColor)
                    if let err = active.errorMessage {
                        Text("\(active.direction.rawValue)失败：\(err)")
                            .font(FerryFont.caption)
                            .foregroundColor(theme.errorRed)
                            .lineLimit(1)
                    } else {
                        Text("\(active.direction == .upload ? "↑" : "↓") \(active.fileName) · \(active.formattedSpeed)")
                            .font(FerryFont.monoCaption)
                            .foregroundColor(theme.text)
                            .lineLimit(1)
                    }
                    Button(action: {
                        connectionService.cancelActiveTransfer()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(theme.text2)
                    }
                    .buttonStyle(.plain)
                    .help("取消当前传输（将按 M1-06 §9.1 硬拆传输连接并刷新）")
                }
            } else if let msg = connectionService.navigationErrorMessage {
                Text(msg)
                    .font(FerryFont.caption)
                    .foregroundColor(theme.errorRed)
                    .lineLimit(1)
            } else {
                HStack(spacing: 8) {
                    Text("↑ 0 KB/s")
                    Text("↓ 0 KB/s")
                }
                .font(FerryFont.monoCaption)
                .foregroundColor(theme.text3)
            }

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
