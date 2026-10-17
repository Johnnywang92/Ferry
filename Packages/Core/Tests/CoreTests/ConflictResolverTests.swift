import Foundation
import Testing
@testable import FerryCore

@Suite("M4: 冲突处理解析器与策略决策")
struct ConflictResolverTests {

    @Test("建议重命名算法：基础扩展名与无扩展名递增")
    func testSuggestRenameBasics() {
        let name1 = ConflictResolver.suggestRename(for: "main.css")
        #expect(name1 == "main_1.css")

        let name2 = ConflictResolver.suggestRename(for: "LICENSE")
        #expect(name2 == "LICENSE_1")

        let name3 = ConflictResolver.suggestRename(for: "archive.tar.gz")
        #expect(name3 == "archive.tar_1.gz")
    }

    @Test("建议重命名算法：避开已存在的候选名")
    func testSuggestRenameCollisionAvoidance() {
        let existing: Set<String> = ["data_1.json", "data_2.json"]
        let suggested = ConflictResolver.suggestRename(for: "data.json", existingNames: existing)
        #expect(suggested == "data_3.json")
    }

    @Test("决策解析：覆盖直接保留原路径")
    func testResolveOverwrite() {
        let item = FileConflictItem(
            fileName: "main.css",
            direction: .upload,
            sourcePath: "/local/main.css",
            sourceSize: 1024,
            sourceDate: Date(),
            destinationPath: "/remote/main.css",
            destinationSize: 2048,
            destinationDate: Date().addingTimeInterval(-60),
            suggestedRename: "main_1.css"
        )
        let outcome = ConflictResolver.resolve(item: item, decision: .overwrite)
        #expect(outcome == .proceedOriginal)
    }

    @Test("决策解析：跳过直接标记 skipped")
    func testResolveSkip() {
        let item = FileConflictItem(
            fileName: "main.css",
            direction: .upload,
            sourcePath: "/local/main.css",
            sourceSize: 1024,
            sourceDate: Date(),
            destinationPath: "/remote/main.css",
            destinationSize: 2048,
            destinationDate: Date(),
            suggestedRename: "main_1.css"
        )
        let outcome = ConflictResolver.resolve(item: item, decision: .skip)
        #expect(outcome == .skipped)
    }

    @Test("决策解析：重命名使用新名称")
    func testResolveRename() {
        let item = FileConflictItem(
            fileName: "main.css",
            direction: .upload,
            sourcePath: "/local/main.css",
            sourceSize: 1024,
            sourceDate: Date(),
            destinationPath: "/remote/main.css",
            destinationSize: 2048,
            destinationDate: Date(),
            suggestedRename: "main_1.css"
        )
        let outcome = ConflictResolver.resolve(item: item, decision: .rename(newName: "main_custom.css"))
        #expect(outcome == .proceedRenamed(newName: "main_custom.css"))
    }

    @Test("决策解析：仅在较新时覆盖（比对 mtime）")
    func testResolveOverwriteIfNewer() {
        let now = Date()
        let older = now.addingTimeInterval(-3600)

        // 场景 1: 本地较新 -> proceedOriginal
        let itemNewer = FileConflictItem(
            fileName: "app.js",
            direction: .upload,
            sourcePath: "/local/app.js",
            sourceSize: 500,
            sourceDate: now,
            destinationPath: "/remote/app.js",
            destinationSize: 500,
            destinationDate: older,
            suggestedRename: "app_1.js"
        )
        #expect(itemNewer.isSourceNewer == true)
        #expect(ConflictResolver.resolve(item: itemNewer, decision: .overwriteIfNewer) == .proceedOriginal)

        // 场景 2: 目标较新或相同 -> skipped
        let itemOlder = FileConflictItem(
            fileName: "app.js",
            direction: .upload,
            sourcePath: "/local/app.js",
            sourceSize: 500,
            sourceDate: older,
            destinationPath: "/remote/app.js",
            destinationSize: 500,
            destinationDate: now,
            suggestedRename: "app_1.js"
        )
        #expect(itemOlder.isSourceNewer == false)
        #expect(ConflictResolver.resolve(item: itemOlder, decision: .overwriteIfNewer) == .skipped)
    }
}
