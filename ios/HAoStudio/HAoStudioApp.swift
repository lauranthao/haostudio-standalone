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
    @StateObject private var themeStore = ThemeStore()
    @StateObject private var coordinator = PlaybackCoordinator()

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
        }
    }
}
