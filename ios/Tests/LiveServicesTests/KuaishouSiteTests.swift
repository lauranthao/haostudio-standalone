// HAo Studio 2.0 — Kuaishou site tests (S4 leg B).
//
// Initial-state extraction, room page (author.id rule, poster
// .jpg rule), play qualities (codec rank, merge, labels), and
// one end-to-end resolve via a stub fetcher. No network.
// Swift 5.0: no async/await, no `any`.

import XCTest
@testable import AppCore

final class KuaishouSiteTests: XCTestCase {
    private var roomPageHTML: String {
        """
        <html><head></head><body><script>
        window.__INITIAL_STATE__ = {"liveroom":{"playList":[{"author":{"id":"ks123","name":"主播","description":"测试\\n直播","avatar":"https://a/avatar.jpg"},"liveStream":{"id":"LS123","poster":"https://a/cover","playUrls":{"h264":{"adaptationSet":{"representation":[{"url":"https://cdn1/x.m3u8","name":"超清","level":3,"bitrate":3000000},{"url":"https://cdn1/y.flv","name":"高清","level":2,"bitrate":2000000}]}}}},"gameInfo":{"watchingCount":555},"isLiving":true}]}};
        </script></body></html>
        """
        }

        // MARK: - Initial state

        func testExtractInitialState() throws {
        let state = try KuaishouLiveSite.extractKuaishouInitialState(html: roomPageHTML)
        XCTAssertNotNil(state["liveroom"])
        }

        func testExtractInitialStateConvertsUndefinedToNull() throws {
        let html = "<script>window.__INITIAL_STATE__ = {\"a\": undefined, \"b\": 1};</script>"
        let state = try KuaishouLiveSite.extractKuaishouInitialState(html: html)
        XCTAssertTrue(state["a"] is NSNull)
        XCTAssertEqual(LiveJSON.asInt(state["b"]), 1)
        }

        func testExtractInitialStateThrowsWithoutMarker() {
        XCTAssertThrowsError(try KuaishouLiveSite.extractKuaishouInitialState(html: "<html></html>"))
        }

        // MARK: - Room page

        func testParseRoomPageLive() throws {
        let room = try KuaishouLiveSite.parseKuaishouRoomPage(html: roomPageHTML, roomId: "ks123")
        XCTAssertEqual(room.roomId, "ks123")
        XCTAssertEqual(room.platform, .kuaishou)
        XCTAssertEqual(room.title, "测试 直播")
        XCTAssertEqual(room.streamer, "主播")
        XCTAssertEqual(room.avatar, "https://a/avatar.jpg")
        XCTAssertEqual(room.cover, "https://a/cover.jpg")
        XCTAssertEqual(room.onlineCount, 555)
        XCTAssertTrue(room.isLive)
        XCTAssertEqual(room.link, "LS123")
        XCTAssertEqual(room.danmakuData?["liveStreamId"] as? String, "LS123")
        XCTAssertNotNil(room.data?["playUrls"])
        }

        func testParseRoomPageOfflineHasZeroWatching() throws {
        let html = roomPageHTML.replacingOccurrences(of: "\"isLiving\":true", with: "\"isLiving\":false")
        let room = try KuaishouLiveSite.parseKuaishouRoomPage(html: html, roomId: "ks123")
        XCTAssertFalse(room.isLive)
        XCTAssertEqual(room.onlineCount, 0)
        XCTAssertEqual(room.title, "测试 直播")
        }

        func testParseRoomPageThrowsWithoutRoomMetadata() {
        let html = "<script>window.__INITIAL_STATE__ = {\"liveroom\":{}};</script>"
        XCTAssertThrowsError(try KuaishouLiveSite.parseKuaishouRoomPage(html: html, roomId: "ks123"))
        }

        func testParseRoomPageFallsBackToTopLevelRoom() throws {
        let html = "<script>window.__INITIAL_STATE__ = {\"room\":{\"author\":{\"id\":\"ks999\",\"name\":\"替补\"},\"liveStream\":{\"id\":\"LS999\",\"poster\":\"https://a/p.png\"},\"isLiving\":1}};</script>"
        let room = try KuaishouLiveSite.parseKuaishouRoomPage(html: html, roomId: "ks999")
        XCTAssertEqual(room.roomId, "ks999")
        XCTAssertEqual(room.streamer, "替补")
        XCTAssertTrue(room.isLive)
        XCTAssertEqual(room.cover, "https://a/p.png")
        }

        // MARK: - Play qualities

        private var playUrlsJSON: String {
        """
        {"h264":{"adaptationSet":{"representation":[{"url":"https://cdn1/x.m3u8","name":"超清","level":3,"bitrate":3000000},{"url":"https://cdn1/y.flv","name":"高清","level":2,"bitrate":2000000}]}},"hevc":{"adaptationSet":{"representation":[{"url":"https://cdn2/x.m3u8","name":"超清","level":3,"bitrate":3000000}]}}}
        """
        }

        func testParsePlayQualitiesCodecRankThenSort() {
        let qualities = KuaishouLiveSite.parseKuaishouPlayQualities(jsonObject(playUrlsJSON))
        XCTAssertEqual(qualities.map { $0.name }, ["超清", "高清", "超清 · H.265"])
        XCTAssertEqual(qualities.map { $0.sort }, [3, 2, 3])
        XCTAssertEqual(qualities[0].lines[0].format, "hls")
        XCTAssertEqual(qualities[1].lines[0].format, "flv")
        XCTAssertEqual(qualities[0].id, "超清\0" + "3")
        }

        func testParsePlayQualitiesMergesSameQualityAcrossCdns() {
        let raw = jsonObject("""
        {"h264":{"adaptationSet":{"representation":[{"url":"https://cdn1/x.m3u8","name":"超清","level":3},{"url":"https://cdn2/x.m3u8","name":"超清","level":3}]}}}
        """)
        let qualities = KuaishouLiveSite.parseKuaishouPlayQualities(raw)
        XCTAssertEqual(qualities.count, 1)
        XCTAssertEqual(qualities[0].lines.count, 2)
        XCTAssertEqual(qualities[0].lines.map { $0.name }, ["cdn1", "cdn2"])
    }

    func testParsePlayQualitiesEmpty() {
        XCTAssertTrue(KuaishouLiveSite.parseKuaishouPlayQualities(nil).isEmpty)
        XCTAssertTrue(KuaishouLiveSite.parseKuaishouPlayQualities(jsonObject("{}")).isEmpty)
    }

    // MARK: - Labels / format / poster

    func testNormalizeQualityLabel() {
        XCTAssertEqual(KuaishouLiveSite.normalizeKuaishouQualityLabel("original"), "原画")
        XCTAssertEqual(KuaishouLiveSite.normalizeKuaishouQualityLabel("blue"), "蓝光")
        XCTAssertEqual(KuaishouLiveSite.normalizeKuaishouQualityLabel("uhd"), "超清")
        XCTAssertEqual(KuaishouLiveSite.normalizeKuaishouQualityLabel("hd"), "高清")
        XCTAssertEqual(KuaishouLiveSite.normalizeKuaishouQualityLabel("sd"), "标清")
        XCTAssertEqual(KuaishouLiveSite.normalizeKuaishouQualityLabel("low"), "流畅")
        XCTAssertEqual(KuaishouLiveSite.normalizeKuaishouQualityLabel("蓝光 4M"), "蓝光 4M")
        XCTAssertEqual(KuaishouLiveSite.normalizeKuaishouQualityLabel(""), "默认")
    }

    func testStreamFormatAndPoster() {
        XCTAssertEqual(KuaishouLiveSite.kuaishouStreamFormat("https://cdn/x.m3u8?tx=1"), "hls")
        XCTAssertEqual(KuaishouLiveSite.kuaishouStreamFormat("https://cdn/x.flv"), "flv")
        XCTAssertEqual(KuaishouLiveSite.kuaishouStreamFormat("https://cdn/x"), "other")
        XCTAssertEqual(KuaishouLiveSite.posterUrl("https://a/cover"), "https://a/cover.jpg")
        XCTAssertEqual(KuaishouLiveSite.posterUrl("https://a/cover.png"), "https://a/cover.png")
        XCTAssertEqual(KuaishouLiveSite.posterUrl(""), "")
    }

    // MARK: - Resolve end to end

    func testResolveReturnsFirstQuality() {
        let site = KuaishouLiveSite(fetcher: stubFetcher(data: jsonData(roomPageHTML), status: 200))
        let expectation = self.expectation(description: "resolve")
        site.resolve(roomId: "ks123", quality: nil) { result in
            if case .success(let resolution) = result {
                XCTAssertEqual(resolution.quality?.name, "超清")
                XCTAssertEqual(resolution.appliedUrls, ["https://cdn1/x.m3u8"])
                XCTAssertNil(resolution.refreshAt)
                XCTAssertNil(resolution.invalidAt)
            } else {
                XCTFail("expected success, got \(result)")
            }
            expectation.fulfill()
        }
        waitForExpectations(timeout: 5)
    }

    func testResolveOfflineRoomFailsOffline() {
        let html = roomPageHTML.replacingOccurrences(of: "\"isLiving\":true", with: "\"isLiving\":false")
        let site = KuaishouLiveSite(fetcher: stubFetcher(data: jsonData(html), status: 200))
        let expectation = self.expectation(description: "offline")
        site.resolve(roomId: "ks123", quality: nil) { result in
            if case .failure(let error as LiveError) = result {
                if case .offline = error {
                    // Expected.
                } else {
                    XCTFail("expected LiveError.offline, got \(error)")
                }
            } else {
                XCTFail("expected LiveError.offline, got \(result)")
            }
            expectation.fulfill()
        }
        waitForExpectations(timeout: 5)
    }
}
