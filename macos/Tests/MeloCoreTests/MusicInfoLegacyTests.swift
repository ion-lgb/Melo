import XCTest
@testable import MeloCore

final class MusicInfoLegacyTests: XCTestCase {
    private func makeInfo(source: String, meta: [String: JSONValue]) -> MusicInfo {
        MusicInfo(id: "\(source)_228908", name: "晴天", singer: "周杰伦", source: source, interval: "04:29", meta: .object(meta))
    }

    func testKWLegacyJSON() {
        let music = makeInfo(source: "kw", meta: [
            "songId": .string("228908"),
            "albumName": .string("叶惠美"),
            "picUrl": .null,
            "albumId": .string("1293"),
            "qualitys": .array([.object(["type": .string("128k"), "size": .null])]),
            "_qualitys": .object(["128k": .object(["size": .null])]),
        ])
        let legacy = music.legacyJSON.objectValue!
        XCTAssertEqual(legacy["songmid"]?.stringValue, "228908")
        XCTAssertEqual(legacy["source"]?.stringValue, "kw")
        XCTAssertEqual(legacy["albumName"]?.stringValue, "叶惠美")
        XCTAssertEqual(legacy["img"]?.stringValue, "")
        XCTAssertEqual(legacy["types"]?.arrayValue?.count, 1)
        XCTAssertEqual(legacy["_types"]?["128k"]?["size"], .null)
        XCTAssertNil(legacy["hash"])
    }

    func testKGLegacyJSON() {
        let music = makeInfo(source: "kg", meta: [
            "songId": .string("abc"),
            "hash": .string("HASH123"),
            "qualitys": .array([.object(["type": .string("320k"), "size": .string("10M"), "hash": .string("HASH123")])]),
            "_qualitys": .object([:]),
        ])
        let legacy = music.legacyJSON.objectValue!
        XCTAssertEqual(legacy["hash"]?.stringValue, "HASH123")
        XCTAssertEqual(legacy["types"]?.arrayValue?.first?["hash"]?.stringValue, "HASH123")
    }

    func testTXMLegacyJSON() {
        let music = makeInfo(source: "tx", meta: [
            "songId": .string("mid123"),
            "id": .int(10086),
            "strMediaMid": .string("media456"),
            "albumMid": .string("album789"),
        ])
        let legacy = music.legacyJSON.objectValue!
        XCTAssertEqual(legacy["songmid"]?.stringValue, "mid123")
        XCTAssertEqual(legacy["songId"]?.intValue, 10086)
        XCTAssertEqual(legacy["strMediaMid"]?.stringValue, "media456")
    }

    func testLocalLegacyJSON() {
        let music = MusicInfo(id: "local_/tmp/a.mp3", name: "本地", singer: "", source: "local", interval: nil, meta: .object([
            "songId": .string("/tmp/a.mp3"),
            "filePath": .string("/tmp/a.mp3"),
            "ext": .string("mp3"),
        ]))
        let legacy = music.legacyJSON.objectValue!
        XCTAssertEqual(legacy["filePath"]?.stringValue, "/tmp/a.mp3")
        XCTAssertEqual(legacy["ext"]?.stringValue, "mp3")
        XCTAssertEqual(legacy["types"]?.arrayValue?.count, 0)
    }
}
