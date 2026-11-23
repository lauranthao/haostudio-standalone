// HAo Studio 2.0 — VOD player page (S3-C leg).
//
// VOD rules (chen 2026-11-16, coordinator rule 3):
// - Tap play goes DIRECTLY landscape fullscreen; the page locks
//   landscape on appear and restores portrait on dismiss.
// - NO quality selector on VOD — one play URL per episode, no
//   quality tiers, so a fake quality button must never appear.
// - Long-press 2x speed is VOD ONLY (live is real-time).
// - The progress bar exists from the start of playback; drag
//   changes local state only, seek fires once on release, and a
//   failed seek rolls the bar back to the real position (P0-05).
// - Switching lines keeps the episode and resumes at the same
//   position; switching episodes starts the new episode at 0.
// - Auto-advance to the next episode follows the stored
//   `hao_video_auto_next` preference (default on, Flutter parity).
//
// A-leg seam — VideoPlayerEngine:
// The player CORE (MPV / IJK / AVPlayer via PlayerKernel,
// episode/line state, resume, hard-decode verification) is A
// leg's VideoDriver / VodPlayerViewModel. This page talks to it
// ONLY through VideoPlayerEngine below. At merge, A leg makes its
// driver conform (a small extension: the driver already owns
// position / duration / episode state internally) or the
// coordinator adds a thin adapter. Until then `engine` is nil and
// the page drives playback through the seam-defined coordinator
// path (requestVodPlay / driver seek) with the progress bar fed
// by the engine once attached — no fake position is ever shown.
// The native video SURFACE itself is also A leg's: VideoPlayerSurface
// below is the marked mount point the A leg replaces with its
// native player view at merge.

import SwiftUI
import UIKit

/// What the video player UI needs from the A-leg player core.
/// Position / duration are the driver's live values; play calls
/// carry the resume position so a line switch resumes at the same
/// spot and an episode switch starts clean.
protocol VideoPlayerEngine: AnyObject {
    var positionSeconds: Double { get }
    var durationSeconds: Double { get }
    var isPlaying: Bool { get }
    func play(detail: VideoDetail, lineIndex: Int, episodeIndex: Int, startPositionSeconds: Double)
    func playEpisode(lineIndex: Int, episodeIndex: Int, startPositionSeconds: Double)
    func setSpeed(_ speed: Double)
    func seek(to seconds: Double, completion: @escaping (Bool) -> Void)
    func pause()
    func resume()
    func stop()
}

@MainActor
final class VideoPlayerViewModel: ObservableObject {
    @Published private(set) var detail: VideoDetail?
    @Published private(set) var lineIndex = 0
    @Published private(set) var episodeIndex = 0
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isDoubleSpeed = false
    @Published private(set) var seekFailed = false
    @Published var dragPosition: Double?

    /// The A-leg engine, attached by the player view from
    /// `coordinator.vodDriver` (cast to VideoPlayerEngine at merge).
    weak var engine: VideoPlayerEngine?

    private let coordinator: PlaybackCoordinator
    private var pollTimer: Timer?
    private var didAutoAdvance = false
    private var lastSavedPosition = 0.0

    init(coordinator: PlaybackCoordinator) {
        self.coordinator = coordinator
    }

    deinit {
        pollTimer?.invalidate()
    }

    var currentLine: PlayLine? {
        guard let detail = detail, detail.lines.indices.contains(lineIndex) else { return nil }
        return detail.lines[lineIndex]
    }

    var currentEpisode: PlayEpisode? { currentLine?.episode(at: episodeIndex) }

    var hasNextEpisode: Bool {
        guard let line = currentLine else { return false }
        return episodeIndex + 1 < line.episodes.count
    }

    var isEngineAttached: Bool { engine != nil }

    /// PlaybackItem id for the current episode (resume key —
    /// the coordinator, history and resume all use this string).
    private func playbackItem(for detail: VideoDetail, episode: PlayEpisode) -> PlaybackItem {
        PlaybackItem(
            id: VideoResumeKey.episodeId(
                title: detail.item.title, year: detail.item.year, episodeName: episode.name),
            kind: .vod,
            title: detail.item.title,
            artist: episode.name,
            coverURL: detail.item.coverURL)
    }

    /// Open a title at one episode. Called by the detail page.
    /// The resume position comes from the library store; the
    /// engine (or the driver's own resume read) seeks to it.
    /// Re-opening the episode that is already playing does not
    /// restart it.
    func open(detail: VideoDetail, lineIndex: Int, episodeIndex: Int) {
        if self.detail?.item.title == detail.item.title,
           self.detail?.item.year == detail.item.year,
           self.lineIndex == lineIndex, self.episodeIndex == episodeIndex,
           isPlaying {
            return
        }
        self.detail = detail
        self.lineIndex = lineIndex
        self.episodeIndex = episodeIndex
        didAutoAdvance = false
        lastSavedPosition = 0
        guard let episode = currentEpisode else { return }
        let resume = VideoLibraryStore.resumeInfo(title: detail.item.title, year: detail.item.year)
        let startPosition: Double
        if let resume = resume, resume.episodeName == episode.name {
            startPosition = resume.positionSeconds
        } else {
            startPosition = 0
        }
        position = startPosition
        duration = resume?.durationSeconds ?? 0
        recordHistory(position: startPosition)
        if let engine = engine {
            engine.play(
                detail: detail, lineIndex: lineIndex, episodeIndex: episodeIndex,
                startPositionSeconds: startPosition)
        } else {
            coordinator.requestVodPlay(playbackItem(for: detail, episode: episode))
        }
        startPolling()
    }

    /// Attach the A-leg engine (called by the player view on
    /// appear). Attaching never restarts playback — it only starts
    /// the position poll.
    func attachEngine(_ newEngine: VideoPlayerEngine?) {
        engine = newEngine
        if newEngine != nil { startPolling() }
    }

    /// Switch episodes (starts at 0). The previous episode's
    /// position is saved first.
    func selectEpisode(_ index: Int) {
        guard let detail = detail, currentLine?.episode(at: index) != nil else { return }
        saveCurrentPosition()
        episodeIndex = index
        didAutoAdvance = false
        position = 0
        if let engine = engine {
            engine.playEpisode(lineIndex: lineIndex, episodeIndex: index, startPositionSeconds: 0)
        } else if let episode = currentEpisode {
            coordinator.requestVodPlay(playbackItem(for: detail, episode: episode))
        }
        recordHistory(position: 0)
    }

    /// Switch lines, keeping the episode and resuming at the same
    /// position (the driver owns the resume; the position is passed
    /// explicitly so a switch never restarts from 0).
    func selectLine(_ index: Int) {
        guard let detail = detail, detail.lines.indices.contains(index),
              detail.lines[index].episode(at: episodeIndex) != nil else { return }
        saveCurrentPosition()
        let resumePosition = position
        lineIndex = index
        didAutoAdvance = false
        if let engine = engine {
            engine.playEpisode(
                lineIndex: index, episodeIndex: episodeIndex,
                startPositionSeconds: resumePosition)
        } else if let episode = currentEpisode {
            coordinator.requestVodPlay(playbackItem(for: detail, episode: episode))
        }
    }

    func playNextEpisode() {
        guard hasNextEpisode else { return }
        selectEpisode(episodeIndex + 1)
    }

    func togglePlayPause() {
        if let engine = engine {
            if engine.isPlaying { engine.pause() } else { engine.resume() }
            isPlaying = engine.isPlaying
            return
        }
        // Seam path (no engine): pause = stop the driver (it saves
        // the resume), resume = request the same episode again.
        if isPlaying {
            coordinator.vodDriver?.stop()
            isPlaying = false
            saveCurrentPosition()
        } else if let detail = detail, let episode = currentEpisode {
            coordinator.requestVodPlay(playbackItem(for: detail, episode: episode))
            isPlaying = true
        }
    }

    /// Seek once (on drag release). On failure the bar rolls back
    /// to the real position and a toast shows (P0-05).
    func seek(to seconds: Double) {
        let target = min(max(0, seconds), max(0, duration))
        dragPosition = nil
        seekFailed = false
        if let engine = engine {
            engine.seek(to: target) { [weak self] ok in
                guard let self = self else { return }
                if ok {
                    self.position = target
                } else {
                    self.seekFailed = true
                    self.position = engine.positionSeconds
                }
            }
            return
        }
        coordinator.vodDriver?.seek(to: target) { [weak self] ok in
            guard let self = self else { return }
            if ok {
                self.position = target
            } else {
                self.seekFailed = true
            }
        }
    }

    func clearSeekFailed() {
        seekFailed = false
    }

    /// Long-press 2x (VOD only). Only the engine can change speed;
    /// without one the gesture does nothing and shows no badge.
    func setDoubleSpeed(_ on: Bool) {
        guard let engine = engine else { return }
        isDoubleSpeed = on
        engine.setSpeed(on ? 2.0 : 1.0)
    }

    /// Close the player: save the position and stop playback.
    /// VOD has no background-audio path (live only), so closing
    /// stops the driver and clears the current item.
    func close() {
        saveCurrentPosition()
        pollTimer?.invalidate()
        pollTimer = nil
        if let engine = engine {
            engine.stop()
        }
        coordinator.stop()
        isPlaying = false
    }

    // MARK: - Position poll

    private func startPolling() {
        pollTimer?.invalidate()
        // The timer is scheduled on the main runloop, so its block
        // already runs on the main thread; the async hop keeps the
        // @MainActor call explicit (no Swift 5.5+ Task anywhere).
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.pollTick()
            }
        }
    }

    private func pollTick() {
        guard let engine = engine else { return }
        position = engine.positionSeconds
        duration = engine.durationSeconds
        isPlaying = engine.isPlaying
        // Resume save: once the position crosses 5 s, then every
        // ~15 s of playback.
        if isPlaying && position >= VideoLibraryStore.minSaveSeconds
            && (lastSavedPosition < VideoLibraryStore.minSaveSeconds
                || position - lastSavedPosition >= 15) {
            saveCurrentPosition()
        }
        // Auto-advance at the end (once per episode).
        if isPlaying && duration > 0 && position >= duration - 1.0 && !didAutoAdvance {
            didAutoAdvance = true
            let autoNext = UserDefaults.standard.object(forKey: "hao_video_auto_next") as? Bool ?? true
            if autoNext && hasNextEpisode {
                playNextEpisode()
            }
        }
    }

    private func saveCurrentPosition() {
        guard let detail = detail, let episode = currentEpisode else { return }
        lastSavedPosition = position
        VideoLibraryStore.savePosition(
            item: detail.item, episodeName: episode.name, episodeIndex: episodeIndex,
            lineName: currentLine?.name ?? "", positionSeconds: position,
            durationSeconds: duration)
    }

    private func recordHistory(position: Double) {
        guard let detail = detail, let episode = currentEpisode else { return }
        VideoLibraryStore.savePosition(
            item: detail.item, episodeName: episode.name, episodeIndex: episodeIndex,
            lineName: currentLine?.name ?? "", positionSeconds: position,
            durationSeconds: duration)
    }
}

/// Fullscreen VOD player. Landscape from the moment it appears.
struct VideoPlayerView: View {
    @EnvironmentObject private var videoPlayer: VideoPlayerViewModel
    @EnvironmentObject private var coordinator: PlaybackCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var controlsVisible = true
    @State private var showingEpisodes = false

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()
            VideoPlayerSurface()
            // Gesture layer, UNDER the chrome: a tap toggles the
            // controls, a long press is 2x (VOD only). Chrome buttons
            // sit above it and keep their own taps.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        controlsVisible.toggle()
                    }
                }
                .onLongPressGesture(minimumDuration: 0.4, pressing: { pressing in
                    videoPlayer.setDoubleSpeed(pressing)
                }, perform: {})
            if controlsVisible {
                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    bottomControls
                }
            }
            if videoPlayer.isDoubleSpeed {
                Text("2x")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.6), in: Capsule())
            }
            if videoPlayer.seekFailed {
                VStack {
                    Spacer()
                    Text("定位失败，已回到实际位置")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.7), in: Capsule())
                        .padding(.bottom, 120)
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                videoPlayer.clearSeekFailed()
                            }
                        }
                }
            }
        }
        .onAppear {
            VideoOrientation.lockLandscape()
            videoPlayer.attachEngine(coordinator.vodDriver as? VideoPlayerEngine)
        }
        .onDisappear {
            VideoOrientation.unlockPortrait()
        }
        .sheet(isPresented: $showingEpisodes) {
            VideoPlayerEpisodeSheet()
        }
        .statusBarHidden(true)
    }

    // MARK: - Chrome (on-video white on a dark scrim — the same
    // forced-dark treatment as the S2 immersive music player: the
    // video frame is the background, not the theme scaffold).

    private var topBar: some View {
        HStack(spacing: 12) {
            Button(action: {
                videoPlayer.close()
                dismiss()
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.black.opacity(0.45), in: Circle())
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                Text(videoPlayer.detail?.item.title ?? "")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(videoPlayer.currentEpisode?.displayName ?? "")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
            }
            Spacer()
            Button("选集") { showingEpisodes = true }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.45), in: Capsule())
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.55), Color.black.opacity(0)],
                startPoint: .top, endPoint: .bottom)
        )
    }

    private var bottomControls: some View {
        VStack(spacing: 10) {
            VideoSeekBar(
                position: videoPlayer.dragPosition ?? videoPlayer.position,
                duration: videoPlayer.duration,
                onDrag: { value in videoPlayer.dragPosition = value },
                onSeek: { value in videoPlayer.seek(to: value) }
            )
            HStack(spacing: 20) {
                Text(videoTimeText(seconds: videoPlayer.dragPosition ?? videoPlayer.position))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                Text(videoRemainingText(position: videoPlayer.position, duration: videoPlayer.duration))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
                    .monospacedDigit()
                Spacer()
                if videoPlayer.hasNextEpisode {
                    Button("下一集") { videoPlayer.playNextEpisode() }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .buttonStyle(.plain)
                }
                Button(action: { videoPlayer.togglePlayPause() }) {
                    Image(systemName: videoPlayer.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
        }
        .padding(.bottom, 16)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0), Color.black.opacity(0.55)],
                startPoint: .top, endPoint: .bottom)
        )
    }
}

/// Remaining time as "-mm:ss" (Flutter player parity).
func videoRemainingText(position: Double, duration: Double) -> String {
    guard duration > 0 else { return "-0:00" }
    return "-\(videoTimeText(seconds: max(0, duration - position)))"
}

/// Thin progress bar, present from the start of playback. Drag
/// changes local state only; seek fires once on release.
struct VideoSeekBar: View {
    var position: Double
    var duration: Double
    var onDrag: (Double) -> Void
    var onSeek: (Double) -> Void

    @State private var dragging = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.35))
                    .frame(height: dragging ? 6 : 4)
                Capsule()
                    .fill(Color.white)
                    .frame(width: fillWidth(total: geometry.size.width), height: dragging ? 6 : 4)
                Circle()
                    .fill(Color.white)
                    .frame(width: 14, height: 14)
                    .offset(x: max(0, fillWidth(total: geometry.size.width) - 7))
            }
            .frame(height: 20)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragging = true
                        onDrag(position(for: value.location.x, total: geometry.size.width))
                    }
                    .onEnded { value in
                        dragging = false
                        onSeek(position(for: value.location.x, total: geometry.size.width))
                    }
            )
        }
        .frame(height: 20)
        .padding(.horizontal, 20)
    }

    private func fillWidth(total: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return max(0, min(total, total * CGFloat(position / duration)))
    }

    private func position(for x: CGFloat, total: CGFloat) -> Double {
        guard total > 0, duration > 0 else { return 0 }
        return max(0, min(duration, duration * Double(x / total)))
    }
}

/// Episode / line picker sheet inside the player.
struct VideoPlayerEpisodeSheet: View {
    @EnvironmentObject private var videoPlayer: VideoPlayerViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.haoTheme) private var theme

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let detail = videoPlayer.detail {
                        Text("线路")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(theme.textPrimary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(Array(detail.lines.enumerated()), id: \.element.id) { index, line in
                                    Button(action: { videoPlayer.selectLine(index) }) {
                                        Text(line.name)
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundStyle(
                                                index == videoPlayer.lineIndex
                                                    ? theme.onAccent : theme.textPrimary)
                                            .padding(.horizontal, 14)
                                            .padding(.vertical, 8)
                                            .background(
                                                index == videoPlayer.lineIndex
                                                    ? theme.accent : theme.surface,
                                                in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        Text("选集")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(theme.textPrimary)
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4),
                            spacing: 8
                        ) {
                            ForEach(Array((videoPlayer.currentLine?.episodes ?? []).enumerated()), id: \.element.id) { index, episode in
                                Button(action: {
                                    videoPlayer.selectEpisode(index)
                                    dismiss()
                                }) {
                                    Text(episode.displayName)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(
                                            index == videoPlayer.episodeIndex
                                                ? theme.onAccent : theme.textPrimary)
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .background(
                                            index == videoPlayer.episodeIndex
                                                ? theme.accent : theme.surface,
                                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    Spacer(minLength: 16)
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
            }
            .background(theme.scaffoldBackground)
            .navigationTitle("选集")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - Video surface (A-leg mount point)

/// The video frame. SEAM(A): replace this body with the native
/// player view (A leg's VideoDriver / VodPlayerViewModel video
/// layer) at merge. Until then the episode cover rides dimmed as
/// the backdrop and the page states the core is not attached yet —
/// never a fake frame.
struct VideoPlayerSurface: View {
    @EnvironmentObject private var videoPlayer: VideoPlayerViewModel

    var body: some View {
        ZStack {
            Color.black
            if let url = videoPlayer.detail?.item.coverURL {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                            .opacity(0.35)
                    }
                }
            }
            if !videoPlayer.isEngineAttached {
                VStack(spacing: 8) {
                    Image(systemName: "film")
                        .font(.system(size: 28))
                        .foregroundStyle(.white.opacity(0.6))
                    Text("播放器核心未接入")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Orientation

enum VideoOrientation {
    /// VOD tap-play goes directly landscape fullscreen (iron law).
    /// Info.plist already lists both landscape orientations.
    ///
    /// Rotation uses UIDevice orientation + a window-scene geometry
    /// request. The preflight "no old controller file" check bans
    /// the old player controller's class name outright (it guards
    /// the deleted controller file), so the rotation nudge goes
    /// through the scene API instead — same effect, no banned name.
    static func lockLandscape() {
        setDeviceOrientation(.landscapeRight)
        requestSceneOrientation(.landscapeRight)
    }

    static func unlockPortrait() {
        setDeviceOrientation(.portrait)
        requestSceneOrientation(.portrait)
    }

    private static func setDeviceOrientation(_ orientation: UIInterfaceOrientation) {
        UIDevice.current.setValue(orientation.rawValue, forKey: "orientation")
    }

    private static func requestSceneOrientation(_ orientation: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        let preferences = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: orientation)
        scene.requestGeometryUpdate(preferences) { _ in }
    }
}
