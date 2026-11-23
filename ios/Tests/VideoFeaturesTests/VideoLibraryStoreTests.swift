// HAo Studio 2.0 — video library store tests (S3-C leg).
//
// Pure rules only (no file I/O, no network): resume gating,
// history merge/dedupe, category prefs. The store's disk methods
// go through LocalStore and are covered by the S1 migration tests'
// approach (real Documents dir), not here.
//
// Wiring (S7, per the build #18 lesson — one file, one target):
// this target imports AppCore; B leg adds Services/Video plus the
// single file Features/Video/VideoLibraryStore.swift (Foundation
// only — no SwiftUI, no UIKit) to the AppCore sources, and a
// VideoFeaturesTests test target depending on it. Do NOT add
// VideoLibraryStore.swift to a second target.

import XCTest

@testable import AppCore

final class VideoLibraryStoreTests: XCTestCase {
    private func item(_ title: String, year: String? = "2023") -> VideoItem {
        VideoItem(id: "1", title: title, coverURL: nil, year: year,
                  typeName: "电视剧", remarks: nil, sourceId: nil)
    }

    private func entry(_ title: String, position: Double = 100, duration: Double = 1000) -> VideoHistoryEntry {
        VideoHistoryEntry(
            item: item(title), episodeName: "第01集", episodeIndex: 0,
            lineName: "线路1", positionSeconds: position,
            durationSeconds: duration, updatedAt: Date())
    }

    // MARK: - Resume gating (Flutter video_history_store rules)

    func testTooShortNeverResumes() {
        XCTAssertFalse(VideoLibraryStore.shouldResume(positionSeconds: 5, durationSeconds: 1000))
        XCTAssertFalse(VideoLibraryStore.shouldResume(positionSeconds: 10, durationSeconds: 1000))
    }

    func testJustOverTenSecondsResumes() {
        XCTAssertTrue(VideoLibraryStore.shouldResume(positionSeconds: 11, durationSeconds: 1000))
    }

    func testUnknownDurationResumesWhenOverTenSeconds() {
        XCTAssertTrue(VideoLibraryStore.shouldResume(positionSeconds: 60, durationSeconds: 0))
    }

    func testWithinThirtySecondsOfEndDoesNotResume() {
        XCTAssertFalse(VideoLibraryStore.shouldResume(positionSeconds: 975, durationSeconds: 1000))
        XCTAssertFalse(VideoLibraryStore.shouldResume(positionSeconds: 970, durationSeconds: 1000))
    }

    func testMoreThanThirtySecondsFromEndResumes() {
        XCTAssertTrue(VideoLibraryStore.shouldResume(positionSeconds: 969, durationSeconds: 1000))
    }

    // MARK: - History merge

    func testSameFilmReplacesInsteadOfDuplicating() {
        let merged = VideoLibraryStore.mergedHistory([entry("狂飙")], with: entry("狂飙", position: 200))
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].positionSeconds, 200)
    }

    func testNewestFirst() {
        let merged = VideoLibraryStore.mergedHistory([entry("狂飙")], with: entry("漫长的季节"))
        XCTAssertEqual(merged.map { $0.item.title }, ["漫长的季节", "狂飙"])
    }

    func testHistoryCappedAtTwenty() {
        var stored: [VideoHistoryEntry] = []
        for index in 0..<20 {
            stored.append(entry("剧\(index)"))
        }
        let merged = VideoLibraryStore.mergedHistory(stored, with: entry("新剧"))
        XCTAssertEqual(merged.count, 20)
        XCTAssertEqual(merged[0].item.title, "新剧")
        XCTAssertFalse(merged.contains { $0.item.title == "剧19" })
    }

    // MARK: - Category prefs

    func testHiddenCategoriesDropOut() {
        let prefs = VideoCategoryPrefs(hidden: ["综艺"], order: [])
        XCTAssertEqual(
            VideoLibraryStore.visibleCategories(["电影", "综艺", "电视剧"], prefs: prefs),
            ["电影", "电视剧"])
    }

    func testStoredOrderComesFirst() {
        let prefs = VideoCategoryPrefs(hidden: [], order: ["电视剧", "电影"])
        XCTAssertEqual(
            VideoLibraryStore.visibleCategories(["电影", "电视剧", "动漫"], prefs: prefs),
            ["电视剧", "电影", "动漫"])
    }

    func testUnknownCategoriesKeepGatewayOrder() {
        let prefs = VideoCategoryPrefs(hidden: [], order: ["不存在"])
        XCTAssertEqual(
            VideoLibraryStore.visibleCategories(["电影", "电视剧"], prefs: prefs),
            ["电影", "电视剧"])
    }
}
