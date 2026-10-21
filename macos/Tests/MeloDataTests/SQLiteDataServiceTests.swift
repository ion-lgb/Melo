import XCTest
@testable import MeloData
import MeloCore

/// MeloData 数据层测试：
/// - 建库（原版 9 表 3 索引 + db_info version=2 + WAL）
/// - 老库（version 1）迁移，不重建用户数据
/// - 列表/歌曲 CRUD、order 算法、事务
/// - 歌词 base64 兼容、URL 缓存、meta 字段保真、下载任务/不喜欢
/// - 重复打开不重建、结构差异只告警
final class SQLiteDataServiceTests: XCTestCase {
    // MARK: - 临时目录

    private struct TempEnvironment {
        let root: URL
        let dataDirectory: URL

        init() throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("MeloDataTests-\(UUID().uuidString)", isDirectory: true)
            let dataDirectory = root.appendingPathComponent("LxDatas", isDirectory: true)
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
            self.root = root
            self.dataDirectory = dataDirectory
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeMusic(
        id: String,
        name: String,
        singer: String = "测试歌手",
        source: String = "kw",
        interval: String? = "03:20",
        meta: JSONValue? = nil
    ) -> MusicInfo {
        MusicInfo(
            id: id,
            name: name,
            singer: singer,
            source: source,
            interval: interval,
            meta: meta ?? .object(["songId": .string(id), "albumName": .string("测试专辑")])
        )
    }

    @MainActor
    private func insertRows(_ service: SQLiteDataService, sql: String, values: [SQLiteValue]) throws {
        try service.withRawDatabase { database in
            let statement = try database.prepare(sql)
            try statement.execute(values)
        }
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

    @MainActor
    private func rawScalarInt(
        _ service: SQLiteDataService,
        _ sql: String,
        _ values: [SQLiteValue] = []
    ) throws -> Int64? {
        try service.withRawDatabase { database in
            try database.scalarInt(sql, values)
        }
    }

    /// `my_list_music_info_order` 中每首歌的 order 值（用于精确断言排序算法）
    @MainActor
    private func orderValues(_ service: SQLiteDataService, listId: String) throws -> [String: Int] {
        try service.withRawDatabase { database in
            let statement = try database.prepare("""
                SELECT "musicInfoId", "order" FROM "main"."my_list_music_info_order" WHERE "listId"=?
                """)
            try statement.bind([.text(listId)])
            var result: [String: Int] = [:]
            while try statement.step() {
                result[statement.text(0) ?? ""] = statement.int(1)
            }
            return result
        }
    }

    // MARK: - 1. 建库

    @MainActor
    func testBootstrapCreatesOriginalSchema() async throws {
        let environment = try TempEnvironment()
        defer { environment.cleanUp() }
        let service = SQLiteDataService(dataDirectory: environment.dataDirectory)

        try service.bootstrap()

        XCTAssertTrue(service.isBootstrapped)
        XCTAssertEqual(service.databasePath.lastPathComponent, "lx.data.db")
        XCTAssertTrue(FileManager.default.fileExists(atPath: service.databasePath.path))
        XCTAssertEqual(
            service.dataDirectory.standardizedFileURL,
            environment.dataDirectory.standardizedFileURL
        )

        let verification = try XCTUnwrap(service.verification)
        XCTAssertTrue(verification.isValid, verification.summary)
        XCTAssertEqual(verification.missingItems, [])
        XCTAssertEqual(verification.mismatchedItems, [])

        // 9 张表 + 3 个索引，名称与原版 tables.ts 完全一致
        let tables = try service.databaseTableNames()
        XCTAssertEqual(tables.count, 9)
        XCTAssertEqual(Set(tables), Set(DatabaseSchema.tableNames))
        XCTAssertEqual(
            Set(tables),
            Set([
                "db_info", "my_list", "my_list_music_info", "my_list_music_info_order",
                "music_info_other_source", "lyric", "music_url", "download_list", "dislike_list",
            ])
        )
        let indexes = try service.databaseIndexNames()
        XCTAssertEqual(indexes.count, 3)
        XCTAssertEqual(
            Set(indexes),
            Set(["index_my_list_music_info", "index_my_list_music_info_order", "index_music_info_other_source"])
        )

        // db_info.version = 2，WAL 模式，数据库文件完整
        XCTAssertEqual(try service.databaseVersion(), "2")
        XCTAssertEqual(try service.databaseJournalMode().lowercased(), "wal")
        XCTAssertEqual(try rawScalarText(service, "PRAGMA integrity_check;"), "ok")

        // 重复 bootstrap 幂等：不重复建表、不重复写 db_info
        try service.bootstrap()
        XCTAssertEqual(try service.databaseVersion(), "2")
        let versionRows = try rawScalarInt(
            service,
            "SELECT COUNT(*) FROM \"main\".\"db_info\" WHERE \"field_name\"='version';"
        )
        XCTAssertEqual(versionRows, 1)
        XCTAssertTrue(try XCTUnwrap(service.verification).isValid)
    }

    @MainActor
    func testDefaultDataDirectoryIsLxDatas() async throws {
        let service = SQLiteDataService()
        XCTAssertEqual(service.dataDirectory.lastPathComponent, "LxDatas")
        XCTAssertEqual(service.databasePath, service.dataDirectory.appendingPathComponent("lx.data.db"))
        if ProcessInfo.processInfo.environment["MELO_DATA_DIR"] == nil {
            XCTAssertEqual(service.dataDirectory.deletingLastPathComponent().lastPathComponent, "lx-music-desktop")
        }
        XCTAssertFalse(service.isBootstrapped)
        // 未 bootstrap 时调用 DAO 应给出明确错误
        XCTAssertThrowsError(try service.loadUserLists()) { error in
            XCTAssertEqual(error as? MeloDataError, .notBootstrapped)
        }
    }

    // MARK: - 2. 列表 CRUD / 位置

    @MainActor
    func testUserListCRUDAndPositions() async throws {
        let environment = try TempEnvironment()
        defer { environment.cleanUp() }
        let service = SQLiteDataService(dataDirectory: environment.dataDirectory)
        try service.bootstrap()

        // 创建（名称 trim、id 规则、position 递增）
        let listA = try service.createList(name: "  列表 A  ")
        let listB = try service.createList(name: "列表 B")
        let listC = try service.createList(name: "列表 C")
        XCTAssertEqual(listA.name, "列表 A")
        XCTAssertTrue(listA.id.hasPrefix("userlist_"))
        XCTAssertEqual(Set([listA.id, listB.id, listC.id]).count, 3, "同一毫秒内创建也不能出现重复 id")
        XCTAssertEqual([listA.position, listB.position, listC.position], [0, 1, 2])
        XCTAssertNil(listA.locationUpdateTime)
        XCTAssertThrowsError(try service.createList(name: "   ")) { error in
            XCTAssertEqual(error as? MeloDataError, .invalidListName)
        }

        XCTAssertEqual(try service.loadUserLists().map(\.id), [listA.id, listB.id, listC.id])

        // 重命名（trim；空名拒绝；同名允许，与原版一样由 UI 确认）
        try service.renameList(id: listB.id, name: "  新 B  ")
        XCTAssertEqual(try service.loadUserLists().map(\.name), ["列表 A", "新 B", "列表 C"])
        XCTAssertThrowsError(try service.renameList(id: listB.id, name: "  ")) { error in
            XCTAssertEqual(error as? MeloDataError, .invalidListName)
        }
        XCTAssertThrowsError(try service.renameList(id: "not_exists", name: "x")) { error in
            XCTAssertEqual(error as? MeloDataError, .listNotFound("not_exists"))
        }
        XCTAssertThrowsError(try service.renameList(id: ListIDs.default, name: "x"))

        // 移动位置：C → 首位；位置全量重排为 0..n-1；被移动列表记录 locationUpdateTime
        try service.updateListPosition(id: listC.id, position: 0)
        var lists = try service.loadUserLists()
        XCTAssertEqual(lists.map(\.id), [listC.id, listA.id, listB.id])
        XCTAssertEqual(lists.map(\.position), [0, 1, 2])
        XCTAssertNotNil(lists.first(where: { $0.id == listC.id })?.locationUpdateTime)
        XCTAssertNil(lists.first(where: { $0.id == listA.id })?.locationUpdateTime)

        // 位置越界收敛到末尾
        try service.updateListPosition(id: listC.id, position: 99)
        lists = try service.loadUserLists()
        XCTAssertEqual(lists.map(\.id), [listA.id, listB.id, listC.id])
        XCTAssertEqual(lists.map(\.position), [0, 1, 2])

        // 删除列表：级联删除歌曲与排序记录
        try service.addMusic(makeMusic(id: "kw_1", name: "歌 1"), to: listA.id, location: .bottom)
        try service.addMusic(makeMusic(id: "kw_2", name: "歌 2"), to: listA.id, location: .bottom)
        XCTAssertEqual(try service.loadMusicCounts()[listA.id], 2)
        try service.removeList(id: listA.id)
        XCTAssertEqual(try service.loadUserLists().map(\.id), [listB.id, listC.id])
        XCTAssertEqual(try service.loadMusics(listId: listA.id), [])
        XCTAssertNil(try service.loadMusicCounts()[listA.id])
        let orphanOrders = try rawScalarInt(
            service,
            "SELECT COUNT(*) FROM \"main\".\"my_list_music_info_order\" WHERE \"listId\"=?;",
            [.text(listA.id)]
        )
        XCTAssertEqual(orphanOrders, 0)
    }

    // MARK: - 3. 歌曲添加 order 算法 / 删除 / 清空 / 覆盖

    @MainActor
    func testMusicAddOrderAlgorithm() async throws {
        let environment = try TempEnvironment()
        defer { environment.cleanUp() }
        let service = SQLiteDataService(dataDirectory: environment.dataDirectory)
        try service.bootstrap()
        let list = try service.createList(name: "排序测试")

        let music1 = makeMusic(id: "kw_1", name: "歌 1")
        let music2 = makeMusic(id: "kw_2", name: "歌 2")
        let music3 = makeMusic(id: "kw_3", name: "歌 3")
        let music4 = makeMusic(id: "kw_4", name: "歌 4")

        try service.addMusic(music1, to: list.id, location: .bottom)
        try service.addMusic(music2, to: list.id, location: .bottom)
        XCTAssertEqual(try service.loadMusics(listId: list.id).map(\.id), ["kw_1", "kw_2"])
        XCTAssertEqual(try orderValues(service, listId: list.id), ["kw_1": 0, "kw_2": 1])

        // top：新歌 order=0，老歌整体顺延
        try service.addMusic(music3, to: list.id, location: .top)
        XCTAssertEqual(try service.loadMusics(listId: list.id).map(\.id), ["kw_3", "kw_1", "kw_2"])
        XCTAssertEqual(try orderValues(service, listId: list.id), ["kw_3": 0, "kw_1": 1, "kw_2": 2])

        // 重复添加被忽略（不产生 UNIQUE 冲突、不重复）
        try service.addMusic(music1, to: list.id, location: .top)
        try service.addMusic(music1, to: list.id, location: .bottom)
        XCTAssertEqual(try service.loadMusics(listId: list.id).count, 3)

        // 删除中间歌曲后 bottom 追加：取最后一首的原始 order + 1
        try service.removeMusic(ids: ["kw_2"], from: list.id)
        XCTAssertEqual(try service.loadMusics(listId: list.id).map(\.id), ["kw_3", "kw_1"])
        try service.addMusic(music4, to: list.id, location: .bottom)
        XCTAssertEqual(try service.loadMusics(listId: list.id).map(\.id), ["kw_3", "kw_1", "kw_4"])
        XCTAssertEqual(try orderValues(service, listId: list.id), ["kw_3": 0, "kw_1": 1, "kw_4": 2])

        XCTAssertTrue(try service.isMusicExist(id: "kw_4", in: list.id))
        XCTAssertFalse(try service.isMusicExist(id: "kw_2", in: list.id))
        XCTAssertFalse(try service.isMusicExist(id: "kw_1", in: "love"))

        // 不同列表互不影响（love 是内置列表，同样落库）
        try service.addMusic(music1, to: ListIDs.love, location: .top)
        XCTAssertEqual(try service.loadMusics(listId: ListIDs.love).map(\.id), ["kw_1"])
        XCTAssertEqual(try service.loadMusics(listId: list.id).count, 3)
        XCTAssertEqual(try service.loadMusicCounts(), [list.id: 3, ListIDs.love: 1])

        // 清空列表：歌曲与 order 都清掉
        try service.clearList(listId: list.id)
        XCTAssertEqual(try service.loadMusics(listId: list.id), [])
        XCTAssertEqual(try service.loadMusicCounts()[list.id], nil)
        XCTAssertEqual(try service.loadMusicCounts()[ListIDs.love], 1)
    }

    @MainActor
    func testOverwriteListDeduplicatesAndReplaces() async throws {
        let environment = try TempEnvironment()
        defer { environment.cleanUp() }
        let service = SQLiteDataService(dataDirectory: environment.dataDirectory)
        try service.bootstrap()
        let list = try service.createList(name: "覆盖测试")

        let music1 = makeMusic(id: "kw_1", name: "歌 1")
        let music2 = makeMusic(id: "kw_2", name: "歌 2")
        let music3 = makeMusic(id: "kw_3", name: "歌 3")
        let unnamed = makeMusic(id: "kw_4", name: "")

        // 重复 id / 空 name 被过滤（与原版 filterMusicList 一致），order 按最终顺序 0..n-1
        try service.overwriteList(listId: list.id, musics: [music1, music2, music2, unnamed, music3])
        XCTAssertEqual(try service.loadMusics(listId: list.id).map(\.id), ["kw_1", "kw_2", "kw_3"])
        XCTAssertEqual(try orderValues(service, listId: list.id), ["kw_1": 0, "kw_2": 1, "kw_3": 2])

        // 再次覆盖：旧数据被整体替换
        try service.overwriteList(listId: list.id, musics: [music2])
        XCTAssertEqual(try service.loadMusics(listId: list.id).map(\.id), ["kw_2"])

        // 覆盖为空 = 清空
        try service.overwriteList(listId: list.id, musics: [])
        XCTAssertEqual(try service.loadMusics(listId: list.id), [])
    }

    // MARK: - 4. meta 字段保真

    @MainActor
    func testMusicMetaRoundTripPreservesUnknownFields() async throws {
        let environment = try TempEnvironment()
        defer { environment.cleanUp() }
        let service = SQLiteDataService(dataDirectory: environment.dataDirectory)
        try service.bootstrap()
        let list = try service.createList(name: "meta")

        let meta: JSONValue = .object([
            "songId": .string("228908"),
            "albumName": .string("叶惠美"),
            "picUrl": .string("https://example.com/pic.jpg"),
            "qualitys": .array([
                .object(["type": .string("320k"), "size": .string("9.1M")]),
                .object(["type": .string("flac")]),
            ]),
            "_qualitys": .object([
                "320k": .object(["size": .string("9.1M"), "hash": .string("abc")]),
                "flac": .null,
            ]),
            "interval": .string("04:29"),
            "unknown_nested": .object([
                "list": .array([.int(1), .double(2.5), .bool(true), .null, .string("中文")]),
                "empty": .object([:]),
            ]),
            "numeric": .int(42),
        ])
        var music = makeMusic(id: "kw_meta", name: "晴天", singer: "周杰伦", interval: "04:29", meta: meta)
        music.meta = meta

        try service.addMusic(music, to: list.id, location: .bottom)
        let loaded = try XCTUnwrap(try service.loadMusics(listId: list.id).first)
        XCTAssertEqual(loaded, music, "meta（含未知字段）必须原样读回")
        XCTAssertEqual(loaded.meta["unknown_nested"]?["list"]?.arrayValue?.count, 5)
        XCTAssertEqual(loaded.meta["_qualitys"]?["320k"]?["hash"]?.stringValue, "abc")
        XCTAssertEqual(loaded.availableQualityKeys, ["320k", "flac"])

        // interval 为 nil 时存 NULL、读回 nil
        var noInterval = makeMusic(id: "kw_no_interval", name: "无时长", interval: nil)
        noInterval.interval = nil
        try service.addMusic(noInterval, to: list.id, location: .bottom)
        let loadedNoInterval = try XCTUnwrap(try service.loadMusics(listId: list.id).last)
        XCTAssertNil(loadedNoInterval.interval)

        // DB 中 meta 列是 JSON 文本，且保留未知字段
        let rawMeta = try XCTUnwrap(try rawScalarText(
            service,
            "SELECT \"meta\" FROM \"main\".\"my_list_music_info\" WHERE \"id\"='kw_meta';"
        ))
        let parsed = try XCTUnwrap(JSONValue(jsonString: rawMeta))
        XCTAssertEqual(parsed["unknown_nested"]?["list"], meta["unknown_nested"]?["list"])

        // top 添加同样不丢 meta
        let another = makeMusic(
            id: "kw_top_meta",
            name: "以父之名",
            meta: .object(["songId": .string("x"), "custom_flag": .int(7)])
        )
        try service.addMusic(another, to: list.id, location: .top)
        let topLoaded = try XCTUnwrap(try service.loadMusics(listId: list.id).first)
        XCTAssertEqual(topLoaded, another)
    }

    // MARK: - 5. 歌词（原版 base64）

    @MainActor
    func testLyricSaveAndGetUsesLegacyBase64Storage() async throws {
        let environment = try TempEnvironment()
        defer { environment.cleanUp() }
        let service = SQLiteDataService(dataDirectory: environment.dataDirectory)
        try service.bootstrap()

        let lyric = "[00:00.00]第一行\n[00:01.00]第二行"
        XCTAssertNil(try service.getLyric(musicId: "kw_1", source: "raw", type: "lyric"))

        try service.saveLyric(musicId: "kw_1", source: "raw", type: "lyric", text: lyric)
        XCTAssertEqual(try service.getLyric(musicId: "kw_1", source: "raw", type: "lyric"), lyric)

        // 再次保存 = UPSERT，不产生重复行
        let newLyric = "[00:00.00]新歌词"
        try service.saveLyric(musicId: "kw_1", source: "raw", type: "lyric", text: newLyric)
        XCTAssertEqual(try service.getLyric(musicId: "kw_1", source: "raw", type: "lyric"), newLyric)
        let rowCount = try rawScalarInt(
            service,
            "SELECT COUNT(*) FROM \"main\".\"lyric\" WHERE \"id\"='kw_1' AND \"source\"='raw' AND \"type\"='lyric';"
        )
        XCTAssertEqual(rowCount, 1)

        // 与原版一致：DB 里存的是 base64 文本
        let stored = try XCTUnwrap(try rawScalarText(
            service,
            "SELECT \"text\" FROM \"main\".\"lyric\" WHERE \"id\"='kw_1' AND \"source\"='raw' AND \"type\"='lyric';"
        ))
        XCTAssertEqual(stored, Data(newLyric.utf8).base64EncodedString())
        XCTAssertNotEqual(stored, newLyric)

        // 多类型 / 多 source 相互独立
        try service.saveLyric(musicId: "kw_1", source: "raw", type: "tlyric", text: "翻译")
        try service.saveLyric(musicId: "kw_1", source: "edited", type: "lyric", text: "编辑后的歌词")
        XCTAssertEqual(try service.getLyric(musicId: "kw_1", source: "raw", type: "tlyric"), "翻译")
        XCTAssertEqual(try service.getLyric(musicId: "kw_1", source: "edited", type: "lyric"), "编辑后的歌词")
        XCTAssertEqual(try service.getLyric(musicId: "kw_1", source: "edited", type: "tlyric"), nil)

        // 直接写入原版格式的 base64 行也能正确读取
        let legacyText = "原版歌词\r\n第二行"
        try insertRows(
            service,
            sql: "INSERT INTO \"main\".\"lyric\" (\"id\",\"source\",\"type\",\"text\") VALUES (?,?,?,?);",
            values: [
                .text("legacy_1"), .text("raw"), .text("lyric"),
                .text(Data(legacyText.utf8).base64EncodedString()),
            ]
        )
        XCTAssertEqual(try service.getLyric(musicId: "legacy_1", source: "raw", type: "lyric"), legacyText)
    }

    // MARK: - 6. URL 缓存

    @MainActor
    func testMusicURLUpsertAndIdentifierFormat() async throws {
        let environment = try TempEnvironment()
        defer { environment.cleanUp() }
        let service = SQLiteDataService(dataDirectory: environment.dataDirectory)
        try service.bootstrap()

        XCTAssertNil(try service.getMusicURL(musicId: "kw_1", quality: "320k"))

        try service.saveMusicURL(musicId: "kw_1", quality: "320k", url: "https://cdn.example.com/a.mp3")
        XCTAssertEqual(
            try service.getMusicURL(musicId: "kw_1", quality: "320k"),
            "https://cdn.example.com/a.mp3"
        )

        // 同 id 覆盖：先删后插，只保留一条
        try service.saveMusicURL(musicId: "kw_1", quality: "320k", url: "https://cdn.example.com/b.mp3")
        XCTAssertEqual(
            try service.getMusicURL(musicId: "kw_1", quality: "320k"),
            "https://cdn.example.com/b.mp3"
        )
        let count = try rawScalarInt(
            service,
            "SELECT COUNT(*) FROM \"main\".\"music_url\" WHERE \"id\"='kw_1_320k';"
        )
        XCTAssertEqual(count, 1)

        // 原版 id 规则 `${musicId}_${quality}`；不同音质互不影响
        let storedID = try rawScalarText(
            service,
            "SELECT \"id\" FROM \"main\".\"music_url\" WHERE \"url\"='https://cdn.example.com/b.mp3' LIMIT 1;"
        )
        XCTAssertEqual(storedID, "kw_1_320k")
        try service.saveMusicURL(musicId: "kw_1", quality: "flac", url: "https://cdn.example.com/a.flac")
        XCTAssertEqual(
            try service.getMusicURL(musicId: "kw_1", quality: "flac"),
            "https://cdn.example.com/a.flac"
        )
        XCTAssertEqual(
            try service.getMusicURL(musicId: "kw_1", quality: "320k"),
            "https://cdn.example.com/b.mp3"
        )
    }

    // MARK: - 7. 下载任务 / 不喜欢（读原版数据）

    @MainActor
    func testLoadDownloadTasksFromLegacyRows() async throws {
        let environment = try TempEnvironment()
        defer { environment.cleanUp() }
        let service = SQLiteDataService(dataDirectory: environment.dataDirectory)
        try service.bootstrap()

        let downloadMusic = makeMusic(
            id: "kw_download",
            name: "下载歌",
            singer: "下载歌手",
            interval: "04:00",
            meta: .object(["songId": .string("dl"), "albumName": .string("下载专辑"), "x_custom": .int(1)])
        )
        let musicInfoJSON = try XCTUnwrap(String(data: JSONEncoder().encode(downloadMusic), encoding: .utf8))

        let insertSQL = """
            INSERT INTO "main"."download_list"
            ("id", "isComplate", "status", "statusText", "progress_downloaded", "progress_total",
             "url", "quality", "ext", "fileName", "filePath", "musicInfo", "position")
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
        // 故意乱序插入，验证按 position 排序
        try insertRows(service, sql: insertSQL, values: [
            .text("kw_download"), .int(1), .text("completed"), .text("已完成"),
            .integer(1024), .integer(1024), .null, .text("320k"), .text("mp3"),
            .text("下载歌"), .text("/tmp/下载歌.mp3"), .text(musicInfoJSON), .int(1),
        ])
        try insertRows(service, sql: insertSQL, values: [
            .text("kw_download_2"), .int(0), .text("run"), .text("下载中"),
            .integer(512), .integer(1024), .text("https://cdn.example.com/dl.mp3"), .text("128k"), .text("mp3"),
            .text("下载歌2"), .text("/tmp/下载歌2.mp3"), .text(musicInfoJSON), .int(0),
        ])

        let tasks = try service.loadDownloadTasks()
        XCTAssertEqual(tasks.map(\.id), ["kw_download_2", "kw_download"])
        XCTAssertEqual(tasks[0].position, 0)
        XCTAssertFalse(tasks[0].isCompleted)
        XCTAssertEqual(tasks[0].status, "run")
        XCTAssertEqual(tasks[0].statusText, "下载中")
        XCTAssertEqual(tasks[0].progressDownloaded, 512)
        XCTAssertEqual(tasks[0].progressTotal, 1024)
        XCTAssertEqual(tasks[0].url, "https://cdn.example.com/dl.mp3")
        XCTAssertEqual(tasks[0].quality, "128k")
        XCTAssertEqual(tasks[0].ext, "mp3")
        XCTAssertEqual(tasks[0].fileName, "下载歌2")
        XCTAssertEqual(tasks[0].filePath, "/tmp/下载歌2.mp3")
        XCTAssertEqual(tasks[0].musicInfo.meta["x_custom"]?.intValue, 1)
        XCTAssertEqual(tasks[1].isCompleted, true)
        XCTAssertNil(tasks[1].url)
    }

    @MainActor
    func testLoadDislikesFromLegacyRows() async throws {
        let environment = try TempEnvironment()
        defer { environment.cleanUp() }
        let service = SQLiteDataService(dataDirectory: environment.dataDirectory)
        try service.bootstrap()

        XCTAssertEqual(try service.loadDislikes(), [])

        try insertRows(
            service,
            sql: "INSERT INTO \"main\".\"dislike_list\" (\"type\",\"content\",\"meta\") VALUES (?,?,?);",
            values: [.text("music"), .text("周杰伦@晴天"), .null]
        )
        try insertRows(
            service,
            sql: "INSERT INTO \"main\".\"dislike_list\" (\"type\",\"content\",\"meta\") VALUES (?,?,?);",
            values: [.text("music"), .text("林俊杰"), .text("{\"reason\":\"不喜欢\"}")]
        )

        let dislikes = try service.loadDislikes()
        XCTAssertEqual(dislikes.count, 2)
        XCTAssertEqual(dislikes[0].type, "music")
        XCTAssertEqual(dislikes[0].content, "周杰伦@晴天", "content 里的 @ 是原版 name/singer 分隔符，必须原样保留")
        XCTAssertNil(dislikes[0].meta)
        XCTAssertEqual(dislikes[1].content, "林俊杰")
        XCTAssertEqual(dislikes[1].meta?["reason"]?.stringValue, "不喜欢")
    }

    // MARK: - 8. 重复打开 / 结构差异不重建

    @MainActor
    func testReopenExistingDatabaseDoesNotRebuild() async throws {
        let environment = try TempEnvironment()
        defer { environment.cleanUp() }

        let first = SQLiteDataService(dataDirectory: environment.dataDirectory)
        try first.bootstrap()
        let list = try first.createList(name: "持久化列表")
        try first.addMusic(makeMusic(id: "kw_keep", name: "保留歌曲"), to: list.id, location: .bottom)
        try first.saveLyric(musicId: "kw_keep", source: "raw", type: "lyric", text: "保留歌词")
        try first.saveMusicURL(musicId: "kw_keep", quality: "320k", url: "https://cdn.example.com/keep.mp3")

        // 模拟应用重启：新实例打开同一目录
        let second = SQLiteDataService(dataDirectory: environment.dataDirectory)
        try second.bootstrap()

        XCTAssertTrue(try XCTUnwrap(second.verification).isValid)
        XCTAssertEqual(try second.databaseVersion(), "2")
        XCTAssertEqual(try second.loadUserLists().map(\.id), [list.id])
        XCTAssertEqual(try second.loadUserLists().map(\.name), ["持久化列表"])
        XCTAssertEqual(try second.loadMusics(listId: list.id).map(\.id), ["kw_keep"])
        XCTAssertEqual(try second.getLyric(musicId: "kw_keep", source: "raw", type: "lyric"), "保留歌词")
        XCTAssertEqual(
            try second.getMusicURL(musicId: "kw_keep", quality: "320k"),
            "https://cdn.example.com/keep.mp3"
        )

        // 数据行没有被重建/清空
        let musicRows = try rawScalarInt(second, "SELECT COUNT(*) FROM \"main\".\"my_list_music_info\";")
        XCTAssertEqual(musicRows, 1)
    }

    @MainActor
    func testSchemaDriftIsNotRebuilt() async throws {
        let environment = try TempEnvironment()
        defer { environment.cleanUp() }

        let first = SQLiteDataService(dataDirectory: environment.dataDirectory)
        try first.bootstrap()
        _ = try first.createList(name: "结构漂移列表")
        // 模拟用户库存在额外列/额外表（例如第三方版本修改过结构）：不允许重建用户库
        try first.withRawDatabase { database in
            try database.execute("ALTER TABLE \"main\".\"my_list\" ADD COLUMN \"customFlag\" TEXT;")
            try database.execute("CREATE TABLE \"custom_table\" (\"id\" INTEGER PRIMARY KEY, \"value\" TEXT);")
            try database.execute("INSERT INTO \"main\".\"custom_table\" (\"value\") VALUES ('keep');")
        }

        let second = SQLiteDataService(dataDirectory: environment.dataDirectory)
        try second.bootstrap() // 只告警，不重建、不抛错

        let verification = try XCTUnwrap(second.verification)
        XCTAssertFalse(verification.isValid)
        XCTAssertEqual(verification.mismatchedItems, ["my_list"])
        XCTAssertEqual(verification.missingItems, [])

        XCTAssertEqual(try second.loadUserLists().map(\.name), ["结构漂移列表"])
        XCTAssertEqual(try rawScalarText(second, "SELECT \"value\" FROM \"main\".\"custom_table\";"), "keep")
        XCTAssertEqual(try second.databaseVersion(), "2")
    }

    // MARK: - 9. 原版 v1 夹具迁移

    /// 原版 v1 建表语句（tables.ts 去掉 dislike_list，逐字复制），用于构造真实老库夹具。
    private static let legacyV1DDL = """
    CREATE TABLE "db_info" (
      "id" INTEGER NOT NULL UNIQUE,
      "field_name" TEXT,
      "field_value" TEXT,
      PRIMARY KEY("id" AUTOINCREMENT)
    );
    CREATE TABLE "my_list" (
      "id" TEXT NOT NULL,
      "name" TEXT NOT NULL,
      "source" TEXT,
      "sourceListId" TEXT,
      "position" INTEGER NOT NULL,
      "locationUpdateTime" INTEGER,
      PRIMARY KEY("id")
    );
    CREATE TABLE "my_list_music_info" (
      "id" TEXT NOT NULL,
      "listId" TEXT NOT NULL,
      "name" TEXT NOT NULL,
      "singer" TEXT NOT NULL,
      "source" TEXT NOT NULL,
      "interval" TEXT,
      "meta" TEXT NOT NULL,
      UNIQUE("id","listId")
    );
    CREATE INDEX "index_my_list_music_info" ON "my_list_music_info" (
      "id",
      "listId"
    );
    CREATE TABLE "my_list_music_info_order" (
      "listId" TEXT NOT NULL,
      "musicInfoId" TEXT NOT NULL,
      "order" INTEGER NOT NULL
    );
    CREATE INDEX "index_my_list_music_info_order" ON "my_list_music_info_order" (
      "listId",
      "musicInfoId"
    );
    CREATE TABLE "music_info_other_source" (
      "source_id" TEXT NOT NULL,
      "id" TEXT NOT NULL,
      "source" TEXT NOT NULL,
      "name" TEXT NOT NULL,
      "singer" TEXT NOT NULL,
      "meta" TEXT NOT NULL,
      "order" INTEGER NOT NULL,
      UNIQUE("source_id","id")
    );
    CREATE INDEX "index_music_info_other_source" ON "music_info_other_source" (
      "source_id",
      "id"
    );
    -- TODO  "meta" TEXT NOT NULL,
    CREATE TABLE "lyric" (
      "id" TEXT NOT NULL,
      "source" TEXT NOT NULL,
      "type" TEXT NOT NULL,
      "text" TEXT NOT NULL
    );
    CREATE TABLE "music_url" (
      "id" TEXT NOT NULL,
      "url" TEXT NOT NULL
    );
    CREATE TABLE "download_list" (
      "id" TEXT NOT NULL,
      "isComplate" INTEGER NOT NULL,
      "status" TEXT NOT NULL,
      "statusText" TEXT NOT NULL,
      "progress_downloaded" INTEGER NOT NULL,
      "progress_total" INTEGER NOT NULL,
      "url" TEXT,
      "quality" TEXT NOT NULL,
      "ext" TEXT NOT NULL,
      "fileName" TEXT NOT NULL,
      "filePath" TEXT NOT NULL,
      "musicInfo" TEXT NOT NULL,
      "position" INTEGER NOT NULL,
      PRIMARY KEY("id")
    );
    """

    /// 用原版 DDL 构造 version=1 的老库（无 dislike_list），并写入用户数据。
    private func createLegacyV1Database(at databaseURL: URL, listID: String) throws {
        let database = try SQLiteDatabase(path: databaseURL.path)
        try database.execute(Self.legacyV1DDL)
        try database.execute(
            "INSERT INTO \"main\".\"db_info\" (\"field_name\", \"field_value\") VALUES ('version', '1');"
        )

        let insertList = try database.prepare("""
            INSERT INTO "main"."my_list" ("id", "name", "source", "sourceListId", "position", "locationUpdateTime")
            VALUES (?, ?, ?, ?, ?, ?);
            """)
        try insertList.execute([
            .text(listID), .text("老版本列表"), .text("kw"), .text("123456.0"), .int(0), .integer(1_700_000_000_000),
        ])

        let legacyMeta = "{\"songId\":\"old_song\",\"albumName\":\"老专辑\",\"unknownField\":{\"k\":1}}"
        let insertMusic = try database.prepare("""
            INSERT INTO "main"."my_list_music_info" ("id", "listId", "name", "singer", "source", "interval", "meta")
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """)
        try insertMusic.execute([
            .text("kw_old_song"), .text(listID), .text("老歌"), .text("老歌手"), .text("kw"), .null, .text(legacyMeta),
        ])

        let insertOrder = try database.prepare("""
            INSERT INTO "main"."my_list_music_info_order" ("listId", "musicInfoId", "order") VALUES (?, ?, ?);
            """)
        try insertOrder.execute([.text(listID), .text("kw_old_song"), .int(0)])

        let insertLyric = try database.prepare("""
            INSERT INTO "main"."lyric" ("id", "source", "type", "text") VALUES (?, ?, ?, ?);
            """)
        try insertLyric.execute([
            .text("kw_old_song"), .text("raw"), .text("lyric"),
            .text(Data("[00:00.00]原版老歌词".utf8).base64EncodedString()),
        ])

        let insertURL = try database.prepare("""
            INSERT INTO "main"."music_url" ("id", "url") VALUES (?, ?);
            """)
        try insertURL.execute([.text("kw_old_song_320k"), .text("https://cdn.example.com/old.mp3")])
    }

    @MainActor
    func testLegacyV1DatabaseMigrationKeepsUserData() async throws {
        let environment = try TempEnvironment()
        defer { environment.cleanUp() }
        let databaseURL = environment.dataDirectory.appendingPathComponent("lx.data.db")
        let listID = "userlist_1700000000000"
        try createLegacyV1Database(at: databaseURL, listID: listID)

        let service = SQLiteDataService(dataDirectory: environment.dataDirectory)
        try service.bootstrap()

        // 迁移：version '1' → '2'，补齐 dislike_list；结构与原版对齐
        XCTAssertEqual(try service.databaseVersion(), "2")
        XCTAssertEqual(Set(try service.databaseTableNames()), Set(DatabaseSchema.tableNames))
        XCTAssertTrue(try XCTUnwrap(service.verification).isValid)
        XCTAssertEqual(try service.databaseJournalMode().lowercased(), "wal")
        XCTAssertEqual(try service.loadDislikes(), [])

        // 用户数据原样保留
        let lists = try service.loadUserLists()
        XCTAssertEqual(lists.map(\.id), [listID])
        XCTAssertEqual(lists[0].name, "老版本列表")
        XCTAssertEqual(lists[0].source, "kw")
        XCTAssertEqual(lists[0].sourceListId, "123456", "兼容 v2.3.0 之前数字 id 末尾 .0 的历史问题")
        XCTAssertEqual(lists[0].locationUpdateTime, 1_700_000_000_000)

        let musics = try service.loadMusics(listId: listID)
        XCTAssertEqual(musics.map(\.id), ["kw_old_song"])
        XCTAssertEqual(musics[0].name, "老歌")
        XCTAssertEqual(musics[0].singer, "老歌手")
        XCTAssertNil(musics[0].interval)
        XCTAssertEqual(musics[0].meta["albumName"]?.stringValue, "老专辑")
        XCTAssertEqual(musics[0].meta["unknownField"]?["k"]?.intValue, 1)

        XCTAssertEqual(try service.getLyric(musicId: "kw_old_song", source: "raw", type: "lyric"), "[00:00.00]原版老歌词")
        XCTAssertEqual(
            try service.getMusicURL(musicId: "kw_old_song", quality: "320k"),
            "https://cdn.example.com/old.mp3"
        )

        // 迁移后仍可正常写入（新老数据共存）
        let newList = try service.createList(name: "迁移后新列表")
        XCTAssertEqual(try service.loadUserLists().map(\.name), ["老版本列表", "迁移后新列表"])
        XCTAssertEqual(newList.position, 1)
    }

    // MARK: - 10. 原版 v2 夹具（完整 DDL）直接读取

    @MainActor
    func testOriginalV2DatabaseFixtureReadable() async throws {
        let environment = try TempEnvironment()
        defer { environment.cleanUp() }
        let databaseURL = environment.dataDirectory.appendingPathComponent("lx.data.db")

        // 用原版完整 DDL（tables.ts 全量，含 dislike_list）手写一个 version=2 的库
        let fixtureSQL = Self.legacyV1DDL + "\n" + """
        CREATE TABLE "dislike_list" (
          "type" TEXT NOT NULL,
          "content" TEXT NOT NULL,
          "meta" TEXT
        );
        INSERT INTO "main"."db_info" ("field_name", "field_value") VALUES ('version', '2');
        INSERT INTO "main"."my_list" ("id", "name", "source", "sourceListId", "position", "locationUpdateTime")
          VALUES ('userlist_fixture', '夹具列表', NULL, NULL, 0, NULL);
        INSERT INTO "main"."my_list_music_info" ("id", "listId", "name", "singer", "source", "interval", "meta")
          VALUES ('wy_fixture', 'userlist_fixture', '夹具歌', '夹具歌手', 'wy', '02:30', '{"songId":"1","picUrl":"https://example.com/p.jpg"}');
        INSERT INTO "main"."my_list_music_info_order" ("listId", "musicInfoId", "order")
          VALUES ('userlist_fixture', 'wy_fixture', 0);
        INSERT INTO "main"."dislike_list" ("type", "content", "meta") VALUES ('music', '某歌手', NULL);
        """
        let fixtureDatabase = try SQLiteDatabase(path: databaseURL.path)
        try fixtureDatabase.execute(fixtureSQL)

        let service = SQLiteDataService(dataDirectory: environment.dataDirectory)
        try service.bootstrap()

        // 已经是 v2 且结构一致：不迁移、不重建
        XCTAssertEqual(try service.databaseVersion(), "2")
        XCTAssertTrue(try XCTUnwrap(service.verification).isValid)
        XCTAssertEqual(try service.loadUserLists().map(\.name), ["夹具列表"])
        let musics = try service.loadMusics(listId: "userlist_fixture")
        XCTAssertEqual(musics.map(\.id), ["wy_fixture"])
        XCTAssertEqual(musics[0].picUrl, "https://example.com/p.jpg")
        XCTAssertEqual(try service.loadDislikes().map(\.content), ["某歌手"])

        // 继续写入后，老数据仍在
        try service.addMusic(makeMusic(id: "wy_new", name: "新歌"), to: "userlist_fixture", location: .top)
        XCTAssertEqual(try service.loadMusics(listId: "userlist_fixture").map(\.id), ["wy_new", "wy_fixture"])
    }
    // MARK: - 11. 拖拽排序写入（updateMusicOrder）

    @MainActor
    func testUpdateMusicOrderRewritesOrderAndKeepsMissingMusics() async throws {
        let environment = try TempEnvironment()
        defer { environment.cleanUp() }
        let service = SQLiteDataService(dataDirectory: environment.dataDirectory)
        try service.bootstrap()
        let list = try service.createList(name: "排序写入")

        for index in 1...4 {
            try service.addMusic(makeMusic(id: "kw_10\(index)", name: "歌 \(index)"), to: list.id, location: .bottom)
        }
        XCTAssertEqual(try service.loadMusics(listId: list.id).map(\.id), ["kw_101", "kw_102", "kw_103", "kw_104"])

        // 完整重排：按传入顺序，order 重写为 0..n-1
        try service.updateMusicOrder(in: list.id, orderedMusicIDs: ["kw_103", "kw_101", "kw_104", "kw_102"])
        XCTAssertEqual(try service.loadMusics(listId: list.id).map(\.id), ["kw_103", "kw_101", "kw_104", "kw_102"])
        XCTAssertEqual(
            try orderValues(service, listId: list.id),
            ["kw_103": 0, "kw_101": 1, "kw_104": 2, "kw_102": 3]
        )

        // 只传部分 id：未包含的旧歌保持原相对顺序追尾，不丢歌
        try service.updateMusicOrder(in: list.id, orderedMusicIDs: ["kw_104"])
        XCTAssertEqual(try service.loadMusics(listId: list.id).map(\.id), ["kw_104", "kw_103", "kw_101", "kw_102"])

        // 未知 id 忽略、重复 id 去重
        try service.updateMusicOrder(in: list.id, orderedMusicIDs: ["kw_102", "not_exists", "kw_102", "kw_101"])
        XCTAssertEqual(try service.loadMusics(listId: list.id).map(\.id), ["kw_102", "kw_101", "kw_104", "kw_103"])
        XCTAssertEqual(try service.loadMusics(listId: list.id).count, 4)

        // 重复调用幂等
        try service.updateMusicOrder(in: list.id, orderedMusicIDs: ["kw_101", "kw_102", "kw_103", "kw_104"])
        let firstSnapshot = try orderValues(service, listId: list.id)
        try service.updateMusicOrder(in: list.id, orderedMusicIDs: ["kw_101", "kw_102", "kw_103", "kw_104"])
        XCTAssertEqual(try orderValues(service, listId: list.id), firstSnapshot)
        XCTAssertEqual(try service.loadMusics(listId: list.id).map(\.id), ["kw_101", "kw_102", "kw_103", "kw_104"])

        // 空列表 id / 不存在的自建列表
        XCTAssertThrowsError(try service.updateMusicOrder(in: "", orderedMusicIDs: [])) { error in
            XCTAssertEqual(error as? MeloDataError, .invalidArgument("列表 id 不能为空"))
        }
        XCTAssertThrowsError(try service.updateMusicOrder(in: "ghost_list", orderedMusicIDs: ["kw_101"])) { error in
            XCTAssertEqual(error as? MeloDataError, .listNotFound("ghost_list"))
        }

        // 内置列表同样可排序（default/love/temp 不在 my_list 表）
        try service.addMusic(makeMusic(id: "kw_love_1", name: "收藏 1"), to: ListIDs.love, location: .bottom)
        try service.addMusic(makeMusic(id: "kw_love_2", name: "收藏 2"), to: ListIDs.love, location: .bottom)
        try service.updateMusicOrder(in: ListIDs.love, orderedMusicIDs: ["kw_love_2", "kw_love_1"])
        XCTAssertEqual(try service.loadMusics(listId: ListIDs.love).map(\.id), ["kw_love_2", "kw_love_1"])

        // 空列表上排序不报错（内置列表始终有效）
        try service.updateMusicOrder(in: ListIDs.default, orderedMusicIDs: [])
        XCTAssertEqual(try service.loadMusics(listId: ListIDs.default), [])
    }
    // MARK: - 12. 下载任务持久化（download_list）

    private func makeDownloadTask(
        id: String,
        status: String = "run",
        statusText: String = "下载中",
        downloaded: Int64 = 0,
        total: Int64 = 0,
        url: String? = "https://cdn.example.com/song.mp3",
        quality: String = "320k",
        ext: String = "mp3",
        fileName: String = "晴天 - 周杰伦.mp3",
        filePath: String = "/tmp/晴天 - 周杰伦.mp3",
        isCompleted: Bool = false,
        music: MusicInfo? = nil
    ) -> DownloadTaskInfo {
        let musicInfo = music ?? makeMusic(id: "kw_download", name: "下载歌", singer: "下载歌手")
        return DownloadTaskInfo(
            id: id,
            isCompleted: isCompleted,
            status: status,
            statusText: statusText,
            progressDownloaded: downloaded,
            progressTotal: total,
            url: url,
            quality: quality,
            ext: ext,
            fileName: fileName,
            filePath: filePath,
            musicInfo: musicInfo,
            position: 0
        )
    }

    @MainActor
    func testSaveDownloadTaskUpsertAndPosition() async throws {
        let environment = try TempEnvironment()
        defer { environment.cleanUp() }
        let service = SQLiteDataService(dataDirectory: environment.dataDirectory)
        try service.bootstrap()

        var music = makeMusic(id: "kw_dl", name: "下载歌", singer: "下载歌手")
        music.meta = .object([
            "songId": .string("dl_1"),
            "albumName": .string("下载专辑"),
            "unknown_field": .object(["k": .int(7)]),
        ])
        let taskA = makeDownloadTask(id: "kw_dl_320k_mp3", music: music)
        let taskB = makeDownloadTask(id: "kw_dl_128k_mp3", quality: "128k")
        let taskC = makeDownloadTask(id: "kw_dl_flac", ext: "flac", fileName: "下载歌.flac")

        try service.saveDownloadTask(taskA)
        try service.saveDownloadTask(taskB)
        try service.saveDownloadTask(taskC)

        var tasks = try service.loadDownloadTasks()
        XCTAssertEqual(tasks.map(\.id), [taskA.id, taskB.id, taskC.id])
        XCTAssertEqual(tasks.map(\.position), [0, 1, 2], "新任务 position 从 0 递增")
        XCTAssertEqual(tasks[0].quality, "320k")
        XCTAssertEqual(tasks[0].ext, "mp3")
        XCTAssertFalse(tasks[0].isCompleted)
        XCTAssertEqual(tasks[0].url, taskA.url)
        XCTAssertEqual(tasks[0].musicInfo, music, "musicInfo JSON 反序列化后应完全一致（含 meta 未知字段）")
        XCTAssertEqual(tasks[0].musicInfo.meta["unknown_field"]?["k"]?.intValue, 7)
        // isComplate 列存 0/1
        XCTAssertEqual(
            try rawScalarInt(service, "SELECT \"isComplate\" FROM \"main\".\"download_list\" WHERE \"id\"=?;", [.text(taskA.id)]),
            0
        )

        // 更新已有任务：position 保留，其余字段全量覆盖
        var updated = taskA
        updated.isCompleted = true
        updated.status = "completed"
        updated.statusText = "已完成"
        updated.progressDownloaded = 4096
        updated.progressTotal = 4096
        updated.url = "https://cdn.example.com/updated.mp3"
        try service.saveDownloadTask(updated)

        tasks = try service.loadDownloadTasks()
        XCTAssertEqual(tasks.count, 3)
        XCTAssertEqual(tasks[0].id, taskA.id)
        XCTAssertEqual(tasks[0].position, 0, "已有任务更新时 position 不变")
        XCTAssertTrue(tasks[0].isCompleted)
        XCTAssertEqual(tasks[0].status, "completed")
        XCTAssertEqual(tasks[0].statusText, "已完成")
        XCTAssertEqual(tasks[0].progressDownloaded, 4096)
        XCTAssertEqual(tasks[0].progressTotal, 4096)
        XCTAssertEqual(tasks[0].url, "https://cdn.example.com/updated.mp3")
        XCTAssertEqual(tasks[0].musicInfo, music)
        XCTAssertEqual(
            try rawScalarInt(service, "SELECT \"isComplate\" FROM \"main\".\"download_list\" WHERE \"id\"=?;", [.text(taskA.id)]),
            1
        )

        // 重复保存幂等：不新增行、position 不变
        try service.saveDownloadTask(updated)
        try service.saveDownloadTask(updated)
        tasks = try service.loadDownloadTasks()
        XCTAssertEqual(tasks.count, 3)
        XCTAssertEqual(tasks.map(\.position), [0, 1, 2])

        // 删除中间行后新增：position = 当前最大值 + 1
        try service.removeDownloadTasks(ids: [taskB.id])
        let taskD = makeDownloadTask(id: "kw_dl_192k_mp3", quality: "192k")
        try service.saveDownloadTask(taskD)
        tasks = try service.loadDownloadTasks()
        XCTAssertEqual(tasks.map(\.id), [taskA.id, taskC.id, taskD.id])
        XCTAssertEqual(tasks.map(\.position), [0, 2, 3], "删除后留下空位，新任务取 max(position)+1")

        // url 为 NULL 时读回 nil
        let noURLTask = makeDownloadTask(id: "kw_no_url", url: nil)
        try service.saveDownloadTask(noURLTask)
        let noURL = try XCTUnwrap(try service.loadDownloadTasks().first(where: { $0.id == noURLTask.id }))
        XCTAssertNil(noURL.url)
    }

    @MainActor
    func testRemoveDownloadTasks() async throws {
        let environment = try TempEnvironment()
        defer { environment.cleanUp() }
        let service = SQLiteDataService(dataDirectory: environment.dataDirectory)
        try service.bootstrap()

        let taskA = makeDownloadTask(id: "dl_a")
        let taskB = makeDownloadTask(id: "dl_b")
        let taskC = makeDownloadTask(id: "dl_c")
        for task in [taskA, taskB, taskC] { try service.saveDownloadTask(task) }

        // 空数组直接返回
        try service.removeDownloadTasks(ids: [])
        XCTAssertEqual(try service.loadDownloadTasks().count, 3)

        try service.removeDownloadTasks(ids: [taskA.id, taskC.id])
        XCTAssertEqual(try service.loadDownloadTasks().map(\.id), [taskB.id])

        // 不存在的 id 不报错
        try service.removeDownloadTasks(ids: ["not_exists"])
        XCTAssertEqual(try service.loadDownloadTasks().map(\.id), [taskB.id])
    }

    @MainActor
    func testClearCompletedDownloadTasks() async throws {
        let environment = try TempEnvironment()
        defer { environment.cleanUp() }
        let service = SQLiteDataService(dataDirectory: environment.dataDirectory)
        try service.bootstrap()

        var completedA = makeDownloadTask(id: "dl_completed_a", isCompleted: true)
        completedA.status = "completed"
        completedA.statusText = "已完成"
        let pending = makeDownloadTask(id: "dl_pending")
        var completedC = makeDownloadTask(id: "dl_completed_c", isCompleted: true)
        completedC.status = "completed"
        completedC.statusText = "已完成"
        for task in [completedA, pending, completedC] { try service.saveDownloadTask(task) }
        XCTAssertEqual(try service.loadDownloadTasks().count, 3)

        try service.clearCompletedDownloadTasks()
        let remaining = try service.loadDownloadTasks()
        XCTAssertEqual(remaining.map(\.id), [pending.id], "只删除 isComplate=1 的任务")
        XCTAssertEqual(remaining.map(\.position), [1], "未完成任务 position 保留")

        // 没有已完成任务时再次调用不报错
        try service.clearCompletedDownloadTasks()
        XCTAssertEqual(try service.loadDownloadTasks().map(\.id), [pending.id])
    }
    // MARK: - 13. 歌词删除（edited 回退 raw）

    @MainActor
    func testRemoveLyricDeletesOnlyTargetedRowAndToleratesMissing() async throws {
        let environment = try TempEnvironment()
        defer { environment.cleanUp() }
        let service = SQLiteDataService(dataDirectory: environment.dataDirectory)
        try service.bootstrap()

        try service.saveLyric(musicId: "kw_1", source: "raw", type: "lyric", text: "原版歌词")
        try service.saveLyric(musicId: "kw_1", source: "edited", type: "lyric", text: "用户编辑歌词")
        try service.saveLyric(musicId: "kw_1", source: "edited", type: "tlyric", text: "用户编辑翻译")
        try service.saveLyric(musicId: "kw_2", source: "edited", type: "lyric", text: "另一首歌")

        // 删除 edited/lyric：edited 回退消失，raw 仍在，其它歌曲/类型不受影响
        try service.removeLyric(musicId: "kw_1", source: "edited", type: "lyric")
        XCTAssertNil(try service.getLyric(musicId: "kw_1", source: "edited", type: "lyric"))
        XCTAssertEqual(try service.getLyric(musicId: "kw_1", source: "raw", type: "lyric"), "原版歌词")
        XCTAssertEqual(try service.getLyric(musicId: "kw_1", source: "edited", type: "tlyric"), "用户编辑翻译")
        XCTAssertEqual(try service.getLyric(musicId: "kw_2", source: "edited", type: "lyric"), "另一首歌")
        // 只剩 raw 一行
        let remaining = try rawScalarInt(
            service,
            "SELECT COUNT(*) FROM \"main\".\"lyric\" WHERE \"id\"='kw_1' AND \"source\"='edited';"
        )
        XCTAssertEqual(remaining, 1, "只删除指定 type，edited/tlyric 保留")

        // 不存在的记录删除不抛错（幂等）
        try service.removeLyric(musicId: "kw_1", source: "edited", type: "lyric")
        try service.removeLyric(musicId: "not_exists", source: "edited", type: "lyric")
        try service.removeLyric(musicId: "kw_1", source: "raw", type: "rlyric")

        // 空参数报 invalidArgument
        XCTAssertThrowsError(try service.removeLyric(musicId: "", source: "edited", type: "lyric")) { error in
            guard case .invalidArgument = error as? MeloDataError else {
                return XCTFail("应抛 invalidArgument，实际：\(error)")
            }
        }
        XCTAssertThrowsError(try service.removeLyric(musicId: "kw_1", source: "", type: "lyric"))
        XCTAssertThrowsError(try service.removeLyric(musicId: "kw_1", source: "edited", type: ""))
    }
}
