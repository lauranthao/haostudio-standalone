// Windows desktop keyboard + mouse-wheel shortcuts for player pages.
//
// One shared handler so VOD, live, the music tab and the full player
// all behave the same. Windows only: every entry point early-returns
// `ignored` off Windows, and the callers gate their Focus/Listener
// the same way, so the mobile tree is untouched.
//
// Keys (KeyDownEvent only — KeyUp/KeyRepeat are ignored so holding
// a key does not repeat the action):
// - Space: play / pause toggle.
// - ← / →: seek ∓10 s — VOD ONLY (live is real-time, no seek; music
//   maps them to previous / next track instead — see the callers).
// - ↑ / ↓: system volume ±1 step (1/16, the hardware-key step).
// - F: toggle fullscreen (VOD / live).
// - Esc: exit fullscreen (VOD / live).
//
// Mouse wheel over a player page: system volume ±0.05 per notch
// (scroll up = louder). The pages' SystemVolume coalesces the
// per-tick sets, so a fast scroll sends the latest value only.
//
// Never steal keys from a text field: when the focused widget is an
// EditableText (danmaku input, music search), every key is ignored
// so Space types a space and arrows move the cursor.

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Result of [handleDesktopPlayerKey]: handled when the key was
/// consumed, ignored otherwise (the caller returns it from
/// `Focus.onKeyEvent`).
typedef DesktopKeyResult = KeyEventResult;

/// Handle one key event for a player page on Windows.
///
/// [onTogglePlayPause] is required; [onSeekBackward]/[onSeekForward]
/// are VOD-only (null on live, where seek does not exist);
/// [onPrevious]/[onNext] are music-only (null on video/live);
/// [onToggleFullscreen]/[onExitFullscreen] are video/live-only;
/// [onVolumeStep] takes +1 (louder) / -1 (quieter); null means the
/// caller has no volume control (↑/↓ are then ignored).
KeyEventResult handleDesktopPlayerKey(
  KeyEvent event, {
  required VoidCallback onTogglePlayPause,
  VoidCallback? onSeekBackward,
  VoidCallback? onSeekForward,
  VoidCallback? onPrevious,
  VoidCallback? onNext,
  VoidCallback? onToggleFullscreen,
  VoidCallback? onExitFullscreen,
  void Function(int direction)? onVolumeStep,
}) {
  if (event is! KeyDownEvent) return KeyEventResult.ignored;
  // Typing in a text field (danmaku input, search): the keys belong
  // to the field, never to the player. The focused node sits inside
  // the EditableText, so an ancestor check finds it.
  final focusContext = FocusManager.instance.primaryFocus?.context;
  if (focusContext != null &&
      focusContext.findAncestorWidgetOfExactType<EditableText>() != null) {
    return KeyEventResult.ignored;
  }
  final key = event.logicalKey;
  if (key == LogicalKeyboardKey.space) {
    onTogglePlayPause();
    return KeyEventResult.handled;
  }
  if (key == LogicalKeyboardKey.arrowLeft) {
    if (onSeekBackward != null) {
      onSeekBackward();
      return KeyEventResult.handled;
    }
    if (onPrevious != null) {
      onPrevious();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }
  if (key == LogicalKeyboardKey.arrowRight) {
    if (onSeekForward != null) {
      onSeekForward();
      return KeyEventResult.handled;
    }
    if (onNext != null) {
      onNext();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }
  if (key == LogicalKeyboardKey.arrowUp) {
    if (onVolumeStep != null) {
      onVolumeStep(1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }
  if (key == LogicalKeyboardKey.arrowDown) {
    if (onVolumeStep != null) {
      onVolumeStep(-1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }
  if (key == LogicalKeyboardKey.keyF) {
    if (onToggleFullscreen != null) {
      onToggleFullscreen();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }
  if (key == LogicalKeyboardKey.escape) {
    if (onExitFullscreen != null) {
      onExitFullscreen();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }
  return KeyEventResult.ignored;
}

/// Handle a mouse-wheel event over a player page on Windows.
/// Returns true when the event was consumed (scroll up = louder).
/// [onVolumeDelta] takes a signed delta in 0..1 units.
bool handleDesktopWheel(
  PointerScrollEvent event,
  void Function(double delta) onVolumeDelta,
) {
  if (event.scrollDelta.dy == 0) return false;
  onVolumeDelta(event.scrollDelta.dy < 0 ? 0.05 : -0.05);
  return true;
}
