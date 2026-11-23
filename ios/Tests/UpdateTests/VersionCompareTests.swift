// HAo Studio 2.0 — semver comparison tests (S6, C leg).
//
// Ports the expectations of the Flutter compareSemver contract in
// lib/app/consts.dart: numeric parts, never lexicographic.

import Foundation
import XCTest

@testable import AppCore

final class VersionCompareTests: XCTestCase {
    func testNumericParts() {
        XCTAssertGreaterThan(VersionCompare.compare("1.0.10", "1.0.9"), 0)
        XCTAssertLessThan(VersionCompare.compare("1.0.9", "1.0.10"), 0)
        XCTAssertGreaterThan(VersionCompare.compare("1.1.7", "1.1.6"), 0)
    }

    func testMissingPartsCountAsZero() {
        XCTAssertEqual(VersionCompare.compare("1.1", "1.1.0"), 0)
        XCTAssertEqual(VersionCompare.compare("1.1.0", "1.1"), 0)
        XCTAssertGreaterThan(VersionCompare.compare("1.1.1", "1.1"), 0)
    }

    func testLeadingZeroPartsEqual() {
        XCTAssertEqual(VersionCompare.compare("1.1.05", "1.1.5"), 0)
        XCTAssertEqual(VersionCompare.compare("1.1.5", "1.1.05"), 0)
    }

    func testMajorVersionJump() {
        XCTAssertGreaterThan(VersionCompare.compare("2.0.0", "1.1.6"), 0)
        XCTAssertLessThan(VersionCompare.compare("1.1.6", "2.0.0"), 0)
    }

    func testEqualVersions() {
        XCTAssertEqual(VersionCompare.compare("1.1.6", "1.1.6"), 0)
        XCTAssertEqual(VersionCompare.compare("2.0.0", "2.0.0"), 0)
    }

    func testIsNewerVersion() {
        XCTAssertTrue(VersionCompare.isNewerVersion("2.0.0", than: "1.1.6"))
        XCTAssertTrue(VersionCompare.isNewerVersion("1.0.10", than: "1.0.9"))
        XCTAssertFalse(VersionCompare.isNewerVersion("1.1.6", than: "1.1.6"))
        XCTAssertFalse(VersionCompare.isNewerVersion("1.1.5", than: "1.1.6"))
    }

    func testWhitespaceIsTrimmed() {
        XCTAssertEqual(VersionCompare.compare(" 1.1.6 ", "1.1.6"), 0)
    }
}
