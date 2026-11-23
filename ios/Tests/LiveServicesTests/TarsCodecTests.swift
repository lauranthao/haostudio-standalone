// HAo Studio 2.0 — TARS codec tests (S4 leg B).
//
// Round-trips through TarsOutputStream / TarsInputStream, tag
// skipping, truncation errors. No network.
// Swift 5.0: no async/await, no `any`.

import XCTest
@testable import AppCore

private struct TarsEcho: TarsStruct {
    var small: Int = 0
    var negative: Int = 0
    var big: Int = 0
    var flag: Bool = false
    var text: String = ""
    var ratio: Double = 0
    var blob: Data = Data()
    var tags: [String] = []

    init() {
    }

    func write(to output: TarsOutputStream) {
        do {
            try output.writeInt(small, tag: 0)
            try output.writeInt(negative, tag: 1)
            try output.writeInt(big, tag: 2)
            try output.writeBool(flag, tag: 3)
            try output.writeString(text, tag: 4)
            try output.writeDouble(ratio, tag: 5)
            try output.writeBytes(blob, tag: 6)
            try output.writeStringList(tags, tag: 7)
        } catch {
            // In-memory writes only fail on a tag over 255.
        }
    }

    mutating func read(from input: TarsInputStream) throws {
        small = try input.readInt(tag: 0)
        negative = try input.readInt(tag: 1)
        big = try input.readInt(tag: 2)
        flag = try input.readBool(tag: 3)
        text = try input.readString(tag: 4)
        ratio = try input.readDouble(tag: 5)
        blob = try input.readBytes(tag: 6)
        tags = try input.readStringList(tag: 7)
    }
}

final class TarsCodecTests: XCTestCase {
    private func roundTrip(_ value: TarsEcho) throws -> TarsEcho {
        let output = TarsOutputStream()
        value.write(to: output)
        var decoded = TarsEcho()
        try decoded.read(from: TarsInputStream(output.bytes))
        return decoded
    }

    func testIntSizesRoundTripIncludingZeroTag() throws {
        var value = TarsEcho()
        value.small = 0
        value.negative = -1
        value.big = 4_000_000_000
        let decoded = try roundTrip(value)
        XCTAssertEqual(decoded.small, 0)
        XCTAssertEqual(decoded.negative, -1)
        XCTAssertEqual(decoded.big, 4_000_000_000)
    }

    func testIntBoundaries() throws {
        for number in [127, 128, 32767, 32768, 2_147_483_647, -128, -32768, -2_147_483_648] {
            var value = TarsEcho()
            value.big = number
            XCTAssertEqual(try roundTrip(value).big, number, "round-trip failed for \(number)")
        }
    }

    func testStringBoolDoubleBytesListRoundTrip() throws {
        var value = TarsEcho()
        value.flag = true
        value.text = "hello 虎牙 🎉"
        value.ratio = 3.25
        value.blob = Data([0x00, 0xFF, 0x7F, 0x80])
        value.tags = ["live:123", "chat:123"]
        let decoded = try roundTrip(value)
        XCTAssertTrue(decoded.flag)
        XCTAssertEqual(decoded.text, "hello 虎牙 🎉")
        XCTAssertEqual(decoded.ratio, 3.25)
        XCTAssertEqual(decoded.blob, Data([0x00, 0xFF, 0x7F, 0x80]))
        XCTAssertEqual(decoded.tags, ["live:123", "chat:123"])
    }

    func testLongStringUsesString4() throws {
        var value = TarsEcho()
        value.text = String(repeating: "a", count: 300)
        XCTAssertEqual(try roundTrip(value).text, value.text)
    }

    func testMissingTagsReturnDefaults() throws {
        let output = TarsOutputStream()
        try output.writeInt(42, tag: 0)
        var decoded = TarsEcho()
        try decoded.read(from: TarsInputStream(output.bytes))
        XCTAssertEqual(decoded.small, 42)
        XCTAssertEqual(decoded.negative, 0)
        XCTAssertEqual(decoded.text, "")
        XCTAssertEqual(decoded.tags, [])
    }

    func testSkipToTagFindsLaterFields() throws {
        let output = TarsOutputStream()
        try output.writeInt(1, tag: 0)
        try output.writeString("skip-me", tag: 5)
        try output.writeInt(99, tag: 9)
        let input = TarsInputStream(output.bytes)
        XCTAssertTrue(try input.skipToTag(9))
        XCTAssertEqual(try input.readInt(tag: 9), 99)
    }

    func testSkipToTagReturnsFalseForAbsentTag() throws {
        let output = TarsOutputStream()
        try output.writeInt(1, tag: 0)
        XCTAssertFalse(try TarsInputStream(output.bytes).skipToTag(7))
    }

    func testTruncatedStreamThrows() throws {
        var value = TarsEcho()
        value.text = "hello world, this is a long string"
        value.tags = ["one", "two", "three"]
        let output = TarsOutputStream()
        value.write(to: output)
        let truncated = output.bytes.prefix(output.bytes.count - 3)
        var decoded = TarsEcho()
        XCTAssertThrowsError(try decoded.read(from: TarsInputStream(Data(truncated))))
    }

    func testStructListRoundTrip() throws {
        let output = TarsOutputStream()
        var first = HuyaUserId()
        first.lUid = 123
        first.sGuid = "guid-1"
        var second = HuyaUserId()
        second.lUid = 456
        second.sGuid = "guid-2"
        try output.writeStructList([first, second], tag: 0)
        let decoded: [HuyaUserId] = try TarsInputStream(output.bytes).readStructList(tag: 0)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].lUid, 123)
        XCTAssertEqual(decoded[0].sGuid, "guid-1")
        XCTAssertEqual(decoded[1].lUid, 456)
    }

    func testStringMapsRoundTrip() throws {
        let output = TarsOutputStream()
        try output.writeStringToStringMap(["a": "1", "b": "2"], tag: 0)
        try output.writeStringToBytesMap(["x": Data([1, 2, 3])], tag: 1)
        let input = TarsInputStream(output.bytes)
        XCTAssertEqual(try input.readStringToStringMap(tag: 0), ["a": "1", "b": "2"])
        XCTAssertEqual(try input.readStringToBytesMap(tag: 1), ["x": Data([1, 2, 3])])
    }
}
