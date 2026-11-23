// HAo Studio 2.0 — streaming search merge tests (S2-C leg).
//
// Dedupe by platform + songId (empty id falls back to title+artist),
// NetEase + QQ first, stable order within a platform.

import XCTest

@testable import MusicFeatures

final class MusicSearchMergeTests: XCTestCase {
    private func song(_ id: String, platform: MusicPlatform, title: String = "Song") -> MusicSong {
        return MusicSong(songId: id, title: title, artist: "Artist", platform: platform, dur: 200)
    }

    func testDedupeSamePlatformAndId() {
        var merge = MusicSearchMerge()
        let added = merge.appendBatch([song("1", platform: .wy), song("1", platform: .wy)])
        XCTAssertEqual(added.count, 1)
        XCTAssertEqual(merge.count, 1)
    }

    func testSameIdDifferentPlatformKept() {
        var merge = MusicSearchMerge()
        merge.appendBatch([song("1", platform: .wy), song("1", platform: .tx)])
        XCTAssertEqual(merge.count, 2)
    }

    func testEmptyIdFallsBackToTitleArtist() {
        var merge = MusicSearchMerge()
        let first = MusicSong(songId: "", title: "Same", artist: "A", platform: .wy)
        let dup = MusicSong(songId: "", title: "Same", artist: "A", platform: .wy)
        let other = MusicSong(songId: "", title: "Different", artist: "A", platform: .wy)
        merge.appendBatch([first, dup, other])
        XCTAssertEqual(merge.count, 2)
    }

    func testNetEaseAndQQFirst() {
        var merge = MusicSearchMerge()
        merge.appendBatch([
            song("kw1", platform: .kw, title: "Kw"),
            song("wy1", platform: .wy, title: "Wy"),
            song("tx1", platform: .tx, title: "Tx"),
            song("kg1", platform: .kg, title: "Kg"),
        ])
        XCTAssertEqual(merge.tracks.map { $0.platform }, [.wy, .tx, .kg, .kw])
    }

    func testLaterLegNeverReordersEarlierLeg() {
        var merge = MusicSearchMerge()
        merge.appendBatch([song("wy1", platform: .wy, title: "Wy1"), song("wy2", platform: .wy, title: "Wy2")])
        // A slower QQ leg arrives afterwards: its rows go after the
        // NetEase rows, but before any Kugou/Kuwo rows.
        merge.appendBatch([song("tx1", platform: .tx, title: "Tx1")])
        merge.appendBatch([song("kg1", platform: .kg, title: "Kg1")])
        XCTAssertEqual(merge.tracks.map { $0.title }, ["Wy1", "Wy2", "Tx1", "Kg1"])
    }

    func testStableWithinPlatform() {
        var merge = MusicSearchMerge()
        merge.appendBatch([
            song("a", platform: .wy, title: "A"),
            song("b", platform: .wy, title: "B"),
            song("c", platform: .wy, title: "C"),
        ])
        XCTAssertEqual(merge.tracks.map { $0.title }, ["A", "B", "C"])
    }

    func testDedupeAcrossBatchesKeepsFirstArrival() {
        var merge = MusicSearchMerge()
        merge.appendBatch([song("1", platform: .wy, title: "First")])
        let added = merge.appendBatch([song("1", platform: .wy, title: "Second")])
        XCTAssertEqual(added.count, 0)
        XCTAssertEqual(merge.tracks.first?.title, "First")
    }

    func testResetClears() {
        var merge = MusicSearchMerge()
        merge.appendBatch([song("1", platform: .wy)])
        merge.reset()
        XCTAssertTrue(merge.isEmpty)
        XCTAssertEqual(merge.count, 0)
        // After reset the same song can arrive again.
        merge.appendBatch([song("1", platform: .wy)])
        XCTAssertEqual(merge.count, 1)
    }

    func testDedupeKeyFoldsLiveVariants() {
        // "(Live)" variants of the same title+artist are one result.
        let live = musicSearchDedupeKey(title: "Song (Live)", artist: "A")
        let plain = musicSearchDedupeKey(title: "Song", artist: "A")
        XCTAssertEqual(live, plain)
    }
}
