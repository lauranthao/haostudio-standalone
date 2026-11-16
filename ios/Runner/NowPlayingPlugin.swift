import AVFoundation
import Flutter
import MediaPlayer
import UIKit

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
// MUST inherit from NSObject: MPRemoteCommand.addTarget messages the
// target through the Objective-C runtime, and a pure Swift class as
// the target crashes the app the moment a remote command fires (same
// fix as NativeMusicPlayer v11.9.1 in the Swift app).
final class NowPlayingPlugin: NSObject, FlutterPlugin {
    private let channel: FlutterMethodChannel

    private var commandsActive = false
    private var currentCoverURL = ""
    private var artwork: MPMediaItemArtwork?
    private var sessionConfigured = false

    init(channel: FlutterMethodChannel) {
        self.channel = channel
        super.init()
    }

    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "com.haostudio.standalone/now_playing",
            binaryMessenger: registrar.messenger())
        let instance = NowPlayingPlugin(channel: channel)
        registrar.addMethodCallDelegate(instance, channel: channel)
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

        configureAudioSessionIfNeeded()
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

        fetchArtworkIfNeeded(coverURL: coverURL)
    }

    private func clearNowPlaying() {
        guard commandsActive else { return }
        teardownCommands()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        currentCoverURL = ""
        artwork = nil
    }

    // The audio session must be .playback and active for iOS to
    // attribute the Now Playing card to this app, so tapping the card
    // / Dynamic Island / Lock Screen opens the app. media_kit (mpv)
    // also configures the session for playback; setting the category
    // here is compatible and guarantees the attribution even if the
    // player has not started its session yet. The session is left
    // alone on clear — deactivating it could pause media_kit's
    // playback.
    private func configureAudioSessionIfNeeded() {
        guard !sessionConfigured else { return }
        sessionConfigured = true
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            // Non-fatal: the player still works; the card may just
            // not be app-attributed until mpv activates the session.
            sessionConfigured = false
        }
    }

    // MARK: - Remote commands

    private func setupCommandsIfNeeded() {
        guard !commandsActive else { return }
        commandsActive = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget(self, action: #selector(remotePlay))
        center.pauseCommand.addTarget(self, action: #selector(remotePause))
        center.togglePlayPauseCommand.addTarget(self, action: #selector(remoteToggle))
        center.changePlaybackPositionCommand.addTarget(self, action: #selector(remoteSeek(_:)))
        // NO skipForward/skipBackward — see the file header.
        center.nextTrackCommand.addTarget(self, action: #selector(remoteNext))
        center.previousTrackCommand.addTarget(self, action: #selector(remotePrevious))
    }

    private func teardownCommands() {
        guard commandsActive else { return }
        commandsActive = false
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(self)
        center.pauseCommand.removeTarget(self)
        center.togglePlayPauseCommand.removeTarget(self)
        center.changePlaybackPositionCommand.removeTarget(self)
        center.nextTrackCommand.removeTarget(self)
        center.previousTrackCommand.removeTarget(self)
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
                }
            }
        }.resume()
    }
}
