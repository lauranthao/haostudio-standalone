// HAo Studio 2.0 — wiring follow-up behaviour tests.
//
// Two leftovers from the S7 wiring round, same isolation pattern
// as WiringBehaviourTests: a fresh UserDefaults suite (UUID) per
// test; the audio-session tests reset the session to no-options
// in setUp AND tearDown so mixWithOthers cannot leak in or out.
//
// 1. dialogueBoost (the 17th dead key): the driver remembers the
//    switch, forwards it live to a capable backend (MPV only),
//    and re-applies it at open; the MPV filter string is checked
//    byte-for-byte against Flutter's kDialogueBoostCentreFilter.
// 2. mixWithOthers: a VOD / live open must not wipe the music
//    player's mix flag — both drivers re-apply the stored switch
//    when they set the audio session (Flutter's just_audio never
//    resets the category, so it never had this bug).
//
// Runs in the HAoStudioTests app host (@testable import HAoStudio).
// Written, not run on this VM (no Swift toolchain) — like every
// other 2.0 test, they run on the final Codemagic build.

import AVFoundation
import Foundation
import XCTest

@testable import HAoStudio

// MARK: - Dialogue boost (VideoDriver + MPV)

final class DialogueBoostDriverTests: XCTestCase {
    func testSetDialogueBoostStoredAndAppliedAtOpenAndLive() {
        let (detail, line, episode) = makeTestDetail()
        let backend = CapableFakeBackend(engine: .mpv)
        let driver = VideoDriver()
        driver.makeBackend = { _ in backend }
        let resolver = FakeVideoResolver()
        resolver.urlsToReturn = [URL(string: "https://a.b/movie.mp4")!]
        driver.playURLResolver = resolver
        driver.openTimeoutInterval = 5
        // Set before the backend exists: stored, applied at open.
        driver.setDialogueBoost(true)
        XCTAssertTrue(driver.currentDialogueBoost)
        let started = expectation(description: "episode started")
        driver.onEpisodeStarted = { _ in started.fulfill() }
        driver.playEpisode(detail: detail, line: line, episode: episode)
        waitForExpectations(timeout: 2)
        XCTAssertEqual(backend.dialogueBoostCalls, [true])
        // Live toggle: applied at once, no reopen.
        driver.setDialogueBoost(false)
        XCTAssertEqual(backend.dialogueBoostCalls, [true, false])
        XCTAssertFalse(driver.currentDialogueBoost)
    }

    func testDialogueBoostNoopsOnIncapableBackend() {
        let (detail, line, episode) = makeTestDetail()
        let backend = FakeVideoBackend(engine: .avplayer)
        let driver = VideoDriver()
        driver.makeBackend = { _ in backend }
        let resolver = FakeVideoResolver()
        resolver.urlsToReturn = [URL(string: "https://a.b/movie.mp4")!]
        driver.playURLResolver = resolver
        driver.openTimeoutInterval = 5
        driver.setDialogueBoost(true)
        XCTAssertTrue(driver.currentDialogueBoost)
        let started = expectation(description: "episode started")
        driver.onEpisodeStarted = { _ in started.fulfill() }
        driver.playEpisode(detail: detail, line: line, episode: episode)
        waitForExpectations(timeout: 2)
        // Remembered for a later capable backend; nothing crashed.
        XCTAssertTrue(driver.currentDialogueBoost)
    }

    func testMpvDialogueBoostFilterMatchesFlutter() {
        // Byte-for-byte against Flutter's kDialogueBoostCentreFilter
        // (mpv_backend.dart): centre fold + loudnorm. A typo in
        // this string would silently do nothing audible.
        XCTAssertEqual(
            MpvPlayerBackend.dialogueBoostFilter,
            "lavfi[pan=stereo|c0=1.0*c0+0.7*c2+0.3*c4|c1=1.0*c1+0.7*c2+0.3*c5,loudnorm=I=-16:TP=-1.5:LRA=11:linear=false]"
        )
    }
}

// MARK: - mixWithOthers survives a video / live open

final class MixWithOthersDriverTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        // Never trust the session state a previous test left.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
        suiteName = "com.haostudio.wiring-followup.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
        if let suiteName = suiteName {
            defaults.removePersistentDomain(forName: suiteName)
        }
        super.tearDown()
    }

    private func mixOptions() -> AVAudioSession.CategoryOptions {
        AVAudioSession.sharedInstance().categoryOptions
    }

    func testVodOpenKeepsMixWithOthers() {
        defaults.set(true, forKey: SettingsStore.mixWithOthersKey)
        let (detail, line, episode) = makeTestDetail()
        let backend = FakeVideoBackend(engine: .avplayer)
        let driver = VideoDriver()
        driver.defaults = defaults
        driver.makeBackend = { _ in backend }
        let resolver = FakeVideoResolver()
        resolver.urlsToReturn = [URL(string: "https://a.b/movie.mp4")!]
        driver.playURLResolver = resolver
        driver.openTimeoutInterval = 5
        let started = expectation(description: "episode started")
        driver.onEpisodeStarted = { _ in started.fulfill() }
        driver.playEpisode(detail: detail, line: line, episode: episode)
        waitForExpectations(timeout: 2)
        XCTAssertTrue(mixOptions().contains(.mixWithOthers))
    }

    func testVodOpenWithoutMixKeepsNoOptions() {
        defaults.set(false, forKey: SettingsStore.mixWithOthersKey)
        let (detail, line, episode) = makeTestDetail()
        let backend = FakeVideoBackend(engine: .avplayer)
        let driver = VideoDriver()
        driver.defaults = defaults
        driver.makeBackend = { _ in backend }
        let resolver = FakeVideoResolver()
        resolver.urlsToReturn = [URL(string: "https://a.b/movie.mp4")!]
        driver.playURLResolver = resolver
        driver.openTimeoutInterval = 5
        let started = expectation(description: "episode started")
        driver.onEpisodeStarted = { _ in started.fulfill() }
        driver.playEpisode(detail: detail, line: line, episode: episode)
        waitForExpectations(timeout: 2)
        XCTAssertFalse(mixOptions().contains(.mixWithOthers))
    }

    private func makeRoom() -> LiveRoom {
        LiveRoom(roomId: "123", platform: .huya, title: "测试直播间", streamer: "主播", onlineCount: 100, isLive: true)
    }

    private func makeResolution(urls: [URL]) -> LivePlayUrlResolution {
        let lines = urls.enumerated().map { index, url in
            LiveLine(name: "线路\(index + 1)", urls: [url.absoluteString])
        }
        return LivePlayUrlResolution(lines: lines, formats: [], qualities: [], quality: nil, refreshAt: nil, invalidAt: nil)
    }

    private func makeLiveDriver(mix: Bool) -> LiveDriver {
        defaults.set(mix, forKey: SettingsStore.mixWithOthersKey)
        let factory = FakeBackendFactory()
        let mpv = FakeVideoBackend(engine: .mpv)
        factory.fakes = [.mpv: [mpv]]
        let resolver = LiveDriverFakeResolver()
        resolver.resolutionsToReturn = [makeResolution(urls: [URL(string: "https://tx.flv.huya.com/room/1.flv")!])]
        let driver = LiveDriver()
        driver.defaults = defaults
        driver.makeBackend = { factory.makeBackend(engine: $0) }
        driver.openTimeoutInterval = 5
        driver.configure(room: makeRoom(), resolver: resolver)
        return driver
    }

    func testLiveOpenKeepsMixWithOthers() {
        let driver = makeLiveDriver(mix: true)
        let started = expectation(description: "room started")
        driver.onRoomStarted = { _ in started.fulfill() }
        driver.play(item: LiveDriver.playbackItem(room: makeRoom()))
        waitForExpectations(timeout: 2)
        XCTAssertTrue(mixOptions().contains(.mixWithOthers))
    }

    func testLiveOpenWithoutMixKeepsNoOptions() {
        let driver = makeLiveDriver(mix: false)
        let started = expectation(description: "room started")
        driver.onRoomStarted = { _ in started.fulfill() }
        driver.play(item: LiveDriver.playbackItem(room: makeRoom()))
        waitForExpectations(timeout: 2)
        XCTAssertFalse(mixOptions().contains(.mixWithOthers))
    }
}
