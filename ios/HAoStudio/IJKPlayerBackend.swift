// IJKPlayerBackend — the ijkplayer (FFmpeg) engine behind the
// PlayerBackend protocol. This is the v1.0.x engine, moved out of
// NativePlayerViewController unchanged: same options, same notifications,
// same finish-reason handling — only the delivery changed (notifications
// become PlayerBackendEvent values the player UI already understands).

import UIKit
import IJKMediaFramework

final class IJKPlayerBackend: NSObject, PlayerBackend {
    var onEvent: ((PlayerBackendEvent) -> Void)?
    var onVideoSize: ((CGSize) -> Void)?

    private var player: IJKFFMoviePlayerController?
    private var streamURL: URL?
    private var rate: Double = 1

    var view: UIView {
        // The player always owns a view once opened; before that a
        // plain placeholder keeps the player's layout code simple.
        if let v = player?.view { return v }
        let v = UIView()
        v.backgroundColor = .black
        return v
    }

    var isPlaying: Bool { player?.isPlaying() ?? false }

    var currentTime: Double {
        let t = player?.currentPlaybackTime ?? 0
        return t.isFinite ? t : 0
    }

    var duration: Double {
        let d = player?.duration ?? Double.nan
        return d.isFinite ? d : Double.nan
    }

    var isPrepared: Bool { player?.isPreparedToPlay ?? false }

    var playbackRate: Double {
        get { rate }
        set {
            rate = newValue
            player?.playbackRate = Float(newValue)
        }
    }

    @discardableResult
    func open(url: URL, headers: [String: String]) -> Bool {
        shutdown()
        streamURL = url
        guard let p = IJKFFMoviePlayerController(contentURL: url, with: makeIJKOptions(headers: headers)) else {
            return false
        }
        p.scalingMode = IJKMPMovieScalingMode.aspectFit
        p.shouldAutoplay = true
        p.shouldShowHudView = false
        p.setPauseInBackground(false)
        // ijkplayer applies the rate live; there is no pitch
        // correction in IJKFFMoviePlayerController, so 2x/3x sound
        // higher-pitched — that is the engine's behaviour, not a bug.
        p.playbackRate = Float(rate)
        p.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.player = p
        registerIJKNotifications(for: p)
        p.prepareToPlay()
        p.play()
        return true
    }

    func play() {
        player?.play()
    }

    func pause() {
        player?.pause()
    }

    func seek(to seconds: Double) {
        player?.currentPlaybackTime = seconds
    }

    func shutdown() {
        NotificationCenter.default.removeObserver(self)
        if let p = player {
            p.view.removeFromSuperview()
            p.shutdown()
        }
        player = nil
    }

    // MARK: - Options (moved from NativePlayerViewController)

    private func makeIJKOptions(headers: [String: String]) -> IJKFFOptions {
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
        if let ua = headers["User-Agent"] {
            options.setFormatOptionValue(ua, forKey: "user_agent")
        }
        if let referer = headers["Referer"] {
            options.setFormatOptionValue("Referer: \(referer)\r\n", forKey: "headers")
        }
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

    // MARK: - Notifications -> events

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

    private func emit(_ event: PlayerBackendEvent) {
        DispatchQueue.main.async { [weak self] in
            self?.onEvent?(event)
        }
    }

    @objc private func ijkLoadStateChanged(_ note: Notification) {
        guard let obj = note.object as? IJKFFMoviePlayerController else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let p = self.player, obj === p else { return }
            if p.loadState.contains(.stalled) {
                self.emit(.stalled)
            }
        }
    }

    @objc private func ijkPlaybackStateChanged(_ note: Notification) {
        guard let obj = note.object as? IJKFFMoviePlayerController else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let p = self.player, obj === p else { return }
            switch p.playbackState {
            case .playing:
                self.emit(.playing)
            case .paused, .interrupted:
                self.emit(.paused)
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
            guard let self = self, let p = self.player, obj === p else { return }
            let reasonValue = (note.userInfo?[IJKMPMoviePlayerPlaybackDidFinishReasonUserInfoKey] as? NSNumber)?.intValue
            let reason = reasonValue.flatMap { IJKMPMovieFinishReason(rawValue: $0) }
            switch reason {
            case .playbackEnded:
                self.emit(.finished(.ended))
            case .playbackError:
                self.emit(.finished(.error))
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
            guard let self = self, let p = self.player, obj === p, p.isPreparedToPlay else { return }
            self.emit(.prepared)
            if !p.isPlaying() { p.play() }
        }
    }

    @objc private func ijkFirstFrameRendered(_ note: Notification) {
        guard let obj = note.object as? IJKFFMoviePlayerController else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.player === obj else { return }
            self.emit(.firstFrame)
        }
    }
}
