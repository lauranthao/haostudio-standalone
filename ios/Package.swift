// swift-tools-version:5.5
// HAo Studio 2.0 — SwiftPM test package (S1 migration + S2 music).
//
// Why a SwiftPM package instead of an Xcode unit-test target:
// adding a test target means a second PBXNativeTarget, a test host
// or @testable import of an app target that is not a framework, new
// build phases, scheme changes, and a preflight rewrite of the
// exactly-one-target check. The pbxproj already broke twice on
// smaller edits (builds 10 and 11), so the project file is not the
// place to experiment. This package compiles the same sources the
// app target compiles (one source of truth, no copies) and runs
// with `swift test` from ios/, which Codemagic runs as a step
// before xcodebuild. No app code changes are needed to test.
//
// One target, not two: S1 had a MigrationCore target (whole
// Storage dir) and S2 added a MusicLX target that also listed
// Storage/LocalStore.swift + Storage/KeychainStore.swift. SwiftPM
// forbids one file in two targets, so build #18 failed with
// "target 'MusicLX' has overlapping sources" on exactly those two
// files. The merge keeps every file in exactly one target —
// AppCore — and both test suites import it. (A later slice that
// needs testable sources must add them to AppCore or to a new
// target that claims no file AppCore already has.)
//
// S2: the LX engine / resolvers / music API (module AppCore) are
// macOS-safe (Foundation + JavaScriptCore + CryptoKit + Security
// only), so their tests run here. The player (MusicCore) and the
// feature UI (MusicFeatures) import iOS-only frameworks
// (MediaPlayer, AVRoutePickerView) and cannot run under
// `swift test`; their tests run via `xcodebuild test` on an iOS
// Simulator destination once an Xcode test target exists — there
// is deliberately none yet (see the note above about the pbxproj).

import PackageDescription

let package = Package(
    name: "HAoStudioTests",
    // AppCore covers the whole HAoStudio dir, which holds
    // Base.lproj; SwiftPM requires a default localization once a
    // target has localized resources (build #17 failed without it).
    defaultLocalization: "en",
    targets: [
        .target(
            name: "AppCore",
            path: "HAoStudio",
            sources: [
                "Services/LXEngine",
                "Services/MusicResolvers",
                "Services/MusicAPI",
                "Playback/PlaybackCoordinator.swift",
                "Storage",
            ],
            // The 13 LX scripts live under Services/LXEngine, which is
            // a sources dir, so SwiftPM treats the .js files as
            // unexpected compiler inputs unless they are declared
            // resources (build #19 failed on exactly those 13 files).
            resources: [
                .process("Services/LXEngine/Scripts"),
            ],
            linkerSettings: [
                .linkedFramework("Security"),
            ]
        ),
        .testTarget(
            name: "MigrationCoreTests",
            dependencies: ["AppCore"],
            path: "Tests/MigrationCoreTests"
        ),
        .testTarget(
            name: "MusicLXTests",
            dependencies: ["AppCore"],
            path: "Tests/MusicLXTests"
        ),
    ]
)
