// HAo Studio 2.0 — wiring-leg-B pure-logic tests (S7 wiring).
//
// Covers the three pure decisions this leg adds to SettingsLogic:
// LowMemoryModeEffect, LiveCellularDowngrade (Flutter
// lib/domains/live/live_network_quality.dart, rules copied
// verbatim) and AutoResumeDecision. No network, no real data, no
// audio session. AppCore only, like SettingsGroupsLogicTests.

import Foundation
import XCTest

@testable import AppCore

final class WiringLogicTests: XCTestCase {
    // MARK: - Low-memory mode effect

    func testLowMemoryAutoFollowsCoreCount() {
        XCTAssertTrue(LowMemoryModeEffect.isEffective(mode: "auto", cpuCores: 4))
        XCTAssertTrue(LowMemoryModeEffect.isEffective(mode: "auto", cpuCores: 2))
        XCTAssertFalse(LowMemoryModeEffect.isEffective(mode: "auto", cpuCores: 6))
        XCTAssertFalse(LowMemoryModeEffect.isEffective(mode: "auto", cpuCores: 8))
    }

    func testLowMemoryAlwaysAndNeverOverrideCores() {
        XCTAssertTrue(LowMemoryModeEffect.isEffective(mode: "always", cpuCores: 8))
        XCTAssertFalse(LowMemoryModeEffect.isEffective(mode: "never", cpuCores: 2))
    }

    func testLowMemoryUnknownValueReadsAsAuto() {
        XCTAssertTrue(LowMemoryModeEffect.isEffective(mode: "on", cpuCores: 4))
        XCTAssertFalse(LowMemoryModeEffect.isEffective(mode: "on", cpuCores: 6))
        XCTAssertTrue(LowMemoryModeEffect.isEffective(mode: nil, cpuCores: 4))
        XCTAssertFalse(LowMemoryModeEffect.isEffective(mode: nil, cpuCores: 6))
        XCTAssertEqual(LowMemoryModeEffect.normalizedMode("bogus"), "auto")
        XCTAssertEqual(LowMemoryModeEffect.normalizedMode("always"), "always")
    }

    // MARK: - Network classification

    func testClassifyInterfaceName() {
        XCTAssertEqual(LiveCellularDowngrade.classifyInterfaceName("en0"), .wifi)
        XCTAssertEqual(LiveCellularDowngrade.classifyInterfaceName("EN0"), .wifi)
        XCTAssertEqual(LiveCellularDowngrade.classifyInterfaceName("wlan0"), .wifi)
        XCTAssertEqual(LiveCellularDowngrade.classifyInterfaceName("pdp_ip0"), .cellular)
        XCTAssertEqual(LiveCellularDowngrade.classifyInterfaceName("rmnet_data0"), .cellular)
        XCTAssertNil(LiveCellularDowngrade.classifyInterfaceName("utun0"))
        XCTAssertNil(LiveCellularDowngrade.classifyInterfaceName(""))
    }

    func testClassifyInterfacesCellularWins() {
        XCTAssertEqual(
            LiveCellularDowngrade.classifyInterfaces(["en0", "pdp_ip0"]), .cellular)
        XCTAssertEqual(
            LiveCellularDowngrade.classifyInterfaces(["en0", "lo0"]), .wifi)
        XCTAssertEqual(
            LiveCellularDowngrade.classifyInterfaces(["utun0", "lo0"]), .unknown)
        XCTAssertEqual(LiveCellularDowngrade.classifyInterfaces([]), .unknown)
    }

    func testCellularDowngradeDefaultsOn() {
        XCTAssertTrue(LiveCellularDowngrade.enabled(stored: nil))
        XCTAssertTrue(LiveCellularDowngrade.enabled(stored: true))
        XCTAssertFalse(LiveCellularDowngrade.enabled(stored: false))
    }

    // MARK: - Entry quality index

    func testEntryQualityKeepsPreferredOnWifi() {
        let names = ["原画", "蓝光", "超清", "高清", "流畅"]
        XCTAssertEqual(
            LiveCellularDowngrade.entryQualityIndex(
                qualityNames: names, preferredIndex: 0, network: .wifi), 0)
        XCTAssertEqual(
            LiveCellularDowngrade.entryQualityIndex(
                qualityNames: names, preferredIndex: 0, network: .unknown), 0)
    }

    func testEntryQualityCapsAtCeilingOnCellular() {
        let names = ["原画", "蓝光", "超清", "高清", "流畅"]
        XCTAssertEqual(
            LiveCellularDowngrade.entryQualityIndex(
                qualityNames: names, preferredIndex: 0, network: .cellular), 2)
    }

    func testEntryQualityFallsBackWithoutCeilingLabels() {
        // No 超清/高清/流畅 anywhere: 5 tiers -> middle tier,
        // 2 tiers -> lowest.
        let five = ["4K", "2K", "1080p", "720p", "480p"]
        XCTAssertEqual(
            LiveCellularDowngrade.entryQualityIndex(
                qualityNames: five, preferredIndex: 0, network: .cellular), 2)
        let two = ["1080p", "480p"]
        XCTAssertEqual(
            LiveCellularDowngrade.entryQualityIndex(
                qualityNames: two, preferredIndex: 0, network: .cellular), 1)
        XCTAssertEqual(
            LiveCellularDowngrade.entryQualityIndex(
                qualityNames: [], preferredIndex: 0, network: .cellular), 0)
    }

    func testEntryQualityClampsPreferredIndex() {
        let names = ["原画", "超清", "流畅"]
        XCTAssertEqual(
            LiveCellularDowngrade.entryQualityIndex(
                qualityNames: names, preferredIndex: 99, network: .wifi), 2)
        XCTAssertEqual(
            LiveCellularDowngrade.entryQualityIndex(
                qualityNames: names, preferredIndex: -1, network: .wifi), 0)
    }

    // MARK: - Mid-room downgrade target

    func testDowngradeTargetCapsButNeverSwitchesUp() {
        let names = ["原画", "蓝光", "超清", "高清", "流畅"]
        // Playing 原画 (0) on cellular, switch on -> 超清 (2).
        XCTAssertEqual(
            LiveCellularDowngrade.cellularDowngradeTargetIndex(
                qualityNames: names, currentIndex: 0, preferredIndex: 0,
                network: .cellular, enabled: true), 2)
        // Already at 高清 (3), below the ceiling -> stays put.
        XCTAssertNil(
            LiveCellularDowngrade.cellularDowngradeTargetIndex(
                qualityNames: names, currentIndex: 3, preferredIndex: 0,
                network: .cellular, enabled: true))
    }

    func testDowngradeTargetOffRestoresPreferred() {
        let names = ["原画", "蓝光", "超清", "高清", "流畅"]
        XCTAssertEqual(
            LiveCellularDowngrade.cellularDowngradeTargetIndex(
                qualityNames: names, currentIndex: 2, preferredIndex: 0,
                network: .cellular, enabled: false), 0)
        // Already at the preferred quality -> no-op.
        XCTAssertNil(
            LiveCellularDowngrade.cellularDowngradeTargetIndex(
                qualityNames: names, currentIndex: 0, preferredIndex: 0,
                network: .cellular, enabled: false))
    }

    func testDowngradeTargetNeverAppliesOffCellular() {
        let names = ["原画", "蓝光", "超清", "高清", "流畅"]
        XCTAssertNil(
            LiveCellularDowngrade.cellularDowngradeTargetIndex(
                qualityNames: names, currentIndex: 0, preferredIndex: 0,
                network: .wifi, enabled: true))
        XCTAssertNil(
            LiveCellularDowngrade.cellularDowngradeTargetIndex(
                qualityNames: names, currentIndex: 0, preferredIndex: 0,
                network: .unknown, enabled: true))
        XCTAssertNil(
            LiveCellularDowngrade.cellularDowngradeTargetIndex(
                qualityNames: [], currentIndex: 0, preferredIndex: 0,
                network: .cellular, enabled: true))
    }

    // MARK: - Auto-resume decision

    func testAutoResumeNeedsSwitchAndQueue() {
        XCTAssertNil(
            AutoResumeDecision.resumeIndex(
                autoResumeEnabled: false, queueCount: 3, currentIndex: 1))
        XCTAssertNil(
            AutoResumeDecision.resumeIndex(
                autoResumeEnabled: true, queueCount: 0, currentIndex: 0))
        XCTAssertEqual(
            AutoResumeDecision.resumeIndex(
                autoResumeEnabled: true, queueCount: 3, currentIndex: 1), 1)
    }

    func testAutoResumeClampsIndex() {
        XCTAssertEqual(
            AutoResumeDecision.resumeIndex(
                autoResumeEnabled: true, queueCount: 3, currentIndex: 99), 2)
        XCTAssertEqual(
            AutoResumeDecision.resumeIndex(
                autoResumeEnabled: true, queueCount: 3, currentIndex: -1), 0)
    }
}
