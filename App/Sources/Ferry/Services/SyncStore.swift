import FerryCore
import Foundation
import Observation

/// 同步基线快照持久化管理服务（M5，v2.3 §388, §432）。
///
/// 记录本地路径与远程路径对应的上次一致基线快照 `SyncBaseSnapshot`。
/// 数据持久化至 `~/Library/Application Support/Ferry/sync_snapshots.json`。
@Observable
@MainActor
public final class SyncStore {
    public static let shared = SyncStore()

    private var snapshots: [String: SyncBaseSnapshot] = [:]
    private let store: Store<[String: SyncBaseSnapshot]>

    public init(storeURL: URL? = nil) {
        let resolvedURL: URL
        if let storeURL {
            resolvedURL = storeURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let ferryDir = appSupport.appendingPathComponent("Ferry", isDirectory: true)
            resolvedURL = ferryDir.appendingPathComponent("sync_snapshots.json")
        }
        self.store = Store<[String: SyncBaseSnapshot]>(url: resolvedURL)
        Task {
            await load()
        }
    }

    public func load() async {
        do {
            if let persisted = try await store.read() {
                self.snapshots = persisted
            }
        } catch {
            self.snapshots = [:]
        }
    }

    public func snapshotKey(localPath: String, remotePath: String) -> String {
        "\(localPath):::\(remotePath)"
    }

    public func getSnapshot(localPath: String, remotePath: String) -> SyncBaseSnapshot? {
        let key = snapshotKey(localPath: localPath, remotePath: remotePath)
        return snapshots[key]
    }

    public func saveSnapshot(_ snapshot: SyncBaseSnapshot) async {
        let key = snapshotKey(localPath: snapshot.localRootPath, remotePath: snapshot.remoteRootPath)
        snapshots[key] = snapshot
        try? await store.write(snapshots)
    }

    public func clearSnapshot(localPath: String, remotePath: String) async {
        let key = snapshotKey(localPath: localPath, remotePath: remotePath)
        snapshots.removeValue(forKey: key)
        try? await store.write(snapshots)
    }
}
