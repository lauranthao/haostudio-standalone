// HAo Studio 2.0 — sleep timer tests (S2-C leg).
//
// The clock is fake: tests advance it by hand and call checkFire()
// directly, so no runloop and no real waiting are involved.

import XCTest

@testable import MusicFeatures

final class MusicSleepTimerTests: XCTestCase {
    /// Fake clock holder so the timer's `now` closure sees advances.
    private final class FakeClock {
        var now = Date(timeIntervalSince1970: 1_000_000)
    }

    private var clock: FakeClock!
    private var fired = 0
    private var changed = 0
    private var timer: MusicSleepTimer!

    override func setUp() {
        super.setUp()
        clock = FakeClock()
        fired = 0
        changed = 0
        timer = MusicSleepTimer(
            onFire: { [weak self] in self?.fired += 1 },
            onChanged: { [weak self] in self?.changed += 1 },
            now: { [weak self] in self?.clock.now ?? Date() }
        )
    }

    override func tearDown() {
        timer.cancel()
        timer = nil
        clock = nil
        super.tearDown()
    }

    func testWallClockFiresAtDeadline() {
        timer.start(.min5)
        XCTAssertTrue(timer.isActive)
        XCTAssertEqual(timer.remaining ?? -1, 300, accuracy: 0.5)
        clock.now = clock.now.addingTimeInterval(299)
        timer.checkFire()
        XCTAssertEqual(fired, 0)
        XCTAssertTrue(timer.isActive)
        clock.now = clock.now.addingTimeInterval(1)
        timer.checkFire()
        XCTAssertEqual(fired, 1)
        XCTAssertFalse(timer.isActive)
        XCTAssertNil(timer.remaining)
    }

    func testWallClockFiresExactlyOnce() {
        timer.start(.min5)
        clock.now = clock.now.addingTimeInterval(301)
        timer.checkFire()
        timer.checkFire()
        XCTAssertEqual(fired, 1)
    }

    func testRemainingTextCountsDown() {
        timer.start(.min5)
        XCTAssertEqual(timer.remainingText, "5:00")
        clock.now = clock.now.addingTimeInterval(61)
        timer.checkFire()
        XCTAssertEqual(timer.remainingText, "3:59")
    }

    func testCancelClears() {
        timer.start(.min15)
        XCTAssertTrue(timer.isActive)
        timer.cancel()
        XCTAssertFalse(timer.isActive)
        XCTAssertNil(timer.remaining)
        XCTAssertEqual(timer.option, .off)
        clock.now = clock.now.addingTimeInterval(3600)
        timer.checkFire()
        XCTAssertEqual(fired, 0)
    }

    func testCustomMinutesClamp() {
        XCTAssertEqual(clampSleepCustomMinutes(nil), 30)
        XCTAssertEqual(clampSleepCustomMinutes(0), 1)
        XCTAssertEqual(clampSleepCustomMinutes(1000), 720)
        XCTAssertEqual(clampSleepCustomMinutes(45), 45)
    }

    func testStartCustomUsesClampedMinutes() {
        timer.startCustom(minutes: 0)
        XCTAssertEqual(timer.customMinutes, 1)
        XCTAssertEqual(timer.remaining ?? -1, 60, accuracy: 0.5)
        timer.cancel()
        timer.startCustom(minutes: 1000)
        XCTAssertEqual(timer.customMinutes, 720)
    }

    func testAfterNTracksCountsNaturalCompletionsOnly() {
        timer.startAfterNTracks(count: 3)
        XCTAssertTrue(timer.isActive)
        XCTAssertNil(timer.remaining)
        XCTAssertFalse(timer.noteTrackCompleted())
        XCTAssertFalse(timer.noteTrackCompleted())
        XCTAssertTrue(timer.noteTrackCompleted())
    }

    func testAfterNTracksCountClamp() {
        XCTAssertEqual(clampSleepTrackCount(nil), 3)
        XCTAssertEqual(clampSleepTrackCount(0), 1)
        XCTAssertEqual(clampSleepTrackCount(99), 10)
    }

    func testSetTrackTargetMidRunRestartsCount() {
        timer.startAfterNTracks(count: 3)
        XCTAssertFalse(timer.noteTrackCompleted())
        XCTAssertFalse(timer.noteTrackCompleted())
        timer.setTrackTarget(2)
        // Count restarted: two more completions needed, not zero.
        XCTAssertFalse(timer.noteTrackCompleted())
        XCTAssertTrue(timer.noteTrackCompleted())
    }

    func testNoteTrackCompletedNoOpWhenNotAfterNTracks() {
        timer.start(.min5)
        XCTAssertFalse(timer.noteTrackCompleted())
        timer.cancel()
        XCTAssertFalse(timer.noteTrackCompleted())
    }

    func testCompletionModesHaveNoClock() {
        timer.start(.queueEnd)
        XCTAssertTrue(timer.isActive)
        XCTAssertTrue(timer.isQueueEnd)
        XCTAssertNil(timer.remaining)
        XCTAssertEqual(timer.remainingText, "")
        timer.cancel()
        timer.start(.currentTrackEnd)
        XCTAssertTrue(timer.isCurrentTrackEnd)
        XCTAssertNil(timer.remaining)
    }

    func testOptionLabels() {
        XCTAssertEqual(SleepTimerOption.min5.label, "5 分钟")
        XCTAssertEqual(SleepTimerOption.queueEnd.label, "到歌单结束")
        XCTAssertEqual(SleepTimerOption.currentTrackEnd.label, "播完本首后停止")
        XCTAssertEqual(SleepTimerOption.afterNTracks.label, "播完 N 首后停止")
        XCTAssertEqual(SleepTimerOption.custom.label, "自定义")
        XCTAssertEqual(SleepTimerOption.off.label, "关闭")
    }

    func testRemainingTextFormat() {
        XCTAssertEqual(sleepRemainingText(0), "0:00")
        XCTAssertEqual(sleepRemainingText(61), "1:01")
        XCTAssertEqual(sleepRemainingText(3599), "59:59")
    }
}
