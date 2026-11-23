// swift-tools-version:5.5
// HAo Studio 2.0 — migration tests (S1).
//
// Why a SwiftPM package instead of an Xcode unit-test target:
// adding a test target means a second PBXNativeTarget, a test host
// or @testable import of an app target that is not a framework, new
// build phases, scheme changes, and a preflight rewrite of the
// exactly-one-target check. The pbxproj already broke twice on
// smaller edits (builds 10 and 11), so the project file is not the
// place to experiment. This package compiles the same Storage
// sources the app target compiles (one source of truth, no copies)
// and runs with `swift test` from ios/, which Codemagic runs as a
// step before xcodebuild. No app code changes are needed to test.

import PackageDescription

let package = Package(
    name: "MigrationTests",
    targets: [
        .target(
            name: "MigrationCore",
            path: "HAoStudio/Storage",
            linkerSettings: [
                .linkedFramework("Security"),
            ]
        ),
        .testTarget(
            name: "MigrationCoreTests",
            dependencies: ["MigrationCore"],
            path: "Tests/MigrationCoreTests"
        ),
    ]
)
