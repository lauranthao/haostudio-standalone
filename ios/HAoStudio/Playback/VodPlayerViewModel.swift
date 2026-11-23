// HAo Studio 2.0 — VOD player view model (S3, leg A).
//
// One of the four independent VOD pieces (P0-08): this file owns
// ONLY the player page's UI state + the coordination between the
// driver, the gesture layer, the settings sheet and the danmaku
// layer. The gesture layer (VodGestures), the settings sheet
// (VodSettingsSheet) and the danmaku layer (VodDanmakuLayer) each
// own their own state; this file never reaches into theirs, and
// they never reach into this one — they talk through the small
// method calls below.
//
// Mirroring follows MusicPlayerViewModel: driver state is mirrored
// into @Published properties through Combine sinks, never read
// off the driver in the view body (the view reads this view
// model, the view model reads the driver).
//
// Swift 5.0: completion handlers only, no async/await, no `any`.

import Combine
import Foundation
import SwiftUI

/// VOD player page view model: UI state + coordination. The driver
/// owns engines, queue and modes; this owns what the page shows.
final class VodPlayerViewModel: ObservableObject {
    /// The driver this page plays through (owned by the app, passed
    /// in — this view model never creates or owns a driver).
    let driver: VideoDriver

    // Mirrored driver state (Combine sinks, set up in init).
    @Published private(set) var isPlaying = false
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var currentEngine: VideoEngine?
    @Published private(set) var diagnostics: VideoPlaybackDiagnostics = .empty
    @Published private(set) var stallWarning = false
    @Published private(set) var isLoading = false
    @Published private(set) var currentEpisode: PlaybackItem?

    // Own UI state.
    /// Controls overlay visible. Auto-hides 3 s after the last
    /// interaction while playing.
    @Published private(set) var controlsVisible = true
    /// A scrub is in progress (progress bar dragged, not yet released).
    @Published private(set) var isScrubbing = false
    /// Drag target while scrubbing (what the bar shows); nil when
    /// not scrubbing (the bar shows `position`).
    @Published var scrubSeconds: Double?
    /// One-shot toast (seek failed, line switched, ...). The view
    /// clears it after showing.
    @Published private(set) var toast: String?
    /// Settings sheet presented.
    @Published var showSettings = false
    /// Episode picker presented.
    @Published var showEpisodes = false

    /// Gesture state (VodGestures owns the object; this view model
    /// holds the reference so the page wires one object).
    let gestures = VodGestureState()
    /// Danmaku layer state (VodDanmakuLayer owns the object).
    let danmaku = VodDanmakuLayerState()
    /// Settings state (VodSettingsSheet owns the struct; this view
    /// model holds the current value and persists it).
    @Published var settings = VodSettingsState.load()

    private var cancellables = Set<AnyCancellable>()
    private var autoHideWork: DispatchWorkItem?

    init(driver: VideoDriver) {
        self.driver = driver
        driver.$isPlaying.sink { [weak self] value in
            self?.isPlaying = value
            if value { self?.scheduleControlsAutoHide() }
        }.store(in: &cancellables)
        driver.$position.sink { [weak self] value in
            guard let self = self else { return }
            if !self.isScrubbing { self.position = value }
        }.store(in: &cancellables)
        driver.$duration.sink { [weak self] value in self?.duration = value }.store(in: &cancellables)
        driver.$currentEngine.sink { [weak self] value in self?.currentEngine = value }.store(in: &cancellables)
        driver.$diagnostics.sink { [weak self] value in self?.diagnostics = value }.store(in: &cancellables)
        driver.$stallWarning.sink { [weak self] value in self?.stallWarning = value }.store(in: &cancellables)
        driver.$isLoading.sink { [weak self] value in self?.isLoading = value }.store(in: &cancellables)
        driver.$currentEpisode.sink { [weak self] value in self?.currentEpisode = value }.store(in: &cancellables)
        gestures.onLongPressSpeedChanged = { [weak self] active in
            guard let self = self else { return }
            self.driver.setSpeed(active ? VodGestureConfig.longPressSpeed : self.settings.playbackSpeed)
        }
        gestures.onDoubleTapSeek = { [weak self] delta in
            guard let self = self else { return }
            self.seekBy(delta)
        }
        gestures.onSingleTap = { [weak self] in self?.toggleControls() }
        // Settings flow one way: the sheet edits the binding, the
        // sink applies every change to the driver + danmaku layer
        // + persistence. The sink also fires once on subscribe
        // with the loaded value, so the persisted fit/speed apply
        // from the first open (the driver never starts at a stale
        // default). `applySettings` only assigns — the sink does
        // the applying, so there is no assign-apply loop.
        $settings.sink { [weak self] value in
            self?.applySettingsToDriver(value)
        }.store(in: &cancellables)
    }

    deinit {
        autoHideWork?.cancel()
    }

    // MARK: - Transport

    func togglePlayPause() {
        if isPlaying { driver.pause() } else { driver.resume() }
        scheduleControlsAutoHide()
    }

    /// Seek by a relative amount (double-tap left/right).
    func seekBy(_ delta: Double) {
        let target = min(max(0, position + delta), duration > 0 ? duration : position + delta)
        seek(to: target)
    }

    /// Seek to an absolute position. On failure the driver has
    /// already republished the real position, so the bar rolls
    /// back on its own; this only adds the toast.
    func seek(to seconds: Double) {
        driver.seek(to: seconds) { [weak self] ok in
            guard let self = self else { return }
            if !ok {
                self.toast = "seek 未落到目标位置，已回到实际进度"
            }
        }
    }

    // MARK: - Scrubbing (progress-bar drag)

    func beginScrub() {
        isScrubbing = true
        scrubSeconds = position
        autoHideWork?.cancel()
    }

    func scrub(to seconds: Double) {
        scrubSeconds = min(max(0, seconds), duration > 0 ? duration : seconds)
    }

    /// Release the scrub: seek to the drag target. While the seek
    /// is in flight the bar keeps showing the target; on failure
    /// the driver republishes the real position and the bar rolls
    /// back, plus a toast.
    func endScrub() {
        let target = scrubSeconds ?? position
        isScrubbing = false
        scrubSeconds = nil
        seek(to: target)
        scheduleControlsAutoHide()
    }

    // MARK: - Controls visibility

    func toggleControls() {
        controlsVisible.toggle()
        if controlsVisible { scheduleControlsAutoHide() }
    }

    func showControls() {
        controlsVisible = true
        scheduleControlsAutoHide()
    }

    private func scheduleControlsAutoHide() {
        autoHideWork?.cancel()
        guard isPlaying else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.isPlaying, !self.isScrubbing else { return }
            self.controlsVisible = false
        }
        autoHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    // MARK: - Episodes / lines

    func switchLine(to line: PlayLine) {
        driver.switchLine(to: line)
        toast = "已切换线路：\(line.name)"
    }

    func playEpisode(at index: Int) {
        if driver.playEpisode(at: index) {
            showEpisodes = false
        }
    }

    func playNextEpisode() {
        _ = driver.playEpisode(at: driver.currentEpisodeIndex + 1)
    }

    func playPreviousEpisode() {
        _ = driver.playEpisode(at: driver.currentEpisodeIndex - 1)
    }

    // MARK: - Settings

    /// Apply settings state (called by the page, or by assigning
    /// `settings` directly): assigns the value; the `$settings`
    /// sink applies it to the driver.
    func applySettings(_ newValue: VodSettingsState) {
        settings = newValue
    }

    /// Push settings to the driver + danmaku layer + persistence.
    /// Called by the `$settings` sink on every change (including
    /// the initial loaded value on subscribe).
    private func applySettingsToDriver(_ value: VodSettingsState) {
        value.persist()
        driver.setVideoFit(value.videoFit)
        if !gestures.isLongPressSpeeding {
            driver.setSpeed(value.playbackSpeed)
        }
        danmaku.isEnabled = value.danmakuEnabled
        danmaku.opacity = value.danmakuOpacity
    }

    func clearToast() {
        toast = nil
    }
}
