import XCTest
@testable import InnerTube

/// The JSON model responses are read through. Document order matters — the parser takes "the first"
/// header, like button or play action it finds — and numbers read as their literal text, as
/// kotlinx's `JsonPrimitive.content` does.
final class InnerTubeJSONTests: XCTestCase {

    func testObjectKeysKeepDocumentOrder() throws {
        let keys = (0..<50).map { "key\($0)" }.shuffled()
        let text = "{" + keys.map { "\"\($0)\":1" }.joined(separator: ",") + "}"
        XCTAssertEqual(try InnerTubeJSON.parse(text).objectValue?.keys, keys)
    }

    func testARepeatedKeyKeepsItsFirstPlaceAndLastValue() throws {
        let object = try XCTUnwrap(try InnerTubeJSON.parse(#"{"a":1,"b":2,"a":3}"#).objectValue)
        XCTAssertEqual(object.keys, ["a", "b"])
        XCTAssertEqual(object["a"], .number("3"))
    }

    func testPrimitivesReadAsTheirText() throws {
        let value = try InnerTubeJSON.parse(#"{"n":-12.50e+3,"i":20717,"t":true,"f":false,"z":null,"s":"x"}"#)
        XCTAssertEqual(value.s("n"), "-12.50e+3")
        XCTAssertEqual(value.s("i"), "20717")
        XCTAssertEqual(value.s("t"), "true")
        XCTAssertEqual(value.s("f"), "false")
        XCTAssertNil(value.s("z"))
        XCTAssertEqual(value.s("s"), "x")
        XCTAssertNil(value.s("missing"))
        XCTAssertNil(value.o("s"), "a string is not an object")
        XCTAssertNil(value.a("i"), "a number is not an array")
    }

    func testEscapesAndUnicode() throws {
        let value = try InnerTubeJSON.parse(#"["tab\tquote\"slash\/back\\", "é’", "🎵", "\ud83c", "raw é ♪"]"#)
        XCTAssertEqual(value.arrayValue?.compactMap(\.primitiveContent), ["tab\tquote\"slash/back\\", "é’", "🎵", "\u{FFFD}", "raw é ♪"])
    }

    func testAByteOrderMarkIsTolerated() throws {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data(#"{"ok":true}"#.utf8))
        XCTAssertEqual(try InnerTubeJSON.parse(data).s("ok"), "true")
    }

    func testMalformedJSONIsAnErrorWithItsOffset() {
        // Each input with the byte offset the reader gives up at.
        let cases: [(text: String, offset: Int)] = [
            ("", 0), ("{", 1), (#"{"a":}"#, 5), ("[1,]", 3), (#"{"a" 1}"#, 5), ("tru", 0), ("01x", 2),
            (#""unterminated"#, 13), ("{} extra", 3), ("1.", 2), ("-", 1), (#""\x""#, 3),
        ]
        for (bad, offset) in cases {
            XCTAssertThrowsError(try InnerTubeJSON.parse(bad), bad) { error in
                XCTAssertEqual((error as? InnerTubeJSONError)?.offset, offset, bad)
            }
        }
    }

    func testSerializingRoundTripsAndEscapes() throws {
        let value: InnerTubeJSON = [
            "context": ["client": ["clientName": "WEB_REMIX", "hl": "en"]],
            "text": "line\nquote\" back\\ ctl\u{01} é",
            "list": [1, true, nil, "x"],
        ]
        let text = String(decoding: value.serialized(), as: UTF8.self)
        XCTAssertEqual(text, #"{"context":{"client":{"clientName":"WEB_REMIX","hl":"en"}},"text":"line\nquote\" back\\ ctl\u0001 é","list":[1,true,null,"x"]}"#)
        XCTAssertEqual(try InnerTubeJSON.parse(text), value)
        // Foundation reads what we write.
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: value.serialized()))
    }

    func testRemovingAKeyKeepsTheRestInOrder() {
        var object = InnerTubeJSONObject(["a": 1, "b": 2, "c": 3])
        object["b"] = nil
        object["d"] = 4
        XCTAssertEqual(object.keys, ["a", "c", "d"])
        XCTAssertEqual(object["c"], .number("3"))
        XCTAssertEqual(object.count, 3)
    }

    func testFindStringLooksDepthFirstInDocumentOrder() throws {
        let value = try InnerTubeJSON.parse(#"{"x":{"deep":{"id":"first"}},"id2":[{"id":"second"}]}"#)
        XCTAssertEqual(value.findString("id"), "first")
        XCTAssertNil(value.findString("absent"))
    }

    func testEveryRecordedFixtureParsesAndMatchesFoundation() throws {
        for name in ["home.json", "artist.json", "search_all.json", "next.json", "mood_chill.json"] {
            let data = try Fixtures.loader.data(name)
            let ours = try InnerTubeJSON.parse(data)
            assertMatchesFoundation(ours, try JSONSerialization.jsonObject(with: data), name)
        }
    }

    /// Every value, recursively, with arrays in order. Foundation's dictionaries have no order to
    /// compare object keys against; ``testObjectKeysKeepDocumentOrder`` covers that.
    private func assertMatchesFoundation(_ ours: InnerTubeJSON, _ theirs: Any, _ path: String, line: UInt = #line) {
        switch ours {
        case .null:
            XCTAssertTrue(theirs is NSNull, path, line: line)
        case .bool(let value):
            XCTAssertEqual((theirs as? NSNumber)?.boolValue, value, path, line: line)
        case .number(let literal):
            guard let value = Double(literal), let number = theirs as? NSNumber else { return XCTFail("\(path): not a number", line: line) }
            XCTAssertEqual(value, number.doubleValue, accuracy: abs(value) * 1e-12, path, line: line)
        case .string(let value):
            XCTAssertEqual(theirs as? String, value, path, line: line)
        case .array(let items):
            guard let others = theirs as? [Any], others.count == items.count else { return XCTFail("\(path): array differs", line: line) }
            for (index, pair) in zip(items, others).enumerated() {
                assertMatchesFoundation(pair.0, pair.1, "\(path)[\(index)]", line: line)
            }
        case .object(let object):
            guard let others = theirs as? [String: Any], others.count == object.count else { return XCTFail("\(path): object differs", line: line) }
            for (key, value) in object.entries {
                guard let other = others[key] else { XCTFail("\(path).\(key) is missing", line: line); continue }
                assertMatchesFoundation(value, other, "\(path).\(key)", line: line)
            }
        }
    }
}
