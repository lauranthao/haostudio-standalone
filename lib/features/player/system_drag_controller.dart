// Shared vertical-drag brightness/volume control (P1-U2).
//
// The live room and the VOD player each had their own copy of this
// logic — same idea, different sensitivity (live mapped a full surface
// height to only 25% of the range; VOD mapped 300 px to the full
// range) and different HUD timing. One controller now serves both
// players: same seed, same HUD, same sensitivity.
//
// Sensitivity (fixed): 300 px of vertical travel = the full 0-1 range
// (the VOD reference implementation). The live room's drag therefore
// feels faster than before — chen judges it on his phone.
//
// Side: left half brightness, right half volume (Pure Live
// PlayerGestureLayer). The side follows the finger: sliding across
// the middle mid-drag switches sides, seeding from that side's cache
// so the value never jumps.
//
// What the controller owns: the per-side level caches, the drag-start
// seed read (brightness is re-read live from the channel, 300 ms
// cap; volume comes from the live volumeChanges stream), the drag
// value notifier, the HUD side notifier (null = HUD hidden), the HUD
// linger timer, and the SystemVolume subscription.
//
// What the page still owns: WHERE the drag may start (gesture guards
// — system home-gesture zone, locked controls, failed/ended player),
// WHAT the HUD looks like (live pill vs VOD hint card), and WHEN the
// brightness is handed back to the system (dispose + backgrounding —
// the page's lifecycle observer keeps calling ScreenBrightness.reset();
// brightness/volume exist ONLY inside a player, never elsewhere).

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/widgets.dart';

import '../../core/native/system_volume.dart';
import 'screen_brightness.dart';

/// Which half of the screen a vertical drag is controlling.
enum SystemDragSide { brightness, volume }

class SystemDragController {
  /// [systemVolume] is injectable for tests; production passes none.
  /// [hudLinger] is how long the HUD stays up after the last drag
  /// tick / drag end / external volume change (live 1 s, VOD 800 ms).
  SystemDragController({
    SystemVolume? systemVolume,
    this.hudLinger = const Duration(milliseconds: 800),
  }) : _systemVolume = systemVolume ?? SystemVolume();

  /// Vertical travel for the full 0-1 range (VOD reference value).
  static const double kFullRangePixels = 300;

  final Duration hudLinger;
  final SystemVolume _systemVolume;
  StreamSubscription<double>? _volumeSub;

  /// The drag HUD value (brightness or volume, 0-1). A ValueNotifier,
  /// not a setState field: pointer ticks arrive at ~60-120 Hz and the
  /// HUD is a small subtree — rebuilding the whole player page per
  /// tick is what made the drag feel choppy (chen 2026-11-20).
  final ValueNotifier<double> value = ValueNotifier<double>(0);

  /// The HUD side, or null when the HUD is hidden. Pages build their
  /// HUD inside a ValueListenableBuilder on this — no setState per
  /// tick, no page rebuild.
  final ValueNotifier<SystemDragSide?> side =
      ValueNotifier<SystemDragSide?>(null);

  /// Per-side level caches. Volume stays live through the
  /// volumeChanges stream (+ an init-time read); brightness through
  /// an init-time read, the drag-start re-read, and the drag itself.
  double brightnessLevel = 0.5;
  double volumeLevel = 1.0;

  bool _seedReady = false;
  bool _disposed = false;
  Timer? _hudTimer;

  /// Start-generation: end/cancel bumps it, so a drag-start seed
  /// that lands AFTER the drag already ended is dropped instead of
  /// popping the HUD up with no drag behind it (pre-existing race
  /// in both players: the seed await outlived the gesture).
  int _seedEpoch = 0;

  bool get seedReady => _seedReady;

  bool get isBrightness => side.value == SystemDragSide.brightness;

  /// Start the volume stream + seed the per-side caches (best
  /// effort). Call from the page's initState.
  void init() {
    _volumeSub = _systemVolume.volumeChanges.listen(_onExternalVolume);
    unawaited(_systemVolume.getVolume().then((v) => volumeLevel = v));
    unawaited(
      ScreenBrightness.getBrightness().then((v) => brightnessLevel = v),
    );
  }

  /// Re-read the CURRENT brightness as the next drag's seed — never
  /// set it. Used on foreground return: whatever the user picked in
  /// Control Center while backgrounded is the brightness now.
  Future<void> refreshBrightnessSeed() async {
    try {
      brightnessLevel =
          (await ScreenBrightness.getBrightness().timeout(
            const Duration(milliseconds: 300),
          )).clamp(0.0, 1.0);
    } catch (_) {}
  }

  /// Drag start: pick the side from the x position, seed the value
  /// (brightness re-read live from the channel — a stale seed would
  /// jump the screen back to the old level on the first move; volume
  /// needs no re-read, its cache is live), show the HUD. Updates
  /// arriving before the seed lands are dropped ([seedReady]).
  /// No-op when the surface has no width.
  ///
  /// Windows has no screen-brightness API and no brightness UI, so
  /// there is no brightness side there: every vertical drag is
  /// volume, whichever half it starts on. A left-half drag doing
  /// nothing would be a dead gesture, and a brightness HUD on
  /// Windows would be fake — volume on both halves is neither.
  Future<void> startDrag(Offset localPosition, Size size) async {
    _seedReady = false;
    if (size.width <= 0) return;
    final epoch = ++_seedEpoch;
    final isBrightnessSide =
        !Platform.isWindows && localPosition.dx <= size.width / 2;
    var seed = isBrightnessSide ? brightnessLevel : volumeLevel;
    if (isBrightnessSide) {
      try {
        seed = await ScreenBrightness.getBrightness().timeout(
          const Duration(milliseconds: 300),
        );
      } catch (_) {}
      brightnessLevel = seed.clamp(0.0, 1.0);
      seed = brightnessLevel;
    }
    if (_disposed || epoch != _seedEpoch) return;
    side.value =
        isBrightnessSide ? SystemDragSide.brightness : SystemDragSide.volume;
    value.value = seed;
    _seedReady = true;
  }

  /// Drag update: apply the vertical delta at the shared sensitivity.
  /// A side change mid-drag re-seeds from the new side's cache (no
  /// channel read) so the value continues from that side's real level
  /// instead of jumping. Tiny ticks are dropped. On Windows the side
  /// never flips to brightness (see [startDrag]): a drag wandering
  /// into the left half keeps doing volume.
  void updateDrag(DragUpdateDetails details, Size size) {
    if (!_seedReady) return;
    if (size.height <= 0) return;
    final delta = details.delta;
    if (delta.distance < 0.5) return;
    final isBrightnessSide =
        !Platform.isWindows && details.localPosition.dx <= size.width / 2;
    if (isBrightness != isBrightnessSide) {
      side.value =
          isBrightnessSide
              ? SystemDragSide.brightness
              : SystemDragSide.volume;
      value.value = isBrightnessSide ? brightnessLevel : volumeLevel;
    }
    _showHud();
    final target = (value.value - delta.dy / kFullRangePixels).clamp(
      0.0,
      1.0,
    );
    if ((target - value.value).abs() <= 0.001) return;
    // HUD first, through the notifier only — the page is NOT rebuilt
    // per tick. The platform call is coalesced inside
    // SystemVolume.setVolume, so a fast drag sends the latest value
    // instead of a queue of stale ones.
    value.value = target;
    if (isBrightnessSide) {
      brightnessLevel = target;
      unawaited(ScreenBrightness.setBrightness(target));
    } else {
      volumeLevel = target;
      unawaited(_systemVolume.setVolume(target));
    }
  }

  /// Drag end: the HUD lingers [hudLinger], then hides.
  void endDrag() {
    _seedReady = false;
    ++_seedEpoch;
    _armHudTimer();
  }

  /// Set the system volume from outside a drag (Windows keyboard /
  /// mouse wheel): applies the level, shows the volume HUD for the
  /// linger, then hides it. The drag HUD is the only volume readout
  /// in the players, so a key/wheel change without it would be
  /// silent. [volume] is clamped to 0-1.
  Future<void> setVolumeLevel(double volume) async {
    final next = volume.clamp(0.0, 1.0);
    volumeLevel = next;
    value.value = next;
    side.value = SystemDragSide.volume;
    _armHudTimer();
    await _systemVolume.setVolume(next);
  }

  /// Drag cancelled (lost the gesture arena): hide the HUD at once.
  void cancelDrag() {
    _seedReady = false;
    ++_seedEpoch;
    _hideHudNow();
  }

  /// Hardware keys / Control Center moved the system volume: show
  /// the real value in the drag HUD (same linger as a drag end).
  /// Ignored while a brightness HUD is showing — a volume change
  /// must not hijack it. Own-set echoes never reach here
  /// (SystemVolume suppresses them).
  void _onExternalVolume(double volume) {
    if (_disposed) return;
    volumeLevel = volume;
    if (side.value == SystemDragSide.brightness) return;
    value.value = volume;
    side.value = SystemDragSide.volume;
    _armHudTimer();
  }

  void _showHud() {
    _armHudTimer();
  }

  void _armHudTimer() {
    _hudTimer?.cancel();
    _hudTimer = Timer(hudLinger, () {
      if (_disposed) return;
      side.value = null;
    });
  }

  void _hideHudNow() {
    _hudTimer?.cancel();
    side.value = null;
  }

  void dispose() {
    _disposed = true;
    _hudTimer?.cancel();
    _volumeSub?.cancel();
    _systemVolume.dispose();
    value.dispose();
    side.dispose();
  }
}
