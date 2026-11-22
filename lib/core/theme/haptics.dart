// Haptic feedback — port of Beans `BeansHaptics` (Components.swift:21-58).
//
// Beans: four entry points over reused UIImpactFeedbackGenerator /
// UINotificationFeedbackGenerator / UISelectionFeedbackGenerator
// instances, all gated by one UserDefaults flag
// (`beans.haptics.enabled`, default true).
//
// Flutter mapping (same four entry points, same gate, same default):
// - tap()     -> HapticFeedback.lightImpact()   (Beans tap = light)
// - medium()  -> HapticFeedback.mediumImpact() (Beans medium)
// - success() -> UINotificationFeedbackGenerator (.success) on iOS
//   via `HaoHapticsPlugin` (channel `com.haostudio.standalone/haptics`);
//   HapticFeedback.heavyImpact() is the fallback when the channel is
//   missing (unit tests, non-iOS, or a build from before the plugin
//   landed) — the closest distinct signal, and it is only used for
//   completed actions, exactly where Beans calls success()
// - warning() -> UINotificationFeedbackGenerator (.warning), fallback
//   mediumImpact — new in build 29 (iOS notification haptics were
//   missing entirely: Flutter has no notification API)
// - error()   -> UINotificationFeedbackGenerator (.error), fallback
//   heavyImpact — new in build 29, same reason
// - select()  -> HapticFeedback.selectionClick() (Beans selection)
//
// EVERY haptic call in the app goes through here — never call
// HapticFeedback directly at a call site, so the settings switch
// turns all of them off at once. Calls are fire-and-forget: a
// failure (no native plugin, e.g. Linux tests) is swallowed, never
// thrown into the caller's gesture handler.
//
// [debugEnabledOverride] is test-only: when set, it replaces the Hive
// read so tests can assert the on/off behaviour without a Hive box.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../storage/hive_store.dart';

class HaoHaptics {
  HaoHaptics._();

  /// Test-only override for [enabled]. Null = read Hive.
  @visibleForTesting
  static bool? debugEnabledOverride;

  /// Master switch: Hive `hapticsEnabled`, default true (Beans default).
  static bool get enabled {
    if (debugEnabledOverride != null) return debugEnabledOverride!;
    try {
      return HiveStore.getBool(HiveKeys.hapticsEnabled, true);
    } catch (_) {
      // Hive not initialised (unit test without a box): haptics stay
      // on — the platform call itself is still guarded by _fire.
      return true;
    }
  }

  /// Persist the master switch (settings page toggle).
  static Future<void> setEnabled(bool value) =>
      HiveStore.put(HiveKeys.hapticsEnabled, value);

  /// Light tap — buttons, row taps, menu opens (Beans `tap()`).
  static void tap() => _fire(HapticFeedback.lightImpact);

  /// Confirmation — play/pause, favourites, long-press (Beans `medium()`).
  static void medium() => _fire(HapticFeedback.mediumImpact);

  /// Completed action — search finished with results, import done
  /// (Beans `success()`). Native notification haptic on iOS, with the
  /// old heavy-impact fallback when the plugin channel is missing.
  static void success() =>
      _notifyOrFallback('success', HapticFeedback.heavyImpact);

  /// Blocked / failed-soft action (Beans notification warning).
  /// Native notification haptic on iOS, medium-impact fallback.
  static void warning() =>
      _notifyOrFallback('warning', HapticFeedback.mediumImpact);

  /// Failed action (Beans notification error). Native notification
  /// haptic on iOS, heavy-impact fallback.
  static void error() =>
      _notifyOrFallback('error', HapticFeedback.heavyImpact);

  /// Selection change — tab switch, chip pick, drag crossing a tab
  /// (Beans `select()`).
  static void select() => _fire(HapticFeedback.selectionClick);

  /// Slider drag end (N-13): a light tap normally, a selection click
  /// when the drag lands on either end (iOS ticks at the ends).
  static void sliderEnd(double value, double min, double max) {
    if (value <= min || value >= max) {
      select();
    } else {
      tap();
    }
  }

  static void _fire(Future<void> Function() call) {
    if (!enabled) return;
    unawaited(call().catchError((_) {}));
  }

  /// Native notification channel (HaoHapticsPlugin). A missing plugin
  /// (unit tests, non-iOS) completes the invoke with
  /// MissingPluginException — the fallback impact fires instead, so
  /// callers never need to know which path ran.
  static const MethodChannel _notificationChannel =
      MethodChannel('com.haostudio.standalone/haptics');

  static void _notifyOrFallback(
    String type,
    Future<void> Function() fallback,
  ) {
    if (!enabled) return;
    unawaited(
      _notificationChannel
          .invokeMethod<void>('notification', {'type': type})
          .catchError((_) => fallback().catchError((_) {})),
    );
  }
}
