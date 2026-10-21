import XCTest
@testable import MeloData
import MeloCore

/// 不喜欢歌曲规则持久化测试（dislike_list 表：save/add/clear + 与 loadDislikes 兼容）。
final class DislikeRulesStoreTests: XCTestCase {
    private struct TempEnvironment {
        let root: URL
        let dataDirectory: URL

        init() throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("MeloDataDislikeTests-\(UUID().uuidString)", isDirectory: true)
            let dataDirectory = root.appendingPathComponent("LxDatas", isDirectory: true)
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
            self.root = root
            self.dataDirectory = dataDirectory
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    @MainActor
    private func makeService(in environment: TempEnvironment) throws -> SQLiteDataService {
        let service = SQLiteDataService(dataDirectory: environment.dataDirectory)
        try service.bootstrap()
        return service
    }

    @MainActor
    private func contents(_ service: SQLiteDataService) throws -> [String] {
        try service.loadDislikes().map(\.content)
    }

    @MainActor
    private func rawScalarText(
        _ service: SQLiteDataService,
        _ sql: String,
        _ values: [SQLiteValue] = []
    ) throws -> String? {
        try service.withRawDatabase { database in
            try database.scalarText(sql, values)
        }
    }

    // MARK: - save 往返 / 覆盖 / 清空

    @MainActor
    func testSaveAndLoadRoundTripWithChineseAndSpecialCharacters() async throws {
        let environment = try TempEnvironment()
        defer { environment.cleanUp() }
        let service = try makeService(in: environment)

        // `#` 在用户规则里代表字面 `@`：持久化层原样保存，不转换（解析由 MeloCore DislikeRules 负责）
        let text = "周杰伦@晴天\n林俊杰\n@陈奕迅\nAC#DC@歌手\n  前导空白后导空白  \n\n"
        try service.saveDislikeRulesText(text)

        let loaded = try service.loadDislikes()
        XCTAssertEqual(loaded.map(\.content), [
            "周杰伦@晴天",
            "林俊杰",
            "@陈奕迅",
            "AC#DC@歌手",
            "前导空白后导空白",
        ], "按行 trim、跳空行、保持顺序、原始文本不转换")
        XCTAssertEqual(loaded.map(\.type), Array(repeating: "music", count: 5))
        XCTAssertTrue(loaded.allSatisfy { $0.meta == nil })
        // 与原版 DB 一致（statements.ts: INSERT ... VALUES ('music', @content)）
        XCTAssertEqual(
            try rawScalarText(service, "SELECT \"type\" FROM \"main\".\"dislike_list\" LIMIT 1;"),
            "music"
        )
        // 空行不产生记录
        XCTAssertEqual(try contents(service).count, 5)
    }

    @MainActor
    func testSaveOverwritesPreviousRulesAndIsIdempotent() async throws {
        let environment = try TempEnvironment()
        defer { environment.cleanUp() }
        let service = try makeService(in: environment)

        try service.saveDislikeRulesText("旧规则1\n旧规则2")
        XCTAssertEqual(try contents(service), ["旧规则1", "旧规则2"])

        try service.saveDislikeRulesText("新规则A\n新规则B\n新规则C")
        XCTAssertEqual(try contents(service), ["新规则A", "新规则B", "新规则C"], "save 是整表覆盖")

        // 重复保存同一文本：幂等（行数/顺序不变）
        let firstLoad = try service.loadDislikes()
        try service.saveDislikeRulesText("新规则A\n新规则B\n新规则C")
        try service.saveDislikeRulesText("新规则A\n新规则B\n新规则C")
        XCTAssertEqual(try service.loadDislikes(), firstLoad)
        XCTAssertEqual(try contents(service).count, 3)
    }

    @MainActor
    func testEmptyTextClearsAllRules() async throws {
        let environment = try TempEnvironment()
        defer { environment.cleanUp() }
        let service = try makeService(in: environment)

        try service.saveDislikeRulesText("规则1\n规则2")
        XCTAssertEqual(try contents(service).count, 2)

        try service.saveDislikeRulesText("")
        XCTAssertEqual(try service.loadDislikes(), [])

        try service.saveDislikeRulesText("规则1")
        try service.saveDislikeRulesText("   \n\t\n\r\n  ")
        XCTAssertEqual(try service.loadDislikes(), [], "只有空白行等价于清空")
    }

    // MARK: - add 四种组合

    @MainActor
    func testAddDislikeMusicFourCombinations() async throws {
        let environment = try TempEnvironment()
        defer { environment.cleanUp() }
        let service = try makeService(in: environment)

        try service.addDislikeMusic(name: "晴天", singer: "周杰伦") // name@singer
        try service.addDislikeMusic(name: "只有歌名", singer: "")     // 仅 name
        try service.addDislikeMusic(name: "", singer: "只有歌手")     // 仅 singer
        try service.addDislikeMusic(name: "", singer: "")            // 都空：不插入
        try service.addDislikeMusic(name: "   ", singer: "  \n ")    // 空白 trim 后都空：不插入

        XCTAssertEqual(try contents(service), [
            "晴天@周杰伦",
            "只有歌名",
            "@只有歌手",
        ])
        XCTAssertEqual(try service.loadDislikes().map(\.type), ["music", "music", "music"])

        // add 为追加：允许重复行（去重由上层规则文本处理）
        try service.addDislikeMusic(name: "晴天", singer: "周杰伦")
        XCTAssertEqual(try contents(service), [
            "晴天@周杰伦",
            "只有歌名",
            "@只有歌手",
            "晴天@周杰伦",
        ])
    }

    @MainActor
    func testAddTrimsWhitespace() async throws {
        let environment = try TempEnvironment()
        defer { environment.cleanUp() }
        let service = try makeService(in: environment)

        try service.addDislikeMusic(name: "  晴天  ", singer: "  周杰伦  ")
        try service.addDislikeMusic(name: " 只有歌名 ", singer: " ")
        try service.addDislikeMusic(name: " ", singer: " 只有歌手 ")
        XCTAssertEqual(try contents(service), ["晴天@周杰伦", "只有歌名", "@只有歌手"])
    }

    // MARK: - clear

    @MainActor
    func testClearDislikes() async throws {
        let environment = try TempEnvironment()
        defer { environment.cleanUp() }
        let service = try makeService(in: environment)

        try service.saveDislikeRulesText("规则1\n规则2")
        try service.addDislikeMusic(name: "新歌", singer: "新歌手")
        XCTAssertEqual(try contents(service).count, 3)

        try service.clearDislikes()
        XCTAssertEqual(try service.loadDislikes(), [])

        // 空表重复清空不报错
        try service.clearDislikes()
        XCTAssertEqual(try service.loadDislikes(), [])
    }

    // MARK: - 顺序 / 空库

    @MainActor
    func testOrderMatchesLoadDislikesRowOrder() async throws {
        let environment = try TempEnvironment()
        defer { environment.cleanUp() }
        let service = try makeService(in: environment)

        try service.saveDislikeRulesText("一\n二\n三")
        try service.addDislikeMusic(name: "四", singer: "歌")
        try service.addDislikeMusic(name: "五", singer: "")
        XCTAssertEqual(try contents(service), ["一", "二", "三", "四@歌", "五"], "save 行序 + add 追加顺序与 loadDislikes 一致")
    }

    @MainActor
    func testEmptyDatabaseBehavesAndUnbootstrappedThrows() async throws {
        let environment = try TempEnvironment()
        defer { environment.cleanUp() }
        let service = try makeService(in: environment)

        XCTAssertEqual(try service.loadDislikes(), [])
        try service.clearDislikes()
        XCTAssertEqual(try service.loadDislikes(), [])

        // 未 bootstrap：需要数据库的方法应抛 notBootstrapped
        let unopened = SQLiteDataService(dataDirectory: environment.root.appendingPathComponent("OtherLxDatas"))
        XCTAssertThrowsError(try unopened.saveDislikeRulesText("规则")) { error in
            XCTAssertEqual(error as? MeloDataError, .notBootstrapped)
        }
        XCTAssertThrowsError(try unopened.addDislikeMusic(name: "歌", singer: "手")) { error in
            XCTAssertEqual(error as? MeloDataError, .notBootstrapped)
        }
        XCTAssertThrowsError(try unopened.clearDislikes()) { error in
            XCTAssertEqual(error as? MeloDataError, .notBootstrapped)
        }
    }
}
