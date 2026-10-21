import XCTest
@testable import MeloData
import MeloCore

/// `LxDatas/data.json` 应用数据存储测试（playInfo / listUpdateInfo、未知键保留、损坏备份、原子写）。
final class AppDataFileStoreTests: XCTestCase {
    private var tempDirectory: URL!
    private var dataDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeloDataAppDataTests-\(UUID().uuidString)", isDirectory: true)
        dataDirectory = tempDirectory.appendingPathComponent("LxDatas", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory { try? FileManager.default.removeItem(at: tempDirectory) }
        try super.tearDownWithError()
    }

    @MainActor
    private func makeStore() -> AppDataFileStore {
        AppDataFileStore(dataDirectory: dataDirectory)
    }

    private func readRootJSON() throws -> JSONValue {
        let data = try Data(contentsOf: dataDirectory.appendingPathComponent("data.json"))
        return try XCTUnwrap(JSONValue(jsonData: data))
    }

    private func makeMusic() -> MusicInfo {
        MusicInfo(
            id: "kw_play_1",
            name: "晴天",
            singer: "周杰伦",
            source: "kw",
            interval: "04:29",
            meta: .object([
                "songId": .string("228908"),
                "albumName": .string("叶惠美"),
                "picUrl": .string("https://example.com/pic.jpg"),
                "qualitys": .array([.object(["type": .string("320k"), "size": .string("9.1M")])]),
                "_qualitys": .object(["320k": .object(["size": .string("9.1M"), "hash": .string("abc")])]),
                "unknownNested": .object(["k": .array([.int(1), .bool(true), .string("中文")])]),
            ])
        )
    }

    // MARK: - 缺失文件

    @MainActor
    func testMissingFileReturnsNilAndEmptyWithoutCreatingFile() async throws {
        let store = makeStore()
        XCTAssertNil(store.loadPlayInfo())
        XCTAssertEqual(store.loadListUpdateInfo(), [:])
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: store.fileURL.path),
            "只读操作不应创建 data.json"
        )
    }

    // MARK: - playInfo 往返

    @MainActor
    func testPlayInfoRoundTripPreservesMusicMeta() async throws {
        let store = makeStore()
        let snapshot = PlayInfoSnapshot(
            time: 123.5,
            maxTime: 269,
            musicInfo: makeMusic(),
            listId: "userlist_abc"
        )
        store.savePlayInfo(snapshot)

        // 新实例读取（模拟重启）
        let loaded = try XCTUnwrap(makeStore().loadPlayInfo())
        XCTAssertEqual(loaded, snapshot, "playInfo 全字段往返（含 MusicInfo meta 未知字段）")
        XCTAssertEqual(loaded.time, 123.5)
        XCTAssertEqual(loaded.maxTime, 269)
        XCTAssertEqual(loaded.listId, "userlist_abc")
        XCTAssertEqual(loaded.musicInfo?.meta["unknownNested"]?["k"]?.arrayValue?.count, 3)
        XCTAssertEqual(loaded.musicInfo?.meta["_qualitys"]?["320k"]?["hash"]?.stringValue, "abc")

        // data.json 根对象结构兼容原版（playInfo 是根键）
        let root = try readRootJSON()
        XCTAssertNotNil(root["playInfo"]?.objectValue)
        XCTAssertEqual(root["playInfo"]?["time"]?.doubleValue, 123.5)
        XCTAssertEqual(root["playInfo"]?["musicInfo"]?["meta"]?["albumName"]?.stringValue, "叶惠美")
    }

    @MainActor
    func testPlayInfoWithoutMusicAndListIdRoundTrip() async throws {
        let store = makeStore()
        let snapshot = PlayInfoSnapshot(time: 0, maxTime: 0, musicInfo: nil, listId: nil)
        store.savePlayInfo(snapshot)
        let loaded = try XCTUnwrap(makeStore().loadPlayInfo())
        XCTAssertEqual(loaded.time, 0)
        XCTAssertEqual(loaded.maxTime, 0)
        XCTAssertNil(loaded.musicInfo)
        XCTAssertNil(loaded.listId)
    }

    /// 原版 electron-store 的 playInfo 只有 time/maxTime/listId/index（没有 musicInfo）。
    @MainActor
    func testLoadsOriginalElectronStorePlayInfoFormat() async throws {
        let original: JSONValue = .object([
            "playInfo": .object([
                "time": .double(42.25),
                "maxTime": .double(200),
                "listId": .string("default"),
                "index": .int(3),
            ]),
            "winLegacyMessageShown": .bool(true),
        ])
        let data = try XCTUnwrap(original.jsonData(pretty: true))
        try data.write(to: dataDirectory.appendingPathComponent("data.json"))

        let loaded = try XCTUnwrap(makeStore().loadPlayInfo())
        XCTAssertEqual(loaded.time, 42.25)
        XCTAssertEqual(loaded.maxTime, 200)
        XCTAssertEqual(loaded.listId, "default")
        XCTAssertNil(loaded.musicInfo)
    }

    // MARK: - 未知顶层键保留

    @MainActor
    func testUnknownTopLevelKeysArePreserved() async throws {
        let original: JSONValue = .object([
            "playInfo": .object(["time": .double(1), "maxTime": .double(2), "listId": .string("default"), "index": .int(0)]),
            "listUpdateInfo": .object([:]),
            "winLegacyMessageShown": .bool(true),
            "searchHistoryList": .array([.string("a"), .string("b")]),
            "viewPrevState": .object(["url": .string("/search")]),
            "lastStartInfo": .string("2.12.6"),
        ])
        try XCTUnwrap(original.jsonData(pretty: true))
            .write(to: dataDirectory.appendingPathComponent("data.json"))

        let store = makeStore()
        store.savePlayInfo(PlayInfoSnapshot(time: 5, maxTime: 6, musicInfo: nil, listId: "love"))
        store.saveListUpdateInfo(["love": ListUpdateInfo(updateTime: 100, isAutoUpdate: true)])

        let root = try readRootJSON()
        XCTAssertEqual(root["winLegacyMessageShown"]?.boolValue, true)
        XCTAssertEqual(root["searchHistoryList"]?.arrayValue?.compactMap(\.stringValue), ["a", "b"])
        XCTAssertEqual(root["viewPrevState"]?["url"]?.stringValue, "/search")
        XCTAssertEqual(root["lastStartInfo"]?.stringValue, "2.12.6")
        XCTAssertEqual(root["playInfo"]?["time"]?.doubleValue, 5)
        XCTAssertEqual(root["listUpdateInfo"]?["love"]?["isAutoUpdate"]?.boolValue, true)
    }

    // MARK: - listUpdateInfo 增删改

    @MainActor
    func testListUpdateInfoAddUpdateDeleteAndEmpty() async throws {
        let store = makeStore()
        let first: [String: ListUpdateInfo] = [
            "default": ListUpdateInfo(updateTime: 1_700_000_000_000, isAutoUpdate: true),
            "userlist_a": ListUpdateInfo(updateTime: 0, isAutoUpdate: false),
        ]
        store.saveListUpdateInfo(first)
        XCTAssertEqual(makeStore().loadListUpdateInfo(), first)

        // 更新 + 删除 + 新增
        var second = try XCTUnwrap(makeStore().loadListUpdateInfo())
        second["default"] = ListUpdateInfo(updateTime: 1_700_000_111_111, isAutoUpdate: false)
        second.removeValue(forKey: "userlist_a")
        second["userlist_b"] = ListUpdateInfo(updateTime: 42, isAutoUpdate: true)
        store.saveListUpdateInfo(second)
        XCTAssertEqual(makeStore().loadListUpdateInfo(), second)
        let root = try readRootJSON()
        XCTAssertNil(root["listUpdateInfo"]?["userlist_a"])
        XCTAssertEqual(root["listUpdateInfo"]?["userlist_b"]?["isAutoUpdate"]?.boolValue, true)

        // 空字典 → 写 {} 且读回 [:]
        store.saveListUpdateInfo([:])
        XCTAssertEqual(makeStore().loadListUpdateInfo(), [:])
        let emptyRoot = try readRootJSON()
        XCTAssertEqual(emptyRoot["listUpdateInfo"]?.objectValue?.count, 0)
    }

    @MainActor
    func testListUpdateInfoLenientHistoryEntries() async throws {
        let raw: JSONValue = .object([
            "listUpdateInfo": .object([
                "default": .object(["updateTime": .int(123)]), // 缺 isAutoUpdate
                "legacy": .object(["updateTime": .int(456), "isAutoUpdate": .bool(true), "unknown": .int(1)]),
                "broken": .string("oops"),
            ]),
        ])
        try XCTUnwrap(raw.jsonData(pretty: true)).write(to: dataDirectory.appendingPathComponent("data.json"))
        let loaded = makeStore().loadListUpdateInfo()
        XCTAssertEqual(loaded["default"], ListUpdateInfo(updateTime: 123, isAutoUpdate: false))
        XCTAssertEqual(loaded["legacy"], ListUpdateInfo(updateTime: 456, isAutoUpdate: true))
        XCTAssertNil(loaded["broken"])
    }

    // MARK: - 幂等 / 不误伤其它文件

    @MainActor
    func testRepeatedSaveIsIdempotentAndKeepsOtherKeys() async throws {
        let store = makeStore()
        let snapshot = PlayInfoSnapshot(time: 10, maxTime: 20, musicInfo: makeMusic(), listId: "default")
        store.savePlayInfo(snapshot)
        let firstData = try Data(contentsOf: store.fileURL)
        let firstRoot = try readRootJSON()

        store.savePlayInfo(snapshot)
        store.savePlayInfo(snapshot)
        let secondData = try Data(contentsOf: store.fileURL)
        XCTAssertEqual(try readRootJSON(), firstRoot)
        XCTAssertEqual(secondData, firstData, "key 排序 + 原子写应保证重复保存字节稳定")
        XCTAssertEqual(makeStore().loadPlayInfo(), snapshot)

        // listUpdateInfo 同样幂等，且不会清掉 playInfo
        store.saveListUpdateInfo(["default": ListUpdateInfo(updateTime: 1, isAutoUpdate: true)])
        let infoData = try Data(contentsOf: store.fileURL)
        store.saveListUpdateInfo(["default": ListUpdateInfo(updateTime: 1, isAutoUpdate: true)])
        XCTAssertEqual(try Data(contentsOf: store.fileURL), infoData)
        XCTAssertEqual(makeStore().loadPlayInfo(), snapshot)
    }

    @MainActor
    func testOtherFilesInDataDirectoryAreUntouched() async throws {
        let fileManager = FileManager.default
        let coreFiles: [(String, Data)] = [
            ("lx.data.db", Data(repeating: 0x01, count: 128)),
            ("config_v2.json", Data("{\"setting\":{}}".utf8)),
            ("user_api.json", Data("{\"userApis\":[]}".utf8)),
            ("theme.json", Data("{\"themes\":[]}".utf8)),
            ("hot_key.json", Data("{}".utf8)),
        ]
        for (name, content) in coreFiles {
            try content.write(to: dataDirectory.appendingPathComponent(name))
        }
        try fileManager.createDirectory(
            at: dataDirectory.appendingPathComponent("covers"), withIntermediateDirectories: true
        )
        try Data(repeating: 0x02, count: 32)
            .write(to: dataDirectory.appendingPathComponent("covers/cover.jpg"))

        let store = makeStore()
        store.savePlayInfo(PlayInfoSnapshot(time: 1, maxTime: 2, musicInfo: nil, listId: nil))
        store.saveListUpdateInfo(["default": ListUpdateInfo(updateTime: 3, isAutoUpdate: true)])
        _ = store.loadPlayInfo()
        _ = store.loadListUpdateInfo()

        for (name, content) in coreFiles {
            XCTAssertEqual(
                try Data(contentsOf: dataDirectory.appendingPathComponent(name)), content,
                "\(name) 不应被 data.json 读写影响"
            )
        }
        XCTAssertEqual(
            try Data(contentsOf: dataDirectory.appendingPathComponent("covers/cover.jpg")),
            Data(repeating: 0x02, count: 32)
        )
        let names = try fileManager.contentsOfDirectory(atPath: dataDirectory.path)
        XCTAssertTrue(names.contains("data.json"))
        XCTAssertEqual(names.filter { $0 == "data.json" }.count, 1)
    }

    // MARK: - 损坏文件备份

    @MainActor
    func testCorruptedFileIsBackedUpAndStoreRecovers() async throws {
        let corrupted = Data("{ this is not valid json".utf8)
        let dataURL = dataDirectory.appendingPathComponent("data.json")
        try corrupted.write(to: dataURL)

        let store = makeStore()
        XCTAssertNil(store.loadPlayInfo())
        XCTAssertEqual(store.loadListUpdateInfo(), [:])

        let backupURL = try XCTUnwrap(store.backupFileURL, "损坏文件应备份为 data.json.bak")
        XCTAssertEqual(backupURL.lastPathComponent, "data.json.bak")
        XCTAssertEqual(try Data(contentsOf: backupURL), corrupted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dataURL.path), "损坏文件应被移走")

        // 备份后仍可正常读写
        let snapshot = PlayInfoSnapshot(time: 7, maxTime: 8, musicInfo: makeMusic(), listId: "default")
        store.savePlayInfo(snapshot)
        XCTAssertEqual(makeStore().loadPlayInfo(), snapshot)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(store.backupFileURL)), corrupted, "旧 bak 不被正常写入覆盖")
    }

    @MainActor
    func testRootNotObjectIsTreatedAsCorrupted() async throws {
        try Data("[]".utf8).write(to: dataDirectory.appendingPathComponent("data.json"))
        let store = makeStore()
        XCTAssertNil(store.loadPlayInfo())
        XCTAssertEqual(store.loadListUpdateInfo(), [:])
        XCTAssertNotNil(store.backupFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    // MARK: - 写入失败不崩溃

    @MainActor
    func testSaveFailureOnlyLogsAndDoesNotCrash() async throws {
        // dataDirectory 指向一个普通文件：data.json 无法创建
        let notADirectory = tempDirectory.appendingPathComponent("not-a-directory")
        try Data("occupied".utf8).write(to: notADirectory)
        let store = AppDataFileStore(dataDirectory: notADirectory)

        XCTAssertNil(store.loadPlayInfo())
        XCTAssertEqual(store.loadListUpdateInfo(), [:])
        // 协议方法不抛错，只记录日志
        store.savePlayInfo(PlayInfoSnapshot(time: 1, maxTime: 2, musicInfo: nil, listId: nil))
        store.saveListUpdateInfo(["default": ListUpdateInfo(updateTime: 1, isAutoUpdate: true)])
        XCTAssertEqual(
            try Data(contentsOf: notADirectory), Data("occupied".utf8),
            "写失败不能破坏传入的路径"
        )
    }
}
