// HAo Studio 2.0 — Bilibili WBI tests (S4 leg B).
//
// Mixin-key reorder and w_rid vectors are Python-computed against
// the Flutter algorithm (see BilibiliWbi.swift header notes).
// No network. Swift 5.0: no async/await, no `any`.

import XCTest
@testable import AppCore

final class BilibiliWbiTests: XCTestCase {
    private let imgKey = "7cd084941338484aae1ad9420b84077c"
    private let subKey = "4932caff0ff746eab6f011814e06a491"

    func testMixinKeyReordersAndTruncates() {
        XCTAssertEqual(
            BilibiliWbi.mixinKey(origin: imgKey + subKey),
            "ea1d1124af3c0062474693fa704f4ff8"
        )
    }

    func testSignParamsProducesKnownWRid() {
        let signed = BilibiliWbi.signParams(
            ["room_id": "6", "platform": "web"],
            mixinKey: BilibiliWbi.mixinKey(origin: imgKey + subKey),
            wtsSeconds: 1700000000
        )
        XCTAssertEqual(signed["w_rid"], "4b92666ee09eecdcd38f5d824645fab6")
        XCTAssertEqual(signed["wts"], "1700000000")
        XCTAssertEqual(signed["room_id"], "6")
        XCTAssertEqual(signed["platform"], "web")
    }

    func testSignParamsStripsSpecialCharacters() {
        let signed = BilibiliWbi.signParams(
            ["room_id": "6", "title": "a!b*c(d)e"],
            mixinKey: BilibiliWbi.mixinKey(origin: imgKey + subKey),
            wtsSeconds: 1700000000
        )
        XCTAssertEqual(signed["title"], "abcde")
        XCTAssertEqual(signed["w_rid"], "096b67b6ec4a8e86051e899b9c7ef293")
    }

    func testSignParamsKeepsExistingWRidOut() {
        let signed = BilibiliWbi.signParams(
            ["room_id": "6", "w_rid": "stale", "wts": "1"],
            mixinKey: BilibiliWbi.mixinKey(origin: imgKey + subKey),
            wtsSeconds: 1700000000
        )
        XCTAssertEqual(signed["wts"], "1700000000")
        XCTAssertNotEqual(signed["w_rid"], "stale")
    }

    func testKeyStemStripsExtension() {
        XCTAssertEqual(
            BilibiliWbi.keyStem(from: "https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9420b84077c.png"),
            "7cd084941338484aae1ad9420b84077c"
        )
        XCTAssertEqual(BilibiliWbi.keyStem(from: "plainkey"), "plainkey")
    }

    func testParseKeysFromNavJson() {
        let json = jsonObject("""
        {
            "data": {
                "wbi_img": {
                    "img_url": "https://i0.hdslb.com/bfs/wbi/\(imgKey).png",
                    "sub_url": "https://i0.hdslb.com/bfs/wbi/\(subKey).png"
                }
            }
        }
        """)
        let keys = BilibiliWbi.parseKeys(from: json)
        XCTAssertEqual(keys?.0, imgKey)
        XCTAssertEqual(keys?.1, subKey)
    }

    func testParseKeysReturnsNilWithoutWbiImg() {
        XCTAssertNil(BilibiliWbi.parseKeys(from: jsonObject("{}")))
    }
}
