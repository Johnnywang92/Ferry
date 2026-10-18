import AppKit
import FerryCore
import SwiftUI
import UniformTypeIdentifiers

public struct LocalPaneView: View {
    @Binding var currentURL: URL
    @Binding var selectedIDs: Set<String>
    var searchText: String
    var onUploadSelected: () -> Void
    var onNewLocalFolder: () -> Void
    var onRenameLocal: (LocalItem) -> Void

    @Environment(\.colorScheme) private var colorScheme
    private var themeManager: ThemeManager { ThemeManager.shared }
    @State private var items: [LocalItem] = []
    @State private var errorMessage: String?
    @State private var sortField: BrowserSortField = .name
    @State private var sortAscending: Bool = true
    @State private var isEditingPath: Bool = false
    @State private var editedPathText: String = ""
    @State private var isDropTargeted: Bool = false
    @State private var targetedFolderID: String? = nil
    @State private var itemToDelete: LocalItem? = nil


    private var theme: FerryTheme {
        themeManager.theme(for: colorScheme)
    }

    private var displayedItems: [LocalItem] {
        let filteredByHidden = items.filter { themeManager.showHiddenFiles || !$0.isHidden }
        let filtered: [LocalItem]
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
                let lDate = lhs.modificationDate ?? .distantPast
                let rDate = rhs.modificationDate ?? .distantPast
                cmp = lDate == rDate ? .orderedSame : (lDate < rDate ? .orderedAscending : .orderedDescending)
            case .size:
                cmp = lhs.size == rhs.size ? .orderedSame : (lhs.size < rhs.size ? .orderedAscending : .orderedDescending)
            case .permissions:
                cmp = lhs.name.localizedStandardCompare(rhs.name)
            }
            if cmp == .orderedSame {
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return sortAscending ? (cmp == .orderedAscending) : (cmp == .orderedDescending)
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // 栏头：本地标签 + 路径栏 + 上一级 + 刷新
            HStack(spacing: 8) {
                // `本地` 标签
                Text(L10n.tr("本地", "Local"))
                    .font(FerryFont.micro)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(theme.tagLocal)
                    .foregroundColor(.white)
                    .cornerRadius(FerryRadius.r3)

                // 路径栏（支持点击直接编辑跳转）
                if isEditingPath {
                    TextField(L10n.tr("输入本地路径…", "Enter local path…"), text: $editedPathText)
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
                        .onSubmit {
                            commitPathEdit()
                        }
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.system(size: 11))
                            .foregroundColor(theme.text3)
                        Text(displayPath(currentURL))
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
                        editedPathText = currentURL.path
                        isEditingPath = true
                    }
                    .help(L10n.tr("点击直接输入本地路径，或按 ⌘⇧G 前往文件夹", "Click to enter path, or press ⌘⇧G to go to folder"))
                }

                // 返回上一级
                Button(action: goUp) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.icon)
                        .frame(width: 24, height: 24)
                        .background(theme.panel)
                        .cornerRadius(FerryRadius.r4)
                }
                .buttonStyle(.plain)
                .help(L10n.tr("上一级", "Parent Folder"))
                .disabled(currentURL.path == "/")

                // 刷新
                Button(action: loadDirectory) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                        .foregroundColor(theme.icon)
                        .frame(width: 24, height: 24)
                        .background(theme.panel)
                        .cornerRadius(FerryRadius.r4)
                }
                .buttonStyle(.plain)
                .help(L10n.tr("刷新本地目录", "Refresh Local Directory"))
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

            // 表头：名称 / 修改时间 / 大小（支持点击排序）
            HStack(spacing: 0) {
                columnHeader(title: L10n.tr("名称", "Name"), field: .name, alignment: .leading)
                    .padding(.leading, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)

                columnHeader(title: L10n.tr("修改时间", "Date Modified"), field: .modificationDate, alignment: .leading)
                    .frame(width: 130, alignment: .leading)

                columnHeader(title: L10n.tr("大小", "Size"), field: .size, alignment: .trailing)
                    .frame(width: 80, alignment: .trailing)
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

            // 文件列表
            if let err = errorMessage {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 24))
                        .foregroundColor(theme.warningOrange)
                    Text(err)
                        .font(FerryFont.caption)
                        .foregroundColor(theme.text2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.bg)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(displayedItems) { item in
                            localRow(item)
                        }
                    }
                }
                .background(theme.bg)
                .onDrop(
                    of: [.fileURL, .url, FerryUTI.remoteItemType, FerryUTI.localItemType, UTType(FerryUTI.promisedFileIdentifier) ?? .data],
                    isTargeted: $isDropTargeted
                ) { providers in
                    handleDrop(providers: providers, targetDirectory: currentURL)
                }
                .overlay(
                    isDropTargeted ?
                        Rectangle()
                            .stroke(theme.accentColor, lineWidth: 2)
                        : nil
                )
                .contextMenu {
                    Button(L10n.tr("新建本地文件夹…", "New Local Folder…")) {
                        onNewLocalFolder()
                    }
                    Button(themeManager.showHiddenFiles ? L10n.tr("隐藏以 . 开头的隐藏文件", "Hide Hidden Files") : L10n.tr("显示隐藏文件", "Show Hidden Files")) {
                        themeManager.toggleHiddenFiles()
                    }
                    Button(L10n.tr("刷新", "Refresh")) {
                        loadDirectory()
                    }
                }
            }
        }
        .onAppear {
            loadDirectory()
        }
        .onChange(of: currentURL) { _, _ in
            isEditingPath = false
            loadDirectory()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ferryRefreshLocalPane)) { _ in
            loadDirectory()
        }
        .alert(
            itemToDelete?.isDirectory == true ? L10n.tr("删除本地文件夹", "Delete Local Folder") : L10n.tr("删除本地文件", "Delete Local File"),
            isPresented: Binding(
                get: { itemToDelete != nil },
                set: { if !$0 { itemToDelete = nil } }
            ),
            presenting: itemToDelete
        ) { item in
            Button(L10n.tr("取消", "Cancel"), role: .cancel) {
                itemToDelete = nil
            }
            Button(L10n.tr("移到废纸篓", "Move to Trash"), role: .destructive) {
                do {
                    try LocalFileSystemService.shared.deleteItem(at: item.url)
                    selectedIDs.remove(item.id)
                    loadDirectory()
                } catch {
                    errorMessage = error.localizedDescription
                }
                itemToDelete = nil
            }
        } message: { item in
            Text(L10n.format("确定要将“%@”移到废纸篓吗？", "Are you sure you want to move \"%@\" to Trash?", item.name))
        }
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
                if alignment == .trailing { Spacer(minLength: 0) }
                Text(title)
                    .font(FerryFont.captionBold)
                    .foregroundColor(sortField == field ? theme.text : theme.text2)
                if sortField == field {
                    Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(theme.accentColor)
                }
                if alignment == .leading { Spacer(minLength: 0) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func localRow(_ item: LocalItem) -> some View {
        let isSelected = selectedIDs.contains(item.id)

        return HStack(spacing: 0) {
            // 图标与名称
            HStack(spacing: 6) {
                Image(systemName: item.isDirectory ? "folder.fill" : (item.isSymbolicLink ? "link" : "doc"))
                    .font(.system(size: 13))
                    .foregroundColor(item.isDirectory ? (isSelected ? .white : theme.accentColor) : (isSelected ? .white : theme.icon))

                Text(item.name)
                    .font(FerryFont.subheadline)
                    .foregroundColor(isSelected ? .white : (item.isHidden ? theme.text2 : theme.text))
                    .lineLimit(1)
            }
            .padding(.leading, 12)
            .frame(maxWidth: .infinity, alignment: .leading)

            // 修改时间
            Text(item.formattedDate)
                .font(FerryFont.monoSmall)
                .foregroundColor(isSelected ? .white.opacity(0.9) : theme.text2)
                .frame(width: 130, alignment: .leading)

            // 大小
            Text(item.formattedSize)
                .font(FerryFont.monoSmall)
                .foregroundColor(isSelected ? .white.opacity(0.9) : theme.text2)
                .frame(width: 80, alignment: .trailing)
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
                    currentURL = item.url
                    selectedIDs.removeAll()
                }
            }
        )
        .contextMenu {
            Button(item.isDirectory ? L10n.tr("上传文件夹到当前远端目录", "Upload Folder to Remote") : L10n.tr("上传到当前远端目录", "Upload to Remote")) {
                selectedIDs = [item.id]
                onUploadSelected()
            }
            if !item.isDirectory {
                Button(L10n.tr("快速预览 (Quick Look)", "Quick Look")) {
                    QuickLookService.shared.togglePreview(localURL: item.url)
                }
            }
            if item.isDirectory {
                Button(L10n.tr("打开文件夹", "Open Folder")) {
                    currentURL = item.url
                    selectedIDs.removeAll()
                }
            }
            Divider()
            Button(L10n.tr("重命名…", "Rename…")) {
                onRenameLocal(item)
            }
            Button(role: .destructive) {
                itemToDelete = item
            } label: {
                Text(item.isDirectory ? L10n.tr("删除文件夹…", "Delete Folder…") : L10n.tr("删除文件…", "Delete File…"))
            }
            Button(L10n.tr("在访达中显示", "Show in Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
            Button(L10n.tr("复制本地路径", "Copy Local Path")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url.path, forType: .string)
            }
            Divider()
            Button(L10n.tr("新建本地文件夹…", "New Local Folder…")) {
                onNewLocalFolder()
            }
        }
        .onDrag {
            if !selectedIDs.contains(item.id) {
                selectedIDs = [item.id]
            }
            let selectedItems = displayedItems.filter { selectedIDs.contains($0.id) }
            return FerryDragDropService.shared.createLocalItemProvider(for: item, allSelectedItems: selectedItems)
        }
        .onDrop(
            of: [.fileURL, .url, FerryUTI.remoteItemType, FerryUTI.localItemType, UTType(FerryUTI.promisedFileIdentifier) ?? .data],
            isTargeted: Binding(
                get: { targetedFolderID == item.id },
                set: { if $0 { targetedFolderID = item.id } else if targetedFolderID == item.id { targetedFolderID = nil } }
            )
        ) { providers in
            if item.isDirectory {
                return handleDrop(providers: providers, targetDirectory: item.url)
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

    private func handleDrop(providers: [NSItemProvider], targetDirectory: URL) -> Bool {
        // 场景 1: 从远端面板拖入下载（远端 → 本地，支持单选与多选批量下载）
        let remoteProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(FerryUTI.remoteItemIdentifier) }
        if !remoteProviders.isEmpty {
            for provider in remoteProviders {
                provider.loadDataRepresentation(forTypeIdentifier: FerryUTI.remoteItemIdentifier) { data, _ in
                    guard let data = data else { return }
                    Task { @MainActor in
                        let itemsToDownload = FerryDragDropService.shared.decodeRemoteItems(from: data)
                        guard !itemsToDownload.isEmpty else { return }
                        ConnectionService.shared.downloadItems(itemsToDownload, to: targetDirectory) {
                            NotificationCenter.default.post(name: .ferryRefreshLocalPane, object: nil)
                        }
                    }
                }
            }
            return true
        }

        // 场景 2: 从访达 (Finder) 或外部拖入本地目录（支持复制文件/文件夹以及 NSFilePromiseReceiver）
        Task { @MainActor in
            let urls = await FerryDragDropService.shared.resolveIncomingFiles(from: providers)
            guard !urls.isEmpty else { return }
            do {
                try LocalFileSystemService.shared.copyItems(urls, into: targetDirectory)
                loadDirectory()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        return true
    }


    private func commitPathEdit() {
        isEditingPath = false
        do {
            let resolved = try LocalFileSystemService.shared.resolvePath(editedPathText, relativeTo: currentURL)
            currentURL = resolved
            selectedIDs.removeAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadDirectory() {
        errorMessage = nil
        do {
            items = try LocalFileSystemService.shared.listContents(at: currentURL, showHidden: true)
        } catch {
            errorMessage = error.localizedDescription
            items = []
        }
    }

    private func goUp() {
        let parent = currentURL.deletingLastPathComponent()
        if parent != currentURL {
            currentURL = parent
            selectedIDs.removeAll()
        }
    }

    private func displayPath(_ url: URL) -> String {
        let path = url.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            let relative = String(path.dropFirst(home.count))
            return "~" + relative
        }
        return path
    }
}
