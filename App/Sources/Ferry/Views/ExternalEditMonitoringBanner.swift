import AppKit
import FerryCore
import SwiftUI

/// 外部编辑“正在监视”状态条（v2.3 §381）。
public struct ExternalEditMonitoringBanner: View {
    @Environment(\.colorScheme) private var colorScheme
    private var service: ExternalEditService { ExternalEditService.shared }
    private var theme: FerryTheme {
        ThemeManager.shared.theme(for: colorScheme)
    }

    public init() {}

    public var body: some View {
        if let session = service.currentSession {
            HStack(spacing: 12) {
                // 状态指示图标与动画
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor(for: session.status))
                        .frame(width: 8, height: 8)

                    Text(L10n.format("外部编辑：%@", "External edit: %@", session.remoteItem.name))
                        .font(FerryFont.subheadlineBold)
                        .foregroundColor(theme.text)

                    Text("(\(session.status.displayText))")
                        .font(FerryFont.caption)
                        .foregroundColor(theme.text2)
                }

                Spacer()

                // 自动回传开关（默认关，v2.3 §381）
                Toggle(isOn: Binding(
                    get: { session.isAutoUploadEnabled },
                    set: { session.isAutoUploadEnabled = $0 }
                )) {
                    Text(L10n.tr("自动回传", "Auto Upload"))
                        .font(FerryFont.captionMedium)
                        .foregroundColor(theme.text)
                }
                .toggleStyle(.checkbox)

                // 手动立即上传按钮
                Button(action: {
                    Task {
                        await service.uploadChanges(for: session)
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 11))
                        Text(L10n.tr("立即上传", "Upload Now"))
                            .font(FerryFont.captionBold)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(session.hasPendingChanges ? theme.accentColor : theme.field)
                    .foregroundColor(session.hasPendingChanges ? .white : theme.text3)
                    .cornerRadius(FerryRadius.r4)
                }
                .buttonStyle(.plain)
                .disabled(!session.hasPendingChanges || session.status == .uploading)

                // 结束编辑按钮
                Button(action: {
                    service.closeSession(session)
                }) {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 13))
                        .foregroundColor(theme.text3)
                }
                .buttonStyle(.plain)
                .help(L10n.tr("完成编辑并关闭监视", "Finish editing and stop monitoring"))
            }
            .padding(.horizontal, 16)
            .frame(height: 32)
            .background(theme.panel)
            .overlay(
                Rectangle()
                    .frame(height: 1)
                    .foregroundColor(theme.line),
                alignment: .bottom
            )
            // 远端 mtime 冲突提示
            .alert(
                L10n.tr("远端文件在编辑期间已被更改", "Remote file has been modified during editing"),
                isPresented: Binding(
                    get: { service.conflictPromptSession != nil },
                    set: { if !$0 { service.conflictPromptSession = nil } }
                )
            ) {
                Button(L10n.tr("仍要覆盖远端", "Overwrite Remote Anyway"), role: .destructive) {
                    if let s = service.conflictPromptSession {
                        Task {
                            await service.uploadChanges(for: s, forceOverwrite: true)
                        }
                    }
                }
                Button(L10n.tr("取消上传", "Cancel Upload"), role: .cancel) {
                    service.conflictPromptSession = nil
                }
            } message: {
                if let d = service.conflictRemoteDate {
                    Text(L10n.format("服务器上的同名文件修改时间为 %@，比您开始编辑时更新。覆盖将替换服务器上的最新内容。", "Remote file modified at %@, newer than your editing session. Overwrite will replace server content.", formattedConflictDate(d)))
                } else {
                    Text(L10n.tr("服务器上的同名文件已被其他人或外部进程修改。覆盖将替换服务器上的最新内容。", "Remote file has been modified by another process. Overwrite will replace server content."))
                }
            }
        }
    }

    private func formattedConflictDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: date)
    }


    private func statusColor(for status: ExternalEditStatus) -> Color {
        switch status {
        case .monitoring: return theme.accentColor
        case .hasChanges: return theme.warningOrange
        case .uploading: return theme.accentColor
        case .uploaded: return .green
        case .conflict: return .red
        case .error: return .red
        }
    }
}
