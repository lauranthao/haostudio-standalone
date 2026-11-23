// HAo Studio 2.0 — Emby synopsis-dedupe regression tests (S3 leg B).
//
// Regression for the build-31 "剧情介绍重复" bug: the Flutter
// detail page rendered `Overview` twice (header + expandable
// bottom block). The Swift side carries the synopsis in exactly
// one field (`VideoMeta.synopsis`) and dedupes the text itself in
// `EmbySynopsis.dedupe`, so no layer can show it twice. Pure
// function, no network. Swift 5.0.

import XCTest
@testable import AppCore

final class EmbySynopsisTests: XCTestCase {
    func testWholeTextDoubledCollapsesToOneCopy() {
        XCTAssertEqual(EmbySynopsis.dedupe("京海市的刑警安欣。 京海市的刑警安欣。"), "京海市的刑警安欣。")
        XCTAssertEqual(EmbySynopsis.dedupe("ABC ABC"), "ABC")
    }

    func testRepeatedParagraphsDroppedInOrder() {
        XCTAssertEqual(
            EmbySynopsis.dedupe("第一段。\n第一段。\n第二段。"),
            "第一段。\n第二段。"
        )
        XCTAssertEqual(
            EmbySynopsis.dedupe("甲\n乙\n甲\n丙"),
            "甲\n乙\n丙"
        )
    }

    func testDistinctParagraphsPreserved() {
        let text = "第一段。\n第二段。\n第三段。"
        XCTAssertEqual(EmbySynopsis.dedupe(text), text)
    }

    func testSingleParagraphUnchanged() {
        XCTAssertEqual(EmbySynopsis.dedupe("只有一段。"), "只有一段。")
    }

    func testEmptyAndWhitespace() {
        XCTAssertEqual(EmbySynopsis.dedupe(""), "")
        XCTAssertEqual(EmbySynopsis.dedupe("   \n  "), "")
    }

    func testAdjacentDuplicatesWithoutWhitespaceAreNotGuessed() {
        // "X。X。" with no separator between the copies is not
        // provably a duplication (it could be intentional text), so
        // the deduper leaves it alone rather than eating content.
        XCTAssertEqual(EmbySynopsis.dedupe("你好。你好。"), "你好。你好。")
    }
}
