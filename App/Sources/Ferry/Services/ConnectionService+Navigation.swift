import FerryBackendsSFTP
import FerryCore
import Foundation

// MARK: - 远程目录导航、刷新与文件操作扩展（v2.3 §330-340 & R5）
extension ConnectionService {

    // MARK: - 切换字符集（即时重解码当前目录，R5）
    public func setCharset(_ charset: CharsetConverter.Charset) {
        currentCharset = charset
        if var bookmark = currentBookmark {
            bookmark.charset = charset
            currentBookmark = bookmark
            Task {
                await SiteStore.shared.upsert(bookmark)
            }
        }
        rebuildDisplayItems()
    }

    // MARK: - 切换与刷新远端目录
    public func navigateRemote(to path: RemotePath) async {
        guard let connection = activeConnection else { return }
        navigationErrorMessage = nil
        do {
            try await loadRemoteItems(from: path, on: connection)
        } catch let remoteError as RemoteError {
            navigationErrorMessage = Self.readableMessage(for: remoteError)
        } catch {
            navigationErrorMessage = error.localizedDescription
        }
    }

    public func navigateRemote(toPathString rawString: String) async throws {
        guard let connection = activeConnection else { return }
        let trimmed = rawString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        navigationErrorMessage = nil

        do {
            let home: RemotePath
            if let sftp = connection as? SFTPConnection {
                home = (try? await sftp.homeDirectory()) ?? PathResolver.root
            } else {
                home = PathResolver.root
            }
            let base = currentRemotePath ?? home
            let rawPath = RemotePath(wireBytes: Array(trimmed.utf8), isAbsolute: trimmed.hasPrefix("/"))
            let resolved = try PathResolver(homeDirectory: home).lexicalResolve(rawPath, relativeTo: base)
            try await loadRemoteItems(from: resolved, on: connection)
        } catch let remoteError as RemoteError {
            navigationErrorMessage = Self.readableMessage(for: remoteError)
            throw remoteError
        } catch {
            navigationErrorMessage = error.localizedDescription
            throw error
        }
    }

    public func refreshRemote() async {
        guard let current = currentRemotePath else { return }
        await navigateRemote(to: current)
    }

    public func navigateRemoteUp() async {
        guard let current = currentRemotePath else { return }
        let parent = current.parent
        await navigateRemote(to: parent)
    }

    public func createRemoteFolder(named name: String) async {
        guard let connection = activeConnection, let current = currentRemotePath else { return }
        let converter = CharsetConverter(charset: currentCharset)
        let nameBytes: [UInt8]
        if case .bytes(let encoded) = converter.encode(name) {
            nameBytes = encoded
        } else {
            nameBytes = Array(name.utf8)
        }
        guard let target = try? PathResolver.child(of: current, name: nameBytes) else { return }
        do {
            try await connection.mkdir(target, permissions: 0o755)
            await refreshRemote()
        } catch let remoteError as RemoteError {
            navigationErrorMessage = Self.readableMessage(for: remoteError)
        } catch {
            navigationErrorMessage = error.localizedDescription
        }
    }

    public func renameRemoteItem(_ item: RemoteDisplayItem, to newName: String) async -> (success: Bool, error: String?) {
        guard let connection = activeConnection else {
            return (false, "未连接到远程服务器")
        }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return (false, "名称不能为空")
        }
        guard !trimmed.contains("/") else {
            return (false, "名称不能包含 '/'")
        }
        if trimmed == item.name {
            return (true, nil)
        }

        let converter = CharsetConverter(charset: currentCharset)
        let nameBytes: [UInt8]
        if case .bytes(let encoded) = converter.encode(trimmed) {
            nameBytes = encoded
        } else {
            nameBytes = Array(trimmed.utf8)
        }

        guard let parent = try? PathResolver.parent(of: item.path),
              let target = try? PathResolver.child(of: parent, name: nameBytes) else {
            return (false, "无法解析目标路径")
        }

        do {
            try await connection.rename(item.path, to: target, overwrite: false)
            await refreshRemote()
            return (true, nil)
        } catch let remoteError as RemoteError {
            let readable = Self.readableMessage(for: remoteError)
            return (false, readable)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    public func deleteRemoteItem(_ item: RemoteDisplayItem) async -> (success: Bool, error: String?) {
        guard let connection = activeConnection else {
            return (false, "未连接到远程服务器")
        }
        do {
            try await connection.remove(item.path, recursive: true)
            await refreshRemote()
            return (true, nil)
        } catch let remoteError as RemoteError {
            let readable = Self.readableMessage(for: remoteError)
            return (false, readable)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    func loadRemoteItems(from path: RemotePath, on connection: any RemoteFileSystem) async throws {
        var listing = try await connection.list(path)
        var resolutions: [RemotePath: RemoteDirectoryListing.LinkResolution] = [:]
        for rawItem in listing.entries where rawItem.kind == .symbolicLink {
            if let res = try? await connection.resolve(rawItem, in: &listing) {
                resolutions[rawItem.path] = res
            }
        }
        self.currentRemotePath = listing.directory
        self.cachedListing = listing
        self.cachedResolutions = resolutions
        self.remoteListingStaleCount = listing.staleResolutionCount
        rebuildDisplayItems()
    }

    func rebuildDisplayItems() {
        guard let listing = cachedListing else {
            self.remoteItems = []
            return
        }
        let converter = CharsetConverter(charset: currentCharset)
        let items = listing.entries.map { rawItem in
            RemoteDisplayItem(
                item: rawItem,
                charsetConverter: converter,
                linkResolution: cachedResolutions[rawItem.path]
            )
        }
        self.remoteItems = items.sorted { a, b in
            if a.isDirectory != b.isDirectory {
                return a.isDirectory && !b.isDirectory
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}
