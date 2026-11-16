// PlayerKernel — multi-engine player core (Pure Live 3.x PlayerKernelService
// + PlayerConsts pattern, ported to native Swift).
//
// Pure Live 3.x keeps three switchable engines in player_consts.dart:
//   engines = {'mpv': mediaKit, 'ijk': fijk, 'exo': exo}, default 'mpv'
//   PlayerKernelService registers the mpv adapter, then on mobile also the
//   ijk + BetterPlayer adapters; PlayerSettingsController.videoPlayerKey
//   (Hive) is the Settings switch ("ijk/exo stay selectable where available").
// iOS mapping (ExoPlayer is Android-only and cannot run on iOS):
//   'mpv' -> libmpv (MpvPlayerBackend, default)
//   'ijk' -> ijkplayer (IJKPlayerBackend, the v1.0.x engine)
//   'exo' -> AVPlayer (AVPlayerBackend, the iOS "exo" slot — BetterPlayer is
//           ExoPlayer on Android / AVPlayer on iOS)
// The stored key is 'videoPlayerKey' semantics ('mpv'/'ijk'/'exo') so the
// web Settings page and the native side share one key space.
// Persistence: UserDefaults 'hao_video_player_key' (native) mirrors the
// web page's localStorage 'hao_player_engine'; the web posts every change
// to the nativePlayer bridge (kind 'playerEngine') so both stay in sync.
// Switching takes effect on the next play; if a player is open it is
// rebuilt in place (VOD resumes at its position, live just reopens).

import Foundation
import UIKit

// One event the backend reports up to the player UI. Mirrors the ijkplayer
// notifications the old player drove its UI from, so the UI logic does not
// change when the engine changes.
enum PlayerBackendEvent {
    // Engine is ready to play (ijk: isPreparedToPlay; AVPlayer: item
    // .readyToPlay; mpv: FILE_LOADED). The player seeks to its start
    // position and plays from here.
    case prepared
    // First video frame hit the screen (ijk: FirstVideoFrameRendered;
    // mpv: VIDEO_RECONFIG; AVPlayer: first timeControlStatus .playing).
    // The player hides its loading UI from here.
    case firstFrame
    // Playback state (ijk: playbackState; AVPlayer: timeControlStatus;
    // mpv: "pause" property).
    case playing
    case paused
    // Stalled / buffering while not started yet (ijk: loadState .stalled;
    // AVPlayer: timeControlStatus .waitingToPlayAtSpecifiedRate). The
    // player only shows the spinner from this while playback has not
    // started — the clock-based stall detection in tickPlayback owns
    // stalls after start, for every engine.
    case stalled
    // Stream finished. .ended = clean EOF (VOD: genuine end; live: the
    // CDN cut the stream — usually an expired anti-code, NOT the room
    // going offline). .error = the engine gave up on this URL.
    case finished(PlayerBackendEndReason)
}

enum PlayerBackendEndReason {
    case ended
    case error
}

// The single interface every engine implements. The player UI
// (NativePlayerViewController) only talks to this — never to an engine
// directly — so quality / line / danmaku / lock / fullscreen behaviour
// is identical on all three engines.
// Picture fit (Pure Live PlayerVideoFitButton): the player cycles
// 适应 / 裁剪 / 拉伸. Each backend maps it to its own scaling control
// (ijk scalingMode, AVPlayerLayer / display-layer videoGravity).
enum PlayerVideoFit {
    case aspectFit, aspectFill, fill
}

protocol PlayerBackend: AnyObject {
    // The video surface. The player embeds it in its videoView and sizes
    // it to the videoView bounds on every layout pass.
    var view: UIView { get }
    var isPlaying: Bool { get }
    // Seconds. currentTime is 0 before start; duration is NaN for live
    // (an endless stream) and for engines that do not know it yet.
    var currentTime: Double { get }
    var duration: Double { get }
    var isPrepared: Bool { get }
    // 0.5–3x. Applied live; a later play() resumes at this rate.
    var playbackRate: Double { get set }
    // Picture fit. Applied live; a later open() starts at it.
    func setVideoFit(_ fit: PlayerVideoFit)
    // Engine -> player UI events (always delivered on the main thread).
    var onEvent: ((PlayerBackendEvent) -> Void)? { get set }
    // Video size in pixels (0x0 until known). The player uses it for the
    // mpv software renderer size and for aspect bookkeeping.
    var onVideoSize: ((CGSize) -> Void)? { get set }
    // Open + autoplay. Returns false when the engine could not even be
    // created (bad URL object) — the player shows the failure UI then.
    // headers: HTTP headers for the stream (User-Agent + Referer; see
    // PlayerKernel.httpHeaders(platform:)). Live + VOD both go through here.
    @discardableResult func open(url: URL, headers: [String: String]) -> Bool
    func play()
    func pause()
    // VOD only (live has no seek). Clamped to [0, duration] by the player.
    func seek(to seconds: Double)
    // Stop + release everything (engine, observers, views). Idempotent.
    func shutdown()
}

enum PlayerEngineKey: String, CaseIterable {
    // Pure Live key space: 'mpv' / 'ijk' / 'exo'.
    case mpv = "mpv"
    case ijk = "ijk"
    // The iOS "exo" slot is AVPlayer (BetterPlayer = ExoPlayer on
    // Android / AVPlayer on iOS). The key stays 'exo' so the web
    // Settings page and the native side share Pure Live's key space.
    case avplayer = "exo"

    var displayName: String {
        switch self {
        case .mpv: return "MPV"
        case .ijk: return "IJK"
        case .avplayer: return "系统播放器"
        }
    }

    // AVPlayer cannot decode FLV (Huya / Douyu live are FLV). The other
    // two engines play HLS + FLV.
    var supportsFLV: Bool { self != .avplayer }

    static func from(_ raw: String?) -> PlayerEngineKey {
        guard let raw = raw, let key = PlayerEngineKey(rawValue: raw) else { return .mpv }
        return key
    }
}

enum PlayerKernel {
    // UserDefaults key (native side). Mirrors Pure Live's Hive
    // 'videoPlayerKey' and the web page's localStorage
    // 'hao_player_engine'.
    static let userDefaultsKey = "hao_video_player_key"

    // Current engine. Default MPV (Pure Live's defaultKey = 'mpv').
    static var current: PlayerEngineKey {
        get {
            let raw = UserDefaults.standard.string(forKey: userDefaultsKey)
            return PlayerEngineKey.from(raw)
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: userDefaultsKey)
        }
    }

    static func makeBackend(engine: PlayerEngineKey = current) -> PlayerBackend {
        switch engine {
        case .mpv: return MpvPlayerBackend()
        case .ijk: return IJKPlayerBackend()
        case .avplayer: return AVPlayerBackend()
        }
    }

    // Can this engine play this URL at all? Only the AVPlayer/FLV gap
    // is known up front; everything else is discovered by trying.
    static func supports(url: URL, engine: PlayerEngineKey = current) -> Bool {
        if !engine.supportsFLV, url.pathExtension.lowercased() == "flv" { return false }
        return true
    }

    // HTTP headers every engine sends for a stream (the ijkplayer
    // options this was copied from, shared so all three engines get
    // the same CDN treatment):
    // - Browser User-Agent: Huya's CDN rejects FFmpeg's default UA
    //   (HTTP 403) but accepts a browser UA (verified with ffprobe).
    // - Referer per platform, same rule as the old ijk options.
    static let browserUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    static func httpHeaders(platform: String) -> [String: String] {
        let referer: String
        switch platform {
        case "huya": referer = "https://www.huya.com/"
        case "bili": referer = "https://live.bilibili.com/"
        case "douyin": referer = "https://live.douyin.com/"
        case "douyu": referer = "https://www.douyu.com/"
        case "ks": referer = "https://live.kuaishou.com/"
        default: referer = "https://example.invalid/"
        }
        return ["User-Agent": browserUserAgent, "Referer": referer]
    }
}
