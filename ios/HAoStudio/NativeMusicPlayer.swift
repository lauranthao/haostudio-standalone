import UIKit
import WebKit
import AVFoundation
import MediaPlayer

// Native music player (v11.9) — the web <audio> element CANNOT achieve
// true zero pause on foreground entry, and this is now proven with
// evidence, not assumed. The "remove a resume path" hypothesis was
// exhausted (2026-11-16) and REJECTED:
//
//  - Timeline (Gitee main, verified): the pause was first reported
//    2026-11-15 ~20:32 CST on v11.3. v11.3 DID have native
//    foreground-resume code (resumeWebMusicIfNeeded /
//    appWillEnterForeground / reactivateAudioSession) but WITHOUT the
//    audioSessionActive guard — so setActive(true) fired unconditionally
//    on every foreground entry, which IS a real pause mechanism and was
//    the likely cause in v11.3–v11.6. The web had NO resume code at
//    20:32 (ev came ~22:24), so the web resume paths did not introduce
//    the pause. v11.7 added the audioSessionActive guard (no more
//    unconditional setActive(true)) — yet the pause PERSISTS on
//    v11.7/v11.8. So setActive(true) is not the remaining cause.
//  - Every resume path was audited and is guarded by `audio.paused`
//    (web: stalled/suspend/__resumeAudioIfPlaying/scheduleWebAutoResume/
//    visibilitychange; native: reactivateAudioSession() is a no-op while
//    audioSessionActive, no webView.reload() anywhere). No `audio.pause()`
//    or `audio.src` change runs on foreground entry (the only pause()
//    sites are user stop / user tap / lock-screen pause). No improvement
//    path can pause or restart a playing element, so removing one cannot
//    reach zero — it would only remove the recovery.
//  - The remaining pause is a SYSTEM behavior: on background->foreground
//    the WKWebView WebContent process / media pipeline resumes and the
//    <audio> element fires a `pause` event. No web code and no native
//    resume code can prevent it — they can only resume faster (~50ms).
//  - The three "prevention" candidates were all evaluated and rejected:
//    (1) keep the session continuously active — ALREADY DONE in v11.7/
//    v11.8, pause persists; (2) swallow a foreground-entry interruption
//    — no evidence one is posted on a plain foreground transition, and
//    the web hears the pause at `.began` before `.ended` can act;
//    (3) stop the WKWebView media pipeline being suspended — no public
//    API exists.
//  - So music moves to a native AVPlayer. AVPlayer lives in the app
//    process and is driven directly by the media server (the same engine
//    Apple Music uses): it does NOT pause when the app returns to the
//    foreground, because there is no WebContent process in its path.
//    The web page keeps owning the queue, song choice, lyrics and UI;
//    only the audio OUTPUT moves native. The web <audio> element stays
//    as the fallback (browser/Safari, and if native fails to start).
//
// Contract with the web page (app.js, v11.9 web half):
//  - Web posts to `nativeMusic`: {kind:'play', url, songId, title,
//    artist, cover, position} / {kind:'pause'} / {kind:'resume'} /
//    {kind:'toggle'} / {kind:'seek', position} / {kind:'stop'} /
//    {kind:'mute', muted} (muted may also ride on 'play') /
//    {kind:'bgPlay', enabled} (settings "后台播放": when OFF the
//    ViewController pauses this player on backgrounding).
//  - Keep-screen (settings "屏幕常亮") is NOT a nativeMusic kind:
//    the web posts {kind:'keepScreen', enabled} to `nativePlayer`
//    and the ViewController applies it (see applyIdleTimer).
//  - Native calls back: window.__nativeMusicStarted() (took over — web
//    cancels its fallback timer), window.__nativeMusicTick(pos, dur)
//    every 0.5s (progress bar + lyrics), window.__nativeMusicEnded()
//    (track finished), window.__nativeMusicState(playing) (pause/resume
//    from lock screen / interruption), window.__nativeMusicError()
//    (could not play — web falls back to the <audio> element).
//  - The web page must NOT set Media Session metadata while native is
//    active (it would publish a competing Now Playing for a paused
//    <audio> element); the native side owns MPNowPlayingInfoCenter.
//  - Lock screen / Control Center lyric line: the periodic observer
//    reads window.currentLyricLine() and writes it into the Now Playing
//    artist field, mirroring what the web Media Session did.
// MUST inherit from NSObject (v11.9.1 fix): MPRemoteCommand.addTarget
// messages the player through the Objective-C runtime, and a pure
// Swift class as the target crashes the app the moment play() calls
// setupNowPlaying() (v11.9: tap play -> instant crash). NSObject
// inheritance makes the target a real ObjC object.
final class NativeMusicPlayer: NSObject {
    static let shared = NativeMusicPlayer()

    weak var webView: WKWebView?

    // The browser UA, captured from the web page at launch so the CDN
    // sees the same UA the <audio> element used to send (some music
    // CDNs reject non-browser UAs). Set by ViewController once the page
    // loads; until then items are created with no custom headers.
    var userAgent: String?

    private var player: AVPlayer?
    // Global mute (settings): applied to the AVPlayer at play time and
    // live via setMuted, so the mute toggle silences native music too
    // (the web <audio> element is muted separately in JS).
    private var muted = false
    // Background-play preference (settings "后台播放", web default ON):
    // set by the nativeMusic {kind:'bgPlay', enabled} message. When
    // OFF the ViewController pauses this player on backgrounding
    // (applyBackgroundPlayPreference); ON leaves the session alone.
    var backgroundPlayEnabled = true
    // Fired whenever the play state changes (play / pause / stop /
    // interruption) so the ViewController can re-apply the idle timer
    // (keep-screen only counts while something is playing).
    var onPlayingStateChanged: (() -> Void)?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var didReportError = false

    private(set) var isActive = false   // a track is loaded natively
    private(set) var isPlaying = false

    private var currentURL: URL?
    private var currentSongId = ""
    private var currentTitle = ""
    private var currentArtist = ""
    private var currentCover = ""
    private var currentLyricLine = ""
    private var nowPlayingArtwork: MPMediaItemArtwork?
    private var nowPlayingActive = false
    private var lastNowPlayingElapsedUpdate = Date.distantPast

    private override init() {
        super.init()
        // A call / Siri pauses the AVPlayer. Sync the web UI state on
        // .began (playing=false) but do NOT clear the intent — the
        // second argument `false` tells the web page this is a system
        // pause, so wantPlaying stays true. The ViewController's
        // .ended path (resumeWebMusicIfNeeded) resumes it.
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] n in
            self?.handleInterruption(n)
        }
    }

    private func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeRaw = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw),
              type == .began, isActive, isPlaying else { return }
        isPlaying = false
        updateNowPlayingInfo()
        postJS("if(window.__nativeMusicState){window.__nativeMusicState(false,false);}")
        onPlayingStateChanged?()
    }

    // MARK: - Playback

    func play(url: URL, songId: String, title: String, artist: String, cover: String, position: Double) {
        let p: AVPlayer
        if let existing = player {
            p = existing
        } else {
            p = AVPlayer()
            player = p
        }
        p.isMuted = muted
        currentSongId = songId
        currentTitle = title
        currentArtist = artist
        currentCover = cover
        currentLyricLine = ""
        nowPlayingArtwork = nil
        didReportError = false
        if currentURL == url, p.currentItem != nil {
            // Same stream: just seek + play, never recreate the item
            // (recreating would re-buffer and gap).
            if position > 0 {
                p.seek(to: CMTime(seconds: position, preferredTimescale: 600))
            }
            p.play()
        } else {
            currentURL = url
            let item: AVPlayerItem
            if let ua = userAgent, !ua.isEmpty {
                // NOTE: AVURLAssetHTTPHeaderFieldsKey is NOT in scope on the
                // Codemagic Xcode SDK (build #40: "cannot find
                // 'AVURLAssetHTTPHeaderFieldsKey'"), so use the literal
                // string key — AVURLAsset options is [String: Any]? and
                // AVFoundation matches the key by its string value.
                let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": ua]])
                item = AVPlayerItem(asset: asset)
            } else {
                item = AVPlayerItem(url: url)
            }
            observeEnd(of: item)
            p.replaceCurrentItem(with: item)
            if position > 0 {
                p.seek(to: CMTime(seconds: position, preferredTimescale: 600))
            }
            p.play()
        }
        isActive = true
        isPlaying = true
        setupNowPlaying()
        updateNowPlayingInfo()
        fetchNowPlayingArtworkIfNeeded()
        startTimeObserver()
        postJS("if(window.__nativeMusicStarted){window.__nativeMusicStarted();}")
        onPlayingStateChanged?()
    }

    // Global mute from the settings page ({kind:'mute'}). Stored so a
    // mute set before playback sticks when the next track starts.
    func setMuted(_ muted: Bool) {
        self.muted = muted
        player?.isMuted = muted
    }

    // Background-play preference from the settings page
    // ({kind:'bgPlay', enabled}). Stored only — the ViewController
    // acts on it at background time.
    func setBackgroundPlayEnabled(_ on: Bool) {
        backgroundPlayEnabled = on
    }

    func pause() {
        guard isActive else { return }
        player?.pause()
        isPlaying = false
        updateNowPlayingInfo()
        // Second argument `true`: a user pause (lock screen / app UI),
        // so the web page clears wantPlaying.
        postJS("if(window.__nativeMusicState){window.__nativeMusicState(false,true);}")
        onPlayingStateChanged?()
    }

    func resume() {
        guard isActive else { return }
        // Zero-pause path: if already playing, do NOTHING. play() on a
        // playing AVPlayer is harmless, but an explicit guard makes the
        // intent clear and avoids any chance of a pipeline restart.
        if isPlaying { return }
        player?.play()
        isPlaying = true
        updateNowPlayingInfo()
        postJS("if(window.__nativeMusicState){window.__nativeMusicState(true,true);}")
        onPlayingStateChanged?()
    }

    func toggle() {
        if isPlaying { pause() } else { resume() }
    }

    func seek(to seconds: Double) {
        guard isActive, let p = player else { return }
        p.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600))
        updateNowPlayingInfo()
        postTick()
    }

    func stop() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        if let t = timeObserver { player?.removeTimeObserver(t); timeObserver = nil }
        if let o = endObserver { NotificationCenter.default.removeObserver(o); endObserver = nil }
        if let o = failObserver { NotificationCenter.default.removeObserver(o); failObserver = nil }
        isActive = false
        isPlaying = false
        currentURL = nil
        currentSongId = ""
        currentTitle = ""
        currentArtist = ""
        currentCover = ""
        currentLyricLine = ""
        nowPlayingArtwork = nil
        teardownNowPlaying()
        onPlayingStateChanged?()
    }

    // MARK: - Position reporting

    private func startTimeObserver() {
        guard timeObserver == nil, let p = player else { return }
        timeObserver = p.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] _ in
            self?.postTick()
            self?.refreshLyricLine()
        }
    }

    private func postTick() {
        guard isActive, let p = player, let item = p.currentItem else { return }
        // A failed item (CDN rejected the stream, bad URL) must fall
        // back to the web <audio> element — report once and release.
        if item.status == .failed {
            reportError()
            return
        }
        let pos = CMTimeGetSeconds(p.currentTime())
        let dur = CMTimeGetSeconds(item.duration)
        let posStr = pos.isFinite ? String(format: "%.3f", pos) : "0"
        let durStr = dur.isFinite ? String(format: "%.3f", dur) : "0"
        postJS("if(window.__nativeMusicTick){window.__nativeMusicTick(\(posStr),\(durStr));}")
        // Keep the lock screen elapsed time fresh (throttled to 1s).
        if Date().timeIntervalSince(lastNowPlayingElapsedUpdate) >= 1.0 {
            updateNowPlayingInfo()
        }
    }

    private func observeEnd(of item: AVPlayerItem) {
        if let o = endObserver { NotificationCenter.default.removeObserver(o); endObserver = nil }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            guard let self = self, self.isActive else { return }
            self.isPlaying = false
            self.updateNowPlayingInfo()
            self.postJS("if(window.__nativeMusicEnded){window.__nativeMusicEnded();}")
        }
        if let o = failObserver { NotificationCenter.default.removeObserver(o); failObserver = nil }
        failObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            self?.reportError()
        }
    }

    // The stream could not be played (CDN rejected it, bad URL). Tell
    // the web page once so it falls back to the <audio> element — music
    // must keep working even if the native path fails for one track.
    private func reportError() {
        guard isActive, !didReportError else { return }
        didReportError = true
        isActive = false
        isPlaying = false
        postJS("if(window.__nativeMusicError){window.__nativeMusicError();}")
    }

    // Lock screen lyric line: pull the web page's current lyric line
    // (the same line the web Media Session used to publish) and write
    // it into the Now Playing artist field. The web page owns lyrics;
    // this only mirrors the line, exactly like updateMediaSession did.
    private func refreshLyricLine() {
        guard isActive else { return }
        webView?.evaluateJavaScript("typeof currentLyricLine==='function'?currentLyricLine():''") { [weak self] result, _ in
            guard let self = self, self.isActive else { return }
            let line = (result as? String) ?? ""
            if line != self.currentLyricLine {
                self.currentLyricLine = line
                self.updateNowPlayingInfo()
            }
        }
    }

    private func postJS(_ js: String) {
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    // MARK: - Now Playing + remote commands

    private func setupNowPlaying() {
        guard !nowPlayingActive else { updateNowPlayingInfo(); return }
        nowPlayingActive = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget(self, action: #selector(remotePlay))
        center.pauseCommand.addTarget(self, action: #selector(remotePause))
        center.togglePlayPauseCommand.addTarget(self, action: #selector(remoteToggle))
        center.changePlaybackPositionCommand.addTarget(self, action: #selector(remoteSeek(_:)))
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: 10)]
        center.skipForwardCommand.addTarget(self, action: #selector(remoteSkipForward(_:)))
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: 10)]
        center.skipBackwardCommand.addTarget(self, action: #selector(remoteSkipBackward(_:)))
        center.nextTrackCommand.addTarget(self, action: #selector(remoteNext))
        center.previousTrackCommand.addTarget(self, action: #selector(remotePrevious))
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
        center.nextTrackCommand.removeTarget(self)
        center.previousTrackCommand.removeTarget(self)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func updateNowPlayingInfo() {
        guard nowPlayingActive, isActive else { return }
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = currentTitle
        // Lyric line in the artist field when one is showing (the web
        // Media Session did the same); otherwise the real artist.
        info[MPMediaItemPropertyArtist] = currentLyricLine.isEmpty ? currentArtist : currentLyricLine
        info[MPMediaItemPropertyAlbumTitle] = currentLyricLine.isEmpty ? "HAo Studio" : currentArtist
        if let p = player, let item = p.currentItem {
            let dur = CMTimeGetSeconds(item.duration)
            let pos = CMTimeGetSeconds(p.currentTime())
            if dur.isFinite, dur > 0 { info[MPMediaItemPropertyPlaybackDuration] = dur }
            if pos.isFinite, pos >= 0 { info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = pos }
        }
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        if let art = nowPlayingArtwork { info[MPMediaItemPropertyArtwork] = art }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        lastNowPlayingElapsedUpdate = Date()
    }

    private func fetchNowPlayingArtworkIfNeeded() {
        guard let url = URL(string: currentCover), !currentCover.isEmpty, nowPlayingArtwork == nil else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self = self, let data = data, let image = UIImage(data: data) else { return }
            let art = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            DispatchQueue.main.async {
                self.nowPlayingArtwork = art
                self.updateNowPlayingInfo()
            }
        }.resume()
    }

    @objc private func remotePlay() -> MPRemoteCommandHandlerStatus {
        resume()
        return .success
    }

    @objc private func remotePause() -> MPRemoteCommandHandlerStatus {
        pause()
        return .success
    }

    @objc private func remoteToggle() -> MPRemoteCommandHandlerStatus {
        toggle()
        return .success
    }

    @objc private func remoteSeek(_ event: MPChangePlaybackPositionCommandEvent) -> MPRemoteCommandHandlerStatus {
        seek(to: event.positionTime)
        return .success
    }

    @objc private func remoteSkipForward(_ event: MPSkipIntervalCommandEvent) -> MPRemoteCommandHandlerStatus {
        guard let p = player else { return .commandFailed }
        let pos = CMTimeGetSeconds(p.currentTime())
        if pos.isFinite { seek(to: pos + event.interval) }
        return .success
    }

    @objc private func remoteSkipBackward(_ event: MPSkipIntervalCommandEvent) -> MPRemoteCommandHandlerStatus {
        guard let p = player else { return .commandFailed }
        let pos = CMTimeGetSeconds(p.currentTime())
        if pos.isFinite { seek(to: max(0, pos - event.interval)) }
        return .success
    }

    @objc private func remoteNext() -> MPRemoteCommandHandlerStatus {
        // The web page owns the queue: ask it to advance (it will post
        // the next track back to nativeMusic).
        postJS("if(window.nextTrack){window.nextTrack();}")
        return .success
    }

    @objc private func remotePrevious() -> MPRemoteCommandHandlerStatus {
        postJS("if(window.prevTrack){window.prevTrack();}")
        return .success
    }
}
