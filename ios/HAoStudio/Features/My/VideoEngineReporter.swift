// HAo Studio 2.0 — video engine reporter (S5, leg A).
//
// Remembers which engine actually played last, so Settings can
// show "上次使用：MPV" and diagnostics can say which engine a
// report came from. The value is the engine that really opened
// the stream — the drivers call `noteUsed` once, in
// `finishStartPlayback` (VideoDriver / LiveDriver), after the
// open verified playback. A failed open, a ladder attempt that
// did not win, and a preference change never write here: only a
// successful start does.
//
// Persistence: one UserDefaults string, key
// `hao_video_last_engine` (new key, no migration). Missing /
// unknown stored value = nil (no engine recorded yet).
//
// Deliberately NOT @MainActor: the drivers call `noteUsed` from
// plain (non-actor) driver code, and a @MainActor type there
// would force an isolation hop at every call site for a one-line
// record. Callers call from the main thread (both drivers record
// in `finishStartPlayback`, which runs via `ensureMain`); the
// @Published value is therefore only ever mutated on main.

import Foundation

final class VideoEngineReporter: ObservableObject {
    static let shared = VideoEngineReporter()

    static let lastEngineKey = "hao_video_last_engine"

    /// The engine of the last successful playback start, or nil
    /// when nothing has played yet (or the stored value is unknown).
    @Published private(set) var lastUsed: VideoEngine?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.lastUsed = VideoEngine(rawValue: defaults.string(forKey: Self.lastEngineKey) ?? "")
    }

    /// Record a successful playback start on `engine`. Writes
    /// through to UserDefaults immediately; setting the same engine
    /// twice is a no-op write of the same value.
    func noteUsed(_ engine: VideoEngine) {
        lastUsed = engine
        defaults.set(engine.rawValue, forKey: Self.lastEngineKey)
    }

    /// Forget the recorded engine (Settings reset path).
    func clear() {
        lastUsed = nil
        defaults.removeObject(forKey: Self.lastEngineKey)
    }
}
