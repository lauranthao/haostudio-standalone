// HAo Studio theme controller — immediate switching, persisted.
//
// Standing rules: theme switching takes effect immediately everywhere
// (no restart, no stale cached colours); 4 themes x light/dark = 8
// combinations; follow-system is a first-class mode.

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';

import 'hao_themes.dart';

class ThemeController extends GetxController {
  static const String _themeKey = 'haoThemeId';
  static const String _modeKey = 'haoThemeMode';

  final Rx<HaoThemeId> themeId;
  final Rx<ThemeMode> themeMode;

  ThemeController({HaoThemeId initialTheme = HaoThemeId.appleGlass, ThemeMode initialMode = ThemeMode.system})
      : themeId = initialTheme.obs,
        themeMode = initialMode.obs;

  /// Load persisted values from the `app_settings` Hive box.
  void loadFromBox(Box<dynamic> box) {
    final savedTheme = box.get(_themeKey) as String?;
    if (savedTheme != null) {
      themeId.value = HaoThemeId.values.firstWhere(
        (e) => e.name == savedTheme,
        orElse: () => HaoThemeId.appleGlass,
      );
    }
    final savedMode = box.get(_modeKey) as String?;
    if (savedMode != null) {
      themeMode.value = ThemeMode.values.firstWhere(
        (e) => e.name == savedMode,
        orElse: () => ThemeMode.system,
      );
    }
  }

  void _persist(Box<dynamic> box) {
    box.put(_themeKey, themeId.value.name);
    box.put(_modeKey, themeMode.value.name);
  }

  /// Switch theme immediately everywhere. Persists the choice.
  void setTheme(HaoThemeId id, {Box<dynamic>? box}) {
    themeId.value = id;
    if (box != null) _persist(box);
  }

  /// Switch light / dark / system immediately everywhere.
  void setMode(ThemeMode mode, {Box<dynamic>? box}) {
    themeMode.value = mode;
    if (box != null) _persist(box);
  }

  ThemeData get lightTheme => HaoThemes.of(themeId.value).light;
  ThemeData get darkTheme => HaoThemes.of(themeId.value).dark;
}
