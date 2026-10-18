import FerryCore
import SwiftUI

public struct TransferQueuePanelView: View {
    public enum QueueFilter: String, CaseIterable, Identifiable {
        case all = "全部"
        case running = "进行中"
        case failed = "失败"

        public var id: String { rawValue }

        @MainActor
        public var displayName: String {
            switch self {
            case .all: return L10n.tr("全部", "All")
            case .running: return L10n.tr("进行中", "Running")
            case .failed: return L10n.tr("失败", "Failed")
            }
        }
    }

    @State private var selectedFilter: QueueFilter = .all
    @Environment(\.colorScheme) private var colorScheme

    private var connectionService: ConnectionService { ConnectionService.shared }
    private var themeManager: ThemeManager { ThemeManager.shared }
    private var theme: FerryTheme { themeManager.theme(for: colorScheme) }

    public init() {}

    private var filteredTasks: [TransferTaskState] {
        let all = connectionService.queueTasks
        switch selectedFilter {
        case .all:
            return all
        case .running:
            return all.filter { $0.status.isRunning || $0.status == .pending || $0.status.isPaused }
        case .failed:
            return all.filter { $0.status.isFailed }
        }
    }

    private var summaryText: String {
        if let prep = connectionService.transferPreparation {
            return prep.statusMessage
        }
        let summary = connectionService.queueSummary
        if summary.running == 0 && summary.failed == 0 && summary.pending == 0 {
            return connectionService.queueTasks.isEmpty ? L10n.tr("队列为空", "Queue empty") : L10n.tr("全部传输已完成", "All transfers completed")
        }
        var parts: [String] = []
        if summary.running > 0 {
            parts.append(L10n.format("%d 项进行中", "%d running", summary.running))
        }
        if summary.failed > 0 {
            parts.append(L10n.format("%d 项失败", "%d failed", summary.failed))
        }
        if summary.pending > 0 {
            parts.append(L10n.format("%d 项等待", "%d pending", summary.pending))
        }
        return parts.joined(separator: " · ")
    }

    public var body: some View {
        VStack(spacing: 0) {
            // 头部（28px，UI-REFERENCE.md §2.3）
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.arrow.down.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(theme.accentColor)

                    Text(L10n.tr("传输队列", "Transfer Queue"))
                        .font(FerryFont.subheadlineBold)
                        .foregroundColor(theme.text)

                    Text(summaryText)
                        .font(FerryFont.caption)
                        .foregroundColor(theme.text2)
                }

                Spacer()

                // 右侧筛选分段：全部 / 进行中 / 失败 (U8)
                Picker("", selection: $selectedFilter) {
                    ForEach(QueueFilter.allCases) { filter in
                        Text(filter.displayName).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 190)

                // 队列快捷全局操作
                HStack(spacing: 4) {
                    Button(action: {
                        if connectionService.queueSummary.running > 0 {
                            connectionService.pauseAllQueueTasks()
                        } else {
                            connectionService.resumeAllQueueTasks()
                        }
                    }) {
                        Image(systemName: connectionService.queueSummary.running > 0 ? "pause.fill" : "play.fill")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .frame(width: 20, height: 20)
                    .background(theme.btn)
                    .cornerRadius(FerryRadius.r4)
                    .overlay(RoundedRectangle(cornerRadius: FerryRadius.r4).stroke(theme.btnRing, lineWidth: 1))
                    .help(connectionService.queueSummary.running > 0 ? L10n.tr("全部暂停", "Pause All") : L10n.tr("全部继续", "Resume All"))

                    Button(action: {
                        connectionService.clearCompletedQueueTasks()
                    }) {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .frame(width: 20, height: 20)
                    .background(theme.btn)
                    .cornerRadius(FerryRadius.r4)
                    .overlay(RoundedRectangle(cornerRadius: FerryRadius.r4).stroke(theme.btnRing, lineWidth: 1))
                    .help(L10n.tr("清空已完成项目", "Clear Completed Items"))

                    Button(action: {
                        connectionService.isQueuePanelPresented = false
                    }) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .frame(width: 20, height: 20)
                    .background(theme.btn)
                    .cornerRadius(FerryRadius.r4)
                    .overlay(RoundedRectangle(cornerRadius: FerryRadius.r4).stroke(theme.btnRing, lineWidth: 1))
                    .help(L10n.tr("收起传输队列", "Collapse Transfer Queue"))
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background(theme.panel)
            .overlay(
                Rectangle()
                    .frame(height: 1)
                    .foregroundColor(theme.line),
                alignment: .top
            )
            .overlay(
                Rectangle()
                    .frame(height: 1)
                    .foregroundColor(theme.line),
                alignment: .bottom
            )

            // 队列非空时的准备中微提示条
            if let prep = connectionService.transferPreparation, !filteredTasks.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(prep.statusMessage)
                        .font(FerryFont.captionBold)
                        .foregroundColor(theme.accentColor)
                    Spacer()
                    if prep.scannedFilesCount > 0 {
                        Text(L10n.format("已扫描 %d 个文件", "%d files scanned", prep.scannedFilesCount))
                            .font(FerryFont.monoCaption)
                            .foregroundColor(theme.text2)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(theme.accentColor.opacity(0.08))
                .overlay(
                    Rectangle()
                        .frame(height: 1)
                        .foregroundColor(theme.accentColor.opacity(0.2)),
                    alignment: .bottom
                )
            }

            // 任务列表
            if filteredTasks.isEmpty {
                if let prep = connectionService.transferPreparation {
                    VStack(spacing: 10) {
                        Spacer()
                        ProgressView()
                            .controlSize(.regular)
                        Text(prep.statusMessage)
                            .font(FerryFont.subheadlineBold)
                            .foregroundColor(theme.text)
                        if prep.scannedFilesCount > 0 {
                            Text(L10n.format("已发现 %d 个文件，正在展开目录结构与比对冲突...", "Found %d files, expanding directory tree and checking conflicts...", prep.scannedFilesCount))
                                .font(FerryFont.caption)
                                .foregroundColor(theme.text2)
                        } else {
                            Text(L10n.tr("正在连接服务器并展开目标文件列表，请稍候...", "Connecting to server and enumerating target files, please wait..."))
                                .font(FerryFont.caption)
                                .foregroundColor(theme.text2)
                        }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(theme.bg)
                } else {
                    VStack(spacing: 6) {
                        Spacer()
                        Image(systemName: "tray")
                            .font(.system(size: 20))
                            .foregroundColor(theme.text3)
                        Text(L10n.tr("暂无传输任务", "No transfer tasks"))
                            .font(FerryFont.caption)
                            .foregroundColor(theme.text3)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(theme.bg)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredTasks) { task in
                            taskRow(task)
                            Divider()
                                .background(theme.line)
                        }
                    }
                }
                .background(theme.bg)
            }
        }
        .frame(height: 170)
    }

    // MARK: - 单行任务渲染（行高 44px，UI-REFERENCE.md §2.3）
    private func taskRow(_ task: TransferTaskState) -> some View {
        HStack(spacing: 12) {
            // 方向标签
            Text(task.direction == .upload ? L10n.tr("上传", "Upload") : L10n.tr("下载", "Download"))
                .font(FerryFont.micro)
                .foregroundColor(task.direction == .upload ? theme.accentColor : Color(hex: "#1F5FB4"))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: FerryRadius.r3)
                        .fill(task.direction == .upload ? theme.accentTint : Color(hex: "#1F5FB4").opacity(0.15))
                )

            // 文件名与路径映射
            VStack(alignment: .leading, spacing: 2) {
                Text(task.fileName)
                    .font(FerryFont.subheadlineBold)
                    .foregroundColor(theme.text)
                    .lineLimit(1)

                Text(pathMappingText(for: task))
                    .font(FerryFont.caption)
                    .foregroundColor(theme.text3)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 进度条与状态文案（U11）
            VStack(alignment: .trailing, spacing: 3) {
                // 进度条
                progressBar(for: task)
                    .frame(width: 140, height: 4)

                // 状态行文案
                statusText(for: task)
            }
            .frame(width: 180, alignment: .trailing)

            // 动作按钮
            HStack(spacing: 6) {
                actionButtons(for: task)
            }
            .frame(width: 50, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    private func pathMappingText(for task: TransferTaskState) -> String {
        switch task.direction {
        case .upload:
            return "\(task.record.localURL.path) → \(task.record.remotePath.displayString())"
        case .download:
            return "\(task.record.remotePath.displayString()) → \(task.record.localURL.path)"
        }
    }

    private func progressBar(for task: TransferTaskState) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(theme.barTrack)

                RoundedRectangle(cornerRadius: 2)
                    .fill(progressBarColor(for: task))
                    .frame(width: geo.size.width * task.progressFraction)
            }
        }
    }

    private func progressBarColor(for task: TransferTaskState) -> Color {
        switch task.status {
        case .completed:
            return theme.successGreen
        case .failed:
            return theme.errorRed
        case .paused:
            return theme.text3
        case .running, .pending:
            return theme.accentColor
        case .cancelled:
            return theme.text3
        }
    }

    @ViewBuilder
    private func statusText(for task: TransferTaskState) -> some View {
        switch task.status {
        case .running:
            let pct = Int(task.progressFraction * 100)
            let eta = task.formattedETA.map { " · \($0)" } ?? ""
            Text("\(pct)% · \(task.formattedSpeed)\(eta)")
                .font(FerryFont.monoCaption)
                .foregroundColor(theme.text2)
                .lineLimit(1)

        case .failed(let message, _):
            HStack(spacing: 4) {
                Text(L10n.format("失败 · %@", "Failed · %@", message))
                    .font(FerryFont.caption)
                    .foregroundColor(theme.errorRed)
                    .lineLimit(1)

                Button(L10n.tr("重试", "Retry")) {
                    connectionService.retryQueueTask(id: task.id)
                }
                .font(FerryFont.captionBold)
                .foregroundColor(theme.accentColor)
                .buttonStyle(.plain)
            }

        case .pending:
            Text(L10n.tr("等待中", "Pending"))
                .font(FerryFont.caption)
                .foregroundColor(theme.text3)

        case .paused:
            HStack(spacing: 4) {
                Text(L10n.tr("已暂停", "Paused"))
                    .font(FerryFont.caption)
                    .foregroundColor(theme.text3)

                Button(L10n.tr("继续", "Resume")) {
                    connectionService.resumeQueueTask(id: task.id)
                }
                .font(FerryFont.captionBold)
                .foregroundColor(theme.accentColor)
                .buttonStyle(.plain)
            }

        case .completed:
            Text(L10n.tr("已完成", "Completed"))
                .font(FerryFont.caption)
                .foregroundColor(theme.successGreen)

        case .cancelled:
            Text(L10n.tr("已取消", "Cancelled"))
                .font(FerryFont.caption)
                .foregroundColor(theme.text3)
        }
    }

    @ViewBuilder
    private func actionButtons(for task: TransferTaskState) -> some View {
        switch task.status {
        case .running, .pending:
            Button(action: {
                connectionService.pauseQueueTask(id: task.id)
            }) {
                Image(systemName: "pause.circle")
                    .font(.system(size: 14))
                    .foregroundColor(theme.text2)
            }
            .buttonStyle(.plain)
            .help(L10n.tr("暂停任务", "Pause Task"))

            Button(action: {
                connectionService.cancelQueueTask(id: task.id)
            }) {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 14))
                    .foregroundColor(theme.text3)
            }
            .buttonStyle(.plain)
            .help(L10n.tr("取消任务并删除临时文件", "Cancel task and delete temp file"))

        case .paused:
            Button(action: {
                connectionService.resumeQueueTask(id: task.id)
            }) {
                Image(systemName: "play.circle")
                    .font(.system(size: 14))
                    .foregroundColor(theme.accentColor)
            }
            .buttonStyle(.plain)
            .help(L10n.tr("恢复断点续传", "Resume Transfer"))

            Button(action: {
                connectionService.cancelQueueTask(id: task.id)
            }) {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 14))
                    .foregroundColor(theme.text3)
            }
            .buttonStyle(.plain)
            .help(L10n.tr("取消任务", "Cancel Task"))

        case .failed:
            Button(action: {
                connectionService.retryQueueTask(id: task.id)
            }) {
                Image(systemName: "arrow.clockwise.circle")
                    .font(.system(size: 14))
                    .foregroundColor(theme.accentColor)
            }
            .buttonStyle(.plain)
            .help(L10n.tr("重试任务", "Retry Task"))

            Button(action: {
                connectionService.cancelQueueTask(id: task.id)
            }) {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 14))
                    .foregroundColor(theme.text3)
            }
            .buttonStyle(.plain)
            .help(L10n.tr("移除任务", "Remove Task"))

        case .completed, .cancelled:
            Button(action: {
                connectionService.cancelQueueTask(id: task.id)
            }) {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 14))
                    .foregroundColor(theme.text3)
            }
            .buttonStyle(.plain)
            .help(L10n.tr("移除记录", "Remove Record"))
        }
    }
}
