// HAo Studio 2.0 — home aggregation tests (Home-B leg).
//
// The five home sections, driven through HomeViewModel's pure
// aggregation helpers and its injectable reload() overload —
// fixture data only, no files, no network. The public reload()
// itself only reads the local stores; its composition is covered
// here through the overload with the same inputs.
//
// Wiring (S7 pattern): Xcode test target HAoStudioTests, host app,
// @testable import HAoStudio. Package.swift untouched.

import XCTest

@testable import HAoStudio

@MainActor
final class HomeAggregationTests: XCTestCase {

    // MARK: - Fixtures

    private func videoItem(title: String, year: String? = "2024") -> VideoItem {
        VideoItem(
            id: title, title: title, coverURL: nil, year: year,
            typeName: nil, remarks: nil, sourceId: nil)
    }

    private func historyEntry(
        title: String,
        positionSeconds: Double,
        durationSeconds: Double,
        updatedAt: Date = Date(timeIntervalSince1970: 1000)
    ) -> VideoHistoryEntry {
        VideoHistoryEntry(
            item: videoItem(title: title), episodeName: "第01集",
            episodeIndex: 0, lineName: "线路1",
            positionSeconds: positionSeconds, durationSeconds: durationSeconds,
            updatedAt: updatedAt)
    }

    private func song(
        songId: String,
        title: String = "歌",
        artist: String = "歌手",
        dur: Int = 300
    ) -> MusicSong {
        MusicSong(
            songId: songId, title: title, artist: artist, cover: "",
            platform: .wy, dur: dur)
    }

    private func event(
        songId: String,
        title: String = "歌",
        artist: String = "歌手",
        totalDur: Int = 300,
        at: Int = 1000
    ) -> ListenEvent {
        ListenEvent(json: [
            "songId": songId, "title": title, "artist": artist,
            "platform": "wy", "cover": "", "dur": totalDur,
            "totalDur": totalDur, "at": at,
        ])
    }

    private func follow(
        platform: String = "bili",
        roomId: String,
        title: String = "直播间",
        followedAt: Date = Date(timeIntervalSince1970: 1000)
    ) -> LiveFollowedRoom {
        LiveFollowedRoom(
            platform: platform, roomId: roomId, title: title,
            nick: "主播", cover: "", followedAt: followedAt)
    }

    private func liveEntry(
        platform: String = "bili",
        roomId: String,
        title: String = "直播间",
        watchedAt: Date = Date(timeIntervalSince1970: 1000)
    ) -> LiveHistoryEntry {
        LiveHistoryEntry(
            platform: platform, roomId: roomId, title: title,
            nick: "主播", cover: "", watchedAt: watchedAt)
    }

    private func emptyReload(on viewModel: HomeViewModel) {
        viewModel.reload(
            videoHistory: [], recent: [], listenLog: [], resumeMap: [:],
            follows: [], liveHistory: [], dailyPicks: [])
    }

    // MARK: - HomeLiveItem identity

    func testHomeLiveItemIdIsPlatformPipeRoomId() {
        let item = HomeLiveItem(
            platform: "bili", roomId: "123", title: "间", nick: "播", cover: "")
        XCTAssertEqual(item.id, "bili|123")
    }

    func testSameRoomIdOnTwoPlatformsHasDifferentIds() {
        let bili = HomeLiveItem(
            platform: "bili", roomId: "1", title: "", nick: "", cover: "")
        let douyu = HomeLiveItem(
            platform: "douyu", roomId: "1", title: "", nick: "", cover: "")
        XCTAssertNotEqual(bili.id, douyu.id)
    }

    func testHomeLiveItemFromFollowAndHistoryShareId() {
        let fromFollow = HomeLiveItem(follow: follow(roomId: "7"))
        let fromHistory = HomeLiveItem(history: liveEntry(roomId: "7"))
        XCTAssertEqual(fromFollow.id, fromHistory.id)
        XCTAssertEqual(fromFollow.id, "bili|7")
    }

    // MARK: - Continue watching

    func testContinueWatchingTakesHistoryAsIs() {
        // Same as the video tab: history() raw, no shouldResume
        // filtering — a too-short row and a finished row both stay.
        let history = [
            historyEntry(
                title: "可续", positionSeconds: 120, durationSeconds: 600,
                updatedAt: Date(timeIntervalSince1970: 4000)),
            historyEntry(
                title: "太短", positionSeconds: 5, durationSeconds: 600,
                updatedAt: Date(timeIntervalSince1970: 3000)),
            historyEntry(
                title: "播完", positionSeconds: 590, durationSeconds: 600,
                updatedAt: Date(timeIntervalSince1970: 2000)),
            historyEntry(
                title: "未知时长", positionSeconds: 120, durationSeconds: 0,
                updatedAt: Date(timeIntervalSince1970: 1000)),
        ]
        let kept = HomeViewModel.continueWatchingEntries(from: history)
        XCTAssertEqual(
            kept.map { $0.item.title }, ["可续", "太短", "播完", "未知时长"])
    }

    func testContinueWatchingNewestFirst() {
        let old = historyEntry(
            title: "旧", positionSeconds: 120, durationSeconds: 600,
            updatedAt: Date(timeIntervalSince1970: 1000))
        let new = historyEntry(
            title: "新", positionSeconds: 120, durationSeconds: 600,
            updatedAt: Date(timeIntervalSince1970: 2000))
        let kept = HomeViewModel.continueWatchingEntries(from: [old, new])
        XCTAssertEqual(kept.map { $0.item.title }, ["新", "旧"])
    }

    func testContinueWatchingCapsAtTen() {
        var history: [VideoHistoryEntry] = []
        for index in 0..<12 {
            history.append(historyEntry(
                title: "片\(index)", positionSeconds: 120, durationSeconds: 600,
                updatedAt: Date(timeIntervalSince1970: 1000 + Double(index))))
        }
        XCTAssertEqual(HomeViewModel.continueWatchingEntries(from: history).count, 10)
    }

    func testContinueWatchingEmptyWhenNoData() {
        XCTAssertEqual(HomeViewModel.continueWatchingEntries(from: []).count, 0)
    }

    // MARK: - Music resume (continue listening)

    func testIsValidMusicResumeBoundaries() {
        // 10 s or less is not a resume point; 11 s is (unknown duration).
        XCTAssertFalse(HomeViewModel.isValidMusicResume(seconds: 10, durationSeconds: 0))
        XCTAssertTrue(HomeViewModel.isValidMusicResume(seconds: 11, durationSeconds: 0))
        // Within 30 s of the end is finished, not resumable.
        XCTAssertFalse(HomeViewModel.isValidMusicResume(seconds: 270, durationSeconds: 300))
        XCTAssertTrue(HomeViewModel.isValidMusicResume(seconds: 269, durationSeconds: 300))
    }

    func testResumeSongPrefersMostRecentValidResume() {
        let recent = [song(songId: "1"), song(songId: "2")]
        let resumeMap = ["wy|1": 120, "wy|2": 150]
        XCTAssertEqual(
            HomeViewModel.resumeSong(recent: recent, listenLog: [], resumeMap: resumeMap)?.songId,
            "1")
    }

    func testResumeSongIgnoresTooShortResume() {
        let recent = [song(songId: "1"), song(songId: "2")]
        // 5 s is not a resume point; nothing else has one either.
        let resumeMap = ["wy|1": 5]
        XCTAssertNil(
            HomeViewModel.resumeSong(recent: recent, listenLog: [], resumeMap: resumeMap))
    }

    func testResumeSongIgnoresFinishedResume() {
        let recent = [song(songId: "1", dur: 300)]
        // 290 s into a 300 s song is finished, not resumable.
        let resumeMap = ["wy|1": 290]
        XCTAssertNil(
            HomeViewModel.resumeSong(recent: recent, listenLog: [], resumeMap: resumeMap))
    }

    func testResumeSongFallsBackToListenLog() {
        // No valid resume in recent; the listen log's newest song has one.
        let recent = [song(songId: "1")]
        let log = [event(songId: "9", totalDur: 300, at: 1000)]
        let resumeMap = ["wy|9": 120]
        XCTAssertEqual(
            HomeViewModel.resumeSong(recent: recent, listenLog: log, resumeMap: resumeMap)?.songId,
            "9")
    }

    func testResumeSongNilWhenNothing() {
        XCTAssertNil(
            HomeViewModel.resumeSong(recent: [], listenLog: [], resumeMap: [:]))
    }

    // MARK: - Hot live

    func testHotLiveMergesFollowsAndHistoryDeduped() {
        let follows = [follow(roomId: "1", title: "关注标题")]
        let history = [
            liveEntry(roomId: "1", title: "历史标题",
                      watchedAt: Date(timeIntervalSince1970: 2000)),
            liveEntry(roomId: "2"),
        ]
        let items = HomeViewModel.hotLiveItems(follows: follows, history: history)
        XCTAssertEqual(items.count, 2)
        // Same room in both lists: one row, the newer record wins.
        XCTAssertEqual(items[0].id, "bili|1")
        XCTAssertEqual(items[0].title, "历史标题")
        XCTAssertEqual(items[1].id, "bili|2")
        // Nothing confirmed live yet: no LIVE badge.
        XCTAssertFalse(items[0].isLive)
        XCTAssertFalse(items[1].isLive)
    }

    func testHotLiveNewestFirstAcrossLists() {
        let follows = [follow(
            roomId: "1", followedAt: Date(timeIntervalSince1970: 1000))]
        let history = [liveEntry(
            roomId: "2", watchedAt: Date(timeIntervalSince1970: 3000))]
        let items = HomeViewModel.hotLiveItems(follows: follows, history: history)
        XCTAssertEqual(items.map { $0.roomId }, ["2", "1"])
    }

    func testHotLiveCapsAtTen() {
        var follows: [LiveFollowedRoom] = []
        for index in 0..<12 {
            follows.append(follow(
                roomId: "\(index)",
                followedAt: Date(timeIntervalSince1970: 1000 + Double(index))))
        }
        XCTAssertEqual(HomeViewModel.hotLiveItems(follows: follows, history: []).count, 10)
    }

    func testHotLiveEmptyWhenNoData() {
        XCTAssertEqual(HomeViewModel.hotLiveItems(follows: [], history: []).count, 0)
    }

    // MARK: - Daily picks (reused logic)

    func testDailyPicksReuseExistingLogic() {
        // Most-played song (3 plays) leads; the discovery half comes
        // from the top artist's other songs; same day = same list.
        let log = [
            event(songId: "1", artist: "甲", at: 1000),
            event(songId: "1", artist: "甲", at: 1001),
            event(songId: "1", artist: "甲", at: 1002),
            event(songId: "2", artist: "甲", at: 1003),
            event(songId: "3", artist: "乙", at: 1004),
        ]
        let first = HomeViewModel.computeDailyPicks(
            listenLog: log, favourites: [], recent: [], dayKey: "2026-11-23")
        let second = HomeViewModel.computeDailyPicks(
            listenLog: log, favourites: [], recent: [], dayKey: "2026-11-23")
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.first?.songId, "1")
        XCTAssertTrue(first.contains { $0.songId == "2" })
    }

    func testDailyPicksEmptyWhenNoData() {
        let picks = HomeViewModel.computeDailyPicks(
            listenLog: [], favourites: [], recent: [], dayKey: "2026-11-23")
        XCTAssertEqual(picks.count, 0)
    }

    // MARK: - reload() composition

    func testReloadWithEmptyInputsYieldsEmptySections() {
        let viewModel = HomeViewModel(liveStatusChecker: nil)
        emptyReload(on: viewModel)
        XCTAssertEqual(viewModel.continueWatching.count, 0)
        XCTAssertEqual(viewModel.continueListening.count, 0)
        XCTAssertEqual(viewModel.hotLive.count, 0)
        XCTAssertEqual(viewModel.daily.count, 0)
        XCTAssertEqual(viewModel.recentPlays.count, 0)
    }

    func testReloadFillsSectionsFromFixtures() {
        let viewModel = HomeViewModel(liveStatusChecker: nil)
        let recent = (0..<12).map { song(songId: "\($0)") }
        viewModel.reload(
            videoHistory: [
                historyEntry(
                    title: "可续", positionSeconds: 120, durationSeconds: 600,
                    updatedAt: Date(timeIntervalSince1970: 2000)),
                historyEntry(
                    title: "太短", positionSeconds: 5, durationSeconds: 600,
                    updatedAt: Date(timeIntervalSince1970: 1000)),
            ],
            recent: recent,
            listenLog: [],
            resumeMap: ["wy|3": 120],
            follows: [follow(roomId: "1", followedAt: Date(timeIntervalSince1970: 2000))],
            liveHistory: [liveEntry(roomId: "2", watchedAt: Date(timeIntervalSince1970: 1000))],
            dailyPicks: (0..<12).map { song(songId: "d\($0)") })
        // Continue watching: history as-is (video tab rule) — the
        // too-short row stays too, newest first.
        XCTAssertEqual(
            viewModel.continueWatching.map { $0.item.title }, ["可续", "太短"])
        // Continue listening: the resume song (recent #3), exactly one.
        XCTAssertEqual(viewModel.continueListening.map { $0.songId }, ["3"])
        // Hot live: follow + history, deduped.
        XCTAssertEqual(viewModel.hotLive.map { $0.roomId }, ["1", "2"])
        // Recent plays and daily: first 10, order kept.
        XCTAssertEqual(viewModel.recentPlays.count, 10)
        XCTAssertEqual(viewModel.recentPlays.first?.songId, "0")
        XCTAssertEqual(viewModel.daily.count, 10)
        XCTAssertEqual(viewModel.daily.first?.songId, "d0")
    }

    func testReloadFallsBackToFirstRecentWithoutResume() {
        let viewModel = HomeViewModel(liveStatusChecker: nil)
        let recent = [song(songId: "1"), song(songId: "2")]
        viewModel.reload(
            videoHistory: [], recent: recent, listenLog: [], resumeMap: [:],
            follows: [], liveHistory: [], dailyPicks: [])
        XCTAssertEqual(viewModel.continueListening.map { $0.songId }, ["1"])
    }

    func testReloadWithNoRecentHasEmptyContinueListening() {
        let viewModel = HomeViewModel(liveStatusChecker: nil)
        emptyReload(on: viewModel)
        XCTAssertEqual(viewModel.continueListening.count, 0)
    }

    func testReloadDoesNotCallCheckerWhenNoLiveRooms() {
        var calls = 0
        let viewModel = HomeViewModel(liveStatusChecker: { _, completion in
            calls += 1
            completion(true)
        })
        emptyReload(on: viewModel)
        XCTAssertEqual(calls, 0)
    }

    func testReloadAppliesConfirmedLiveStatus() {
        let viewModel = HomeViewModel(liveStatusChecker: { item, completion in
            // Only room "1" is on air; room "2" is unknown.
            completion(item.roomId == "1")
        })
        viewModel.reload(
            videoHistory: [], recent: [], listenLog: [], resumeMap: [:],
            follows: [follow(roomId: "1", followedAt: Date(timeIntervalSince1970: 2000))],
            liveHistory: [liveEntry(roomId: "2", watchedAt: Date(timeIntervalSince1970: 1000))],
            dailyPicks: [])
        // The checker answers synchronously; the view model applies
        // it on the next main-queue turn.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        XCTAssertEqual(viewModel.hotLive.map { $0.roomId }, ["1", "2"])
        XCTAssertEqual(viewModel.hotLive.map { $0.isLive }, [true, false])
    }
}
