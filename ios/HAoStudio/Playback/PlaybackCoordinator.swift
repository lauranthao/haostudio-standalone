// HAo Studio 2.0 — playback coordinator SHELL (foundation slice).
//
// This file is an interface + rules only. There is NO engine, NO parsing
// and NO network here; the player slice wires the engines behind it.
// Nothing in the foundation UI calls `requestPlay`, so `currentItem`
// stays nil and the mini player stays hidden until the player slice
// lands — the shell must never pretend something is playing.
//
// Iron laws encoded here (chen 2026-11-16/17 — the coordinator exists
// so these rules have exactly one enforcement point, not one copy per
// player):
//
// 1. ONE SOUND AT A TIME. Starting any kind of playback stops whatever
//    is currently playing first (music / VOD / live never overlap).
// 2. MUSIC USES AVPLAYER ONLY. Music never follows the video/live
//    kernel selector (MPV / IJK / AVPlayer) — that selector is video
//    and live only. Lyrics go BEHIND the cover (tap cover -> lyrics in
//    the cover area; tap lyrics blank -> cover back; tap a lyric line
//    -> seek). The player slice must honour both.
// 3. VOD AND LIVE ARE DIFFERENT PLAYERS, never mixed:
//    - Quality selector: LIVE ONLY, never on VOD (Apple CMS gives one
//      play URL per episode — no quality tiers, so no fake button).
//    - Long-press 2x speed: VOD ONLY (live is real-time and cannot be
//      sped up).
//    - Live switches stream ONLY when stalled; it never proactively
//      switches to a "better" line.
//    - Entry orientation: VOD tap-play goes DIRECTLY landscape
//      fullscreen; live enters PORTRAIT and only the [] button takes
//      it landscape.
// 4. SOURCE RESOLUTION IS SERIAL, FASTEST FIRST. Ask sources one by
//    one in speed order; the FIRST source that returns a playable URL
//    plays immediately — never ask all sources, never wait for a higher
//    tier once a playable URL exists. If the target quality has no URL,
//    play one tier down AT ONCE and keep the target quality for the
//    next track. (`SourceResolver` below is the contract; the player
//    slice implements it.)
// 5. NO LOGIN-GATED FEATURES. The app has no login interface: comment
//    posting, like/follow sync to platform accounts and anything else
//    that needs a platform login must not be added behind this
//    coordinator. Likes are stored locally only; comments are read-only.

import Foundation

/// What kind of playback a request is. VOD and live are distinct cases
/// on purpose — no shared "video" case that could blur rule 3.
enum PlaybackKind: String, Equatable {
    case music
    case vod
    case live
}

/// Audio-quality target tier. The target persists to the next track;
/// a lower tier plays immediately as a drop-down, never labelled as
/// the target tier (Master honesty gate: only a real Master URL
/// satisfies Master).
enum AudioQuality: String, CaseIterable {
    case master
    case hiRes
    case flac
    case high320
    case standard128

    var displayName: String {
        switch self {
        case .master: return "Master"
        case .hiRes: return "Hi-Res"
        case .flac: return "无损 FLAC"
        case .high320: return "高音质 320k"
        case .standard128: return "标准 128k"
        }
    }
}

/// One playable item, as far as the foundation shell knows it.
/// No URL lives here: the URL is resolved at play time by the
/// SourceResolver (rule 4), never stored ahead of playback.
struct PlaybackItem: Identifiable, Equatable {
    let id: String
    let kind: PlaybackKind
    let title: String
    let artist: String?

    var subtitle: String { artist ?? kindSubtitle }

    private var kindSubtitle: String {
        switch kind {
        case .music: return "音乐"
        case .vod: return "影视"
        case .live: return "直播"
        }
    }
}

/// Serial source resolution (rule 4). The player slice implements this:
/// ask sources one by one, fastest first, and call `completion` with the
/// FIRST playable URL — never collect all candidates, never hold playback
/// for a higher tier. `completion(nil)` only when every source returned
/// nothing. Completion-handler style (not async/await): the project
/// keeps SWIFT_VERSION = 5.0 from the old project, and concurrency
/// needs Swift 5.5+.
protocol SourceResolver {
    func resolveFirstPlayable(
        for item: PlaybackItem,
        targetQuality: AudioQuality?,
        completion: @escaping (URL?) -> Void
    )
}

/// Single-audio coordinator. One instance for the whole app
/// (owned by HAoStudioApp, injected as an environment object).
@MainActor
final class PlaybackCoordinator: ObservableObject {
    /// The item the UI shows in the mini player / full player.
    /// Nil in the foundation slice: no engine, no playback, no item.
    @Published private(set) var currentItem: PlaybackItem?

    /// Target audio-quality tier. Persists across tracks (and restarts,
    /// via UserDefaults); a lower tier playing now never overwrites it.
    @Published var targetQuality: AudioQuality {
        didSet { defaults.set(targetQuality.rawValue, forKey: Self.targetQualityKey) }
    }

    /// The resolver the player slice plugs in. Nil in the foundation:
    /// `requestPlay` refuses to record playback without one. (Bare
    /// protocol existential, not `any`: `any` needs Swift 5.6+, and the
    /// project keeps SWIFT_VERSION = 5.0 from the old project.)
    var resolver: SourceResolver?

    static let targetQualityKey = "hao.audio.targetQuality"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.string(forKey: Self.targetQualityKey)
        self.targetQuality = AudioQuality(rawValue: saved ?? "") ?? .hiRes
    }

    /// Request playback of an item. Foundation behaviour: records the
    /// request ONLY when a resolver is plugged in (player slice). Until
    /// then this is a no-op by design — recording an item with no engine
    /// would show a mini player for playback that is not happening.
    /// The player slice implements: stop current first (rule 1), resolve
    /// serially (rule 4), then set `currentItem` and start the engine.
    func requestPlay(_ item: PlaybackItem) {
        guard resolver != nil else { return }
        currentItem = item
    }

    /// Stop everything. Clears the current item; the player slice also
    /// stops the engine here (rule 1: starting anything else stops the
    /// current playback first).
    func stop() {
        currentItem = nil
    }
}
