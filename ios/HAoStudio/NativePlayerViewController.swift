import UIKit
import IJKMediaFramework
import MediaPlayer
import AVFoundation
import AVKit

// Fullscreen native player — ONE engine for everything (ijkplayer /
// FFmpeg), like Pure Live. HLS (Bilibili / Douyin / Huya) and FLV
// (Kuaishou / Douyu) live, plus VOD movies / episodes, all play here
// in a single UI with the same bars, quality button and loading state.
// ijkplayer replaces both earlier engines: VLC (Huya's CDN blocks
// VLC's HTTP client with 403) and the system player (cannot decode
// FLV).
// The `format` the web page posts ('hls' / 'flv') is accepted but no
// longer picks an engine — ijkplayer plays both.
// - Live (kind "live"): quality switch via the 画质 button; room
//   switches reuse this player and swap the stream in place
//   (shutdown + recreate with the new URL, same view, same UI).
//   Danmaku rides on the video too: the web page already runs the
//   Bilibili WS / Kuaishou polling danmaku for the room, and this
//   player pulls fresh items from it through `liveDanmakuPull`
//   (a JS bridge set by ViewController) and spawns them on the same
//   danmaku layer VOD uses. The bridge drains whatever the web page
//   feeds — Bilibili / Huya / Douyu WS danmaku and Kuaishou polling;
//   Douyin has no danmaku source in v1 (needs a ttwid Cookie the
//   browser cannot send), so it shows none for now.
// - VOD (kind "vod"): HLS movie / episode playback with a native danmaku
//   layer. Standalone has no server: the web page fetches the episode's
//   danmaku itself (Bilibili direct via nativeFetch) and feeds time-synced
//   items in through `feedVodDanmaku(_:)` — this player never fetches
//   danmaku from any server. The old shop server-side danmaku fetch
//   is deleted, not re-pointed.
// The stream is played direct; no server relay.

struct DanmakuConfig {
    // Standalone: baseURL / name / episode / year / type are retained
    // only for postMessage-contract compatibility with the web page;
    // this player makes no request with them (VOD danmaku arrives via
    // feedVodDanmaku, live danmaku via liveDanmakuPull).
    var baseURL: URL
    var name: String
    var episode: Int
    var year: String
    var type: String
    var enabled: Bool
    var opacity: Double
    var speed: Double
    var position: String
}

// One playable quality of a live room, handed over by the web page.
struct LiveQuality {
    var id: String
    var name: String
    var url: URL
}

struct NativePlayerConfig {
    var url: URL
    var title: String
    var platform: String
    var kind: String
    var startPosition: Double
    var danmaku: DanmakuConfig?
    var qualities: [LiveQuality] = []
    // 'hls' or 'flv' for live (from the web page). Accepted for
    // compatibility with the web postMessage contract, but ijkplayer
    // plays both formats, so it no longer picks an engine.
    var format: String = ""
    // Synced-lyrics LRC text, when the web page has it (music songs;
    // VOD movies have none, so this is normally empty). Drives the
    // lyrics Live Activity on the lock screen / Dynamic Island.
    var lyrics: String = ""
    // Poster / room cover for the lock screen + Control Center artwork.
    // Optional: no cover just means no artwork, never a failure.
    var coverURL: URL? = nil
    // Playback speed chosen on the web page (0.5–3x, default 1). The web
    // page sends it in the nativePlayer message; the player applies it to
    // ijkplayer and reports changes back via onSpeedChanged.
    var playbackSpeed: Double = 1
    // Stable platform room id (from the web page's liveRoom.roomId,
    // sent as `roomId` in the nativePlayer message). Drives the
    // per-room volume memory key. Empty when the web page did not send
    // one — the key then falls back to the room title (weak: titles
    // change per broadcast, so the memory may miss; see liveVolumeKey).
    var roomId: String = ""
}

private struct DanmakuItem {
    var id: String
    var time: Double
    var text: String
}

// Gradient shade under a control bar (Pure Live OnVideoColors.shade):
// 60% black at the screen edge fading to transparent into the picture,
// stops [0, 0.55, 1]. Replaces the frosted UIVisualEffectView bars --
// a shade looks like the video itself darkening at the edges, while a
// blur bar looks like a settings panel floating over the video.
private final class BarShadeView: UIView {
    private let gradient = CAGradientLayer()
    init(down: Bool) {
        super.init(frame: .zero)
        backgroundColor = .clear
        gradient.colors = [UIColor(white: 0, alpha: 0.6).cgColor,
                           UIColor(white: 0, alpha: 0.3).cgColor,
                           UIColor(white: 0, alpha: 0).cgColor]
        gradient.locations = [0, 0.55, 1]
        if down {
            gradient.startPoint = CGPoint(x: 0.5, y: 0)
            gradient.endPoint = CGPoint(x: 0.5, y: 1)
        } else {
            gradient.startPoint = CGPoint(x: 0.5, y: 1)
            gradient.endPoint = CGPoint(x: 0.5, y: 0)
        }
        layer.addSublayer(gradient)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        gradient.frame = bounds
    }
}

// Battery chip (Pure Live PlaybackHud: 36x17 outline, 11px figure).
// Plain views: an outline, a fill proportional to the level, and a nub.
private final class BatteryChipView: UIView {
    private let fill = UIView()
    private let nub = UIView()
    var level: Double = 1 { didSet { setNeedsLayout() } }
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        layer.borderWidth = 1
        layer.borderColor = UIColor.white.cgColor
        layer.cornerRadius = 4
        clipsToBounds = false
        fill.backgroundColor = .white
        fill.layer.cornerRadius = 2
        addSubview(fill)
        nub.backgroundColor = .white
        nub.layer.cornerRadius = 1
        addSubview(nub)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        let innerW = bounds.width - 4
        let innerH = bounds.height - 4
        fill.frame = CGRect(x: 2, y: 2, width: max(0, innerW * CGFloat(max(0, min(1, level)))), height: innerH)
        nub.frame = CGRect(x: bounds.width - 0.5, y: bounds.height / 2 - 3, width: 2.5, height: 6)
    }
}

final class NativePlayerViewController: UIViewController {

    private var streamURL: URL
    // Title / platform / roomId are `var`, not `let`: a room switch
    // reuses this player in place (updateStream) and the identity must
    // follow the new room — the per-room volume key reads them.
    private var streamTitle: String
    private var platform: String
    private var roomId: String
    private let kind: String
    private let startPosition: Double
    private var danmakuConfig: DanmakuConfig?

    // The single playback engine (ijkplayer / FFmpeg) for live HLS +
    // FLV and VOD. Recreated (shutdown + new instance) on every
    // stream switch; the UI never re-presents.
    private var ijkPlayer: IJKFFMoviePlayerController?
    // Accepted from the web page for compatibility; ijkplayer plays
    // both formats, so this never picks an engine.
    private var streamFormat: String
    // Playback state tracked for the spinner / retry / ended UI.
    private var playFailed = false
    private var liveAutoRetried = false
    // Whether the current stall episode already triggered a line switch
    // (see tickPlayback). Cleared whenever the clock advances, so a
    // later stall can switch again.
    private var stallLineSwitched = false
    // Live only: how many consecutive .playbackEnded clean-EOFs have
    // fired WITHOUT any playback clock advance in between. Huya's FLV
    // anti-code expires after ~5 min (wsTime+300s) and the CDN cuts
    // the stream, which ijkplayer reports as a clean EOF — the room
    // is usually still live, so the first few EOFs must ask the web
    // page for the next CDN line / a fresh URL instead of showing
    // "直播已结束" (see ijkPlaybackDidFinish). Cleared whenever the
    // clock advances, so a later expiry is a new episode. Deliberately
    // NOT reset in startIJKPlayback/updateStream: each re-posted line
    // would reset it and the cap could never trip. Cap is 5: enough
    // for 3 CDN lines + a fresh URL + one more line; a truly offline
    // room ends on "直播已结束" (or the 30s never-started safety net)
    // instead of looping forever.
    private var liveEndedRetries = 0
    private var didEnd = false
    private var userPaused = false
    private var playbackStartedAt = Date()
    // Last playback clock seen by the 0.25s poll timer, and when it
    // last advanced. Drives the stall detection (see tickPlayback).
    private var lastPlaybackTime: Double = 0
    private var lastAdvanceDate: Date = Date()
    private var playbackTimer: Timer?
    private var videoView: UIView!
    private var danmakuView: UIView!
    private var topBar: UIView!
    private var bottomBar: UIView!
    private var titleLabel: UILabel!
    private var titleLeadingClose: NSLayoutConstraint?
    private var titleLeadingHUD: NSLayoutConstraint?
    // HUD clock + battery (Pure Live PlaybackHud, landscape only).
    private var hudStack: UIStackView?
    private var clockLabel: UILabel?
    private var batteryChip: BatteryChipView?
    private var batteryPctLabel: UILabel?
    private var clockTimer: Timer?
    // Status layer action buttons (Pure Live player_status).
    private var statusDimView: UIView?
    private var statusActionsStack: UIStackView?
    private var statusRetryButton: UIButton?
    private var statusLineButton: UIButton?
    private var statusRoomButton: UIButton?
    private var spinner: UIActivityIndicatorView!
    private var statusLabel: UILabel!
    private var playPauseButton: UIButton!
    private var controlsVisible = true
    private var didStop = false
    private var didSeekToStart = false
    // Set once the current stream has really started (playback time
    // advanced past ~0.5s, or state first became .playing). ijkplayer
    // keeps reporting .stalled while re-fetching on a slow overseas
    // source even though the picture plays fine from its buffer, so
    // the loading spinner must not come back once this is true.
    // Reset in updateStream for a new live stream.
    private var hasStartedPlaying = false
    private var didReportClose = false
    var onClose: ((Double) -> Void)?
    // Live only: called when ijkplayer finally gives up on a live
    // stream (its one same-URL auto-retry already failed). The web
    // page fetches a FRESH play URL and re-posts it — retrying the
    // same expired URL can never work. VOD never calls this.
    var onLiveFailed: (() -> Void)?
    // Pure Live style: the top/bottom bars fade out on their own after
    // a few idle seconds (tap the video to bring them back).
    private var controlsHideTimer: Timer?
    // Live danmaku: the web page runs Bilibili WS / Kuaishou polling
    // and buffers fresh items; ViewController hands this player a
    // closure that drains them (JS bridge). The player polls it and
    // spawns each item on the danmaku layer.
    var liveDanmakuPull: ((@escaping ([String]) -> Void) -> Void)?
    private var liveDanmakuTimer: Timer?
    private var fullscreenButton: UIButton?

    // Visual landscape (see setVisualLandscape): the whole player UI
    // lives in contentView; rotating it 90° shows landscape video
    // without touching the system orientation, so it works even with
    // the iPhone orientation lock on.
    private var contentView: UIView!
    private var visualLandscape = false
    private var didApplyOpenLandscape = false
    private var topBarTopConstraint: NSLayoutConstraint?
    private var bottomBarBottomConstraint: NSLayoutConstraint?

    // VOD seek UI.
    private var seekSlider: UISlider?
    private var curTimeLabel: UILabel?
    private var durTimeLabel: UILabel?
    private var isScrubbing = false

    // VOD danmaku engine.
    private var danmakuEnabled: Bool
    private var danmakuItems: [DanmakuItem] = []
    private var danmakuCursor = 0
    private var lastDanmakuTime = 0.0
    private var laneBusyUntil: [Int: Date] = [:]
    private var danmakuButton: UIButton?
    // Danmaku settings panel (position / opacity / speed), opened by
    // the gear button in the top bar. The native player had only an
    // on/off toggle, so the position could not be changed while
    // watching — this is the in-player settings the user asked for.
    private var danmakuSettingsButton: UIButton?
    private var danmakuSettingsView: UIView?
    private var danmakuPosSegment: UISegmentedControl?
    private var danmakuOpacitySlider: UISlider?
    private var danmakuSpeedSlider: UISlider?
    private var danmakuOpacityValueLabel: UILabel?
    private var danmakuSpeedValueLabel: UILabel?
    // Called when the user changes danmaku position/opacity/speed in
    // the player, so the web page can persist it (localStorage) and
    // the next player open uses the same values.
    var onDanmakuSettingsChanged: ((String, Double, Double) -> Void)?
    // Playback speed (VOD, 0.5–3x). Set from the web page's vodSpeed on
    // open; changed in the settings panel or by long-press 2x. Reported
    // back via onSpeedChanged so the web page stays in step.
    private var playbackSpeed: Double = 1
    private var playbackSpeedSegment: UISegmentedControl?
    var onSpeedChanged: ((Double) -> Void)?
    // Long-press 2x: while held, the speed is temporarily 2x; on release
    // the pre-press speed is restored. `suppressTapUntil` stops the
    // finger-lift tap from toggling the controls after a long-press.
    private var longPressSpeedActive = false
    private var speedBeforeLongPress: Double = 1
    private var suppressTapUntil = Date.distantPast
    private var speed2xLabel: UILabel?

    // Live quality list (from the web page) + current selection.
    private var liveQualities: [LiveQuality]
    private var currentQualityId: String?
    private var qualityButton: UIButton?
    private var switchingStream = false

    // Pure Live player copy (Phase A): gestures, lock, HUD, follow.
    // Live only: the web page switches to the previous / next room
    // (its liveSwipeNext(dir)); set by ViewController. Nil when the
    // web page has no room list (deep link) -- the room-switch gesture
    // and button hide themselves then, instead of showing a dead control.
    var onRequestRoomSwitch: ((Int) -> Void)?
    // Live only: the web page toggles the follow for the current room
    // (its toggleLiveFollow); set by ViewController.
    var onFollowTapped: (() -> Void)?
    private var isFollowed = false
    private var isLocked = false
    private var lockButtonHiddenByTap = false
    private var lockButton: UIButton?
    private var followButton: UIButton?
    private var refreshButton: UIButton?
    private var lineButton: UIButton?
    private var liveChip: UIView?
    private var airPlayView: AVRoutePickerView?
    private var bottomStack: UIStackView?
    private var panGesture: UIPanGestureRecognizer?
    private var doubleTapGesture: UITapGestureRecognizer?
    private var volumeView: MPVolumeView?
    // KVO on the system volume (hardware buttons / Control Center):
    // while a live room is on screen, any change is saved for the
    // current room (see liveVolumeKey). Block-based observation —
    // releasing it (deinit) invalidates it.
    private var volumeObservation: NSKeyValueObservation?
    private var gesturePill: UIView?
    private var gesturePillIcon: UIImageView?
    private var gesturePillBar: UIProgressView?
    private var gesturePillText: UILabel?
    private var gestureHideTimer: Timer?
    private var panKind: PanKind = .none
    private var panStartPoint = CGPoint.zero
    private var panStartBrightness: CGFloat = 0.5
    private var panStartVolume: Float = 0.5
    private var panStartPosition: Double = 0
    private var panSeekTarget: Double = 0
    private var panRoomDir = 0
    private var panDecided = false

    private enum PanKind {
        case none, brightness, volume, seek, roomSwitch
    }

    // Lock screen / Control Center (Part 1): MPNowPlayingInfoCenter +
    // MPRemoteCommandCenter. `lyrics` / `coverURL` come from the
    // postMessage contract via NativePlayerConfig.
    private var lyricsText: String
    private var coverURL: URL?
    private var nowPlayingArtwork: MPMediaItemArtwork?
    private var nowPlayingActive = false
    private var lastNowPlayingUpdate = Date.distantPast
    // Synced-lyrics Live Activity (Part 2, iOS 16.2+): started when
    // this player has LRC lyrics; the NPC drives the position from
    // its own playback clock (externalDrive = true).
    private var lyricsActivityStarted = false

    init(config: NativePlayerConfig) {
        self.streamURL = config.url
        self.streamTitle = config.title
        self.platform = config.platform
        self.roomId = config.roomId
        self.kind = config.kind
        self.startPosition = config.startPosition
        self.danmakuConfig = config.danmaku
        if config.kind == "live" {
            // Live has no episode danmaku file; give it a default config
            // ONLY when the web page sent no danmaku settings, so
            // spawnDanmaku works. When the web page did send them
            // (dm.pos / opacity / speed / enabled — the global dmPos),
            // use those: the position the user set must survive into
            // every live room, same as VOD. The baseURL is unused for
            // live (items come from the web bridge).
            if self.danmakuConfig == nil {
                // Inert placeholder: baseURL is unused for live (items
                // come from the web bridge) and standalone has no
                // server to point it at. Never fetched.
                let base = URL(string: "https://example.invalid/")!
                self.danmakuConfig = DanmakuConfig(baseURL: base, name: "", episode: 0, year: "", type: "", enabled: true, opacity: 0.9, speed: 1, position: "full")
            }
            self.danmakuEnabled = self.danmakuConfig?.enabled ?? true
        } else {
            self.danmakuEnabled = config.danmaku?.enabled ?? false
        }
        self.streamFormat = config.format
        self.lyricsText = config.lyrics
        self.coverURL = config.coverURL
        self.playbackSpeed = config.playbackSpeed
        self.liveQualities = config.qualities
        self.currentQualityId = config.qualities.first(where: { $0.url == config.url })?.id
        super.init(nibName: nil, bundle: nil)
        self.modalPresentationStyle = .fullScreen
    }

    convenience init(streamURL: URL, title: String, platform: String, qualities: [LiveQuality] = [], format: String = "", coverURL: URL? = nil, danmaku: DanmakuConfig? = nil, roomId: String = "") {
        var config = NativePlayerConfig(url: streamURL, title: title, platform: platform, kind: "live", startPosition: 0, danmaku: danmaku, qualities: qualities, format: format)
        config.coverURL = coverURL
        config.roomId = roomId
        self.init(config: config)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        volumeObservation = nil
        playbackTimer?.invalidate()
        controlsHideTimer?.invalidate()
        liveDanmakuTimer?.invalidate()
        clockTimer?.invalidate()
        gestureHideTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        // Safety net: the normal path tears these down in stopPlayback
        // (called from viewWillDisappear / closeTapped); both are
        // no-ops if that already ran.
        teardownNowPlaying()
        endLyricsActivity()
        ijkPlayer?.shutdown()
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        // Live rooms must open in portrait — landscape only via the
        // player's fullscreen button (visual rotation). Returning .all
        // here let the system rotate a live room to landscape on entry,
        // even though the visual-landscape transform is VOD-only.
        // VOD keeps .all: it goes landscape on open by design.
        return isVod ? .all : .portrait
    }

    // THE missing half of the portrait-on-entry rule (v1.0.0 bug:
    // live rooms still opened landscape on chen's phone even though
    // supportedInterfaceOrientations returned .portrait for live).
    // supportedInterfaceOrientations only constrains FUTURE rotations
    // once the player is on screen — it does NOT pick the orientation
    // the player is FIRST presented in. That comes from
    // preferredInterfaceOrientationForPresentation, whose default is
    // the CURRENT interface orientation. The main ViewController
    // (web) supports all orientations, so if the phone is held
    // sideways / the interface is landscape when a room is tapped
    // (orientation lock off), the player was presented in landscape
    // and nothing ever rotated it back — no device-rotation event
    // fires while the phone sits still. Overriding this to .portrait
    // for live makes the presentation itself start in portrait,
    // whatever the interface orientation was before. VOD keeps the
    // default: it goes visual-landscape on open by design.
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        return isVod ? super.preferredInterfaceOrientationForPresentation : .portrait
    }

    // Explicit (the default): rotation is allowed, so a live room
    // still rotates back to portrait on the next orientation event,
    // and VOD keeps rotating with the device.
    override var shouldAutorotate: Bool {
        return true
    }

    override var prefersStatusBarHidden: Bool {
        return true
    }

    private var isVod: Bool { kind == "vod" }

    // Whether the ijkplayer engine is currently playing (ViewController
    // reads this for the keep-screen idle timer: the screen only stays
    // on while a player is on screen AND playing).
    var isPlaying: Bool { ijkPlayer?.isPlaying() ?? false }

    // MARK: - Per-room volume memory (live only)
    // Each live room remembers its own volume: entering a room applies
    // the level last used there, changing the volume saves it.
    // HOW IT WORKS (honest): ijkplayer exposes no per-player volume
    // API that this project uses, and AVAudioSession only reports the
    // SYSTEM volume — the only supported way to SET it is the hidden
    // MPVolumeView slider this player already drives for the volume
    // gesture. So "per-room volume" here means the SYSTEM volume level
    // remembered per room: entering room A sets the system volume to
    // A's remembered level; changing it (gesture, hardware buttons,
    // Control Center) saves it for the current room. It does NOT
    // isolate rooms from each other at the audio level — it restores
    // the level you last used in each room.
    // Key: liveVol_<platform>_<roomId> (roomId from the web page), or
    // liveVol_<platform>_<title> when the web page sent no roomId.
    private var liveVolumeKey: String {
        let room = roomId.isEmpty ? streamTitle : roomId
        return "liveVol_" + platform + "_" + room
    }
    private func applyRememberedLiveVolume() {
        guard isLive else { return }
        guard let level = UserDefaults.standard.object(forKey: liveVolumeKey) as? Float else { return }
        if systemVolumeSlider() != nil {
            systemVolumeSlider()?.value = level
        } else {
            // MPVolumeView builds its slider lazily; retry once after
            // layout so a first-open restore is not silently lost.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self, self.isLive else { return }
                if let l = UserDefaults.standard.object(forKey: self.liveVolumeKey) as? Float {
                    self.systemVolumeSlider()?.value = l
                }
            }
        }
    }
    private func saveCurrentLiveVolume(_ level: Double) {
        guard isLive else { return }
        UserDefaults.standard.set(Float(max(0, min(1, level))), forKey: liveVolumeKey)
    }
    // True for a live player (used by ViewController to reuse it instead
    // of presenting a second one when the web posts a new live URL).
    var isLive: Bool { kind == "live" }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Re-derive the player frame from the LIVE view bounds on
        // every layout pass (rotation, split view, different device).
        layoutContentView()
        if !didApplyOpenLandscape {
            didApplyOpenLandscape = true
            // VOD opened from the ▶ 播放 button: go landscape on open.
            // Live rooms stay portrait — landscape only via the
            // fullscreen button.
            if isVod && view.bounds.width < view.bounds.height {
                visualLandscape = true
                layoutContentView()
            }
        }
        guard let videoView = videoView else { return }
        ijkPlayer?.view.frame = videoView.bounds
    }

    // MARK: - Visual landscape (device-adaptive, lock-proof)

    // Sizes and rotates contentView from the LIVE view bounds — read
    // fresh on every call, never hardcoded, no device-model checks.
    // Portrait bounds (W×H) become a landscape layout (H×W) rotated
    // -90°, so the video fills the screen edge-to-edge on any iPhone
    // (390×844 iPhone Air, larger phones, split view alike). Called
    // from viewDidLayoutSubviews, so any bounds change while the
    // player is open re-derives the frame automatically.
    private func layoutContentView() {
        guard let contentView = contentView else { return }
        let b = view.bounds
        let wantVisual = visualLandscape && b.width < b.height
        if wantVisual {
            // Landscape layout sized from the real device bounds:
            // width = portrait height, height = portrait width.
            contentView.transform = .identity
            contentView.bounds = CGRect(x: 0, y: 0, width: b.height, height: b.width)
            contentView.center = CGPoint(x: b.midX, y: b.midY)
            // -90°: the layout's top stays at the top after the user
            // rotates the phone clockwise (landscapeRight).
            contentView.transform = CGAffineTransform(rotationAngle: -.pi / 2)
            topBarTopConstraint?.constant = 0
            bottomBarBottomConstraint?.constant = 0
        } else {
            contentView.transform = .identity
            contentView.frame = b
            // Root-view safe area is always in unrotated coordinates,
            // so the bars clear the Dynamic Island / home indicator
            // in portrait exactly as before.
            topBarTopConstraint?.constant = view.safeAreaInsets.top
            bottomBarBottomConstraint?.constant = -view.safeAreaInsets.bottom
        }
        contentView.layoutIfNeeded()
        updateLandscapeOnlyViews()
    }

    private func setVisualLandscape(_ on: Bool) {
        guard visualLandscape != on else { return }
        visualLandscape = on
        // Leaving fullscreen releases the lock (Pure Live).
        if !on && isLocked { setLocked(false) }
        view.setNeedsLayout()
        view.layoutIfNeeded()
        updateFullscreenButton()
    }

    private var platformName: String {
        if platform == "ks" {
            return "快手"
        } else if platform == "douyu" {
            return "斗鱼"
        } else if platform == "bili" {
            return "哔哩哔哩"
        } else if platform == "douyin" {
            return "抖音"
        } else if platform == "huya" {
            return "虎牙"
        } else if platform == "video" {
            return "影视"
        } else {
            return platform
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        buildUI()
        danmakuView.isHidden = !danmakuEnabled
        startPlayback()
        if !isVod {
            startLiveDanmakuPull()
            // Per-room volume memory: save the level whenever the
            // system volume changes while this live room is on screen
            // (hardware buttons, Control Center, or the gesture —
            // the gesture also saves directly, this covers the rest).
            // AVAudioSession.outputVolume is KVO-compliant. The
            // restore itself also fires this (same value) — harmless.
            volumeObservation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] _, _ in
                guard let self = self, self.isLive else { return }
                self.saveCurrentLiveVolume(Double(AVAudioSession.sharedInstance().outputVolume))
            }
        }
        // Battery monitoring for the HUD battery chip (landscape).
        UIDevice.current.isBatteryMonitoringEnabled = true
        updateClockLabel()
        updateBattery()
        startClockTimer()
        // Pure Live: bars fade out on their own if the user does not
        // touch anything; a tap on the video brings them back.
        scheduleControlsHide()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Live rooms restore their remembered volume once the view is
        // on screen (the MPVolumeView slider exists by now).
        applyRememberedLiveVolume()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Only tear down when the player is actually being dismissed.
        // A system popup / incoming-call screen also triggers
        // viewWillDisappear and must not kill playback.
        guard isBeingDismissed else { return }
        reportClose()
        stopPlayback()
    }

    private func buildUI() {
        // Content container: every player element lives inside it, so
        // the visual-landscape rotation turns the whole UI at once.
        // Frame-managed (no constraints) — layoutContentView() sizes
        // it from the live view bounds on every layout pass.
        let contentView = UIView()
        contentView.backgroundColor = .black
        view.addSubview(contentView)
        self.contentView = contentView

        // Video surface.
        let videoView = UIView()
        videoView.backgroundColor = .black
        videoView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(videoView)
        NSLayoutConstraint.activate([
            videoView.topAnchor.constraint(equalTo: contentView.topAnchor),
            videoView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            videoView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
        ])
        self.videoView = videoView

        // Danmaku layer: above the video, below the bars. It never takes
        // touches, so taps still reach the video view's gesture recognizer.
        let danmakuView = UIView()
        danmakuView.backgroundColor = .clear
        danmakuView.isUserInteractionEnabled = false
        danmakuView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(danmakuView)
        NSLayoutConstraint.activate([
            danmakuView.topAnchor.constraint(equalTo: contentView.topAnchor),
            danmakuView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            danmakuView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            danmakuView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
        ])
        self.danmakuView = danmakuView

        // Tap the video to show / hide the controls.
        let tap = UITapGestureRecognizer(target: self, action: #selector(toggleControls(_:)))
        videoView.addGestureRecognizer(tap)

        // Long-press the video (~0.5s) for a temporary 2x; release
        // restores the chosen speed. VOD only — a live stream cannot
        // be sped up. The recognizer sits on the video surface (not the
        // bars), so it never fires from a button press.
        if isVod {
            let lp = UILongPressGestureRecognizer(target: self, action: #selector(longPressSpeed(_:)))
            lp.minimumPressDuration = 0.5
            lp.cancelsTouchesInView = false
            videoView.addGestureRecognizer(lp)
            let ind = UILabel()
            ind.text = "2x"
            ind.font = .systemFont(ofSize: 14, weight: .bold)
            ind.textColor = .white
            ind.textAlignment = .center
            ind.backgroundColor = UIColor(white: 0, alpha: 0.65)
            ind.layer.cornerRadius = 14
            ind.clipsToBounds = true
            ind.isHidden = true
            ind.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(ind)
            NSLayoutConstraint.activate([
                ind.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
                ind.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
                ind.widthAnchor.constraint(equalToConstant: 44),
                ind.heightAnchor.constraint(equalToConstant: 28)
            ])
            self.speed2xLabel = ind
        }

        // Gestures (Pure Live player_gestures): vertical drag left =
        // brightness, right = volume, with a centred pill indicator;
        // horizontal drag seeks (VOD); double-tap toggles fullscreen.
        // No require(toFail:) on the single tap: Pure Live fires the
        // tap immediately, and a double-tap's two toggles cancel out.
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        videoView.addGestureRecognizer(pan)
        self.panGesture = pan
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapFullscreen))
        doubleTap.numberOfTapsRequired = 2
        videoView.addGestureRecognizer(doubleTap)
        self.doubleTapGesture = doubleTap

        // Loading spinner + status text, centered.
        let spinner = UIActivityIndicatorView(style: .large)
        spinner.color = .white
        spinner.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])
        self.spinner = spinner

        let statusLabel = UILabel()
        statusLabel.text = "正在加载…"
        statusLabel.font = .systemFont(ofSize: 14)
        statusLabel.textColor = UIColor(white: 1, alpha: 0.65)
        statusLabel.textAlignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            statusLabel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 12)
        ])
        self.statusLabel = statusLabel

        // Status layer (Pure Live player_status): a dim veil plus real
        // action buttons on failure / end. The spinner + label above
        // are the loading state; these only appear when the stream
        // has failed or genuinely ended.
        let statusDim = UIView()
        statusDim.backgroundColor = UIColor(white: 0, alpha: 0.6)
        statusDim.isHidden = true
        statusDim.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(statusDim)
        NSLayoutConstraint.activate([
            statusDim.topAnchor.constraint(equalTo: contentView.topAnchor),
            statusDim.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            statusDim.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            statusDim.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
        ])
        // Below the spinner + label, above the bars.
        contentView.bringSubviewToFront(spinner)
        contentView.bringSubviewToFront(statusLabel)
        self.statusDimView = statusDim

        let actionsStack = UIStackView()
        actionsStack.axis = .horizontal
        actionsStack.spacing = 10
        actionsStack.alignment = .center
        actionsStack.isHidden = true
        actionsStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(actionsStack)
        NSLayoutConstraint.activate([
            actionsStack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            actionsStack.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 16)
        ])
        let retryBtn = makeStatusButton(title: "重试", primary: true, action: #selector(statusRetryTapped))
        actionsStack.addArrangedSubview(retryBtn)
        self.statusRetryButton = retryBtn
        let lineBtn = makeStatusButton(title: "换线路", primary: false, action: #selector(statusLineTapped))
        actionsStack.addArrangedSubview(lineBtn)
        self.statusLineButton = lineBtn
        let roomBtn = makeStatusButton(title: "换房间", primary: false, action: #selector(statusRoomTapped))
        actionsStack.addArrangedSubview(roomBtn)
        self.statusRoomButton = roomBtn
        self.statusActionsStack = actionsStack

        // Top bar: gradient shade, not a blur bar (Pure Live
        // OnVideoColors.shade). Bare white icons, 48x48 touch.
        let topBar = BarShadeView(down: true)
        topBar.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(topBar)
        NSLayoutConstraint.activate([
            topBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 52)
        ])
        // Top offset is a stored constraint: layoutContentView() sets
        // it from the root view's safe area in portrait, or 0 in
        // visual landscape (the physical top edge maps to the
        // landscape left edge, so there is no top notch there).
        let topBarTop = topBar.topAnchor.constraint(equalTo: contentView.topAnchor)
        topBarTop.isActive = true
        topBarTopConstraint = topBarTop
        self.topBar = topBar

        let closeButton = makeVideoIconButton(systemName: "xmark", pointSize: 22, action: #selector(closeTapped))
        topBar.addSubview(closeButton)
        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 4),
            closeButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor)
        ])

        // Danmaku settings (gear): opens the in-player danmaku panel
        // (position / opacity / speed). Bare white icon, top-right.
        let dmSettingsButton = makeVideoIconButton(systemName: "gearshape", pointSize: 22, action: #selector(danmakuSettingsTapped))
        topBar.addSubview(dmSettingsButton)
        NSLayoutConstraint.activate([
            dmSettingsButton.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -4),
            dmSettingsButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor)
        ])
        self.danmakuSettingsButton = dmSettingsButton

        // HUD clock + battery (Pure Live PlaybackHud): landscape only,
        // phones in portrait use the system clock. Sits between the
        // close button and the title; the title's leading constraint
        // switches to it in landscape (see updateLandscapeOnlyViews).
        let hudStack = UIStackView()
        hudStack.axis = .horizontal
        hudStack.spacing = 6
        hudStack.alignment = .center
        hudStack.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(hudStack)
        let clockLabel = UILabel()
        clockLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 14, weight: .regular)
        clockLabel.textColor = .white
        clockLabel.textAlignment = .center
        videoShadow(clockLabel)
        hudStack.addArrangedSubview(clockLabel)
        self.clockLabel = clockLabel
        let batteryChip = BatteryChipView(frame: CGRect(x: 0, y: 0, width: 36, height: 17))
        batteryChip.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            batteryChip.widthAnchor.constraint(equalToConstant: 36),
            batteryChip.heightAnchor.constraint(equalToConstant: 17)
        ])
        hudStack.addArrangedSubview(batteryChip)
        self.batteryChip = batteryChip
        let batteryPctLabel = UILabel()
        batteryPctLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        batteryPctLabel.textColor = .white
        videoShadow(batteryPctLabel)
        hudStack.addArrangedSubview(batteryPctLabel)
        self.batteryPctLabel = batteryPctLabel
        NSLayoutConstraint.activate([
            hudStack.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 4),
            hudStack.centerYAnchor.constraint(equalTo: topBar.centerYAnchor)
        ])
        self.hudStack = hudStack

        // LIVE badge (live only): small red #D92D20 mark next to the
        // title. VOD has no badge. The old platform pill is gone.
        let badgeContainer = UIView()
        badgeContainer.backgroundColor = UIColor(red: 0.851, green: 0.18, blue: 0.125, alpha: 1)
        badgeContainer.layer.cornerRadius = 10
        badgeContainer.clipsToBounds = true
        badgeContainer.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(badgeContainer)
        let badge = UILabel()
        badge.text = "直播"
        badge.font = .systemFont(ofSize: 11, weight: .semibold)
        badge.textColor = .white
        badge.textAlignment = .center
        badge.translatesAutoresizingMaskIntoConstraints = false
        badgeContainer.addSubview(badge)
        NSLayoutConstraint.activate([
            badgeContainer.trailingAnchor.constraint(equalTo: dmSettingsButton.leadingAnchor, constant: -8),
            badgeContainer.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            badgeContainer.heightAnchor.constraint(equalToConstant: 20),
            badge.leadingAnchor.constraint(equalTo: badgeContainer.leadingAnchor, constant: 8),
            badge.trailingAnchor.constraint(equalTo: badgeContainer.trailingAnchor, constant: -8),
            badge.centerYAnchor.constraint(equalTo: badgeContainer.centerYAnchor)
        ])
        badgeContainer.isHidden = isVod

        let titleLabel = UILabel()
        titleLabel.text = streamTitle.isEmpty ? platformName + (isVod ? "" : "直播") : streamTitle
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        videoShadow(titleLabel)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(titleLabel)
        let titleLeadingClose = titleLabel.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 8)
        let titleLeadingHUD = titleLabel.leadingAnchor.constraint(equalTo: hudStack.trailingAnchor, constant: 8)
        titleLeadingClose.isActive = true
        self.titleLeadingClose = titleLeadingClose
        self.titleLeadingHUD = titleLeadingHUD
        NSLayoutConstraint.activate([
            titleLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor)
        ])
        if isVod {
            NSLayoutConstraint.activate([
                titleLabel.trailingAnchor.constraint(equalTo: dmSettingsButton.leadingAnchor, constant: -8)
            ])
        } else {
            NSLayoutConstraint.activate([
                titleLabel.trailingAnchor.constraint(equalTo: badgeContainer.leadingAnchor, constant: -8)
            ])
        }
        self.titleLabel = titleLabel

        // Bottom bar: gradient shade, not a blur bar (Pure Live).
        // One horizontal stack holds every control; items hide per
        // kind (live/VOD) and per orientation (see
        // updateBottomBarItems). Pure Live's inline row has no
        // quality/line/follow -- but our player covers the web page,
        // so quality stays in portrait; follow/line/AirPlay are
        // landscape-only, where there is room for them.
        let bottomBar = BarShadeView(down: false)
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(bottomBar)
        NSLayoutConstraint.activate([
            bottomBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: 56)
        ])
        // Bottom offset is a stored constraint (see topBarTop above).
        let bottomBarBottom = bottomBar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        bottomBarBottom.isActive = true
        bottomBarBottomConstraint = bottomBarBottom
        self.bottomBar = bottomBar

        let bottomStack = UIStackView()
        bottomStack.axis = .horizontal
        bottomStack.alignment = .center
        bottomStack.spacing = 4
        bottomStack.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(bottomStack)
        NSLayoutConstraint.activate([
            bottomStack.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 8),
            bottomStack.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -8),
            bottomStack.topAnchor.constraint(equalTo: bottomBar.topAnchor),
            bottomStack.bottomAnchor.constraint(equalTo: bottomBar.bottomAnchor)
        ])
        self.bottomStack = bottomStack

        // Live chip: red LIVE badge + 直连 (landscape only).
        let liveChip = UIView()
        liveChip.backgroundColor = UIColor(red: 0.851, green: 0.18, blue: 0.125, alpha: 1)
        liveChip.layer.cornerRadius = 11
        liveChip.clipsToBounds = true
        liveChip.translatesAutoresizingMaskIntoConstraints = false
        let liveDot = UIView()
        liveDot.backgroundColor = .white
        liveDot.layer.cornerRadius = 3
        liveDot.translatesAutoresizingMaskIntoConstraints = false
        liveChip.addSubview(liveDot)
        let liveLabel = UILabel()
        liveLabel.text = "直播中 · 直连"
        liveLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        liveLabel.textColor = .white
        liveLabel.translatesAutoresizingMaskIntoConstraints = false
        liveChip.addSubview(liveLabel)
        NSLayoutConstraint.activate([
            liveChip.heightAnchor.constraint(equalToConstant: 22),
            liveDot.leadingAnchor.constraint(equalTo: liveChip.leadingAnchor, constant: 10),
            liveDot.centerYAnchor.constraint(equalTo: liveChip.centerYAnchor),
            liveDot.widthAnchor.constraint(equalToConstant: 6),
            liveDot.heightAnchor.constraint(equalToConstant: 6),
            liveLabel.leadingAnchor.constraint(equalTo: liveDot.trailingAnchor, constant: 6),
            liveLabel.trailingAnchor.constraint(equalTo: liveChip.trailingAnchor, constant: -10),
            liveLabel.centerYAnchor.constraint(equalTo: liveChip.centerYAnchor)
        ])
        bottomStack.addArrangedSubview(liveChip)
        self.liveChip = liveChip

        let playPauseButton = makeVideoIconButton(systemName: "pause.fill", pointSize: 28, action: #selector(playPauseTapped))
        bottomStack.addArrangedSubview(playPauseButton)
        self.playPauseButton = playPauseButton

        // Refresh: re-open the current source (Pure Live).
        let refreshButton = makeVideoIconButton(systemName: "arrow.clockwise", pointSize: 22, action: #selector(refreshTapped))
        bottomStack.addArrangedSubview(refreshButton)
        self.refreshButton = refreshButton

        // Follow (live, landscape only): the web page owns the follow
        // list; this button only asks it (onFollowTapped).
        let followButton = makeVideoTextButton(title: "关注", action: #selector(followTapped))
        bottomStack.addArrangedSubview(followButton)
        self.followButton = followButton

        let curLabel = UILabel()
        curLabel.text = "0:00"
        curLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        curLabel.textColor = .white
        curLabel.textAlignment = .center
        curLabel.setContentHuggingPriority(.required, for: .horizontal)
        curLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([curLabel.widthAnchor.constraint(equalToConstant: 46)])
        bottomStack.addArrangedSubview(curLabel)
        self.curTimeLabel = curLabel

        let slider = UISlider()
        slider.minimumValue = 0
        slider.maximumValue = 1
        slider.value = 0
        slider.minimumTrackTintColor = .white
        slider.maximumTrackTintColor = UIColor(white: 1, alpha: 0.24)
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        slider.addTarget(self, action: #selector(seekTouchDown), for: .touchDown)
        slider.addTarget(self, action: #selector(seekTouchUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        slider.translatesAutoresizingMaskIntoConstraints = false
        bottomStack.addArrangedSubview(slider)
        self.seekSlider = slider

        let durLabel = UILabel()
        durLabel.text = "0:00"
        durLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        durLabel.textColor = .white
        durLabel.textAlignment = .center
        durLabel.setContentHuggingPriority(.required, for: .horizontal)
        durLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([durLabel.widthAnchor.constraint(equalToConstant: 46)])
        bottomStack.addArrangedSubview(durLabel)
        self.durTimeLabel = durLabel

        // Danmaku toggle: bare white icon + text. On = yellow #FFD166
        // (Pure Live active), off = white 38%. The old red/grey filled
        // pill is gone.
        let dmButton = UIButton(type: .system)
        var dmCfg = UIButton.Configuration.plain()
        dmCfg.image = UIImage(systemName: "text.bubble", withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold))
        dmCfg.title = "弹幕"
        dmCfg.imagePlacement = .leading
        dmCfg.imagePadding = 4
        dmCfg.baseForegroundColor = danmakuEnabled ? UIColor(red: 1, green: 0.82, blue: 0.4, alpha: 1) : UIColor(white: 1, alpha: 0.38)
        dmCfg.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
            return outgoing
        }
        dmButton.configuration = dmCfg
        dmButton.addTarget(self, action: #selector(danmakuToggleTapped), for: .touchUpInside)
        dmButton.translatesAutoresizingMaskIntoConstraints = false
        videoShadow(dmButton)
        dmButton.heightAnchor.constraint(equalToConstant: 48).isActive = true
        bottomStack.addArrangedSubview(dmButton)
        self.danmakuButton = dmButton

        // Quality switch (live only): plain text button "原画 ⌄"
        // opening a small menu above it (Pure Live stream_menu).
        // Hidden when there are 0 or 1 qualities.
        let qButton = makeVideoTextButton(title: "画质", action: nil)
        bottomStack.addArrangedSubview(qButton)
        self.qualityButton = qButton
        updateQualityButton()

        // Line switch (live, landscape only): asks the web page for
        // the next CDN line (its __nativeLiveFailed tries the next
        // line first). The web posts one URL per quality, so the
        // player cannot show a numbered 线路1/2/3 menu yet -- that
        // needs the web to post each quality's urls array.
        let lineButton = makeVideoTextButton(title: "线路", action: #selector(lineButtonTapped))
        bottomStack.addArrangedSubview(lineButton)
        self.lineButton = lineButton

        // AirPlay (landscape only): the system route picker. Pure
        // Live's cast is DLNA/Chromecast, which iOS does not have;
        // AirPlay is the native equivalent. No PiP button -- it does
        // not work with ijkplayer's OpenGL view, and a dead button
        // is worse than none.
        let airPlay = AVRoutePickerView(frame: .zero)
        airPlay.activeTintColor = .white
        airPlay.tintColor = .white
        airPlay.backgroundColor = .clear
        airPlay.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            airPlay.widthAnchor.constraint(equalToConstant: 48),
            airPlay.heightAnchor.constraint(equalToConstant: 48)
        ])
        bottomStack.addArrangedSubview(airPlay)
        self.airPlayView = airPlay

        // Fullscreen: expand = straight to landscape (Pure Live).
        let fsButton = makeVideoIconButton(systemName: "arrow.up.left.and.arrow.down.right", pointSize: 26, action: #selector(fullscreenTapped))
        bottomStack.addArrangedSubview(fsButton)
        self.fullscreenButton = fsButton

        updateBottomBarItems()

        // Gesture pill (Pure Live): 87% black panel, icon + 100x6 bar
        // + % text, centred; hides 1s after the gesture ends.
        let pill = UIView()
        pill.backgroundColor = UIColor(white: 0, alpha: 0.87)
        pill.layer.cornerRadius = 10
        pill.clipsToBounds = true
        pill.isHidden = true
        pill.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(pill)
        let pillStack = UIStackView()
        pillStack.axis = .horizontal
        pillStack.spacing = 8
        pillStack.alignment = .center
        pillStack.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(pillStack)
        NSLayoutConstraint.activate([
            pillStack.topAnchor.constraint(equalTo: pill.topAnchor, constant: 10),
            pillStack.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -10),
            pillStack.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 14),
            pillStack.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -14)
        ])
        let pillIcon = UIImageView()
        pillIcon.tintColor = .white
        pillIcon.contentMode = .scaleAspectFit
        pillIcon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            pillIcon.widthAnchor.constraint(equalToConstant: 24),
            pillIcon.heightAnchor.constraint(equalToConstant: 24)
        ])
        pillStack.addArrangedSubview(pillIcon)
        self.gesturePillIcon = pillIcon
        let pillBar = UIProgressView(progressViewStyle: .default)
        pillBar.trackTintColor = UIColor(white: 1, alpha: 0.24)
        pillBar.progressTintColor = .white
        pillBar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            pillBar.widthAnchor.constraint(equalToConstant: 100),
            pillBar.heightAnchor.constraint(equalToConstant: 6)
        ])
        pillStack.addArrangedSubview(pillBar)
        self.gesturePillBar = pillBar
        let pillText = UILabel()
        pillText.font = UIFont.monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        pillText.textColor = .white
        pillText.textAlignment = .center
        pillStack.addArrangedSubview(pillText)
        self.gesturePillText = pillText
        NSLayoutConstraint.activate([
            pill.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            pill.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])
        self.gesturePill = pill

        // Lock button (Pure Live LockButton): 50x50 round on 38%
        // black, right-centre in fullscreen. Locked: bars hidden,
        // gestures off, only this button shows (tap the picture to
        // show / hide it).
        let lockBtn = UIButton(type: .system)
        lockBtn.setImage(UIImage(systemName: "lock.open", withConfiguration: UIImage.SymbolConfiguration(pointSize: 28, weight: .semibold)), for: .normal)
        lockBtn.tintColor = .white
        lockBtn.backgroundColor = UIColor(white: 0, alpha: 0.38)
        lockBtn.layer.cornerRadius = 25
        lockBtn.clipsToBounds = true
        lockBtn.addTarget(self, action: #selector(lockTapped), for: .touchUpInside)
        lockBtn.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(lockBtn)
        NSLayoutConstraint.activate([
            lockBtn.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            lockBtn.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            lockBtn.widthAnchor.constraint(equalToConstant: 50),
            lockBtn.heightAnchor.constraint(equalToConstant: 50)
        ])
        lockBtn.isHidden = true
        self.lockButton = lockBtn

        // Hidden system-volume view: AVAudioSession only reports the
        // volume; the only supported way to SET it is a MPVolumeView
        // slider. Kept offscreen; never shown.
        let volumeView = MPVolumeView(frame: CGRect(x: -200, y: -200, width: 10, height: 10))
        volumeView.showsRouteButton = false
        volumeView.showsVolumeSlider = true
        contentView.addSubview(volumeView)
        self.volumeView = volumeView
    }

    // MARK: - ijkplayer engine (the single engine for live + VOD)

    private func makeIJKOptions() -> IJKFFOptions {
        let options = IJKFFOptions.byDefault() ?? IJKFFOptions()
        // Hardware decoding (VideoToolbox) — smooth 1080p on iPhone.
        options.setPlayerOptionIntValue(1, forKey: "videotoolbox")
        // Live streams: let FFmpeg reconnect instead of failing when
        // a flaky overseas CDN drops the HTTP connection.
        options.setFormatOptionIntValue(1, forKey: "reconnect")
        options.setFormatOptionIntValue(1, forKey: "reconnect_streamed")
        options.setFormatOptionIntValue(5, forKey: "reconnect_delay_max")
        // Fast open + fast failure on a dead line (Pure Live's probe /
        // buffer policy: 1 MiB probe, 1 s analyze, 15 s network
        // timeout; its cache is 6 s memory-only, smooth-first, so no
        // nobuffer / low-latency flag — smoothness beats latency here).
        options.setFormatOptionIntValue(1048576, forKey: "probesize")
        options.setFormatOptionIntValue(1000000, forKey: "analyzeduration")
        options.setFormatOptionIntValue(15000000, forKey: "timeout")
        // Huya's CDN rejects FFmpeg's default UA (HTTP 403) but accepts
        // a browser UA (verified with ffprobe: default 403, browser UA
        // returns a valid HLS playlist). Send a browser UA + Referer so
        // picky CDNs treat ijkplayer like a browser. This is what makes
        // Huya play in the native player.
        options.setFormatOptionValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", forKey: "user_agent")
        let referer: String
        switch platform {
        case "huya": referer = "https://www.huya.com/"
        case "bili": referer = "https://live.bilibili.com/"
        case "douyin": referer = "https://live.douyin.com/"
        case "douyu": referer = "https://www.douyu.com/"
        case "ks": referer = "https://live.kuaishou.com/"
        default: referer = "https://example.invalid/"
        }
        options.setFormatOptionValue("Referer: \(referer)\r\n", forKey: "headers")
        // Huya HLS segments carry a query string (xxx.ts?EXTINF=2.7).
        // FFmpeg 4's HLS demuxer blocks segments whose "extension" is
        // not whitelisted — it reads the extension as "ts?EXTINF=2.7",
        // not "ts", so EVERY Huya segment is refused ("not a common
        // multimedia extension") and playback never starts (30s
        // timeout -> 播放失败). Douyu FLV has no segments, so it is
        // unaffected. Verified with ffprobe 4.4 on a local Huya-style
        // playlist: all 3 segments blocked; the clean playlist (same
        // .ts files, no query) probes fine. Allow all extensions —
        // segment URLs come from the platform's own playlist (trusted).
        options.setFormatOptionValue("ALL", forKey: "allowed_extensions")
        return options
    }

    private func startPlayback() {
        startIJKPlayback()
        startPlaybackTimer()
    }

    private func startIJKPlayback() {
        playbackStartedAt = Date()
        lastPlaybackTime = 0
        lastAdvanceDate = Date()
        liveAutoRetried = false
        stallLineSwitched = false
        guard let p = IJKFFMoviePlayerController(contentURL: streamURL, with: makeIJKOptions()) else {
            playFailed = true
            spinner.stopAnimating()
            statusLabel.text = "播放失败，请检查网络后点 ▶ 重试"
            statusLabel.isHidden = false
            updateStatusActions()
            // Player could not even be created (bad URL object): same
            // fresh-URL path as a playback error.
            if !isVod { onLiveFailed?() }
            return
        }
        p.scalingMode = IJKMPMovieScalingMode.aspectFit
        p.shouldAutoplay = true
        p.shouldShowHudView = false
        p.setPauseInBackground(false)
        // Playback speed chosen on the web page (or the default 1x).
        // ijkplayer applies it live; there is no pitch correction in
        // IJKFFMoviePlayerController, so 2x/3x sound higher-pitched —
        // that is the engine's behaviour, not a bug in this player.
        p.playbackRate = Float(playbackSpeed)
        p.view.frame = videoView.bounds
        p.view.autoresizingMask = [UIView.AutoresizingMask.flexibleWidth, UIView.AutoresizingMask.flexibleHeight]
        videoView.addSubview(p.view)
        self.ijkPlayer = p
        registerIJKNotifications(for: p)
        showLoadingUI()
        p.prepareToPlay()
        p.play()
        // Lock screen / Control Center + lyrics Live Activity.
        setupNowPlaying()
        fetchNowPlayingArtworkIfNeeded()
        startLyricsActivityIfNeeded()
    }

    private func teardownIJKPlayer() {
        NotificationCenter.default.removeObserver(self)
        if let p = ijkPlayer {
            p.view.removeFromSuperview()
            p.shutdown()
        }
        ijkPlayer = nil
        playFailed = false
        didEnd = false
        userPaused = false
    }

    // MARK: - Lock screen / Control Center (Now Playing)

    // Registers the remote commands this player actually supports and
    // publishes the first Now Playing info. Idempotent: live stream
    // switches recreate the ijkplayer (startIJKPlayback) without
    // tearing the commands down, so a second setup must not add the
    // same target twice (the handler would fire twice per press).
    private func setupNowPlaying() {
        guard !nowPlayingActive else { updateNowPlayingInfo(); return }
        nowPlayingActive = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget(self, action: #selector(remotePlay))
        center.pauseCommand.addTarget(self, action: #selector(remotePause))
        center.togglePlayPauseCommand.addTarget(self, action: #selector(remoteTogglePlayPause))
        if isVod {
            // VOD supports seeking (it has a seek bar); live does not.
            center.changePlaybackPositionCommand.addTarget(self, action: #selector(remoteSeek(_:)))
            center.skipForwardCommand.preferredIntervals = [NSNumber(value: 10)]
            center.skipForwardCommand.addTarget(self, action: #selector(remoteSkipForward(_:)))
            center.skipBackwardCommand.preferredIntervals = [NSNumber(value: 10)]
            center.skipBackwardCommand.addTarget(self, action: #selector(remoteSkipBackward(_:)))
        }
        // Next / previous are NOT wired: this player plays one stream
        // with no queue or episode list, so there is nothing for them
        // to do. The web page owns episode navigation.
        updateNowPlayingInfo()
    }

    private func teardownNowPlaying() {
        guard nowPlayingActive else { return }
        nowPlayingActive = false
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(self)
        center.pauseCommand.removeTarget(self)
        center.togglePlayPauseCommand.removeTarget(self)
        center.changePlaybackPositionCommand.removeTarget(self)
        center.skipForwardCommand.removeTarget(self)
        center.skipBackwardCommand.removeTarget(self)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // Title / artist / artwork / duration / elapsed / rate. Live has
    // no duration (an endless stream), so only VOD sets one.
    private func updateNowPlayingInfo() {
        guard nowPlayingActive, let p = ijkPlayer else { return }
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = streamTitle.isEmpty ? platformName : streamTitle
        info[MPMediaItemPropertyArtist] = platformName
        info[MPMediaItemPropertyAlbumTitle] = isVod ? "HAo Studio · 影视" : "HAo Studio · 直播"
        let t = p.currentPlaybackTime
        if isVod {
            let dur = p.duration
            if dur.isFinite, dur > 0 { info[MPMediaItemPropertyPlaybackDuration] = dur }
            if t.isFinite, t >= 0 { info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = t }
        }
        info[MPNowPlayingInfoPropertyPlaybackRate] = p.isPlaying() ? 1.0 : 0.0
        if let art = nowPlayingArtwork { info[MPMediaItemPropertyArtwork] = art }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        lastNowPlayingUpdate = Date()
    }

    // Poster / room cover -> lock screen artwork. One fetch per player
    // instance; a missing cover just means no artwork, never a failure.
    private func fetchNowPlayingArtworkIfNeeded() {
        guard let url = coverURL, nowPlayingArtwork == nil else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self = self, let data = data, let image = UIImage(data: data) else { return }
            let art = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            DispatchQueue.main.async {
                self.nowPlayingArtwork = art
                self.updateNowPlayingInfo()
            }
        }.resume()
    }

    @objc private func remotePlay(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        guard let p = ijkPlayer, !p.isPlaying() else { return .commandFailed }
        userPaused = false
        lastAdvanceDate = Date()
        p.play()
        playPauseButton.setImage(playPauseImage(named: "pause.fill"), for: .normal)
        if isVod { resumeDanmakuAnimations() }
        scheduleControlsHide()
        updateNowPlayingInfo()
        syncLyricsActivity()
        return .success
    }

    @objc private func remotePause(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        guard let p = ijkPlayer, p.isPlaying() else { return .commandFailed }
        userPaused = true
        p.pause()
        playPauseButton.setImage(playPauseImage(named: "play.fill"), for: .normal)
        if isVod { pauseDanmakuAnimations() }
        showControls()
        updateNowPlayingInfo()
        syncLyricsActivity()
        return .success
    }

    @objc private func remoteTogglePlayPause(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        guard let p = ijkPlayer else { return .commandFailed }
        if p.isPlaying() { return remotePause(event) }
        return remotePlay(event)
    }

    @objc private func remoteSeek(_ event: MPChangePlaybackPositionCommandEvent) -> MPRemoteCommandHandlerStatus {
        guard isVod, let p = ijkPlayer else { return .commandFailed }
        let target = event.positionTime
        let dur = p.duration
        guard target.isFinite, target >= 0, (!dur.isFinite || dur <= 0 || target <= dur) else { return .commandFailed }
        p.currentPlaybackTime = target
        lastDanmakuTime = target
        danmakuCursor = danmakuItems.firstIndex(where: { $0.time > target - 0.5 }) ?? danmakuItems.count
        lastPlaybackTime = target
        lastAdvanceDate = Date()
        updateNowPlayingInfo()
        syncLyricsActivity()
        return .success
    }

    @objc private func remoteSkipForward(_ event: MPSkipIntervalCommandEvent) -> MPRemoteCommandHandlerStatus {
        return remoteSkip(by: event.interval)
    }

    @objc private func remoteSkipBackward(_ event: MPSkipIntervalCommandEvent) -> MPRemoteCommandHandlerStatus {
        return remoteSkip(by: -event.interval)
    }

    private func remoteSkip(by seconds: TimeInterval) -> MPRemoteCommandHandlerStatus {
        guard isVod, let p = ijkPlayer else { return .commandFailed }
        let dur = p.duration
        var target = p.currentPlaybackTime + seconds
        if target < 0 { target = 0 }
        if dur.isFinite, dur > 0, target > dur { target = dur }
        p.currentPlaybackTime = target
        lastDanmakuTime = target
        danmakuCursor = danmakuItems.firstIndex(where: { $0.time > target - 0.5 }) ?? danmakuItems.count
        lastPlaybackTime = target
        lastAdvanceDate = Date()
        updateNowPlayingInfo()
        syncLyricsActivity()
        return .success
    }

    // MARK: - Synced-lyrics Live Activity (iOS 16.2+)

    // Starts the lyrics Live Activity when this stream carries LRC
    // lyrics. VOD movies normally have none (empty string), so this
    // is a no-op for them; the mechanism exists for whatever the web
    // page passes. The NPC drives the position from its own clock.
    private func startLyricsActivityIfNeeded() {
        guard !lyricsActivityStarted, !lyricsText.isEmpty else { return }
        let lines = parseLRC(lyricsText)
        guard !lines.isEmpty else { return }
        lyricsActivityStarted = true
        if #available(iOS 16.2, *) {
            LyricsLiveActivity.shared.start(owner: "npc", key: streamTitle, title: streamTitle.isEmpty ? platformName : streamTitle, artist: platformName, lines: lines, position: startPosition, externalDrive: true)
        }
    }

    // Push the current playback clock into the Live Activity. The
    // manager only updates the activity when the lyric line actually
    // changed, so calling this every tick is cheap.
    private func syncLyricsActivity() {
        guard lyricsActivityStarted, let p = ijkPlayer else { return }
        if #available(iOS 16.2, *) {
            LyricsLiveActivity.shared.sync(position: p.currentPlaybackTime, playing: p.isPlaying())
        }
    }

    private func endLyricsActivity() {
        guard lyricsActivityStarted else { return }
        lyricsActivityStarted = false
        if #available(iOS 16.2, *) {
            LyricsLiveActivity.shared.end(owner: "npc")
        }
    }

    private func registerIJKNotifications(for p: IJKFFMoviePlayerController) {
        // NOTE: ijkplayer's notification names are `NSString *const`
        // globals. In this toolchain (Xcode 26 / Swift 6) they import
        // as `NSNotification.Name` values that CANNOT be referenced
        // by name — neither as a bare identifier, nor as a
        // `NSNotification.Name.<Name>` member (builds #13/#14/#15
        // each proved one of those forms fails). So build the names
        // from their raw strings instead. Verified against the
        // framework binary: each constant's runtime string value
        // equals its name, so these match the posted notifications.
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(ijkLoadStateChanged), name: NSNotification.Name(rawValue: "IJKMPMoviePlayerLoadStateDidChangeNotification"), object: p)
        nc.addObserver(self, selector: #selector(ijkPlaybackStateChanged), name: NSNotification.Name(rawValue: "IJKMPMoviePlayerPlaybackStateDidChangeNotification"), object: p)
        nc.addObserver(self, selector: #selector(ijkPlaybackDidFinish), name: NSNotification.Name(rawValue: "IJKMPMoviePlayerPlaybackDidFinishNotification"), object: p)
        nc.addObserver(self, selector: #selector(ijkPreparedToPlayChanged), name: NSNotification.Name(rawValue: "IJKMPMediaPlaybackIsPreparedToPlayDidChangeNotification"), object: p)
        nc.addObserver(self, selector: #selector(ijkFirstFrameRendered), name: NSNotification.Name(rawValue: "IJKMPMoviePlayerFirstVideoFrameRenderedNotification"), object: p)
    }

    private func hideLoadingUI() {
        spinner.stopAnimating()
        statusLabel.isHidden = true
        updateStatusActions()
    }

    private func showLoadingUI() {
        spinner.startAnimating()
        statusLabel.text = "正在加载…"
        statusLabel.isHidden = false
        updateStatusActions()
    }

    private func seekToStartPositionIfNeeded() {
        guard isVod, !didSeekToStart, startPosition > 5, let p = ijkPlayer, p.isPreparedToPlay else { return }
        didSeekToStart = true
        p.currentPlaybackTime = startPosition
        lastDanmakuTime = startPosition
        danmakuCursor = danmakuItems.firstIndex(where: { $0.time > startPosition - 0.5 }) ?? danmakuItems.count
    }

    // MARK: - ijkplayer notifications

    @objc private func ijkLoadStateChanged(_ note: Notification) {
        // Loading UI is driven by actual time advance (see
        // tickPlayback), not by load state: ijkplayer reports
        // .stalled while re-fetching on slow overseas sources even
        // though the picture keeps playing from its buffer. Only
        // show the spinner here while playback has not started yet.
        guard let obj = note.object as? IJKFFMoviePlayerController else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let p = self.ijkPlayer, obj === p else { return }
            if !self.hasStartedPlaying, p.loadState.contains(.stalled) {
                self.showLoadingUI()
            }
        }
    }

    @objc private func ijkPlaybackStateChanged(_ note: Notification) {
        guard let obj = note.object as? IJKFFMoviePlayerController else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let p = self.ijkPlayer, obj === p else { return }
            switch p.playbackState {
            case .playing:
                self.switchingStream = false
                self.hasStartedPlaying = true
                self.hideLoadingUI()
                self.playPauseButton.setImage(self.playPauseImage(named: "pause.fill"), for: .normal)
                if self.isVod { self.resumeDanmakuAnimations() }
                self.scheduleControlsHide()
            case .paused:
                self.hideLoadingUI()
                self.playPauseButton.setImage(self.playPauseImage(named: "play.fill"), for: .normal)
                if self.isVod { self.pauseDanmakuAnimations() }
                self.showControls()
            case .interrupted:
                self.hideLoadingUI()
                self.playPauseButton.setImage(self.playPauseImage(named: "play.fill"), for: .normal)
            case .stopped, .seekingForward, .seekingBackward:
                break
            @unknown default:
                break
            }
        }
    }

    @objc private func ijkPlaybackDidFinish(_ note: Notification) {
        guard let obj = note.object as? IJKFFMoviePlayerController else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let p = self.ijkPlayer, obj === p else { return }
            if self.switchingStream { return }
            let reasonValue = (note.userInfo?[IJKMPMoviePlayerPlaybackDidFinishReasonUserInfoKey] as? NSNumber)?.intValue
            let reason = reasonValue.flatMap { IJKMPMovieFinishReason(rawValue: $0) }
            switch reason {
            case .playbackEnded:
                if self.isVod {
                    // VOD: genuine end of file — unchanged.
                    self.didEnd = true
                    self.spinner.stopAnimating()
                    self.statusLabel.text = "已播完"
                    self.statusLabel.isHidden = false
                    self.updateStatusActions()
                    self.playPauseButton.setImage(self.playPauseImage(named: "play.fill"), for: .normal)
                    self.pauseDanmakuAnimations()
                    break
                }
                // Live: a clean EOF is usually NOT the room going
                // offline. Huya's FLV anti-code expires after ~5 min
                // (wsTime+300s) and the CDN cuts the stream, which
                // ijkplayer reports as .playbackEnded — the old code
                // showed "直播已结束" and stopped, even though the
                // streamer was still live. Treat it like a failure
                // instead: show the loading state and ask the web page
                // for the next CDN line / a fresh URL (same path as
                // .playbackError; the web throttles fresh fetches to
                // once per 60s). NOTE: all lines share one anti-code,
                // so they all expire together — the line switch alone
                // cannot fix an expiry, only the fresh URL can. The
                // cap bounds consecutive EOFs with no playback in
                // between: once it trips, the room really is offline
                // and the genuine end state shows.
                if self.liveEndedRetries < 5 {
                    self.liveEndedRetries += 1
                    self.showLoadingUI()
                    self.onLiveFailed?()
                } else {
                    self.didEnd = true
                    self.spinner.stopAnimating()
                    self.statusLabel.text = "直播已结束"
                    self.statusLabel.isHidden = false
                    self.updateStatusActions()
                    self.playPauseButton.setImage(self.playPauseImage(named: "play.fill"), for: .normal)
                }
            case .playbackError:
                // Live streams often drop once on a flaky network; retry
                // automatically once instead of leaving "playback failed"
                // on screen. VOD failures are usually a dead source, so
                // they still show the manual retry immediately.
                if !self.isVod, !self.liveAutoRetried {
                    self.retryCurrentStream()
                    // startIJKPlayback() (called inside retry) resets
                    // liveAutoRetried, so re-arm it AFTER the retry:
                    // the retried stream gets no further same-URL
                    // auto-retry — its failure goes to onLiveFailed
                    // (fresh URL) instead of looping forever.
                    self.liveAutoRetried = true
                    break
                }
                self.playFailed = true
                self.spinner.stopAnimating()
                self.statusLabel.text = "播放失败，请检查网络后点 ▶ 重试"
                self.statusLabel.isHidden = false
                self.updateStatusActions()
                self.playPauseButton.setImage(self.playPauseImage(named: "play.fill"), for: .normal)
                // Final live failure: ask the web page for a fresh URL
                // instead of leaving the user on a dead stream. The
                // web side throttles this to once per 60s.
                if !self.isVod { self.onLiveFailed?() }
            case .userExited, .none:
                break
            @unknown default:
                break
            }
        }
    }

    @objc private func ijkPreparedToPlayChanged(_ note: Notification) {
        guard let obj = note.object as? IJKFFMoviePlayerController else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let p = self.ijkPlayer, obj === p, p.isPreparedToPlay else { return }
            self.seekToStartPositionIfNeeded()
            if !p.isPlaying() { p.play() }
        }
    }

    @objc private func ijkFirstFrameRendered(_ note: Notification) {
        guard let obj = note.object as? IJKFFMoviePlayerController else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.ijkPlayer === obj else { return }
            self.hasStartedPlaying = true
            self.hideLoadingUI()
        }
    }

    // Polls the player clock 4x/second. This is the only place the
    // loading spinner is hidden once playback has started: time
    // actually advancing proves the picture is playing, even if
    // ijkplayer still reports .stalled while re-fetching on a slow
    // overseas source. A genuine stall (no advance for > 2s) brings
    // the spinner back. Also drives the VOD seek bar, time labels
    // and danmaku spawning.
    private func startPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.tickPlayback()
        }
    }

    private func tickPlayback() {
        guard let p = ijkPlayer else { return }
        let t = p.currentPlaybackTime
        let now = Date()
        if t.isFinite, t > lastPlaybackTime + 0.05 {
            lastPlaybackTime = t
            lastAdvanceDate = now
            // Clock moving again: a later stall is a new episode and
            // may switch lines again (see below). A later clean EOF
            // is a new episode too — the reconnect cap resets.
            stallLineSwitched = false
            liveEndedRetries = 0
            if !hasStartedPlaying {
                hasStartedPlaying = true
                seekToStartPositionIfNeeded()
            }
            hideLoadingUI()
        } else if hasStartedPlaying, !userPaused, !didEnd, !playFailed,
                  now.timeIntervalSince(lastAdvanceDate) > 2.0 {
            // Genuine stall: picture frozen, nothing arriving.
            showLoadingUI()
            // Pure Live judges a live source by its position moving,
            // not by the engine's flags (its stallNotice is 4 s, first
            // recovery attempt; bufferingStall 12 s is a failure). The
            // old code only showed the spinner here — a laggy line that
            // never errors would spin forever and the user saw 卡顿.
            // At 4 s of no advance, ask the web page for the next CDN
            // line (same path as a playback error: __nativeLiveFailed
            // tries the next line, then a fresh URL). Once per stall
            // episode; guarded by stallLineSwitched so it cannot loop
            // while the same line stays frozen.
            if !isVod, !stallLineSwitched,
               now.timeIntervalSince(lastAdvanceDate) > 4.0 {
                stallLineSwitched = true
                onLiveFailed?()
            }
        }
        // Slow open: still no first frame after 4s -- say so instead
        // of spinning on "正在加载…" forever (Pure Live's 加载较慢).
        if !hasStartedPlaying, !playFailed,
           now.timeIntervalSince(playbackStartedAt) > 4.0 {
            statusLabel.text = "加载较慢…"
        }
        // Live reconnect safety net: a clean EOF already asked the web
        // for a fresh URL (liveEndedRetries > 0), but no new stream
        // ever started playing — e.g. the web was inside its 60s
        // fresh-fetch throttle, or every line was dead. The clock has
        // been frozen for 45s with no playback, so the room is almost
        // certainly offline; show the genuine end state instead of
        // spinning forever. 45s (not 30s): a fresh fetch may take up
        // to 30s, plus stream startup — a good URL still lands in
        // time and updateStream heals this via teardown (didEnd
        // resets). VOD never reaches here (liveEndedRetries is 0).
        if !isVod, liveEndedRetries > 0, !didEnd, !playFailed, !userPaused,
           now.timeIntervalSince(lastAdvanceDate) > 45.0 {
            didEnd = true
            spinner.stopAnimating()
            statusLabel.text = "直播已结束"
            statusLabel.isHidden = false
            updateStatusActions()
            playPauseButton.setImage(playPauseImage(named: "play.fill"), for: .normal)
        }
        // Never-started safety net: a URL that never opens (e.g. 403)
        // would spin forever if the finish notification never fires.
        // 30s (not 15s): slow overseas HLS can take >15s for the first
        // segment, and killing it early reads as "can't play".
        if !hasStartedPlaying, !playFailed,
           now.timeIntervalSince(playbackStartedAt) > 30.0 {
            playFailed = true
            spinner.stopAnimating()
            statusLabel.text = "播放失败，请检查网络后点 ▶ 重试"
            statusLabel.isHidden = false
            updateStatusActions()
            playPauseButton.setImage(playPauseImage(named: "play.fill"), for: .normal)
            // Same final-failure path as the finish notification:
            // ask the web page for a FRESH live URL instead of
            // leaving the user on a dead stream. Guarded by
            // playFailed above, so it fires once.
            if !isVod { onLiveFailed?() }
        }
        if isVod {
            updateVODProgress(time: t)
            spawnDanmakuIfDue()
        }
        // Lock screen progress + lyrics line, throttled to 1s: the
        // activity manager only pushes when the line changed.
        if Date().timeIntervalSince(lastNowPlayingUpdate) >= 1.0 {
            updateNowPlayingInfo()
        }
        syncLyricsActivity()
    }

    private func updateVODProgress(time t: Double) {
        guard let p = ijkPlayer else { return }
        let dur = p.duration
        curTimeLabel?.text = formatTime(max(0, t))
        if dur.isFinite, dur > 0 {
            durTimeLabel?.text = formatTime(dur)
            if !isScrubbing {
                seekSlider?.value = Float(max(0, min(1, t / dur)))
            }
        }
    }

    // Switch the live stream in place (quality change, or the web page
    // posted a new room URL while this player is already presented).
    // Safe to call while playing; does not dismiss or re-present.
    // If the new stream needs the other engine (HLS <-> FLV), the
    // current engine is torn down and the right one started in place,
    // so the UI never flashes back to the web page.
    // Room / quality switch reusing this player in place. The title /
    // platform / roomId parameters are optional: a quality switch
    // (same room) omits them and the identity stays; a room switch
    // (web liveSwipeNext -> new postMessage) passes the new room's
    // identity so the title, the per-room volume key and the follow
    // button all follow the new room. The new room's remembered
    // volume is applied once the new stream starts.
    func updateStream(url: URL, qualities: [LiveQuality], format: String = "", title: String? = nil, platform: String? = nil, roomId: String? = nil) {
        guard !isVod else { return }
        // Clear the old room's danmaku so it doesn't float over the new room.
        danmakuView.subviews.forEach { $0.removeFromSuperview() }
        laneBusyUntil.removeAll()
        // `format` is accepted for compatibility with the web
        // postMessage contract; ijkplayer plays both HLS and FLV,
        // so there is no engine to switch — the player is simply
        // recreated with the new URL in the same view and UI.
        streamURL = url
        if let t = title { streamTitle = t; titleLabel?.text = t.isEmpty ? platformName + "直播" : t }
        if let p = platform { self.platform = p }
        if let r = roomId { self.roomId = r }
        liveQualities = qualities
        currentQualityId = qualities.first(where: { $0.url == url })?.id
        updateQualityButton()
        // New stream: it has not started playing yet, so the loading
        // spinner may show again until its time starts advancing.
        hasStartedPlaying = false
        switchingStream = true
        showLoadingUI()
        playPauseButton.setImage(playPauseImage(named: "pause.fill"), for: .normal)
        teardownIJKPlayer()
        startIJKPlayback()
        switchingStream = false
        // New room (or same room, same key): apply its remembered volume.
        applyRememberedLiveVolume()
    }

    private func updateQualityButton() {
        guard !isVod, let b = qualityButton else { return }
        var name = "画质"
        if let id = currentQualityId,
           let q = liveQualities.first(where: { $0.id == id }),
           !q.name.isEmpty {
            name = q.name
        }
        b.setTitle(name + " ⌄", for: .normal)
        // Small menu opening above the button (Pure Live stream_menu):
        // current quality checked, tap switches the stream in place.
        var actions: [UIAction] = []
        for q in liveQualities {
            let title = q.name.isEmpty ? q.id : q.name
            let isCurrent = q.id == currentQualityId
            actions.append(UIAction(title: title, state: isCurrent ? .on : .off) { [weak self] _ in
                guard let self = self else { return }
                self.updateStream(url: q.url, qualities: self.liveQualities)
                self.scheduleControlsHide()
            })
        }
        b.menu = UIMenu(title: "", children: actions)
        b.showsMenuAsPrimaryAction = true
        updateBottomBarItems()
    }

    private func stopPlayback() {
        guard !didStop else { return }
        didStop = true
        // Next open starts clean (portrait unless it is VOD).
        visualLandscape = false
        contentView?.transform = .identity
        playbackTimer?.invalidate()
        playbackTimer = nil
        controlsHideTimer?.invalidate()
        controlsHideTimer = nil
        liveDanmakuTimer?.invalidate()
        liveDanmakuTimer = nil
        teardownNowPlaying()
        endLyricsActivity()
        teardownIJKPlayer()
    }

    private func reportClose() {
        guard !didReportClose else { return }
        didReportClose = true
        let pos = ijkPlayer?.currentPlaybackTime ?? 0
        onClose?(pos)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds > 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    @objc private func closeTapped() {
        reportClose()
        stopPlayback()
        dismiss(animated: true, completion: nil)
    }

    @objc private func toggleControls(_ gesture: UITapGestureRecognizer) {
        // Ignore the finger-lift tap right after a long-press 2x ends,
        // or the controls would toggle every time the user releases 2x.
        if Date() < suppressTapUntil { return }
        if isLocked {
            // Locked: a tap only shows / hides the unlock button.
            lockButtonHiddenByTap.toggle()
            updateLockButtonVisibility()
            return
        }
        // Tap a flying danmaku to pin it in place; tap again to
        // release it (Pure Live). A tap anywhere else toggles the bars.
        let point = gesture.location(in: danmakuView)
        if let label = danmakuView.subviews.compactMap({ $0 as? UILabel }).first(where: { $0.frame.contains(point) }) {
            toggleDanmakuPin(label)
            return
        }
        controlsVisible = !controlsVisible
        if controlsVisible {
            topBar.isHidden = false
            bottomBar.isHidden = false
            UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState], animations: {
                self.topBar.alpha = 1
                self.bottomBar.alpha = 1
            })
            scheduleControlsHide()
        } else {
            controlsHideTimer?.invalidate()
            controlsHideTimer = nil
            UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState], animations: {
                self.topBar.alpha = 0
                self.bottomBar.alpha = 0
            }, completion: { _ in
                self.topBar.isHidden = true
                self.bottomBar.isHidden = true
            })
        }
    }

    // Pure Live: bars fade out on their own after 4s idle. Any tap on
    // a control resets the timer (button handlers call this).
    private func scheduleControlsHide() {
        controlsHideTimer?.invalidate()
        controlsHideTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { [weak self] _ in
            self?.hideControls()
        }
    }

    // Show the bars now (used when playback pauses -- Pure Live keeps
    // the controls visible while paused).
    private func showControls() {
        guard !isLocked else { return }
        controlsHideTimer?.invalidate()
        controlsHideTimer = nil
        guard !controlsVisible else { return }
        controlsVisible = true
        topBar.isHidden = false
        bottomBar.isHidden = false
        UIView.animate(withDuration: 0.2, animations: {
            self.topBar.alpha = 1
            self.bottomBar.alpha = 1
        })
    }

    private func hideControls() {
        guard controlsVisible, !isLocked else { return }
        // Pause keeps the bars visible: never auto-hide while the
        // picture is up but not playing (the user paused it).
        if let p = ijkPlayer, !p.isPlaying(), hasStartedPlaying { return }
        controlsVisible = false
        UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState], animations: {
            self.topBar.alpha = 0
            self.bottomBar.alpha = 0
        }, completion: { _ in
            self.topBar.isHidden = true
            self.bottomBar.isHidden = true
        })
    }

    // MARK: - Live danmaku (via the web page's JS bridge)

    private func startLiveDanmakuPull() {
        guard !isVod else { return }
        liveDanmakuTimer?.invalidate()
        liveDanmakuTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.pullLiveDanmaku()
        }
    }

    private func pullLiveDanmaku() {
        guard !isVod, danmakuEnabled, let pull = liveDanmakuPull else { return }
        pull { [weak self] texts in
            guard let self = self else { return }
            for t in texts where !t.isEmpty {
                self.spawnDanmaku(text: t)
            }
        }
    }

    // MARK: - Fullscreen (Pure Live: expand = straight to landscape)

    // The expand button toggles visual landscape (and back to
    // portrait). Visual rotation only — the system orientation is
    // never touched, so it works with orientation lock on.
    @objc private func fullscreenTapped() {
        scheduleControlsHide()
        setVisualLandscape(!visualLandscape)
    }

    private func updateFullscreenButton() {
        // Icon follows the effective landscape state: the visual
        // rotation, or a real system rotation if the lock is off.
        let isLandscape = visualLandscape || view.bounds.width > view.bounds.height
        let name = isLandscape ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
        fullscreenButton?.setImage(UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 26, weight: .semibold)), for: .normal)
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            self?.updateFullscreenButton()
        }
    }

    private func playPauseImage(named: String) -> UIImage? {
        UIImage(systemName: named, withConfiguration: UIImage.SymbolConfiguration(pointSize: 28, weight: .semibold))
    }

    @objc private func playPauseTapped() {
        guard let p = ijkPlayer else { return }
        if didEnd {
            if isVod {
                // Replay from the start.
                didEnd = false
                p.currentPlaybackTime = 0
                lastPlaybackTime = 0
                lastAdvanceDate = Date()
                // Restart danmaku from the top too, or the replay shows none.
                danmakuCursor = 0
                lastDanmakuTime = 0
                showLoadingUI()
                p.play()
                playPauseButton.setImage(playPauseImage(named: "pause.fill"), for: .normal)
            } else {
                // Live ended (room went offline): retry the same URL.
                retryCurrentStream()
            }
            return
        }
        if playFailed {
            retryCurrentStream()
            return
        }
        if p.isPlaying() {
            userPaused = true
            p.pause()
            playPauseButton.setImage(playPauseImage(named: "play.fill"), for: .normal)
            if isVod { pauseDanmakuAnimations() }
            showControls()
        } else {
            userPaused = false
            lastAdvanceDate = Date()
            p.play()
            playPauseButton.setImage(playPauseImage(named: "pause.fill"), for: .normal)
            if isVod { resumeDanmakuAnimations() }
            scheduleControlsHide()
        }
    }

    // Retry a failed stream by recreating the player with the same
    // URL (ijkplayer has no "re-attach media" on a live player).
    private func retryCurrentStream() {
        playFailed = false
        didEnd = false
        hasStartedPlaying = false
        showLoadingUI()
        teardownIJKPlayer()
        startIJKPlayback()
    }

    @objc private func seekTouchDown() {
        isScrubbing = true
    }

    @objc private func seekTouchUp() {
        guard let slider = seekSlider else { isScrubbing = false; return }
        isScrubbing = false
        guard let p = ijkPlayer else { return }
        let duration = p.duration
        guard duration.isFinite, duration > 0 else { return }
        seekToPosition(Double(slider.value) * duration)
    }

    // Seek + resync the VOD danmaku cursor (shared by the seek bar
    // and the horizontal-swipe gesture).
    private func seekToPosition(_ target: Double) {
        guard let p = ijkPlayer else { return }
        let duration = p.duration
        guard duration.isFinite, duration > 0 else { return }
        let t = max(0, min(duration, target))
        p.currentPlaybackTime = t
        lastDanmakuTime = t
        danmakuCursor = danmakuItems.firstIndex(where: { $0.time > t - 0.5 }) ?? danmakuItems.count
        lastPlaybackTime = t
        lastAdvanceDate = Date()
    }

    @objc private func danmakuToggleTapped() {
        scheduleControlsHide()
        danmakuEnabled = !danmakuEnabled
        syncDanmakuToggleButton()
        danmakuView.isHidden = !danmakuEnabled
        if !danmakuEnabled {
            danmakuView.subviews.forEach { $0.removeFromSuperview() }
        }
    }

    // Danmaku toggle look: bare icon + text, yellow #FFD166 when on
    // (Pure Live active), white 38% when off.
    private func syncDanmakuToggleButton() {
        guard let b = danmakuButton, var cfg = b.configuration else { return }
        cfg.baseForegroundColor = danmakuEnabled ? UIColor(red: 1, green: 0.82, blue: 0.4, alpha: 1) : UIColor(white: 1, alpha: 0.38)
        b.configuration = cfg
    }

    // MARK: - Danmaku settings panel (position / opacity / speed)

    @objc private func danmakuSettingsTapped() {
        scheduleControlsHide()
        if let panel = danmakuSettingsView {
            panel.isHidden = !panel.isHidden
            if !panel.isHidden { syncDanmakuSettingsPanel() }
            return
        }
        let panel = buildDanmakuSettingsView()
        contentView.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            panel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            panel.bottomAnchor.constraint(equalTo: bottomBar.topAnchor, constant: -12)
        ])
        danmakuSettingsView = panel
        syncDanmakuSettingsPanel()
    }

    private func buildDanmakuSettingsView() -> UIView {
        let panel = UIView()
        panel.backgroundColor = UIColor(white: 0, alpha: 0.87)
        panel.layer.cornerRadius = 16
        panel.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -14)
        ])

        let titleRow = UIStackView()
        titleRow.axis = .horizontal
        titleRow.distribution = .equalSpacing
        let title = UILabel()
        title.text = "弹幕设置"
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .white
        titleRow.addArrangedSubview(title)
        let done = UIButton(type: .system)
        done.setTitle("完成", for: .normal)
        done.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        done.setTitleColor(UIColor(red: 1, green: 0.82, blue: 0.4, alpha: 1), for: .normal)
        done.addTarget(self, action: #selector(danmakuSettingsDone), for: .touchUpInside)
        titleRow.addArrangedSubview(done)
        stack.addArrangedSubview(titleRow)

        let posLabel = UILabel()
        posLabel.text = "位置"
        posLabel.font = .systemFont(ofSize: 13)
        posLabel.textColor = UIColor(white: 1, alpha: 0.7)
        stack.addArrangedSubview(posLabel)
        let seg = UISegmentedControl(items: ["全部", "顶部", "中部", "底部"])
        seg.selectedSegmentTintColor = UIColor(red: 1, green: 0.82, blue: 0.4, alpha: 1)
        seg.setTitleTextAttributes([.foregroundColor: UIColor(red: 0.098, green: 0.11, blue: 0.125, alpha: 1)], for: .selected)
        seg.setTitleTextAttributes([.foregroundColor: UIColor(white: 1, alpha: 0.75)], for: .normal)
        seg.addTarget(self, action: #selector(danmakuPosChanged(_:)), for: .valueChanged)
        stack.addArrangedSubview(seg)
        danmakuPosSegment = seg

        let opRow = UIStackView()
        opRow.axis = .horizontal
        opRow.spacing = 8
        let opLabel = UILabel()
        opLabel.text = "不透明度"
        opLabel.font = .systemFont(ofSize: 13)
        opLabel.textColor = UIColor(white: 1, alpha: 0.7)
        opLabel.setContentHuggingPriority(.required, for: .horizontal)
        opRow.addArrangedSubview(opLabel)
        let opSlider = UISlider()
        opSlider.minimumValue = 0.3
        opSlider.maximumValue = 1.0
        opSlider.tintColor = UIColor(red: 1, green: 0.82, blue: 0.4, alpha: 1)
        opSlider.addTarget(self, action: #selector(danmakuOpacityChanged(_:)), for: .valueChanged)
        opRow.addArrangedSubview(opSlider)
        let opVal = UILabel()
        opVal.font = .systemFont(ofSize: 13)
        opVal.textColor = .white
        opVal.textAlignment = .right
        opVal.widthAnchor.constraint(equalToConstant: 32).isActive = true
        opRow.addArrangedSubview(opVal)
        stack.addArrangedSubview(opRow)
        danmakuOpacitySlider = opSlider
        danmakuOpacityValueLabel = opVal

        let spRow = UIStackView()
        spRow.axis = .horizontal
        spRow.spacing = 8
        let spLabel = UILabel()
        spLabel.text = "速度"
        spLabel.font = .systemFont(ofSize: 13)
        spLabel.textColor = UIColor(white: 1, alpha: 0.7)
        spLabel.setContentHuggingPriority(.required, for: .horizontal)
        spRow.addArrangedSubview(spLabel)
        let spSlider = UISlider()
        spSlider.minimumValue = 0.5
        spSlider.maximumValue = 2.0
        spSlider.tintColor = UIColor(red: 1, green: 0.82, blue: 0.4, alpha: 1)
        spSlider.addTarget(self, action: #selector(danmakuSpeedChanged(_:)), for: .valueChanged)
        spRow.addArrangedSubview(spSlider)
        let spVal = UILabel()
        spVal.font = .systemFont(ofSize: 13)
        spVal.textColor = .white
        spVal.textAlignment = .right
        spVal.widthAnchor.constraint(equalToConstant: 32).isActive = true
        spRow.addArrangedSubview(spVal)
        stack.addArrangedSubview(spRow)
        danmakuSpeedSlider = spSlider
        danmakuSpeedValueLabel = spVal

        // Playback speed (VOD only): 0.5–3x. Hidden for live rooms —
        // a live stream cannot be sped up. Changing it applies to
        // ijkplayer immediately and syncs back to the web page.
        if isVod {
            let rateLabel = UILabel()
            rateLabel.text = "倍速"
            rateLabel.font = .systemFont(ofSize: 13)
            rateLabel.textColor = UIColor(white: 1, alpha: 0.7)
            stack.addArrangedSubview(rateLabel)
            let rateSeg = UISegmentedControl(items: ["0.5x", "0.75x", "1x", "1.25x", "1.5x", "2x", "3x"])
            rateSeg.selectedSegmentTintColor = UIColor(red: 1, green: 0.82, blue: 0.4, alpha: 1)
            rateSeg.setTitleTextAttributes([.foregroundColor: UIColor(red: 0.098, green: 0.11, blue: 0.125, alpha: 1)], for: .selected)
            rateSeg.setTitleTextAttributes([.foregroundColor: UIColor(white: 1, alpha: 0.75)], for: .normal)
            rateSeg.addTarget(self, action: #selector(playbackSpeedChanged(_:)), for: .valueChanged)
            stack.addArrangedSubview(rateSeg)
            playbackSpeedSegment = rateSeg
        }

        return panel
    }

    private func syncDanmakuSettingsPanel() {
        guard let cfg = danmakuConfig else { return }
        let idx: Int
        switch cfg.position {
        case "top": idx = 1
        case "middle": idx = 2
        case "bottom": idx = 3
        default: idx = 0
        }
        danmakuPosSegment?.selectedSegmentIndex = idx
        danmakuOpacitySlider?.value = Float(max(0.3, min(1.0, cfg.opacity)))
        danmakuOpacityValueLabel?.text = String(format: "%.1f", max(0.3, min(1.0, cfg.opacity)))
        danmakuSpeedSlider?.value = Float(max(0.5, min(2.0, cfg.speed)))
        danmakuSpeedValueLabel?.text = String(format: "%.2f", max(0.5, min(2.0, cfg.speed))).replacingOccurrences(of: ".00", with: "")
        playbackSpeedSegment?.selectedSegmentIndex = Self.playbackSpeeds.firstIndex(of: playbackSpeed) ?? 2
    }

    @objc private func danmakuSettingsDone() {
        danmakuSettingsView?.isHidden = true
        scheduleControlsHide()
    }

    @objc private func danmakuPosChanged(_ sender: UISegmentedControl) {
        let pos: String
        switch sender.selectedSegmentIndex {
        case 1: pos = "top"
        case 2: pos = "middle"
        case 3: pos = "bottom"
        default: pos = "full"
        }
        danmakuConfig?.position = pos
        notifyDanmakuSettingsChanged()
    }

    @objc private func danmakuOpacityChanged(_ sender: UISlider) {
        let v = Double(sender.value)
        danmakuConfig?.opacity = v
        danmakuOpacityValueLabel?.text = String(format: "%.1f", v)
        notifyDanmakuSettingsChanged()
    }

    @objc private func danmakuSpeedChanged(_ sender: UISlider) {
        let v = Double(sender.value)
        danmakuConfig?.speed = v
        danmakuSpeedValueLabel?.text = String(format: "%.2f", v).replacingOccurrences(of: ".00", with: "")
        notifyDanmakuSettingsChanged()
    }

    private func notifyDanmakuSettingsChanged() {
        guard let cfg = danmakuConfig else { return }
        onDanmakuSettingsChanged?(cfg.position, cfg.opacity, cfg.speed)
    }

    // MARK: - Playback speed (VOD)
    // The supported speeds, shared with the web page's VOD_SPEEDS.
    private static let playbackSpeeds: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2, 3]
    private func setPlaybackSpeed(_ rate: Double, notify: Bool = true) {
        guard Self.playbackSpeeds.contains(rate) else { return }
        playbackSpeed = rate
        ijkPlayer?.playbackRate = Float(rate)
        playbackSpeedSegment?.selectedSegmentIndex = Self.playbackSpeeds.firstIndex(of: rate) ?? 2
        if notify { onSpeedChanged?(rate) }
    }
    @objc private func playbackSpeedChanged(_ sender: UISegmentedControl) {
        let rate = Self.playbackSpeeds[sender.selectedSegmentIndex]
        setPlaybackSpeed(rate)
    }
    // Long-press 2x: hold the video ~0.5s to play at 2x, release to go
    // back to the speed chosen before the press. The "2x" label shows
    // top-right while held. The finger-lift tap is suppressed so the
    // controls do not toggle when the press ends.
    @objc private func longPressSpeed(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            guard !longPressSpeedActive else { return }
            longPressSpeedActive = true
            speedBeforeLongPress = playbackSpeed
            ijkPlayer?.playbackRate = 2
            speed2xLabel?.isHidden = false
        case .ended, .cancelled, .failed:
            guard longPressSpeedActive else { return }
            longPressSpeedActive = false
            ijkPlayer?.playbackRate = Float(speedBeforeLongPress)
            speed2xLabel?.isHidden = true
            suppressTapUntil = Date().addingTimeInterval(0.35)
        default:
            break
        }
    }

    // Apply the web page's danmaku settings to this player while it is
    // already open (a live room / quality switch reuses the player via
    // updateStream instead of presenting a new one). The web page's
    // dmPos is the single source of truth; a position change made on
    // the web page must reach the player that is currently playing,
    // not just the next one. Newly spawned danmaku reads cfg.position
    // live, so the change shows on screen immediately. `enabled` is
    // deliberately left alone here: the player's own on/off toggle
    // owns it while playing (it does not write back to the web page).
    func applyDanmakuSettings(_ d: DanmakuConfig) {
        if danmakuConfig == nil {
            danmakuConfig = d
        } else {
            danmakuConfig?.position = d.position
            danmakuConfig?.opacity = d.opacity
            danmakuConfig?.speed = d.speed
        }
        if danmakuSettingsView?.isHidden == false { syncDanmakuSettingsPanel() }
    }

    // MARK: - Danmaku (VOD only)

    // Standalone VOD danmaku feed: the web page fetches the episode's
    // danmaku itself (Bilibili direct via nativeFetch) and pushes
    // time-synced items in here; the player spawns them from the
    // playback clock exactly as before (spawnDanmakuIfDue). Called by
    // ViewController when the web page posts new items. Replaces the
    // deleted server fetch (fetchDanmaku) —
    // this player makes no danmaku network request of its own.
    // `items` are (seconds, text) pairs; unsorted input is sorted.
    func feedVodDanmaku(_ items: [(Double, String)]) {
        guard isVod else { return }
        let mapped = items.compactMap { (t, text) -> DanmakuItem? in
            guard !text.isEmpty else { return nil }
            return DanmakuItem(id: UUID().uuidString, time: t, text: text)
        }.sorted { $0.time < $1.time }
        danmakuItems = mapped
        danmakuCursor = mapped.firstIndex(where: { $0.time > lastDanmakuTime - 0.5 }) ?? mapped.count
    }

    private func spawnDanmakuIfDue() {
        guard isVod, danmakuEnabled, !danmakuItems.isEmpty,
              let p = ijkPlayer, p.isPlaying() else { return }
        let now = p.currentPlaybackTime
        if now < lastDanmakuTime - 1.0 {
            // Seeked backwards: rewind the cursor.
            danmakuCursor = danmakuItems.firstIndex(where: { $0.time > now - 0.5 }) ?? danmakuItems.count
        }
        lastDanmakuTime = now
        while danmakuCursor < danmakuItems.count && danmakuItems[danmakuCursor].time <= now {
            let item = danmakuItems[danmakuCursor]
            danmakuCursor += 1
            if item.time > now - 1.0 {
                spawnDanmaku(text: item.text)
            }
        }
    }

    private func spawnDanmaku(text: String) {
        let viewWidth = danmakuView.bounds.width
        let viewHeight = danmakuView.bounds.height
        guard viewWidth > 0, viewHeight > 0, let cfg = danmakuConfig else { return }
        let laneHeight: CGFloat = 30
        let laneCount = max(1, Int(viewHeight / laneHeight))
        let zone: Range<Int>
        switch cfg.position {
        case "top":
            zone = 0..<max(1, laneCount / 3)
        case "middle":
            zone = (laneCount / 3)..<max(laneCount / 3 + 1, 2 * laneCount / 3)
        case "bottom":
            zone = (2 * laneCount / 3)..<laneCount
        default:
            zone = 0..<laneCount
        }
        let now = Date()
        let freeLanes = zone.filter { (laneBusyUntil[$0] ?? .distantPast) < now }
        // Cap the visible danmaku at 48 (Pure Live maxVisible): a busy
        // room would otherwise stack labels until the picture is gone.
        guard danmakuView.subviews.count < 48 else { return }
        guard let lane = freeLanes.randomElement() else { return }

        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = CGSize(width: 0, height: 1)
        let label = UILabel()
        label.attributedText = NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: 16, weight: .medium),
            .foregroundColor: UIColor.white,
            .shadow: shadow,
            .strokeColor: UIColor.black,
            .strokeWidth: -1.5
        ])
        label.alpha = CGFloat(max(0.3, min(1.0, cfg.opacity)))
        label.sizeToFit()
        let labelWidth = label.bounds.width
        label.frame = CGRect(x: viewWidth, y: CGFloat(lane) * laneHeight + 2, width: labelWidth, height: 26)
        danmakuView.addSubview(label)

        // Same pacing as the web player: ~120 points/sec, min 2.5s.
        let duration = max(2.5, Double(viewWidth + labelWidth) / (120.0 * max(0.5, cfg.speed)))
        laneBusyUntil[lane] = now.addingTimeInterval(duration * 0.75)
        UIView.animate(withDuration: duration, delay: 0, options: [.curveLinear], animations: {
            label.frame.origin.x = -labelWidth
        }, completion: { _ in
            label.removeFromSuperview()
        })
    }

    private func pauseDanmakuAnimations() {
        let layer = danmakuView.layer
        guard layer.speed != 0 else { return }
        let pausedTime = layer.convertTime(CACurrentMediaTime(), from: nil)
        layer.speed = 0
        layer.timeOffset = pausedTime
    }

    private func resumeDanmakuAnimations() {
        let layer = danmakuView.layer
        guard layer.speed == 0 else { return }
        let pausedTime = layer.timeOffset
        layer.speed = 1
        layer.timeOffset = 0
        layer.beginTime = 0
        let timeSincePause = layer.convertTime(CACurrentMediaTime(), from: nil) - pausedTime
        layer.beginTime = timeSincePause
    }

    // MARK: - Pure Live player copy (Phase A helpers)

    // Bare white icon button on the video (Pure Live VideoIconButton):
    // 48x48 touch target, white icon with a soft shadow, no filled
    // background. Icon sizes: play/pause 28, fullscreen 26, others 22.
    private func makeVideoIconButton(systemName: String, pointSize: CGFloat, action: Selector) -> UIButton {
        let b = UIButton(type: .system)
        b.setImage(UIImage(systemName: systemName, withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)), for: .normal)
        b.tintColor = .white
        b.addTarget(self, action: action, for: .touchUpInside)
        b.translatesAutoresizingMaskIntoConstraints = false
        videoShadow(b)
        NSLayoutConstraint.activate([
            b.widthAnchor.constraint(equalToConstant: 48),
            b.heightAnchor.constraint(equalToConstant: 48)
        ])
        return b
    }

    // Plain white text button on the video (Pure Live stream_menu):
    // "原画 ⌄" / "线路" -- white 13 semibold, no pill background.
    private func makeVideoTextButton(title: String, action: Selector?) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        b.tintColor = .white
        if let action = action {
            b.addTarget(self, action: action, for: .touchUpInside)
        }
        b.translatesAutoresizingMaskIntoConstraints = false
        videoShadow(b)
        b.heightAnchor.constraint(equalToConstant: 48).isActive = true
        return b
    }

    // Soft shadow under icons and text on the video (Pure Live
    // OnVideoColors.shadows: 60% black, blur 6).
    private func videoShadow(_ view: UIView) {
        view.layer.shadowColor = UIColor(white: 0, alpha: 0.6).cgColor
        view.layer.shadowRadius = 6
        view.layer.shadowOpacity = 1
        view.layer.shadowOffset = .zero
        view.layer.masksToBounds = false
    }

    // Status-layer action button (Pure Live player_status): primary =
    // white fill + dark ink; secondary = 35% black fill + 45% white
    // outline.
    private func makeStatusButton(title: String, primary: Bool, action: Selector) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        if primary {
            b.backgroundColor = .white
            b.setTitleColor(UIColor(red: 0.098, green: 0.11, blue: 0.125, alpha: 1), for: .normal)
        } else {
            b.backgroundColor = UIColor(white: 0, alpha: 0.35)
            b.layer.borderWidth = 1
            b.layer.borderColor = UIColor(white: 1, alpha: 0.45).cgColor
            b.setTitleColor(.white, for: .normal)
        }
        b.layer.cornerRadius = 10
        b.contentEdgeInsets = UIEdgeInsets(top: 0, left: 18, bottom: 0, right: 18)
        b.heightAnchor.constraint(equalToConstant: 44).isActive = true
        b.addTarget(self, action: action, for: .touchUpInside)
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }

    // Show / hide the status layer's action buttons from the current
    // playFailed / didEnd state. Live failure: retry + switch line +
    // switch room. Live end: retry + switch room. VOD failure: retry.
    // VOD end: no buttons (the play button replays).
    private func updateStatusActions() {
        let failed = playFailed
        let ended = didEnd
        statusDimView?.isHidden = !(failed || ended)
        guard let stack = statusActionsStack else { return }
        if failed {
            statusRetryButton?.isHidden = false
            statusLineButton?.isHidden = isVod
            statusRoomButton?.isHidden = isVod || onRequestRoomSwitch == nil
            stack.isHidden = false
        } else if ended {
            statusRetryButton?.isHidden = false
            statusLineButton?.isHidden = true
            statusRoomButton?.isHidden = isVod || onRequestRoomSwitch == nil
            stack.isHidden = false
        } else {
            stack.isHidden = true
        }
    }

    @objc private func statusRetryTapped() {
        retryCurrentStream()
    }

    @objc private func statusLineTapped() {
        switchLineTapped()
    }

    @objc private func statusRoomTapped() {
        onRequestRoomSwitch?(1)
    }

    // Ask the web page for the next CDN line (its __nativeLiveFailed
    // tries the next line first; only a fresh URL is throttled to 60s).
    @objc private func lineButtonTapped() {
        switchLineTapped()
    }

    private func switchLineTapped() {
        scheduleControlsHide()
        showLoadingUI()
        onLiveFailed?()
    }

    @objc private func refreshTapped() {
        scheduleControlsHide()
        retryCurrentStream()
    }

    @objc private func followTapped() {
        scheduleControlsHide()
        onFollowTapped?()
        // Optimistic flip; ViewController corrects it from the web's
        // liveFollowed state right after toggling.
        setFollowed(!isFollowed)
    }

    // Current follow state, synced from the web page at present time
    // and after every tap (ViewController calls this).
    func setFollowed(_ followed: Bool) {
        isFollowed = followed
        updateFollowButton()
    }

    private func updateFollowButton() {
        guard let b = followButton else { return }
        if isFollowed {
            b.setTitle("✓ 已关注", for: .normal)
            b.setTitleColor(UIColor(red: 1, green: 0.82, blue: 0.4, alpha: 1), for: .normal)
        } else {
            b.setTitle("关注", for: .normal)
            b.setTitleColor(.white, for: .normal)
        }
    }

    // MARK: - HUD clock + battery (Pure Live PlaybackHud)

    private func startClockTimer() {
        clockTimer?.invalidate()
        // Minute-aligned: fire at the next minute boundary (+50ms),
        // then reschedule -- the clock never ticks the player.
        let now = Date()
        let next = Calendar.current.nextDate(after: now, matching: DateComponents(second: 0), matchingPolicy: .nextTime) ?? now.addingTimeInterval(60)
        let interval = max(1, next.timeIntervalSince(now) + 0.05)
        clockTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.updateClockLabel()
            self?.updateBattery()
            self?.startClockTimer()
        }
    }

    private func updateClockLabel() {
        let now = Date()
        let cal = Calendar.current
        clockLabel?.text = String(format: "%02d:%02d", cal.component(.hour, from: now), cal.component(.minute, from: now))
    }

    private func updateBattery() {
        let device = UIDevice.current
        let level = device.batteryLevel
        if level < 0 {
            batteryChip?.isHidden = true
            batteryPctLabel?.text = ""
            return
        }
        batteryChip?.isHidden = false
        batteryChip?.level = Double(level)
        batteryPctLabel?.text = "\(Int(round(level * 100)))%"
    }

    // MARK: - Lock button (Pure Live LockButton)

    @objc private func lockTapped() {
        setLocked(!isLocked)
    }

    private func setLocked(_ locked: Bool) {
        isLocked = locked
        lockButtonHiddenByTap = false
        lockButton?.setImage(UIImage(systemName: locked ? "lock" : "lock.open", withConfiguration: UIImage.SymbolConfiguration(pointSize: 28, weight: .semibold)), for: .normal)
        panGesture?.isEnabled = !locked
        doubleTapGesture?.isEnabled = !locked
        if locked {
            controlsVisible = false
            controlsHideTimer?.invalidate()
            controlsHideTimer = nil
            topBar.isHidden = true
            bottomBar.isHidden = true
            topBar.alpha = 0
            bottomBar.alpha = 0
        } else {
            showControls()
        }
        updateLockButtonVisibility()
    }

    private func updateLockButtonVisibility() {
        guard let b = lockButton else { return }
        let land = visualLandscape || view.bounds.width > view.bounds.height
        b.isHidden = !land || (isLocked && lockButtonHiddenByTap)
    }

    // MARK: - Gestures (Pure Live player_gestures)

    @objc private func doubleTapFullscreen() {
        guard !isLocked else { return }
        setVisualLandscape(!visualLandscape)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard !isLocked, let videoView = videoView else { return }
        let size = videoView.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        switch gesture.state {
        case .began:
            panStartPoint = gesture.location(in: videoView)
            panStartBrightness = UIScreen.main.brightness
            panStartVolume = AVAudioSession.sharedInstance().outputVolume
            if isVod, let p = ijkPlayer {
                panStartPosition = p.currentPlaybackTime
            }
            panDecided = false
            panKind = .none
            panRoomDir = 0
        case .changed:
            let t = gesture.translation(in: videoView)
            if !panDecided {
                if max(abs(t.x), abs(t.y)) < 12 { return }
                if abs(t.x) > abs(t.y) {
                    // Horizontal: VOD seek. Live has no seek -- ignore.
                    if isVod {
                        panKind = .seek
                        panDecided = true
                    } else {
                        return
                    }
                } else {
                    // Vertical: Pure Live thirds when a room list is
                    // available (middle = switch room), halves
                    // otherwise (left = brightness, right = volume).
                    let x = panStartPoint.x
                    if !isVod, onRequestRoomSwitch != nil,
                       x >= size.width / 3, x <= size.width * 2 / 3 {
                        panKind = .roomSwitch
                    } else if x < size.width / 2 {
                        panKind = .brightness
                    } else {
                        panKind = .volume
                    }
                    panDecided = true
                }
            }
            switch panKind {
            case .brightness:
                let level = max(0, min(1, Double(panStartBrightness) + Double(-t.y / size.height) * 1.2))
                UIScreen.main.brightness = CGFloat(level)
                showLevelPill(kind: .brightness, level: level)
            case .volume:
                let level = max(0, min(1, Double(panStartVolume) + Double(-t.y / size.height) * 1.2))
                systemVolumeSlider()?.value = Float(level)
                showLevelPill(kind: .volume, level: level)
                // Remember it for this room (live only).
                saveCurrentLiveVolume(level)
            case .seek:
                guard let p = ijkPlayer else { return }
                let dur = p.duration
                guard dur.isFinite, dur > 0 else { return }
                let target = max(0, min(dur, panStartPosition + Double(t.x / size.width) * dur))
                panSeekTarget = target
                showSeekPill(target: target, duration: dur)
            case .roomSwitch:
                if t.y < -60 {
                    panRoomDir = 1
                    showTextPill("下一个直播间")
                } else if t.y > 60 {
                    panRoomDir = -1
                    showTextPill("上一个直播间")
                } else {
                    panRoomDir = 0
                    hideGesturePill()
                }
            case .none:
                break
            }
        case .ended, .cancelled, .failed:
            switch panKind {
            case .seek:
                seekToPosition(panSeekTarget)
            case .roomSwitch:
                if panRoomDir != 0 {
                    onRequestRoomSwitch?(panRoomDir)
                }
            default:
                break
            }
            hideGesturePillAfterDelay()
            // A drag's finger-lift must not toggle the controls.
            suppressTapUntil = Date().addingTimeInterval(0.35)
            panKind = .none
            panDecided = false
            panRoomDir = 0
        default:
            break
        }
    }

    private func systemVolumeSlider() -> UISlider? {
        guard let v = volumeView else { return nil }
        return v.subviews.compactMap { $0 as? UISlider }.first
    }

    private func showLevelPill(kind: PanKind, level: Double) {
        guard let pill = gesturePill, let icon = gesturePillIcon,
              let bar = gesturePillBar, let text = gesturePillText else { return }
        let name: String
        switch kind {
        case .brightness:
            name = level <= 0 ? "sun.min.fill" : level < 0.5 ? "sun.min" : "sun.max.fill"
        case .volume:
            name = level <= 0 ? "speaker.slash.fill" : level < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.3.fill"
        default:
            return
        }
        icon.image = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .regular))
        icon.isHidden = false
        bar.isHidden = false
        bar.progress = Float(level)
        text.text = "\(Int(round(level * 100)))%"
        pill.isHidden = false
        scheduleGesturePillHide()
    }

    private func showSeekPill(target: Double, duration: Double) {
        guard let pill = gesturePill, let icon = gesturePillIcon,
              let bar = gesturePillBar, let text = gesturePillText else { return }
        icon.isHidden = true
        bar.isHidden = false
        bar.progress = duration > 0 ? Float(max(0, min(1, target / duration))) : 0
        text.text = "\(formatTime(max(0, target))) / \(formatTime(duration))"
        pill.isHidden = false
        scheduleGesturePillHide()
    }

    private func showTextPill(_ text: String) {
        guard let pill = gesturePill, let icon = gesturePillIcon,
              let bar = gesturePillBar, let label = gesturePillText else { return }
        icon.isHidden = true
        bar.isHidden = true
        label.text = text
        pill.isHidden = false
        scheduleGesturePillHide()
    }

    private func scheduleGesturePillHide() {
        gestureHideTimer?.invalidate()
        gestureHideTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            self?.hideGesturePill()
        }
    }

    private func hideGesturePillAfterDelay() {
        scheduleGesturePillHide()
    }

    private func hideGesturePill() {
        gestureHideTimer?.invalidate()
        gestureHideTimer = nil
        gesturePill?.isHidden = true
    }

    // Tap a flying danmaku to pin it; tap again to release it.
    // (Pure Live pins a danmaku on tap / long-press / press-hold.)
    private func toggleDanmakuPin(_ label: UILabel) {
        let layer = label.layer
        if layer.speed == 0 {
            let pausedTime = layer.timeOffset
            layer.speed = 1
            layer.timeOffset = 0
            layer.beginTime = 0
            let timeSincePause = layer.convertTime(CACurrentMediaTime(), from: nil) - pausedTime
            layer.beginTime = timeSincePause
        } else {
            layer.timeOffset = layer.convertTime(CACurrentMediaTime(), from: nil)
            layer.speed = 0
        }
    }

    // MARK: - Orientation-dependent visibility

    // Which bottom-bar items show, whether the HUD / lock button show,
    // and which title leading constraint is active. Called from
    // layoutContentView on every layout pass, so rotation and the
    // visual-landscape transform both re-derive it. Idempotent:
    // setting a flag to its current value changes nothing.
    private func updateLandscapeOnlyViews() {
        let land = visualLandscape || view.bounds.width > view.bounds.height
        hudStack?.isHidden = !land
        titleLeadingClose?.isActive = !land
        titleLeadingHUD?.isActive = land
        updateLockButtonVisibility()
        updateBottomBarItems()
    }

    private func updateBottomBarItems() {
        let land = visualLandscape || view.bounds.width > view.bounds.height
        let live = !isVod
        liveChip?.isHidden = !live || !land
        followButton?.isHidden = !live || !land
        lineButton?.isHidden = !live || !land
        airPlayView?.isHidden = !land
        refreshButton?.isHidden = !live
        qualityButton?.isHidden = !live || liveQualities.count <= 1
        curTimeLabel?.isHidden = live
        seekSlider?.isHidden = live
        durTimeLabel?.isHidden = live
    }

}
