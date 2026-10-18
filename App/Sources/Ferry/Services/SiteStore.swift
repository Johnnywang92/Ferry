import FerryCore
import Foundation
import Observation

/// 站点书签持久化与 `.ssh/config` 导入服务（M2 交付）。
///
/// - 站点元数据落盘 `~/Library/Application Support/Ferry/sites.json`（经 `Store<[SiteBookmark]>` 原子写）；
/// - 密码与私钥口令绝不落 JSON，按 `savePasswordInKeychain` 存入登录钥匙串 `KeychainService`；
/// - 支持一键扫描 `~/.ssh/config`（或任意自定义 ssh_config 文件）并去重导入站点。
@Observable
@MainActor
public final class SiteStore {
    public static let shared = SiteStore()

    public private(set) var sites: [SiteBookmark] = []
    public var bookmarks: [SiteBookmark] { sites }
    public var lastImportSummary: String?

    private let store: Store<[SiteBookmark]>
    private let keychain: KeychainService

    public init(storeURL: URL? = nil, keychain: KeychainService = .shared) {
        let resolvedURL: URL
        if let storeURL {
            resolvedURL = storeURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let ferryDir = appSupport.appendingPathComponent("Ferry", isDirectory: true)
            resolvedURL = ferryDir.appendingPathComponent("sites.json")
        }
        self.store = Store<[SiteBookmark]>(url: resolvedURL)
        self.keychain = keychain
        Task {
            await load()
        }
    }

    public func load() async {
        do {
            if let persisted = try await store.read(), !persisted.isEmpty {
                self.sites = persisted.map { hydrateSecrets(for: $0) }
            } else {
                // 首次启动写入默认预设站点并同步保存预设密码
                let presets = SiteBookmark.samplePresets
                for preset in presets where preset.savePasswordInKeychain {
                    persistSecrets(for: preset)
                }
                self.sites = presets
                try? await store.write(presets)
            }
        } catch {
            self.sites = SiteBookmark.samplePresets
        }
    }

    public func upsert(_ bookmark: SiteBookmark) async {
        if bookmark.savePasswordInKeychain {
            persistSecrets(for: bookmark)
        } else {
            keychain.deleteAllSecrets(for: bookmark.id)
        }

        if let index = sites.firstIndex(where: { $0.id == bookmark.id }) {
            sites[index] = bookmark
        } else {
            sites.insert(bookmark, at: 0)
        }
        try? await store.write(sites)
    }

    public func delete(_ id: UUID) async {
        keychain.deleteAllSecrets(for: id)
        sites.removeAll { $0.id == id }
        try? await store.write(sites)
    }

    /// 预览 `~/.ssh/config`（或指定路径）中的可导入主机条目。
    public func previewSSHConfig(at url: URL? = nil) throws -> [SSHHostEntry] {
        let configURL = url ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config")
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            return []
        }
        return try SSHConfigParser.parseFile(at: configURL)
    }

    /// 将选定的 `SSHHostEntry` 列表导入站点库（按名称+主机+端口去重更新或新增）。
    @discardableResult
    public func importSSHConfigEntries(_ entries: [SSHHostEntry]) async -> (added: Int, updated: Int, proxyJumpCount: Int) {
        var added = 0
        var updated = 0
        var proxyCount = 0

        for entry in entries {
            if entry.proxyJump != nil {
                proxyCount += 1
            }
            let converted = SiteBookmark.from(sshEntry: entry)
            if let existingIdx = sites.firstIndex(where: { $0.name == entry.alias }) {
                var merged = converted
                merged.id = sites[existingIdx].id
                merged.password = sites[existingIdx].password
                merged.passphrase = sites[existingIdx].passphrase
                merged.localBookmark = sites[existingIdx].localBookmark
                merged.remotePath = sites[existingIdx].remotePath
                sites[existingIdx] = merged
                updated += 1
            } else {
                sites.append(converted)
                added += 1
            }
        }

        try? await store.write(sites)
        var summary = "已从 SSH 配置导入 \(added) 个新增站点、更新 \(updated) 个站点"
        if proxyCount > 0 {
            summary += "（其中 \(proxyCount) 个含 ProxyJump 配置，已保留但 v1.1+ 才支持跳板连接）"
        }
        lastImportSummary = summary
        return (added, updated, proxyCount)
    }

    private func hydrateSecrets(for bookmark: SiteBookmark) -> SiteBookmark {
        var copy = bookmark
        if copy.savePasswordInKeychain {
            if let savedPass = keychain.loadSecret(for: copy.id, kind: .password), !savedPass.isEmpty {
                copy.password = savedPass
            } else if let preset = SiteBookmark.samplePresets.first(where: { $0.id == copy.id }), !preset.password.isEmpty {
                copy.password = preset.password
            }
            if let savedPassphrase = keychain.loadSecret(for: copy.id, kind: .passphrase), !savedPassphrase.isEmpty {
                copy.passphrase = savedPassphrase
            }
        }
        return copy
    }

    private func persistSecrets(for bookmark: SiteBookmark) {
        if !bookmark.password.isEmpty {
            keychain.saveSecret(bookmark.password, for: bookmark.id, kind: .password)
        }
        if !bookmark.passphrase.isEmpty {
            keychain.saveSecret(bookmark.passphrase, for: bookmark.id, kind: .passphrase)
        }
    }
}
