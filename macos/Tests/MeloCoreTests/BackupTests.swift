import XCTest
@testable import MeloCore

/// 备份编解码 + BackupService 单元测试（列表读写用轻量 FakeDataService）。
@MainActor
final class BackupTests: XCTestCase {
    func testGzipRoundTrip() throws {
        let samples: [Data] = [
            Data(),
            Data("{}".utf8),
            Data(String(repeating: "晴天 - 周杰伦\n", count: 500).utf8),
            Data((0..<120_000).map { UInt8($0 % 251) }),
        ]
        for sample in samples {
            let compressed = try GzipCoder.compress(sample)
            XCTAssertGreaterThanOrEqual(compressed.count, 18)
            XCTAssertEqual([UInt8](compressed.prefix(3)), [0x1f, 0x8b, 0x08])
            let restored = try GzipCoder.decompress(compressed)
            XCTAssertEqual(restored, sample)
        }
    }

    func testGzipNonGzipThrows() {
        XCTAssertThrowsError(try GzipCoder.decompress(Data("not gzip".utf8)))
    }

    func testBackupCoderJSONAndLXMC() throws {
        let value = JSONValue.object(["type": .string("setting_v2"), "data": .object(["a": .int(1)])])
        let json = try BackupCoder.encode(value, pathExtension: "json")
        XCTAssertEqual(try BackupCoder.decode(json, pathExtension: "json"), value)
        let lxmc = try BackupCoder.encode(value, pathExtension: "lxmc")
        XCTAssertEqual([UInt8](lxmc.prefix(2)), [0x1f, 0x8b])
        XCTAssertEqual(try BackupCoder.decode(lxmc, pathExtension: "lxmc"), value)
    }

    func testSettingsExportImport() throws {
        let dir = try makeTempDir()
        let store = SettingsStore(dataDirectory: dir)
        store.set("player.volume", .double(0.66))
        store.set("player.muted", .bool(true))
        let backup = BackupService(data: FakeDataService(), settings: store)
        let file = dir.appendingPathComponent("settings.lxmc")
        try backup.export(kind: .settings, to: file)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        let otherDir = try makeTempDir()
        let other = SettingsStore(dataDirectory: otherDir)
        let backup2 = BackupService(data: FakeDataService(), settings: other)
        let summary = try backup2.importBackup(from: file)
        XCTAssertTrue(summary.settingsImported)
        XCTAssertEqual(summary.sourceType, "setting_v2")
        XCTAssertEqual(other.double("player.volume", default: 0), 0.66, accuracy: 0.0001)
        XCTAssertTrue(other.bool("player.muted"))
    }

    func testAllDataLegacyMusicInfoNormalization() throws {
        // 模拟旧版备份：list 中是无 meta 的旧结构歌曲
        let legacySong: JSONValue = .object([
            "name": .string("晴天"),
            "singer": .string("周杰伦"),
            "source": .string("tx"),
            "songmid": .string("0039MnYb0qxYhV"),
            "songId": .int(10086),
            "interval": .string("04:29"),
            "albumName": .string("叶惠美"),
            "img": .string(""),
            "types": .array([.object(["type": .string("320k"), "size": .null])]),
            "_types": .object(["320k": .object(["size": .null])]),
            "strMediaMid": .string("media"),
            "albumMid": .string("album"),
        ])
        let lists: JSONValue = .array([
            .object([
                "id": .string("default"),
                "name": .string("试听列表"),
                "list": .array([legacySong]),
            ]),
        ])
        let normalized = try BackupService.normalizePlaylists(lists)
        guard let list = normalized.arrayValue?.first,
              let songs = list["list"]?.arrayValue,
              let song = songs.first else {
            return XCTFail("normalize 结果为空")
        }
        XCTAssertEqual(song["id"]?.stringValue, "tx_0039MnYb0qxYhV")
        XCTAssertEqual(song["meta"]?["songId"]?.stringValue, "0039MnYb0qxYhV")
        XCTAssertEqual(song["meta"]?["id"]?.intValue, 10086)
        XCTAssertEqual(song["meta"]?["strMediaMid"]?.stringValue, "media")
    }

    func testNewFormatKeptAsIs() throws {
        let music = MusicInfo(id: "kw_228908", name: "晴天", singer: "周杰伦", source: "kw",
                              interval: "04:29", meta: .object(["songId": .string("228908")]))
        let lists: JSONValue = .array([
            .object(["id": .string("love"), "name": .string("我的收藏"), "list": .array([music.jsonObject])]),
        ])
        let normalized = try BackupService.normalizePlaylists(lists)
        let song = normalized.arrayValue?.first?["list"]?.arrayValue?.first
        XCTAssertEqual(song?["id"]?.stringValue, "kw_228908")
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("melo-backup-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// 只实现备份相关能力的假数据层，其余方法不被这些测试调用。
@MainActor
final class FakeDataService: DataService {
    var dataDirectory: URL { FileManager.default.temporaryDirectory }
    var importedLists: JSONValue?

    func bootstrap() throws {}
    func loadUserLists() throws -> [ListInfo] { [] }
    func loadMusics(listId: String) throws -> [MusicInfo] { [] }
    func loadMusicCounts() throws -> [String: Int] { [:] }
    func createList(name: String) throws -> ListInfo { ListInfo(id: UUID().uuidString, name: name) }
    func renameList(id: String, name: String) throws {}
    func removeList(id: String) throws {}
    func updateListPosition(id: String, position: Int) throws {}
    func addMusic(_ music: MusicInfo, to listId: String, location: AddMusicLocationType) throws {}
    func removeMusic(ids: [String], from listId: String) throws {}
    func isMusicExist(id: String, in listId: String) throws -> Bool { false }
    func clearList(listId: String) throws {}
    func overwriteList(listId: String, musics: [MusicInfo]) throws {}
    func updateMusicOrder(in listId: String, orderedMusicIDs: [String]) throws {}
    func scanLocalMusic(at urls: [URL]) throws -> [MusicInfo] { [] }
    func exportPlaylistsBackup() throws -> JSONValue { .array([]) }
    func importPlaylistsBackup(_ lists: JSONValue) throws -> BackupImportSummary {
        importedLists = lists
        return BackupImportSummary(lists: 1, musics: 1)
    }
    func saveDownloadTask(_ task: DownloadTaskInfo) throws {}
    func removeDownloadTasks(ids: [String]) throws {}
    func clearCompletedDownloadTasks() throws {}
    func getLyric(musicId: String, source: String, type: String) throws -> String? { nil }
    func saveLyric(musicId: String, source: String, type: String, text: String) throws {}
    func getMusicURL(musicId: String, quality: String) throws -> String? { nil }
    func saveMusicURL(musicId: String, quality: String, url: String) throws {}
    func loadDownloadTasks() throws -> [DownloadTaskInfo] { [] }
    func loadDislikes() throws -> [DislikeInfo] { [] }
}
