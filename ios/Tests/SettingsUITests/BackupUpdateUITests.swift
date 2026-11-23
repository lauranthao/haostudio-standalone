// HAo Studio 2.0 — backup + update UI tests (S6-B leg).
//
// UNWIRED (same as the other files in this directory): there is
// no Xcode test target yet — these run from the S7 Xcode target,
// not from `swift test`. The assertions below only touch AppCore
// pure logic (UpdatePromptContent), so the only wiring change at
// S7 is the import line, same as MyEntriesTests.
// What these tests CANNOT cover (verify by hand at merge): the
// sheet actually appears on check, the fileImporter opens the
// .zip picker, ShareLink shares the exported file, the alert
// shows after import. See the S6-B leg report.

import XCTest

@testable import AppCore

final class BackupUpdateUITests: XCTestCase {
    private func makeResult(
        minOs: String? = "17.0",
        downloadURL: URL? = URL(string: "https://example.com/app.ipa"),
        notes: String? = "新功能。",
        requiresNewerOS: Bool = false
    ) -> UpdateCheckResult {
        UpdateCheckResult(
            latestVersion: "1.1.7", latestBuild: 12, minOs: minOs,
            downloadURL: downloadURL, releaseNotes: notes,
            requiresNewerOS: requiresNewerOS, isSkipped: false,
            failureMessage: nil)
    }

    /// A blocked build must never offer an update button — the
    /// sheet's only actions are skip / later.
    func testBlockedBuildOffersNoUpdateAction() {
        let content = UpdateCheckLogic.promptContent(result: makeResult(minOs: "18.0", requiresNewerOS: true), deviceVersion: (major: 17, minor: 0, patch: 0))
        XCTAssertFalse(content.showUpdateButton)
        XCTAssertNotNil(content.blockedMessage)
    }

    /// An installable build with a download URL offers update.
    func testInstallableBuildOffersUpdateAction() {
        let content = UpdateCheckLogic.promptContent(result: makeResult(), deviceVersion: (major: 17, minor: 0, patch: 0))
        XCTAssertTrue(content.showUpdateButton)
        XCTAssertNil(content.blockedMessage)
    }

    /// An installable build WITHOUT a download URL must not offer
    /// an update button that leads nowhere.
    func testInstallableBuildWithoutURLOffersNoUpdateAction() {
        let content = UpdateCheckLogic.promptContent(result: makeResult(downloadURL: nil), deviceVersion: (major: 17, minor: 0, patch: 0))
        XCTAssertTrue(content.canInstall)
        XCTAssertFalse(content.showUpdateButton)
    }

    /// The sheet always shows notes — manifest notes, or the
    /// fallback line when the manifest has none.
    func testSheetAlwaysShowsNotes() {
        let withNotes = UpdateCheckLogic.promptContent(result: makeResult(notes: "新功能。"), deviceVersion: (major: 17, minor: 0, patch: 0))
        XCTAssertEqual(withNotes.releaseNotes, "新功能。")
        let withoutNotes = UpdateCheckLogic.promptContent(result: makeResult(notes: nil), deviceVersion: (major: 17, minor: 0, patch: 0))
        XCTAssertEqual(withoutNotes.releaseNotes, "本次更新没有附带更新说明。")
    }
}
