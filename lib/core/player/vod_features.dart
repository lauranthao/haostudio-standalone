// I-影视 (build 29) — VOD-only feature prefs + pure logic.
//
// One module, one Hive key per feature (see HiveKeys): every switch
// / default in Settings → 影视播放 and every player behaviour below
// reads the SAME key — no second copy of any state, and the
// in-player panel D 组随后接读的也是这些 key.
//
// Scope is VOD ONLY, always: nothing here is read by the live room
// or the music player. Live never gets speed / super-res /
// dialogue-boost (live has no speed control, no VOD-only MPV
// properties), music keeps AVPlayer and its own SleepTimer state.
//
// Defaults: everything OFF / neutral, so a fresh install plays
// exactly like build 28 until the user turns something on —
// except the DV-P8 default, which predates this module and stays
// untouched.
//
// Item map (12 项):
//  1. 倍速记忆 (already persisted: vodPlaybackRate — see
//     VideoPlaybackSettings.playbackRate) + 双击快进秒数可配.
//  2. 手势细节: 双击 ±N 秒 / 双指点按播放暂停 / 双指缩放去黑边 /
//     拖进度震动反馈.
//  3. 对白增强: 中置声道折叠 + loudnorm 动态均衡 — UI/逻辑/偏好
//     + 后端 cap 已接 (K 组 build 29: mpv volume-max=300 + 中置
//     折叠; b30: 链里加 loudnorm, 立体声上才真正听得见 — 折叠
//     本身在立体声上是 bit-identical, 开关原来是摆设).
//  4. 元数据手动纠错 (本地覆盖, 豆瓣是唯一元数据源).
//  5. 防剧透: 隐藏简介 / 模糊未看海报.
//  6. 截图 (MPV only, via FrameCapableBackend) / GIF — see
//     [assessGifRecording]: GIF is NOT implemented, with reasons.
//  7. 播放锁屏 (runtime state on the player page, no Hive key —
//     a lock is a per-session mode, not a default).
//  8. 睡眠定时: reuses the music SleepTimer state machine
//     (services/music/sleep_timer.dart) — same class, same option
//     enum, only separate persisted custom-minutes / episode-count
//     keys. No second timer implementation.
//  9. 纯音频后台模式 (session.setAudioOnly, already exists for
//     live background audio; VOD now uses the same call).
// 10. 分类显示/隐藏/重排 (home rows).
// 11. 单个文件源重扫 (VideoHomeService.rescanSource).
// 12. 时间线缩略图预览 — see [assessTimelineThumbnails]: NOT
//     feasible on the current CMS + backend facts; the assessment
//     function pins the decision so it is not re-litigated by
//     re-implementing a seek-per-preview loop.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../storage/hive_store.dart';
import 'kernel/video_fit.dart';
import '../../features/video/video_models.dart';

// -- 1. 双击快进秒数 ------------------------------------------------------

/// Double-tap seek step options (seconds), in cycle order.
const List<int> kVodDoubleTapSeekOptions = [5, 10, 15, 30, 60];

/// Default double-tap seek step: 10 s (matches the long-standing
/// ±10 s convention; the value is user-changeable, the default is
/// not a behaviour change — build 28 had no double-tap seek at all).
const int kVodDoubleTapSeekDefault = 10;

/// Clamp a stored/entered step to the supported set; garbage reads
/// as the default, never as 0 (a 0 s double-tap would be a dead
/// gesture) or an arbitrary value.
int clampDoubleTapSeekSeconds(int? seconds) {
  if (seconds == null) return kVodDoubleTapSeekDefault;
  if (kVodDoubleTapSeekOptions.contains(seconds)) return seconds;
  // Nearest supported option, so a hand-edited 12 s still lands on
  // a real step instead of resetting silently to 10.
  var best = kVodDoubleTapSeekOptions.first;
  var bestDist = (seconds - best).abs();
  for (final o in kVodDoubleTapSeekOptions.skip(1)) {
    final d = (seconds - o).abs();
    if (d < bestDist) {
      best = o;
      bestDist = d;
    }
  }
  return best;
}

/// The persisted double-tap step (default 10 s). Storage failure
/// reads as the default.
int vodDoubleTapSeekSeconds() {
  try {
    return clampDoubleTapSeekSeconds(
      HiveStore.getInt(
        HiveKeys.vodDoubleTapSeekSeconds,
        kVodDoubleTapSeekDefault,
      ),
    );
  } catch (_) {
    return kVodDoubleTapSeekDefault;
  }
}

/// Next step in the settings cycle (5 → 10 → 15 → 30 → 60 → 5).
int nextDoubleTapSeekSeconds(int current) {
  final i = kVodDoubleTapSeekOptions.indexOf(
    clampDoubleTapSeekSeconds(current),
  );
  return kVodDoubleTapSeekOptions[
      (i + 1) % kVodDoubleTapSeekOptions.length];
}

/// Pure seek target for a double-tap: [forward] = right half of the
/// screen, else left half. Clamped to [0, duration]; a zero/unknown
/// duration seeks nowhere (returns the current position).
double resolveDoubleTapSeek({
  required double position,
  required double duration,
  required bool forward,
  required int seconds,
}) {
  if (duration <= 0) return position;
  final step = clampDoubleTapSeekSeconds(seconds).toDouble();
  final target = forward ? position + step : position - step;
  return target.clamp(0.0, duration);
}

// -- 2. 手势细节 ---------------------------------------------------------

/// Pinch-to-remove-black-bars target: pinch OUT past 1.2x → cover
/// (crop the black bars); pinch IN past 0.85x → back to 自动
/// (contain). Inside the dead zone → null (no change), so a small
/// accidental pinch never flips the fit mid-film.
VideoFitMode? pinchFitTarget(double scale) {
  if (scale >= 1.2) return VideoFitMode.cover;
  if (scale <= 0.85) return VideoFitMode.auto;
  return null;
}

/// Two-finger tap tracker — pure, no Flutter dependency, so the
/// gesture is unit-testable without pumping widgets.
///
/// Feed pointer down/up/move events (pointer ids + positions +
/// timestamps); [noteTap] returns true exactly once when a
/// two-finger tap completes: two pointers down within 200 ms,
/// both up within 400 ms of the first down, neither moving more
/// than 24 px. A pinch (movement) or a hold never completes it.
class TwoFingerTapTracker {
  static const Duration maxDownGap = Duration(milliseconds: 200);
  static const Duration maxTapDuration = Duration(milliseconds: 400);
  static const double maxMove = 24.0;

  final Map<int, _PointerRecord> _down = {};
  DateTime? _firstDownAt;
  bool _movedTooFar = false;
  bool _hadTwoPointers = false;

  void pointerDown(int id, double x, double y, DateTime at) {
    if (_down.length >= 2) return;
    _down[id] = _PointerRecord(x, y);
    _firstDownAt ??= at;
    if (_down.length == 2) {
      _hadTwoPointers = true;
      final first = _firstDownAt;
      if (first != null && at.difference(first) > maxDownGap) {
        // Second finger arrived too late: not one tap.
        _reset();
        pointerDown(id, x, y, at);
      }
    }
  }

  void pointerMove(int id, double x, double y) {
    final rec = _down[id];
    if (rec == null) return;
    final dx = (x - rec.x).abs();
    final dy = (y - rec.y).abs();
    if (dx > maxMove || dy > maxMove) _movedTooFar = true;
  }

  /// Returns true when this pointer-up completes a two-finger tap.
  bool pointerUp(int id, DateTime at) {
    final wasDown = _down.remove(id) != null;
    if (!wasDown) return false;
    if (_down.isEmpty) {
      final first = _firstDownAt;
      final completed = !_movedTooFar &&
          first != null &&
          at.difference(first) <= maxTapDuration &&
          _hadTwoPointers;
      _reset();
      return completed;
    }
    return false;
  }

  /// Drop all tracked pointers (pointer-cancelled: never a tap).
  void reset() => _reset();

  void _reset() {
    _down.clear();
    _firstDownAt = null;
    _movedTooFar = false;
    _hadTwoPointers = false;
  }
}

class _PointerRecord {
  const _PointerRecord(this.x, this.y);
  final double x;
  final double y;
}

/// Pinch tracker — pure, no Flutter dependency.
///
/// Flutter's GestureDetector FORBIDS a scale recognizer alongside
/// horizontal + vertical drag recognizers ("Incorrect GestureDetector
/// arguments … the scale gesture recognizer being ignored") — so
/// pinch is tracked here, from raw pointer events via a Listener
/// (arena-independent, like [TwoFingerTapTracker]), never from
/// onScale. Feed down/move/up; [pointerUp] returns the final pinch
/// scale (current distance / start distance) when the first of two
/// pointers lifts after a two-pointer move, else null. A plain
/// two-finger tap (no movement) returns ~1.0, which
/// [pinchFitTarget] maps to null (no change).
class PinchTracker {
  final Map<int, _PointerRecord> _points = {};
  double? _startDistance;
  double _currentDistance = 0;

  void pointerDown(int id, double x, double y) {
    if (_points.length >= 2) return;
    _points[id] = _PointerRecord(x, y);
    if (_points.length == 2) {
      _startDistance = _distance();
      _currentDistance = _startDistance!;
    }
  }

  void pointerMove(int id, double x, double y) {
    if (!_points.containsKey(id)) return;
    _points[id] = _PointerRecord(x, y);
    if (_points.length == 2) _currentDistance = _distance();
  }

  /// End of the pinch (a pointer lifts). Returns the scale when a
  /// two-pointer gesture ends, else null. Always resets.
  double? pointerUp(int id) {
    if (!_points.containsKey(id)) return null;
    _points.remove(id);
    if (_startDistance != null && _startDistance! > 0) {
      final scale = _currentDistance / _startDistance!;
      _reset();
      return scale;
    }
    if (_points.isEmpty) _reset();
    return null;
  }

  void reset() => _reset();

  void _reset() {
    _points.clear();
    _startDistance = null;
    _currentDistance = 0;
  }

  double _distance() {
    final pts = _points.values.toList();
    final dx = pts[0].x - pts[1].x;
    final dy = pts[0].y - pts[1].y;
    return math.sqrt(dx * dx + dy * dy);
  }
}
/// a 10 s boundary since the last tick, so a long drag buzzes
/// regularly instead of once per pixel (or never). Pure.
bool shouldTickSeekHaptic({
  required double lastTickTarget,
  required double target,
}) =>
    (target - lastTickTarget).abs() >= 10.0;

// -- 3. 对白增强 ---------------------------------------------------------
//
// UI/logic/prefs only. The backend work — mpv `volume-max=300`
// (raises the media_kit volume ceiling so setVolume can exceed
// 100%) + a centre-channel fold + loudnorm dynamic normalization
// — lives in mpv_backend.dart and is K 组's (fold, build 29) plus
// the b30 loudnorm chain. This module only owns the switch and the
// session forward. The loudnorm stage matters: the fold alone is
// bit-identical on stereo, so before b30 the switch did nothing
// audible on the stereo streams nearly every CMS source serves.

/// The persisted dialogue-boost switch (default off).
bool vodDialogueBoostEnabled() {
  try {
    return HiveStore.getBool(HiveKeys.vodDialogueBoost, false);
  } catch (_) {
    return false;
  }
}

/// Gate: VOD only, switch on. Live never reads it (live has no
/// dialogue-boost path — the live room never calls
/// PlaybackSession.setDialogueBoost).
bool shouldApplyDialogueBoost({
  required bool isLive,
  required bool switchOn,
}) =>
    !isLive && switchOn;

// -- 5. 防剧透 -----------------------------------------------------------

/// Hide the synopsis on the detail page (default off — the
/// synopsis stays visible until the user opts into spoiler
/// protection).
bool vodSpoilerHideSynopsis() {
  try {
    return HiveStore.getBool(HiveKeys.vodSpoilerHideSynopsis, false);
  } catch (_) {
    return false;
  }
}

/// Blur the cover poster of unwatched titles on the detail page
/// (default off). Episode cards carry no stills — CMS episodes
/// have no per-episode thumbnails at all (see the item-12 note) —
/// so the cover poster is the only thumbnail that exists to blur;
/// watched titles (in history) are never blurred.
bool vodSpoilerBlurUnwatched() {
  try {
    return HiveStore.getBool(HiveKeys.vodSpoilerBlurUnwatched, false);
  } catch (_) {
    return false;
  }
}

// -- 9. 纯音频后台模式 ----------------------------------------------------

/// Default for the VOD audio-only toggle (default off — a film
/// opens with picture, as before). The player toggle writes this
/// same key, so the next open remembers the choice.
bool vodAudioOnlyDefault() {
  try {
    return HiveStore.getBool(HiveKeys.vodAudioOnly, false);
  } catch (_) {
    return false;
  }
}

// -- 4. 元数据手动纠错 ----------------------------------------------------
//
// Local override only, keyed by the exact source + vodId
// (`'<source>|<vodId>'` — the same identity the resume store
// uses, so a correction never leaks onto a same-title work from
// another source). Applied AFTER the CMS load and AFTER Douban
// enrichment, so a user correction always wins over both —
// including over a Douban poster. Clearing removes the entry, and
// the next load shows the source/Douban values again. Douban stays
// the ONLY metadata source: no TMDB call, key, or attribution is
// added anywhere by this feature.

/// One manual correction: every field optional — an empty field
/// means "keep the source value", never "blank it out".
class VodMetadataOverride {
  const VodMetadataOverride({this.title, this.year, this.poster});

  factory VodMetadataOverride.fromJson(Map<String, dynamic> json) =>
      VodMetadataOverride(
        title: (json['title'] as String?)?.trim().isEmpty == true
            ? null
            : (json['title'] as String?)?.trim(),
        year: (json['year'] as String?)?.trim().isEmpty == true
            ? null
            : (json['year'] as String?)?.trim(),
        poster: (json['poster'] as String?)?.trim().isEmpty == true
            ? null
            : (json['poster'] as String?)?.trim(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (title != null) 'title': title,
        if (year != null) 'year': year,
        if (poster != null) 'poster': poster,
      };

  final String? title;
  final String? year;
  final String? poster;

  bool get isEmpty => title == null && year == null && poster == null;
}

/// Storage key for one work: exact source + vodId.
String vodMetadataOverrideKey(dynamic source, String vodId) =>
    '${source.toString()}|$vodId';

/// Read the whole override map defensively: missing / corrupt /
/// uninitialised Hive reads as empty, never a throw.
Map<String, VodMetadataOverride> readMetadataOverrides() {
  try {
    final raw = HiveStore.box.get(HiveKeys.vodMetadataOverrides);
    if (raw is! String || raw.isEmpty) return const {};
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) return const {};
    final out = <String, VodMetadataOverride>{};
    for (final e in decoded.entries) {
      if (e.value is Map<String, dynamic>) {
        final o = VodMetadataOverride.fromJson(e.value);
        if (!o.isEmpty) out[e.key] = o;
      }
    }
    return out;
  } catch (_) {
    return const {};
  }
}

/// The override for one work, or null.
VodMetadataOverride? metadataOverrideFor(dynamic source, String vodId) =>
    readMetadataOverrides()[vodMetadataOverrideKey(source, vodId)];

/// Persist one correction (empty = clear the entry). Never throws:
/// a settings write must never break the detail page.
Future<void> saveMetadataOverride({
  required dynamic source,
  required String vodId,
  required VodMetadataOverride override,
}) async {
  try {
    final map = Map<String, VodMetadataOverride>.of(
      readMetadataOverrides(),
    );
    final key = vodMetadataOverrideKey(source, vodId);
    if (override.isEmpty) {
      map.remove(key);
    } else {
      map[key] = override;
    }
    await HiveStore.put(
      HiveKeys.vodMetadataOverrides,
      jsonEncode(map.map((k, v) => MapEntry(k, v.toJson()))),
    );
  } catch (_) {}
}

/// Apply an override to a meta, returning a NEW VideoMeta (the
/// original is untouched — the detail page keeps the source meta
/// for the union scan / alt-source matching). Null override returns
/// the meta as-is.
VideoMeta applyMetadataOverride(VideoMeta meta, VodMetadataOverride? o) {
  if (o == null) return meta;
  return VideoMeta(
    name: o.title ?? meta.name,
    pic: o.poster ?? meta.pic,
    picAlt: meta.picAlt,
    year: o.year ?? meta.year,
    type: meta.type,
    area: meta.area,
    remarks: meta.remarks,
    score: meta.score,
    actor: meta.actor,
    director: meta.director,
    content: meta.content,
    runtime: meta.runtime,
    releaseDate: meta.releaseDate,
    douban: meta.douban,
  );
}

/// Apply an override IN PLACE (VideoMeta's fields are mutable).
/// The detail page uses this form: Douban enrichment and the
/// poster patch mutate the SAME meta object afterwards, so a
/// copy would go stale — the page applies the override, enriches,
/// then applies it again (override always wins, including over a
/// Douban poster). Null override is a no-op.
void applyMetadataOverrideInPlace(VideoMeta meta, VodMetadataOverride? o) {
  if (o == null) return;
  if (o.title != null) meta.name = o.title!;
  if (o.year != null) meta.year = o.year!;
  if (o.poster != null) meta.pic = o.poster!;
}

// -- 10. 分类显示/隐藏/重排 ----------------------------------------------
//
// Home rows are CMS types (VideoHomeRow.name). The prefs store the
// user's hidden set + manual order; unknown names (a source added
// a type since the prefs were saved) are never hidden and keep
// their fetched position after the ordered ones.

/// Persisted category prefs: hidden names + manual order.
class VideoCategoryPrefs {
  const VideoCategoryPrefs({
    this.hidden = const {},
    this.order = const [],
  });

  factory VideoCategoryPrefs.fromJson(Map<String, dynamic> json) {
    final hidden = <String>{};
    final order = <String>[];
    final rawHidden = json['hidden'];
    if (rawHidden is List) {
      for (final e in rawHidden) {
        if (e is String && e.isNotEmpty) hidden.add(e);
      }
    }
    final rawOrder = json['order'];
    if (rawOrder is List) {
      for (final e in rawOrder) {
        if (e is String && e.isNotEmpty && !order.contains(e)) {
          order.add(e);
        }
      }
    }
    return VideoCategoryPrefs(hidden: hidden, order: order);
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'hidden': hidden.toList(),
        'order': order,
      };

  final Set<String> hidden;
  final List<String> order;
}

/// Read the persisted category prefs (default: nothing hidden, no
/// manual order — the fetched order stands). Defensive like the
/// other readers.
VideoCategoryPrefs readCategoryPrefs() {
  try {
    final raw = HiveStore.box.get(HiveKeys.vodCategoryPrefs);
    if (raw is! String || raw.isEmpty) return const VideoCategoryPrefs();
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      return const VideoCategoryPrefs();
    }
    return VideoCategoryPrefs.fromJson(decoded);
  } catch (_) {
    return const VideoCategoryPrefs();
  }
}

/// Persist category prefs. Never throws.
Future<void> saveCategoryPrefs(VideoCategoryPrefs prefs) async {
  try {
    await HiveStore.put(
      HiveKeys.vodCategoryPrefs,
      jsonEncode(prefs.toJson()),
    );
  } catch (_) {}
}

/// Apply prefs to fetched home rows (pure): drop hidden rows, then
/// order by the manual order (ordered names first, in order; the
/// rest keep their fetched relative order). Rows whose name is in
/// neither list are untouched.
List<VideoHomeRow> applyCategoryPrefs(
  List<VideoHomeRow> rows,
  VideoCategoryPrefs prefs,
) {
  final visible = rows.where((r) => !prefs.hidden.contains(r.name)).toList();
  if (prefs.order.isEmpty) return visible;
  final rank = <String, int>{
    for (var i = 0; i < prefs.order.length; i++) prefs.order[i]: i,
  };
  final indexed = visible.asMap().entries.toList();
  indexed.sort((a, b) {
    final ra = rank[a.value.name];
    final rb = rank[b.value.name];
    if (ra != null && rb != null) return ra.compareTo(rb);
    if (ra != null) return -1;
    if (rb != null) return 1;
    return a.key.compareTo(b.key);
  });
  return indexed.map((e) => e.value).toList();
}

/// Editor model: every known category name, in display order
/// (manual order first, then the rest in fetched order), each with
/// its hidden flag. Names only in the prefs (a type that no longer
/// fetches) are dropped — the editor edits what exists.
List<({String name, bool hidden})> categoryEditorEntries(
  List<String> fetchedNames,
  VideoCategoryPrefs prefs,
) {
  final ordered = <String>[
    for (final n in prefs.order)
      if (fetchedNames.contains(n)) n,
    for (final n in fetchedNames)
      if (!prefs.order.contains(n)) n,
  ];
  return [
    for (final n in ordered) (name: n, hidden: prefs.hidden.contains(n)),
  ];
}

// -- 6. 截图 / GIF --------------------------------------------------------
//
// Screenshot: MPV only — the only backend with a frame outlet
// (FrameCapableBackend.captureFrameJpeg, media_kit screenshot).
// AVPlayer (BetterPlayer) and IJK expose no frame outlet in Dart,
// so on those engines the player shows "当前内核不支持截图" instead
// of a broken button. The file lands in Documents/screenshots/
// (relative name, per LocalPaths — never an absolute path in Hive)
// and is offered through the share sheet, the only way the file
// reaches the user on iOS.

/// Screenshot file name: `vod_YYYYMMDD_HHmmss.jpg`.
String vodScreenshotFileName(DateTime now) {
  String two(int n) => n.toString().padLeft(2, '0');
  return 'vod_${now.year}${two(now.month)}${two(now.day)}_'
      '${two(now.hour)}${two(now.minute)}${two(now.second)}.jpg';
}

/// Write JPEG bytes to `<documentsDir>/screenshots/<name>`,
/// creating the dir. Returns the written file. Pure I/O (no
/// platform channels), so it is unit-testable with a temp dir.
Future<File> saveVodScreenshot({
  required Uint8List jpeg,
  required Directory documentsDir,
  DateTime? now,
}) async {
  final dir = Directory('${documentsDir.path}/screenshots');
  await dir.create(recursive: true);
  final file = File('${dir.path}/${vodScreenshotFileName(now ?? DateTime.now())}');
  await file.writeAsBytes(jpeg);
  return file;
}

/// GIF recording assessment — NOT implemented, on purpose.
///
/// mpv has no GIF encoder in Dart and no frame-sequence outlet:
/// [captureFrameJpeg] returns ONE current frame, so a GIF would
/// need a capture loop (a timer screenshotting at ~5 fps) plus a
/// GIF encoder (the `image` package is not a dependency, and
/// adding a native encoder for a nicety is out of scope for
/// build 29). A capture loop also fights the occlusion-avoidance
/// snapshot loop for the same frame outlet and burns battery for
/// a feature whose output (a low-fps GIF of a film) has no
/// established need. Screenshot (single frame, MPV only) is the
/// shipped scope; GIF stays unimplemented until a real encoder
/// and a real request for it exist.
({bool feasible, String reason}) assessGifRecording() => (
      feasible: false,
      reason: '无 GIF 编码器（未引入 image 包），且 mpv 只有单帧抓取 '
          'captureFrameJpeg，没有帧序列出口；定时连拍会与弹幕防遮挡的快照循环抢同一出口。'
          '已做截图（MPV 单帧，保存 + 分享）；GIF 不做。',
    );

// -- 12. 时间线缩略图预览 — assessment first ------------------------------
//
// Verdict: NOT feasible, do not implement.
//
// Facts (checked 2026-11-22 against the code, not assumed):
// - CMS returns no thumbnail track and no sprite sheet: the
//   videolist/detail JSON carries only vod_pic (the poster) —
//   grep the CMS parsers for `thumb|sprite|preview` finds only
//   the poster field. There is nothing to download per timestamp.
// - The backends expose no out-of-band frame source: the only
//   frame outlet is FrameCapableBackend.captureFrameJpeg, which
//   captures the CURRENT frame of the PLAYING stream. A preview
//   at time T would need seek(T) → capture → seek(back): on HLS
//   each seek costs ~1–2 s of rebuffer, so scrubbing the timeline
//   would stutter the film it is previewing.
// - The alternative (a second parallel backend decoding the same
//   URL at the preview time) doubles decode + memory for a
//   preview strip and fights the low-memory mode — the opposite
//   of what the player is optimising for.
// A thumbnail strip would need either a CMS that serves sprites
// (none of the 19 sources does) or a server-side frame-extraction
// job (the standalone app has no server by design). So: no code,
// no fake strip of poster repeats (the "不许复用标题海报充数"
// red line from build 28 applies here too).

enum TimelineThumbnailVerdict { feasible, notFeasible }

/// Pure assessment: feasible only when a real per-timestamp source
/// exists (a thumbnail track or a sprite API) or frames can be
/// captured without disturbing playback. The production call
/// passes the real facts (false, false, false) — see above.
({TimelineThumbnailVerdict verdict, String reason})
    assessTimelineThumbnails({
  required bool hasThumbnailTrack,
  required bool hasSpriteApi,
  required bool canCaptureWithoutSeek,
}) {
  if (hasThumbnailTrack || hasSpriteApi || canCaptureWithoutSeek) {
    return (
      verdict: TimelineThumbnailVerdict.feasible,
      reason: '有逐时间点的缩略图来源（轨道 / 雪碧图 / 无扰动抓帧），可做。',
    );
  }
  return (
    verdict: TimelineThumbnailVerdict.notFeasible,
    reason: 'CMS 无缩略图轨道、无雪碧图；唯一帧出口 captureFrameJpeg '
        '只抓当前帧，预览任意时刻须 seek→抓帧→seek 回，HLS 每次 seek '
        '约 1–2 s 重缓冲，拖动预览会打断正片；并行第二路解码则翻倍内存，'
        '与低内存模式相悖。故不做，不贴海报充数。',
  );
}
