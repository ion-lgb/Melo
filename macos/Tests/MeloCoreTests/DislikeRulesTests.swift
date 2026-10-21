import XCTest
@testable import MeloCore

final class DislikeRulesTests: XCTestCase {
    private func music(name: String, singer: String) -> MusicInfo {
        MusicInfo(id: "\(name)_\(singer)", name: name, singer: singer, source: "kw", interval: nil,
                  meta: .object([:]))
    }

    func testParseRulesText() {
        let rules = DislikeRules(rulesText: """
        晴天@周杰伦
        夜曲
        @陈奕迅
        #重要的人@某人
        """)
        XCTAssertEqual(rules.names.count, 2, "含空行/重复应去重")
        XCTAssertTrue(rules.musicNames.contains("夜曲"))
        XCTAssertTrue(rules.singerNames.contains("陈奕迅"))
        XCTAssertEqual(rules.count, 4)
        XCTAssertTrue(rules.rulesText.contains("晴天@周杰伦"))
        XCTAssertTrue(rules.rulesText.contains("@陈奕迅"))
        XCTAssertTrue(rules.rulesText.contains("#重要的人@某人"))
    }

    func testMatches() {
        let rules = DislikeRules(rulesText: "晴天@周杰伦\n夜曲\n@陈奕迅")
        XCTAssertTrue(rules.matches(music(name: "晴天", singer: "周杰伦")))
        XCTAssertFalse(rules.matches(music(name: "晴天", singer: "其他")))
        XCTAssertTrue(rules.matches(music(name: "任意歌", singer: "陈奕迅")))
        XCTAssertTrue(rules.matches(music(name: "夜曲", singer: "任意")))
        XCTAssertFalse(rules.matches(music(name: "稻香", singer: "周杰伦")))
    }

    func testAliasAtInName() {
        let rules = DislikeRules(rulesText: "#A@B")
        // 「#A」代表字面名称为 "@A"
        XCTAssertTrue(rules.matches(music(name: "@A", singer: "B")))
        XCTAssertFalse(rules.matches(music(name: "@A", singer: "C")))
    }

    func testFilterAndEmpty() {
        let rules = DislikeRules(rulesText: "夜曲")
        let list = [music(name: "夜曲", singer: "x"), music(name: "晴天", singer: "y")]
        XCTAssertEqual(rules.filter(list).map(\.name), ["晴天"])
        XCTAssertTrue(DislikeRules().isEmpty)
        XCTAssertEqual(DislikeRules().filter(list).count, 2)
    }

    func testToDislikeInfosRoundTrip() {
        let rules = DislikeRules(rulesText: "晴天@周杰伦\n@陈奕迅")
        let infos = rules.toDislikeInfos()
        XCTAssertEqual(infos.count, 2)
        let restored = DislikeRules(dislikes: infos)
        XCTAssertTrue(restored.matches(music(name: "晴天", singer: "周杰伦")))
        XCTAssertTrue(restored.matches(music(name: "某歌", singer: "陈奕迅")))
    }

    func testProxySettingsValidation() {
        XCTAssertFalse(ProxySettings().isValid)
        XCTAssertFalse(ProxySettings(enabled: true, host: "", port: 8080).isValid)
        XCTAssertFalse(ProxySettings(enabled: true, host: "127.0.0.1", port: 0).isValid)
        XCTAssertTrue(ProxySettings(enabled: true, host: "127.0.0.1", port: 7890).isValid)
    }
}
