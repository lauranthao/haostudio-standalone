// HAo Studio 2.0 — auto-resume checkpoint tests.
//
// Covers the pure decisions in MusicResumeLogic: the 10 s
// periodic gate, the pause/background immediate save, and the
// stored-position validation. No I/O, no player, no network —
// AppCore only, like WiringLogicTests.

import Foundation
import XCTest

@testable import AppCore

final class MusicResumeLogicTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - Periodic gate

    func testPeriodicSaveFiresWhenNothingSavedYet() {
        XCTAssertTrue(MusicResumeLogic.shouldSaveCheckpoint(
            isPlaying: true, position: 42,
            now: t0, lastSavedAt: nil, lastSavedKey: nil,
            lastSavedSeconds: 0, currentKey: "song-a"))
    }

    func testPeriodicSaveRequiresPlaying() {
        XCTAssertFalse(MusicResumeLogic.shouldSaveCheckpoint(
            isPlaying: false, position: 42,
            now: t0, lastSavedAt: nil, lastSavedKey: nil,
            lastSavedSeconds: 0, currentKey: "song-a"))
    }

    func testPeriodicSaveRequiresAPosition() {
        XCTAssertFalse(MusicResumeLogic.shouldSaveCheckpoint(
            isPlaying: true, position: 0,
            now: t0, lastSavedAt: nil, lastSavedKey: nil,
            lastSavedSeconds: 0, currentKey: "song-a"))
    }

    func testPeriodicSaveWaitsTenSeconds() {
        // Last save 9 s ago: not due yet.
        XCTAssertFalse(MusicResumeLogic.shouldSaveCheckpoint(
            isPlaying: true, position: 120,
            now: t0, lastSavedAt: t0.addingTimeInterval(-9),
            lastSavedKey: "song-a", lastSavedSeconds: 100,
            currentKey: "song-a"))
        // Last save 10 s ago: due.
        XCTAssertTrue(MusicResumeLogic.shouldSaveCheckpoint(
            isPlaying: true, position: 120,
            now: t0, lastSavedAt: t0.addingTimeInterval(-10),
            lastSavedKey: "song-a", lastSavedSeconds: 100,
            currentKey: "song-a"))
    }

    func testPeriodicSaveSkipsSmallMoves() {
        // Due by the clock (20 s), but the position only moved
        // 2 s since the last write: not worth rewriting the file.
        XCTAssertFalse(MusicResumeLogic.shouldSaveCheckpoint(
            isPlaying: true, position: 102,
            now: t0, lastSavedAt: t0.addingTimeInterval(-20),
            lastSavedKey: "song-a", lastSavedSeconds: 100,
            currentKey: "song-a"))
        // Moved 5 s: worth writing.
        XCTAssertTrue(MusicResumeLogic.shouldSaveCheckpoint(
            isPlaying: true, position: 105,
            now: t0, lastSavedAt: t0.addingTimeInterval(-20),
            lastSavedKey: "song-a", lastSavedSeconds: 100,
            currentKey: "song-a"))
    }

    func testPeriodicSaveFiresOnTrackChange() {
        // Same clock, same seconds, different song: the new
        // track has no checkpoint yet, so it must be written —
        // otherwise the old track's position would be saved
        // under the new track's key (or not at all).
        XCTAssertTrue(MusicResumeLogic.shouldSaveCheckpoint(
            isPlaying: true, position: 100,
            now: t0, lastSavedAt: t0.addingTimeInterval(-20),
            lastSavedKey: "song-a", lastSavedSeconds: 100,
            currentKey: "song-b"))
    }

    // MARK: - Immediate save (pause / background)

    func testSaveNowSkipsIdenticalCheckpoint() {
        XCTAssertFalse(MusicResumeLogic.shouldSaveNow(
            position: 100, lastSavedKey: "song-a",
            lastSavedSeconds: 100, currentKey: "song-a"))
    }

    func testSaveNowFiresAfterAMove() {
        XCTAssertTrue(MusicResumeLogic.shouldSaveNow(
            position: 101, lastSavedKey: "song-a",
            lastSavedSeconds: 100, currentKey: "song-a"))
    }

    func testSaveNowFiresForANewTrack() {
        XCTAssertTrue(MusicResumeLogic.shouldSaveNow(
            position: 100, lastSavedKey: "song-a",
            lastSavedSeconds: 100, currentKey: "song-b"))
    }

    func testSaveNowRequiresAPosition() {
        XCTAssertFalse(MusicResumeLogic.shouldSaveNow(
            position: 0, lastSavedKey: nil,
            lastSavedSeconds: 0, currentKey: "song-a"))
    }

    // MARK: - Stored-position validation

    func testValidPositionPasses() {
        XCTAssertEqual(
            MusicResumeLogic.validatedResumeSeconds(stored: 120, duration: 240), 120)
    }

    func testZeroOrNegativeIsNoResume() {
        XCTAssertNil(MusicResumeLogic.validatedResumeSeconds(stored: 0, duration: 240))
        XCTAssertNil(MusicResumeLogic.validatedResumeSeconds(stored: -5, duration: 240))
    }

    func testPositionAtOrPastTheEndIsNoResume() {
        // 3 s from the end: finished, start from 0.
        XCTAssertNil(MusicResumeLogic.validatedResumeSeconds(stored: 237, duration: 240))
        // Exactly at the end.
        XCTAssertNil(MusicResumeLogic.validatedResumeSeconds(stored: 240, duration: 240))
        // Past the end (track replaced by a shorter version).
        XCTAssertNil(MusicResumeLogic.validatedResumeSeconds(stored: 300, duration: 200))
    }

    func testUnknownDurationAcceptsAnyPositivePosition() {
        XCTAssertEqual(
            MusicResumeLogic.validatedResumeSeconds(stored: 120, duration: nil), 120)
        XCTAssertEqual(
            MusicResumeLogic.validatedResumeSeconds(stored: 120, duration: 0), 120)
    }

    // MARK: - Save -> restore round trip (logic only)

    func testCheckpointThenRestoreRoundTrip() {
        // Playing at 87 s, nothing saved yet: periodic gate fires.
        XCTAssertTrue(MusicResumeLogic.shouldSaveCheckpoint(
            isPlaying: true, position: 87,
            now: t0, lastSavedAt: nil, lastSavedKey: nil,
            lastSavedSeconds: 0, currentKey: "song-a"))
        // The stored 87 s restores against a 240 s track.
        XCTAssertEqual(
            MusicResumeLogic.validatedResumeSeconds(stored: 87, duration: 240), 87)
    }

    func testCompletedTrackLeavesNoResume() {
        // The track finished at 239/240 s: the stored end
        // position must not resume.
        XCTAssertNil(MusicResumeLogic.validatedResumeSeconds(stored: 239, duration: 240))
    }
}
