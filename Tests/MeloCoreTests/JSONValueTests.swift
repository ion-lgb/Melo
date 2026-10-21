import XCTest
@testable import MeloCore

final class JSONValueTests: XCTestCase {
    func testRoundTrip() throws {
        let json = #"{"a":1,"b":[true,null,"x"],"c":{"d":1.5}}"#
        let value = try XCTUnwrap(JSONValue(jsonString: json))
        XCTAssertEqual(value["a"]?.intValue, 1)
        XCTAssertEqual(value["b"]?[2]?.stringValue, "x")
        XCTAssertEqual(value["c"]?["d"]?.doubleValue, 1.5)
        let encoded = try XCTUnwrap(value.jsonString())
        let decoded = try XCTUnwrap(JSONValue(jsonString: encoded))
        XCTAssertEqual(decoded["a"]?.intValue, 1)
    }

    func testLyricParser() {
        let lrc = """
        [ti:Test]
        [offset:100]
        [00:01.00]第一行
        [00:02.50]第二行
        [00:02.50]翻译行
        """
        let doc = LyricParser.parse(lrc)
        XCTAssertEqual(doc.lines.count, 2)
        XCTAssertEqual(doc.offsetMs, 100)
        XCTAssertEqual(doc.lines[0].timeMs, 1000)
        XCTAssertEqual(doc.lines[1].extended, ["翻译行"])
        XCTAssertEqual(doc.lineIndex(at: 2.6), 1)
    }
}
