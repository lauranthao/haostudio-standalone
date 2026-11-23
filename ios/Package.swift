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
// S2: the LX engine / resolvers / music API (module MusicLX) are
// macOS-safe (Foundation + JavaScriptCore + CryptoKit + Security
// only), so their tests run here. The player (MusicCore) and the
// feature UI (MusicFeatures) import iOS-only frameworks
// (MediaPlayer, AVRoutePickerView) and cannot run under
// `swift test`; their tests run via `xcodebuild test` on an iOS
// Simulator destination once an Xcode test target exists — there
// is deliberately none yet (see the note above about the pbxproj).
//
// MusicLX sources: the three Services dirs plus the three files
// they depend on outside Services — PlaybackCoordinator.swift
// (PlaybackItem, AudioQuality, SourceResolver, the driver contract)
// and Storage/LocalStore.swift + Storage/KeychainStore.swift
// (documents dir + Keychain user keys). The driver contract lives
// in PlaybackCoordinator.swift (not the player file) exactly so
// this target does not pull in the iOS-only player.

import PackageDescription

let package = Package(
    name: "HAoStudioTests",
    // Build #17 fix: the MusicLX target's path is the whole HAoStudio
    // directory, which contains Base.lproj; SwiftPM requires the
    // manifest to declare a default localization once it sees
    // localized resources. "en" is the conventional value for
    // Base.lproj. (S1's MigrationCore target only covers Storage/,
    // which has no .lproj, so build #16 passed without it.)
    defaultLocalization: "en",
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
        .target(
            name: "MusicLX",
            path: "HAoStudio",
            sources: [
                "Services/LXEngine",
                "Services/MusicResolvers",
                "Services/MusicAPI",
                "Services/Video",
                "Services/DownloadEngine",
                "Playback/PlaybackCoordinator.swift",
                "Storage/LocalStore.swift",
                "Storage/KeychainStore.swift",
            ],
            linkerSettings: [
                .linkedFramework("Security"),
            ]
        ),
        .testTarget(
            name: "MusicLXTests",
            dependencies: ["MusicLX"],
            path: "Tests/MusicLXTests"
        ),
        // S3: video services (CMS / Douban / Emby / danmaku) and the
        // shared download engine live in MusicLX too — SwiftPM
        // forbids one source file in two targets (build #18: the
        // MusicLX/MigrationCore Storage overlap), so no separate
        // VideoServices target is created here. At leg merge the
        // coordinator moves these two dirs onto AppCore (the merged
        // MusicLX + MigrationCore target from the music branch,
        // 09b05e4) and re-points this test target at AppCore.
        .testTarget(
            name: "VideoServicesTests",
            dependencies: ["MusicLX"],
            path: "Tests/VideoServicesTests"
        ),
    ]
)
