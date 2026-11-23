// HAo Studio 2.0 — keychain tests (S1).
//
// The Emby API key must live in the Keychain and nowhere else: the
// migration writes the config file with the key removed and the key
// itself here. These tests prove the round-trip and the split. When
// the runner has no usable keychain (locked, headless, no login
// keychain), the tests skip instead of failing: keychain access is
// an OS property of the runner, not of this code.

import Foundation
import XCTest

@testable import MigrationCore

final class KeychainStoreTests: XCTestCase {
    private var docs: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "com.haostudio.keychain.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        docs = FileManager.default.temporaryDirectory
            .appendingPathComponent("hao-keychain-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        _ = KeychainStore.deleteEmbyApiKey()
    }

    override func tearDown() {
        _ = KeychainStore.deleteEmbyApiKey()
        if let docs = docs {
            try? FileManager.default.removeItem(at: docs)
        }
        if let suiteName = suiteName {
            defaults.removePersistentDomain(forName: suiteName)
        }
        super.tearDown()
    }

    /// True when this runner lets the test write to the Keychain.
    /// Called once per test that needs the Keychain; skips the test
    /// when the OS refuses, so a headless runner cannot fail it.
    private func requireKeychain() throws {
        let probeAccount = "hao-keychain-probe"
        _ = KeychainStore.delete(account: probeAccount)
        guard KeychainStore.save("__probe__", account: probeAccount) else {
            throw XCTSkip("keychain write unavailable on this runner")
        }
        _ = KeychainStore.delete(account: probeAccount)
    }

    func testRoundTrip() throws {
        try requireKeychain()
        XCTAssertNil(KeychainStore.loadEmbyApiKey())
        XCTAssertTrue(KeychainStore.saveEmbyApiKey("token-abc"))
        XCTAssertEqual(KeychainStore.loadEmbyApiKey(), "token-abc")
        XCTAssertTrue(KeychainStore.saveEmbyApiKey("token-def"))
        XCTAssertEqual(KeychainStore.loadEmbyApiKey(), "token-def")
        XCTAssertTrue(KeychainStore.deleteEmbyApiKey())
        XCTAssertNil(KeychainStore.loadEmbyApiKey())
        XCTAssertTrue(KeychainStore.deleteEmbyApiKey())
    }

    func testEmbyTokenSplitAcrossFileAndKeychain() throws {
        try requireKeychain()
        let config: [String: Any] = [
            "baseUrl": "http://192.168.1.10:8096",
            "apiKey": "test-api-key-123",
            "userId": "u1",
            "enabled": true,
            "movieLibraryId": "m1",
            "tvLibraryId": "t1",
        ]
        let report = MigrationStore.importData(
            ["hao_emby_config": config],
            documentsURL: docs, defaults: defaults, markDone: false
        )
        XCTAssertEqual(report.outcome, .migrated)

        let fileURL = docs.appendingPathComponent("hao_emby_config.json")
        let raw = try Data(contentsOf: fileURL)
        let stored = try JSONSerialization.jsonObject(with: raw, options: []) as? [String: Any]
        XCTAssertNotNil(stored)
        XCTAssertNil(stored?["apiKey"])
        XCTAssertEqual(stored?["baseUrl"] as? String, "http://192.168.1.10:8096")
        XCTAssertEqual(stored?["userId"] as? String, "u1")
        XCTAssertEqual(KeychainStore.loadEmbyApiKey(), "test-api-key-123")

        // The token never appears in the file, even as a substring.
        XCTAssertFalse(String(data: raw, encoding: .utf8)?.contains("test-api-key-123") ?? true)
    }
}
