import SwiftUI

public struct SidebarView: View {
    @Binding var selectedBookmark: SiteBookmark?
    @Binding var showingNewConnection: Bool
    var onConnectSite: (SiteBookmark) -> Void
    var onSelectLocalLocation: (URL) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var sites: [SiteBookmark] = SiteBookmark.samplePresets
    @State private var localLocations: [LocalLocation] = LocalLocation.defaults

    private var theme: FerryTheme {
        ThemeManager().theme(for: colorScheme)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 站点分组
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("站点")
                                .font(FerryFont.captionBold)
                                .foregroundColor(theme.text3)
                            Spacer()
                            Button(action: { showingNewConnection = true }) {
                                Image(systemName: "plus")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(theme.text2)
                            }
                            .buttonStyle(.plain)
                            .help("添加站点")
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                        .padding(.bottom, 4)

                        ForEach(sites) { site in
                            siteRow(site)
                        }
                    }

                    Divider().background(theme.line).padding(.horizontal, 10)

                    // 本地位置分组
                    VStack(alignment: .leading, spacing: 2) {
                        Text("本地位置")
                            .font(FerryFont.captionBold)
                            .foregroundColor(theme.text3)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 4)

                        ForEach(localLocations) { loc in
                            localLocationRow(loc)
                        }
                    }
                }
                .padding(.vertical, 8)
            }

            Divider().background(theme.line)

            // 底部外观模式与偏好快捷设置
            HStack(spacing: 8) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 12))
                    .foregroundColor(theme.text3)
                Text("偏好设置")
                    .font(FerryFont.caption)
                    .foregroundColor(theme.text2)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(theme.side)
        }
        .frame(width: 220)
        .background(theme.side)
        .overlay(
            Rectangle()
                .frame(width: 1)
                .foregroundColor(theme.line),
            alignment: .trailing
        )
    }

    private func siteRow(_ site: SiteBookmark) -> some View {
        let isSelected = selectedBookmark?.id == site.id
        return Button(action: {
            selectedBookmark = site
        }) {
            HStack(spacing: 8) {
                Image(systemName: site.protocolType == .sftp ? "server.rack" : "externaldrive.connected.to.line.below")
                    .font(.system(size: 12))
                    .foregroundColor(isSelected ? .white : theme.icon)
                    .frame(width: 16)

                Text(site.name)
                    .font(FerryFont.captionMedium)
                    .foregroundColor(isSelected ? .white : theme.text)
                    .lineLimit(1)

                Spacer()

                // 协议胶囊
                Text(site.protocolType.rawValue)
                    .font(FerryFont.micro)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(isSelected ? Color.white.opacity(0.2) : theme.pill)
                    .foregroundColor(isSelected ? .white : theme.text2)
                    .cornerRadius(FerryRadius.r3)
                    .overlay(
                        RoundedRectangle(cornerRadius: FerryRadius.r3)
                            .stroke(isSelected ? Color.clear : theme.pillRing, lineWidth: 1)
                    )
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: FerryRadius.r5)
                    .fill(isSelected ? theme.accentSelected : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .contextMenu {
            Button("连接") {
                onConnectSite(site)
            }
            Button("编辑…") {
                selectedBookmark = site
                showingNewConnection = true
            }
        }
    }

    private func localLocationRow(_ location: LocalLocation) -> some View {
        Button(action: {
            onSelectLocalLocation(location.url)
        }) {
            HStack(spacing: 8) {
                Image(systemName: location.iconName)
                    .font(.system(size: 12))
                    .foregroundColor(theme.icon)
                    .frame(width: 16)

                Text(location.name)
                    .font(FerryFont.captionMedium)
                    .foregroundColor(theme.text)
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }
}
