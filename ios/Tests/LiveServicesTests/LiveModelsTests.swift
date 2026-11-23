// HAo Studio 2.0 — live models tests (S4 leg B).
//
// Platform ids, quality-echo resolution, applied URLs.
// No network. Swift 5.0: no async/await, no `any`.

import XCTest
@testable import AppCore

final class LiveModelsTests: XCTestCase {
    // MARK: - Platform ids (A-leg contract)

    func testPlatformRawValuesAreTheFivePlayerKernelIds() {
        XCTAssertEqual(LivePlatform.bilibili.rawValue, "bili")
        XCTAssertEqual(LivePlatform.douyu.rawValue, "douyu")
        XCTAssertEqual(LivePlatform.huya.rawValue, "huya")
        XCTAssertEqual(LivePlatform.douyin.rawValue, "douyin")
        XCTAssertEqual(LivePlatform.kuaishou.rawValue, "ks")
        XCTAssertEqual(LivePlatform.allCases.count, 5)
    }

    func testFlutterSiteIdsDifferForBilibiliAndKuaishou() {
        XCTAssertEqual(LivePlatform.bilibili.flutterSiteId, "bilibili")
        XCTAssertEqual(LivePlatform.douyu.flutterSiteId, "douyu")
        XCTAssertEqual(LivePlatform.huya.flutterSiteId, "huya")
        XCTAssertEqual(LivePlatform.douyin.flutterSiteId, "douyin")
        XCTAssertEqual(LivePlatform.kuaishou.flutterSiteId, "kuaishou")
    }

    func testRoomLinksUseThePlatformUrl() {
        XCTAssertEqual(LivePlatform.bilibili.roomLink(roomId: "6"), "https://live.bilibili.com/6")
        XCTAssertEqual(LivePlatform.douyu.roomLink(roomId: "123"), "https://www.douyu.com/123")
        XCTAssertEqual(LivePlatform.huya.roomLink(roomId: "123"), "https://www.huya.com/123")
        XCTAssertEqual(LivePlatform.douyin.roomLink(roomId: "abc"), "https://live.douyin.com/abc")
        XCTAssertEqual(LivePlatform.kuaishou.roomLink(roomId: "123"), "https://live.kuaishou.com/u/123")
    }

    // MARK: - Resolution / quality echo

    func testApplyingEchoesTheAppliedQualityAndDedupesUrls() {
        let lineA = LiveLine(name: "cdn-a", urls: ["https://a/x.flv", "https://a/y.flv"], format: "flv")
        let lineB = LiveLine(name: "cdn-b", urls: ["https://a/x.flv", "https://b/z.flv"], format: "flv")
        let applied = LiveQuality(id: "250", name: "超清", sort: 250, lines: [lineA, lineB])
        let advertised = LiveQuality(id: "10000", name: "原画", sort: 10000, lines: [])
        let resolution = LivePlayUrlResolution.applying(applied, in: [advertised, applied])
        XCTAssertEqual(resolution.quality?.id, "250")
        XCTAssertEqual(resolution.appliedUrls, ["https://a/x.flv", "https://a/y.flv", "https://b/z.flv"])
        XCTAssertEqual(resolution.formats, ["flv"])
        XCTAssertEqual(resolution.lines.count, 2)
    }

    func testApplyingWithNilQualityHasNoUrls() {
        let resolution = LivePlayUrlResolution.applying(nil, in: [])
        XCTAssertNil(resolution.quality)
        XCTAssertTrue(resolution.appliedUrls.isEmpty)
        XCTAssertTrue(resolution.lines.isEmpty)
    }

    func testResolutionFallsBackToTopLevelLinesWhenQualityIsAbsent() {
        let line = LiveLine(name: "cdn", urls: ["https://a/x.flv"], format: "flv")
        let resolution = LivePlayUrlResolution(lines: [line], qualities: [], quality: nil)
        XCTAssertEqual(resolution.appliedUrls, ["https://a/x.flv"])
    }

    // MARK: - Room / message defaults

    func testLiveRoomDefaultsToOffline() {
        let room = LiveRoom(roomId: "6", platform: .bilibili)
        XCTAssertFalse(room.isLive)
        XCTAssertEqual(room.onlineCount, 0)
        XCTAssertEqual(room.title, "")
        XCTAssertEqual(room.link, "")
        XCTAssertNil(room.data)
        XCTAssertNil(room.danmakuData)
    }

    func testDanmakuMessageDefaults() {
        let message = DanmakuMessage(text: "hello")
        XCTAssertEqual(message.text, "hello")
        XCTAssertEqual(message.colorArgb, 0xFFFFFFFF)
        XCTAssertEqual(message.kind, .scroll)
        XCTAssertFalse(message.isSuperChat)
        XCTAssertFalse(message.suspectedAutomated)
    }

    func testLiveLineAndQualityAreValueTypes() {
        let line = LiveLine(name: "cdn", urls: ["https://a/x.flv"], format: "flv")
        XCTAssertEqual(line.urls, ["https://a/x.flv"])
        XCTAssertEqual(line.format, "flv")
        let quality = LiveQuality(id: "0", name: "原画", sort: 1 << 30, lines: [line])
        XCTAssertEqual(quality.sort, 1 << 30)
    }
}
