// VOD video fit mode — PiliPlus `VideoFitType` + Kazumi
// `PlayerAspectRatio`, own words/structure (both are GPL-3.0 — no code
// copied, only the mode set and the behaviour).
//
// PiliPlus `lib/plugin/pl_player/models/video_fit_type.dart` (values 0-8):
// fill 拉伸 / contain 自动 / cover 裁剪 / fitWidth 等宽 / fitHeight 等高 /
// none 原始 / scaleDown 限制 / ratio_4x3 4:3 / ratio_16x9 16:9.
// Kazumi `lib/pages/player/controller/player_aspect_ratio.dart`:
// automatic 自动 (contain) / crop 裁切填充 (cover) / stretch 拉伸填充
// (fill) / ratio4x3 4:3 (fill + frame 4/3).
//
// Intersection both projects agree on, and the only three we ship:
// 自动 (contain) / 拉伸 (fill) / 裁剪 (cover).
// NOT shipped, and why:
// - fitWidth / fitHeight / none / scaleDown (PiliPlus-only): marginal
//   modes no user asked for; each would be a half-understood menu entry.
// - 4:3 / 16:9 frame ratios (both projects): they constrain the video
//   FRAME inside a non-fullscreen container. Our VOD player is always
//   landscape fullscreen (StackFit.expand, whole-app rotation) — there
//   is no frame to constrain, so a ratio mode would need a layout
//   rework of the player page, not a fit flag. If a ratio mode is ever
//   wanted, it belongs with that rework, not here.
// - PiliPlus's vertical-video rule (`_initVideoFit`: pref fill +
//   vertical video -> contain) does not apply: our VOD surface is
//   always landscape fullscreen.
//
// Scope (logic check — where it applies, where it does not):
// - VOD only. Live stays contain always: the live room is a portrait
//   16:9 inline surface and the same backends serve it; stretching a
//   live room would distort the stream for a setting the user set
//   while watching a film. The backends gate on their own `_isLive`
//   (MPV/IJK) / the session never asks live for a fit (AVPlayer reads
//   the mode only in open() — see below).
// - MPV + IJK apply a change LIVE: media_kit `Video` re-applies fit
//   in didUpdateWidget (`video_texture.dart:244` — `widget.fit !=
//   oldWidget.fit ? widget.fit : currentParams.fit`) and FijkView
//   re-applies it the same way (`fijkview.dart:407/429`). The VOD page
//   rebuilds after cycling, so the picture changes immediately.
// - AVPlayer does NOT: BetterPlayerConfiguration (incl. `fit`) is
//   fixed when the controller is created in open(). A mid-play cycle
//   on AVPlayer takes effect on the NEXT open — the open() below reads
//   the persisted mode, so the choice is never lost, just deferred.
//   Default engine is MPV, so most users see it instantly.

import 'package:flutter/widgets.dart';

import '../../storage/hive_store.dart';

/// VOD picture fit. Stored as [storageValue] under
/// [HiveKeys.vodVideoFit]; unknown/garbage values read back as [auto]
/// (same fallback discipline as `VideoPlaybackSettings.playbackRate`).
enum VideoFitMode {
  auto('auto', '自动', BoxFit.contain),
  fill('fill', '拉伸', BoxFit.fill),
  cover('cover', '裁剪', BoxFit.cover);

  const VideoFitMode(this.storageValue, this.label, this.boxFit);

  final String storageValue;
  final String label;
  final BoxFit boxFit;

  static VideoFitMode fromStorageValue(Object? value) {
    if (value is String) {
      for (final mode in VideoFitMode.values) {
        if (mode.storageValue == value) return mode;
      }
    }
    return VideoFitMode.auto;
  }

  /// Cycle order for the player top-bar button and the settings row:
  /// 自动 -> 拉伸 -> 裁剪 -> 自动.
  VideoFitMode get next {
    final i = VideoFitMode.values.indexOf(this);
    return VideoFitMode.values[(i + 1) % VideoFitMode.values.length];
  }

  /// Persisted mode; uninitialised/corrupt Hive falls back to [auto]
  /// instead of throwing (unit tests without a box hit this path).
  static VideoFitMode get current {
    try {
      return fromStorageValue(
        HiveStore.getString(HiveKeys.vodVideoFit, 'auto'),
      );
    } catch (_) {
      return VideoFitMode.auto;
    }
  }

  static Future<void> save(VideoFitMode mode) =>
      HiveStore.put(HiveKeys.vodVideoFit, mode.storageValue);
}
