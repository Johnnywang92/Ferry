import AppKit
import SwiftUI

public struct LocalPaneView: View {
    @Binding var currentURL: URL
    @Binding var selectedIDs: Set<String>
    var searchText: String
    var onUploadSelected: () -> Void
    var onNewLocalFolder: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    private var themeManager: ThemeManager { ThemeManager.shared }
    @State private var items: [LocalItem] = []
    @State private var errorMessage: String?
    @State private var sortField: BrowserSortField = .name
    @State private var sortAscending: Bool = true
    @State private var isEditingPath: Bool = false
    @State private var editedPathText: String = ""

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
                Text("本地")
                    .font(FerryFont.micro)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(theme.tagLocal)
                    .foregroundColor(.white)
                    .cornerRadius(FerryRadius.r3)

                // 路径栏（支持点击直接编辑跳转）
                if isEditingPath {
                    TextField("输入本地路径…", text: $editedPathText)
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
                    .help("点击直接输入本地路径，或按 ⌘⇧G 前往文件夹")
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
                .help("上一级")
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
                .help("刷新本地目录")
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
                columnHeader(title: "名称", field: .name, alignment: .leading)
                    .padding(.leading, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)

                columnHeader(title: "修改时间", field: .modificationDate, alignment: .leading)
                    .frame(width: 130, alignment: .leading)

                columnHeader(title: "大小", field: .size, alignment: .trailing)
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
                .contextMenu {
                    Button("新建本地文件夹…") {
                        onNewLocalFolder()
                    }
                    Button(themeManager.showHiddenFiles ? "隐藏以 . 开头的隐藏文件" : "显示隐藏文件") {
                        themeManager.toggleHiddenFiles()
                    }
                    Button("刷新") {
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
            Button(item.isDirectory ? "上传文件夹到当前远端目录" : "上传到当前远端目录") {
                selectedIDs = [item.id]
                onUploadSelected()
            }
            if item.isDirectory {
                Button("打开文件夹") {
                    currentURL = item.url
                    selectedIDs.removeAll()
                }
            }
            Divider()
            Button("在访达中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
            Button("复制本地路径") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url.path, forType: .string)
            }
            Divider()
            Button("新建本地文件夹…") {
                onNewLocalFolder()
            }
        }
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
