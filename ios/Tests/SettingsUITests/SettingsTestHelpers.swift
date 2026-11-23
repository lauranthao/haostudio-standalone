// HAo Studio 2.0 — settings test helpers (S5, leg A).
//
// Shared fixtures for the SettingsTests target: a tiny generated
// image (no bundle assets, no network) and the isolated-defaults
// boilerplate. Fixture-only — no production code depends on this.

import Foundation
import UIKit
import XCTest

@testable import AppCore

/// A generated image, so tests never need a bundle asset.
enum SettingsTestImages {
    /// 10x10 solid red PNG data.
    static func pngData() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10))
        let image = renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }
        return image.pngData() ?? Data()
    }

    /// A 1024x768 solid blue image (for the avatar downsample test).
    static func largeImage() -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1024, height: 768))
        return renderer.image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1024, height: 768))
        }
    }
}

/// Isolated UserDefaults suite + temp dir, shared by the tests
/// that do not need a ThemeStore. Same pattern as
/// MigrationStoreTests: a UUID suite that is removed in tearDown.
final class SettingsTestIsolation {
    let suiteName: String
    let defaults: UserDefaults
    let docs: URL

    init() {
        suiteName = "com.haostudio.settings.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName) ?? .standard
        docs = FileManager.default.temporaryDirectory
            .appendingPathComponent("hao-settings-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: docs)
        defaults.removePersistentDomain(forName: suiteName)
    }
}
