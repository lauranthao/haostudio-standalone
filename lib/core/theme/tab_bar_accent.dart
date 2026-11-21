// Custom accent colour — storage + distribution ONLY.
//
// User-chosen via the colour picker (settings → 自定义强调色). This
// controller stores the pick (Hive key `hao_tabbar_accent`, with its
// opacity) and hands it out; it does NOT decide what the app looks
// like when nothing is picked. The bottom tab bar has NOT read this
// controller directly since 2026-11-20 (Muse target: all icons theme
// text, selected tab marked by the glass pill only) — `app_shell.dart`
// has zero references to it. The app-wide accent lives in
// ThemeController: when a custom colour IS stored it overrides the
// per-theme accent (opaque form); when nothing is stored
// ([color] == null) the theme's own accent shows, and the picker /
// ring read that actual accent through
// [ThemeController.effectiveAccent] instead of inventing one.
//
// "No choice" is a real state here, not a colour: the old default
// (NetEase red 0xFFFA2D2D) showed a fake red as the "current" accent
// on a fresh install and seeded the picker HSV from red. There is no
// red default any more — null means "use the theme accent".

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../storage/hive_store.dart';

/// Hue guard (P1-U6): no purple/magenta custom accent. Hues in the
/// 260°–320° band clamp to the 260° blue boundary — the blue side
/// (the 320° side is magenta-pink, so it is not a landing spot).
/// Applied wherever a custom accent is stored or loaded, so a stored
/// purple from before this fix is also corrected on next launch.
Color clampAccentHue(Color color) {
  final hsv = HSVColor.fromColor(color);
  final hue = hsv.hue;
  if (hue > 260 && hue < 320) {
    return hsv.withHue(260).toColor();
  }
  return color;
}

class TabBarAccentController extends GetxController {
  static TabBarAccentController ensure() {
    if (Get.isRegistered<TabBarAccentController>()) {
      return Get.find<TabBarAccentController>();
    }
    final controller = Get.put(TabBarAccentController());
    controller._load();
    return controller;
  }

  /// The user's custom accent, with its stored opacity — or null
  /// when nothing was ever picked (or after "恢复默认"): the theme's
  /// own accent is in effect then.
  final Rx<Color?> color = Rx<Color?>(null);

  void _load() {
    try {
      final stored = HiveStore.box.get(HiveKeys.tabBarAccentColor);
      color.value = stored is int ? Color(stored) : null;
    } catch (_) {
      // Hive not initialised (widget tests) — no choice stored.
    }
  }

  /// Apply immediately (the tab bar rebuilds through the Rx) and
  /// persist. If Hive is unavailable the in-memory value still
  /// applies for the session.
  Future<void> setColor(Color next) async {
    final clamped = clampAccentHue(next);
    color.value = clamped;
    try {
      await HiveStore.put(HiveKeys.tabBarAccentColor, clamped.toARGB32());
    } catch (_) {}
  }

  /// Clear the custom colour and delete the stored key, so the theme
  /// accent returns to the per-theme default. The sheet's reset calls
  /// this and clears ThemeController as well.
  Future<void> reset() async {
    color.value = null;
    try {
      await HiveStore.delete(HiveKeys.tabBarAccentColor);
    } catch (_) {}
  }
}

/// The colour sheet's preset dots: 5 built-in defaults (never
/// deletable) plus the user's own customs (persisted in Hive, added
/// with the sheet's + button, long-press a custom to delete).
class AccentPresetStore {
  /// Built-in presets, in sheet order: black, blue, green, yellow,
  /// red (the reference sheet's five dots).
  static const List<Color> defaults = [
    Color(0xFF000000),
    Color(0xFF2563EB),
    Color(0xFF22C55E),
    Color(0xFFFACC15),
    Color(0xFFEF4444),
  ];

  /// User-added presets, in the order added. Empty when Hive is
  /// unavailable (widget tests without Hive).
  static List<Color> loadCustoms() {
    try {
      final raw = HiveStore.box.get(HiveKeys.tabBarAccentPresets);
      if (raw is! List) return [];
      return [
        for (final v in raw)
          if (v is int) Color(v),
      ];
    } catch (_) {
      return [];
    }
  }

  static Future<void> saveCustoms(List<Color> customs) async {
    try {
      await HiveStore.put(
        HiveKeys.tabBarAccentPresets,
        [for (final c in customs) c.toARGB32()],
      );
    } catch (_) {}
  }

  /// True when [color] is already a preset (default or custom) —
  /// the + button adds nothing then, so the list never duplicates.
  static bool contains(Color color, List<Color> customs) =>
      defaults.contains(color) || customs.contains(color);
}
