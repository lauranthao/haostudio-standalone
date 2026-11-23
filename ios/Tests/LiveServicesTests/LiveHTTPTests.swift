// HAo Studio 2.0 — live HTTP helpers tests (S4 leg B).
//
// LiveQuery (RFC 3986 build/parse) and LiveCrypto (MD5).
// No network. Swift 5.0: no async/await, no `any`.

import XCTest
@testable import AppCore

final class LiveHTTPTests: XCTestCase {
    // MARK: - LiveQuery

    func testQueryBuildPercentEncodes() {
        let built = LiveQuery.build([("room_id", "6"), ("title", "a b&c=d"), ("empty", "")])
        XCTAssertEqual(built, "room_id=6&title=a%20b%26c%3Dd&empty=")
    }

    func testQueryBuildKeepsUnreservedCharacters() {
        XCTAssertEqual(LiveQuery.build([("k", "a-b_c.d~e")]), "k=a-b_c.d~e")
    }

    func testQueryParseKeepsFirstSeenOrderAndLastValue() {
        let parsed = LiveQuery.parse("b=2&a=1&b=3")
        XCTAssertEqual(parsed.map { $0.0 }, ["b", "a"])
        XCTAssertEqual(parsed.first { $0.0 == "b" }?.1, "3")
        XCTAssertEqual(parsed.first { $0.0 == "a" }?.1, "1")
    }

    func testQueryParseDecodesPercentEscapesAndPlus() {
        let parsed = LiveQuery.parse("title=a%20b%26c&x=1%2B2")
        XCTAssertEqual(parsed.first { $0.0 == "title" }?.1, "a b&c")
        XCTAssertEqual(parsed.first { $0.0 == "x" }?.1, "1+2")
    }

    func testQueryParseSkipsEmptySegments() {
        XCTAssertTrue(LiveQuery.parse("").isEmpty)
        XCTAssertEqual(LiveQuery.parse("a=1&&b=2").count, 2)
        let bare = LiveQuery.parse("flag")
        XCTAssertEqual(bare.count, 1)
        XCTAssertEqual(bare[0].0, "flag")
        XCTAssertEqual(bare[0].1, "")
    }

    func testQueryBuildParseRoundTrip() {
        let pairs = [("fm", "abc=="), ("wsTime", "6553f5a0"), ("t", "100")]
        let parsed = LiveQuery.parse(LiveQuery.build(pairs))
        XCTAssertEqual(parsed.map { $0.0 }, ["fm", "wsTime", "t"])
        XCTAssertEqual(parsed.first { $0.0 == "fm" }?.1, "abc==")
    }

    // MARK: - LiveCrypto

    func testMd5HexOfKnownStrings() {
        XCTAssertEqual(LiveCrypto.md5Hex(""), "d41d8cd98f00b204e9800998ecf8427e")
        XCTAssertEqual(LiveCrypto.md5Hex("hello"), "5d41402abc4b2a76b9719d911017c592")
        XCTAssertEqual(LiveCrypto.md5Hex("hello danmaku"), LiveCrypto.md5Hex(Data("hello danmaku".utf8)))
    }

    func testMd5BytesMatchHex() {
        let bytes = LiveCrypto.md5(Data("abc".utf8))
        XCTAssertEqual(bytes.count, 16)
        XCTAssertEqual(bytes.map { String(format: "%02x", $0) }.joined(), "900150983cd24fb0d6963f7d28e17f72")
    }

    func testRandomHexHasRequestedLengthAndAlphabet() {
        let hex = LiveCrypto.randomHex(count: 32)
        XCTAssertEqual(hex.count, 32)
        XCTAssertTrue(hex.allSatisfy { "0123456789abcdef".contains($0) })
        XCTAssertNotEqual(LiveCrypto.randomHex(count: 32), LiveCrypto.randomHex(count: 32))
    }

    // MARK: - LiveHTTP request builders

    func testGetRequestCarriesQueryAndHeaders() {
        let url = URL(string: "https://example.com/api")!
        let request = LiveHTTP.getRequest(
            url: url,
            queryItems: [URLQueryItem(name: "id", value: "6")],
            headers: ["Referer": "https://live.bilibili.com/6"]
        )
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://example.com/api?id=6")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://live.bilibili.com/6")
        XCTAssertEqual(request.timeoutInterval, LiveHTTP.defaultTimeoutSeconds)
    }

    func testDefaultTimeoutIsSixSeconds() {
        XCTAssertEqual(LiveHTTP.defaultTimeoutSeconds, 6)
    }
}
