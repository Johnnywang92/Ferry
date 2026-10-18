import AppKit
import FerryCore
import SwiftUI
import UniformTypeIdentifiers

public struct RemotePaneView: View {
    @Binding var selectedIDs: Set<String>
    @Binding var showingNewConnection: Bool
    var searchText: String
    var onDownloadSelected: () -> Void
    var onNewRemoteFolder: () -> Void
    var onRenameRemote: (RemoteDisplayItem) -> Void

    @Environment(\.colorScheme) private var colorScheme
    private var connectionService: ConnectionService { ConnectionService.shared }
    private var themeManager: ThemeManager { ThemeManager.shared }

    @State private var sortField: BrowserSortField = .name
    @State private var sortAscending: Bool = true
    @State private var isEditingPath: Bool = false
    @State private var editedPathText: String = ""
    @FocusState private var isPathFieldFocused: Bool
    @State private var isDropTargeted: Bool = false
    @State private var targetedFolderID: String? = nil
    @State private var itemToDelete: RemoteDisplayItem? = nil


    private var theme: FerryTheme {
        themeManager.theme(for: colorScheme)
    }

    private var displayedItems: [RemoteDisplayItem] {
        let filteredByHidden = connectionService.remoteItems.filter { themeManager.showHiddenFiles || !$0.isHidden }
        let filtered: [RemoteDisplayItem]
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            filtered = filteredByHidden
        } else {
            filtered = filteredByHidden.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
        }
        return filtered.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory
            }
            let cmp: ComparisonResult
            switch sortField {
            case .name:
                cmp = lhs.name.localizedStandardCompare(rhs.name)
            case .modificationDate:
                let lDate = lhs.mtime ?? .distantPast
                let rDate = rhs.mtime ?? .distantPast
                cmp = lDate == rDate ? .orderedSame : (lDate < rDate ? .orderedAscending : .orderedDescending)
            case .size:
                let lSize = lhs.size ?? 0
                let rSize = rhs.size ?? 0
                cmp = lSize == rSize ? .orderedSame : (lSize < rSize ? .orderedAscending : .orderedDescending)
            case .permissions:
                cmp = lhs.permissionsString.compare(rhs.permissionsString)
            }
            if cmp == .orderedSame {
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return sortAscending ? (cmp == .orderedAscending) : (cmp == .orderedDescending)
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // 栏头：远程标签 + 路径栏 + 上一级 + 刷新
            HStack(spacing: 8) {
                // `远程` 标签
                Text(L10n.tr("远程", "Remote"))
                    .font(FerryFont.micro)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(theme.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(FerryRadius.r3)

                // 路径栏（支持点击直接输入远程路径跳转）
                if isEditingPath && isConnected {
                    TextField(L10n.tr("输入远程路径…", "Enter remote path…"), text: $editedPathText)
                        .textFieldStyle(.plain)
                        .font(FerryFont.monoSmall)
                        .foregroundColor(theme.text)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(theme.field)
                        .cornerRadius(FerryRadius.r4)
                        .overlay(
                            RoundedRectangle(cornerRadius: FerryRadius.r4)
                                .stroke(theme.accentColor, lineWidth: 1)
                        )
                        .focused($isPathFieldFocused)
                        .onSubmit {
                            commitPathEdit()
                        }
                        .onExitCommand {
                            cancelPathEdit()
                        }
                } else {
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
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if isConnected {
                            editedPathText = currentRemotePathString
                            isEditingPath = true
                            isPathFieldFocused = true
                        }
                    }
                    .help(isConnected ? L10n.tr("点击直接输入远程路径，或按 ⌘⇧G 前往文件夹", "Click to edit remote path, or press ⌘⇧G") : L10n.tr("连接后可浏览远程路径", "Connect to browse remote path"))
                }

                // 返回上一级
                Button(action: {
                    cancelPathEdit()
                    Task {
                        await connectionService.navigateRemoteUp()
                        selectedIDs.removeAll()
                    }
                }) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.icon)
                        .frame(width: 24, height: 24)
                        .background(theme.panel)
                        .cornerRadius(FerryRadius.r4)
                }
                .buttonStyle(.plain)
                .help(L10n.tr("上一级", "Parent Folder"))
                .disabled(!isConnected || connectionService.currentRemotePath?.description == "/")

                // 刷新
                Button(action: {
                    cancelPathEdit()
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
                .help(L10n.tr("刷新远程目录", "Refresh Remote Directory"))
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

            // 远程操作与路径跳转错误提示条
            if let navError = connectionService.navigationErrorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(theme.warningOrange)
                    Text(navError)
                        .font(FerryFont.caption)
                        .foregroundColor(theme.text)
                        .lineLimit(1)
                    Spacer()
                    Button(action: {
                        connectionService.navigationErrorMessage = nil
                    }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(theme.text3)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.tr("忽略提示", "Dismiss"))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(theme.warningOrange.opacity(0.12))
                .overlay(
                    Rectangle()
                        .frame(height: 1)
                        .foregroundColor(theme.warningOrange.opacity(0.3)),
                    alignment: .bottom
                )
            }

            // 表头：名称 / 修改时间 / 大小 / 权限（支持点击排序）
            HStack(spacing: 0) {
                columnHeader(title: L10n.tr("名称", "Name"), field: .name, alignment: .leading)
                    .padding(.leading, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)

                columnHeader(title: L10n.tr("修改时间", "Date Modified"), field: .modificationDate, alignment: .leading)
                    .frame(width: 120, alignment: .leading)

                columnHeader(title: L10n.tr("大小", "Size"), field: .size, alignment: .trailing)
                    .frame(width: 75, alignment: .trailing)

                columnHeader(title: L10n.tr("权限", "Permissions"), field: .permissions, alignment: .center)
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
                        ForEach(displayedItems) { item in
                            remoteRow(item)
                        }
                    }
                }
                .background(theme.bg)
                .onDrop(
                    of: [.fileURL, .url, FerryUTI.remoteItemType, FerryUTI.localItemType, UTType(FerryUTI.promisedFileIdentifier) ?? .data],
                    isTargeted: $isDropTargeted
                ) { providers in
                    handleDrop(providers: providers, targetDirectory: nil)
                }
                .overlay(
                    isDropTargeted ?
                        Rectangle()
                            .stroke(theme.accentColor, lineWidth: 2)
                        : nil
                )
                .contextMenu {
                    Button(L10n.tr("新建远程文件夹…", "New Remote Folder…")) {
                        onNewRemoteFolder()
                    }
                    Button(themeManager.showHiddenFiles ? L10n.tr("隐藏以 . 开头的隐藏文件", "Hide Hidden Files") : L10n.tr("显示隐藏文件", "Show Hidden Files")) {
                        themeManager.toggleHiddenFiles()
                    }
                    Menu(L10n.format("文件名字符集 (%@)", "Encoding (%@)", connectionService.currentCharset.displayName)) {
                        ForEach(CharsetConverter.Charset.allCases) { cs in
                            Button(cs.displayName) {
                                connectionService.setCharset(cs)
                            }
                        }
                    }
                    Button(L10n.tr("刷新", "Refresh")) {
                        Task { await connectionService.refreshRemote() }
                    }
                }
            }
        }
        .alert(
            itemToDelete?.isDirectory == true ? L10n.tr("永久删除远程文件夹", "Delete Remote Folder Permanently") : L10n.tr("永久删除远程文件", "Delete Remote File Permanently"),
            isPresented: Binding(
                get: { itemToDelete != nil },
                set: { if !$0 { itemToDelete = nil } }
            ),
            presenting: itemToDelete
        ) { item in
            Button(L10n.tr("取消", "Cancel"), role: .cancel) {
                itemToDelete = nil
            }
            Button(L10n.tr("永久删除", "Delete Permanently"), role: .destructive) {
                Task {
                    let result = await connectionService.deleteRemoteItem(item)
                    if result.success {
                        selectedIDs.remove(item.id)
                    }
                }
                itemToDelete = nil
            }
        } message: { item in
            Text(L10n.format("确定要从远程服务器上永久删除“%@”吗？此操作无法撤销。", "Are you sure you want to permanently delete \"%@\" from the remote server? This action cannot be undone.", item.name))
        }
        .onChange(of: connectionService.currentRemotePath) { _, newPath in
            isEditingPath = false
            isPathFieldFocused = false
            editedPathText = newPath?.description ?? ""
        }
        .onChange(of: connectionService.state) { _, _ in
            isEditingPath = false
            isPathFieldFocused = false
            editedPathText = currentRemotePathString
        }
        .onChange(of: isPathFieldFocused) { _, focused in
            if !focused && isEditingPath {
                commitPathEdit()
            }
        }
    }

    private func commitPathEdit() {
        let target = editedPathText.trimmingCharacters(in: .whitespacesAndNewlines)
        isEditingPath = false
        isPathFieldFocused = false
        guard !target.isEmpty else {
            editedPathText = currentRemotePathString
            return
        }
        Task {
            do {
                try await connectionService.navigateRemote(toPathString: target)
                selectedIDs.removeAll()
            } catch {
                editedPathText = currentRemotePathString
            }
        }
    }

    private func cancelPathEdit() {
        isEditingPath = false
        isPathFieldFocused = false
        editedPathText = currentRemotePathString
    }

    private func columnHeader(title: String, field: BrowserSortField, alignment: Alignment) -> some View {
        Button(action: {
            if sortField == field {
                sortAscending.toggle()
            } else {
                sortField = field
                sortAscending = true
            }
        }) {
            HStack(spacing: 4) {
                if alignment == .trailing || alignment == .center { Spacer(minLength: 0) }
                Text(title)
                    .font(FerryFont.captionBold)
                    .foregroundColor(sortField == field ? theme.text : theme.text2)
                if sortField == field {
                    Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(theme.accentColor)
                }
                if alignment == .leading || alignment == .center { Spacer(minLength: 0) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var isConnected: Bool {
        if case .connected = connectionService.state { return true }
        return false
    }

    private var currentRemotePathString: String {
        if let path = connectionService.currentRemotePath {
            return path.description
        }
        return L10n.tr("未连接", "Disconnected")
    }

    private var unconnectedPlaceholder: some View {
        VStack(spacing: 14) {
            AppIconView(size: 56)

            Text(L10n.tr("未连接到远程服务器", "Not Connected to Remote Server"))
                .font(FerryFont.bodyBold)
                .foregroundColor(theme.text)

            Text(L10n.tr("点击下方按钮新建连接，或在左侧选择站点连接。", "Click below to create a new connection, or select a site from the sidebar."))
                .font(FerryFont.caption)
                .foregroundColor(theme.text2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)

            Button(L10n.tr("新建连接…", "New Connection…")) {
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
                    .foregroundColor(isSelected ? .white : (item.isHidden ? theme.text2 : theme.text))
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
                    cancelPathEdit()
                    Task {
                        await connectionService.navigateRemote(to: item.path)
                        selectedIDs.removeAll()
                    }
                }
            }
        )
        .contextMenu {
            Button(item.isDirectory ? L10n.tr("下载文件夹到当前本地目录", "Download Folder to Local") : L10n.tr("下载到当前本地目录", "Download to Local")) {
                selectedIDs = [item.id]
                onDownloadSelected()
            }
            if !item.isDirectory {
                Button(L10n.tr("用外部编辑器打开", "Open with External Editor")) {
                    Task {
                        try? await ExternalEditService.shared.openForEditing(
                            remoteItem: item,
                            connection: connectionService.activeConnection
                        )
                    }
                }
                Button(L10n.tr("快速预览 (Quick Look)", "Quick Look")) {
                    QuickLookService.shared.togglePreview(
                        remoteItem: item,
                        connection: connectionService.activeConnection
                    )
                }
            }
            if item.isDirectory {
                Button(L10n.tr("打开远程文件夹", "Open Remote Folder")) {
                    cancelPathEdit()
                    Task {
                        await connectionService.navigateRemote(to: item.path)
                        selectedIDs.removeAll()
                    }
                }
            }
            Divider()
            Button(L10n.tr("重命名…", "Rename…")) {
                onRenameRemote(item)
            }
            Button(role: .destructive) {
                itemToDelete = item
            } label: {
                Text(item.isDirectory ? L10n.tr("删除文件夹…", "Delete Folder…") : L10n.tr("删除文件…", "Delete File…"))
            }
            Button(L10n.tr("复制远程路径", "Copy Remote Path")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.path.description, forType: .string)
            }
            Divider()
            Button(L10n.tr("新建远程文件夹…", "New Remote Folder…")) {
                onNewRemoteFolder()
            }
        }
        .onDrag {
            if !selectedIDs.contains(item.id) {
                selectedIDs = [item.id]
            }
            let selectedItems = displayedItems.filter { selectedIDs.contains($0.id) }
            return FerryDragDropService.shared.createItemProvider(for: item, allSelectedItems: selectedItems)
        }
        .onDrop(
            of: [.fileURL, .url, FerryUTI.remoteItemType, FerryUTI.localItemType, UTType(FerryUTI.promisedFileIdentifier) ?? .data],
            isTargeted: Binding(
                get: { targetedFolderID == item.id },
                set: { if $0 { targetedFolderID = item.id } else if targetedFolderID == item.id { targetedFolderID = nil } }
            )
        ) { providers in
            if item.isDirectory {
                return handleDrop(providers: providers, targetDirectory: item.path)
            }
            return false
        }
        .overlay(
            targetedFolderID == item.id && item.isDirectory ?
                RoundedRectangle(cornerRadius: FerryRadius.r4)
                    .stroke(theme.accentColor, lineWidth: 2)
                : nil
        )
    }

    private func handleDrop(providers: [NSItemProvider], targetDirectory: RemotePath?) -> Bool {
        guard let destDir = targetDirectory ?? connectionService.currentRemotePath else { return false }

        // 场景 1: 同面板远端移动到子目录（远端 → 远端子目录归类，v2.3 §368）
        let remoteProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(FerryUTI.remoteItemIdentifier) }
        if !remoteProviders.isEmpty {
            for provider in remoteProviders {
                provider.loadDataRepresentation(forTypeIdentifier: FerryUTI.remoteItemIdentifier) { data, _ in
                    guard let data = data else { return }
                    Task { @MainActor in
                        let paths = FerryDragDropService.shared.decodeRemotePaths(from: data)
                        _ = await FerryDragDropService.shared.moveRemoteItems(paths, toDestinationDirectory: destDir)
                    }
                }
            }
            return true
        }

        // 场景 2: 来自本地面板的多选拖拽传输（本地 → 远端）
        let localProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(FerryUTI.localItemIdentifier) }
        if !localProviders.isEmpty {
            for provider in localProviders {
                provider.loadDataRepresentation(forTypeIdentifier: FerryUTI.localItemIdentifier) { data, _ in
                    guard let data = data else { return }
                    Task { @MainActor in
                        let urls = FerryDragDropService.shared.decodeLocalURLs(from: data)
                        connectionService.uploadFiles(urls, toRemoteDirectory: destDir)
                    }
                }
            }
            return true
        }

        // 场景 3: 来自访达 (Finder) 或其他外部应用的拖入（普通文件或 NSFilePromiseReceiver，v2.3 §366）
        Task { @MainActor in
            let urls = await FerryDragDropService.shared.resolveIncomingFiles(from: providers)
            guard !urls.isEmpty else { return }
            connectionService.uploadFiles(urls, toRemoteDirectory: destDir)
        }
        return true
    }
}

