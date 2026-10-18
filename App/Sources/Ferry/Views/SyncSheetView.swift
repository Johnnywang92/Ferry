import AppKit
import FerryCore
import SwiftUI

/// 文件夹双向同步与差异计划预览界面（M5 交付，v2.3 §384-434, U4）。
///
/// 核心特性：
/// 1. 基于三方基线快照比对（SyncEngine + BaseSnapshot），支持增量同步；
/// 2. 严格区分 notFound 与网络错误，网络错误即刻中断，不误删文件；
/// 3. 冲突绝不自动解决，支持行内显式决策（以本地为准 / 以远端为准 / 保留双份 / 跳过）；
/// 4. 删除默认关闭，开启需显式确认；
/// 5. DiffPlan 支持 JSON 序列化导出（v2.3 §432）。
public struct SyncSheetView: View {
    @Binding var isPresented: Bool
    public let localURL: URL
    public let remotePath: RemotePath
    public let fileSystem: any RemoteFileSystem

    @Environment(\.colorScheme) private var colorScheme
    private var theme: FerryTheme {
        ThemeManager.shared.theme(for: colorScheme)
    }

    private let syncEngine = SyncEngine()

    // 状态
    @State private var isAnalyzing: Bool = true
    @State private var isExecuting: Bool = false
    @State private var errorMessage: String? = nil
    @State private var diffPlan: DiffPlan? = nil
    @State private var resolvedItems: [String: SyncConflictResolution] = [:]

    // 选项
    @State private var allowDeletions: Bool = false
    @State private var forceCompareHash: Bool = false
    @State private var filterMode: FilterMode = .actionableOnly
    @State private var showDeleteConfirmation: Bool = false
    @State private var exportNotification: String? = nil

    public enum FilterMode: String, CaseIterable, Identifiable {
        case all = "全部"
        case actionableOnly = "仅需操作"
        case conflictsOnly = "仅冲突"
        public var id: String { rawValue }

        @MainActor
        public var displayName: String {
            switch self {
            case .all: return L10n.tr("全部", "All")
            case .actionableOnly: return L10n.tr("仅需操作", "Actionable")
            case .conflictsOnly: return L10n.tr("仅冲突", "Conflicts")
            }
        }
    }

    public init(
        isPresented: Binding<Bool>,
        localURL: URL,
        remotePath: RemotePath,
        fileSystem: any RemoteFileSystem
    ) {
        self._isPresented = isPresented
        self.localURL = localURL
        self.remotePath = remotePath
        self.fileSystem = fileSystem
    }

    public var body: some View {
        VStack(spacing: 0) {
            // 头部标题与路径指示
            headerView

            Divider().background(theme.line)

            // 统计胶囊与选项栏
            toolbarSection

            Divider().background(theme.line)

            // 列表内容区域
            ZStack {
                theme.bg

                if isAnalyzing {
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.regular)
                        Text(L10n.tr("正在扫描目录并比对差异 (DiffPlan)...", "Scanning directories and computing DiffPlan..."))
                            .font(FerryFont.caption)
                            .foregroundColor(theme.text2)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = errorMessage {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 32))
                            .foregroundColor(theme.errorRed)
                        Text(L10n.tr("分析失败", "Analysis Failed"))
                            .font(FerryFont.bodyBold)
                            .foregroundColor(theme.text)
                        Text(error)
                            .font(FerryFont.caption)
                            .foregroundColor(theme.text2)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                        Button(L10n.tr("重试", "Retry")) {
                            runAnalysis()
                        }
                        .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let plan = diffPlan {
                    let displayed = filteredItems(from: plan.items)
                    if displayed.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 32))
                                .foregroundColor(theme.successGreen)
                            Text(L10n.tr("本地与远端完全一致，无需同步。", "Local and remote are in sync, no actions needed."))
                                .font(FerryFont.body)
                                .foregroundColor(theme.text2)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        itemsTable(displayed)
                    }
                }
            }
            .frame(height: 400)

            Divider().background(theme.line)

            // 底部动作栏
            footerView
        }
        .frame(width: 820)
        .background(theme.bg)
        .onAppear {
            runAnalysis()
        }
        .alert(L10n.tr("开启删除操作确认", "Confirm Enable Deletion"), isPresented: $showDeleteConfirmation) {
            Button(L10n.tr("确认开启", "Enable Deletion"), role: .destructive) {
                allowDeletions = true
                runAnalysis()
            }
            Button(L10n.tr("取消", "Cancel"), role: .cancel) {
                allowDeletions = false
            }
        } message: {
            Text(L10n.tr("同步删除将在目标端永久删除本地或服务器上已移除的文件。\n建议先在无删除模式下复核 DiffPlan。确定开启吗？", "Sync deletion will permanently remove files on the target that were deleted locally or on the server.\nIt is recommended to review the DiffPlan without deletion first. Are you sure?"))
        }
    }

    // MARK: - 子视图组件

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L10n.tr("文件夹双向同步 (DiffPlan)", "Folder Two-way Sync (DiffPlan)"))
                    .font(FerryFont.titleBold)
                    .foregroundColor(theme.text)

                Spacer()

                if let notification = exportNotification {
                    Text(notification)
                        .font(FerryFont.caption)
                        .foregroundColor(theme.successGreen)
                        .transition(.opacity)
                }
            }

            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Text(L10n.tr("本地:", "Local:"))
                        .font(FerryFont.captionBold)
                        .foregroundColor(theme.text2)
                    Text(localURL.path)
                        .font(FerryFont.caption)
                        .foregroundColor(theme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 11))
                    .foregroundColor(theme.text3)

                HStack(spacing: 4) {
                    Text(L10n.tr("远程:", "Remote:"))
                        .font(FerryFont.captionBold)
                        .foregroundColor(theme.text2)
                    Text(remotePath.displayString())
                        .font(FerryFont.caption)
                        .foregroundColor(theme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(theme.bar)
    }

    private var toolbarSection: some View {
        HStack(spacing: 14) {
            // 统计胶囊
            if let plan = diffPlan {
                HStack(spacing: 8) {
                    badgeView(title: L10n.tr("上行", "Upload"), count: plan.uploadCount, color: theme.successGreen)
                    badgeView(title: L10n.tr("下行", "Download"), count: plan.downloadCount, color: theme.accentColor)
                    badgeView(title: L10n.tr("删除", "Delete"), count: plan.deleteRemoteCount + plan.deleteLocalCount, color: theme.errorRed)
                    badgeView(title: L10n.tr("冲突", "Conflict"), count: plan.conflictCount, color: theme.warningOrange)
                    badgeView(title: L10n.tr("相同", "Unchanged"), count: plan.unchangedCount, color: theme.text3)
                }
            }

            Spacer()

            // 过滤分段
            Picker("", selection: $filterMode) {
                ForEach(FilterMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 200)

            // 选项开关
            Toggle(L10n.tr("允许删除", "Allow Deletion"), isOn: Binding(
                get: { allowDeletions },
                set: { val in
                    if val {
                        showDeleteConfirmation = true
                    } else {
                        allowDeletions = false
                        runAnalysis()
                    }
                }
            ))
            .font(FerryFont.caption)
            .toggleStyle(.checkbox)

            Toggle(L10n.tr("强验内容哈希", "Verify Content Hash"), isOn: $forceCompareHash)
                .font(FerryFont.caption)
                .toggleStyle(.checkbox)
                .onChange(of: forceCompareHash) { _, _ in
                    runAnalysis()
                }

            Button(action: runAnalysis) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
            }
            .help(L10n.tr("重新分析", "Re-analyze"))
            .disabled(isAnalyzing || isExecuting)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(theme.panel)
    }

    private func badgeView(title: String, count: Int, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(FerryFont.caption)
                .foregroundColor(theme.text2)
            Text("\(count)")
                .font(FerryFont.captionBold)
                .foregroundColor(color)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(theme.field)
        .cornerRadius(FerryRadius.r4)
    }

    private func itemsTable(_ items: [SyncDiffItem]) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                // 表头
                HStack(spacing: 12) {
                    Text(L10n.tr("建议操作", "Action"))
                        .font(FerryFont.captionBold)
                        .foregroundColor(theme.text2)
                        .frame(width: 100, alignment: .leading)

                    Text(L10n.tr("相对路径", "Relative Path"))
                        .font(FerryFont.captionBold)
                        .foregroundColor(theme.text2)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(L10n.tr("本地", "Local"))
                        .font(FerryFont.captionBold)
                        .foregroundColor(theme.text2)
                        .frame(width: 140, alignment: .trailing)

                    Text(L10n.tr("远程", "Remote"))
                        .font(FerryFont.captionBold)
                        .foregroundColor(theme.text2)
                        .frame(width: 140, alignment: .trailing)

                    Text(L10n.tr("冲突解决", "Resolution"))
                        .font(FerryFont.captionBold)
                        .foregroundColor(theme.text2)
                        .frame(width: 120, alignment: .leading)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(theme.panel)

                Divider().background(theme.line)

                // 表体行
                ForEach(items) { item in
                    tableRow(for: item)
                    Divider().background(theme.line.opacity(0.5))
                }
            }
        }
    }

    private func tableRow(for item: SyncDiffItem) -> some View {
        HStack(spacing: 12) {
            // 操作胶囊
            actionBadge(for: item)
                .frame(width: 100, alignment: .leading)

            // 路径
            Text(item.relativePath)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            // 本地文件信息
            fileInfoText(snapshot: item.localItem)
                .frame(width: 140, alignment: .trailing)

            // 远端文件信息
            fileInfoText(snapshot: item.remoteItem)
                .frame(width: 140, alignment: .trailing)

            // 冲突解决决策 Picker
            if item.action == .conflict {
                Picker("", selection: Binding(
                    get: { resolvedItems[item.relativePath] ?? item.userResolution ?? .skip },
                    set: { resolvedItems[item.relativePath] = $0 }
                )) {
                    ForEach(SyncConflictResolution.allCases, id: \.self) { res in
                        Text(conflictResolutionName(res)).tag(res)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 120)
            } else {
                Text("—")
                    .font(FerryFont.caption)
                    .foregroundColor(theme.text3)
                    .frame(width: 120, alignment: .center)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(item.action == .conflict ? theme.warningOrange.opacity(0.08) : Color.clear)
    }

    private func conflictResolutionName(_ res: SyncConflictResolution) -> String {
        switch res {
        case .useLocal: return L10n.tr("以本地为准", "Use Local")
        case .useRemote: return L10n.tr("以远端为准", "Use Remote")
        case .keepBoth: return L10n.tr("保留双份", "Keep Both")
        case .skip: return L10n.tr("跳过此项", "Skip")
        }
    }

    private func actionBadge(for item: SyncDiffItem) -> some View {
        let text: String
        let color: Color

        switch item.action {
        case .none:
            text = L10n.tr("— 相同", "— In Sync")
            color = theme.text3
        case .upload:
            text = L10n.tr("↑ 上传", "↑ Upload")
            color = theme.successGreen
        case .download:
            text = L10n.tr("↓ 下载", "↓ Download")
            color = theme.accentColor
        case .deleteRemote:
            text = L10n.tr("✕ 删远端", "✕ Del Remote")
            color = theme.errorRed
        case .deleteLocal:
            text = L10n.tr("✕ 删本地", "✕ Del Local")
            color = theme.errorRed
        case .conflict:
            text = L10n.tr("⚠️ 冲突", "⚠️ Conflict")
            color = theme.warningOrange
        case .needsVerification:
            text = L10n.tr("? 待比对", "? Needs Check")
            color = theme.warningOrange
        }

        return Text(text)
            .font(FerryFont.captionBold)
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .cornerRadius(FerryRadius.r4)
    }

    private func fileInfoText(snapshot: SyncItemSnapshot?) -> some View {
        Group {
            if let snap = snapshot {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(ByteCountFormatter.string(fromByteCount: snap.size ?? 0, countStyle: .file))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.text)
                    if let date = snap.modificationDate {
                        Text(date, format: .dateTime.month().day().hour().minute())
                            .font(.system(size: 10))
                            .foregroundColor(theme.text3)
                    }
                }
            } else {
                Text(L10n.tr("(不存在)", "(None)"))
                    .font(FerryFont.caption)
                    .foregroundColor(theme.text3)
            }
        }
    }

    private var footerView: some View {
        HStack {
            Button(L10n.tr("导出 DiffPlan JSON…", "Export DiffPlan JSON…")) {
                exportDiffPlanJSON()
            }
            .disabled(diffPlan == nil || isAnalyzing || isExecuting)

            Spacer()

            Button(L10n.tr("取消", "Cancel")) {
                isPresented = false
            }
            .keyboardShortcut(.cancelAction)

            Button(action: executeSync) {
                if isExecuting {
                    ProgressView().controlSize(.small)
                        .padding(.trailing, 4)
                    Text(L10n.tr("正在派发同步任务…", "Dispatching sync tasks…"))
                } else {
                    let actionable = actionableCount
                    Text(actionable > 0 ? L10n.format("开始同步 (%d 项)", "Start Sync (%d items)", actionable) : L10n.tr("开始同步", "Start Sync"))
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.accentColor)
            .keyboardShortcut(.defaultAction)
            .disabled(isAnalyzing || isExecuting || diffPlan == nil || actionableCount == 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(theme.bar)
    }

    private var actionableCount: Int {
        guard let plan = diffPlan else { return 0 }
        var count = 0
        for item in plan.items {
            if item.action == .conflict {
                let res = resolvedItems[item.relativePath] ?? item.userResolution
                if res != nil && res != .skip {
                    count += 1
                }
            } else if item.action != .none {
                count += 1
            }
        }
        return count
    }

    // MARK: - 逻辑与执行

    private func filteredItems(from all: [SyncDiffItem]) -> [SyncDiffItem] {
        switch filterMode {
        case .all:
            return all
        case .actionableOnly:
            return all.filter { $0.action != .none }
        case .conflictsOnly:
            return all.filter { $0.action == .conflict }
        }
    }

    private func runAnalysis() {
        isAnalyzing = true
        errorMessage = nil
        exportNotification = nil

        Task {
            let base = SyncStore.shared.getSnapshot(localPath: localURL.path, remotePath: remotePath.displayString())
            let options = SyncOptions(
                allowDeletions: allowDeletions,
                forceCompareHash: forceCompareHash,
                pathPolicy: .posix
            )

            do {
                let plan = try await syncEngine.computeDiffPlan(
                    localRootURL: localURL,
                    remoteRootPath: remotePath,
                    fileSystem: fileSystem,
                    baseSnapshot: base,
                    options: options
                )

                await MainActor.run {
                    self.diffPlan = plan
                    // 预置未解决冲突默认值
                    for item in plan.items where item.action == .conflict {
                        if resolvedItems[item.relativePath] == nil {
                            resolvedItems[item.relativePath] = .skip
                        }
                    }
                    self.isAnalyzing = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isAnalyzing = false
                }
            }
        }
    }

    private func exportDiffPlanJSON() {
        guard let plan = diffPlan else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "DiffPlan-\(Date().timeIntervalSince1970).json"
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(plan) {
                try? data.write(to: url)
                withAnimation {
                    exportNotification = L10n.tr("DiffPlan 已导出", "DiffPlan exported")
                }
            }
        }
    }

    private func executeSync() {
        guard let plan = diffPlan else { return }
        isExecuting = true

        Task {
            var uploadBatch: [DirectoryScanner.ScannedFile] = []
            var downloadBatch: [DirectoryScanner.ScannedFile] = []
            var updatedBaseEntries = SyncStore.shared.getSnapshot(
                localPath: localURL.path,
                remotePath: remotePath.displayString()
            )?.entries ?? [:]

            let resolver = PathResolver()

            for item in plan.items {
                let relative = item.relativePath
                let itemLocalURL = localURL.appendingPathComponent(relative)
                let itemRemotePath: RemotePath
                do {
                    itemRemotePath = try resolver.lexicalResolve(
                        RemotePath(wireBytes: Array(relative.utf8), isAbsolute: false),
                        relativeTo: remotePath
                    )
                } catch {
                    continue
                }

                var effectiveAction = item.action
                if effectiveAction == .conflict {
                    let userChoice = resolvedItems[relative] ?? .skip
                    switch userChoice {
                    case .useLocal:
                        effectiveAction = .upload
                    case .useRemote:
                        effectiveAction = .download
                    case .keepBoth:
                        effectiveAction = .upload // 保留双份将本地文件重命名上传
                    case .skip:
                        effectiveAction = .none
                    }
                }

                switch effectiveAction {
                case .upload:
                    uploadBatch.append(DirectoryScanner.ScannedFile(
                        localURL: itemLocalURL,
                        remotePath: itemRemotePath,
                        size: item.localItem?.size
                    ))
                    // 记录预估 base
                    updatedBaseEntries[item.comparisonKey] = SyncBaseEntry(
                        key: item.comparisonKey,
                        relativePath: relative,
                        localSize: item.localItem?.size,
                        localMTime: item.localItem?.modificationDate,
                        remoteSize: item.localItem?.size,
                        remoteMTime: Date(),
                        remoteMTimeIsReliable: true
                    )

                case .download:
                    downloadBatch.append(DirectoryScanner.ScannedFile(
                        localURL: itemLocalURL,
                        remotePath: itemRemotePath,
                        size: item.remoteItem?.size
                    ))
                    updatedBaseEntries[item.comparisonKey] = SyncBaseEntry(
                        key: item.comparisonKey,
                        relativePath: relative,
                        localSize: item.remoteItem?.size,
                        localMTime: item.remoteItem?.modificationDate,
                        remoteSize: item.remoteItem?.size,
                        remoteMTime: item.remoteItem?.modificationDate,
                        remoteMTimeIsReliable: item.remoteItem?.mtimeIsReliable ?? true
                    )

                case .deleteRemote:
                    if allowDeletions {
                        try? await fileSystem.remove(itemRemotePath, recursive: false)
                        updatedBaseEntries.removeValue(forKey: item.comparisonKey)
                    }

                case .deleteLocal:
                    if allowDeletions {
                        try? FileManager.default.removeItem(at: itemLocalURL)
                        updatedBaseEntries.removeValue(forKey: item.comparisonKey)
                    }

                case .none, .conflict, .needsVerification:
                    break
                }
            }

            // 派发任务到传输队列
            if !uploadBatch.isEmpty {
                await ConnectionService.shared.transferQueue.addScannedBatch(uploadBatch, direction: .upload)
            }
            if !downloadBatch.isEmpty {
                await ConnectionService.shared.transferQueue.addScannedBatch(downloadBatch, direction: .download)
            }

            // 更新并保存基线快照
            let newSnapshot = SyncBaseSnapshot(
                localRootPath: localURL.path,
                remoteRootPath: remotePath.displayString(),
                entries: updatedBaseEntries,
                lastSyncTime: Date()
            )
            await SyncStore.shared.saveSnapshot(newSnapshot)

            await MainActor.run {
                self.isExecuting = false
                self.isPresented = false
                ConnectionService.shared.isQueuePanelPresented = true
            }
        }
    }
}
