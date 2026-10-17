import FerryContracts
import FerryCore
import Foundation
import Testing

@Suite("M5: 同步引擎与真值表判定")
struct SyncEngineTests {

    private func createTempDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ferry_sync_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    @Test("M5 出口标准：双端同时修改同一文件被识别为冲突")
    func testBothModifiedDetectedAsConflict() async throws {
        let localDir = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: localDir) }

        // 本地写入已修改的文件内容
        let localFile = localDir.appendingPathComponent("document.txt")
        try "Local Modified Content".write(to: localFile, atomically: true, encoding: .utf8)

        // 远端配置同样路径但内容不同的已修改文件
        let fakeFS = InMemoryFileSystem()
        let remoteBase = RemotePath(string: "/remote/project", isAbsolute: true)!
        try await fakeFS.seed([
            .text("remote/project/document.txt", "Remote Modified Different Content")
        ])

        // 建立初始一致的 base 快照（上次双方大小为 100，旧时间）
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let key = ComparisonKey(string: "document.txt", pathPolicy: .posix)
        let baseSnapshot = SyncBaseSnapshot(
            localRootPath: localDir.path,
            remoteRootPath: "/remote/project",
            entries: [
                key: SyncBaseEntry(
                    key: key,
                    relativePath: "document.txt",
                    localSize: 100,
                    localMTime: baseDate,
                    remoteSize: 100,
                    remoteMTime: baseDate,
                    remoteMTimeIsReliable: true
                )
            ]
        )

        let engine = SyncEngine()
        let plan = try await engine.computeDiffPlan(
            localRootURL: localDir,
            remoteRootPath: remoteBase,
            fileSystem: fakeFS,
            baseSnapshot: baseSnapshot
        )

        #expect(plan.conflictCount == 1)
        let item = try #require(plan.items.first { $0.relativePath == "document.txt" })
        #expect(item.action == .conflict)
        #expect(item.conflictReason == .bothModifiedContentDifferent)
    }

    @Test("真值表：本地已修改、远端未修改 -> 上行上传")
    func testLocalModifiedRemoteUnchanged() async throws {
        let localDir = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: localDir) }

        let localFile = localDir.appendingPathComponent("app.js")
        try "console.log('v2')".write(to: localFile, atomically: true, encoding: .utf8)

        let fakeFS = InMemoryFileSystem()
        let remoteBase = RemotePath(string: "/remote/project", isAbsolute: true)!
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        try await fakeFS.seed([
            InMemoryFileSystem.Seed("remote/project/app.js", kind: .file, payload: Array("v1".utf8), modification: baseDate)
        ])

        let key = ComparisonKey(string: "app.js", pathPolicy: .posix)
        let baseSnapshot = SyncBaseSnapshot(
            localRootPath: localDir.path,
            remoteRootPath: "/remote/project",
            entries: [
                key: SyncBaseEntry(
                    key: key,
                    relativePath: "app.js",
                    localSize: 2,
                    localMTime: baseDate,
                    remoteSize: 2,
                    remoteMTime: baseDate,
                    remoteMTimeIsReliable: true
                )
            ]
        )

        let engine = SyncEngine()
        let plan = try await engine.computeDiffPlan(
            localRootURL: localDir,
            remoteRootPath: remoteBase,
            fileSystem: fakeFS,
            baseSnapshot: baseSnapshot
        )

        #expect(plan.uploadCount == 1)
        let item = try #require(plan.items.first { $0.relativePath == "app.js" })
        #expect(item.action == .upload)
    }

    @Test("真值表：本地未修改、远端已修改 -> 下行下载")
    func testLocalUnchangedRemoteModified() async throws {
        let localDir = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: localDir) }

        let localFile = localDir.appendingPathComponent("styles.css")
        try "body { margin: 0; }".write(to: localFile, atomically: true, encoding: .utf8)
        let localAttrs = try FileManager.default.attributesOfItem(atPath: localFile.path)
        let localMTime = localAttrs[.modificationDate] as? Date

        let fakeFS = InMemoryFileSystem()
        let remoteBase = RemotePath(string: "/remote/project", isAbsolute: true)!
        let remoteNewDate = Date(timeIntervalSince1970: 1_700_050_000)
        try await fakeFS.seed([
            InMemoryFileSystem.Seed("remote/project/styles.css", kind: .file, payload: Array("body { margin: 10px; color: red; }".utf8), modification: remoteNewDate)
        ])

        let key = ComparisonKey(string: "styles.css", pathPolicy: .posix)
        let baseSnapshot = SyncBaseSnapshot(
            localRootPath: localDir.path,
            remoteRootPath: "/remote/project",
            entries: [
                key: SyncBaseEntry(
                    key: key,
                    relativePath: "styles.css",
                    localSize: Int64("body { margin: 0; }".utf8.count),
                    localMTime: localMTime,
                    remoteSize: 50,
                    remoteMTime: Date(timeIntervalSince1970: 1_700_000_000),
                    remoteMTimeIsReliable: true
                )
            ]
        )

        let engine = SyncEngine()
        let plan = try await engine.computeDiffPlan(
            localRootURL: localDir,
            remoteRootPath: remoteBase,
            fileSystem: fakeFS,
            baseSnapshot: baseSnapshot
        )

        #expect(plan.downloadCount == 1)
        let item = try #require(plan.items.first { $0.relativePath == "styles.css" })
        #expect(item.action == .download)
    }

    @Test("真值表：两侧同时新建且内容不同 -> 识别为冲突")
    func testBothCreatedContentDifferent() async throws {
        let localDir = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: localDir) }

        let localFile = localDir.appendingPathComponent("notes.md")
        try "Local Note".write(to: localFile, atomically: true, encoding: .utf8)

        let fakeFS = InMemoryFileSystem()
        let remoteBase = RemotePath(string: "/remote/project", isAbsolute: true)!
        try await fakeFS.seed([
            .text("remote/project/notes.md", "Remote Note That Differs In Length")
        ])

        let engine = SyncEngine()
        let plan = try await engine.computeDiffPlan(
            localRootURL: localDir,
            remoteRootPath: remoteBase,
            fileSystem: fakeFS,
            baseSnapshot: nil // 无基线快照
        )

        #expect(plan.conflictCount == 1)
        let item = try #require(plan.items.first { $0.relativePath == "notes.md" })
        #expect(item.action == .conflict)
        #expect(item.conflictReason == .bothCreatedContentDifferent)
    }

    @Test("真值表：一侧已删除而另一侧已修改 -> 识别为冲突")
    func testDeletedAndModifiedConflict() async throws {
        let localDir = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: localDir) }

        // 本地删除了 config.json，本地目录空
        let fakeFS = InMemoryFileSystem()
        let remoteBase = RemotePath(string: "/remote/project", isAbsolute: true)!
        // 远端不仅没删，反而被修改了（大小与时间改变）
        let remoteNewDate = Date(timeIntervalSince1970: 1_700_090_000)
        try await fakeFS.seed([
            InMemoryFileSystem.Seed("remote/project/config.json", kind: .file, payload: Array("{\"new\": true}".utf8), modification: remoteNewDate)
        ])

        let key = ComparisonKey(string: "config.json", pathPolicy: .posix)
        let baseSnapshot = SyncBaseSnapshot(
            localRootPath: localDir.path,
            remoteRootPath: "/remote/project",
            entries: [
                key: SyncBaseEntry(
                    key: key,
                    relativePath: "config.json",
                    localSize: 10,
                    localMTime: Date(timeIntervalSince1970: 1_700_000_000),
                    remoteSize: 10,
                    remoteMTime: Date(timeIntervalSince1970: 1_700_000_000),
                    remoteMTimeIsReliable: true
                )
            ]
        )

        let engine = SyncEngine()
        let plan = try await engine.computeDiffPlan(
            localRootURL: localDir,
            remoteRootPath: remoteBase,
            fileSystem: fakeFS,
            baseSnapshot: baseSnapshot,
            options: SyncOptions(allowDeletions: true)
        )

        #expect(plan.conflictCount == 1)
        let item = try #require(plan.items.first { $0.relativePath == "config.json" })
        #expect(item.action == .conflict)
        #expect(item.conflictReason == .deletedAndModified)
    }

    @Test("删除安全策略：默认禁止删除，开启 allowDeletions 后才建议删除")
    func testDeletionSafetyPolicy() async throws {
        let localDir = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: localDir) }

        // 本地未删
        let localFile = localDir.appendingPathComponent("old.log")
        try "log content".write(to: localFile, atomically: true, encoding: .utf8)
        let localAttrs = try FileManager.default.attributesOfItem(atPath: localFile.path)
        let localMTime = localAttrs[.modificationDate] as? Date

        // 远端已删（fakeFS 为空）
        let fakeFS = InMemoryFileSystem()
        let remoteBase = RemotePath(string: "/remote/project", isAbsolute: true)!

        let key = ComparisonKey(string: "old.log", pathPolicy: .posix)
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let baseSnapshot = SyncBaseSnapshot(
            localRootPath: localDir.path,
            remoteRootPath: "/remote/project",
            entries: [
                key: SyncBaseEntry(
                    key: key,
                    relativePath: "old.log",
                    localSize: Int64("log content".utf8.count),
                    localMTime: localMTime,
                    remoteSize: Int64("log content".utf8.count),
                    remoteMTime: baseDate,
                    remoteMTimeIsReliable: true
                )
            ]
        )

        let engine = SyncEngine()

        // 1. 默认设置（allowDeletions == false）：不产生 deleteLocal 操作
        let safePlan = try await engine.computeDiffPlan(
            localRootURL: localDir,
            remoteRootPath: remoteBase,
            fileSystem: fakeFS,
            baseSnapshot: baseSnapshot,
            options: SyncOptions(allowDeletions: false)
        )
        let safeItem = try #require(safePlan.items.first { $0.relativePath == "old.log" })
        #expect(safeItem.action == .none)

        // 2. 显式开启 allowDeletions：产生 deleteLocal 操作
        let deletePlan = try await engine.computeDiffPlan(
            localRootURL: localDir,
            remoteRootPath: remoteBase,
            fileSystem: fakeFS,
            baseSnapshot: baseSnapshot,
            options: SyncOptions(allowDeletions: true)
        )
        let deleteItem = try #require(deletePlan.items.first { $0.relativePath == "old.log" })
        #expect(deleteItem.action == .deleteLocal)
    }
}
