// Tab-bar selected colour (icon + label of the selected tab) —
// and, since 1.1.5+21, the source of the app-wide custom accent.
//
// User-chosen via the colour picker (settings → 自定义强调色). The
// tab bar reads this controller directly (with the stored opacity —
// a translucent selected tab is a look). The theme reads the SAME
// stored colour through ThemeController (opaque form): every
// accent-role usage (switches, selected chips, play buttons,
// progress, highlights) follows it, so the picked colour is the
// accent everywhere. The pill itself stays a transparent
// liquid-glass lens (never coloured, never black); the bar
// background stays theme glass. Default is NetEase red (chen: the
// tab bar copies NetEase).
//
// The colour is stored with its opacity (Hive int ARGB) and applied
// as-is, so a 50%-opacity pick reads as a translucent selected tab.

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../storage/hive_store.dart';

class TabBarAccentController extends GetxController {
  /// NetEase red — the default selected colour.
  static const Color defaultColor = Color(0xFFFA2D2D);

  static TabBarAccentController ensure() {
    if (Get.isRegistered<TabBarAccentController>()) {
      return Get.find<TabBarAccentController>();
    }
    final controller = Get.put(TabBarAccentController());
    controller._load();
    return controller;
  }

  final Rx<Color> color = defaultColor.obs;

  void _load() {
    try {
      color.value = Color(
        HiveStore.getInt(
          HiveKeys.tabBarAccentColor,
          defaultColor.toARGB32(),
        ),
      );
    } catch (_) {
      // Hive not initialised (widget tests) — keep the default.
    }
  }

  /// Apply immediately (the tab bar rebuilds through the Rx) and
  /// persist. If Hive is unavailable the in-memory value still
  /// applies for the session.
  Future<void> setColor(Color next) async {
    color.value = next;
    try {
      await HiveStore.put(HiveKeys.tabBarAccentColor, next.toARGB32());
    } catch (_) {}
  }

  /// Restore the default (NetEase red) and delete the stored colour,
  /// so the theme accent returns to the per-theme default too. The
  /// sheet's reset calls this and clears ThemeController as well.
  Future<void> reset() async {
    color.value = defaultColor;
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
