// Danmaku occlusion avoidance (1.1.6, REDUCED version) — the
// controller + the pure logic it runs on.
//
// What this is: Vision person segmentation over low-frequency MPV
// snapshots, whole-layer ShaderMask on the danmaku layer (see
// danmaku_occlusion_mask.dart). MPV-only, default off, one switch
// for VOD + live (HiveKeys.danmakuOcclusionAvoidance).
//
// What this is NOT (hard blocks, audit v16): true per-pixel
// real-time cutout. No engine exposes a frame stream to Dart
// (HB-1), flame_barrage 0.0.9 has no per-item mask entry (HB-2),
// and the iOS 17+ per-person mask API is not used (deployment
// target stays 15.0, HB-3). The mask refreshes at ~5 Hz, so a
// fast-moving person leaves a ~100-200 ms "danmaku briefly covers
// the face, then moves away" afterimage — an architecture ceiling,
// not a tuning bug. Do not promise "real-time, no delay" anywhere.
//
// Degradation ladder (audit §4, all silent, no popups):
//   single frame/segmentation failure -> skip the frame, keep the
//     old mask, no retry, no error;
//   3 consecutive empty results (no person, or failures) -> 1 Hz
//     patrol; one frame with a person restores 5 Hz;
//   engine is not MPV -> the loop never starts (silent off);
//   thermal fair -> 1 Hz; thermal serious/critical -> stop until
//     the next page entry (latched, never auto-restarts);
//   scene cut / episode / line / quality switch -> the page calls
//     invalidateMask() and the old mask is dropped at once;
//   mask older than 500 ms -> treated as no mask;
//   background -> the page calls stopLoop(); the loop never runs
//     while backgrounded.

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../logging/app_log.dart';
import '../native/person_segmentation.dart';
import '../storage/hive_store.dart';

/// Active mask refresh: 5 Hz (audit §2-§3 target).
const Duration kOcclusionActiveInterval = Duration(milliseconds: 200);

/// Patrol refresh when no person is on screen: 1 Hz.
const Duration kOcclusionPatrolInterval = Duration(seconds: 1);

/// A mask older than this is treated as no mask (audit §4).
const Duration kOcclusionMaskMaxAge = Duration(milliseconds: 500);

/// Consecutive empty results (no person, or failed frames) before
/// dropping to patrol.
const int kOcclusionEmptyFramesToPatrol = 3;

/// The persisted switch (HiveKeys.danmakuOcclusionAvoidance,
/// default off). Any storage failure reads as off — occlusion must
/// never turn itself on because Hive is uninitialised or corrupt
/// (same discipline as superResolutionSwitchOn).
bool danmakuOcclusionAvoidanceSwitchOn() {
  try {
    return HiveStore.getBool(HiveKeys.danmakuOcclusionAvoidance, false);
  } catch (_) {
    return false;
  }
}

/// Pure degradation ladder: no timers, no channels, no clock —
//  unit-tested on its own. The controller owns one and feeds it
/// frame results + thermal states.
class OcclusionLadder {
  OcclusionLadder({
    this.activeInterval = kOcclusionActiveInterval,
    this.patrolInterval = kOcclusionPatrolInterval,
  });

  /// Active refresh interval (5 Hz default; tests inject shorter).
  final Duration activeInterval;

  /// Patrol refresh interval (1 Hz default; tests inject shorter).
  final Duration patrolInterval;

  int consecutiveEmpty = 0;
  bool thermalFair = false;
  bool thermalStopped = false;

  /// Next tick interval, or null when the loop must stop
  /// (thermal latch — the controller never restarts past it).
  Duration? get interval {
    if (thermalStopped) return null;
    if (thermalFair || consecutiveEmpty >= kOcclusionEmptyFramesToPatrol) {
      return patrolInterval;
    }
    return activeInterval;
  }

  bool get stopped => thermalStopped;

  bool get patrolling =>
      !thermalStopped &&
      (thermalFair ||
          consecutiveEmpty >= kOcclusionEmptyFramesToPatrol);

  /// Feed one tick's outcome. A failure counts as empty for patrol
  /// purposes (no usable mask this tick); the old mask is kept by
  /// the controller, not by this ladder.
  void onFrame({required bool success, required bool hasPerson}) {
    if (success && hasPerson) {
      consecutiveEmpty = 0;
    } else {
      consecutiveEmpty++;
    }
  }

  /// Thermal state raw value (ProcessInfo.ThermalState): 0 nominal,
  /// 1 fair, 2 serious, 3 critical.
  void onThermal(int state) {
    if (state >= 2) {
      thermalStopped = true;
    } else {
      thermalFair = state == 1;
    }
  }

  /// Clear counters for a fresh start. The thermal latch is
  /// deliberately NOT cleared: a thermally stopped loop never
  /// restarts on the same page (audit §4).
  void reset() {
    consecutiveEmpty = 0;
    thermalFair = false;
  }
}

/// Pure: is a mask received at [receivedAt] stale at [now]?
bool isMaskExpired({
  required DateTime receivedAt,
  required DateTime now,
  Duration maxAge = kOcclusionMaskMaxAge,
}) =>
    now.difference(receivedAt) > maxAge;

/// Pure: expand a single-channel mask (255 = person) to RGBA bytes
/// for decodeImageFromPixels. White with alpha = mask value: the
/// shader only needs the alpha (BlendMode.dstOut erases where the
/// shader is opaque), the white keeps the meaning obvious.
Uint8List expandMaskToRgba(Uint8List mask) {
  final out = Uint8List(mask.length * 4);
  for (var i = 0; i < mask.length; i++) {
    final o = i * 4;
    out[o] = 255;
    out[o + 1] = 255;
    out[o + 2] = 255;
    out[o + 3] = mask[i];
  }
  return out;
}

/// Pure: the rect the video actually occupies inside [container]
/// for [fit] — the mask must be mapped onto this rect, NOT the whole
/// container, or a letterboxed (non-16:9) source gets its mask
/// smeared across the black bars (audit §2 acceptance).
Rect videoDisplayRect({
  required Size container,
  required Size video,
  required BoxFit fit,
}) {
  if (container.isEmpty || video.isEmpty) {
    return Rect.fromLTWH(0, 0, container.width, container.height);
  }
  switch (fit) {
    case BoxFit.fill:
      return Offset.zero & container;
    case BoxFit.contain:
      final s =
          (container.width / video.width).clamp(0.0, double.infinity);
      final s2 =
          (container.height / video.height).clamp(0.0, double.infinity);
      final scale = s < s2 ? s : s2;
      return _centered(container, video * scale);
    case BoxFit.cover:
      final s =
          (container.width / video.width).clamp(0.0, double.infinity);
      final s2 =
          (container.height / video.height).clamp(0.0, double.infinity);
      final scale = s > s2 ? s : s2;
      return _centered(container, video * scale);
    case BoxFit.fitWidth:
      final scale = container.width / video.width;
      return _centered(container, video * scale);
    case BoxFit.fitHeight:
      final scale = container.height / video.height;
      return _centered(container, video * scale);
    case BoxFit.none:
      return _centered(container, video);
    case BoxFit.scaleDown:
      final s =
          (container.width / video.width).clamp(0.0, double.infinity);
      final s2 =
          (container.height / video.height).clamp(0.0, double.infinity);
      final scale = (s < s2 ? s : s2).clamp(0.0, 1.0);
      return _centered(container, video * scale);
  }
}

Rect _centered(Size container, Size size) {
  return Rect.fromLTWH(
    (container.width - size.width) / 2,
    (container.height - size.height) / 2,
    size.width,
    size.height,
  );
}

/// Pure: matrix for ImageShader that draws the mask image exactly
/// onto [videoRect] inside the shader's coordinate space (the
/// ShaderMask child's bounds).
///
/// ImageShader samples the image at `matrix * point` (Skia local
/// matrix), so to show the image at rect R: first subtract R's
/// origin, then scale canvas units into image pixels. Matrix4
/// post-multiplies (`..scaleByDouble()..translateByDouble()` =
/// S * T), so the translate applies first to the incoming point —
/// exactly the order needed. Verified by the pure-math test in
/// danmaku_occlusion_test.dart (corner mapping); a pixel-level
/// readback test was dropped — toImage/toByteData never completes
/// in this VM's test engine under load, see
/// danmaku_occlusion_mask_test.dart. True pixel proof is on-device.
Matrix4 maskShaderMatrix({
  required Rect videoRect,
  required Size maskSize,
}) {
  if (videoRect.width <= 0 ||
      videoRect.height <= 0 ||
      maskSize.width <= 0 ||
      maskSize.height <= 0) {
    return Matrix4.identity();
  }
  return Matrix4.identity()
    ..scaleByDouble(
      maskSize.width / videoRect.width,
      maskSize.height / videoRect.height,
      1.0,
      1.0,
    )
    ..translateByDouble(-videoRect.left, -videoRect.top, 0.0, 1.0);
}

/// Injectable clock (tests pin time; production uses DateTime.now).
typedef OcclusionClock = DateTime Function();

/// Runs the take-frame -> segment -> mask loop and owns the current
/// mask image. One controller per player page; the page calls
/// [update] whenever a gate may have changed (build / fullscreen
/// toggle / lifecycle) and [invalidateMask] on episode / line /
/// quality switches. [update] is idempotent and cheap — calling it
/// on every build is the design, not an accident: every gate
/// (switch, danmaku visibility, playing state, engine) changes via
/// a rebuild, so a build-driven refresh cannot miss one.
class DanmakuOcclusionController extends ChangeNotifier {
  DanmakuOcclusionController({
    required this._segmentation,
    required this._frameSource,
    required this._isFrameCapable,
    bool Function()? switchReader,
    Duration activeInterval = kOcclusionActiveInterval,
    Duration patrolInterval = kOcclusionPatrolInterval,
    this._maskMaxAge = kOcclusionMaskMaxAge,
    OcclusionClock? clock,
  })  : _switchReader = switchReader ?? danmakuOcclusionAvoidanceSwitchOn,
        _clock = clock ?? DateTime.now,
        _ladder = OcclusionLadder(
          activeInterval: activeInterval,
          patrolInterval: patrolInterval,
        );

  final PersonSegmentation _segmentation;
  final Future<Uint8List?> Function() _frameSource;
  final bool Function() _isFrameCapable;
  final bool Function() _switchReader;
  final Duration _maskMaxAge;
  final OcclusionClock _clock;

  final OcclusionLadder _ladder;

  Timer? _timer;
  Timer? _expiryTimer;
  bool _running = false;
  bool _tickInFlight = false;
  bool _disposed = false;
  int _generation = 0;

  bool _danmakuVisible = false;
  bool _playing = false;
  bool _lastWant = false;
  Duration? _lastInterval;

  ui.Image? _maskImage;
  Size? _frameSize;
  DateTime? _maskReceivedAt;

  /// Current mask image, or null when there is no (live) mask.
  /// The widget draws nothing extra when this is null — plain
  /// danmaku, zero overhead.
  ui.Image? get maskImage => _maskImage;

  /// Source frame size of the current mask (for the display-rect
  /// math in the widget).
  Size? get frameSize => _frameSize;

  bool get hasMask => _maskImage != null;

  /// Test seam: is the loop ticking?
  bool get running => _running;

  /// Test seam: the interval the ladder currently wants (null =
  /// thermally stopped).
  Duration? get currentInterval => _ladder.interval;

  /// Refresh the gate. Cheap and idempotent: no-ops when nothing
  /// changed, so pages call it from build / Obx builders.
  void update({required bool danmakuVisible, required bool playing}) {
    _danmakuVisible = danmakuVisible;
    _playing = playing;
    final want =
        _switchReader() && _danmakuVisible && _playing && _isFrameCapable();
    if (want == _lastWant && _running == want) return;
    _lastWant = want;
    if (want) {
      _start();
    } else {
      _stop(clearMask: true);
    }
  }

  /// Stop the loop and drop the mask (background / page exit).
  /// A later [update] with the gates on restarts it — unless the
  /// thermal latch tripped, in which case it stays stopped until
  /// the next page entry (new controller).
  void stopLoop() {
    _lastWant = false;
    _stop(clearMask: true);
  }

  /// Drop the current mask at once (scene cut / episode / line /
  /// quality switch). The loop keeps running; the next tick fetches
  /// a fresh frame. Does not touch the ladder.
  void invalidateMask() {
    _generation++;
    _clearMask();
  }

  void _start() {
    if (_disposed || _ladder.stopped) return;
    if (_running) return;
    _ladder.reset();
    _lastInterval = _ladder.interval;
    _running = true;
    AppLog.info('弹幕防遮挡已启动（MPV，5 Hz）');
    _scheduleNext(from: _clock());
  }

  void _stop({required bool clearMask}) {
    _timer?.cancel();
    _timer = null;
    _running = false;
    _tickInFlight = false;
    if (clearMask) _clearMask();
  }

  void _scheduleNext({required DateTime from}) {
    if (!_running || _disposed) return;
    final interval = _ladder.interval;
    if (interval == null) return;
    // Patrol transitions are the audit's "日志可验" signal — log
    // the change, never per-frame.
    if (interval != _lastInterval) {
      _lastInterval = interval;
      if (interval == _ladder.patrolInterval) {
        AppLog.info('弹幕防遮挡：无人物，降为 1 Hz 巡检');
      } else {
        AppLog.info('弹幕防遮挡：有人物，恢复 5 Hz');
      }
    }
    final elapsed = _clock().difference(from);
    var delay = interval - elapsed;
    if (delay.isNegative) delay = Duration.zero;
    _timer?.cancel();
    _timer = Timer(delay, _tick);
  }

  Future<void> _tick() async {
    if (!_running || _disposed) return;
    if (_tickInFlight) return;
    _tickInFlight = true;
    final started = _clock();
    try {
      final jpeg = await _frameSource();
      if (!_running || _disposed) return;
      if (jpeg == null) {
        // Screenshot failure (or not-MPV anymore): skip the frame,
        // keep the old mask, count toward patrol.
        _ladder.onFrame(success: false, hasPerson: false);
        return;
      }
      final mask = await _segmentation.segmentFrame(jpeg);
      if (!_running || _disposed) return;
      if (mask == null) {
        _ladder.onFrame(success: false, hasPerson: false);
        return;
      }
      _ladder.onThermal(mask.thermalState);
      if (_ladder.stopped) {
        AppLog.warn('弹幕防遮挡：过热（thermal ${mask.thermalState}），已停止，下次进播放页再开');
        _lastWant = false;
        _stop(clearMask: true);
        return;
      }
      if (!mask.hasPerson) {
        _ladder.onFrame(success: true, hasPerson: false);
        _clearMask();
        return;
      }
      final image = await _decodeMask(mask);
      if (!_running || _disposed) return;
      if (image == null) {
        _ladder.onFrame(success: false, hasPerson: false);
        return;
      }
      _ladder.onFrame(success: true, hasPerson: true);
      _installMask(image, mask);
    } finally {
      _tickInFlight = false;
      if (_running && !_disposed) _scheduleNext(from: started);
    }
  }

  /// Expand + decode one mask into a ui.Image. Null when the decode
  /// fails or a newer generation invalidated this frame meanwhile.
  /// Async callback form of decodeImageFromPixels: the sync form
  /// (decodeImageFromPixelsSync) is not implemented on Skia, so it
  /// throws in widget tests (and is not a supported path everywhere).
  /// The generation check still holds across the await gap.
  Future<ui.Image?> _decodeMask(PersonMask mask) async {
    final generation = _generation;
    try {
      final rgba = expandMaskToRgba(mask.bytes);
      final completer = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        rgba,
        mask.width,
        mask.height,
        ui.PixelFormat.rgba8888,
        (ui.Image image) {
          if (!completer.isCompleted) completer.complete(image);
        },
      );
      final image = await completer.future;
      if (_disposed || generation != _generation) {
        image.dispose();
        return null;
      }
      return image;
    } catch (_) {
      return null;
    }
  }

  void _installMask(ui.Image image, PersonMask mask) {
    _maskImage?.dispose();
    _maskImage = image;
    _frameSize = Size(
      mask.frameWidth.toDouble(),
      mask.frameHeight.toDouble(),
    );
    _maskReceivedAt = _clock();
    _expiryTimer?.cancel();
    _expiryTimer = Timer(_maskMaxAge, () {
      if (_maskReceivedAt == null) return;
      if (isMaskExpired(
        receivedAt: _maskReceivedAt!,
        now: _clock(),
        maxAge: _maskMaxAge,
      )) {
        _clearMask();
      }
    });
    notifyListeners();
  }

  void _clearMask({bool notify = true}) {
    _expiryTimer?.cancel();
    _expiryTimer = null;
    if (_maskImage == null && _frameSize == null) return;
    _maskImage?.dispose();
    _maskImage = null;
    _frameSize = null;
    _maskReceivedAt = null;
    if (notify) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _timer?.cancel();
    _timer = null;
    _expiryTimer?.cancel();
    _expiryTimer = null;
    _running = false;
    // No notify on dispose: listeners are going away with the page.
    _clearMask(notify: false);
    super.dispose();
  }
}
