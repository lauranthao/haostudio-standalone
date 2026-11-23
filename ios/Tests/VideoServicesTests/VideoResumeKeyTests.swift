// HAo Studio 2.0 — resume-key + danmaku-parser tests (S3 leg B).
//
// Pure functions, no network. Swift 5.0.

import XCTest
@testable import MusicLX

final class VideoResumeKeyTests: XCTestCase {
    func testKeyWithYear() {
        XCTAssertEqual(VideoResumeKey.key(title: "狂飙", year: "2023"), "狂飙-2023")
    }

    func testKeyWithoutYear() {
        XCTAssertEqual(VideoResumeKey.key(title: "狂飙", year: nil), "狂飙")
        XCTAssertEqual(VideoResumeKey.key(title: "狂飙", year: ""), "狂飙")
    }

    func testKeyTrimsYearWhitespace() {
        XCTAssertEqual(VideoResumeKey.key(title: "狂飙", year: " 2023 "), "狂飙-2023")
    }

    func testEpisodeId() {
        XCTAssertEqual(
            VideoResumeKey.episodeId(title: "狂飙", year: "2023", episodeName: "第1集"),
            "狂飙-2023#第1集"
        )
        XCTAssertEqual(
            VideoResumeKey.episodeId(title: "狂飙", year: nil, episodeName: "正片"),
            "狂飙#正片"
        )
    }
}

final class VodDanmakuParserTests: XCTestCase {
    func testFoldChineseNumerals() {
        XCTAssertEqual(VodDanmakuParsers.foldChineseNumerals("第二季"), "2季")
        XCTAssertEqual(VodDanmakuParsers.foldChineseNumerals("第十二季"), "12季")
        XCTAssertEqual(VodDanmakuParsers.foldChineseNumerals("第二十一集"), "21集")
        XCTAssertEqual(VodDanmakuParsers.foldChineseNumerals("第一百零三集"), "103集")
        XCTAssertEqual(VodDanmakuParsers.foldChineseNumerals("庆余年"), "庆余年")
    }

    func testMatchKeyFoldsWhitespaceAndNumeralsBothSides() {
        XCTAssertEqual(
            VodDanmakuParsers.matchKey("庆余年 第2季"),
            VodDanmakuParsers.matchKey("庆余年第二季")
        )
    }

    func testCandidatePassesTitleAndYearGates() {
        let candidate = VodDanmakuCandidate(name: "狂飙(2023)from iqiyi - 狂飙第1集", url: "https://x/danmaku?format=xml")
        XCTAssertTrue(VodDanmakuParsers.candidatePasses(candidate, queryTitle: "狂飙", year: "2023"))
        // Year mismatch rejects.
        XCTAssertFalse(VodDanmakuParsers.candidatePasses(candidate, queryTitle: "狂飙", year: "2019"))
        // No year in the candidate name passes.
        let noYear = VodDanmakuCandidate(name: "狂飙 from iqiyi - 狂飙第1集", url: "https://x/danmaku?format=xml")
        XCTAssertTrue(VodDanmakuParsers.candidatePasses(noYear, queryTitle: "狂飙", year: "2023"))
        // Season numeral is part of the key: S1 must not match S2.
        let s1 = VodDanmakuCandidate(name: "庆余年第一季(2019) - 庆余年第1集", url: "https://x/danmaku?format=xml")
        XCTAssertFalse(VodDanmakuParsers.candidatePasses(s1, queryTitle: "庆余年 第2季", year: "2024"))
    }

    func testSelectCandidateSkipsFailingCandidates() {
        let candidates = [
            VodDanmakuCandidate(name: "狂飙(2019) - 狂飙第1集", url: "https://x/a?format=xml"),
            VodDanmakuCandidate(name: "狂飙(2023) - 狂飙第1集", url: "https://x/b?format=xml"),
        ]
        XCTAssertEqual(
            VodDanmakuParsers.selectCandidate(candidates, queryTitle: "狂飙", year: "2023")?.url,
            "https://x/b?format=xml"
        )
    }

    func testParseCommentsJson() {
        let body = """
        {"count": 3, "comments": [
          {"cid": "1", "p": "12.5,1,16777215", "m": "好看", "t": 12.5},
          {"cid": "2", "p": "13.0,4,16711680", "m": "顶部弹幕", "t": 13.0},
          {"cid": "3", "p": "14.0,5,0", "m": "底部弹幕", "t": 14.0},
          {"cid": "4", "p": "bad", "m": "", "t": 15.0},
          {"cid": "5", "p": "16.0,1,16777215", "m": "无 t 字段取 p 首位"}
        ]}
        """
        let comments = VodDanmakuParsers.parseCommentsJson(body)
        XCTAssertEqual(comments.count, 4)
        XCTAssertEqual(comments[0].text, "好看")
        XCTAssertEqual(comments[0].time, 12.5)
        XCTAssertEqual(comments[0].colorRgb, 16777215)
        XCTAssertEqual(comments[0].kind, .scroll)
        XCTAssertEqual(comments[1].kind, .top)
        XCTAssertEqual(comments[2].kind, .bottom)
        XCTAssertEqual(comments[3].time, 16.0)
    }

    func testParseCommentsJsonUnparseableReturnsEmpty() {
        XCTAssertTrue(VodDanmakuParsers.parseCommentsJson("not json").isEmpty)
        XCTAssertTrue(VodDanmakuParsers.parseCommentsJson("{}").isEmpty)
    }

    func testRewriteCommentUrlToJson() {
        XCTAssertEqual(
            VodDanmakuParsers.rewriteCommentUrlToJson("https://x/danmaku?format=xml&id=1", baseUrl: "https://base.example")?.absoluteString,
            "https://x/danmaku?format=json&id=1"
        )
        // format added when absent.
        XCTAssertTrue(
            VodDanmakuParsers.rewriteCommentUrlToJson("https://x/danmaku?id=1", baseUrl: "https://base.example")?.absoluteString.contains("format=json") == true
        )
        // Relative URL resolves against the base.
        XCTAssertEqual(
            VodDanmakuParsers.rewriteCommentUrlToJson("/d/1?format=xml", baseUrl: "https://base.example")?.absoluteString,
            "https://base.example/d/1?format=json"
        )
        XCTAssertNil(VodDanmakuParsers.rewriteCommentUrlToJson("", baseUrl: "https://base.example"))
    }

    func testUniformSampleTimeline() {
        let items = (0..<10).map { DanmakuItem(text: "\($0)", timeSeconds: Double($0), colorHex: "", isTop: false) }
        let sampled = VodDanmakuParsers.uniformSampleTimeline(items, maxCount: 5)
        XCTAssertEqual(sampled.map { $0.text }, ["0", "2", "4", "6", "8"])
        XCTAssertEqual(VodDanmakuParsers.uniformSampleTimeline(items, maxCount: 0), [])
        XCTAssertEqual(VodDanmakuParsers.uniformSampleTimeline(items, maxCount: 20).count, 10)
    }
}
