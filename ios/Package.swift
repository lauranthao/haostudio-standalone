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
//
// S3: the video services (CMS / Douban / Emby / danmaku) and the
// shared download engine are Foundation-only too, so they join
// AppCore as whole directories. VideoLibraryStore.swift joins as
// a single file (its home is Features/Video, outside the service
// dirs) so its tests compile; no other Features file is claimed.
// VideoPlayerTests (A leg, iOS-only driver tests) stays unwired
// until S7 — it is not a SwiftPM target.

import PackageDescription

let package = Package(
    name: "HAoStudioTests",
    // AppCore covers the whole HAoStudio dir, which holds
    // Base.lproj; SwiftPM requires a default localization once a
    // target has localized resources (build #17 failed without it).
    defaultLocalization: "en",
    // No platforms means SwiftPM targets the oldest macOS, where
    // Combine (@Published / ObservableObject) and CryptoKit's
    // Insecure hash are unavailable (build #22 failed on exactly
    // those). The tests only run on modern CI Macs; 10.15 covers
    // everything AppCore uses.
    platforms: [.macOS(.v10_15)],
    targets: [
        .target(
            name: "AppCore",
            path: "HAoStudio",
            // The 13 LX scripts live under Services/LXEngine, which is
            // a sources dir, so SwiftPM tries to build rules for the
            // .js files: "unexpected input file" without a resource
            // declaration (build #19), "duplicate rule" with one
            // (build #20 — the auto-discovered rule plus the declared
            // one). Excluding the dir removes them from the build
            // graph entirely; the tests locate the scripts on disk
            // via #file, which the checkout still has.
            // NOTE: exclude must come BEFORE sources in this
            // initializer (build #21 failed on the order).
            exclude: [
                "Services/LXEngine/Scripts",
            ],
            sources: [
                "Services/LXEngine",
                "Services/MusicResolvers",
                "Services/MusicAPI",
                "Services/Video",
                "Services/DownloadEngine",
                "Playback/PlaybackCoordinator.swift",
                "Features/Video/VideoLibraryStore.swift",
                "Storage",
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
        // S3: video services (CMS / Douban / Emby / danmaku) and the
        // shared download engine — tested against AppCore, which
        // owns their sources (see the note above: one file, one
        // target).
        .testTarget(
            name: "VideoServicesTests",
            dependencies: ["AppCore"],
            path: "Tests/VideoServicesTests"
        ),
        // S3: video feature stores (resume key, library store,
        // music platform badge) — same AppCore dependency.
        .testTarget(
            name: "VideoFeaturesTests",
            dependencies: ["AppCore"],
            path: "Tests/VideoFeaturesTests"
        ),
    ]
)
