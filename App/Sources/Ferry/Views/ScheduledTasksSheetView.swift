import FerryCore
import SwiftUI

/// 定时计划与自动同步管理弹窗。
public struct ScheduledTasksSheetView: View {
    @Binding var isPresented: Bool

    @Environment(\.colorScheme) private var colorScheme
    private var themeManager: ThemeManager { ThemeManager.shared }
    private var theme: FerryTheme { themeManager.theme(for: colorScheme) }
    private var taskStore: ScheduledTaskStore { ScheduledTaskStore.shared }
    private var taskService: ScheduledTaskService { ScheduledTaskService.shared }
    private var siteStore: SiteStore { SiteStore.shared }

    @State private var showingEditDialog: Bool = false
    @State private var editingTask: ScheduledTask? = nil

    public init(isPresented: Binding<Bool>) {
        self._isPresented = isPresented
    }

    public var body: some View {
        VStack(spacing: 0) {
            // 头部
            HStack(spacing: 12) {
                Image(systemName: "clock.arrow.2.circlepath")
                    .font(.system(size: 26))
                    .foregroundColor(theme.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.tr("定时同步与备份计划 (Scheduled Transfers)", "Scheduled Transfers & Backups"))
                        .font(FerryFont.bodyBold)
                        .foregroundColor(theme.text)

                    Text(L10n.tr("配置定时自动执行的上传备份、镜像同步与服务器间直传任务。",
                                 "Automate recurring backup, directory sync, and server-to-server relay transfers."))
                        .font(FerryFont.caption)
                        .foregroundColor(theme.text2)
                }

                Spacer()

                Button(action: {
                    editingTask = ScheduledTask(
                        name: L10n.tr("新建定时备份", "New Backup Task"),
                        sourcePath: NSHomeDirectory(),
                        destinationPath: "/backup"
                    )
                    showingEditDialog = true
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                        Text(L10n.tr("新建计划", "New Task"))
                    }
                    .font(FerryFont.captionBold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(theme.accentColor)
                    .cornerRadius(FerryRadius.r7)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider().background(theme.line)

            // 任务列表
            if taskStore.tasks.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 44))
                        .foregroundColor(theme.text3)
                    Text(L10n.tr("暂无定时同步计划", "No Scheduled Tasks Yet"))
                        .font(FerryFont.bodyBold)
                        .foregroundColor(theme.text2)
                    Text(L10n.tr("点击右上角“新建计划”，可设置每天凌晨定时将本地目录备份至远程服务器，或实现多服务器间自动镜像中继。",
                                 "Click 'New Task' to schedule automatic daily backups or multi-server directory relay."))
                        .font(FerryFont.caption)
                        .foregroundColor(theme.text3)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 400)
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: 320)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(taskStore.tasks) { task in
                            taskCard(task)
                        }
                    }
                    .padding(20)
                }
            }

            Divider().background(theme.line)

            // 底部关闭
            HStack {
                Spacer()
                Button(L10n.tr("完成", "Done")) {
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(theme.accentColor)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(theme.bar)
        }
        .frame(width: 640, height: 480)
        .background(theme.bg)
        .sheet(isPresented: $showingEditDialog) {
            if let task = editingTask {
                ScheduledTaskEditorDialog(task: task, isPresented: $showingEditDialog)
            }
        }
    }

    private func taskCard(_ task: ScheduledTask) -> some View {
        let isRunning = taskService.runningTaskIDs.contains(task.id)

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(task.name)
                    .font(FerryFont.subheadlineBold)
                    .foregroundColor(theme.text)

                Spacer()

                if isRunning {
                    HStack(spacing: 4) {
                        ProgressView().scaleEffect(0.6)
                        Text(L10n.tr("正在同步中…", "Syncing…"))
                            .font(FerryFont.caption)
                            .foregroundColor(theme.accentColor)
                    }
                } else {
                    Toggle("", isOn: Binding(
                        get: { task.isEnabled },
                        set: { _ in Task { await taskStore.toggleEnabled(id: task.id) } }
                    ))
                    .toggleStyle(.switch)
                    .scaleEffect(0.8)
                }
            }

            // 路径指示
            HStack(spacing: 6) {
                Text(formatEndpoint(bookmarkID: task.sourceBookmarkID, path: task.sourcePath))
                    .font(FerryFont.monoSmall)
                    .foregroundColor(theme.text2)
                Image(systemName: "arrow.right")
                    .font(.system(size: 10))
                    .foregroundColor(theme.text3)
                Text(formatEndpoint(bookmarkID: task.destinationBookmarkID, path: task.destinationPath))
                    .font(FerryFont.monoSmall)
                    .foregroundColor(theme.text2)
            }

            HStack {
                // 周期标签
                Text(task.frequency.displayName)
                    .font(FerryFont.captionMedium)
                    .foregroundColor(theme.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(theme.accentColor.opacity(0.12))
                    .cornerRadius(FerryRadius.r4)

                if let next = task.nextRunTime, task.isEnabled {
                    Text(L10n.format("下次运行：%@ (%@)", formatTime(next), relativeTime(next)))
                        .font(FerryFont.caption)
                        .foregroundColor(theme.text3)
                }

                Spacer()

                // 操作按钮
                HStack(spacing: 8) {
                    Button(action: {
                        Task { await taskService.runTaskNow(task) }
                    }) {
                        Text(L10n.tr("立即运行", "Run Now"))
                            .font(FerryFont.caption)
                            .foregroundColor(theme.accentColor)
                    }
                    .buttonStyle(.plain)
                    .disabled(isRunning)

                    Button(action: {
                        editingTask = task
                        showingEditDialog = true
                    }) {
                        Text(L10n.tr("编辑", "Edit"))
                            .font(FerryFont.caption)
                            .foregroundColor(theme.text2)
                    }
                    .buttonStyle(.plain)

                    Button(action: {
                        Task { await taskStore.delete(id: task.id) }
                    }) {
                        Text(L10n.tr("删除", "Delete"))
                            .font(FerryFont.caption)
                            .foregroundColor(theme.errorRed)
                    }
                    .buttonStyle(.plain)
                }
            }

            if let lastStatus = task.lastRunStatus {
                Text(L10n.format("上次执行：%@", "Last Run: %@", lastStatus))
                    .font(FerryFont.caption)
                    .foregroundColor(theme.text3)
            }
        }
        .padding(14)
        .background(theme.panel)
        .cornerRadius(FerryRadius.r8)
        .overlay(
            RoundedRectangle(cornerRadius: FerryRadius.r8)
                .stroke(theme.line, lineWidth: 1)
        )
    }

    private func formatEndpoint(bookmarkID: UUID?, path: String) -> String {
        if let id = bookmarkID, let bm = siteStore.bookmarks.first(where: { $0.id == id }) {
            return "[\(bm.name.isEmpty ? bm.host : bm.name)] \(path)"
        }
        return "[\(L10n.tr("本地", "Local"))] \(path)"
    }

    private func formatTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: date)
    }

    private func relativeTime(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}

/// 定时计划任务配置与编辑对话框。
struct ScheduledTaskEditorDialog: View {
    @State var task: ScheduledTask
    @Binding var isPresented: Bool

    @Environment(\.colorScheme) private var colorScheme
    private var themeManager: ThemeManager { ThemeManager.shared }
    private var theme: FerryTheme { themeManager.theme(for: colorScheme) }
    private var siteStore: SiteStore { SiteStore.shared }

    @State private var freqType: Int = 0 // 0: 每天, 1: 每小时, 2: 间隔分钟
    @State private var dailyHour: Int = 3
    @State private var dailyMinute: Int = 0
    @State private var intervalMinutes: Int = 30

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.tr("配置定时同步计划", "Configure Scheduled Task"))
                    .font(FerryFont.bodyBold)
                    .foregroundColor(theme.text)
                Spacer()
            }
            .padding(20)

            Divider().background(theme.line)

            Form {
                TextField(L10n.tr("计划名称", "Task Name"), text: $task.name)

                Section(header: Text(L10n.tr("源端目录", "Source Endpoint"))) {
                    Picker(L10n.tr("来源主机", "Source Host"), selection: $task.sourceBookmarkID) {
                        Text(L10n.tr("本机目录 (Local)", "Local Machine")).tag(UUID?.none)
                        ForEach(siteStore.bookmarks) { bm in
                            Text("\(bm.name.isEmpty ? bm.host : bm.name) (\(bm.host))").tag(UUID?.some(bm.id))
                        }
                    }
                    TextField(L10n.tr("源目录路径", "Source Directory Path"), text: $task.sourcePath)
                }

                Section(header: Text(L10n.tr("目标目录", "Destination Endpoint"))) {
                    Picker(L10n.tr("目标主机", "Destination Host"), selection: $task.destinationBookmarkID) {
                        Text(L10n.tr("本机目录 (Local)", "Local Machine")).tag(UUID?.none)
                        ForEach(siteStore.bookmarks) { bm in
                            Text("\(bm.name.isEmpty ? bm.host : bm.name) (\(bm.host))").tag(UUID?.some(bm.id))
                        }
                    }
                    TextField(L10n.tr("目标目录路径", "Destination Directory Path"), text: $task.destinationPath)
                }

                Section(header: Text(L10n.tr("触发频次与周期", "Schedule Frequency"))) {
                    Picker(L10n.tr("执行频率", "Frequency"), selection: $freqType) {
                        Text(L10n.tr("每天定时执行", "Daily")).tag(0)
                        Text(L10n.tr("每隔指定时间", "Interval")).tag(1)
                    }
                    .pickerStyle(.segmented)

                    if freqType == 0 {
                        HStack {
                            Text(L10n.tr("执行时间", "Time"))
                            Picker("", selection: $dailyHour) {
                                ForEach(0..<24) { h in Text(String(format: "%02d 点", h)).tag(h) }
                            }
                            Picker("", selection: $dailyMinute) {
                                ForEach([0, 15, 30, 45], id: \.self) { m in Text(String(format: "%02d 分", m)).tag(m) }
                            }
                        }
                    } else {
                        Picker(L10n.tr("间隔时长", "Interval Duration"), selection: $intervalMinutes) {
                            Text(L10n.tr("每 15 分钟", "Every 15 mins")).tag(15)
                            Text(L10n.tr("每 30 分钟", "Every 30 mins")).tag(30)
                            Text(L10n.tr("每 1 小时", "Every 1 hour")).tag(60)
                            Text(L10n.tr("每 2 小时", "Every 2 hours")).tag(120)
                            Text(L10n.tr("每 6 小时", "Every 6 hours")).tag(360)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .padding(.horizontal, 12)

            Divider().background(theme.line)

            HStack {
                Button(L10n.tr("取消", "Cancel")) {
                    isPresented = false
                }
                .buttonStyle(.plain)
                .font(FerryFont.captionMedium)
                .foregroundColor(theme.text2)

                Spacer()

                Button(L10n.tr("保存计划", "Save Task")) {
                    saveTask()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(theme.accentColor)
            }
            .padding(16)
            .background(theme.bar)
        }
        .frame(width: 520, height: 480)
        .background(theme.bg)
        .onAppear {
            switch task.frequency {
            case .daily(let h, let m):
                freqType = 0
                dailyHour = h
                dailyMinute = m
            case .intervalMinutes(let min):
                freqType = 1
                intervalMinutes = min
            default:
                freqType = 0
            }
        }
    }

    private func saveTask() {
        if freqType == 0 {
            task.frequency = .daily(hour: dailyHour, minute: dailyMinute)
        } else {
            task.frequency = .intervalMinutes(intervalMinutes)
        }
        task.nextRunTime = ScheduledTask.calculateNextRunTime(for: task.frequency, from: Date())

        Task {
            await ScheduledTaskStore.shared.upsert(task)
            isPresented = false
        }
    }
}
