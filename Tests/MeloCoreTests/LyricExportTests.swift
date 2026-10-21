import XCTest
@testable import MeloCore

final class LyricExporterTests: XCTestCase {
    private func makeInfo() -> LyricInfo {
        LyricInfo(
            lyric: "[00:00.00]line1\n[00:05.00]line2",
            tlyric: "[00:00.00]翻译1\n[00:05.00]翻译2\n[00:99.00]不匹配",
            rlyric: "[00:00.00]roma1\n[00:05.00]roma2",
            lxlyric: "[00:00.00]<00:00.00>逐字1<00:01.00>逐字2"
        )
    }

    func testNoExtensionsReturnsMainLyric() {
        let info = LyricInfo(lyric: "[00:01.00]only")
        XCTAssertEqual(LyricExporter.buildMergedLyric(info, includeWordByWord: true, includeTranslation: true, includeRoman: true),
                       "[00:01.00]only")
    }

    func testMergeTranslationRomanAndWordByWord() {
        let merged = LyricExporter.buildMergedLyric(makeInfo(), includeWordByWord: true, includeTranslation: true, includeRoman: true)
        XCTAssertTrue(merged.contains("[00:00.00]翻译1"))
        XCTAssertTrue(merged.contains("[00:05.00]翻译2"))
        XCTAssertFalse(merged.contains("不匹配"), "扩展歌词里时间不匹配的行应被过滤")
        XCTAssertTrue(merged.contains("[00:00.00]roma1"))
        XCTAssertTrue(merged.contains("[awlrc:"))
        XCTAssertTrue(merged.contains("lrc:"))
        XCTAssertTrue(merged.contains("tlrc:"))
        XCTAssertTrue(merged.contains("rlrc:"))
        XCTAssertTrue(merged.contains("awlrc:"))
    }

    func testFlagsOff() {
        let merged = LyricExporter.buildMergedLyric(makeInfo(), includeWordByWord: false, includeTranslation: false, includeRoman: false)
        XCTAssertEqual(merged, "[00:00.00]line1\n[00:05.00]line2")
    }

    func testOnlyTranslation() {
        let merged = LyricExporter.buildMergedLyric(makeInfo(), includeWordByWord: false, includeTranslation: true, includeRoman: false)
        XCTAssertTrue(merged.contains("[00:00.00]翻译1"))
        XCTAssertFalse(merged.contains("roma1"))
        XCTAssertFalse(merged.contains("[awlrc:"))
    }
}

final class ListTransferServiceTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("melo-list-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var playlists: JSONValue {
        .array([
            .object([
                "id": .string("default"), "name": .string("试听列表"),
                "list": .array([
                    .object(["name": .string("晴天"), "singer": .string("周杰伦"),
                             "meta": .object(["albumName": .string("叶惠美")])]),
                    .object(["name": .string("Song, with comma"), "singer": .string("A \"B\""),
                             "meta": .object(["albumName": .string("")])]),
                ]),
            ]),
        ])
    }

    func testExportTextMergedWithBOM() throws {
        let urls = try ListTransferService.export(playlists: playlists, kind: .text, merge: true, to: directory)
        XCTAssertEqual(urls.count, 1)
        let data = try Data(contentsOf: urls[0])
        XCTAssertEqual([UInt8](data.prefix(3)), [0xEF, 0xBB, 0xBF])
        let text = String(decoding: data.dropFirst(3), as: UTF8.self)
        XCTAssertTrue(text.contains("晴天  周杰伦  叶惠美"))
        XCTAssertTrue(urls[0].lastPathComponent.hasSuffix(".txt"))
    }

    func testExportCSVPerListEscapes() throws {
        let urls = try ListTransferService.export(playlists: playlists, kind: .csv, merge: false, to: directory)
        XCTAssertEqual(urls.count, 1)
        let text = String(decoding: try Data(contentsOf: urls[0]).dropFirst(3), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("歌曲名,歌手,专辑"))
        XCTAssertTrue(text.contains("\"Song, with comma\""))
        XCTAssertTrue(text.contains("\"A \"\"B\"\"\""))
    }

    func testExportEmptyListsProducesNoFiles() throws {
        let empty: JSONValue = .array([])
        let urls = try ListTransferService.export(playlists: empty, kind: .text, merge: true, to: directory)
        XCTAssertTrue(urls.isEmpty)
    }
}
