// HAo Studio 2.0 — listen report tests (S2-C leg).
//
// Pure local aggregation of the listen log (Flutter
// ListenReport.compute): calendar ranges, totals, top songs /
// artists / platforms, per-day counts.

import XCTest

@testable import HAoStudio

final class MusicReportTests: XCTestCase {
    private func event(
        songId: String, title: String, artist: String, platform: MusicPlatform,
        dur: Int, totalDur: Int, at: Int
    ) -> ListenEvent {
        return ListenEvent(json: [
            "songId": songId, "title": title, "artist": artist,
            "platform": platform.rawValue, "cover": "", "dur": dur,
            "totalDur": totalDur, "at": at,
        ])
    }

    /// Fixed "now": Wednesday 2026-11-25 12:00 local. Monday of that
    /// week is 2026-11-23; the month started 2026-11-01.
    private var now: Date {
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 11
        comps.day = 25
        comps.hour = 12
        return Calendar.current.date(from: comps) ?? Date()
    }

    private func ms(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Int {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        let date = Calendar.current.date(from: comps) ?? Date()
        return Int(date.timeIntervalSince1970 * 1000)
    }

    func testWeekRangeStartsMonday() {
        let events = [
            event(songId: "sunday", title: "Sun", artist: "A", platform: .wy, dur: 100, totalDur: 200, at: ms(2026, 11, 22)),
            event(songId: "monday", title: "Mon", artist: "A", platform: .wy, dur: 100, totalDur: 200, at: ms(2026, 11, 23)),
        ]
        let report = MusicDiscoveryViewModel.computeReport(events: events, range: .week, now: now)
        XCTAssertEqual(report.totalPlays, 1)
        XCTAssertEqual(report.topSongs.first?.song.songId, "monday")
    }

    func testMonthRangeStartsFirst() {
        let events = [
            event(songId: "oct", title: "Oct", artist: "A", platform: .wy, dur: 100, totalDur: 200, at: ms(2026, 10, 31)),
            event(songId: "nov", title: "Nov", artist: "A", platform: .wy, dur: 100, totalDur: 200, at: ms(2026, 11, 1)),
        ]
        let report = MusicDiscoveryViewModel.computeReport(events: events, range: .month, now: now)
        XCTAssertEqual(report.totalPlays, 1)
        XCTAssertEqual(report.topSongs.first?.song.songId, "nov")
    }

    func testAllRangeIncludesEverything() {
        let events = [
            event(songId: "old", title: "Old", artist: "A", platform: .wy, dur: 60, totalDur: 200, at: ms(2025, 1, 1)),
            event(songId: "new", title: "New", artist: "B", platform: .tx, dur: 90, totalDur: 200, at: ms(2026, 11, 25)),
        ]
        let report = MusicDiscoveryViewModel.computeReport(events: events, range: .all, now: now)
        XCTAssertEqual(report.totalPlays, 2)
        XCTAssertEqual(report.totalSeconds, 150)
    }

    func testTopSongsCountPlaysNotSeconds() {
        let events = [
            event(songId: "a", title: "A", artist: "X", platform: .wy, dur: 30, totalDur: 200, at: ms(2026, 11, 24)),
            event(songId: "a", title: "A", artist: "X", platform: .wy, dur: 30, totalDur: 200, at: ms(2026, 11, 24)),
            event(songId: "b", title: "B", artist: "Y", platform: .wy, dur: 180, totalDur: 200, at: ms(2026, 11, 24)),
        ]
        let report = MusicDiscoveryViewModel.computeReport(events: events, range: .week, now: now)
        XCTAssertEqual(report.topSongs.first?.song.songId, "a")
        XCTAssertEqual(report.topSongs.first?.plays, 2)
        // The row shows the FULL song length, not heard seconds.
        XCTAssertEqual(report.topSongs.first?.song.dur, 200)
        XCTAssertEqual(report.totalSeconds, 240)
    }

    func testTopArtistsAndPlatforms() {
        let events = [
            event(songId: "a", title: "A", artist: "X", platform: .wy, dur: 10, totalDur: 200, at: ms(2026, 11, 24)),
            event(songId: "b", title: "B", artist: "X", platform: .tx, dur: 10, totalDur: 200, at: ms(2026, 11, 24)),
            event(songId: "c", title: "C", artist: "Y", platform: .tx, dur: 10, totalDur: 200, at: ms(2026, 11, 24)),
        ]
        let report = MusicDiscoveryViewModel.computeReport(events: events, range: .week, now: now)
        XCTAssertEqual(report.topArtists.first?.artist, "X")
        XCTAssertEqual(report.topArtists.first?.plays, 2)
        XCTAssertEqual(report.topPlatforms.first?.platform, .tx)
        XCTAssertEqual(report.topPlatforms.first?.plays, 2)
    }

    func testEmptyLogGivesEmptyReport() {
        let report = MusicDiscoveryViewModel.computeReport(events: [], range: .week, now: now)
        XCTAssertEqual(report, ListenReport.empty)
    }

    func testPerDayCounts() {
        let events = [
            event(songId: "a", title: "A", artist: "X", platform: .wy, dur: 10, totalDur: 200, at: ms(2026, 11, 24, 10)),
            event(songId: "b", title: "B", artist: "X", platform: .wy, dur: 10, totalDur: 200, at: ms(2026, 11, 24, 11)),
            event(songId: "c", title: "C", artist: "X", platform: .wy, dur: 10, totalDur: 200, at: ms(2026, 11, 25, 10)),
        ]
        let report = MusicDiscoveryViewModel.computeReport(events: events, range: .week, now: now)
        XCTAssertEqual(report.perDay.count, 2)
        XCTAssertEqual(report.perDay.first?.plays, 2)
    }
}
