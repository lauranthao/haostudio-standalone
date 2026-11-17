import AVFoundation
import AVKit
import Flutter
import MediaPlayer
import UIKit
import os

// Now Playing shell for music (Fix 14) — port of the Swift app's
// NativeMusicPlayer Now Playing behaviour to the Flutter shell.
//
//  - Dart pushes track state over the
//    `com.haostudio.standalone/now_playing` MethodChannel
//    (`updateNowPlaying` / `clearNowPlaying`).
//  - This side publishes MPNowPlayingInfoCenter and owns the
//    MPRemoteCommandCenter handlers (play / pause / toggle / seek /
//    next / previous). Remote commands are forwarded back to Dart over
//    the same channel as `remoteCommand`.
//  - NO skipForward/skipBackward: music is track-based. Enabling skip
//    makes iOS show ±10 s buttons INSTEAD of prev/next (same lesson as
//    the Swift app, chen 2026-11-16: Control Center showed only the
//    ±10 s buttons, no prev/next). The video player keeps its own
//    ±10 s — untouched here.
//  - Tapping the Now Playing card / Dynamic Island / Lock Screen
//    opens the app: that comes free from a correctly configured audio
//    session (.playback, active) + Now Playing info. No Live Activity
//    is added.
//  - This plugin is the SOLE owner of the shared command center for
//    music: media_kit registers no remote commands, and there is no
//    web Media Session bridge in the Flutter app, so one press fires
//    exactly once. The Dart side additionally dedupes rapid
//    next/previous commands (see NowPlayingService).
//  - Root cause of "tap does nothing" (chen 2026-11-16, v1.0.5):
//    (a) `beginReceivingRemoteControlEvents()` was never called —
//    the documented prerequisite for the system to route Lock Screen
//    / Control Center / headphone commands to the app (the path
//    just_audio_background and audio_service both use); without it
//    the command targets can sit registered and never fire, and
//    Control Center prev/next does nothing. (b) The audio session
//    was activated only once: media_kit's mpv re-inits its audio
//    output on every track open / crossfade player swap, and mpv's
//    ao_avfoundation deactivates the shared session on teardown —
//    the app then silently loses Now Playing attribution, the Lock
//    Screen / Dynamic Island keep showing a stale card, and tapping
//    it does nothing. Fix: set up commands eagerly at registration,
//    call beginReceivingRemoteControlEvents, and re-assert the
//    session active on every publish (a no-op when already active).
//  - v1.0.6 follow-up (chen 2026-11-17): STILL does not open on tap.
//    That fix only re-asserted the session on Dart pushes — and Dart
//    pushes STOP exactly when they are needed most: the throttled
//    path returns early while paused, and the isolate can stall in
//    background, so if mpv releases the session after a pause (or an
//    interruption ends without mpv reclaiming it) the card keeps
//    showing the last info while the session is inactive — and a
//    Now Playing card with an inactive session does NOT open the app.
//    Also `clearNowPlaying` tore the whole command center down
//    (endReceivingRemoteControlEvents) whenever the queue transiently
//    emptied, and the plugin fought mpv over the session category
//    (forcing mode .default over mpv's .moviePlayback). Fix: the
//    native side is now self-healing and independent of Dart pushes —
//    it observes interruptions + foreground, runs a 5 s heartbeat
//    that re-asserts the session and re-publishes the cached info
//    when it went missing, never tears the command center down, and
//    only sets the category when it is not already .playback.
// MUST inherit from NSObject: MPRemoteCommand.addTarget messages the
// target through the Objective-C runtime, and a pure Swift class as
// the target crashes the app the moment a remote command fires (same
// fix as NativeMusicPlayer v11.9.1 in the Swift app).
final class NowPlayingPlugin: NSObject, FlutterPlugin {
    private let channel: FlutterMethodChannel

    private var commandsActive = false
    private var currentCoverURL = ""
    private var artwork: MPMediaItemArtwork?
    // Last published Now Playing info, cached so the native side can
    // re-publish it without waiting for a Dart push (interruption end,
    // foreground, heartbeat). The elapsed time inside may be a few
    // seconds stale; Dart pushes a fresh one ~1 s while playing.
    private var lastInfo: [String: Any]?
    // Safety-net timer: re-asserts the session + re-publishes the
    // cached info every 5 s. Only acts when something is actually
    // wrong (setActive is a no-op when active; re-publish only fires
    // when nowPlayingInfo went nil), so it costs nothing when healthy.
    private var heartbeat: Timer?

    init(channel: FlutterMethodChannel) {
        self.channel = channel
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        heartbeat?.invalidate()
    }

    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "com.haostudio.standalone/now_playing",
            binaryMessenger: registrar.messenger())
        let instance = NowPlayingPlugin(channel: channel)
        registrar.addMethodCallDelegate(instance, channel: channel)
        // Eager command setup: the app is remote-control-ready from
        // launch, so a first publish skipped by the empty-title guard
        // (or any early failure) can never leave the command center
        // unregistered. Session activation still happens on publish
        // (updateNowPlaying), when there is real audio to attribute.
        instance.setupCommandsIfNeeded()
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "updateNowPlaying":
            guard let args = call.arguments as? [String: Any] else {
                result(FlutterError(code: "bad_args", message: "updateNowPlaying needs a map", details: nil))
                return
            }
            updateNowPlaying(args)
            result(nil)
        case "clearNowPlaying":
            clearNowPlaying()
            result(nil)
        case "showAirPlayPicker":
            result(showAirPlayPicker())
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Now Playing info

    private func updateNowPlaying(_ args: [String: Any]) {
        let title = args["title"] as? String ?? ""
        guard !title.isEmpty else { return }
        let artist = args["artist"] as? String ?? ""
        let album = args["album"] as? String ?? ""
        let coverURL = args["coverUrl"] as? String ?? ""
        let duration = (args["duration"] as? NSNumber)?.doubleValue ?? 0
        let position = (args["position"] as? NSNumber)?.doubleValue ?? 0
        let playing = args["playing"] as? Bool ?? false

        configureAudioSession()
        setupCommandsIfNeeded()

        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = title
        info[MPMediaItemPropertyArtist] = artist
        info[MPMediaItemPropertyAlbumTitle] = album.isEmpty ? "HAo Studio" : album
        if duration.isFinite, duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        if position.isFinite, position >= 0 {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
        }
        info[MPNowPlayingInfoPropertyPlaybackRate] = playing ? 1.0 : 0.0
        if let art = artwork {
            info[MPMediaItemPropertyArtwork] = art
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        lastInfo = info

        fetchArtworkIfNeeded(coverURL: coverURL)
    }

    private func clearNowPlaying() {
        // Clear the info only. The command center stays registered for
        // the app's lifetime: tearing it down here (endReceivingRemote
        // ControlEvents) left the app deregistered whenever the queue
        // transiently emptied, with nothing re-registering it until
        // the next track change.
        lastInfo = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        currentCoverURL = ""
        artwork = nil
    }

    // MARK: - AirPlay route picker

    /// Long-lived hidden AVRoutePickerView (iOS 11+, AVKit).
    ///
    /// The system AirPlay route picker can only be opened by tapping
    /// an AVRoutePickerView — there is no public "present the picker"
    /// API — so this instance lives in the key window's hierarchy
    /// (44×44 pt, parked off-screen at -100,-100) and the Dart
    /// AirPlay button asks it to fire its internal button's action,
    /// which is exactly what a physical tap would do. The view is
    /// never removed: it stays alive for the app's lifetime, so the
    /// picker can be opened any number of times.
    ///
    /// AVRoutePickerView only selects the audio output route; it
    /// never touches volume. The MPVolumeView that used to drive
    /// volume sync was deleted per chen 2026-11-17 and is NOT brought
    /// back here.
    private var routePickerView: AVRoutePickerView?
    /// Last time the picker action was fired: a second tap while the
    /// system sheet is still animating in would make UIKit log a
    /// "presentation in progress" warning, so re-fires within 0.5 s
    /// are ignored (the picker is already open, so true is returned).
    private var lastPickerFireAt: Date?

    /// Open the system AirPlay route picker. Returns true when the
    /// picker's button action fired (the sheet itself is presented by
    /// the system, which also handles the no-device state — it just
    /// lists this iPhone). Returns false only when the picker cannot
    /// be opened at all (no key window, or the picker's internal
    /// button was not found).
    private func showAirPlayPicker() -> Bool {
        if let last = lastPickerFireAt, Date().timeIntervalSince(last) < 0.5 {
            return true
        }
        guard let window = Self.keyWindow else { return false }
        if routePickerView == nil {
            let picker = AVRoutePickerView(frame: CGRect(x: -100, y: -100, width: 44, height: 44))
            window.addSubview(picker)
            routePickerView = picker
        }
        guard let picker = routePickerView else { return false }
        picker.layoutIfNeeded()
        guard let button = Self.routePickerButton(in: picker) else { return false }
        lastPickerFireAt = Date()
        button.sendActions(for: .touchUpInside)
        return true
    }

    /// The picker's button is an internal subview (no public
    /// accessor): find the first UIButton in its hierarchy. Returns
    /// nil if Apple ever changes the hierarchy — the caller then
    /// reports failure instead of crashing.
    private static func routePickerButton(in view: UIView) -> UIButton? {
        if let button = view as? UIButton { return button }
        for subview in view.subviews {
            if let found = routePickerButton(in: subview) { return found }
        }
        return nil
    }

    /// iOS 13+ scene-based key-window lookup (`keyWindow` is
    /// deprecated).
    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
    }

    // The audio session must be .playback and active for iOS to
    // attribute the Now Playing card to this app, so tapping the card
    // / Dynamic Island / Lock Screen opens the app. media_kit (mpv)
    // also configures the session for playback; setting the category
    // here is compatible and guarantees the attribution even if the
    // player has not started its session yet.
    //
    // Do NOT fight mpv over the category: mpv's ao_avfoundation sets
    // .playback + .moviePlayback itself. The category is set here only
    // when it is not already .playback (e.g. before mpv first starts),
    // so we never clobber mpv's mode mid-playback.
    //
    // The session is re-activated on EVERY publish AND by the
    // heartbeat / interruption / foreground handlers: mpv re-inits its
    // audio output on each track open / crossfade player swap and its
    // ao_avfoundation deactivates the shared session on teardown, and
    // Dart pushes stop while paused — without these native-side
    // re-asserts the app silently loses Now Playing attribution after
    // a pause or an interruption, the Lock Screen / Dynamic Island
    // keep a stale card and tapping it does nothing. setActive(true)
    // on an already-active session is a no-op. The session is left
    // alone on clear — deactivating it could pause media_kit's
    // playback. A failed activation is logged (os_log) instead of
    // swallowed: it is the one signal that attribution is lost.
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            if session.category != .playback {
                try session.setCategory(.playback, mode: .default, options: [])
            }
            try session.setActive(true)
        } catch {
            os_log("NowPlaying: setActive failed: %{public}@", log: .default, type: .error, String(describing: error))
        }
    }

    // MARK: - Self-healing (v1.0.6 follow-up)

    /// Re-publish the cached Now Playing info, but only when it went
    /// missing. Re-setting an already-set info with a stale elapsed
    /// time would make the Lock Screen progress jump backwards; the
    /// fresh Dart push (~1 s while playing) owns the live values.
    private func republishIfNeeded() {
        guard let info = lastInfo else { return }
        if MPNowPlayingInfoCenter.default().nowPlayingInfo == nil {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }

    /// Interruption (call / Siri / alarm) ended: reclaim the session
    /// and the Now Playing slot. mpv may or may not resume on its own;
    /// attribution must not depend on it.
    @objc private func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue),
              type == .ended else { return }
        configureAudioSession()
        republishIfNeeded()
    }

    /// App came to foreground: re-assert the session and the info so
    /// the card is tappable immediately, without waiting for the next
    /// Dart position push.
    @objc private func handleDidBecomeActive() {
        configureAudioSession()
        republishIfNeeded()
    }

    private func startHeartbeatIfNeeded() {
        guard heartbeat == nil else { return }
        let timer = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.heartbeatTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeat = timer
    }

    /// Safety net for the case Dart pushes stop — paused, or the
    /// isolate stalled in background — and mpv released the session in
    /// the meantime. Without it the card keeps showing stale info but
    /// tapping it does nothing, because the app is no longer the
    /// now-playing app.
    private func heartbeatTick() {
        guard commandsActive else { return }
        configureAudioSession()
        republishIfNeeded()
    }

    // MARK: - Remote commands

    private func setupCommandsIfNeeded() {
        guard !commandsActive else { return }
        commandsActive = true
        // Documented prerequisite for the system to route remote
        // control events to the app (the path just_audio_background
        // and audio_service both use): without it, Lock Screen /
        // Control Center / headphone commands may never reach the
        // registered MPRemoteCommandCenter targets at all.
        UIApplication.shared.beginReceivingRemoteControlEvents()
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget(self, action: #selector(remotePlay))
        center.pauseCommand.addTarget(self, action: #selector(remotePause))
        center.togglePlayPauseCommand.addTarget(self, action: #selector(remoteToggle))
        center.changePlaybackPositionCommand.addTarget(self, action: #selector(remoteSeek(_:)))
        // NO skipForward/skipBackward — see the file header.
        center.nextTrackCommand.addTarget(self, action: #selector(remoteNext))
        center.previousTrackCommand.addTarget(self, action: #selector(remotePrevious))
        startHeartbeatIfNeeded()
    }

    private func forwardCommand(_ command: String, position: Double? = nil) {
        var args: [String: Any] = ["command": command]
        if let position {
            args["position"] = position
        }
        channel.invokeMethod("remoteCommand", arguments: args)
    }

    @objc private func remotePlay() -> MPRemoteCommandHandlerStatus {
        forwardCommand("play")
        return .success
    }

    @objc private func remotePause() -> MPRemoteCommandHandlerStatus {
        forwardCommand("pause")
        return .success
    }

    @objc private func remoteToggle() -> MPRemoteCommandHandlerStatus {
        forwardCommand("toggle")
        return .success
    }

    @objc private func remoteSeek(_ event: MPChangePlaybackPositionCommandEvent) -> MPRemoteCommandHandlerStatus {
        let pos = event.positionTime
        guard pos.isFinite, pos >= 0 else { return .commandFailed }
        forwardCommand("seek", position: pos)
        return .success
    }

    @objc private func remoteNext() -> MPRemoteCommandHandlerStatus {
        forwardCommand("next")
        return .success
    }

    @objc private func remotePrevious() -> MPRemoteCommandHandlerStatus {
        forwardCommand("previous")
        return .success
    }

    // MARK: - Artwork

    private func fetchArtworkIfNeeded(coverURL: String) {
        guard coverURL != currentCoverURL, let url = URL(string: coverURL), !coverURL.isEmpty else { return }
        currentCoverURL = coverURL
        artwork = nil
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self = self, let data = data, let image = UIImage(data: data) else { return }
            let art = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            DispatchQueue.main.async {
                // Only apply if this is still the current cover and
                // this plugin still owns the Now Playing slot.
                guard self.commandsActive, self.currentCoverURL == coverURL else { return }
                self.artwork = art
                if var info = MPNowPlayingInfoCenter.default().nowPlayingInfo {
                    info[MPMediaItemPropertyArtwork] = art
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
                    self.lastInfo = info
                }
            }
        }.resume()
    }
}
