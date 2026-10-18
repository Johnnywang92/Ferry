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
    @State private var isDropTargeted: Bool = false
    @State private var targetedFolderID: String? = nil


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
                Text("远程")
                    .font(FerryFont.micro)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(theme.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(FerryRadius.r3)

                // 路径栏（支持点击直接输入远程路径跳转）
                if isEditingPath && isConnected {
                    TextField("输入远程路径…", text: $editedPathText)
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
                            let target = editedPathText
                            isEditingPath = false
                            Task {
                                try? await connectionService.navigateRemote(toPathString: target)
                                selectedIDs.removeAll()
                            }
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
                        }
                    }
                    .help(isConnected ? "点击直接输入远程路径，或按 ⌘⇧G 前往文件夹" : "连接后可浏览远程路径")
                }

                // 返回上一级
                Button(action: {
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

            // 表头：名称 / 修改时间 / 大小 / 权限（支持点击排序）
            HStack(spacing: 0) {
                columnHeader(title: "名称", field: .name, alignment: .leading)
                    .padding(.leading, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)

                columnHeader(title: "修改时间", field: .modificationDate, alignment: .leading)
                    .frame(width: 120, alignment: .leading)

                columnHeader(title: "大小", field: .size, alignment: .trailing)
                    .frame(width: 75, alignment: .trailing)

                columnHeader(title: "权限", field: .permissions, alignment: .center)
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
                .onDrop(of: [.fileURL, UTType(FerryUTI.remoteItemIdentifier) ?? .item], isTargeted: $isDropTargeted) { providers in
                    handleDrop(providers: providers, targetDirectory: nil)
                }
                .overlay(
                    isDropTargeted ?
                        Rectangle()
                            .stroke(theme.accentColor, lineWidth: 2)
                        : nil
                )
                .contextMenu {
                    Button("新建远程文件夹…") {
                        onNewRemoteFolder()
                    }
                    Button(themeManager.showHiddenFiles ? "隐藏以 . 开头的隐藏文件" : "显示隐藏文件") {
                        themeManager.toggleHiddenFiles()
                    }
                    Menu("文件名字符集 (\(connectionService.currentCharset.displayName))") {
                        ForEach(CharsetConverter.Charset.allCases) { cs in
                            Button(cs.displayName) {
                                connectionService.setCharset(cs)
                            }
                        }
                    }
                    Button("刷新") {
                        Task { await connectionService.refreshRemote() }
                    }
                }
            }
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
                    Task {
                        await connectionService.navigateRemote(to: item.path)
                        selectedIDs.removeAll()
                    }
                }
            }
        )
        .contextMenu {
            Button(item.isDirectory ? "下载文件夹到当前本地目录" : "下载到当前本地目录") {
                selectedIDs = [item.id]
                onDownloadSelected()
            }
            if !item.isDirectory {
                Button("用外部编辑器打开") {
                    Task {
                        try? await ExternalEditService.shared.openForEditing(
                            remoteItem: item,
                            connection: connectionService.activeConnection
                        )
                    }
                }
                Button("快速预览 (Quick Look)") {
                    QuickLookService.shared.togglePreview(
                        remoteItem: item,
                        connection: connectionService.activeConnection
                    )
                }
            }
            if item.isDirectory {
                Button("打开远程文件夹") {
                    Task {
                        await connectionService.navigateRemote(to: item.path)
                        selectedIDs.removeAll()
                    }
                }
            }
            Divider()
            Button("重命名…") {
                onRenameRemote(item)
            }
            Button("复制远程路径") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.path.description, forType: .string)
            }
            Divider()
            Button("新建远程文件夹…") {
                onNewRemoteFolder()
            }
        }
        .onDrag {
            selectedIDs = [item.id]
            return FerryDragDropService.shared.createItemProvider(for: item)
        }
        .onDrop(of: [.fileURL, UTType(FerryUTI.remoteItemIdentifier) ?? .item], isTargeted: Binding(
            get: { targetedFolderID == item.id },
            set: { if $0 { targetedFolderID = item.id } else if targetedFolderID == item.id { targetedFolderID = nil } }
        )) { providers in
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
        var handled = false

        for provider in providers {
            // 场景 1: 同面板远端移动到子目录（远端 → 远端，v2.3 §368）
            if provider.hasItemConformingToTypeIdentifier(FerryUTI.remoteItemIdentifier) {
                provider.loadDataRepresentation(forTypeIdentifier: FerryUTI.remoteItemIdentifier) { data, _ in
                    guard let data = data else { return }
                    let bytes = Array(data)
                    let sourcePath = RemotePath(wireBytes: bytes, isAbsolute: true)
                    Task { @MainActor in
                        _ = await FerryDragDropService.shared.moveRemoteItem(sourcePath, toDestinationDirectory: destDir)
                    }
                }
                handled = true
                continue
            }

            // 场景 2: 本地文件或 Finder 文件拖入上传（本地 → 远端 / Finder → 远端）
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let url: URL?
                    if let u = item as? URL {
                        url = u
                    } else if let data = item as? Data, let str = String(data: data, encoding: .utf8) {
                        url = URL(string: str)
                    } else {
                        url = nil
                    }
                    if let fileURL = url {
                        Task { @MainActor in
                            connectionService.uploadFiles([fileURL])
                        }
                    }
                }
                handled = true
            }
        }
        return handled
    }
}

