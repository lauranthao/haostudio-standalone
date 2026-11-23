// HAo Studio 2.0 — semver comparison (S6).
//
// Swift port of the Flutter `compareSemver` / `isNewerVersion` in
// lib/app/consts.dart (main, 1.1.6+31). Numeric, part by part:
// "1.0.10" beats "1.0.9", "1.1.05" equals "1.1.5", missing parts
// count as 0. A part that is not numeric on either side falls back
// to plain string comparison for that part, exactly like Flutter.
// Prerelease tags therefore compare lexicographically ("2.0.0-dev.1"
// sorts after "2.0.0"); no manifest the app ships carries a dev tag,
// so this keeps the behaviour the Flutter check already verified.

import Foundation

enum VersionCompare {
    /// Returns a negative number when a is older than b, 0 when they
    /// are equal, and a positive number when a is newer than b.
    static func compare(_ a: String, _ b: String) -> Int {
        let aParts = a.trimmingCharacters(in: .whitespaces).components(separatedBy: ".")
        let bParts = b.trimmingCharacters(in: .whitespaces).components(separatedBy: ".")
        let count = max(aParts.count, bParts.count)
        for index in 0..<count {
            let aPart = index < aParts.count ? aParts[index] : "0"
            let bPart = index < bParts.count ? bParts[index] : "0"
            if let aNumber = Int(aPart), let bNumber = Int(bPart) {
                if aNumber != bNumber {
                    return aNumber < bNumber ? -1 : 1
                }
            } else if aPart != bPart {
                return aPart < bPart ? -1 : 1
            }
        }
        return 0
    }

    /// True when candidate is a newer version than current.
    static func isNewerVersion(_ candidate: String, than current: String) -> Bool {
        compare(candidate, current) > 0
    }
}
