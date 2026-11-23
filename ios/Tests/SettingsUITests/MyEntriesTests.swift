// HAo Studio 2.0 — My tab entry tests (S5-C leg).
//
// Pure logic only: no file I/O, no network, no real store data.
// Values are built inline; nothing reads Documents or
// UserDefaults. Isolation follows MigrationStoreTests.
//
// Wiring note: S7 wired this file to the app module
// (`@testable import HAoStudio`) under the `HAoStudioTests` Xcode
// test target, because MyView.swift is a SwiftUI file and AppCore
// has stayed Foundation-only.

import XCTest

@testable import HAoStudio

final class MyEntriesTests: XCTestCase {
    // MARK: - Entry counts

    func testAllEmptyCountsAreZero() {
        let counts = MyEntryCounts.make(
            playlists: [], favourites: [], recent: [], downloads: [],
            videoFavourites: [], videoHistory: [],
            liveFollows: [], liveHistory: [])
        XCTAssertEqual(counts.playlists, 0)
        XCTAssertEqual(counts.favourites, 0)
        XCTAssertEqual(counts.recent, 0)
        XCTAssertEqual(counts.downloads, 0)
        XCTAssertEqual(counts.videoFavourites, 0)
        XCTAssertEqual(counts.videoHistory, 0)
        XCTAssertEqual(counts.liveFollows, 0)
        XCTAssertEqual(counts.liveHistory, 0)
    }

    func testCountsMatchArrayLengths() {
        let counts = MyEntryCounts.make(
            playlists: [
                UserPlaylist(id: "p1", name: "A", tracks: []),
                UserPlaylist(id: "p2", name: "B", tracks: [])
            ],
            favourites: [
                MusicSong(songId: "s1", title: "Song One")
            ],
            recent: [
                MusicSong(songId: "s2", title: "Song Two"),
                MusicSong(songId: "s3", title: "Song Three"),
                MusicSong(songId: "s4", title: "Song Four")
            ],
            downloads: [
                DownloadedSong(json: [
                    "song": ["songId": "d1", "title": "Downloaded"],
                    "filePath": "music_downloads/d1.mp3",
                    "sizeBytes": 10,
                    "downloadedAt": 0,
                    "quality": "hires"
                ])
            ],
            videoFavourites: [
                VideoItem(id: "v1", title: "Film One", coverURL: nil, year: "2023", typeName: "电影", remarks: nil, sourceId: nil),
                VideoItem(id: "v2", title: "Film Two", coverURL: nil, year: "2024", typeName: "电影", remarks: nil, sourceId: nil)
            ],
            videoHistory: [
                VideoHistoryEntry(
                    item: VideoItem(id: "v1", title: "Film One", coverURL: nil, year: "2023", typeName: "电影", remarks: nil, sourceId: nil),
                    episodeName: "第01集", episodeIndex: 0, lineName: "线路1",
                    positionSeconds: 100, durationSeconds: 1000, updatedAt: Date())
            ],
            liveFollows: [
                LiveFollowedRoom(platform: "bili", roomId: "1", title: "Room One", nick: "Anchor", cover: "", followedAt: Date()),
                LiveFollowedRoom(platform: "douyu", roomId: "2", title: "Room Two", nick: "Anchor", cover: "", followedAt: Date())
            ],
            liveHistory: [])
        XCTAssertEqual(counts.playlists, 2)
        XCTAssertEqual(counts.favourites, 1)
        XCTAssertEqual(counts.recent, 3)
        XCTAssertEqual(counts.downloads, 1)
        XCTAssertEqual(counts.videoFavourites, 2)
        XCTAssertEqual(counts.videoHistory, 1)
        XCTAssertEqual(counts.liveFollows, 2)
        XCTAssertEqual(counts.liveHistory, 0)
    }

    // MARK: - Hex colour parsing

    func testValidHexParses() {
        XCTAssertNotNil(MyBackgroundColor.color(fromHex: "#FF0000"))
        XCTAssertNotNil(MyBackgroundColor.color(fromHex: "00ff00"))
        XCTAssertNotNil(MyBackgroundColor.color(fromHex: "  #F2F2F7  "))
    }

    func testInvalidHexReturnsNil() {
        XCTAssertNil(MyBackgroundColor.color(fromHex: ""))
        XCTAssertNil(MyBackgroundColor.color(fromHex: "#FFF"))
        XCTAssertNil(MyBackgroundColor.color(fromHex: "#GGGGGG"))
        XCTAssertNil(MyBackgroundColor.color(fromHex: "#FF00000"))
        XCTAssertNil(MyBackgroundColor.color(fromHex: "FF0000FF"))
    }

    // MARK: - Background priority

    func testWallpaperBeatsColor() {
        XCTAssertEqual(
            MyBackgroundColor.kind(
                wallpaperEnabled: true, wallpaperAvailable: true,
                bgColorEnabled: true, bgColorHex: "#FF0000"),
            .wallpaper)
    }

    func testMissingWallpaperFallsBackToColor() {
        XCTAssertEqual(
            MyBackgroundColor.kind(
                wallpaperEnabled: true, wallpaperAvailable: false,
                bgColorEnabled: true, bgColorHex: "#FF0000"),
            .color)
    }

    func testDisabledWallpaperFallsBackToColor() {
        XCTAssertEqual(
            MyBackgroundColor.kind(
                wallpaperEnabled: false, wallpaperAvailable: true,
                bgColorEnabled: true, bgColorHex: "#FF0000"),
            .color)
    }

    func testInvalidHexFallsBackToTheme() {
        XCTAssertEqual(
            MyBackgroundColor.kind(
                wallpaperEnabled: true, wallpaperAvailable: false,
                bgColorEnabled: true, bgColorHex: "not-a-color"),
            .theme)
    }

    func testEverythingOffIsTheme() {
        XCTAssertEqual(
            MyBackgroundColor.kind(
                wallpaperEnabled: false, wallpaperAvailable: false,
                bgColorEnabled: false, bgColorHex: "#FF0000"),
            .theme)
    }
}
