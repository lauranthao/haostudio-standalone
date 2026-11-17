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

  /// Hive key for the custom font family (same key as
  /// HiveKeys.customFontFamily — the controller reads it directly
  /// from the box so the font applies on the first frame).
  static const String _fontKey = 'hao_custom_font_family';

  final Rx<HaoThemeId> themeId;
  final Rx<ThemeMode> themeMode;

  /// Custom font family (stage 2, Beans `FontManager`): '' = system
  /// default, 'HaoCustomFont' = user-installed font (registered with
  /// FontLoader before runApp — see main.dart).
  final RxString customFontFamily = ''.obs;

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
    final savedFont = box.get(_fontKey) as String?;
    if (savedFont != null) customFontFamily.value = savedFont;
  }

  void _persist(Box<dynamic> box) {
    box.put(_themeKey, themeId.value.name);
    box.put(_modeKey, themeMode.value.name);
    box.put(_fontKey, customFontFamily.value);
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

  /// Apply a custom font family immediately everywhere ('' restores
  /// the system font). Persists the choice. The family must already
  /// be registered with FontLoader (CustomFontService does that).
  void setCustomFontFamily(String family, {Box<dynamic>? box}) {
    customFontFamily.value = family;
    if (box != null) _persist(box);
  }

  ThemeData get lightTheme {
    final family = customFontFamily.value;
    return HaoThemes.of(
      themeId.value,
      fontFamily: family.isEmpty ? null : family,
    ).light;
  }

  ThemeData get darkTheme {
    final family = customFontFamily.value;
    return HaoThemes.of(
      themeId.value,
      fontFamily: family.isEmpty ? null : family,
    ).dark;
  }
}
