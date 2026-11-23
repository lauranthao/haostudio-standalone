// HAo Studio 2.0 — app entry point (SwiftUI lifecycle).
//
// There is deliberately NO UIKit app-delegate / scene-delegate shell:
// the 2.0 app is SwiftUI from the first frame. The old Info.plist
// scene-manifest entry (which pointed at the deleted scene delegate)
// is removed for the same reason — a SwiftUI @main app must not
// declare a scene delegate class that does not exist.

import SwiftUI

@main
struct HAoStudioApp: App {
    @StateObject private var themeStore: ThemeStore
    @StateObject private var coordinator: PlaybackCoordinator
    /// S2-C: one shared music player view model for the whole app
    /// (home, mini player, full player all observe the same queue
    /// and playback state). Created here, next to the coordinator
    /// it observes — never one instance per page.
    @StateObject private var musicPlayer: MusicPlayerViewModel
    /// S3-C: one shared video player view model for the whole app
    /// (detail page, fullscreen player, mini-player re-entry all
    /// observe the same episode/line state). Created here, next to
    /// the coordinator it observes — never one instance per page.
    @StateObject private var videoPlayer: VideoPlayerViewModel
    /// S4-C: one shared live player view model for the whole app
    /// (room page, portrait + landscape, all observe the same
    /// room/quality/line/danmaku state). Created here, next to
    /// the coordinator it observes — never one instance per page.
    /// A leg owns the type (Playback/LivePlayerViewModel.swift);
    /// its init takes the live driver, mirroring the VOD view
    /// model shape.
    @StateObject private var livePlayer: LivePlayerViewModel

    init() {
        // S1: the snapshot migration runs before anything reads
        // settings, so the first frame already uses the migrated
        // theme and preferences. It is synchronous, idempotent, and
        // skips quietly when there is no snapshot to migrate from.
        _ = MigrationStore.runIfNeeded()
        _themeStore = StateObject(wrappedValue: ThemeStore())
        let coordinator = PlaybackCoordinator()
        // S2: wire the music engine behind the coordinator. The LX
        // resolver answers resolveFirstPlayable; the player is the
        // driver. Without these two lines requestPlay is a no-op.
        coordinator.resolver = LXSourceResolver()
        coordinator.musicDriver = NativeMusicPlayer.shared
        // S3-C: wire the VOD engine behind the coordinator. The
        // driver (A leg) owns engines + episode/line state; URL
        // resolution is the B-leg CmsClient, which answers the
        // seam VideoPlayURLResolver contract. The coordinator
        // wires onEpisodeStarted / onEpisodeFailed itself in the
        // vodDriver didSet — nothing else to do here.
        let vodDriver = VideoDriver()
        vodDriver.playURLResolver = CmsClient.shared
        coordinator.vodDriver = vodDriver
        // S4-C: wire the live engine behind the coordinator. The
        // driver (A leg, Playback/LiveDriver.swift) owns engines +
        // room/quality/line state; room resolution is the B-leg
        // LiveSiteResolver, which answers the seam contract. The
        // coordinator wires onRoomStarted / onRoomFailed itself in
        // the liveDriver didSet — nothing else to do here.
        let liveDriver = LiveDriver()
        coordinator.liveDriver = liveDriver
        _coordinator = StateObject(wrappedValue: coordinator)
        _musicPlayer = StateObject(wrappedValue: MusicPlayerViewModel(coordinator: coordinator))
        _videoPlayer = StateObject(wrappedValue: VideoPlayerViewModel(coordinator: coordinator))
        _livePlayer = StateObject(wrappedValue: LivePlayerViewModel(driver: liveDriver))
    }

    /// The splash covers the first frame; it fades out at 1.5s
    /// (animation #4) once the app reports ready. Foundation: ready
    /// immediately — no async startup work yet. Later slices flip
    /// `splashReady` only after their startup work finishes, which is
    /// when the splash's spinner + subtitle path is used.
    @State private var splashReady = true
    @State private var showingSplash = true

    var body: some Scene {
        WindowGroup {
            ZStack {
                MainTabView()
                    .preferredColorScheme(themeStore.appearance.preferredColorScheme)
                if showingSplash {
                    SplashView(isReady: $splashReady) {
                        showingSplash = false
                    }
                }
            }
            .environmentObject(themeStore)
            .environmentObject(coordinator)
            .environmentObject(musicPlayer)
            .environmentObject(videoPlayer)
            .environmentObject(livePlayer)
        }
    }
}
