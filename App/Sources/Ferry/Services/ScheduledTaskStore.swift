import FerryCore
import Foundation
import Observation

/// 定时计划任务存储服务（持久化至 ~/Library/Application Support/Ferry/scheduled_tasks.json）
@Observable
@MainActor
public final class ScheduledTaskStore {
    public static let shared = ScheduledTaskStore()

    public private(set) var tasks: [ScheduledTask] = []

    private let store: Store<[ScheduledTask]>

    public init(storeURL: URL? = nil) {
        let resolvedURL: URL
        if let storeURL {
            resolvedURL = storeURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let ferryDir = appSupport.appendingPathComponent("Ferry", isDirectory: true)
            resolvedURL = ferryDir.appendingPathComponent("scheduled_tasks.json")
        }
        self.store = Store<[ScheduledTask]>(url: resolvedURL)
        Task {
            await load()
        }
    }

    public func load() async {
        do {
            if let persisted = try await store.read() {
                self.tasks = persisted
            } else {
                self.tasks = []
            }
        } catch {
            self.tasks = []
        }
    }

    public func upsert(_ task: ScheduledTask) async {
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index] = task
        } else {
            tasks.append(task)
        }
        try? await store.write(tasks)
    }

    public func delete(id: UUID) async {
        tasks.removeAll { $0.id == id }
        try? await store.write(tasks)
    }

    public func toggleEnabled(id: UUID) async {
        if let index = tasks.firstIndex(where: { $0.id == id }) {
            var updated = tasks[index]
            updated.isEnabled.toggle()
            if updated.isEnabled {
                updated.nextRunTime = ScheduledTask.calculateNextRunTime(for: updated.frequency, from: Date())
            }
            tasks[index] = updated
            try? await store.write(tasks)
        }
    }
}
