import FerryCore
import Foundation
import Observation

/// 本地常用快速位置持久化管理服务
///
/// 存储用户在侧边栏“本地位置”自定义添加、修改或删除的书签条目。
/// 数据持久化至 `~/Library/Application Support/Ferry/local_locations.json`。
@Observable
@MainActor
public final class LocalLocationStore {
    public static let shared = LocalLocationStore()

    public private(set) var locations: [LocalLocation] = []

    private let store: Store<[LocalLocation]>

    public init(storeURL: URL? = nil) {
        let resolvedURL: URL
        if let storeURL {
            resolvedURL = storeURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let ferryDir = appSupport.appendingPathComponent("Ferry", isDirectory: true)
            resolvedURL = ferryDir.appendingPathComponent("local_locations.json")
        }
        self.store = Store<[LocalLocation]>(url: resolvedURL)
        Task {
            await load()
        }
    }

    public func load() async {
        do {
            if let persisted = try await store.read() {
                self.locations = persisted
            } else {
                // 首次使用，写入系统预设默认位置
                let defaults = LocalLocation.defaults
                self.locations = defaults
                try? await store.write(defaults)
            }
        } catch {
            self.locations = LocalLocation.defaults
        }
    }

    public func add(_ location: LocalLocation) async {
        locations.append(location)
        try? await store.write(locations)
    }

    public func update(_ location: LocalLocation) async {
        if let index = locations.firstIndex(where: { $0.id == location.id }) {
            locations[index] = location
            try? await store.write(locations)
        }
    }

    public func delete(id: String) async {
        locations.removeAll { $0.id == id }
        try? await store.write(locations)
    }

    public func resetToDefaults() async {
        self.locations = LocalLocation.defaults
        try? await store.write(self.locations)
    }

    public func move(from source: IndexSet, to destination: Int) async {
        locations.move(fromOffsets: source, toOffset: destination)
        try? await store.write(locations)
    }
}
