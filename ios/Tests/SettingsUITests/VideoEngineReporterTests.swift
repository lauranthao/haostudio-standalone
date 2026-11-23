// HAo Studio 2.0 — video engine reporter tests (S5, leg A).
//
// iOS-only (see SettingsStoreTests.swift header): unwired in
// `ios/Package.swift`, runs under the S7 Xcode test target.
// Isolation: a fresh UserDefaults suite per test, removed in
// tearDown; the shared singleton is never touched (a fresh
// reporter instance is built with the suite instead).

import Foundation
import XCTest

@testable import AppCore

@MainActor
final class VideoEngineReporterTests: XCTestCase {
    private var isolation: SettingsTestIsolation!

    override func setUp() {
        super.setUp()
        isolation = SettingsTestIsolation()
    }

    override func tearDown() {
        isolation.cleanUp()
        super.tearDown()
    }

    func testStartsEmptyWhenNothingRecorded() {
        let reporter = VideoEngineReporter(defaults: isolation.defaults)
        XCTAssertNil(reporter.lastUsed)
    }

    func testNoteUsedPersistsRawValue() {
        let reporter = VideoEngineReporter(defaults: isolation.defaults)
        reporter.noteUsed(.avplayer)
        XCTAssertEqual(reporter.lastUsed, .avplayer)
        // AVPlayer's stored raw value is "exo" (Pure Live key space).
        XCTAssertEqual(isolation.defaults.string(forKey: "hao_video_last_engine"), "exo")
        let reloaded = VideoEngineReporter(defaults: isolation.defaults)
        XCTAssertEqual(reloaded.lastUsed, .avplayer)
    }

    func testNoteUsedOverwritesPreviousEngine() {
        let reporter = VideoEngineReporter(defaults: isolation.defaults)
        reporter.noteUsed(.mpv)
        reporter.noteUsed(.ijk)
        XCTAssertEqual(reporter.lastUsed, .ijk)
        XCTAssertEqual(isolation.defaults.string(forKey: "hao_video_last_engine"), "ijk")
    }

    func testUnknownStoredValueReadsAsNil() {
        isolation.defaults.set("bogus", forKey: "hao_video_last_engine")
        let reporter = VideoEngineReporter(defaults: isolation.defaults)
        XCTAssertNil(reporter.lastUsed)
    }

    func testClearForgetsEngine() {
        let reporter = VideoEngineReporter(defaults: isolation.defaults)
        reporter.noteUsed(.mpv)
        reporter.clear()
        XCTAssertNil(reporter.lastUsed)
        XCTAssertNil(isolation.defaults.object(forKey: "hao_video_last_engine"))
    }
}
