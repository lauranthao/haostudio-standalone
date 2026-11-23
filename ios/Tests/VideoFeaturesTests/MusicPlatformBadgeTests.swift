// HAo Studio 2.0 — music platform badge tests (S3-C leg).
//
// The badge fix: an LX script result must show its REAL platform,
// never a defaulted 网易. `fromSourceID` keeps its old default
// (ordering / identity only); anything the user sees goes through
// `platformIfKnown` / `displayPlatform` / `badgePlatform`, which
// answer nil for an `lx:…` source id so the row hides the badge.
//
// Wiring (S7): this target imports AppCore — MusicTrack.swift is
// already an AppCore source (Services/MusicResolvers). No new
// target, no overlapping files (build #18 lesson).

import XCTest

@testable import AppCore

final class MusicPlatformBadgeTests: XCTestCase {
    func testKnownCodesMapDirectly() {
        XCTAssertEqual(MusicPlatform.platformIfKnown("wy"), .wy)
        XCTAssertEqual(MusicPlatform.platformIfKnown("tx"), .tx)
        XCTAssertEqual(MusicPlatform.platformIfKnown("kg"), .kg)
        XCTAssertEqual(MusicPlatform.platformIfKnown("kw"), .kw)
        XCTAssertEqual(MusicPlatform.platformIfKnown("mg"), .mg)
    }

    func testScriptIdHasNoPlatform() {
        XCTAssertNil(MusicPlatform.platformIfKnown("lx:suyin"))
        XCTAssertNil(MusicPlatform.platformIfKnown("lx:"))
    }

    func testUnknownOrEmptyHasNoPlatform() {
        XCTAssertNil(MusicPlatform.platformIfKnown("bogus"))
        XCTAssertNil(MusicPlatform.platformIfKnown(""))
        XCTAssertNil(MusicPlatform.platformIfKnown(nil))
    }

    func testTrackDisplayPlatformFollowsSourceID() {
        let scriptTrack = MusicTrack(id: "1", title: "Song", artist: "A", sourceID: "lx:suyin")
        XCTAssertNil(scriptTrack.displayPlatform)
        let txTrack = MusicTrack(id: "1", title: "Song", artist: "A", sourceID: "tx")
        XCTAssertEqual(txTrack.displayPlatform, .tx)
    }

    func testFromSourceIDKeepsOrderingDefault() {
        // Locked on purpose: fromSourceID is ordering/identity
        // only. If a badge ever reads it again, this test still
        // passes — the badge path is covered by the tests above,
        // not by this default.
        XCTAssertEqual(MusicPlatform.fromSourceID("lx:suyin"), .wy)
        XCTAssertEqual(MusicPlatform.fromSourceID("tx"), .tx)
    }
}
