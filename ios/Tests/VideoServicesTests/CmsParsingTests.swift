// HAo Studio 2.0 — CMS parsing tests (S3 leg B).
//
// No network: every case feeds recorded JSON / strings into the
// pure parsers in CmsClient.swift. Swift 5.0: no async/await,
// no `any`.

import XCTest
@testable import AppCore

final class CmsParsingTests: XCTestCase {
    private func source() -> VideoSource {
        VideoSource(id: 1, name: "测试源", apiUrl: "https://example.com/api.php/provide/vod/", kind: "play", enabled: true, sort: 1)
    }

    // MARK: - Play lines

    func testParsePlayLinesM3u8FirstAndNeverDropped() {
        let lines = CmsClient.parsePlayLines(
            playUrl: "第01集$http://x/a.mp4#第02集$http://x/b.mp4$$$第01集$http://y/c.m3u8",
            playFrom: "线路1$$$线路2"
        )
        XCTAssertEqual(lines.count, 2)
        // The m3u8 line sorts first …
        XCTAssertTrue(lines[0].episodes.contains { $0.url?.absoluteString.contains(".m3u8") == true })
        // … and the mp4 line is kept after it, never dropped.
        XCTAssertTrue(lines[1].episodes.contains { $0.url?.absoluteString.contains(".mp4") == true })
        XCTAssertEqual(lines[1].episodes.count, 2)
    }

    func testParsePlayLinesEmptyNameBecomesZhengPianAndNonCjkLineName() {
        let lines = CmsClient.parsePlayLines(
            playUrl: "$http://x/a.m3u8",
            playFrom: "xyz"
        )
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].name, "线路1")
        XCTAssertEqual(lines[0].episodes[0].name, "正片")
        XCTAssertEqual(lines[0].episodes[0].index, 0)
    }

    func testParsePlayLinesSkipsEpisodesWithoutUrl() {
        let lines = CmsClient.parsePlayLines(
            playUrl: "第01集$#第02集$http://x/b.m3u8",
            playFrom: "线路"
        )
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].episodes.count, 1)
        XCTAssertEqual(lines[0].episodes[0].name, "第02集")
    }

    // MARK: - Content fallback

    func testContentFallbackPrefersM3u8OverMp4() {
        let lines = CmsClient.parsePlayLinesWithContentFallback(
            playUrl: "",
            playFrom: "",
            content: "watch <a href=\"http://x/f.mp4\">mp4</a> then http://y/g.m3u8 here"
        )
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].name, "直链")
        XCTAssertEqual(lines[0].episodes[0].name, "正片")
        XCTAssertTrue(lines[0].episodes[0].url?.absoluteString.contains(".m3u8") == true)
    }

    func testContentFallbackReturnsEmptyWhenNoDirectLink() {
        let lines = CmsClient.parsePlayLinesWithContentFallback(
            playUrl: "",
            playFrom: "",
            content: "nothing playable here, just text"
        )
        XCTAssertTrue(lines.isEmpty)
    }

    func testContentFallbackDoesNotOverrideParsedLines() {
        let lines = CmsClient.parsePlayLinesWithContentFallback(
            playUrl: "第01集$http://x/a.m3u8",
            playFrom: "线路",
            content: "http://y/other.mp4"
        )
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].episodes[0].url?.absoluteString.contains("x/a.m3u8") == true)
    }

    // MARK: - Detail

    func testParseCmsDetailRecordedFixture() {
        let json: [String: Any] = [
            "code": 1,
            "list": [[
                "vod_id": "123",
                "vod_name": "狂飙",
                "vod_pic": "http://example.com/pic.jpg",
                "vod_year": "2023",
                "type_name": "国产剧",
                "vod_remarks": "更新至第39集",
                "vod_actor": "张译, 张颂文",
                "vod_score": "8.5",
                "vod_content": "<p>京海市的刑警安欣。</p>",
                "vod_play_from": "线路1",
                "vod_play_url": "第01集$http://x/1.m3u8#第02集$http://x/2.m3u8",
            ]],
        ]
        guard let detail = CmsClient.parseCmsDetail(source: source(), vodId: "123", json: json) else {
            XCTFail("detail should parse")
            return
        }
        XCTAssertEqual(detail.item.title, "狂飙")
        XCTAssertEqual(detail.item.year, "2023")
        XCTAssertEqual(detail.lines.count, 1)
        XCTAssertEqual(detail.lines[0].episodes.count, 2)
        XCTAssertEqual(detail.meta?.cast, ["张译", "张颂文"])
        XCTAssertEqual(detail.meta?.rating, 8.5)
        XCTAssertEqual(detail.meta?.synopsis, "京海市的刑警安欣。")
    }

    func testParseCmsDetailNilWhenNoLines() {
        let json: [String: Any] = [
            "list": [[
                "vod_id": "123",
                "vod_name": "无源片",
                "vod_play_from": "",
                "vod_play_url": "",
                "vod_content": "",
            ]],
        ]
        XCTAssertNil(CmsClient.parseCmsDetail(source: source(), vodId: "123", json: json))
    }

    // MARK: - Probe / dedupe

    func testIsProbeOk() {
        XCTAssertTrue(CmsClient.isProbeOk(["code": 0]))
        XCTAssertTrue(CmsClient.isProbeOk(["list": []]))
        XCTAssertTrue(CmsClient.isProbeOk(["class": []]))
        XCTAssertFalse(CmsClient.isProbeOk([:]))
        XCTAssertFalse(CmsClient.isProbeOk(["code": 1]))
    }

    func testDedupeAndRankSearchCollapsesSameTitleAndYear() {
        func row(_ id: String, _ title: String, _ sourceId: Int) -> CmsSearchRow {
            CmsSearchRow(
                item: VideoItem(id: id, title: title, coverURL: nil, year: "2023", typeName: nil, remarks: nil, sourceId: sourceId),
                score: 0, hits: 0, area: ""
            )
        }
        let ranked = CmsClient.dedupeAndRankSearch(
            [row("1", "狂飙", 1), row("2", "狂飙", 2), row("3", "狂飙前传", 1)],
            query: "狂飙"
        )
        XCTAssertEqual(ranked.count, 2)
        XCTAssertEqual(ranked[0].title, "狂飙")
    }

    func testDedupeAndRankSearchCapsAtForty() {
        let rows = (0..<50).map { i in
            CmsSearchRow(
                item: VideoItem(id: "\(i)", title: "片名\(i)", coverURL: nil, year: nil, typeName: nil, remarks: nil, sourceId: 1),
                score: 0, hits: 0, area: ""
            )
        }
        XCTAssertEqual(CmsClient.dedupeAndRankSearch(rows, query: "片名").count, 40)
    }
}
