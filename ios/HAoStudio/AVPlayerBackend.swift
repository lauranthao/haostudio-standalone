// AVPlayerBackend — the system player (AVPlayer + AVPlayerLayer) behind
// the PlayerBackend protocol. This is Pure Live's 'exo' slot on iOS:
// BetterPlayer is ExoPlayer on Android and AVPlayer on iOS, so the
// "EXOPlayer" chen asked for IS this on iOS — ExoPlayer itself cannot
// run on iOS (Android-only).
//
// What it plays: HLS (.m3u8) and MP4 — i.e. Bilibili live (HLS), VOD
// movies/episodes (HLS/MP4). What it CANNOT play: FLV (Huya / Douyu
// live are FLV) — AVFoundation has no FLV demuxer. The player UI checks
// PlayerKernel.supports(url:) before opening and shows a clear message
// for FLV instead of a generic failure; the retry button then switches
// the engine to MPV and retries.
// Background audio: AVPlayer keeps its audio going in the background
// with the app's .playback audio session (same as ijkplayer's
// setPauseInBackground(false)); the video layer simply stops drawing.

import UIKit
import AVFoundation

// Container that keeps the player layer filling it on every layout
// pass (the player sizes the container to its videoView bounds).
private final class AVPlayerContainerView: UIView {
    var playerLayer: AVPlayerLayer?
    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer?.frame = bounds
    }
}

final class AVPlayerBackend: NSObject, PlayerBackend {
    var onEvent: ((PlayerBackendEvent) -> Void)?
    var onVideoSize: ((CGSize) -> Void)?

    private let player = AVPlayer()
    private let playerLayer = AVPlayerLayer()
    private let containerView = AVPlayerContainerView()

    private var rate: Double = 1
    private var currentURL: URL?
    private var didEmitFirstFrame = false
    private var didEmitPrepared = false

    private var timeControlObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private var itemBufferEmptyObservation: NSKeyValueObservation?
    private var itemLikelyObservation: NSKeyValueObservation?

    override init() {
        super.init()
        containerView.backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
        playerLayer.player = player
        containerView.playerLayer = playerLayer
        containerView.layer.addSublayer(playerLayer)
        playerLayer.frame = containerView.bounds
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            self?.timeControlChanged()
        }
    }

    var view: UIView { containerView }

    var isPlaying: Bool { player.timeControlStatus == .playing }

    var currentTime: Double {
        let t = player.currentTime().seconds
        return t.isFinite ? t : 0
    }

    var duration: Double {
        guard let item = player.currentItem else { return Double.nan }
        let d = item.duration.seconds
        return d.isFinite ? d : Double.nan
    }

    var isPrepared: Bool { player.currentItem?.status == .readyToPlay }

    var playbackRate: Double {
        get { rate }
        set {
            rate = newValue
            // AVPlayer.play() resumes at defaultRate (1.0); keep the
            // chosen speed by driving play() through rate instead.
            if player.timeControlStatus == .playing {
                player.rate = Float(newValue)
            }
        }
    }

    @discardableResult
    func open(url: URL, headers: [String: String]) -> Bool {
        shutdown()
        currentURL = url
        didEmitFirstFrame = false
        didEmitPrepared = false
        let asset = AVURLAsset(url: url, options: [AVURLAssetHTTPHeaderFieldsKey: headers])
        let item = AVPlayerItem(asset: asset)
        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] _, _ in
            self?.itemStatusChanged()
        }
        itemBufferEmptyObservation = item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] _, _ in
            self?.bufferChanged()
        }
        itemLikelyObservation = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] _, _ in
            self?.bufferChanged()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(itemDidPlayToEndTime), name: .AVPlayerItemDidPlayToEndTime, object: item)
        NotificationCenter.default.addObserver(self, selector: #selector(itemFailedToPlayToEndTime(_:)), name: .AVPlayerItemFailedToPlayToEndTime, object: item)
        player.replaceCurrentItem(with: item)
        player.rate = Float(rate)
        return true
    }

    func play() {
        player.rate = Float(rate)
    }

    func pause() {
        player.pause()
    }

    func seek(to seconds: Double) {
        let target = CMTimeMakeWithSeconds(seconds, preferredTimescale: 1000)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func shutdown() {
        NotificationCenter.default.removeObserver(self)
        itemStatusObservation = nil
        itemBufferEmptyObservation = nil
        itemLikelyObservation = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentURL = nil
    }

    // MARK: - State mapping

    private func emit(_ event: PlayerBackendEvent) {
        DispatchQueue.main.async { [weak self] in
            self?.onEvent?(event)
        }
    }

    private func timeControlChanged() {
        guard player.currentItem != nil else { return }
        switch player.timeControlStatus {
        case .playing:
            if !didEmitFirstFrame {
                didEmitFirstFrame = true
                emit(.firstFrame)
                if let size = naturalSize() { onVideoSize?(size) }
            }
            emit(.playing)
        case .paused:
            emit(.paused)
        case .waitingToPlayAtSpecifiedRate:
            emit(.stalled)
        @unknown default:
            break
        }
    }

    private func itemStatusChanged() {
        guard let item = player.currentItem else { return }
        switch item.status {
        case .readyToPlay:
            if !didEmitPrepared {
                didEmitPrepared = true
                emit(.prepared)
            }
            if let size = naturalSize() { onVideoSize?(size) }
        case .failed:
            emit(.finished(.error))
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    private func bufferChanged() {
        guard let item = player.currentItem else { return }
        // Buffer ran dry while playing: the clock-based stall
        // detection in the player owns the recovery, but the spinner
        // state also wants to know (pre-start only, per the player).
        if item.isPlaybackBufferEmpty, !item.isPlaybackLikelyToKeepUp, player.timeControlStatus != .paused {
            emit(.stalled)
        }
    }

    private func naturalSize() -> CGSize? {
        guard let track = player.currentItem?.asset.tracks(withMediaType: .video).first else { return nil }
        let size = track.naturalSize.applying(track.preferredTransform)
        let w = abs(size.width), h = abs(size.height)
        guard w > 0, h > 0 else { return nil }
        return CGSize(width: w, height: h)
    }

    @objc private func itemDidPlayToEndTime(_ note: Notification) {
        emit(.finished(.ended))
    }

    @objc private func itemFailedToPlayToEndTime(_ note: Notification) {
        emit(.finished(.error))
    }
}
