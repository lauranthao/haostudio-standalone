// HAo Studio 2.0 — Douban year-check + suggest-pick tests (S3 leg B).
//
// No network: pure parsers in DoubanService.swift. The year rule:
// a 1-year gap is tolerated (release-year vs first-air-year drift
// between sources); more than 1 year apart is a mismatch, and a
// mismatch must never be permanently cached. Swift 5.0.

import XCTest
@testable import AppCore

final class DoubanYearTests: XCTestCase {
    // MARK: - parseYear

    func testParseYear() {
        XCTAssertEqual(DoubanParsers.parseYear("2024"), 2024)
        XCTAssertEqual(DoubanParsers.parseYear("2024年上映"), 2024)
        XCTAssertEqual(DoubanParsers.parseYear("首播 1999-09-10"), 1999)
        XCTAssertEqual(DoubanParsers.parseYear(""), 0)
        XCTAssertEqual(DoubanParsers.parseYear(nil), 0)
        XCTAssertEqual(DoubanParsers.parseYear("没有年份"), 0)
    }

    // MARK: - yearsMismatch (±1 boundary)

    func testYearsMismatchBoundary() {
        // Exact match: no mismatch.
        XCTAssertFalse(DoubanParsers.yearsMismatch(gotYear: "2024", useYear: true, wantYear: 2024))
        // ±1 tolerated.
        XCTAssertFalse(DoubanParsers.yearsMismatch(gotYear: "2023", useYear: true, wantYear: 2024))
        XCTAssertFalse(DoubanParsers.yearsMismatch(gotYear: "2025", useYear: true, wantYear: 2024))
        // ±2 is a mismatch.
        XCTAssertTrue(DoubanParsers.yearsMismatch(gotYear: "2022", useYear: true, wantYear: 2024))
        XCTAssertTrue(DoubanParsers.yearsMismatch(gotYear: "2026", useYear: true, wantYear: 2024))
    }

    func testYearsMismatchUnknownYearsNeverMismatch() {
        // Unknown detail year: no evidence of a mismatch.
        XCTAssertFalse(DoubanParsers.yearsMismatch(gotYear: nil, useYear: true, wantYear: 2024))
        XCTAssertFalse(DoubanParsers.yearsMismatch(gotYear: "", useYear: true, wantYear: 2024))
        // Unknown wanted year: nothing to check against.
        XCTAssertFalse(DoubanParsers.yearsMismatch(gotYear: "2024", useYear: true, wantYear: 0))
        // Year check disabled (season-stripped titles don't enforce
        // a year): never a mismatch.
        XCTAssertFalse(DoubanParsers.yearsMismatch(gotYear: "2010", useYear: false, wantYear: 2024))
    }

    // MARK: - pickSuggestId

    private func hits() -> [DoubanSearchHit] {
        [
            DoubanSearchHit(id: "100", title: "狂飙", year: 2023, type: "movie"),
            DoubanSearchHit(id: "200", title: "狂飙前传", year: 2023, type: "movie"),
            DoubanSearchHit(id: "300", title: "狂飙", year: 2019, type: "movie"),
        ]
    }

    func testPickSuggestIdExactTitleAndYear() {
        XCTAssertEqual(DoubanParsers.pickSuggestId(hits: hits(), title: "狂飙", year: 2023), "100")
    }

    func testPickSuggestIdPrefersYearMatchOverTitlePrefix() {
        // The 2019 "狂飙" is an exact title match but 4 years off:
        // it must lose to the 2023 exact match.
        XCTAssertEqual(DoubanParsers.pickSuggestId(hits: hits(), title: "狂飙", year: 2023), "100")
    }

    func testPickSuggestIdRejectsYearMismatch() {
        // Only the 2019 hit matches the title, but the wanted year
        // is 2024 — more than 1 year away, so nothing is eligible.
        let onlyOld = [DoubanSearchHit(id: "300", title: "狂飙", year: 2019, type: "movie")]
        XCTAssertNil(DoubanParsers.pickSuggestId(hits: onlyOld, title: "狂飙", year: 2024))
    }

    func testPickSuggestIdNoTitleMatch() {
        XCTAssertNil(DoubanParsers.pickSuggestId(hits: hits(), title: "漫长的季节", year: 2023))
        XCTAssertNil(DoubanParsers.pickSuggestId(hits: [], title: "狂飙", year: 2023))
        XCTAssertNil(DoubanParsers.pickSuggestId(hits: hits(), title: "", year: 2023))
    }

    // MARK: - parseSuggestHits

    func testParseSuggestHitsDropsMalformedEntries() {
        let json: Any = [
            ["id": "1", "title": "狂飙", "year": 2023, "type": "movie"],
            ["title": "无 id", "year": 2023],
            "not a map",
            ["id": "2", "title": "流浪地球2", "year": "2023", "type": "movie"],
        ]
        let parsed = DoubanParsers.parseSuggestHits(json)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0].id, "1")
        XCTAssertEqual(parsed[1].year, 2023)
    }

    func testParseSuggestHitsNonListReturnsEmpty() {
        XCTAssertTrue(DoubanParsers.parseSuggestHits(["not": "a list"]).isEmpty)
        XCTAssertTrue(DoubanParsers.parseSuggestHits(nil).isEmpty)
    }
}
