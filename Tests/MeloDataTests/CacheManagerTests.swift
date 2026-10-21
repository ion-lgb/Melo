import XCTest
@testable import MeloData
import MeloCore

/// 缓存统计/清理测试：字段统计、只清指定类别、核心数据文件不动、未知类别/空目录处理、符号链接安全。
final class CacheManagerTests: XCTestCase {
    private var tempDirectory: URL!
    private var dataDirectory: URL!
    private var effectsDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeloDataCacheTests-\(UUID().uuidString)", isDirectory: true)
        dataDirectory = tempDirectory.appendingPathComponent("LxDatas", isDirectory: true)
        effectsDirectory = tempDirectory.appendingPathComponent("EffectsAudio", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: effectsDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory { try? FileManager.default.removeItem(at: tempDirectory) }
        try super.tearDownWithError()
    }

    @discardableResult
    private func writeFile(_ size: Int, relativeTo root: URL, path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(repeating: 0x5A, count: size).write(to: url)
        return url
    }

    private func makeManager() -> CacheManager {
        CacheManager(dataDirectory: dataDirectory, effectsCacheDirectory: effectsDirectory)
    }

    // MARK: - 统计

    @MainActor
    func testCategoriesRecursivelyCountSizeAndFiles() async throws {
        // covers：3 个文件（含子目录），共 175 字节
        try writeFile(100, relativeTo: dataDirectory, path: "covers/a.jpg")
        try writeFile(50, relativeTo: dataDirectory, path: "covers/sub/b.png")
        try writeFile(25, relativeTo: dataDirectory, path: "covers/sub/deeper/c.webp")
        // effects：2 个文件共 30 字节
        try writeFile(10, relativeTo: effectsDirectory, path: "effect_1.bin")
        try writeFile(20, relativeTo: effectsDirectory, path: "sub/effect_2.bin")
        // 核心数据文件（不在任何缓存类别内）
        try writeFile(11, relativeTo: dataDirectory, path: "lx.data.db")
        try writeFile(22, relativeTo: dataDirectory, path: "config_v2.json")
        try writeFile(33, relativeTo: dataDirectory, path: "user_api.json")

        let manager = makeManager()
        let categories = manager.categories()
        XCTAssertEqual(categories.map(\.id), ["covers", "effectAudio", "downloadTemp"])

        let covers = try XCTUnwrap(categories.first { $0.id == "covers" })
        XCTAssertEqual(covers.name, "本地音乐封面")
        XCTAssertEqual(covers.path.standardizedFileURL.path, dataDirectory.appendingPathComponent("covers").standardizedFileURL.path)
        XCTAssertEqual(covers.sizeBytes, 175)
        XCTAssertEqual(covers.fileCount, 3)
        XCTAssertFalse(covers.displaySize.isEmpty)

        let effects = try XCTUnwrap(categories.first { $0.id == "effectAudio" })
        XCTAssertEqual(effects.name, "音效/混响缓存")
        XCTAssertEqual(effects.sizeBytes, 30)
        XCTAssertEqual(effects.fileCount, 2)

        // downloadTemp：目录不存在 → 0/0，但类别仍列出
        let downloadTemp = try XCTUnwrap(categories.first { $0.id == "downloadTemp" })
        XCTAssertEqual(downloadTemp.sizeBytes, 0)
        XCTAssertEqual(downloadTemp.fileCount, 0)

        XCTAssertEqual(manager.totalSizeBytes(), 205)
        XCTAssertEqual(manager.category(id: "covers"), covers)
        XCTAssertNil(manager.category(id: "unknown"))
    }

    // MARK: - 清理

    @MainActor
    func testClearOnlyRemovesTargetCategoryAndKeepsCoreData() async throws {
        try writeFile(100, relativeTo: dataDirectory, path: "covers/a.jpg")
        try writeFile(50, relativeTo: dataDirectory, path: "covers/sub/b.png")
        try writeFile(30, relativeTo: effectsDirectory, path: "effect_1.bin")
        let db = try writeFile(11, relativeTo: dataDirectory, path: "lx.data.db")
        let config = try writeFile(22, relativeTo: dataDirectory, path: "config_v2.json")
        let userAPI = try writeFile(33, relativeTo: dataDirectory, path: "user_api.json")
        let theme = try writeFile(44, relativeTo: dataDirectory, path: "theme.json")
        let hotKey = try writeFile(55, relativeTo: dataDirectory, path: "hot_key.json")

        let manager = makeManager()
        let freed = try manager.clear(categoryID: "covers")
        XCTAssertEqual(freed, 150, "返回清理前统计的字节数")

        // covers 目录保留但内容清空
        let coversPath = dataDirectory.appendingPathComponent("covers").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: coversPath), "clear 必须保留目录本身")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: coversPath), [])
        let coversAfter = try XCTUnwrap(manager.category(id: "covers"))
        XCTAssertEqual(coversAfter.sizeBytes, 0)
        XCTAssertEqual(coversAfter.fileCount, 0)

        // 其它类别与核心数据不受影响
        let effectsAfter = try XCTUnwrap(manager.category(id: "effectAudio"))
        XCTAssertEqual(effectsAfter.sizeBytes, 30)
        for coreFile in [db, config, userAPI, theme, hotKey] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: coreFile.path), "核心数据不能被清理：\(coreFile.lastPathComponent)")
        }

        // 清理 effects 全量
        let effectsFreed = try manager.clear(categoryID: "effectAudio")
        XCTAssertEqual(effectsFreed, 30)
        XCTAssertEqual(manager.category(id: "effectAudio")?.sizeBytes, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: effectsDirectory.path))

        XCTAssertEqual(manager.totalSizeBytes(), 0)
    }

    @MainActor
    func testClearUnknownCategoryThrows() async throws {
        let manager = makeManager()
        XCTAssertThrowsError(try manager.clear(categoryID: "unknown")) { error in
            XCTAssertEqual(error as? CacheManagerError, .unknownCategory("unknown"))
        }
        XCTAssertThrowsError(try manager.clear(categoryID: "")) { error in
            XCTAssertEqual(error as? CacheManagerError, .unknownCategory(""))
        }
    }

    @MainActor
    func testClearMissingOrEmptyDirectoryReturnsZero() async throws {
        let manager = makeManager()
        // covers 目录尚不存在
        XCTAssertFalse(FileManager.default.fileExists(atPath: dataDirectory.appendingPathComponent("covers").path))
        XCTAssertEqual(try manager.clear(categoryID: "covers"), 0)
        // 不存在的目录不会被创建
        XCTAssertFalse(FileManager.default.fileExists(atPath: dataDirectory.appendingPathComponent("covers").path))

        // 空目录
        let emptyDirectory = dataDirectory.appendingPathComponent("covers", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyDirectory, withIntermediateDirectories: true)
        XCTAssertEqual(try manager.clear(categoryID: "covers"), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: emptyDirectory.path))
    }

    // MARK: - 符号链接安全

    @MainActor
    func testStatisticsAndClearSkipSymbolicLinks() async throws {
        let coreFile = try writeFile(4096, relativeTo: dataDirectory, path: "lx.data.db")
        let coversDirectory = dataDirectory.appendingPathComponent("covers", isDirectory: true)
        try FileManager.default.createDirectory(at: coversDirectory, withIntermediateDirectories: true)
        try writeFile(10, relativeTo: dataDirectory, path: "covers/real.jpg")
        // 指向核心数据文件的符号链接：不能被统计进大小，也不能在 clear 时顺着链接删除目标
        try FileManager.default.createSymbolicLink(
            at: coversDirectory.appendingPathComponent("link-to-db.jpg"),
            withDestinationURL: coreFile
        )

        let manager = makeManager()
        let covers = try XCTUnwrap(manager.category(id: "covers"))
        XCTAssertEqual(covers.sizeBytes, 10, "符号链接不应计入统计")
        XCTAssertEqual(covers.fileCount, 1)

        let freed = try manager.clear(categoryID: "covers")
        XCTAssertEqual(freed, 10)
        XCTAssertTrue(FileManager.default.fileExists(atPath: coreFile.path), "符号链接清理不能删除链接目标")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: coversDirectory.appendingPathComponent("link-to-db.jpg").path)
        )
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: coversDirectory.path), [])
    }

    // MARK: - 默认音效缓存目录

    @MainActor
    func testDefaultEffectsDirectoryUnderCaches() async throws {
        let manager = CacheManager(dataDirectory: dataDirectory)
        let path = manager.effectsCacheDirectory.standardizedFileURL.path
        XCTAssertTrue(path.hasSuffix("Melo/EffectsAudio"), "默认音效缓存目录应为 ~/Library/Caches/Melo/EffectsAudio，实际：\(path)")
        XCTAssertTrue(manager.categories().contains { $0.id == "effectAudio" })
    }
}
