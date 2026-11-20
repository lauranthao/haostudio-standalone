// HAo Studio theme controller — immediate switching, persisted.
//
// Standing rules: theme switching takes effect immediately everywhere
// (no restart, no stale cached colours); 4 themes x light/dark = 8
// combinations; follow-system is a first-class mode.

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';

import '../storage/hive_store.dart';
import 'hao_themes.dart';
import 'tab_bar_accent.dart';

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

  /// The user's custom accent colour (settings -> 自定义强调色):
  /// null = no override, use the per-theme accent. Non-null = the
  /// accent for BOTH modes of every theme (see [lightTheme] /
  /// [darkTheme]). Stored OPAQUE: the sheet stores the colour with
  /// its opacity for the tab bar (a translucent selected tab is a
  /// look), but buttons / switches / progress need a solid accent,
  /// so the opacity is dropped here — the hue is what carries over.
  ///
  /// Persistence lives with [TabBarAccentController]: the sheet
  /// writes the colour (with opacity) to the shared Hive key
  /// `hao_tabbar_accent` and this controller only holds the opaque
  /// in-memory view, so the two never fight over the stored value.
  /// [loadFromBox] reads the same key at startup; [clearCustomAccent]
  /// only clears the in-memory view — the sheet's reset deletes the
  /// stored key as well.
  final Rx<Color?> customAccent = Rx<Color?>(null);

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
    // Custom accent: same shared key the tab bar reads
    // (TabBarAccentController persists it with opacity); the theme
    // takes the opaque form.
    final savedAccent = box.get(HiveKeys.tabBarAccentColor);
    if (savedAccent is int) {
      customAccent.value =
          clampAccentHue(Color(savedAccent)).withValues(alpha: 1.0);
    }
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

  /// The accent actually in effect right now: the custom override
  /// when one is set, else the current theme's own accent for
  /// [brightness]. The ring and the colour picker read this when no
  /// custom colour is stored, so a fresh install never shows an
  /// invented colour (P0-5).
  Color effectiveAccent(Brightness brightness) {
    final custom = customAccent.value;
    if (custom != null) return custom;
    final themes = HaoThemes.of(themeId.value);
    final data = brightness == Brightness.dark ? themes.dark : themes.light;
    return data.extension<HaoTheme>()!.accent;
  }

  /// Apply a custom accent colour immediately everywhere (the root
  /// Obx in HAoApp rebuilds GetMaterialApp when this Rx changes).
  /// Null clears the override and restores the per-theme accent.
  /// Does NOT persist: the sheet persists through
  /// TabBarAccentController (shared key, stored with opacity).
  void setCustomAccent(Color? color) {
    // P1-U6: purple/magenta hues clamp to the 260° blue boundary.
    customAccent.value =
        color == null ? null : clampAccentHue(color).withValues(alpha: 1.0);
  }

  /// Clear the in-memory override (per-theme accent returns). The
  /// sheet's reset also deletes the stored key.
  void clearCustomAccent() {
    customAccent.value = null;
  }

  ThemeData get lightTheme {
    final family = customFontFamily.value;
    return HaoThemes.of(
      themeId.value,
      fontFamily: family.isEmpty ? null : family,
      accentOverride: customAccent.value,
    ).light;
  }

  ThemeData get darkTheme {
    final family = customFontFamily.value;
    return HaoThemes.of(
      themeId.value,
      fontFamily: family.isEmpty ? null : family,
      accentOverride: customAccent.value,
    ).dark;
  }
}
