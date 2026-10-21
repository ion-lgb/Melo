import XCTest
@testable import MeloCore

final class ResourceTests: XCTestCase {
    private var resources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MeloCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // macos
            .appendingPathComponent("Resources")
    }

    func testThemesDecode() throws {
        let data = try Data(contentsOf: resources.appendingPathComponent("themes.json"))
        let themes = try JSONDecoder().decode([Theme].self, from: data)
        XCTAssertEqual(themes.count, 15)
        XCTAssertEqual(themes.first?.id, "green")
        XCTAssertFalse(themes.first?.config.themeColors.isEmpty ?? true)
        XCTAssertNotNil(themes.first?.config.extInfo["--color-app-background"])
    }

    func testLanguageDecode() throws {
        let data = try Data(contentsOf: resources.appendingPathComponent("lang/zh-cn.json"))
        let object = try XCTUnwrap(JSONValue(jsonData: data)?.objectValue)
        XCTAssertGreaterThan(object.count, 600)
        XCTAssertEqual(object["search"]?.stringValue, "搜索")
    }

    func testDefaultSettingsDecode() throws {
        let data = try Data(contentsOf: resources.appendingPathComponent("default-settings.json"))
        let object = try XCTUnwrap(JSONValue(jsonData: data)?.objectValue)
        XCTAssertEqual(object.count, 135)
        XCTAssertEqual(object["theme.id"]?.stringValue, "green")
        XCTAssertEqual(object["player.volume"]?.doubleValue, 1)
    }

    func testThemesBackgroundImage() throws {
        let data = try Data(contentsOf: resources.appendingPathComponent("themes.json"))
        let themes = try JSONDecoder().decode([Theme].self, from: data)
        let black = try XCTUnwrap(themes.first { $0.id == "black" })
        XCTAssertTrue(black.isDark)
        XCTAssertEqual(black.config.extInfo["--background-image"], "url(./theme_images/landingMoon.png)")
    }

    func testCSSColorParsing() {
        XCTAssertEqual(RGBAColor(css: "#4daf7c")?.r, 77)
        XCTAssertEqual(RGBAColor(css: "rgb(77, 175, 124)")?.g, 175)
        XCTAssertEqual(RGBAColor(css: "rgba(0, 0, 0, 0.5)")?.a, 0.5)
        XCTAssertNil(RGBAColor(css: "url(./theme_images/x.png)"))
    }
}
