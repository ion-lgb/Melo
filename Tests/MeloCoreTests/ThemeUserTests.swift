import XCTest
@testable import MeloCore

@MainActor
final class ThemeUserTests: XCTestCase {
    private var dataDir: URL!

    override func setUpWithError() throws {
        dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("melo-theme-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dataDir { try? FileManager.default.removeItem(at: dataDir) }
    }

    private func makeManager() -> ThemeManager {
        let settings = SettingsStore(dataDirectory: dataDir)
        return ThemeManager(resourcesDirectory: ResourceLocator.resourcesDirectory(), settings: settings, dataDirectory: dataDir)
    }

    func testCreateSaveReloadRemoveUserTheme() throws {
        let manager = makeManager()
        XCTAssertFalse(manager.builtinThemes.isEmpty)
        guard let created = manager.createUserTheme(name: "我的主题", baseThemeID: "green", overrides: [
            "--color-primary": "rgb(255, 0, 0)",
        ]) else {
            return XCTFail("createUserTheme 失败")
        }
        XCTAssertTrue(created.id.hasPrefix("custom_"))
        XCTAssertTrue(created.isCustom == true)
        XCTAssertEqual(created.name, "我的主题")
        XCTAssertEqual(created.config.themeColors["--color-primary"], "rgb(255, 0, 0)")
        // base 主题其它颜色应被继承
        XCTAssertNotNil(created.config.themeColors["--color-500"])

        try manager.saveUserTheme(created)
        let storeURL = dataDir.appendingPathComponent("theme.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path))

        // 新 manager 从 theme.json 读回
        let reloaded = makeManager()
        XCTAssertTrue(reloaded.userThemes.contains { $0.id == created.id })
        XCTAssertEqual(reloaded.theme(id: created.id)?.name, "我的主题")

        try reloaded.removeUserTheme(id: created.id)
        XCTAssertFalse(reloaded.userThemes.contains { $0.id == created.id })
        let afterRemove = makeManager()
        XCTAssertFalse(afterRemove.userThemes.contains { $0.id == created.id })
    }

    func testExportImportRoundTrip() throws {
        let manager = makeManager()
        guard let created = manager.createUserTheme(name: "导出主题", baseThemeID: "black", overrides: [
            "--color-primary": "rgb(0, 128, 255)",
        ]) else {
            return XCTFail("createUserTheme 失败")
        }
        try manager.saveUserTheme(created)
        guard let text = manager.exportThemeJSON(id: created.id) else {
            return XCTFail("导出失败")
        }
        XCTAssertTrue(text.contains("导出主题"))

        let freshDir = dataDir.appendingPathComponent("fresh", isDirectory: true)
        try FileManager.default.createDirectory(at: freshDir, withIntermediateDirectories: true)
        let settings = SettingsStore(dataDirectory: freshDir)
        let fresh = ThemeManager(resourcesDirectory: ResourceLocator.resourcesDirectory(), settings: settings, dataDirectory: freshDir)
        let imported = try fresh.importThemeJSON(text)
        XCTAssertEqual(imported.name, "导出主题")
        XCTAssertTrue(fresh.userThemes.contains { $0.id == imported.id })
        // 再次导入同 id 应生成新 id，不覆盖
        let importedAgain = try fresh.importThemeJSON(text)
        XCTAssertNotEqual(importedAgain.id, imported.id)
        XCTAssertEqual(fresh.userThemes.count, 2)
    }

    func testCreateWithUnknownBaseFallsBackOrFails() {
        let manager = makeManager()
        // 未知基础主题时回退到第一个内置主题（方法内实现为 `?? builtinThemes.first`）
        let created = manager.createUserTheme(name: "回退", baseThemeID: "does-not-exist", overrides: [:])
        XCTAssertNotNil(created)
    }

    func testInvalidThemeJSONThrows() {
        let manager = makeManager()
        XCTAssertThrowsError(try manager.importThemeJSON("not json"))
        XCTAssertThrowsError(try manager.importThemeJSON("{\"id\":\"x\"}"))
    }
}
