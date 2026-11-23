// HAo Studio 2.0 — video resume-key tests (S3-C leg).
//
// Pure logic, no I/O, no network. The resume identity is title +
// year (a CMS vod_id drifts on reseed and is never the key).
//
// Wiring (S7, per the build #18 lesson — one file, one target):
// this target imports AppCore; B leg adds Services/Video to the
// AppCore sources (no new target, no overlapping files) and a
// VideoFeaturesTests test target depending on it.

import XCTest

@testable import AppCore

final class VideoResumeKeyTests: XCTestCase {
    func testKeyWithYear() {
        XCTAssertEqual(VideoResumeKey.key(title: "狂飙", year: "2023"), "狂飙-2023")
    }

    func testKeyWithoutYearIsTitleOnly() {
        XCTAssertEqual(VideoResumeKey.key(title: "狂飙", year: nil), "狂飙")
        XCTAssertEqual(VideoResumeKey.key(title: "狂飙", year: "  "), "狂飙")
    }

    func testKeyTrimsYearWhitespace() {
        XCTAssertEqual(VideoResumeKey.key(title: "狂飙", year: " 2023 "), "狂飙-2023")
    }

    func testSameTitleDifferentYearIsDifferentFilm() {
        // A remake with a different known year never matches the
        // original — it must not resume the original's position.
        XCTAssertNotEqual(
            VideoResumeKey.key(title: "倩女幽魂", year: "1987"),
            VideoResumeKey.key(title: "倩女幽魂", year: "2020"))
    }

    func testEpisodeId() {
        XCTAssertEqual(
            VideoResumeKey.episodeId(title: "狂飙", year: "2023", episodeName: "第01集"),
            "狂飙-2023#第01集")
    }

    func testEpisodeIdWithoutYear() {
        XCTAssertEqual(
            VideoResumeKey.episodeId(title: "狂飙", year: nil, episodeName: "正片"),
            "狂飙#正片")
    }
}
