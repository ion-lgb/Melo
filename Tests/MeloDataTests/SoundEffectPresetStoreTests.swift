import XCTest
@testable import MeloData
import MeloCore

/// `sound_effect.json` 音效预设持久化测试（原版结构 / 原子写 / 损坏备份 / 未知字段兼容）。
final class SoundEffectPresetStoreTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeloDataSoundEffectTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory { try? FileManager.default.removeItem(at: tempDirectory) }
        try super.tearDownWithError()
    }

    private func makeStore() throws -> SoundEffectPresetStore {
        let dataDirectory = tempDirectory.appendingPathComponent("LxDatas", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        return SoundEffectPresetStore(dataDirectory: dataDirectory)
    }

    private func readRawJSON(_ store: SoundEffectPresetStore) throws -> JSONValue {
        let data = try Data(contentsOf: store.fileURL)
        return try XCTUnwrap(JSONValue(jsonData: data))
    }

    // MARK: - 缺失 / 往返

    func testMissingFileReturnsEmptyArrays() throws {
        let store = try makeStore()
        XCTAssertEqual(store.loadEQPresets(), [])
        XCTAssertEqual(store.loadConvolutionPresets(), [])
        XCTAssertNil(store.backupFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    func testSaveAndLoadOriginalPresetFields() throws {
        let store = try makeStore()

        let eqPreset: [String: JSONValue] = [
            "id": .string("user_eq_1"),
            "name": .string("我的低频"),
            "hz31": .int(3),
            "hz62": .int(2),
            "hz125": .int(1),
            "hz250": .int(0),
            "hz500": .double(-1.5),
            "hz1000": .int(0),
            "hz2000": .int(0),
            "hz4000": .double(1.25),
            "hz8000": .int(0),
            "hz16000": .int(-2),
            "unknownFutureField": .string("keep-me"),
        ]
        let convolution: [String: JSONValue] = [
            "id": .string("user_conv_1"),
            "name": .string("大厅"),
            "source": .string("hall.irs"),
            "mainGain": .double(0.75),
            "sendGain": .double(-2.25),
            "unknownConvolutionField": .int(7),
        ]

        try store.saveEQPresets([eqPreset])
        try store.saveConvolutionPresets([convolution])

        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.path))
        XCTAssertEqual(store.loadEQPresets(), [eqPreset], "原版 EQ 字段与未知字段应完整读写")
        XCTAssertEqual(store.loadConvolutionPresets(), [convolution], "原版卷积预设字段应完整读写")

        // 文件是合法 JSON 且同时包含两个 key（原版结构）
        let raw = try readRawJSON(store)
        XCTAssertNotNil(raw["eqPreset"]?.arrayValue)
        XCTAssertNotNil(raw["convolutionPreset"]?.arrayValue)

        // 再次保存 EQ 不影响已保存的卷积预设
        let secondEQ: [String: JSONValue] = ["id": .string("user_eq_2"), "name": .string("第二套")]
        try store.saveEQPresets([secondEQ])
        XCTAssertEqual(store.loadEQPresets(), [secondEQ])
        XCTAssertEqual(store.loadConvolutionPresets(), [convolution])
    }

    func testEmptyPresetArraysRoundTrip() throws {
        let store = try makeStore()
        try store.saveEQPresets([])
        try store.saveConvolutionPresets([])
        XCTAssertEqual(store.loadEQPresets(), [])
        XCTAssertEqual(store.loadConvolutionPresets(), [])
        let raw = try readRawJSON(store)
        XCTAssertEqual(raw["eqPreset"]?.arrayValue?.count, 0)
        XCTAssertEqual(raw["convolutionPreset"]?.arrayValue?.count, 0)
    }

    // MARK: - 未知顶层字段保留

    func testUnknownTopLevelFieldsArePreserved() throws {
        let store = try makeStore()
        let initial: JSONValue = .object([
            "eqPreset": .array([.object(["id": .string("builtin-eq")])]),
            "convolutionPreset": .array([.object(["id": .string("builtin-conv")])]),
            "schemaVersion": .int(2),
            "extraConfig": .object(["enabled": .bool(true), "note": .string("保留")]),
        ])
        try XCTUnwrap(initial.jsonData(pretty: true)).write(to: store.fileURL)

        try store.saveEQPresets([["id": .string("user-eq")]])

        let raw = try readRawJSON(store)
        XCTAssertEqual(raw["eqPreset"]?.arrayValue?.first?["id"]?.stringValue, "user-eq")
        XCTAssertEqual(raw["convolutionPreset"]?.arrayValue?.first?["id"]?.stringValue, "builtin-conv", "其它预设 key 保留")
        XCTAssertEqual(raw["schemaVersion"]?.intValue, 2)
        XCTAssertEqual(raw["extraConfig"]?["enabled"]?.boolValue, true)
        XCTAssertEqual(raw["extraConfig"]?["note"]?.stringValue, "保留")
    }

    // MARK: - 损坏文件

    func testCorruptedFileIsBackedUpAndReturnsEmpty() throws {
        let store = try makeStore()
        let corrupted = Data("{ this is not valid json".utf8)
        try corrupted.write(to: store.fileURL)

        XCTAssertEqual(store.loadEQPresets(), [])
        XCTAssertEqual(store.loadConvolutionPresets(), [])

        let backupURL = try XCTUnwrap(store.backupFileURL, "损坏文件应备份为 sound_effect.json.bak")
        XCTAssertEqual(backupURL.lastPathComponent, "sound_effect.json.bak")
        XCTAssertEqual(try Data(contentsOf: backupURL), corrupted, "备份内容应与原损坏文件一致")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path), "损坏文件应被移走")

        // 备份后仍可正常写入
        let preset: [String: JSONValue] = ["id": .string("after-corrupt"), "name": .string("恢复")]
        try store.saveEQPresets([preset])
        XCTAssertEqual(store.loadEQPresets(), [preset])
        // 旧 .bak 保留，不被正常写入覆盖
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(store.backupFileURL)), corrupted)
    }

    func testRootNotObjectIsTreatedAsCorrupted() throws {
        let store = try makeStore()
        try Data("[]".utf8).write(to: store.fileURL)
        XCTAssertEqual(store.loadEQPresets(), [])
        XCTAssertNotNil(store.backupFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    func testNonObjectPresetElementsAreSkipped() throws {
        let store = try makeStore()
        let raw: JSONValue = .object([
            "eqPreset": .array([
                .object(["id": .string("a")]),
                .string("oops"),
                .int(1),
                .object(["id": .string("b")]),
            ]),
            "convolutionPreset": .null,
        ])
        try XCTUnwrap(raw.jsonData(pretty: true)).write(to: store.fileURL)
        XCTAssertEqual(store.loadEQPresets().compactMap { $0["id"]?.stringValue }, ["a", "b"])
        XCTAssertEqual(store.loadConvolutionPresets(), [])
    }
}
