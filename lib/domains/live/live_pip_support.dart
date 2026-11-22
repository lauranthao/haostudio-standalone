// iOS system Picture-in-Picture — item 15 (build 29, I group).
//
// Verification of the three kernels, done by reading the kernel
// sources (not by guessing from the package names). The verdicts
// below are the deliverable: which engine can do system PiP, which
// cannot, and why.
//
// | engine | verdict | evidence |
// |---|---|---|
// | AVPlayer (BetterPlayer) | POSSIBLE — needs a backend change | better_player_plus 1.4.1 ships `BetterPlayerController.enablePictureInPicture(GlobalKey)` + `isPictureInPictureSupported()` (video_player method channel `enablePictureInPicture`, AVPictureInPictureController underneath on iOS). The app's `AvPlayerBackend` (lib/core/player/kernel/avplayer_backend.dart) never calls either: it builds `BetterPlayer(controller:)` with `showControls: false` and exposes no PiP method on `PlayerBackend`, and `PlaybackSession` has no PiP entry point. Wiring it needs: a `PlayerBackend.enterPictureInPicture()` hook + the AVPlayer backend calling `enablePictureInPicture(_controller.betterPlayerGlobalKey)` + a room-page button. That change is in kernel files this group does not own — recorded as a gap, with the exact call named. Also note the format gate: AVPlayer cannot play FLV (the backend throws), so PiP on this engine only ever applies to HLS/MP4 rooms. |
// | MPV (media_kit / libmpv) | NOT POSSIBLE with the current stack | media_kit exposes no PiP API at all (no `pictureInPicture` / `enterPictureInPicture` anywhere in the vendored media_kit Player surface), and libmpv's iOS video output (`vo=libmpv`) renders into the app's own view — there is no AVPlayerLayer for AVPictureInPictureController to attach to. System PiP on iOS requires AVFoundation playback; mpv is not AVFoundation. No Dart-side change can fix that — it would need a native mpv->AVSampleBufferDisplayLayer bridge, which does not exist in this project. |
// | IJK (flv_lzc / fijkplayer) | NOT POSSIBLE with the current stack | fijkplayer exposes no PiP API (no picture-in-picture method on FijkPlayer or its iOS plugin), and like MPV it decodes with ffmpeg/ijkplayer, not AVFoundation — no AVPlayerLayer exists for the system PiP controller. Same native-bridge problem as MPV. |
//
// Consequence for the room: PiP is offered only when the active
// engine is AVPlayer AND the backend exposes it — today that is
// never, so the room's tools sheet shows the per-engine table
// honestly ("AVPlayer：需接线后可用；MPV/IJK：系统画中画不支持") instead
// of a dead button. When the kernel owner wires the AVPlayer hook,
// [pipAvailableFor] flips for `exo` with no live-domain change.

import '../../core/player/kernel/player_engine.dart';

/// PiP verdict for one engine.
enum LivePipVerdict {
  /// Works once the (small, named) backend wiring lands.
  needsBackendWiring,

  /// Cannot work on this stack — no AVFoundation playback underneath.
  unsupported,
}

/// The per-engine verdict, with the reason in one line.
class LivePipSupport {
  const LivePipSupport({required this.verdict, required this.reason});

  final LivePipVerdict verdict;

  /// Human-readable reason, shown in the room's tools sheet.
  final String reason;
}

/// Verdict for [engine]. Today AVPlayer is [LivePipVerdict.needsBackendWiring]
/// (BetterPlayer has the API, the backend never calls it); MPV and
/// IJK are [LivePipVerdict.unsupported].
LivePipSupport pipSupportFor(PlayerEngine engine) {
  switch (engine) {
    case PlayerEngine.exo:
      return const LivePipSupport(
        verdict: LivePipVerdict.needsBackendWiring,
        reason: 'AVPlayer：BetterPlayer 自带画中画，需在 AVPlayer 内核接通 enablePictureInPicture 后可用（仅 HLS/MP4 房间，FLV 播不了）',
      );
    case PlayerEngine.mediaKit:
      return const LivePipSupport(
        verdict: LivePipVerdict.unsupported,
        reason: 'MPV：media_kit 没有画中画接口，libmpv 不是 AVFoundation 播放，系统画中画接不上',
      );
    case PlayerEngine.fijk:
      return const LivePipSupport(
        verdict: LivePipVerdict.unsupported,
        reason: 'IJK：fijkplayer 没有画中画接口，ijk 解码不是 AVFoundation 播放，系统画中画接不上',
      );
  }
}

/// Whether the room can offer a working PiP button right now.
/// Today always false (the AVPlayer wiring has not landed); the
/// function exists so the tools sheet flips automatically when it
/// does — [pipWired] is set by the kernel owner, never guessed here.
bool pipAvailableNow({required bool pipWired}) => pipWired;
