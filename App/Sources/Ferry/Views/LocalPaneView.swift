import SwiftUI

public struct LocalPaneView: View {
    @Binding var currentURL: URL
    @Binding var selectedIDs: Set<String>

    @Environment(\.colorScheme) private var colorScheme
    @State private var items: [LocalItem] = []
    @State private var errorMessage: String?
    @State private var sortAscending: Bool = true

    private var theme: FerryTheme {
        ThemeManager().theme(for: colorScheme)
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

                // 路径栏
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

            // 表头：名称 ↑ / 修改时间 / 大小
            HStack(spacing: 0) {
                HStack(spacing: 4) {
                    Text("名称")
                        .font(FerryFont.captionBold)
                        .foregroundColor(theme.text2)
                    Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
                        .font(.system(size: 9))
                        .foregroundColor(theme.text3)
                }
                .padding(.leading, 12)
                .frame(maxWidth: .infinity, alignment: .leading)

                Text("修改时间")
                    .font(FerryFont.captionBold)
                    .foregroundColor(theme.text2)
                    .frame(width: 130, alignment: .leading)

                Text("大小")
                    .font(FerryFont.captionBold)
                    .foregroundColor(theme.text2)
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
                        ForEach(items) { item in
                            localRow(item)
                        }
                    }
                }
                .background(theme.bg)
            }
        }
        .onAppear {
            loadDirectory()
        }
        .onChange(of: currentURL) { _, _ in
            loadDirectory()
        }
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
                    .foregroundColor(isSelected ? .white : theme.text)
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
