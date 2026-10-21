import XCTest
@testable import MeloData
import MeloCore

/// 列表备份导出/导入测试（供 MeloCore.BackupService 组装原版 `.lxmc`）。
final class BackupPlaylistTests: XCTestCase {
    private struct TempEnvironment {
        let root: URL
        let dataDirectory: URL

        init() throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("MeloDataBackupTests-\(UUID().uuidString)", isDirectory: true)
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
            meta: meta ?? .object([
                "songId": .string(id),
                "albumName": .string("测试专辑"),
                "qualitys": .array([.object(["type": .string("320k")])]),
            ])
        )
    }

    @MainActor
    private func makeService(in environment: TempEnvironment) throws -> SQLiteDataService {
        let service = SQLiteDataService(dataDirectory: environment.dataDirectory)
        try service.bootstrap()
        return service
    }

    // MARK: - 导出结构 / 不含 temp

    @MainActor
    func testExportStructureIncludesDefaultLoveUserListsButNotTemp() async throws {
        let environment = try TempEnvironment()
        defer { environment.cleanUp() }
        let service = try makeService(in: environment)
        let userList = try service.createList(name: "导出列表")

        try service.addMusic(makeMusic(id: "kw_1", name: "歌 1"), to: ListIDs.default, location: .bottom)
        try service.addMusic(makeMusic(id: "kw_2", name: "歌 2"), to: ListIDs.default, location: .top)
        try service.addMusic(makeMusic(id: "wy_1", name: "收藏 1", source: "wy"), to: ListIDs.love, location: .bottom)
        try service.addMusic(makeMusic(id: "tx_1", name: "用户列表歌", source: "tx"), to: userList.id, location: .bottom)
        try service.addMusic(makeMusic(id: "temp_1", name: "临时歌"), to: ListIDs.temp, location: .bottom)
        // 用户列表附加原版字段
        try service.withRawDatabase { database in
            let statement = try database.prepare(
                "UPDATE \"main\".\"my_list\" SET \"source\"=?, \"sourceListId\"=?, \"locationUpdateTime\"=? WHERE \"id\"=?"
            )
            try statement.execute([
                .text("kg"), .text("list_42"), .integer(1_700_000_000_000), .text(userList.id),
            ])
        }

        let exported = try service.exportPlaylistsBackup()
        let entries = try XCTUnwrap(exported.arrayValue)
        XCTAssertEqual(entries.count, 3, "default + love + 1 个用户列表（不含 temp）")
        XCTAssertEqual(entries.compactMap { $0["id"]?.stringValue }, [ListIDs.default, ListIDs.love, userList.id])
        XCTAssertEqual(entries[0]["name"]?.stringValue, "试听列表")
        XCTAssertEqual(entries[1]["name"]?.stringValue, "我的收藏")
        XCTAssertEqual(entries[2]["name"]?.stringValue, "导出列表")
        XCTAssertFalse(entries.contains { $0["id"]?.stringValue == ListIDs.temp })

        // 歌曲按 order 排序：kw_2 是 top 添加的
        XCTAssertEqual(
            entries[0]["list"]?.arrayValue?.compactMap { $0["id"]?.stringValue },
            ["kw_2", "kw_1"]
        )
        XCTAssertEqual(entries[1]["list"]?.arrayValue?.compactMap { $0["id"]?.stringValue }, ["wy_1"])
        // 新结构包含 meta
        XCTAssertNotNil(entries[0]["list"]?.arrayValue?.first?["meta"])
        // 用户列表原版字段
        XCTAssertEqual(entries[2]["source"]?.stringValue, "kg")
        XCTAssertEqual(entries[2]["sourceListId"]?.stringValue, "list_42")
        XCTAssertEqual(entries[2]["locationUpdateTime"]?.intValue, Int(1_700_000_000_000))
        // 空列表也导出（list 为空数组）
        XCTAssertEqual(entries[2]["list"]?.arrayValue?.count, 1)
    }

    @MainActor
    func testExportKeepsEmptyDefaultAndLoveLists() async throws {
        let environment = try TempEnvironment()
        defer { environment.cleanUp() }
        let service = try makeService(in: environment)

        let exported = try service.exportPlaylistsBackup()
        let entries = try XCTUnwrap(exported.arrayValue)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.compactMap { $0["id"]?.stringValue }, [ListIDs.default, ListIDs.love])
        for entry in entries {
            XCTAssertEqual(entry["list"]?.arrayValue?.count, 0)
        }
    }

    // MARK: - 导出 → 新库导入 一致

    @MainActor
    func testExportImportRoundTripPreservesEverything() async throws {
        let sourceEnvironment = try TempEnvironment()
        defer { sourceEnvironment.cleanUp() }
        let source = try makeService(in: sourceEnvironment)

        let listA = try source.createList(name: "列表 A")
        let listB = try source.createList(name: "列表 B")

        try source.addMusic(makeMusic(id: "kw_1", name: "默认 1"), to: ListIDs.default, location: .bottom)
        try source.addMusic(makeMusic(id: "kw_2", name: "默认 2"), to: ListIDs.default, location: .bottom)
        try source.addMusic(makeMusic(id: "kw_3", name: "默认 3"), to: ListIDs.default, location: .top)
        try source.addMusic(makeMusic(id: "wy_1", name: "收藏 1", source: "wy"), to: ListIDs.love, location: .bottom)

        try source.addMusic(makeMusic(id: "tx_1", name: "A1", source: "tx"), to: listA.id, location: .bottom)
        let deepMeta: JSONValue = .object([
            "songId": .string("tx_2"),
            "albumName": .string("深字段专辑"),
            "qualitys": .array([.object(["type": .string("flac"), "size": .string("30M")])]),
            "unknownNested": .object(["k": .array([.int(1), .bool(true), .string("中文")])]),
        ])
        try source.addMusic(makeMusic(id: "tx_2", name: "A2", source: "tx", meta: deepMeta), to: listA.id, location: .bottom)
        try source.addMusic(makeMusic(id: "mg_1", name: "B1", source: "mg"), to: listB.id, location: .bottom)

        try source.withRawDatabase { database in
            let statement = try database.prepare(
                "UPDATE \"main\".\"my_list\" SET \"source\"=?, \"sourceListId\"=?, \"locationUpdateTime\"=? WHERE \"id\"=?"
            )
            try statement.execute([
                .text("tx"), .text("playlist_123"), .integer(1_700_000_000_000), .text(listA.id),
            ])
        }

        let exported = try source.exportPlaylistsBackup()

        let targetEnvironment = try TempEnvironment()
        defer { targetEnvironment.cleanUp() }
        let target = try makeService(in: targetEnvironment)

        let summary = try target.importPlaylistsBackup(exported)
        XCTAssertEqual(summary.lists, 4, "default + love + 2 个用户列表")
        XCTAssertEqual(summary.musics, 7, "3 + 1 + 2 + 1")
        XCTAssertEqual(summary.settingsImported, false)

        // 用户列表：名称/顺序/原版字段一致
        let importedLists = try target.loadUserLists()
        XCTAssertEqual(importedLists.map(\.id), [listA.id, listB.id])
        XCTAssertEqual(importedLists.map(\.name), ["列表 A", "列表 B"])
        XCTAssertEqual(importedLists.map(\.position), [0, 1])
        XCTAssertEqual(importedLists[0].source, "tx")
        XCTAssertEqual(importedLists[0].sourceListId, "playlist_123")
        XCTAssertEqual(importedLists[0].locationUpdateTime, 1_700_000_000_000)

        // 歌曲顺序与内容（含 meta 深字段）一致
        XCTAssertEqual(try target.loadMusics(listId: ListIDs.default).map(\.id), ["kw_3", "kw_1", "kw_2"])
        XCTAssertEqual(try target.loadMusics(listId: ListIDs.default), try source.loadMusics(listId: ListIDs.default))
        XCTAssertEqual(try target.loadMusics(listId: ListIDs.love).map(\.id), ["wy_1"])
        XCTAssertEqual(try target.loadMusics(listId: listA.id).map(\.id), ["tx_1", "tx_2"])
        XCTAssertEqual(try target.loadMusics(listId: listA.id), try source.loadMusics(listId: listA.id))
        XCTAssertEqual(
            try target.loadMusics(listId: listA.id)[1].meta["unknownNested"]?["k"]?.arrayValue?.count,
            3
        )
        XCTAssertEqual(try target.loadMusics(listId: listB.id).map(\.id), ["mg_1"])
        // temp 不参与导出/导入
        XCTAssertEqual(try target.loadMusics(listId: ListIDs.temp), [])
    }

    // MARK: - 旧结构（legacy musicInfo）导入

    @MainActor
    func testImportLegacyKgAndTxMusicAndUsersLists() async throws {
        let environment = try TempEnvironment()
        defer { environment.cleanUp() }
        let service = try makeService(in: environment)
        let existing = try service.createList(name: "已存在列表")

        let legacyKG: JSONValue = .object([
            "name": .string("酷狗老歌"),
            "singer": .string("酷狗歌手"),
            "source": .string("kg"),
            "songmid": .string("kg_mid_1"),
            "hash": .string("ABCDEF123"),
            "albumName": .string("老专辑"),
            "interval": .string("03:00"),
            "img": .string("http://example.com/kg.jpg"),
            "types": .array([.object(["type": .string("128k"), "size": .string("3M")])]),
            "_types": .object(["128k": .object(["size": .string("3M")])]),
        ])
        let legacyTX: JSONValue = .object([
            "name": .string("QQ老歌"),
            "singer": .string("QQ歌手"),
            "source": .string("tx"),
            "songmid": .string("tx_mid_1"),
            "songId": .string("tx_song_id_1"),
            "strMediaMid": .string("media_mid_1"),
            "albumMid": .string("album_mid_1"),
            "albumName": .string("QQ专辑"),
            "interval": .string("04:00"),
            "img": .string(""),
            "types": .array([]),
            "_types": .object([:]),
        ])
        let newStructureMusic = makeMusic(id: "kw_new_1", name: "新结构歌").jsonObject

        let backup: JSONValue = .array([
            .object([
                "id": .string(ListIDs.default),
                "name": .string("试听列表"),
                "list": .array([legacyKG, legacyTX]),
            ]),
            .object([
                "id": .string("userlist_legacy"),
                "name": .string("旧备份列表"),
                "source": .string("kg"),
                "sourceListId": .string("42"),
                "locationUpdateTime": .int(1_600_000_000_000),
                "list": .array([newStructureMusic]),
            ]),
            .object([
                "id": .string("userlist_auto_created"),
                "name": .string("自动创建列表"),
                "list": .array([]),
            ]),
        ])

        let summary = try service.importPlaylistsBackup(backup)
        XCTAssertEqual(summary.lists, 3)
        XCTAssertEqual(summary.musics, 3, "default 2 首 + 用户列表 1 首")

        // kg：id = songmid_hash，meta 保留原版字段
        let defaultMusics = try service.loadMusics(listId: ListIDs.default)
        XCTAssertEqual(defaultMusics.map(\.id), ["kg_mid_1_ABCDEF123", "tx_tx_mid_1"])
        XCTAssertEqual(defaultMusics[0].source, "kg")
        XCTAssertEqual(defaultMusics[0].meta["hash"]?.stringValue, "ABCDEF123")
        XCTAssertEqual(defaultMusics[0].meta["songId"]?.stringValue, "kg_mid_1")
        XCTAssertEqual(defaultMusics[0].meta["albumName"]?.stringValue, "老专辑")
        XCTAssertEqual(defaultMusics[0].meta["qualitys"]?.arrayValue?.count, 1)
        // tx：id = tx_songmid；meta["id"] 保留 songId
        XCTAssertEqual(defaultMusics[1].source, "tx")
        XCTAssertEqual(defaultMusics[1].meta["id"]?.stringValue, "tx_song_id_1")
        XCTAssertEqual(defaultMusics[1].meta["strMediaMid"]?.stringValue, "media_mid_1")

        // 自动创建用户列表：position = max+1 递增，原版字段保留
        let lists = try service.loadUserLists()
        XCTAssertEqual(lists.map(\.id), [existing.id, "userlist_legacy", "userlist_auto_created"])
        XCTAssertEqual(lists.map(\.position), [0, 1, 2])
        XCTAssertEqual(lists[1].source, "kg")
        XCTAssertEqual(lists[1].sourceListId, "42")
        XCTAssertEqual(lists[1].locationUpdateTime, 1_600_000_000_000)
        XCTAssertEqual(try service.loadMusics(listId: "userlist_legacy").map(\.id), ["kw_new_1"])
        XCTAssertEqual(try service.loadMusics(listId: "userlist_auto_created"), [])
    }

    // MARK: - 幂等 / 无效元素 / 错误

    @MainActor
    func testImportIsIdempotent() async throws {
        let sourceEnvironment = try TempEnvironment()
        defer { sourceEnvironment.cleanUp() }
        let source = try makeService(in: sourceEnvironment)
        let list = try source.createList(name: "幂等列表")
        try source.addMusic(makeMusic(id: "kw_1", name: "歌 1"), to: ListIDs.default, location: .bottom)
        try source.addMusic(makeMusic(id: "kw_2", name: "歌 2"), to: list.id, location: .bottom)
        let exported = try source.exportPlaylistsBackup()

        let targetEnvironment = try TempEnvironment()
        defer { targetEnvironment.cleanUp() }
        let target = try makeService(in: targetEnvironment)

        let first = try target.importPlaylistsBackup(exported)
        XCTAssertEqual(first.lists, 3)
        let firstLists = try target.loadUserLists()
        let firstDefault = try target.loadMusics(listId: ListIDs.default)

        let second = try target.importPlaylistsBackup(exported)
        XCTAssertEqual(second.lists, first.lists)
        XCTAssertEqual(second.musics, first.musics)
        XCTAssertEqual(try target.loadUserLists(), firstLists, "重复导入不产生重复列表，position 不变")
        XCTAssertEqual(try target.loadMusics(listId: ListIDs.default), firstDefault)
        XCTAssertEqual(try target.loadMusics(listId: list.id).map(\.id), ["kw_2"])
    }

    @MainActor
    func testImportSkipsInvalidElementsAndMusics() async throws {
        let environment = try TempEnvironment()
        defer { environment.cleanUp() }
        let service = try makeService(in: environment)
        let validMusic = makeMusic(id: "kw_valid", name: "有效歌曲").jsonObject

        let backup: JSONValue = .array([
            .string("不是对象"),
            .object(["name": .string("缺少 id"), "list": .array([])]),
            .object(["id": .string(""), "name": .string("空 id"), "list": .array([])]),
            .object(["id": .string(ListIDs.temp), "name": .string("临时列表"), "list": .array([validMusic])]),
            .object(["id": .string(ListIDs.download), "name": .string("下载列表"), "list": .array([validMusic])]),
            .object([
                "id": .string("userlist_valid"),
                "name": .string("有效列表"),
                "list": .array([
                    .string("不合法歌曲"),
                    .object(["id": .string(""), "name": .string("空 id 歌曲"), "singer": .string(""), "source": .string("kw"), "interval": .null, "meta": .object([:])]),
                    validMusic,
                    validMusic, // 重复 id 由 overwriteList 过滤
                    .object(["name": .string("缺 source 的旧结构")]),
                ]),
            ]),
        ])

        let summary = try service.importPlaylistsBackup(backup)
        XCTAssertEqual(summary.lists, 1)
        XCTAssertEqual(summary.musics, 1, "重复/无效歌曲被过滤")
        XCTAssertEqual(try service.loadUserLists().map(\.id), ["userlist_valid"])
        XCTAssertEqual(try service.loadMusics(listId: "userlist_valid").map(\.id), ["kw_valid"])
        // temp/download 特殊 id 被跳过：不会建列表，也不会写歌曲
        XCTAssertFalse(try service.isMusicExist(id: "kw_valid", in: ListIDs.temp))
        XCTAssertFalse(try service.loadUserLists().contains { $0.id == ListIDs.download || $0.id == ListIDs.temp })

        // 全是无效元素：返回 0、不抛错
        let emptySummary = try service.importPlaylistsBackup(.array([
            .object(["id": .string("temp"), "list": .array([])]),
            .string("bad"),
        ]))
        XCTAssertEqual(emptySummary.lists, 0)
        XCTAssertEqual(emptySummary.musics, 0)

        // 内容不是数组：抛错
        XCTAssertThrowsError(try service.importPlaylistsBackup(.object([:])))
    }

    @MainActor
    func testImportThrowsWhenAllListsFail() async throws {
        let environment = try TempEnvironment()
        defer { environment.cleanUp() }
        let service = try makeService(in: environment)
        // 人为破坏 my_list 表，使用户列表导入全部失败
        try service.withRawDatabase { database in
            try database.execute("DROP TABLE \"main\".\"my_list\";")
        }
        let backup: JSONValue = .array([
            .object(["id": .string("userlist_fail"), "name": .string("失败列表"), "list": .array([])]),
        ])
        XCTAssertThrowsError(try service.importPlaylistsBackup(backup)) { error in
            XCTAssertTrue(error is MeloDataError || error is SQLiteError)
        }
    }

    // MARK: - 与 MeloCore.BackupService 集成（.lxmc gzip）

    @MainActor
    func testBackupServiceLXMCPlaylistRoundTrip() async throws {
        let sourceEnvironment = try TempEnvironment()
        defer { sourceEnvironment.cleanUp() }
        let source = try makeService(in: sourceEnvironment)
        let list = try source.createList(name: "备份列表")
        try source.addMusic(makeMusic(id: "kw_b1", name: "备份歌 1"), to: ListIDs.default, location: .bottom)
        try source.addMusic(makeMusic(id: "wy_b1", name: "收藏备份", source: "wy"), to: ListIDs.love, location: .bottom)
        try source.addMusic(makeMusic(id: "tx_b1", name: "列表备份", source: "tx"), to: list.id, location: .bottom)

        let sourceSettings = SettingsStore(dataDirectory: sourceEnvironment.dataDirectory)
        let exporter = BackupService(data: source, settings: sourceSettings)
        let backupURL = sourceEnvironment.root.appendingPathComponent("playlist.lxmc")
        try exporter.export(kind: .playlists, to: backupURL)

        let bytes = try Data(contentsOf: backupURL)
        XCTAssertEqual([UInt8](bytes.prefix(2)), [0x1F, 0x8B], ".lxmc 必须是 gzip")

        let targetEnvironment = try TempEnvironment()
        defer { targetEnvironment.cleanUp() }
        let target = try makeService(in: targetEnvironment)
        let targetSettings = SettingsStore(dataDirectory: targetEnvironment.dataDirectory)
        let importer = BackupService(data: target, settings: targetSettings)
        let summary = try importer.importBackup(from: backupURL)

        XCTAssertEqual(summary.sourceType, "playList_v2")
        XCTAssertFalse(summary.settingsImported)
        XCTAssertEqual(summary.lists, 3)
        XCTAssertEqual(summary.musics, 3)
        XCTAssertEqual(try target.loadUserLists().map(\.name), ["备份列表"])
        XCTAssertEqual(try target.loadMusics(listId: ListIDs.default).map(\.id), ["kw_b1"])
        XCTAssertEqual(try target.loadMusics(listId: ListIDs.love).map(\.id), ["wy_b1"])
        XCTAssertEqual(try target.loadMusics(listId: list.id).map(\.id), ["tx_b1"])
    }
}
