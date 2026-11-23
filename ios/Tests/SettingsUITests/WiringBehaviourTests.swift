// HAo Studio 2.0 — wiring-leg-B behaviour tests (S7 wiring).
//
// Settings-store persistence for the four B-leg keys, the live
// audio-session effect of mixWithOthers, and the live network
// classifier. Runs in the HAoStudioTests app host (@testable
// import HAoStudio), same isolation pattern as SettingsStoreTests:
// a fresh UserDefaults suite (UUID) + a fresh temporary Documents
// directory per test; nothing touches the real defaults. The
// audio-session test restores the session to no-options in
// tearDown so mixWithOthers cannot leak into other tests.

import AVFoundation
import Foundation
import XCTest

@testable import HAoStudio

/// Minimal MusicPlayerEngine stub: never plays anything, only
/// satisfies the protocol so NativeMusicPlayer can be built with
/// isolated defaults.
private final class StubMusicEngine: MusicPlayerEngine {
    var isPlaying = false
    var rate: Float = 1
    var volume: Float = 1
    var currentTimeSeconds = 0.0
    var durationSeconds = 0.0
    var hasItem = false
    var equalizer: MusicEqualizer?
    var onEnded: (() -> Void)?
    var onFailed: (() -> Void)?
    var onTimeUpdate: ((Double, Double) -> Void)?

    func load(url: URL, headers: [String: String]?, identityKey: String, completion: @escaping (Bool) -> Void) {
        completion(false)
    }

    func play() {}
    func pause() {}

    func seek(to seconds: Double, completion: @escaping (Bool) -> Void) {
        completion(false)
    }

    func unload() {}
}

@MainActor
final class WiringBehaviourTests: XCTestCase {
    private var docs: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var themeStore: ThemeStore!
    private var settings: SettingsStore!

    override func setUp() {
        super.setUp()
        suiteName = "com.haostudio.wiring.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        docs = FileManager.default.temporaryDirectory
            .appendingPathComponent("hao-wiring-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        themeStore = ThemeStore(defaults: defaults)
        settings = SettingsStore(defaults: defaults, themeStore: themeStore, documentsURL: docs)
    }

    override func tearDown() {
        // Never leak mixWithOthers into the next test / the host.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
        if let docs = docs {
            try? FileManager.default.removeItem(at: docs)
        }
        if let suiteName = suiteName {
            defaults.removePersistentDomain(forName: suiteName)
        }
        super.tearDown()
    }

    // MARK: - Persistence (改设置 -> 存住 -> 重读还在)

    func testMixWithOthersPersistsAndReloads() {
        settings.mixWithOthers = true
        XCTAssertTrue(defaults.bool(forKey: SettingsStore.mixWithOthersKey))
        let reloaded = SettingsStore(defaults: defaults, themeStore: themeStore, documentsURL: docs)
        XCTAssertTrue(reloaded.mixWithOthers)
    }

    func testAutoResumePersistsAndReloads() {
        settings.autoResume = true
        XCTAssertTrue(defaults.bool(forKey: SettingsStore.autoResumeKey))
        let reloaded = SettingsStore(defaults: defaults, themeStore: themeStore, documentsURL: docs)
        XCTAssertTrue(reloaded.autoResume)
    }

    func testCellularDowngradePersistsAndReloads() {
        XCTAssertTrue(settings.cellularDowngrade)
        settings.cellularDowngrade = false
        XCTAssertFalse(defaults.bool(forKey: SettingsStore.cellularDowngradeKey))
        let reloaded = SettingsStore(defaults: defaults, themeStore: themeStore, documentsURL: docs)
        XCTAssertFalse(reloaded.cellularDowngrade)
    }

    func testLowMemoryModePersistsAndReloads() {
        settings.lowMemoryMode = "always"
        XCTAssertEqual(defaults.string(forKey: SettingsStore.lowMemoryModeKey), "always")
        let reloaded = SettingsStore(defaults: defaults, themeStore: themeStore, documentsURL: docs)
        XCTAssertEqual(reloaded.lowMemoryMode, "always")
    }

    // MARK: - mixWithOthers: the audio session really follows

    func testApplyMixWithOthersTogglesSessionOptions() {
        let player = NativeMusicPlayer(makeEngine: { StubMusicEngine() }, defaults: defaults)
        player.applyMixWithOthers(true)
        XCTAssertTrue(AVAudioSession.sharedInstance().categoryOptions.contains(.mixWithOthers))
        player.applyMixWithOthers(false)
        XCTAssertFalse(AVAudioSession.sharedInstance().categoryOptions.contains(.mixWithOthers))
    }

    func testPlayerInitAppliesStoredMixWithOthers() {
        defaults.set(true, forKey: SettingsStore.mixWithOthersKey)
        _ = NativeMusicPlayer(makeEngine: { StubMusicEngine() }, defaults: defaults)
        XCTAssertTrue(AVAudioSession.sharedInstance().categoryOptions.contains(.mixWithOthers))
    }

    // MARK: - Live network detection (test seam)

    func testDetectNetworkTypeClassifiesInterfaces() {
        XCTAssertEqual(LiveDriver.detectNetworkType(interfaceNames: ["en0"]), .wifi)
        XCTAssertEqual(LiveDriver.detectNetworkType(interfaceNames: ["pdp_ip0"]), .cellular)
        XCTAssertEqual(LiveDriver.detectNetworkType(interfaceNames: ["rmnet_data0", "en0"]), .cellular)
        XCTAssertEqual(LiveDriver.detectNetworkType(interfaceNames: ["utun0"]), .unknown)
        XCTAssertEqual(LiveDriver.detectNetworkType(interfaceNames: []), .unknown)
    }
}
